import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'killable.dart';
import 'midi_synth.dart' show MidiRenderer;
import 'music.dart';

/// Библиотеки, которыми музыку играет и сама игра: libopenmpt (трекерные
/// модули MOD/XM/IT/S3M) и libgme (Game Music Emu: SPC, VGM/VGZ, NSF...).
/// В Windows-сборках SRB2/SRB2Kart они лежат рядом с exe игры; в Linux —
/// пакеты libopenmpt0 и libgme0 (в AppImage лаунчера они уже есть).
enum NativeLib { openmpt, gme }

/// Отрисованный трек: WAV и начало петли (у VGM — из файла).
typedef RenderedMusic = (Uint8List wav, Duration? loopStart);

class NativeMusic {
  NativeMusic._();

  static const rate = 44100;

  /// Самый длинный трек, который рендерим (у модулей бывает «бесконечная» длина).
  static const _maxSeconds = 20 * 60;

  /// Кадров за один вызов библиотеки.
  static const _chunk = 8192;

  static NativeLib libraryFor(MusicFormat f) => f.isTracker ? NativeLib.openmpt : NativeLib.gme;

  static List<String> _names(NativeLib lib) {
    final base = lib == NativeLib.gme ? 'gme' : 'openmpt';
    // libopenmpt-0.dll — имя в сборках MSYS2 (так её кладёт сборка лаунчера).
    if (Platform.isWindows) return ['lib$base.dll', 'lib$base-0.dll', '$base.dll'];
    if (Platform.isMacOS) return ['lib$base.dylib', 'lib$base.0.dylib'];
    return ['lib$base.so.0', 'lib$base.so'];
  }

  static String _symbol(NativeLib lib) =>
      lib == NativeLib.gme ? 'gme_open_data' : 'openmpt_module_read_interleaved_stereo';

  /// Где нашлась библиотека: полный путь или имя для системного поиска;
  /// null — нигде. Ищем рядом с лаунчером, в [dirs] (папки игр), затем в
  /// системе.
  static String? find(NativeLib lib, Iterable<String> dirs) => findLibrary(_names(lib), _symbol(lib), dirs);

  /// Библиотека с одним из имён [names], в которой есть функция [symbol]:
  /// рядом с лаунчером (и в его папке lib), в [dirs], затем в системе.
  /// Полный путь или имя для системного поиска; null — нигде.
  static String? findLibrary(List<String> names, String symbol, Iterable<String> dirs) {
    final exeDir = p.dirname(Platform.resolvedExecutable);
    final seen = <String>{};
    final candidates = [
      for (final d in [exeDir, p.join(exeDir, 'lib'), ...dirs])
        for (final n in names) p.join(d, n),
      ...names,
    ];
    for (final c in candidates) {
      if (!seen.add(c)) continue;
      if (p.isAbsolute(c) && !File(c).existsSync()) continue;
      final opened = open(c);
      if (opened != null && opened.providesSymbol(symbol)) return c;
    }
    return null;
  }

  static final Map<String, DynamicLibrary?> _opened = {};

  static DynamicLibrary? _open(String path) => open(path);

  /// Открывает библиотеку (в Windows — с зависимостями из её папки); null — не вышло.
  static DynamicLibrary? open(String path) => _opened.putIfAbsent(path, () {
        try {
          if (Platform.isWindows && p.isAbsolute(path)) _preloadWithDependencies(path);
          return DynamicLibrary.open(path);
        } catch (_) {
          return null; // нет файла, другая разрядность и т.п.
        }
      });

  /// Windows ищет зависимости DLL рядом с exe лаунчера, а не рядом с самой
  /// DLL. Загружаем её с LOAD_WITH_ALTERED_SEARCH_PATH — тогда зависимости
  /// (например, openmpt-mpg123.dll) берутся из её папки; DynamicLibrary.open
  /// потом получит уже загруженный модуль.
  static void _preloadWithDependencies(String path) {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final loadLibraryEx = kernel32.lookupFunction<IntPtr Function(Pointer<Utf16>, IntPtr, Uint32),
        int Function(Pointer<Utf16>, int, int)>('LoadLibraryExW');
    final native = path.toNativeUtf16();
    try {
      loadLibraryEx(native, 0, 0x00000008);
    } finally {
      malloc.free(native);
    }
  }

  /// В отдельном изоляте: модуль или файл приставки → WAV библиотекой
  /// [library] (из [find]). Прогресс и отмена — как у рендера MIDI.
  /// [subtrack] — дорожка многодорожечного файла (NSF, GBS...), с нуля.
  static Future<RenderedMusic> renderInBackground(
    Uint8List bytes,
    MusicFormat format,
    String library, {
    int subtrack = 0,
    void Function(double progress)? onProgress,
    bool Function()? cancelled,
  }) async {
    final result = await runKillable(
      _renderJob,
      (TransferableTypedData.fromList([bytes]), format, library, subtrack),
      onProgress: onProgress,
      cancelled: cancelled,
    );
    final (wav, loopMs) = result as (TransferableTypedData, int);
    return (wav.materialize().asUint8List(), loopMs > 0 ? Duration(milliseconds: loopMs) : null);
  }

  static void _renderJob(IsolateJob job) {
    final (data, format, library, subtrack) = job.input as (TransferableTypedData, MusicFormat, String, int);
    final bytes = data.materialize().asUint8List();
    final lib = _open(library) ?? (throw StateError('Cannot load $library'));
    final (pcm, loopMs) =
        format.isTracker ? _renderOpenmpt(lib, bytes, job.progress) : _renderGme(lib, bytes, job.progress, subtrack);
    job.done((TransferableTypedData.fromList([MidiRenderer.wav(pcm, rate, 2)]), loopMs));
  }

  /// Трекерный модуль через libopenmpt: один проход песни, петля — с начала.
  static (Int16List, int) _renderOpenmpt(DynamicLibrary lib, Uint8List bytes, void Function(double) progress) {
    final setRepeat =
        lib.lookupFunction<Int32 Function(Pointer<Void>, Int32), int Function(Pointer<Void>, int)>('openmpt_module_set_repeat_count');
    final duration =
        lib.lookupFunction<Double Function(Pointer<Void>), double Function(Pointer<Void>)>('openmpt_module_get_duration_seconds');
    final read = lib.lookupFunction<Size Function(Pointer<Void>, Int32, Size, Pointer<Int16>),
        int Function(Pointer<Void>, int, int, Pointer<Int16>)>('openmpt_module_read_interleaved_stereo');
    final destroy = lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('openmpt_module_destroy');
    // Без сообщений в консоль.
    final silent = lib.providesSymbol('openmpt_log_func_silent') ? lib.lookup<Void>('openmpt_log_func_silent') : nullptr;

    final data = malloc<Uint8>(math.max(1, bytes.length));
    final buf = malloc<Int16>(_chunk * 2);
    Pointer<Void> mod = nullptr;
    try {
      data.asTypedList(bytes.length).setAll(0, bytes);
      mod = _openmptCreate(lib, data, bytes.length, silent);
      if (mod == nullptr) throw const FormatException('libopenmpt cannot open this module');
      setRepeat(mod, 0);
      final seconds = duration(mod);
      final total = (math.min(seconds.isFinite && seconds > 0 ? seconds : _maxSeconds, _maxSeconds) * rate).ceil();
      final pcm = Int16List(total * 2);
      var done = 0;
      while (done < total) {
        final n = read(mod, rate, math.min(_chunk, total - done), buf);
        if (n <= 0) break;
        pcm.setRange(done * 2, (done + n) * 2, buf.asTypedList(n * 2));
        done += n;
        progress(done / total);
      }
      return (done < total ? Int16List.sublistView(pcm, 0, done * 2) : pcm, 0);
    } finally {
      if (mod != nullptr) destroy(mod);
      malloc.free(data);
      malloc.free(buf);
    }
  }

  /// Модуль из памяти: новая функция (libopenmpt 0.3+) или старая.
  static Pointer<Void> _openmptCreate(DynamicLibrary lib, Pointer<Uint8> data, int length, Pointer<Void> log) {
    if (lib.providesSymbol('openmpt_module_create_from_memory2')) {
      final create = lib.lookupFunction<
          Pointer<Void> Function(Pointer<Uint8>, Size, Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>,
              Pointer<Int32>, Pointer<Pointer<Utf8>>, Pointer<Void>),
          Pointer<Void> Function(Pointer<Uint8>, int, Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>,
              Pointer<Int32>, Pointer<Pointer<Utf8>>, Pointer<Void>)>('openmpt_module_create_from_memory2');
      return create(data, length, log, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr);
    }
    final create = lib.lookupFunction<Pointer<Void> Function(Pointer<Uint8>, Size, Pointer<Void>, Pointer<Void>, Pointer<Void>),
        Pointer<Void> Function(Pointer<Uint8>, int, Pointer<Void>, Pointer<Void>, Pointer<Void>)>('openmpt_module_create_from_memory');
    return create(data, length, log, nullptr, nullptr);
  }

  /// Музыка приставок через libgme, дорожка [subtrack]. Если в файле есть петля
  /// (VGM), рендерим вступление и одну петлю и возвращаем её начало (мс);
  /// иначе — длину из тегов или 2.5 минуты, петля с начала.
  static (Int16List, int) _renderGme(DynamicLibrary lib, Uint8List bytes, void Function(double) progress, int subtrack) {
    bytes = _gunzip(bytes);
    final open = lib.lookupFunction<Pointer<Utf8> Function(Pointer<Uint8>, Long, Pointer<Pointer<Void>>, Int32),
        Pointer<Utf8> Function(Pointer<Uint8>, int, Pointer<Pointer<Void>>, int)>('gme_open_data');
    final startTrack =
        lib.lookupFunction<Pointer<Utf8> Function(Pointer<Void>, Int32), Pointer<Utf8> Function(Pointer<Void>, int)>('gme_start_track');
    final play = lib.lookupFunction<Pointer<Utf8> Function(Pointer<Void>, Int32, Pointer<Int16>),
        Pointer<Utf8> Function(Pointer<Void>, int, Pointer<Int16>)>('gme_play');
    final ended = lib.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('gme_track_ended');
    final trackInfo = lib.lookupFunction<Pointer<Utf8> Function(Pointer<Void>, Pointer<Pointer<Int32>>, Int32),
        Pointer<Utf8> Function(Pointer<Void>, Pointer<Pointer<Int32>>, int)>('gme_track_info');
    final freeInfo = lib.lookupFunction<Void Function(Pointer<Int32>), void Function(Pointer<Int32>)>('gme_free_info');
    final delete = lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('gme_delete');
    final ignoreSilence = lib.providesSymbol('gme_ignore_silence')
        ? lib.lookupFunction<Void Function(Pointer<Void>, Int32), void Function(Pointer<Void>, int)>('gme_ignore_silence')
        : null;

    void check(Pointer<Utf8> error) {
      if (error != nullptr) throw FormatException('libgme: ${error.toDartString()}');
    }

    final data = malloc<Uint8>(math.max(1, bytes.length));
    final out = malloc<Pointer<Void>>();
    final info = malloc<Pointer<Int32>>();
    final buf = malloc<Int16>(_chunk * 2);
    out.value = nullptr;
    try {
      data.asTypedList(bytes.length).setAll(0, bytes);
      check(open(data, bytes.length, out, rate));
      final emu = out.value;
      // gme_info_t начинается с length, intro_length, loop_length (мс, -1 — нет).
      var lengthMs = 150000, loopMs = 0;
      if (trackInfo(emu, info, subtrack) == nullptr) {
        final i = info.value;
        final length = i[0], intro = i[1], loopLength = i[2];
        if (intro >= 0 && loopLength > 0) {
          lengthMs = intro + loopLength;
          loopMs = intro;
        } else if (length > 0) {
          lengthMs = length;
        }
        freeInfo(i);
      }
      ignoreSilence?.call(emu, 1);
      check(startTrack(emu, subtrack));
      final total = math.min(lengthMs, _maxSeconds * 1000) * rate ~/ 1000;
      final pcm = Int16List(total * 2);
      var done = 0;
      while (done < total && ended(emu) == 0) {
        final n = math.min(_chunk, total - done);
        check(play(emu, n * 2, buf));
        pcm.setRange(done * 2, (done + n) * 2, buf.asTypedList(n * 2));
        done += n;
        progress(done / total);
      }
      return (done < total ? Int16List.sublistView(pcm, 0, done * 2) : pcm, loopMs);
    } finally {
      if (out.value != nullptr) delete(out.value);
      malloc.free(data);
      malloc.free(out);
      malloc.free(info);
      malloc.free(buf);
    }
  }

  /// VGZ — сжатый gzip VGM; игра тоже сама распаковывает его перед libgme.
  static Uint8List _gunzip(Uint8List b) =>
      b.length > 2 && b[0] == 0x1F && b[1] == 0x8B ? Uint8List.fromList(gzip.decode(b)) : b;

  /// Длительность и теги модуля (libopenmpt) или файла приставки (libgme):
  /// название, автор, игра, число дорожек. [library] — из [find].
  static TrackDetails details(String library, Uint8List bytes, MusicFormat format) {
    final lib = _open(library);
    if (lib == null) return const TrackDetails();
    return format.isTracker ? _openmptDetails(lib, bytes) : _gmeDetails(lib, _gunzip(bytes));
  }

  static TrackDetails _openmptDetails(DynamicLibrary lib, Uint8List bytes) {
    final duration =
        lib.lookupFunction<Double Function(Pointer<Void>), double Function(Pointer<Void>)>('openmpt_module_get_duration_seconds');
    final metadata = lib.lookupFunction<Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>),
        Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)>('openmpt_module_get_metadata');
    final freeString = lib.lookupFunction<Void Function(Pointer<Utf8>), void Function(Pointer<Utf8>)>('openmpt_free_string');
    final destroy = lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('openmpt_module_destroy');
    final silent = lib.providesSymbol('openmpt_log_func_silent') ? lib.lookup<Void>('openmpt_log_func_silent') : nullptr;
    final data = malloc<Uint8>(math.max(1, bytes.length));
    Pointer<Void> mod = nullptr;
    String meta(String key) {
      final k = key.toNativeUtf8();
      try {
        final v = metadata(mod, k);
        if (v == nullptr) return '';
        try {
          return v.toDartString().trim();
        } finally {
          freeString(v);
        }
      } finally {
        malloc.free(k);
      }
    }

    try {
      data.asTypedList(bytes.length).setAll(0, bytes);
      mod = _openmptCreate(lib, data, bytes.length, silent);
      if (mod == nullptr) return const TrackDetails();
      final seconds = duration(mod);
      return TrackDetails(
        durationMs: seconds.isFinite && seconds > 0 ? (seconds * 1000).round() : null,
        title: meta('title'),
        author: meta('artist'),
      );
    } catch (_) {
      return const TrackDetails();
    } finally {
      if (mod != nullptr) destroy(mod);
      malloc.free(data);
    }
  }

  static TrackDetails _gmeDetails(DynamicLibrary lib, Uint8List bytes) {
    final open = lib.lookupFunction<Pointer<Utf8> Function(Pointer<Uint8>, Long, Pointer<Pointer<Void>>, Int32),
        Pointer<Utf8> Function(Pointer<Uint8>, int, Pointer<Pointer<Void>>, int)>('gme_open_data');
    final trackCount = lib.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('gme_track_count');
    final trackInfo = lib.lookupFunction<Pointer<Utf8> Function(Pointer<Void>, Pointer<Pointer<Int32>>, Int32),
        Pointer<Utf8> Function(Pointer<Void>, Pointer<Pointer<Int32>>, int)>('gme_track_info');
    final freeInfo = lib.lookupFunction<Void Function(Pointer<Int32>), void Function(Pointer<Int32>)>('gme_free_info');
    final delete = lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('gme_delete');
    final data = malloc<Uint8>(math.max(1, bytes.length));
    final out = malloc<Pointer<Void>>();
    final info = malloc<Pointer<Int32>>();
    out.value = nullptr;
    try {
      data.asTypedList(bytes.length).setAll(0, bytes);
      if (open(data, bytes.length, out, rate) != nullptr) return const TrackDetails();
      final emu = out.value;
      final count = trackCount(emu);
      if (trackInfo(emu, info, 0) != nullptr) return TrackDetails(subtracks: math.max(1, count));
      final i = info.value;
      try {
        // gme_info_t: 16 int (длины и резерв), затем строки system, game, song, author.
        final length = i[0], intro = i[1], loopLength = i[2];
        final strings = Pointer<Pointer<Utf8>>.fromAddress(i.address + 16 * sizeOf<Int32>());
        String str(int n) {
          final v = strings[n];
          return v == nullptr ? '' : v.toDartString().trim();
        }

        return TrackDetails(
          durationMs: length > 0 ? length : (intro >= 0 && loopLength > 0 ? intro + loopLength : null),
          game: str(1),
          title: str(2),
          author: str(3),
          subtracks: math.max(1, count),
        );
      } finally {
        freeInfo(i);
      }
    } catch (_) {
      return const TrackDetails();
    } finally {
      if (out.value != nullptr) delete(out.value);
      malloc.free(data);
      malloc.free(out);
      malloc.free(info);
    }
  }
}
