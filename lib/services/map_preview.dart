import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../models/srb2_server.dart';

/// Запись архива аддона: lump в WAD или файл в PK3 (zip).
class ArchiveEntry {
  /// Полный путь внутри PK3 ("Maps/MAP01.wad"); у WAD — имя lump.
  final String path;

  /// Имя lump, как его видит игра: имя файла без расширения, в верхнем регистре.
  final String name;
  final int offset;
  final int size;
  final int compressedSize;

  /// 0 — без сжатия, 8 — deflate (PK3), [lzfWad] — lump сжатого WAD (ZWAD).
  final int method;

  /// Lump из ZWAD (SRB2 2.1 / 2.0): первые 4 байта — размер после распаковки
  /// (0 — не сжат), дальше данные, сжатые LZF.
  static const lzfWad = 100;

  /// CRC-32 содержимого из каталога zip (PK3); 0 — неизвестен (WAD).
  final int crc;

  const ArchiveEntry(this.path, this.name, this.offset, this.size, {int? compressedSize, this.method = 0, this.crc = 0})
      : compressedSize = compressedSize ?? size;

  /// Путь в PK3 в нижнем регистре — для проверки папок с подпапками.
  String get lowerPath => path.toLowerCase();

  /// Папка в PK3 в нижнем регистре ("maps/"), у WAD — ''.
  String get folder {
    final i = path.lastIndexOf('/');
    return i < 0 ? '' : path.substring(0, i + 1).toLowerCase();
  }
}

/// WAD или PK3, открытый для чтения отдельных записей (без распаковки целиком).
class AddonArchive {
  final RandomAccessFile _file;
  final Uint8List? _bytes; // вложенный WAD из PK3 — уже в памяти
  final List<ArchiveEntry> entries;
  final bool isZip;

  /// Путь файла ('' — вложенный WAD из PK3, тогда путь PK3).
  final String path;

  AddonArchive._(this._file, this._bytes, this.entries, this.isZip, [this.path = '']);

  /// null — не WAD и не PK3 (или файл повреждён).
  static AddonArchive? open(String path) {
    RandomAccessFile? f;
    try {
      f = File(path).openSync();
      final head = f.readSync(4);
      if (head.length == 4 && _isWadMagic(head)) {
        return AddonArchive._(f, null, _readWadDirectory(f, null), false, path);
      }
      if (head.length == 4 && head[0] == 0x50 && head[1] == 0x4B) {
        final entries = _readZipDirectory(f);
        if (entries != null) return AddonArchive._(f, null, entries, true, path);
      }
      f.closeSync();
    } catch (_) {
      try {
        f?.closeSync();
      } catch (_) {}
    }
    return null;
  }

  /// WAD, уже прочитанный в память (карта Maps/*.wad из PK3).
  static AddonArchive? fromWadBytes(Uint8List bytes, RandomAccessFile parent, [String path = '']) {
    if (bytes.length < 12 || !_isWadMagic(bytes)) return null;
    try {
      return AddonArchive._(parent, bytes, _readWadDirectory(null, bytes), false, path);
    } catch (_) {
      return null;
    }
  }

  static bool _isWadMagic(List<int> b) => _isPlainWad(b) || _isZwad(b) || _isSdll(b);

  static bool _isPlainWad(List<int> b) =>
      (b[0] == 0x50 || b[0] == 0x49) && b[1] == 0x57 && b[2] == 0x41 && b[3] == 0x44; // PWAD / IWAD

  /// ZWAD — WAD со сжатыми (LZF) lump'ами; его читает SRB2 2.1 (W_InitFile).
  static bool _isZwad(List<int> b) => b[0] == 0x5A && b[1] == 0x57 && b[2] == 0x41 && b[3] == 0x44;

  /// SDLL — тот же WAD (W_InitFile в 2.1 принимает и его).
  static bool _isSdll(List<int> b) => b[0] == 0x53 && b[1] == 0x44 && b[2] == 0x4C && b[3] == 0x4C;

  /// Распаковка LZF (liblzf, lzf_decompress) до [outLength] байт.
  static Uint8List lzfDecompress(Uint8List input, int outLength) {
    final out = Uint8List(outLength);
    var ip = 0, op = 0;
    while (ip < input.length) {
      var ctrl = input[ip++];
      if (ctrl < 32) {
        ctrl++; // literal run
        if (op + ctrl > outLength || ip + ctrl > input.length) throw const FormatException('Bad LZF data');
        out.setRange(op, op + ctrl, input, ip);
        op += ctrl;
        ip += ctrl;
      } else {
        var len = ctrl >> 5;
        var ref = op - ((ctrl & 0x1F) << 8) - 1;
        if (len == 7) {
          if (ip >= input.length) throw const FormatException('Bad LZF data');
          len += input[ip++];
        }
        if (ip >= input.length) throw const FormatException('Bad LZF data');
        ref -= input[ip++];
        len += 2;
        if (op + len > outLength || ref < 0) throw const FormatException('Bad LZF data');
        for (var i = 0; i < len; i++) {
          out[op++] = out[ref++]; // копии могут перекрываться — по байту
        }
      }
    }
    return op == outLength ? out : Uint8List.sublistView(out, 0, op);
  }

  /// Данные lump'а ZWAD из [raw] (как он лежит в файле).
  static Uint8List _unpackZwadLump(Uint8List raw) {
    if (raw.length < 4) return Uint8List(0);
    final realSize = ByteData.sublistView(raw, 0, 4).getUint32(0, Endian.little);
    final data = Uint8List.sublistView(raw, 4);
    return realSize == 0 ? data : lzfDecompress(data, realSize);
  }

  static List<ArchiveEntry> _readWadDirectory(RandomAccessFile? f, Uint8List? bytes) {
    Uint8List read(int offset, int length) {
      if (bytes != null) {
        if (offset < 0 || offset + length > bytes.length) throw const FormatException('WAD out of range');
        return Uint8List.sublistView(bytes, offset, offset + length);
      }
      f!.setPositionSync(offset);
      final r = f.readSync(length);
      if (r.length != length) throw const FormatException('WAD out of range');
      return r;
    }

    final magic = read(0, 4);
    final zwad = _isZwad(magic);
    final head = ByteData.sublistView(read(0, 12));
    final count = head.getInt32(4, Endian.little);
    final dir = head.getInt32(8, Endian.little);
    if (count < 0 || count > 200000) throw const FormatException('Bad WAD');
    final table = read(dir, count * 16);
    final bd = ByteData.sublistView(table);
    return [
      for (var i = 0; i < count; i++)
        () {
          final o = i * 16;
          var end = o + 8;
          while (end < o + 16 && table[end] != 0) {
            end++;
          }
          final name = latin1.decode(table.sublist(o + 8, end), allowInvalid: true).toUpperCase();
          final size = bd.getInt32(o + 4, Endian.little);
          return zwad
              ? ArchiveEntry(name, name, bd.getInt32(o, Endian.little), size, method: ArchiveEntry.lzfWad)
              : ArchiveEntry(name, name, bd.getInt32(o, Endian.little), size);
        }(),
    ];
  }

  /// Центральный каталог zip (без zip64: pk3 меньше 4 ГБ).
  static List<ArchiveEntry>? _readZipDirectory(RandomAccessFile f) {
    final length = f.lengthSync();
    final tail = length < 65557 ? length : 65557;
    f.setPositionSync(length - tail);
    final buf = f.readSync(tail);
    var eocd = -1;
    for (var i = buf.length - 22; i >= 0; i--) {
      if (buf[i] == 0x50 && buf[i + 1] == 0x4B && buf[i + 2] == 0x05 && buf[i + 3] == 0x06) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) return null;
    final e = ByteData.sublistView(buf, eocd);
    final count = e.getUint16(10, Endian.little);
    final cdSize = e.getUint32(12, Endian.little);
    final cdOffset = e.getUint32(16, Endian.little);
    f.setPositionSync(cdOffset);
    final cd = f.readSync(cdSize);
    final bd = ByteData.sublistView(cd);
    final entries = <ArchiveEntry>[];
    var p = 0;
    for (var i = 0; i < count && p + 46 <= cd.length; i++) {
      if (bd.getUint32(p, Endian.little) != 0x02014b50) break;
      final method = bd.getUint16(p + 10, Endian.little);
      final crc = bd.getUint32(p + 16, Endian.little);
      final compressed = bd.getUint32(p + 20, Endian.little);
      final size = bd.getUint32(p + 24, Endian.little);
      final nameLen = bd.getUint16(p + 28, Endian.little);
      final extraLen = bd.getUint16(p + 30, Endian.little);
      final commentLen = bd.getUint16(p + 32, Endian.little);
      final local = bd.getUint32(p + 42, Endian.little);
      final path = utf8.decode(cd.sublist(p + 46, p + 46 + nameLen), allowMalformed: true);
      p += 46 + nameLen + extraLen + commentLen;
      if (path.endsWith('/')) continue; // папка
      entries.add(ArchiveEntry(path, lumpName(path), local, size, compressedSize: compressed, method: method, crc: crc));
    }
    return entries;
  }

  /// Имя lump для файла PK3: имя без папки и расширения, до 8 символов
  /// (как W_InitFile в SRB2), в верхнем регистре.
  static String lumpName(String path) {
    var name = path.substring(path.lastIndexOf('/') + 1);
    final dot = name.indexOf('.');
    if (dot > 0) name = name.substring(0, dot);
    if (name.length > 8) name = name.substring(0, 8);
    return name.toUpperCase();
  }

  /// Длинное имя карты из PK3 (Maps/RR_TESTRUN.wad → RR_TESTRUN): Ring Racers
  /// ищет карты в maps/ по полному имени, а не по 8 символам.
  static String fullName(String path) {
    var name = path.substring(path.lastIndexOf('/') + 1);
    final dot = name.lastIndexOf('.');
    if (dot > 0) name = name.substring(0, dot);
    return name.toUpperCase();
  }

  Uint8List read(ArchiveEntry e) {
    final bytes = _bytes;
    if (bytes != null) {
      if (e.offset < 0 || e.offset + e.size > bytes.length) throw const FormatException('Lump out of range');
      final raw = Uint8List.sublistView(bytes, e.offset, e.offset + e.size);
      return e.method == ArchiveEntry.lzfWad ? _unpackZwadLump(raw) : raw;
    }
    if (!isZip) {
      _file.setPositionSync(e.offset);
      final raw = _file.readSync(e.size);
      return e.method == ArchiveEntry.lzfWad ? _unpackZwadLump(raw) : raw;
    }
    // Локальный заголовок: 30 байт + имя + extra, потом данные.
    _file.setPositionSync(e.offset);
    final h = _file.readSync(30);
    final hd = ByteData.sublistView(h);
    if (h.length < 30 || hd.getUint32(0, Endian.little) != 0x04034b50) {
      throw const FormatException('Bad zip entry');
    }
    _file.setPositionSync(e.offset + 30 + hd.getUint16(26, Endian.little) + hd.getUint16(28, Endian.little));
    final raw = _file.readSync(e.compressedSize);
    return switch (e.method) {
      0 => raw,
      8 => Uint8List.fromList(ZLibCodec(raw: true).decode(raw)),
      _ => throw const FormatException('Unsupported compression'),
    };
  }

  /// Первые [max] байт записи (для определения формата) — без чтения всей
  /// записи; сжатую запись распаковываем только до нужной длины.
  Uint8List readHead(ArchiveEntry e, int max) {
    if (e.method == ArchiveEntry.lzfWad) {
      final all = read(e);
      return all.length <= max ? all : Uint8List.sublistView(all, 0, max);
    }
    final bytes = _bytes;
    if (bytes != null) {
      final n = e.size < max ? e.size : max;
      if (e.offset < 0 || e.offset + n > bytes.length) throw const FormatException('Lump out of range');
      return Uint8List.sublistView(bytes, e.offset, e.offset + n);
    }
    if (!isZip) {
      _file.setPositionSync(e.offset);
      return _file.readSync(e.size < max ? e.size : max);
    }
    _file.setPositionSync(e.offset);
    final h = _file.readSync(30);
    final hd = ByteData.sublistView(h);
    if (h.length < 30 || hd.getUint32(0, Endian.little) != 0x04034b50) {
      throw const FormatException('Bad zip entry');
    }
    _file.setPositionSync(e.offset + 30 + hd.getUint16(26, Endian.little) + hd.getUint16(28, Endian.little));
    if (e.method == 0) return _file.readSync(e.size < max ? e.size : max);
    if (e.method != 8) throw const FormatException('Unsupported compression');
    // Сжатых данных берём с запасом: deflate редко сжимает больше чем в 16 раз.
    final want = max * 16 + 1024;
    final raw = _file.readSync(e.compressedSize < want ? e.compressedSize : want);
    List<int> head;
    if (raw.length >= e.compressedSize) {
      head = ZLibCodec(raw: true).decode(raw);
    } else {
      // Начало потока: распаковываем, сколько получится из прочитанного.
      final filter = RawZLibFilter.inflateFilter(raw: true);
      filter.process(raw, 0, raw.length);
      final out = BytesBuilder(copy: false);
      while (out.length < max) {
        final chunk = filter.processed();
        if (chunk == null || chunk.isEmpty) break;
        out.add(chunk);
      }
      head = out.takeBytes();
    }
    return Uint8List.fromList(head.length <= max ? head : head.sublist(0, max));
  }

  /// Первая запись с именем lump [name] (последняя побеждает в игре — как и тут).
  ArchiveEntry? find(String name) {
    ArchiveEntry? found;
    for (final e in entries) {
      if (e.name == name) found = e;
    }
    return found;
  }

  /// Первая запись с именем [name] — так ищет игра (W_CheckNumForNamePwad
  /// идёт по файлу с начала; среди файлов — последний загруженный).
  ArchiveEntry? findFirst(String name) {
    for (final e in entries) {
      if (e.name == name) return e;
    }
    return null;
  }

  void close() {
    if (_bytes != null) return; // файл принадлежит родительскому архиву
    try {
      _file.closeSync();
    } catch (_) {}
  }
}

/// Уровень, найденный в аддоне.
class MapPreview {
  /// Имя карты ("MAP01", "MAPA1", "RR_TESTRUN") — для -warp.
  final String map;

  /// Название из заголовка уровня (SOC): "Greenflower Zone 1"; '' — нет.
  final String title;

  /// Картинка уровня (PNG или BMP); null — нет или не удалось прочитать.
  final Uint8List? image;

  /// Скрыт из меню выбора уровней (`Hidden = true` в SOC).
  final bool hidden;

  /// Титульная карта (`TitleMap` в MAINCFG) — фон главного меню, не уровень.
  final bool isTitleMap;

  /// Режимы из `TypeOfLevel` ("Singleplayer", "Co-op", "Race"...); пусто — не указаны.
  final List<String> types;

  const MapPreview(this.map, this.title, this.image,
      {this.hidden = false, this.isTitleMap = false, this.types = const []});
}

/// Что известно из SOC: названия уровней, скрытые уровни, титульная карта.
class SocInfo {
  final Map<String, String> titles = {};
  final Map<String, bool> hidden = {};
  final Map<String, List<String>> types = {};

  /// Музыка уровня (`Music = GFZ1`; у Ring Racers бывает несколько через
  /// запятую): имена без O_/D_, в верхнем регистре. `Music = NONE` — пустой
  /// список (тишина); уровня нет в списке — музыка по умолчанию (MAPxxM).
  final Map<String, List<String>> music = {};

  /// Ring Racers: музыка уровня в режиме Encore (`EncoreMusic = ...`).
  final Map<String, List<String>> encoreMusic = {};
  String? titleMap;

  /// В SOC есть `Clear Levels` / `Clear All`: заголовки уровней, загруженные
  /// до него, сбрасываются, а карты из более ранних файлов не показываем.
  bool clearLevels = false;

  void clear() {
    titles.clear();
    hidden.clear();
    types.clear();
    music.clear();
    encoreMusic.clear();
    clearLevels = true;
  }

  void addAll(SocInfo other) {
    if (other.clearLevels) clear();
    titles.addAll(other.titles);
    hidden.addAll(other.hidden);
    types.addAll(other.types);
    music.addAll(other.music);
    encoreMusic.addAll(other.encoreMusic);
    if (other.titleMap != null) titleMap = other.titleMap;
  }
}

/// Палитра для картинок файла. Обычно — последняя загруженная PLAYPAL. У
/// BlanKart (в файлах игры есть лампа PALREMAP) файлы «режима совместимости»
/// (srb2.srb и *.kart игры, у аддонов — WAD *.kart и файлы на «K») нарисованы
/// в старой палитре SRB2Kart: игра переводит их цвета таблицей PALREMAP в
/// цвета своей палитры (w_wad.c MakePatch → R_DoPaletteRemapPatch), так же и
/// здесь. Без PALREMAP (SRB2, SRB2Kart, Ring Racers) — одна палитра на всё.
class PaletteResolver {
  /// Где искать: открытые файлы (последний важнее), затем [files] по порядку.
  final List<AddonArchive> archives;
  final List<String> files;
  PaletteResolver(this.archives, this.files);

  bool _searched = false;
  Uint8List? _master;
  bool _masterCompat = false;
  Uint8List? _palRemap, _invRemap;
  final Map<bool, Uint8List?> _byCompat = {};

  /// Первая (по правилам игры) лампа [name] не короче [min] байт и откуда.
  (Uint8List, String)? _lump(String name, int min) {
    for (final a in archives.reversed) {
      final e = a.findFirst(name);
      if (e == null) continue;
      try {
        final d = a.read(e);
        if (d.length >= min) return (Uint8List.fromList(d.sublist(0, min)), a.path);
      } catch (_) {}
    }
    for (final path in files) {
      final x = AddonArchive.open(path);
      if (x == null) continue;
      try {
        final e = x.findFirst(name);
        if (e == null) continue;
        final d = x.read(e);
        if (d.length >= min) return (Uint8List.fromList(d.sublist(0, min)), path);
      } catch (_) {
        // следующий файл
      } finally {
        x.close();
      }
    }
    return null;
  }

  void _search() {
    if (_searched) return;
    _searched = true;
    final master = _lump('PLAYPAL', 768);
    _master = master?.$1;
    _palRemap = _lump('PALREMAP', 256)?.$1;
    if (_palRemap != null) {
      _invRemap = _lump('INVREMAP', 256)?.$1;
      if (master != null) _masterCompat = isCompatFile(master.$2);
    }
  }

  /// Файл режима совместимости BlanKart (d_main: основные файлы; w_wad.c:
  /// CheckCompatFilename / CheckCompatExtension для остальных).
  static bool isCompatFile(String path) {
    final name = path.replaceAll('\\', '/').split('/').last.toLowerCase();
    if (name.isEmpty) return false;
    if (name.endsWith('.kart') || name == 'srb2.srb') return true;
    if (name.endsWith('.pk3') && !name.startsWith('k')) return false;
    return name.startsWith('k');
  }

  /// Основная палитра (последняя PLAYPAL).
  Uint8List? get master {
    _search();
    return _master;
  }

  /// Палитра для картинок из файла [path].
  Uint8List? forFile(String path) {
    _search();
    final m = _master;
    if (m == null || _palRemap == null || path.isEmpty) return m;
    final compat = isCompatFile(path);
    if (compat == _masterCompat) return m;
    return _byCompat.putIfAbsent(compat, () {
      final table = compat ? _palRemap : _invRemap;
      if (table == null) return m;
      final out = Uint8List(768);
      for (var i = 0; i < 256; i++) {
        final j = table[i];
        out[i * 3] = m[j * 3];
        out[i * 3 + 1] = m[j * 3 + 1];
        out[i * 3 + 2] = m[j * 3 + 2];
      }
      return out;
    });
  }
}

/// Поиск уровней и их картинок в WAD/PK3.
///
/// - SRB2, SRB2Kart: карта — lump MAPxx (MAP01–MAP99, MAPA0–MAPZZ), картинка —
///   lump MAPxxP (160×100), PNG или Doom-патч.
/// - Ring Racers: имя карты любое (Maps/RR_TESTRUN.wad), картинка — lump
///   PICTURE внутри самой карты.
/// - Название — из SOC (lumps MAINCFG, SOC_*, папка SOC/ в PK3):
///   `Level 1` / `Level A1` / `Level RR_TESTRUN`, `Levelname = ...`, `Act = ...`.
///
/// Doom-патчи раскрашиваются палитрой PLAYPAL: из самого аддона или из
/// файлов игры [paletteFiles] (srb2.pk3 и т.п.).
class MapScanner {
  MapScanner._();

  /// То же в отдельном изоляте, чтобы не тормозить интерфейс.
  static Future<List<MapPreview>> scanInBackground(String path, List<String> paletteFiles) =>
      Isolate.run(() => scan(path, paletteFiles));

  static List<MapPreview> scan(String path, List<String> paletteFiles) {
    final archive = AddonArchive.open(path);
    if (archive == null) return const [];
    try {
      final maps = _findMaps(archive); // имя → вложенная карта (PK3) или маркер (WAD)
      if (maps.isEmpty) return const [];
      final soc = _readSoc(archive);
      final titles = soc.titles;
      final palettes = PaletteResolver([archive], paletteFiles);
      Uint8List? paletteOnce() => palettes.forFile(path);

      final result = <MapPreview>[];
      for (final entry in maps.entries) {
        final name = entry.key;
        Uint8List? image;
        try {
          final lump = archive.find('${name}P') ?? _pictureInsideMap(archive, entry.value);
          if (lump != null) {
            final bytes = lump is _MemoryEntry ? lump.bytes : archive.read(lump);
            image = imageFromLump(bytes, paletteOnce);
          }
        } catch (_) {
          image = null; // битая картинка — покажем заглушку
        }
        result.add(MapPreview(name, titles[name] ?? '', image,
            hidden: soc.hidden[name] ?? false, isTitleMap: name == soc.titleMap, types: soc.types[name] ?? const []));
      }
      result.sort((a, b) => mapOrder(a.map).compareTo(mapOrder(b.map)));
      return result;
    } finally {
      archive.close();
    }
  }

  /// Все карты из нескольких файлов в порядке загрузки (файлы игры, потом
  /// очередь): позже загруженный файл заменяет карту, её название и картинку,
  /// как в игре. [pictureInsideMaps] — искать PICTURE внутри карт (Ring Racers;
  /// для SRB2 не нужно и дорого: пришлось бы распаковывать каждую карту).
  static Future<List<MapPreview>> scanAllInBackground(List<String> files, List<String> paletteFiles,
          {bool pictureInsideMaps = false}) =>
      Isolate.run(() => scanAll(files, paletteFiles, pictureInsideMaps: pictureInsideMaps));

  static List<MapPreview> scanAll(List<String> files, List<String> paletteFiles, {bool pictureInsideMaps = false}) {
    final archives = <AddonArchive>[
      for (final f in files)
        if (AddonArchive.open(f) case final a?) a,
    ];
    try {
      final mapSource = <String, (AddonArchive, ArchiveEntry)>{};
      final pictures = <String, (AddonArchive, ArchiveEntry)>{};
      final soc = SocInfo();
      for (final a in archives) {
        final fileSoc = _readSoc(a);
        // Clear Levels: карты из файлов, загруженных раньше, не показываем.
        if (fileSoc.clearLevels) mapSource.clear();
        _findMaps(a).forEach((name, e) => mapSource[name] = (a, e));
        soc.addAll(fileSoc);
        for (final e in a.entries) {
          if (e.name.length > 1 && e.name.endsWith('P')) {
            pictures[e.name.substring(0, e.name.length - 1)] = (a, e);
          }
        }
      }

      final palettes = PaletteResolver(archives, paletteFiles);

      final result = <MapPreview>[];
      mapSource.forEach((name, src) {
        Uint8List? image;
        try {
          final pic = pictures[name];
          ArchiveEntry? lump = pic?.$2;
          var from = pic?.$1;
          if (lump == null && pictureInsideMaps) {
            lump = _pictureInsideMap(src.$1, src.$2);
            from = src.$1;
          }
          if (lump != null && from != null) {
            final bytes = lump is _MemoryEntry ? lump.bytes : from.read(lump);
            final file = from.path;
            image = imageFromLump(bytes, () => palettes.forFile(file));
          }
        } catch (_) {
          image = null;
        }
        result.add(MapPreview(name, soc.titles[name] ?? '', image,
            hidden: soc.hidden[name] ?? false, isTitleMap: name == soc.titleMap, types: soc.types[name] ?? const []));
      });
      result.sort((a, b) => mapOrder(a.map).compareTo(mapOrder(b.map)));
      return result;
    } finally {
      for (final a in archives) {
        a.close();
      }
    }
  }

  /// Картинка карты сервера: ищется в [files] с конца (аддон, загруженный
  /// позже, заменяет карту — как в игре). [map] — имя карты (SRB2, SRB2Kart);
  /// Ring Racers имени не присылает, тогда карта ищется по названию [title]
  /// из SOC. null — не нашлась.
  static Future<Uint8List?> findPictureInBackground({
    required List<String> files,
    required String map,
    required String title,
    required List<String> paletteFiles,
  }) =>
      Isolate.run(() => findPicture(files: files, map: map, title: title, paletteFiles: paletteFiles));

  static Uint8List? findPicture({
    required List<String> files,
    required String map,
    required String title,
    required List<String> paletteFiles,
  }) {
    final wantMap = map.trim().toUpperCase();
    final wantTitle = _normTitle(title);
    for (final path in files.reversed) {
      final archive = AddonArchive.open(path);
      if (archive == null) continue;
      try {
        final maps = _findMaps(archive);
        var name = wantMap;
        if (name.isEmpty && wantTitle.isNotEmpty) {
          // Точное совпадение, иначе — название сервера начинается с
          // названия уровня (сервер дописывает название зоны).
          var prefix = '';
          for (final t in _readSoc(archive).titles.entries) {
            final n = _normTitle(t.value);
            if (n == wantTitle) name = t.key;
            if (n.isNotEmpty && wantTitle.startsWith('$n ')) prefix = t.key;
          }
          if (name.isEmpty) name = prefix;
        }
        if (name.isEmpty) continue;
        var lump = archive.find('${name}P');
        final mapEntry = maps[name];
        if (lump == null && mapEntry != null) lump = _pictureInsideMap(archive, mapEntry);
        if (lump == null) continue;
        final bytes = lump is _MemoryEntry ? lump.bytes : archive.read(lump);
        final image = imageFromLump(bytes, () => PaletteResolver([archive], paletteFiles).forFile(path));
        if (image != null) return image;
      } catch (_) {
        // битый файл — ищем дальше
      } finally {
        archive.close();
      }
    }
    return null;
  }

  /// Без цветовых кодов SRB2 (`^4`, `\82`, \x80–\x8F): сервер присылает
  /// название без них.
  static String _normTitle(String s) =>
      Srb2Text.plain(Srb2Text.parse(Srb2Text.decodeSoc(s))).toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  /// Порядок карт: MAP01…MAP99, MAPA0…MAPZZ, затем остальные по имени.
  static String mapOrder(String map) {
    final n = mapNumber(map);
    return n > 0 ? 'A${n.toString().padLeft(4, '0')}' : 'B$map';
  }

  /// Номер карты как в игре (M_MapNumber): MAP01 → 1, MAPA0 → 100, MAPZZ → 1035; 0 — не номер.
  static int mapNumber(String map) {
    if (map.length != 5 || !map.startsWith('MAP')) return 0;
    final a = map.codeUnitAt(3), b = map.codeUnitAt(4);
    bool digit(int c) => c >= 0x30 && c <= 0x39;
    bool letter(int c) => c >= 0x41 && c <= 0x5A;
    if (digit(a)) return digit(b) ? (a - 0x30) * 10 + (b - 0x30) : 0;
    if (!letter(a) || !(digit(b) || letter(b))) return 0;
    return 100 + (a - 0x41) * 36 + (digit(b) ? b - 0x30 : b - 0x41 + 10);
  }

  /// Имя карты по номеру (G_BuildMapName).
  static String mapName(int number) {
    if (number < 100) return 'MAP${number.toString().padLeft(2, '0')}';
    final n = number - 100;
    final second = n % 36 < 10 ? String.fromCharCode(0x30 + n % 36) : String.fromCharCode(0x41 + n % 36 - 10);
    return 'MAP${String.fromCharCode(0x41 + n ~/ 36)}$second';
  }

  static const _mapLumps = {'THINGS', 'TEXTMAP'};

  /// В PK3 карта бывает не WAD-файлом, а набором lumps в папке: маркер
  /// (MAPA0) и сразу за ним THINGS или TEXTMAP в той же папке — игра читает
  /// их подряд до следующей карты (vres_GetMap).
  static bool _isFolderMap(AddonArchive a, int i) {
    if (i + 1 >= a.entries.length) return false;
    final e = a.entries[i], next = a.entries[i + 1];
    return !_mapLumps.contains(e.name) && next.folder == e.folder && _mapLumps.contains(next.name);
  }

  /// Имя, которое игра может найти как карту: буквы, цифры, '_' и '-'.
  /// "MAPTO (1).wad" (копия файла) игра не загрузит: её lump — "MAPTO (1".
  static final _validMapName = RegExp(r'^[A-Z0-9_-]+$');

  /// Карты: в WAD — маркер, за которым идёт THINGS/TEXTMAP; в PK3 — файлы в maps/.
  static Map<String, ArchiveEntry> _findMaps(AddonArchive a) {
    final maps = <String, ArchiveEntry>{};
    if (a.isZip) {
      for (var i = 0; i < a.entries.length; i++) {
        final e = a.entries[i];
        // Как W_CheckNumForMap: всё в maps/ (и в подпапках).
        if (!e.lowerPath.startsWith('maps/')) continue;
        final name = AddonArchive.fullName(e.path);
        if (!_validMapName.hasMatch(name)) continue;
        if (e.lowerPath.endsWith('.wad')) {
          maps[name] = e; // карта — вложенный WAD
        } else if (_isFolderMap(a, i)) {
          maps[name] = e; // карта «папкой»: маркер, за ним THINGS/TEXTMAP... (как в WAD)
        }
      }
      return maps;
    }
    for (var i = 0; i + 1 < a.entries.length; i++) {
      if (!_validMapName.hasMatch(a.entries[i].name)) continue;
      if (_mapLumps.contains(a.entries[i + 1].name) && !_mapLumps.contains(a.entries[i].name)) {
        maps[a.entries[i].name] = a.entries[i];
      }
    }
    return maps;
  }

  /// Названия уровней из SOC архива: имя карты → "Levelname Act".
  static Map<String, String> levelTitles(AddonArchive a) => _readSoc(a).titles;

  /// Заголовки уровней из всех SOC архива (названия, музыка, режимы...).
  static SocInfo readSocInfo(AddonArchive a) => _readSoc(a);

  /// Имена карт в архиве (как их найдёт игра).
  static List<String> mapNames(AddonArchive a) => _findMaps(a).keys.toList();

  /// Ring Racers: lump PICTURE внутри карты (вложенный WAD из PK3 или
  /// lumps после маркера в WAD).
  static ArchiveEntry? _pictureInsideMap(AddonArchive a, ArchiveEntry map) {
    if (a.isZip && !map.lowerPath.endsWith('.wad')) {
      // Карта «папкой»: PICTURE — среди её lumps, до следующей карты.
      final start = a.entries.indexOf(map);
      for (var j = start + 1; j < a.entries.length && j <= start + 40; j++) {
        final e = a.entries[j];
        if (e.folder != map.folder || _isFolderMap(a, j)) break;
        if (e.name == 'PICTURE') return e;
      }
      return null;
    }
    if (!a.isZip) {
      // Lumps карты идут сразу за маркером — до следующей карты.
      final start = a.entries.indexOf(map);
      for (var j = start + 1; j < a.entries.length && j <= start + 40; j++) {
        final e = a.entries[j];
        if (e.name == 'PICTURE') return e;
        final nextIsMap = j + 1 < a.entries.length && _mapLumps.contains(a.entries[j + 1].name);
        if (nextIsMap && !_mapLumps.contains(e.name)) break;
      }
      return null;
    }
    final inner = AddonArchive.fromWadBytes(a.read(map), a._file, a.path);
    if (inner == null) return null;
    final pic = inner.find('PICTURE');
    // Читаем сразу: вложенный архив живёт только здесь.
    return pic == null ? null : _MemoryEntry(inner.read(pic));
  }

  static const _pngMagic = [0x89, 0x50, 0x4E, 0x47];

  /// Картинка lump: PNG — как есть; Doom-патч — в BMP по палитре.
  /// null — формат непонятен или палитры нет.
  static Uint8List? imageFromLump(Uint8List data, Uint8List? Function() palette) {
    if (data.length >= 4 && List.generate(4, (i) => data[i]).join(',') == _pngMagic.join(',')) {
      return data;
    }
    final pal = palette();
    if (pal == null) return null;
    final rgb = decodePatch(data, pal);
    return rgb == null ? null : encodeBmp(rgb.$1, rgb.$2, rgb.$3);
  }

  /// Doom-патч → (ширина, высота, RGB сверху вниз). Прозрачное — чёрным.
  /// [mask] — RGBA с прозрачностью (иконки персонажей).
  /// Поддерживает "высокие" патчи (topdelta ≤ предыдущего — смещение от него).
  static (int, int, Uint8List)? decodePatch(Uint8List d, Uint8List palette, {bool mask = false}) {
    if (d.length < 8) return null;
    final bd = ByteData.sublistView(d);
    final w = bd.getUint16(0, Endian.little);
    final h = bd.getUint16(2, Endian.little);
    if (w == 0 || h == 0 || w > 4096 || h > 4096 || d.length < 8 + 4 * w) return null;
    final bpp = mask ? 4 : 3; // RGBA: непокрытые пиксели прозрачные
    final rgb = Uint8List(w * h * bpp);
    for (var x = 0; x < w; x++) {
      var p = bd.getUint32(8 + 4 * x, Endian.little);
      var top = -1;
      while (p < d.length) {
        final delta = d[p];
        if (delta == 0xFF) break;
        top = top >= 0 && delta <= top ? top + delta : delta;
        if (p + 3 > d.length) return null;
        final len = d[p + 1];
        final start = p + 3;
        if (start + len > d.length) return null;
        for (var i = 0; i < len; i++) {
          final y = top + i;
          if (y >= h) break;
          final c = d[start + i] * 3;
          final o = (y * w + x) * bpp;
          rgb[o] = palette[c];
          rgb[o + 1] = palette[c + 1];
          rgb[o + 2] = palette[c + 2];
          if (mask) rgb[o + 3] = 255;
        }
        p = start + len + 1;
      }
    }
    return (w, h, rgb);
  }

  /// Палитра: PLAYPAL из [archives] (последний загруженный важнее), иначе из [files].
  static Uint8List? findPalette(List<AddonArchive> archives, List<String> files) {
    for (final a in archives.reversed) {
      final e = a.findFirst('PLAYPAL');
      if (e == null) continue;
      try {
        final d = a.read(e);
        if (d.length >= 768) return Uint8List.fromList(d.sublist(0, 768));
      } catch (_) {}
    }
    for (final path in files) {
      final x = AddonArchive.open(path);
      if (x == null) continue;
      try {
        final p = findPalette([x], const []);
        if (p != null) return p;
      } finally {
        x.close();
      }
    }
    return null;
  }

  /// Doom-патч → (ширина, высота, индексы палитры, маска непрозрачности) —
  /// для перекраски персонажей до перевода в цвета.
  static (int, int, Uint8List, Uint8List)? decodePatchIndexed(Uint8List d) {
    if (d.length < 8) return null;
    final bd = ByteData.sublistView(d);
    final w = bd.getUint16(0, Endian.little);
    final h = bd.getUint16(2, Endian.little);
    if (w == 0 || h == 0 || w > 4096 || h > 4096 || d.length < 8 + 4 * w) return null;
    final idx = Uint8List(w * h);
    final mask = Uint8List(w * h);
    for (var x = 0; x < w; x++) {
      var p = bd.getUint32(8 + 4 * x, Endian.little);
      var top = -1;
      while (p < d.length) {
        final delta = d[p];
        if (delta == 0xFF) break;
        top = top >= 0 && delta <= top ? top + delta : delta;
        if (p + 3 > d.length) return null;
        final len = d[p + 1];
        final start = p + 3;
        if (start + len > d.length) return null;
        for (var i = 0; i < len; i++) {
          final y = top + i;
          if (y >= h) break;
          idx[y * w + x] = d[start + i];
          mask[y * w + x] = 1;
        }
        p = start + len + 1;
      }
    }
    return (w, h, idx, mask);
  }

  /// PNG (RGBA, 8 бит) — Flutter показывает его с прозрачностью.
  static Uint8List encodePng(int w, int h, Uint8List rgba) {
    final raw = BytesBuilder();
    for (var y = 0; y < h; y++) {
      raw.addByte(0); // фильтр None
      raw.add(Uint8List.sublistView(rgba, y * w * 4, (y + 1) * w * 4));
    }
    final out = BytesBuilder()..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    void chunk(String type, List<int> data) {
      final t = ascii.encode(type);
      out.add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List());
      out.add(t);
      out.add(data);
      out.add((ByteData(4)..setUint32(0, crc32([...t, ...data]))).buffer.asUint8List());
    }

    chunk('IHDR', (ByteData(13)
          ..setUint32(0, w)
          ..setUint32(4, h)
          ..setUint8(8, 8) // бит на канал
          ..setUint8(9, 6)) // RGBA
        .buffer
        .asUint8List());
    chunk('IDAT', ZLibCodec().encode(raw.toBytes()));
    chunk('IEND', const []);
    return out.toBytes();
  }

  static List<int>? _crcTable;

  /// CRC-32 (как в zip и PNG).
  static int crc32(List<int> data) {
    final table = _crcTable ??= List<int>.generate(256, (n) {
      var c = n;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
      }
      return c;
    });
    var crc = 0xFFFFFFFF;
    for (final b in data) {
      crc = table[(crc ^ b) & 0xFF] ^ (crc >> 8);
    }
    return crc ^ 0xFFFFFFFF;
  }

  /// 24-битный BMP (Flutter показывает его через Image.memory).
  static Uint8List encodeBmp(int w, int h, Uint8List rgb) {
    final row = (w * 3 + 3) & ~3;
    final size = 54 + row * h;
    final b = Uint8List(size);
    final bd = ByteData.sublistView(b);
    b[0] = 0x42;
    b[1] = 0x4D;
    bd.setUint32(2, size, Endian.little);
    bd.setUint32(10, 54, Endian.little);
    bd.setUint32(14, 40, Endian.little);
    bd.setInt32(18, w, Endian.little);
    bd.setInt32(22, h, Endian.little); // снизу вверх
    bd.setUint16(26, 1, Endian.little);
    bd.setUint16(28, 24, Endian.little);
    bd.setUint32(34, row * h, Endian.little);
    for (var y = 0; y < h; y++) {
      final dst = 54 + (h - 1 - y) * row;
      for (var x = 0; x < w; x++) {
        final s = (y * w + x) * 3;
        b[dst + x * 3] = rgb[s + 2];
        b[dst + x * 3 + 1] = rgb[s + 1];
        b[dst + x * 3 + 2] = rgb[s];
      }
    }
    return b;
  }

  /// SOC аддона, как их грузит игра (W_LoadDehackedLumps*): в WAD — lumps
  /// SOC_*, MAINCFG, OBJCTCFG; в PK3 — все файлы в SOC/ и её подпапках,
  /// с любыми именами.
  static SocInfo _readSoc(AddonArchive a) {
    final info = SocInfo();
    for (final e in a.entries) {
      final isSoc = a.isZip
          ? e.lowerPath.startsWith('soc/')
          : e.name == 'MAINCFG' || e.name == 'OBJCTCFG' || e.name.startsWith('SOC_');
      if (!isSoc || e.size > 4 << 20) continue;
      try {
        info.addAll(parseSocInfo(latin1.decode(a.read(e), allowInvalid: true)));
      } catch (_) {
        // битый SOC — без названий
      }
    }
    return info;
  }

  /// Разбор блоков `Level ...` в SOC: имя карты → "Levelname Act".
  static Map<String, String> parseSoc(String text) => parseSocInfo(text).titles;

  /// Разбор SOC: блоки `Level ...` (Levelname, Act, Hidden) и TitleMap из MainCfg.
  static SocInfo parseSocInfo(String text) {
    final info = SocInfo();
    final titles = info.titles;
    String? map;
    var name = '';
    var act = '';

    void flush() {
      if (map != null && name.isNotEmpty) titles[map!] = act.isEmpty || act == '0' ? name : '$name $act';
      map = null;
      name = '';
      act = '';
    }

    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.split('#').first.trim();
      if (line.isEmpty) {
        flush();
        continue;
      }
      final eq = line.indexOf('=');
      if (eq < 0) {
        // Новый блок: "Level 1", "Level A1", "Level RR_TESTRUN"; другие блоки закрывают уровень.
        flush();
        final parts = line.split(RegExp(r'\s+'));
        final word = parts[0].toUpperCase();
        if (parts.length >= 2 && word == 'LEVEL') map = socLevelMap(parts[1]);
        if (parts.length >= 2 && word == 'CLEAR') {
          final what = parts[1].toUpperCase();
          if (what == 'ALL' || what == 'LEVELS') info.clear();
        }
        continue;
      }
      final key = line.substring(0, eq).trim().toUpperCase();
      final value = line.substring(eq + 1).trim();
      if (map == null) {
        if (key == 'TITLEMAP' && value.isNotEmpty) info.titleMap = socTitleMap(value);
        continue;
      }
      if (key == 'LEVELNAME') name = value;
      if (key == 'ACT') act = value;
      if (key == 'TYPEOFLEVEL') {
        info.types[map!] = [
          for (final t in value.split(RegExp(r'[,|]')))
            if (t.trim().isNotEmpty) t.trim(),
        ];
      }
      if (key == 'MUSIC' && value.isNotEmpty) info.music[map!] = _musicList(value);
      if (key == 'ENCOREMUSIC' && value.isNotEmpty) info.encoreMusic[map!] = _musicList(value);
      // Старый номер музыки (2.1): MusicSlot = 5 → O_MAP05M.
      if (key == 'MUSICSLOT') {
        final n = int.tryParse(value) ?? 0;
        if (n > 0 && n <= 1035) info.music[map!] = ['${mapName(n)}M'];
      }
      if (key == 'HIDDEN') {
        final v = value.toUpperCase();
        info.hidden[map!] = v.startsWith('T') || v.startsWith('Y') || (int.tryParse(v) ?? 0) != 0;
      }
    }
    flush();
    return info;
  }

  /// `GFZ1` / `O_GFZ1` / `RRA, RRB` → имена без O_/D_; `NONE` — без музыки.
  static List<String> _musicList(String value) {
    if (value.trim().toUpperCase() == 'NONE') return const [];
    return [
      for (final m in value.split(RegExp(r'[,\s]+')))
        if (m.isNotEmpty) _musicLump(m),
    ];
  }

  static String _musicLump(String name) {
    final u = name.toUpperCase();
    return u.startsWith('O_') || u.startsWith('D_') ? u.substring(2) : u;
  }

  /// TitleMap: число ("99"), две буквы ("Z0" → MAPZ0) или имя карты ("RR_TITLE").
  static String? socTitleMap(String value) {
    final v = value.split(RegExp(r'\s')).first.toUpperCase();
    final n = int.tryParse(v);
    if (n != null) return n > 0 && n <= 1035 ? mapName(n) : null;
    if (v.length == 2 && mapNumber('MAP$v') > 0) return 'MAP$v';
    return v;
  }

  /// "1" → MAP01, "A1" → MAPA1, "MAP05"/"RR_TESTRUN" — как есть.
  static String? socLevelMap(String word) {
    final w = word.toUpperCase();
    final n = int.tryParse(w);
    if (n != null) return n > 0 && n <= 1035 ? mapName(n) : null;
    if (w.length == 2 && mapNumber('MAP$w') > 0) return 'MAP$w';
    return w;
  }
}

/// Запись, уже прочитанная в память (картинка из вложенной карты).
class _MemoryEntry extends ArchiveEntry {
  final Uint8List bytes;
  _MemoryEntry(this.bytes) : super('PICTURE', 'PICTURE', 0, bytes.length);
}
