import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'platform_utils.dart';

/// Аддон, записанный в заголовке реплея SRB2 2.2 (`demoversion >= 16`).
class ReplayAddon {
  final String name;
  final String md5;
  const ReplayAddon(this.name, this.md5);
}

/// Тип файла реплея по стандартному суффиксу имени в SRB2.
enum ReplayKind {
  last,
  timeBest,
  scoreBest,
  ringsBest,
  custom;

  static ReplayKind fromFileName(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('-last.lmp')) return ReplayKind.last;
    if (lower.endsWith('-time-best.lmp')) return ReplayKind.timeBest;
    if (lower.endsWith('-score-best.lmp')) return ReplayKind.scoreBest;
    if (lower.endsWith('-rings-best.lmp')) return ReplayKind.ringsBest;
    return ReplayKind.custom;
  }
}

/// Прочитанный `.lmp`-файл реплея SRB2 2.2.
class ReplayFile {
  final String path;

  /// Путь, который нужно передавать в `-playdemo` (относительно `data/` или корня игры).
  final String relativePlayPath;

  /// Папка внутри `replay/` (например, `main`, `scr_tei3`) или `SRB2AL-Replays`.
  final String folder;
  final String fileName;
  final ReplayKind kind;
  final int size;
  final DateTime modified;

  final bool validHeader;
  final int version;
  final int subversion;
  final int demoVersion;
  final String headerChecksum;
  final int mapNumber;
  final String mapName;
  final List<ReplayAddon> addons;
  final int? timeTics;
  final int score;
  final int rings;
  final String playerName;
  final String skin;
  final String color;

  const ReplayFile({
    required this.path,
    required this.relativePlayPath,
    required this.folder,
    required this.fileName,
    required this.kind,
    required this.size,
    required this.modified,
    required this.validHeader,
    this.version = 0,
    this.subversion = 0,
    this.demoVersion = 0,
    this.headerChecksum = '',
    this.mapNumber = 0,
    this.mapName = '',
    this.addons = const [],
    this.timeTics,
    this.score = 0,
    this.rings = 0,
    this.playerName = '',
    this.skin = '',
    this.color = '',
  });

  bool get isImported => folder == ReplayScanner.importedFolder;

  /// Читаемая версия игры (например, `2.2.15`).
  String get versionLabel => validHeader && version > 0
      ? '${version ~/ 100}.${version % 100}.$subversion'
      : '';

  /// Время забега в формате `M:SS.cc` (35 тиков/сек в SRB2); `—` если забег не завершён.
  String get formattedTime {
    final t = timeTics;
    if (t == null) return '—';
    final totalSec = t ~/ 35;
    final min = totalSec ~/ 60;
    final sec = totalSec % 60;
    final cs = ((t % 35) * 100) ~/ 35;
    return '$min:${sec.toString().padLeft(2, '0')}.${cs.toString().padLeft(2, '0')}';
  }
}

/// Группа одинаковых файлов реплея в одной папке (например, `-last`,
/// `-time-best`, `-score-best`, `-rings-best`, указывающие на один забег).
class ReplayGroup {
  final ReplayFile primary;
  final List<ReplayFile> variants;

  const ReplayGroup(this.primary, this.variants);

  bool get isImported => primary.isImported;
}

class ReplayScanner {
  ReplayScanner._();

  static const importedFolder = 'SRB2AL-Replays';

  /// Магическая сигнатура заголовка SRB2 2.2: `\xf0SRB2Replay\x0f`.
  static const _magic = <int>[
    0xF0, 0x53, 0x52, 0x42, 0x32, 0x52, 0x65, 0x70, 0x6C, 0x61, 0x79, 0x0F,
  ];

  static String importedDir(String gameFolder) => p.join(gameFolder, importedFolder);

  static bool hasMagic(Uint8List bytes) {
    if (bytes.length < _magic.length) return false;
    for (var i = 0; i < _magic.length; i++) {
      if (bytes[i] != _magic[i]) return false;
    }
    return true;
  }

  /// Номер карты SRB2 (`1..99` -> `MAP01..MAP99`, `100..1035` -> `MAPA0..MAPZZ`).
  static String formatMapName(int n) {
    if (n >= 1 && n <= 99) return 'MAP${n.toString().padLeft(2, '0')}';
    if (n >= 100 && n <= 1035) {
      final v = n - 100;
      final first = String.fromCharCode(0x41 + v ~/ 36);
      final rem = v % 36;
      final second = rem < 10 ? '$rem' : String.fromCharCode(0x41 + rem - 10);
      return 'MAP$first$second';
    }
    return n > 0 ? 'MAP$n' : 'MAP?';
  }

  static String _hex(Uint8List bytes, int start, int len) {
    final sb = StringBuffer();
    for (var i = 0; i < len && start + i < bytes.length; i++) {
      sb.write(bytes[start + i].toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  static String _readFixedLatin1(Uint8List bytes, int start, int maxLen) {
    if (start >= bytes.length) return '';
    var end = start + maxLen;
    if (end > bytes.length) end = bytes.length;
    for (var i = start; i < end; i++) {
      if (bytes[i] == 0) {
        end = i;
        break;
      }
    }
    return latin1.decode(Uint8List.sublistView(bytes, start, end));
  }

  /// Разбирает заголовок `.lmp`-файла SRB2 2.2.
  static ReplayFile parseBytes(
    Uint8List bytes, {
    required String path,
    required String relativePlayPath,
    required String folder,
    required int size,
    required DateTime modified,
  }) {
    final fileName = p.basename(path);
    final kind = ReplayKind.fromFileName(fileName);
    ReplayFile fallback() => ReplayFile(
          path: path,
          relativePlayPath: relativePlayPath,
          folder: folder,
          fileName: fileName,
          kind: kind,
          size: size,
          modified: modified,
          validHeader: false,
        );

    if (!hasMagic(bytes) || bytes.length < 0x37 + 10 + 4 + 64) return fallback();
    if (bytes[0x20] != 0x50 || bytes[0x21] != 0x4C || bytes[0x22] != 0x41 || bytes[0x23] != 0x59) {
      return fallback();
    }

    final data = ByteData.sublistView(bytes);
    final version = bytes[0x0C];
    final subversion = bytes[0x0D];
    final demoVersion = bytes[0x0E];
    final checksum = _hex(bytes, 0x10, 16);
    final mapNumber = data.getUint16(0x24, Endian.little);
    final mapName = formatMapName(mapNumber);

    var off = 0x37;
    final addons = <ReplayAddon>[];
    if (demoVersion >= 16) {
      if (off + 2 > bytes.length) return fallback();
      final numFiles = data.getUint16(off, Endian.little);
      off += 2;
      if (numFiles > 256) return fallback();
      for (var i = 0; i < numFiles; i++) {
        var end = off;
        while (end < bytes.length && bytes[end] != 0 && end - off < 260) {
          end++;
        }
        if (end >= bytes.length || bytes[end] != 0) return fallback();
        final name = latin1.decode(Uint8List.sublistView(bytes, off, end));
        off = end + 1;
        if (off + 16 > bytes.length) return fallback();
        final md5 = _hex(bytes, off, 16);
        off += 16;
        if (name.isNotEmpty) addons.add(ReplayAddon(name, md5));
      }
    }

    if (off + 14 + 64 > bytes.length) return fallback();
    final rawTime = data.getUint32(off, Endian.little);
    final timeTics = rawTime == 0xFFFFFFFF ? null : rawTime;
    final score = data.getUint32(off + 4, Endian.little);
    final rings = data.getUint16(off + 8, Endian.little);
    off += 14; // time(4) + score(4) + rings(2) + seed/reserved(4)

    final playerName = _readFixedLatin1(bytes, off, 16).trim();
    off += 16;
    final skin = _readFixedLatin1(bytes, off, 16).trim().toLowerCase();
    off += 16;
    final color = _readFixedLatin1(bytes, off, 32).trim();

    return ReplayFile(
      path: path,
      relativePlayPath: relativePlayPath,
      folder: folder,
      fileName: fileName,
      kind: kind,
      size: size,
      modified: modified,
      validHeader: true,
      version: version,
      subversion: subversion,
      demoVersion: demoVersion,
      headerChecksum: checksum,
      mapNumber: mapNumber,
      mapName: mapName,
      addons: addons,
      timeTics: timeTics,
      score: score,
      rings: rings,
      playerName: playerName,
      skin: skin,
      color: color,
    );
  }

  /// Сканирует реплеи SRB2 2.2 в `SRB2AL-Replays/`, `data/replay/` и `replay/` в фоне.
  static Future<List<ReplayFile>> scanInBackground(String gameFolder) =>
      Isolate.run(() => _scanSync(gameFolder));

  static List<ReplayFile> _scanSync(String gameFolder) {
    final out = <ReplayFile>[];
    final seenPaths = <String>{};

    void scanRoot(Directory dir, {required String baseForRelative, String? fixedFolder}) {
      if (!dir.existsSync()) return;
      try {
        for (final e in dir.listSync(recursive: true, followLinks: false)) {
          if (e is! File) continue;
          if (!e.path.toLowerCase().endsWith('.lmp')) continue;
          final norm = p.normalize(e.path).toLowerCase();
          if (!seenPaths.add(norm)) continue;

          try {
            final st = e.statSync();
            final raf = e.openSync();
            Uint8List bytes;
            try {
              bytes = raf.readSync(4096);
            } finally {
              raf.closeSync();
            }
            final relDir = p.relative(p.dirname(e.path), from: dir.path);
            final folder = fixedFolder ?? (relDir == '.' ? '' : relDir);
            final relPlay = p.relative(e.path, from: baseForRelative);
            out.add(parseBytes(
              bytes,
              path: e.path,
              relativePlayPath: relPlay,
              folder: folder,
              size: st.size,
              modified: st.modified,
            ));
          } catch (_) {}
        }
      } catch (_) {}
    }

    // 1. Импортированные лаунчером реплеи — прямо в корне игры (`SRB2AL-Replays/`).
    scanRoot(Directory(importedDir(gameFolder)), baseForRelative: gameFolder, fixedFolder: importedFolder);
    // 2. Стандартная папка реплеев SRB2 2.2 (`data/replay/...`).
    final dataDir = p.join(gameFolder, 'data');
    scanRoot(Directory(p.join(dataDir, 'replay')), baseForRelative: dataDir);
    // 3. Корневая `replay/` (если игра пишет не в `data/`).
    scanRoot(Directory(p.join(gameFolder, 'replay')), baseForRelative: gameFolder);

    out.sort((a, b) => b.modified.compareTo(a.modified));
    return out;
  }

  /// Объединяет идентичные файлы реплея в одной папке (например `-last`,
  /// `-time-best`, `-score-best`, `-rings-best` с одинаковым размером и контрольной суммой).
  static List<ReplayGroup> groupDuplicates(List<ReplayFile> files) {
    final groups = <String, List<ReplayFile>>{};
    var uniqueIdx = 0;
    for (final f in files) {
      final key = f.validHeader && f.headerChecksum.isNotEmpty
          ? '${f.folder.toLowerCase()}\u0000${f.size}\u0000${f.headerChecksum}'
          : 'u\u0000${uniqueIdx++}';
      groups.putIfAbsent(key, () => []).add(f);
    }

    int kindRank(ReplayKind k) => switch (k) {
          ReplayKind.last => 0,
          ReplayKind.timeBest => 1,
          ReplayKind.scoreBest => 2,
          ReplayKind.ringsBest => 3,
          ReplayKind.custom => 4,
        };

    final out = <ReplayGroup>[];
    for (final variants in groups.values) {
      variants.sort((a, b) {
        final r = kindRank(a.kind).compareTo(kindRank(b.kind));
        return r != 0 ? r : a.fileName.toLowerCase().compareTo(b.fileName.toLowerCase());
      });
      out.add(ReplayGroup(variants.first, variants));
    }
    out.sort((a, b) => b.primary.modified.compareTo(a.primary.modified));
    return out;
  }

  /// Подбирает свободное имя `.lmp` в `SRB2AL-Replays/`.
  static String _availableTarget(String dir, String rawName) {
    var safe = PlatformUtils.safeFileName(rawName) ?? 'replay.lmp';
    if (!safe.toLowerCase().endsWith('.lmp')) safe = '$safe.lmp';
    var candidate = p.join(dir, safe);
    if (!File(candidate).existsSync()) return candidate;
    final stem = p.basenameWithoutExtension(safe);
    for (var i = 2; i < 1000; i++) {
      candidate = p.join(dir, '$stem ($i).lmp');
      if (!File(candidate).existsSync()) return candidate;
    }
    return p.join(dir, '${stem}_${DateTime.now().millisecondsSinceEpoch}.lmp');
  }

  /// Копирует локальный `.lmp` в `<gameFolder>/SRB2AL-Replays/`.
  static Future<ReplayFile> importLocalFile(String sourcePath, String gameFolder, {String? preferredName}) async {
    final src = File(sourcePath);
    if (!await src.exists()) {
      throw FileSystemException('Replay file not found', sourcePath);
    }
    final dir = Directory(importedDir(gameFolder));
    await dir.create(recursive: true);
    final destPath = _availableTarget(dir.path, preferredName ?? p.basename(sourcePath));
    await src.copy(destPath);
    final st = await File(destPath).stat();
    final raf = File(destPath).openSync();
    late Uint8List bytes;
    try {
      bytes = raf.readSync(4096);
    } finally {
      raf.closeSync();
    }
    return parseBytes(
      bytes,
      path: destPath,
      relativePlayPath: p.relative(destPath, from: gameFolder),
      folder: importedFolder,
      size: st.size,
      modified: st.modified,
    );
  }

  /// Скачивает `.lmp` по HTTP/HTTPS ссылке в `<gameFolder>/SRB2AL-Replays/`.
  static Future<ReplayFile> downloadFromUrl(String rawUrl, String gameFolder) async {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
      throw const FormatException('Enter a valid http:// or https:// URL');
    }

    const maxBytes = 50 * 1024 * 1024;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = 'SRB2-Autonomi-Launcher';
    try {
      final req = await client.getUrl(uri).timeout(const Duration(seconds: 20));
      final resp = await req.close().timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode}', uri: uri);
      }
      if (resp.contentLength > maxBytes) {
        throw const FormatException('File is too large (> 50 MiB)');
      }

      final builder = BytesBuilder(copy: false);
      await for (final chunk in resp.timeout(const Duration(seconds: 30))) {
        builder.add(chunk);
        if (builder.length > maxBytes) {
          throw const FormatException('File is too large (> 50 MiB)');
        }
      }
      final bytes = builder.takeBytes();
      if (!hasMagic(bytes)) {
        throw const FormatException('Not an SRB2 2.2 replay file (.lmp)');
      }

      var fileName = '';
      final disp = resp.headers.value('content-disposition');
      if (disp != null) {
        final m = RegExp(r'''filename\*?=(?:UTF-8'')?["']?([^"';]+)["']?''', caseSensitive: false).firstMatch(disp);
        if (m != null) fileName = Uri.decodeComponent(m.group(1)!.trim());
      }
      if (fileName.isEmpty) {
        fileName = uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? 'replay.lmp';
      }

      final dir = Directory(importedDir(gameFolder));
      await dir.create(recursive: true);
      final destPath = _availableTarget(dir.path, fileName);
      await File(destPath).writeAsBytes(bytes, flush: true);
      final st = await File(destPath).stat();
      return parseBytes(
        bytes,
        path: destPath,
        relativePlayPath: p.relative(destPath, from: gameFolder),
        folder: importedFolder,
        size: st.size,
        modified: st.modified,
      );
    } finally {
      client.close(force: true);
    }
  }
}
