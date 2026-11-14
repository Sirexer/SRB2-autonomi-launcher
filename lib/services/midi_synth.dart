import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'killable.dart';

export 'killable.dart' show RenderCancelled;

/// Событие MIDI с абсолютным временем в секундах.
class MidiEvent {
  final double time;
  final int status; // 0x80..0xEF (с каналом)
  final int a;
  final int b;
  const MidiEvent(this.time, this.status, this.a, this.b);
  int get channel => status & 0x0F;
  int get type => status & 0xF0;
}

/// Стандартный MIDI-файл (форматы 0 и 1): события всех дорожек по времени,
/// с учётом смены темпа.
class MidiFile {
  final List<MidiEvent> events;
  final double duration;
  const MidiFile(this.events, this.duration);

  static MidiFile parse(Uint8List b) {
    if (b.length >= 4 && b[0] == 0x4D && b[1] == 0x55 && b[2] == 0x53 && b[3] == 0x1A) return _parseMus(b);
    final bd = ByteData.sublistView(b);
    if (b.length < 14 || ascii.decode(b.sublist(0, 4)) != 'MThd') throw const FormatException('Not a MIDI file');
    final headerLen = bd.getUint32(4);
    final tracks = bd.getUint16(10);
    final division = bd.getUint16(12);
    if (division & 0x8000 != 0) throw const FormatException('SMPTE time is not supported');
    var p = 8 + headerLen;

    // (тик, порядок, статус, a, b) и смены темпа (тик, мкс на четверть).
    final raw = <(int, int, int, int, int)>[];
    final tempos = <(int, int)>[];
    var order = 0;
    for (var t = 0; t < tracks && p + 8 <= b.length; t++) {
      final id = ascii.decode(b.sublist(p, p + 4), allowInvalid: true);
      final len = bd.getUint32(p + 4);
      p += 8;
      final end = math.min(p + len, b.length);
      if (id != 'MTrk') {
        p = end;
        continue;
      }
      var tick = 0;
      var running = 0;
      int vlq() {
        var v = 0;
        while (p < end) {
          final c = b[p++];
          v = (v << 7) | (c & 0x7F);
          if (c & 0x80 == 0) break;
        }
        return v;
      }

      while (p < end) {
        tick += vlq();
        if (p >= end) break;
        var status = b[p];
        if (status & 0x80 != 0) {
          p++;
        } else {
          status = running; // running status
        }
        if (status == 0xFF) {
          final type = b[p++];
          final l = vlq();
          if (type == 0x51 && l == 3 && p + 3 <= end) {
            tempos.add((tick, (b[p] << 16) | (b[p + 1] << 8) | b[p + 2]));
          }
          p += l;
          if (type == 0x2F) break; // конец дорожки
        } else if (status == 0xF0 || status == 0xF7) {
          p += vlq(); // SysEx
        } else if (status >= 0x80) {
          running = status;
          final type = status & 0xF0;
          final a = p < end ? b[p++] : 0;
          final c = type == 0xC0 || type == 0xD0 ? 0 : (p < end ? b[p++] : 0);
          raw.add((tick, order++, status, a, c));
        } else {
          break; // повреждённые данные
        }
      }
      p = end;
    }

    raw.sort((x, y) => x.$1 != y.$1 ? x.$1.compareTo(y.$1) : x.$2.compareTo(y.$2));
    tempos.sort((x, y) => x.$1.compareTo(y.$1));

    // Тики → секунды по карте темпа.
    var tempo = 500000;
    var lastTick = 0;
    var lastTime = 0.0;
    var ti = 0;
    double toSeconds(int tick) {
      while (ti < tempos.length && tempos[ti].$1 <= tick) {
        lastTime += (tempos[ti].$1 - lastTick) * tempo / 1e6 / division;
        lastTick = tempos[ti].$1;
        tempo = tempos[ti].$2;
        ti++;
      }
      return lastTime + (tick - lastTick) * tempo / 1e6 / division;
    }

    final events = [for (final e in raw) MidiEvent(toSeconds(e.$1), e.$3, e.$4, e.$5)];
    return MidiFile(events, events.isEmpty ? 0 : events.last.time);
  }
}

/// Doom MUS → события MIDI. Такты по 140 Гц; канал 15 — ударные (10-й
/// канал MIDI), каналы 9..14 сдвигаются на один (как в mus2mid).
MidiFile _parseMus(Uint8List b) {
  if (b.length < 16) throw const FormatException('Not a MUS file');
  final bd = ByteData.sublistView(b);
  var p = bd.getUint16(6, Endian.little); // начало партитуры
  int byte() => p < b.length ? b[p++] : 0;
  int channel(int c) => c == 15 ? 9 : (c >= 9 ? c + 1 : c);
  final volume = List.filled(16, 100);
  final events = <MidiEvent>[];
  var tick = 0;
  score:
  while (p < b.length) {
    final desc = byte();
    final c = channel(desc & 0x0F);
    final t = tick / 140;
    switch ((desc >> 4) & 7) {
      case 0: // отпустить ноту
        events.add(MidiEvent(t, 0x80 | c, byte() & 0x7F, 0));
      case 1: // нажать ноту (громкость — если старший бит)
        final note = byte();
        if (note & 0x80 != 0) volume[c] = byte() & 0x7F;
        events.add(MidiEvent(t, 0x90 | c, note & 0x7F, volume[c]));
      case 2: // pitch bend: 0..255, 128 — середина
        final v = math.min(byte() * 64, 16383);
        events.add(MidiEvent(t, 0xE0 | c, v & 0x7F, v >> 7));
      case 3: // системные: all sounds off, all notes off, mono, poly, reset
        final cc = switch (byte()) { 10 => 120, 11 => 123, 12 => 126, 13 => 127, 14 => 121, _ => -1 };
        if (cc >= 0) events.add(MidiEvent(t, 0xB0 | c, cc, 0));
      case 4: // контроллер: 0 — инструмент, остальные — CC
        final ctrl = byte(), value = byte() & 0x7F;
        if (ctrl == 0) {
          events.add(MidiEvent(t, 0xC0 | c, value, 0));
        } else {
          final cc = switch (ctrl) { 1 => 0, 2 => 1, 3 => 7, 4 => 10, 5 => 11, 6 => 91, 7 => 93, 8 => 64, 9 => 67, _ => -1 };
          if (cc >= 0) events.add(MidiEvent(t, 0xB0 | c, cc, value));
        }
      case 5: // конец такта
        break;
      case 6: // конец партитуры
        break score;
      default:
        byte();
    }
    if (desc & 0x80 != 0) {
      var delay = 0;
      while (p < b.length) {
        final x = b[p++];
        delay = (delay << 7) | (x & 0x7F);
        if (x & 0x80 == 0) break;
      }
      tick += delay;
    }
  }
  return MidiFile(events, tick / 140);
}

// --- SoundFont 2 ---

class _Sf2Sample {
  final int start, end, loopStart, loopEnd, rate, originalPitch, correction;

  /// Данные сэмпла [start, end] (читаются из файла при первой ноте); индекс
  /// в общем массиве сэмплов SoundFont — [base] + индекс в [data].
  Int16List? data;
  int base = 0;

  _Sf2Sample(this.start, this.end, this.loopStart, this.loopEnd, this.rate, this.originalPitch, this.correction);
}

/// Зона инструмента после сложения генераторов (то, что нужно для ноты).
class _Zone {
  final _Sf2Sample sample;
  final int startOffset, endOffset, loopStartOffset, loopEndOffset;
  final int rootKey; // -1 — из сэмпла
  final double tuneCents;
  final int scaleTuning;
  final int sampleModes;
  final double attenuationCb;
  final double pan; // -500..500
  final double attack, hold, decay, release; // секунды
  final double sustainCb;
  final int exclusiveClass;
  const _Zone(this.sample, this.startOffset, this.endOffset, this.loopStartOffset, this.loopEndOffset, this.rootKey,
      this.tuneCents, this.scaleTuning, this.sampleModes, this.attenuationCb, this.pan, this.attack, this.hold,
      this.decay, this.release, this.sustainCb, this.exclusiveClass);
}

/// Откуда читать SoundFont: файл (по кускам) или байты в памяти.
abstract class _Sf2Source {
  int get length;

  /// Новый массив (с нулевым смещением — его можно смотреть как Int16List).
  Uint8List read(int offset, int count);
  void close();
}

class _MemorySource implements _Sf2Source {
  final Uint8List bytes;
  _MemorySource(this.bytes);

  @override
  int get length => bytes.length;

  @override
  Uint8List read(int offset, int count) {
    final from = math.max(0, math.min(offset, bytes.length));
    final to = math.max(from, math.min(offset + count, bytes.length));
    return Uint8List.fromList(Uint8List.sublistView(bytes, from, to));
  }

  @override
  void close() {}
}

class _FileSource implements _Sf2Source {
  final RandomAccessFile file;
  @override
  final int length;
  _FileSource(this.file) : length = file.lengthSync();

  @override
  Uint8List read(int offset, int count) {
    file.setPositionSync(offset);
    return file.readSync(count);
  }

  @override
  void close() {
    try {
      file.closeSync();
    } catch (_) {}
  }
}

/// SoundFont 2 (упрощённо: сэмплы, диапазоны клавиш/скоростей, настройка,
/// петли, громкостная огибающая, панорама; без фильтров и модуляторов).
///
/// Сэмплы не читаются целиком: SoundFont на сотни мегабайт загружается
/// быстро, с диска берутся только сэмплы нот, которые звучат в MIDI.
class SoundFont {
  final _Sf2Source _source;
  final int _smplAt; // смещение данных сэмплов в файле
  final int _sampleCount; // всего сэмплов (16 бит)
  final Map<int, List<(List<int>, List<int>)>> _presets; // bank<<8|program → зоны пресета (gens, instGensList)
  final List<_Sf2Sample> _sampleHeaders;
  final List<List<(List<int>, Map<int, int>)>> _instruments; // зоны: (keyVel, gens)

  /// Сколько сэмплов прочитано с диска (для проверки ленивой загрузки).
  int loadedSamples = 0;

  SoundFont._(this._source, this._smplAt, this._sampleCount, this._presets, this._sampleHeaders, this._instruments);

  /// SoundFont из файла; данные сэмплов читаются по мере надобности,
  /// поэтому файл остаётся открытым до [close].
  static SoundFont load(String path) {
    final f = File(path).openSync();
    try {
      return _parse(_FileSource(f));
    } catch (_) {
      f.closeSync();
      rethrow;
    }
  }

  static SoundFont parse(Uint8List b) => _parse(_MemorySource(b));

  void close() => _source.close();

  static String _tag(Uint8List b, int at) => ascii.decode(b.sublist(at, at + 4), allowInvalid: true);

  static SoundFont _parse(_Sf2Source src) {
    final head = src.read(0, 12);
    if (head.length < 12 || _tag(head, 0) != 'RIFF' || _tag(head, 8) != 'sfbk') {
      throw const FormatException('Not a SoundFont 2 file');
    }
    // Читаем только заголовки блоков; данные сэмплов (sdta) пропускаем.
    final chunks = <String, (int, int)>{};
    void walk(int from, int to) {
      var p = from;
      while (p + 8 <= to) {
        final h = src.read(p, 12);
        if (h.length < 8) break;
        final id = _tag(h, 0);
        final len = ByteData.sublistView(h).getUint32(4, Endian.little);
        if (id == 'LIST') {
          walk(p + 12, math.min(p + 8 + len, to));
        } else {
          chunks[id] = (p + 8, math.max(0, math.min(len, to - p - 8)));
        }
        p += 8 + len + (len & 1);
      }
    }

    walk(12, src.length);
    (int, int) need(String id) => chunks[id] ?? (throw FormatException('SoundFont: no $id'));
    ByteData chunk(String id) {
      final (at, len) = need(id);
      return ByteData.sublistView(src.read(at, len));
    }

    final (smplAt, smplLen) = need('smpl');
    final phdr = chunk('phdr'), pbag = chunk('pbag'), pgen = chunk('pgen');
    final inst = chunk('inst'), ibag = chunk('ibag'), igen = chunk('igen');
    final shdr = chunk('shdr');
    int count(ByteData d, int size) => d.lengthInBytes ~/ size;
    int u16(ByteData d, int at) => d.getUint16(at, Endian.little);
    int u32(ByteData d, int at) => d.getUint32(at, Endian.little);

    final headers = [
      for (var i = 0; i < count(shdr, 46); i++)
        _Sf2Sample(
          u32(shdr, i * 46 + 20),
          u32(shdr, i * 46 + 24),
          u32(shdr, i * 46 + 28),
          u32(shdr, i * 46 + 32),
          u32(shdr, i * 46 + 36),
          shdr.getUint8(i * 46 + 40),
          shdr.getInt8(i * 46 + 41),
        ),
    ];

    Map<int, int> gensOf(ByteData gen, int from, int to) => {
          for (var g = from; g < to && g < count(gen, 4); g++) u16(gen, g * 4): u16(gen, g * 4 + 2),
        };

    // Инструменты: зоны (генераторы); глобальная зона (без sampleID) — по умолчанию.
    final instruments = <List<(List<int>, Map<int, int>)>>[];
    final nInst = count(inst, 22), nIbag = count(ibag, 4);
    for (var i = 0; i + 1 < nInst; i++) {
      final from = u16(inst, i * 22 + 20), to = u16(inst, (i + 1) * 22 + 20);
      Map<int, int> global = {};
      final zones = <(List<int>, Map<int, int>)>[];
      for (var z = from; z < to && z + 1 < nIbag; z++) {
        final g = gensOf(igen, u16(ibag, z * 4), u16(ibag, (z + 1) * 4));
        if (!g.containsKey(53)) {
          if (z == from) global = g;
          continue;
        }
        final merged = {...global, ...g};
        zones.add((_ranges(merged), merged));
      }
      instruments.add(zones);
    }

    // Пресеты: зоны со ссылкой на инструмент.
    final presets = <int, List<(List<int>, List<int>)>>{};
    final nPhdr = count(phdr, 38), nPbag = count(pbag, 4);
    for (var i = 0; i + 1 < nPhdr; i++) {
      final program = u16(phdr, i * 38 + 20), bank = u16(phdr, i * 38 + 22);
      final from = u16(phdr, i * 38 + 24), to = u16(phdr, (i + 1) * 38 + 24);
      Map<int, int> global = {};
      final zones = <(List<int>, List<int>)>[];
      for (var z = from; z < to && z + 1 < nPbag; z++) {
        final g = gensOf(pgen, u16(pbag, z * 4), u16(pbag, (z + 1) * 4));
        if (!g.containsKey(41)) {
          if (z == from) global = g;
          continue;
        }
        final merged = {...global, ...g};
        // (диапазоны, [инструмент, генераторы-добавки...])
        zones.add((_ranges(merged), [merged[41]!, ..._flatten(merged)]));
      }
      presets[(bank << 8) | program] = zones;
    }
    return SoundFont._(src, smplAt, smplLen ~/ 2, presets, headers, instruments);
  }

  /// Читает данные сэмпла с диска (один раз): от start до end включительно —
  /// end указывает на первый из нулевых сэмплов-разделителей, он нужен для
  /// интерполяции последнего сэмпла.
  void _ensureData(_Sf2Sample s) {
    if (s.data != null) return;
    final lo = math.max(0, math.min(s.start, _sampleCount));
    final hi = math.max(lo, math.min(s.end + 1, _sampleCount));
    s.base = lo;
    s.data = _int16(_source.read(_smplAt + lo * 2, (hi - lo) * 2));
    loadedSamples += hi - lo;
  }

  /// Байты (little-endian) → Int16List: на обычных процессорах — без
  /// копирования, просто другим взглядом на те же байты.
  static Int16List _int16(Uint8List bytes) {
    final n = bytes.length ~/ 2;
    if (Endian.host == Endian.little && bytes.offsetInBytes.isEven) {
      return bytes.buffer.asInt16List(bytes.offsetInBytes, n);
    }
    final bd = ByteData.sublistView(bytes);
    final out = Int16List(n);
    for (var i = 0; i < n; i++) {
      out[i] = bd.getInt16(i * 2, Endian.little);
    }
    return out;
  }

/// [kLo, kHi, vLo, vHi].
  static List<int> _ranges(Map<int, int> g) {
    final k = g[43] ?? 0x7F00, v = g[44] ?? 0x7F00;
    return [k & 0xFF, k >> 8, v & 0xFF, v >> 8];
  }

  static List<int> _flatten(Map<int, int> g) => [for (final e in g.entries) ...[e.key, e.value]];

  static double _tc(int? v, double def) => v == null ? def : math.pow(2, v.toSigned(16) / 1200).toDouble();

  /// Зоны для ноты [key] со скоростью [vel] в банке/программе (с запасным
  /// вариантом: банк 0 той же программы, затем программа 0).
  List<_Zone> zonesFor(int bank, int program, int key, int vel) {
    final preset = _presets[(bank << 8) | program] ??
        _presets[(bank == 128 ? 128 << 8 : 0) | program] ??
        _presets[bank == 128 ? 128 << 8 : 0] ??
        (_presets.isEmpty ? null : _presets.values.first);
    if (preset == null) return const [];
    final out = <_Zone>[];
    for (final (pr, data) in preset) {
      if (key < pr[0] || key > pr[1] || vel < pr[2] || vel > pr[3]) continue;
      final instIndex = data[0];
      if (instIndex >= _instruments.length) continue;
      final add = <int, int>{for (var i = 1; i + 1 < data.length; i += 2) data[i]: data[i + 1]};
      for (final (ir, g) in _instruments[instIndex]) {
        if (key < ir[0] || key > ir[1] || vel < ir[2] || vel > ir[3]) continue;
        final sid = g[53]!;
        if (sid >= _sampleHeaders.length) continue;
        int s(int gen) => (g[gen] ?? 0).toSigned(16) + (add[gen] ?? 0).toSigned(16);
        double env(int gen, double def) {
          final base = g[gen];
          final extra = add[gen];
          if (base == null && extra == null) return def;
          return _tc((base ?? -12000).toSigned(16) + (extra ?? 0).toSigned(16), def);
        }

        out.add(_Zone(
          _sampleHeaders[sid],
          s(0) + s(4) * 32768,
          s(1) + s(12) * 32768,
          s(2) + s(45) * 32768,
          s(3) + s(50) * 32768,
          g.containsKey(58) ? g[58]!.toSigned(16) : -1,
          s(51) * 100.0 + s(52),
          g.containsKey(56) ? g[56]!.toSigned(16) : 100,
          (g[54] ?? 0) & 3,
          s(48).toDouble().clamp(0, 1440),
          s(17).toDouble().clamp(-500, 500),
          env(34, 0.001),
          env(35, 0.001),
          env(36, 0.001),
          env(38, 0.001),
          s(37).toDouble().clamp(0, 1440),
          g[57] ?? 0,
        ));
      }
    }
    return out;
  }
}

// --- Синтез ---

class _Voice {
  final int channel, key;
  final double velGain;
  bool held = true;
  bool sustained = false;
  double age = 0; // секунды с начала
  double releaseAge = -1; // секунды с отпускания
  double releaseFrom = 0;
  double level = 0;

  // Простой синтез.
  int wave = 0; // 0 sine 1 square 2 saw 3 triangle 4 noise
  double phase = 0;
  double baseFreq = 0;
  double attack = 0.005, decay = 0.3, sustain = 0.7, release = 0.15;
  bool drum = false;
  int drumKind = 0;

  // SoundFont.
  _Zone? zone;
  Int16List data = _noData;
  int base = 0;
  double pos = 0;
  double baseStep = 0;

  _Voice(this.channel, this.key, this.velGain);
}

final _noData = Int16List(0);

class _Channel {
  int program = 0;
  int bank = 0;
  double volume = 100 / 127, expression = 1, pan = 0.5, bend = 0;
  bool sustain = false;
}

/// Рендер MIDI в PCM (стерео, 16 бит): по SoundFont или простым встроенным
/// синтезатором (волны по семействам инструментов GM, ударные — шум и тоны).
class MidiRenderer {
  MidiRenderer._();

  static const sampleRate = 44100;

  /// В отдельном изоляте: байты MIDI (или MUS) → WAV. [sf2] — путь к
  /// SoundFont или null. [onProgress] получает долю готового (0..1). Если
  /// [cancelled] вернёт true, рендер прерывается (изолят убивается) с
  /// ошибкой [RenderCancelled].
  static Future<Uint8List> renderToWavInBackground(Uint8List midi, String? sf2,
      {void Function(double progress)? onProgress, bool Function()? cancelled}) async {
    final result = await runKillable(
      _renderJob,
      (TransferableTypedData.fromList([midi]), sf2),
      onProgress: onProgress,
      cancelled: cancelled,
    );
    return (result as TransferableTypedData).materialize().asUint8List();
  }

  static void _renderJob(IsolateJob job) {
    final (data, sf2) = job.input as (TransferableTypedData, String?);
    final midi = data.materialize().asUint8List();
    final font = sf2 == null ? null : SoundFont.load(sf2);
    try {
      job.done(TransferableTypedData.fromList([renderToWav(midi, font, onProgress: job.progress)]));
    } finally {
      font?.close();
    }
  }

  static Uint8List renderToWav(Uint8List midi, SoundFont? font, {void Function(double progress)? onProgress}) {
    final pcm = render(MidiFile.parse(midi), font, onProgress: onProgress);
    return wav(pcm, sampleRate, 2);
  }

  static Int16List render(MidiFile file, SoundFont? font, {void Function(double progress)? onProgress}) {
    const tail = 2.0; // хвост на затухание
    final total = ((file.duration + tail) * sampleRate).ceil();
    final out = Float32List(total * 2);
    final channels = List.generate(16, (_) => _Channel());
    final voices = <_Voice>[];
    final rng = math.Random(1);
    var ei = 0;
    const block = 64;
    // Прогресс — примерно каждый процент.
    final every = math.max(1, total ~/ block ~/ 100);

    for (var start = 0, b = 0; start < total; start += block, b++) {
      if (onProgress != null && b % every == 0) onProgress(start / total);
      final t = start / sampleRate;
      while (ei < file.events.length && file.events[ei].time <= t) {
        _apply(file.events[ei++], channels, voices, font);
      }
      final n = math.min(block, total - start);
      for (final v in voices) {
        final ch = channels[v.channel];
        final chGain = ch.volume * ch.volume * ch.expression; // громкость — квадратичная кривая
        final bendRatio = ch.bend == 0 ? 1.0 : math.pow(2, ch.bend * 2 / 12).toDouble();
        if (v.zone != null) {
          _renderSf2(v, out, start, n, chGain, ch.pan, bendRatio);
        } else {
          _renderSimple(v, out, start, n, chGain, ch.pan, bendRatio, rng);
        }
      }
      voices.removeWhere((v) => v.level < 0.0001 && v.releaseAge >= 0 && v.releaseAge > 0.02);
    }

    // Нормализация мягким ограничителем.
    final pcm = Int16List(out.length);
    for (var i = 0; i < out.length; i++) {
      final x = out[i] * 0.6;
      final y = x / (1 + x.abs()); // мягкий клиппинг
      pcm[i] = (y * 32767).round().clamp(-32768, 32767);
    }
    return pcm;
  }

  static void _apply(MidiEvent e, List<_Channel> channels, List<_Voice> voices, SoundFont? font) {
    final ch = channels[e.channel];
    switch (e.type) {
      case 0x90 when e.b > 0:
        _noteOn(e.channel, e.a, e.b, ch, voices, font);
      case 0x80 || 0x90:
        for (final v in voices) {
          if (v.channel == e.channel && v.key == e.a && v.held) {
            v.held = false;
            if (ch.sustain) {
              v.sustained = true;
            } else {
              _release(v);
            }
          }
        }
      case 0xB0:
        switch (e.a) {
          case 0:
            ch.bank = e.b;
          case 7:
            ch.volume = e.b / 127;
          case 10:
            ch.pan = e.b / 127;
          case 11:
            ch.expression = e.b / 127;
          case 64:
            ch.sustain = e.b >= 64;
            if (!ch.sustain) {
              for (final v in voices) {
                if (v.channel == e.channel && v.sustained) {
                  v.sustained = false;
                  _release(v);
                }
              }
            }
          case 120 || 123:
            for (final v in voices) {
              if (v.channel == e.channel) _release(v);
            }
          case 121:
            ch
              ..volume = 100 / 127
              ..expression = 1
              ..pan = 0.5
              ..bend = 0
              ..sustain = false;
        }
      case 0xC0:
        ch.program = e.a;
      case 0xE0:
        ch.bend = (((e.b << 7) | e.a) - 8192) / 8192;
    }
  }

  static void _release(_Voice v) {
    if (v.releaseAge >= 0) return;
    v.held = false;
    v.releaseAge = 0;
    v.releaseFrom = v.level;
  }

  static void _noteOn(int channel, int key, int vel, _Channel ch, List<_Voice> voices, SoundFont? font) {
    // Ограничение полифонии — самый старый голос уходит.
    if (voices.length >= 64) voices.removeAt(0);
    final velGain = (vel / 127) * (vel / 127);
    final drums = channel == 9;
    if (font != null) {
      final zones = font.zonesFor(drums ? 128 : ch.bank, ch.program, key, vel);
      for (final z in zones) {
        if (z.exclusiveClass != 0) {
          for (final o in voices) {
            if (o.channel == channel && o.zone?.exclusiveClass == z.exclusiveClass) _release(o);
          }
        }
        final s = z.sample;
        font._ensureData(s);
        final data = s.data!;
        if (data.length < 2) continue;
        final root = z.rootKey >= 0 ? z.rootKey : s.originalPitch;
        final cents = (key - root) * z.scaleTuning + z.tuneCents + s.correction;
        final start = math.max(s.base, math.min(s.start + z.startOffset, s.base + data.length - 2));
        final v = _Voice(channel, key, velGain)
          ..zone = z
          ..data = data
          ..base = s.base
          ..pos = start.toDouble()
          ..baseStep = math.pow(2, cents / 1200).toDouble() * s.rate / sampleRate;
        voices.add(v);
      }
      if (zones.isNotEmpty) return;
    }
    final v = _Voice(channel, key, velGain);
    if (drums) {
      v
        ..drum = true
        ..drumKind = _drumKind(key)
        ..attack = 0.001;
      v.decay = switch (v.drumKind) { 0 => 0.25, 1 => 0.18, 2 => 0.05, 3 => 0.6, _ => 0.2 };
      v.sustain = 0;
      v.release = 0.05;
      v.baseFreq = switch (v.drumKind) { 0 => 60.0, 4 => 80.0 + (key - 41) * 12, _ => 180.0 };
    } else {
      v.baseFreq = 440 * math.pow(2, (key - 69) / 12).toDouble();
      final family = ch.program ~/ 8;
      final (wave, attack, decay, sustain, release) = switch (family) {
        0 => (3, 0.002, 0.6, 0.15, 0.2), // фортепиано
        1 => (0, 0.001, 0.5, 0.05, 0.3), // хроматическая перкуссия
        2 => (1, 0.01, 0.1, 0.8, 0.08), // орган
        3 => (2, 0.002, 0.4, 0.1, 0.15), // гитара
        4 => (3, 0.005, 0.3, 0.6, 0.1), // бас
        5 || 6 => (2, 0.08, 0.3, 0.8, 0.3), // струнные, ансамбль
        7 => (2, 0.03, 0.2, 0.8, 0.15), // медные
        8 || 9 => (1, 0.03, 0.2, 0.7, 0.15), // язычковые, флейты
        10 => (1, 0.005, 0.2, 0.7, 0.1), // солирующие синты
        11 => (2, 0.2, 0.5, 0.8, 0.6), // пэды
        _ => (0, 0.01, 0.3, 0.6, 0.2),
      };
      v
        ..wave = wave
        ..attack = attack
        ..decay = decay
        ..sustain = sustain
        ..release = release;
    }
    voices.add(v);
  }

  /// 0 — бочка, 1 — малый, 2 — хай-хэт, 3 — тарелка, 4 — том.
  static int _drumKind(int key) => switch (key) {
        35 || 36 => 0,
        37 || 38 || 39 || 40 => 1,
        42 || 44 || 46 || 54 || 69 || 70 => 2,
        49 || 51 || 52 || 53 || 55 || 57 || 59 => 3,
        41 || 43 || 45 || 47 || 48 || 50 => 4,
        _ => 2,
      };

  /// Огибающая простого синтеза в момент [age] (или [rel] после отпускания).
  static double _envSimple(_Voice v, double age, double rel) {
    if (rel >= 0) return v.releaseFrom * math.max(0, 1 - rel / v.release);
    if (age < v.attack) return age / v.attack;
    final d = (age - v.attack) / v.decay;
    return v.sustain + (1 - v.sustain) * math.exp(-3 * d);
  }

  static double _envSf2(_Voice v, _Zone z, double sustainLevel, double age, double rel) {
    if (rel >= 0) return v.releaseFrom * math.exp(-5 * rel / math.max(z.release, 0.005));
    if (age < z.attack) return age / z.attack;
    if (age < z.attack + z.hold) return 1;
    final d = (age - z.attack - z.hold) / math.max(z.decay, 0.001);
    return sustainLevel + (1 - sustainLevel) * math.exp(-5 * d);
  }

  static void _renderSimple(
      _Voice v, Float32List out, int start, int n, double chGain, double pan, double bend, math.Random rng) {
    const dt = 1 / sampleRate;
    final left = math.cos(pan * math.pi / 2), right = math.sin(pan * math.pi / 2);
    final gain = v.velGain * chGain * (v.drum ? 0.5 : 0.22);
    // Огибающая — на границах блока, внутри линейно (быстрее, чем exp на сэмпл).
    final rel0 = v.releaseAge;
    final e0 = _envSimple(v, v.age, rel0);
    final e1 = _envSimple(v, v.age + n * dt, rel0 >= 0 ? rel0 + n * dt : -1);
    if (rel0 < 0 && v.sustain == 0 && (v.age - v.attack) / v.decay > 1.5) _release(v);
    for (var i = 0; i < n; i++) {
      final env = e0 + (e1 - e0) * i / n;
      if (env <= 0) continue;
      double s;
      if (v.drum) {
        final noise = rng.nextDouble() * 2 - 1;
        switch (v.drumKind) {
          case 0 || 4: // тон с падающей частотой
            final f = v.baseFreq * (1 + 2 * math.exp(-(v.age + i * dt) * 30));
            v.phase += f * dt;
            s = math.sin(2 * math.pi * v.phase) * (v.drumKind == 0 ? 1.2 : 0.8);
          case 1:
            v.phase += v.baseFreq * dt;
            s = noise * 0.7 + math.sin(2 * math.pi * v.phase) * 0.3;
          default:
            s = noise * (v.drumKind == 3 ? 0.5 : 0.4);
        }
      } else {
        v.phase += v.baseFreq * bend * dt;
        v.phase -= v.phase.floorToDouble();
        final ph = v.phase;
        s = switch (v.wave) {
          1 => ph < 0.5 ? 0.6 : -0.6,
          2 => (2 * ph - 1) * 0.7,
          3 => 1 - 4 * (ph - 0.5).abs(),
          _ => math.sin(2 * math.pi * ph),
        };
      }
      final x = s * env * gain;
      out[(start + i) * 2] += x * left;
      out[(start + i) * 2 + 1] += x * right;
    }
    v.age += n * dt;
    if (v.releaseAge >= 0 && rel0 >= 0) v.releaseAge += n * dt;
    v.level = e1;
  }

  static void _renderSf2(_Voice v, Float32List out, int start, int n, double chGain, double chPan, double bend) {
    const dt = 1 / sampleRate;
    final z = v.zone!;
    final s = z.sample;
    final data = v.data;
    final base = v.base;
    // Последний прочитанный сэмпл — граница для конца и петли.
    final last = base + data.length - 1;
    final end = math.max(base, math.min(s.end + z.endOffset, last));
    final loopStart = math.max(base, math.min(s.loopStart + z.loopStartOffset, end)).toDouble();
    final loopEnd = math.max(base, math.min(s.loopEnd + z.loopEndOffset, end)).toDouble();
    final looping = (z.sampleModes == 1 || (z.sampleModes == 3 && v.releaseAge < 0)) && loopEnd > loopStart + 1;
    final span = loopEnd - loopStart;
    // Панорама: зона (-500..500) + канал.
    final pan = (chPan + z.pan / 1000).clamp(0.0, 1.0);
    final attenuation = math.pow(10, -z.attenuationCb * 0.4 / 200).toDouble(); // как FluidSynth
    final sustainLevel = math.pow(10, -z.sustainCb / 200).toDouble();
    final gain = v.velGain * chGain * attenuation * 0.5 / 32768;
    final gl = gain * math.cos(pan * math.pi / 2), gr = gain * math.sin(pan * math.pi / 2);
    final step = v.baseStep * bend;
    final rel0 = v.releaseAge;
    final e0 = _envSf2(v, z, sustainLevel, v.age, rel0);
    final e1 = _envSf2(v, z, sustainLevel, v.age + n * dt, rel0 >= 0 ? rel0 + n * dt : -1);
    final dEnv = (e1 - e0) / n;

    var pos = v.pos;
    var env = e0;
    var o = start * 2;
    for (var i = 0; i < n; i++) {
      final ip = pos.toInt(); // pos >= 0
      if (ip >= end) {
        _release(v);
        v.level = 0;
        v.releaseAge = 1; // сэмпл кончился — голос можно убрать
        v.pos = pos;
        return;
      }
      final a = data[ip - base];
      final x = (a + (data[ip + 1 - base] - a) * (pos - ip)) * env;
      out[o] += x * gl;
      out[o + 1] += x * gr;
      o += 2;
      env += dEnv;
      pos += step;
      if (looping && pos >= loopEnd) pos -= span;
    }
    v.pos = pos;
    v.age += n * dt;
    if (rel0 >= 0) v.releaseAge += n * dt;
    v.level = e1;
  }

  /// PCM 16 бит → WAV.
  static Uint8List wav(Int16List pcm, int rate, int channels) {
    final dataLen = pcm.length * 2;
    final b = ByteData(44 + dataLen);
    void str(int at, String s) {
      for (var i = 0; i < 4; i++) {
        b.setUint8(at + i, s.codeUnitAt(i));
      }
    }

    str(0, 'RIFF');
    b.setUint32(4, 36 + dataLen, Endian.little);
    str(8, 'WAVE');
    str(12, 'fmt ');
    b.setUint32(16, 16, Endian.little);
    b.setUint16(20, 1, Endian.little);
    b.setUint16(22, channels, Endian.little);
    b.setUint32(24, rate, Endian.little);
    b.setUint32(28, rate * channels * 2, Endian.little);
    b.setUint16(32, channels * 2, Endian.little);
    b.setUint16(34, 16, Endian.little);
    str(36, 'data');
    b.setUint32(40, dataLen, Endian.little);
    final bytes = b.buffer.asUint8List();
    bytes.setRange(44, 44 + dataLen, pcm.buffer.asUint8List(pcm.offsetInBytes, dataLen));
    return bytes;
  }
}
