import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:xxh3/xxh3.dart';

import 'file_hash.dart';
import 'game_progress.dart' show ProgressDefs;
import 'map_preview.dart' show AddonArchive;
import 'platform_utils.dart';

/// Доп. аддон для просмотра реплеев (например, Spectator Camera).
typedef ReplayExtraAddon = ({String path, bool enabled});

/// Найденный на диске аддон реплея: путь и совпала ли контрольная сумма из заголовка.
typedef ReplayResolvedAddon = ({String path, bool exact});

/// Аддон, записанный в заголовке реплея (SRB2 `demoversion >= 16`, SRB2Kart, Ring Racers, BlanKart).
class ReplayAddon {
  final String name;

  /// Контрольная сумма: 32 hex-символа MD5 (SRB2, SRB2Kart, Ring Racers)
  /// или 16 hex-символов XXH3-64 (BlanKart).
  final String md5;

  /// Байт compatmode в заголовке BlanKart (для остальных форматов — 0).
  final int compatMode;

  const ReplayAddon(this.name, this.md5, {this.compatMode = 0});
}

/// Тип файла реплея по стандартному суффиксу имени в SRB2 / Ring Racers.
enum ReplayKind {
  last,
  timeBest,
  lapBest,
  scoreBest,
  ringsBest,
  custom;

  static ReplayKind fromFileName(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('-last.lmp')) return ReplayKind.last;
    if (lower.endsWith('-time-best.lmp')) return ReplayKind.timeBest;
    if (lower.endsWith('-lap-best.lmp')) return ReplayKind.lapBest;
    if (lower.endsWith('-score-best.lmp')) return ReplayKind.scoreBest;
    if (lower.endsWith('-rings-best.lmp')) return ReplayKind.ringsBest;
    return ReplayKind.custom;
  }
}

/// Прочитанный `.lmp`-файл реплея SRB2 2.2, SRB2 Legacy или Ring Racers.
class ReplayFile {
  final String path;

  /// Путь, который нужно передавать в `-playdemo` (относительно `data/` или корня игры).
  final String relativePlayPath;

  /// Папка внутри `replay/` / `media/replay/` (например, `main`, `online/v2.2`) или `SRB2AL-Replays`.
  final String folder;
  final String fileName;
  final ReplayKind kind;
  final int size;
  final DateTime modified;

  final bool validHeader;
  final bool isKart;
  final bool isBlan;
  final int version;
  final int subversion;
  final int demoVersion;
  final String headerChecksum;
  final int mapNumber;
  final String mapName;
  final String title;
  final String gametype;
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
    this.isKart = false,
    this.isBlan = false,
    this.version = 0,
    this.subversion = 0,
    this.demoVersion = 0,
    this.headerChecksum = '',
    this.mapNumber = 0,
    this.mapName = '',
    this.title = '',
    this.gametype = '',
    this.addons = const [],
    this.timeTics,
    this.score = 0,
    this.rings = 0,
    this.playerName = '',
    this.skin = '',
    this.color = '',
  });

  bool get isImported => folder == ReplayScanner.importedFolder;

  /// Хранит ли заголовок список аддонов (SRB2 `demover >= 16` и все версии Ring Racers).
  bool get supportsEmbeddedAddons => isKart || demoVersion >= 16;

  /// Читаемая версия игры (например, `2.2.15`, `2.1.30`, `2.4`).
  String get versionLabel {
    if (!validHeader || version <= 0) return '';
    if (isKart) return '$version.$subversion';
    return '${version ~/ 100}.${version % 100}.$subversion';
  }

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
  static const tempFolder = 'temp';
  static const tempReplayName = 'replay.lmp';

  /// Магическая сигнатура заголовка SRB2 2.1/2.2: `\xf0SRB2Replay\x0f`.
  static const _magic = <int>[
    0xF0, 0x53, 0x52, 0x42, 0x32, 0x52, 0x65, 0x70, 0x6C, 0x61, 0x79, 0x0F,
  ];

  /// Магическая сигнатура заголовка SRB2Kart / Ring Racers: `\xf0KartReplay\x0f`.
  static const _kartMagic = <int>[
    0xF0, 0x4B, 0x61, 0x72, 0x74, 0x52, 0x65, 0x70, 0x6C, 0x61, 0x79, 0x0F,
  ];

  /// Магическая сигнатура заголовка BlanKart: `\xf0BlanReplay\x0f`.
  static const _blanMagic = <int>[
    0xF0, 0x42, 0x6C, 0x61, 0x6E, 0x52, 0x65, 0x70, 0x6C, 0x61, 0x79, 0x0F,
  ];

  static String importedDir(String gameFolder) => p.join(gameFolder, importedFolder);

  static String tempDir(String gameFolder) => p.join(importedDir(gameFolder), tempFolder);

  static String tempReplayPath(String gameFolder) => p.join(tempDir(gameFolder), tempReplayName);

  static String tempReplayRelativePlayPath() => p.join(importedFolder, tempFolder, tempReplayName);

  static bool _startsWith(Uint8List bytes, List<int> magic) {
    if (bytes.length < magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) return false;
    }
    return true;
  }

  static bool hasSrb2Magic(Uint8List bytes) => _startsWith(bytes, _magic);
  static bool hasKartMagic(Uint8List bytes) => _startsWith(bytes, _kartMagic);
  static bool hasBlanMagic(Uint8List bytes) => _startsWith(bytes, _blanMagic);
  static bool hasMagic(Uint8List bytes) => hasSrb2Magic(bytes) || hasKartMagic(bytes) || hasBlanMagic(bytes);

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

  /// Разбирает заголовок `.lmp`-файла SRB2 (2.1/2.2) или Ring Racers (`\xf0KartReplay\x0f`).
  /// Если прочитан только префикс файла, итоги заезда Ring Racers можно передать через [tailBytes].
  static ReplayFile parseBytes(
    Uint8List bytes, {
    required String path,
    required String relativePlayPath,
    required String folder,
    required int size,
    required DateTime modified,
    Uint8List? tailBytes,
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

    if (hasBlanMagic(bytes)) {
      return _parseBlanBytes(
        bytes,
        tailBytes: tailBytes ?? bytes,
        path: path,
        relativePlayPath: relativePlayPath,
        folder: folder,
        fileName: fileName,
        kind: kind,
        size: size,
        modified: modified,
        fallback: fallback,
      );
    }

    if (hasKartMagic(bytes)) {
      if (bytes.length > 0x0C && bytes[0x0C] < 2) {
        return _parseSrb2KartBytes(
          bytes,
          tailBytes: tailBytes ?? bytes,
          path: path,
          relativePlayPath: relativePlayPath,
          folder: folder,
          fileName: fileName,
          kind: kind,
          size: size,
          modified: modified,
          fallback: fallback,
        );
      }
      return _parseKartBytes(
        bytes,
        tailBytes: tailBytes ?? bytes,
        path: path,
        relativePlayPath: relativePlayPath,
        folder: folder,
        fileName: fileName,
        kind: kind,
        size: size,
        modified: modified,
        fallback: fallback,
      );
    }

    if (!hasSrb2Magic(bytes) || bytes.length < 0x37 + 10 + 4 + 64) return fallback();
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

  static ReplayFile _parseKartBytes(
    Uint8List bytes, {
    required Uint8List tailBytes,
    required String path,
    required String relativePlayPath,
    required String folder,
    required String fileName,
    required ReplayKind kind,
    required int size,
    required DateTime modified,
    required ReplayFile Function() fallback,
  }) {
    // 0x00..0x0F заголовка + 64-байтовый title + 16-байтовый checksum + "PLAY" + map\0 + 16-байтовый mapmd5 + flags(2)
    if (bytes.length < 0x64 + 2 + 16 + 2 + 3) return fallback();
    if (bytes[0x60] != 0x50 || bytes[0x61] != 0x4C || bytes[0x62] != 0x41 || bytes[0x63] != 0x59) {
      return fallback();
    }
    final version = bytes[0x0C];
    final subversion = bytes[0x0D];
    final demoVersion = bytes[0x0E];
    final title = _readFixedLatin1(bytes, 0x10, 64).trim();
    final checksum = _hex(bytes, 0x50, 16);

    var off = 0x64;
    var mapEnd = off;
    while (mapEnd < bytes.length && bytes[mapEnd] != 0 && mapEnd - off < 64) {
      mapEnd++;
    }
    if (mapEnd >= bytes.length || bytes[mapEnd] != 0) return fallback();
    final mapName = latin1.decode(Uint8List.sublistView(bytes, off, mapEnd)).toUpperCase();
    off = mapEnd + 1 + 16 + 2; // '\0' + mapmd5(16) + demoflags(2)
    if (off >= bytes.length) return fallback();

    var gtEnd = off;
    while (gtEnd < bytes.length && bytes[gtEnd] != 0 && gtEnd - off < 64) {
      gtEnd++;
    }
    if (gtEnd >= bytes.length || bytes[gtEnd] != 0) return fallback();
    final gametype = latin1.decode(Uint8List.sublistView(bytes, off, gtEnd));
    off = gtEnd + 1 + 1; // '\0' + speed/flags byte
    if (off >= bytes.length) return fallback();

    final numAddons = bytes[off++];
    final addons = <ReplayAddon>[];
    for (var i = 0; i < numAddons; i++) {
      var end = off;
      while (end < bytes.length && bytes[end] != 0 && end - off < 260) {
        end++;
      }
      if (end >= bytes.length || bytes[end] != 0) return fallback();
      final name = latin1.decode(Uint8List.sublistView(bytes, off, end));
      off = end + 1;
      if (off + 16 > bytes.length) return fallback();
      final md5Hex = _hex(bytes, off, 16);
      off += 16;
      if (name.isNotEmpty) addons.add(ReplayAddon(name, md5Hex));
    }

    final skins = <String>[];
    if (off < bytes.length) {
      final nSkins = bytes[off++];
      for (var i = 0; i < nSkins && off + 22 <= bytes.length; i++) {
        skins.add(_readFixedLatin1(bytes, off, 16).trim().toLowerCase());
        off += 22; // 16-байтовое имя + 6 байт характеристик/флагов
      }
    }

    var playerName = '';
    var skin = '';
    var color = '';
    int? timeTics;
    var score = 0;

    final stIdx = _findKartStandingsOffset(tailBytes);
    if (stIdx >= 0) {
      try {
        final (obj, _) = _readUbjson(tailBytes, stIdx);
        if (obj is Map) {
          final standings = obj['standings'];
          if (standings is List && standings.isNotEmpty && standings.first is Map) {
            final first = standings.first as Map;
            playerName = '${first['name'] ?? ''}'.trim();
            color = '${first['skincolor'] ?? ''}'.trim();
            final demoSkin = (first['demoskin'] as num?)?.toInt();
            if (demoSkin != null && demoSkin >= 0 && demoSkin < skins.length) {
              skin = skins[demoSkin];
            }
            final rawVal = (first['timeorscore'] as num?)?.toInt();
            if (rawVal != null && rawVal >= 0 && rawVal < 0x7FFFFFFF) {
              if (gametype.toLowerCase() == 'battle') {
                score = rawVal;
              } else {
                timeTics = rawVal;
              }
            }
          }
        }
      } catch (_) {}
    }

    // Если заезд не был завершён (итогового UBJSON нет), скин можно узнать из имени `MAP-SKIN-last.lmp`.
    if (skin.isEmpty && skins.isNotEmpty) {
      final parts = p.basenameWithoutExtension(fileName).split('-');
      for (var i = 1; i < parts.length; i++) {
        final cand = parts[i].toLowerCase();
        if (skins.contains(cand)) {
          skin = cand;
          break;
        }
      }
    }

    return ReplayFile(
      path: path,
      relativePlayPath: relativePlayPath,
      folder: folder,
      fileName: fileName,
      kind: kind,
      size: size,
      modified: modified,
      validHeader: true,
      isKart: true,
      version: version,
      subversion: subversion,
      demoVersion: demoVersion,
      headerChecksum: checksum,
      mapName: mapName,
      title: title,
      gametype: gametype,
      addons: addons,
      timeTics: timeTics,
      score: score,
      playerName: playerName,
      skin: skin,
      color: color,
    );
  }

  static (String, int)? _readCstr(Uint8List bytes, int start, {int maxLen = 260}) {
    var end = start;
    while (end < bytes.length && bytes[end] != 0 && end - start < maxLen) {
      end++;
    }
    if (end >= bytes.length || bytes[end] != 0) return null;
    return (latin1.decode(Uint8List.sublistView(bytes, start, end)), end + 1);
  }

  static List<ReplayAddon>? _readAddonList(
    Uint8List bytes,
    int start,
    int count, {
    required int hashBytes,
    int extraBytes = 0,
  }) {
    final addons = <ReplayAddon>[];
    var off = start;
    for (var i = 0; i < count; i++) {
      final res = _readCstr(bytes, off, maxLen: 512);
      if (res == null) return null;
      final (name, nextOff) = res;
      off = nextOff;
      if (off + hashBytes + extraBytes > bytes.length) return null;
      final hashHex = _hex(bytes, off, hashBytes);
      final compat = extraBytes > 0 ? bytes[off + hashBytes] : 0;
      off += hashBytes + extraBytes;
      if (name.isNotEmpty) addons.add(ReplayAddon(name, hashHex, compatMode: compat));
    }
    return addons;
  }

  static (String name, String skin, String color, int? timeTics, int score) _parseLegacyKartStandings(
    Uint8List tailBytes, {
    required bool cstrFields,
    required bool isBattle,
  }) {
    final searchStart = tailBytes.length > 8192 ? tailBytes.length - 8192 : 0;
    final marker = _lastIndexOfBytes(tailBytes, const [0xFF, 0x80], searchStart);
    if (marker < 0 || marker + 3 > tailBytes.length) return ('', '', '', null, 0);

    var p0 = marker + 2;
    if (p0 < tailBytes.length && tailBytes[p0] == 0) p0++;
    if (p0 >= tailBytes.length || tailBytes[p0] != 1) return ('', '', '', null, 0);
    p0++;

    String name = '';
    String skin = '';
    String color = '';
    if (cstrFields) {
      final nRes = _readCstr(tailBytes, p0, maxLen: 64);
      if (nRes == null) return ('', '', '', null, 0);
      final sRes = _readCstr(tailBytes, nRes.$2, maxLen: 64);
      if (sRes == null) return ('', '', '', null, 0);
      final cRes = _readCstr(tailBytes, sRes.$2, maxLen: 64);
      if (cRes == null) return ('', '', '', null, 0);
      name = nRes.$1.trim();
      skin = sRes.$1.trim().toLowerCase();
      color = cRes.$1.trim();
      p0 = cRes.$2;
    } else {
      if (p0 + 48 > tailBytes.length) return ('', '', '', null, 0);
      name = _readFixedLatin1(tailBytes, p0, 16).trim();
      skin = _readFixedLatin1(tailBytes, p0 + 16, 16).trim().toLowerCase();
      color = _readFixedLatin1(tailBytes, p0 + 32, 16).trim();
      p0 += 48;
    }

    int? timeTics;
    var score = 0;
    final hasSentinel = p0 + 5 == tailBytes.length &&
        tailBytes[p0] == 0xFE &&
        tailBytes[p0 + 1] == 0xFF &&
        tailBytes[p0 + 2] == 0xFF &&
        tailBytes[p0 + 3] == 0xFF &&
        tailBytes[p0 + 4] == 0xFF;
    if (!hasSentinel && p0 + 4 <= tailBytes.length) {
      final rawVal = ByteData.sublistView(tailBytes).getUint32(p0, Endian.little);
      if (rawVal < 0x7FFFFFFF) {
        if (isBattle) {
          score = rawVal;
        } else {
          timeTics = rawVal;
        }
      }
    }
    return (name, skin, color, timeTics, score);
  }

  static ReplayFile _parseSrb2KartBytes(
    Uint8List bytes, {
    required Uint8List tailBytes,
    required String path,
    required String relativePlayPath,
    required String folder,
    required String fileName,
    required ReplayKind kind,
    required int size,
    required DateTime modified,
    required ReplayFile Function() fallback,
  }) {
    // 0x00..0x0F заголовка + 64 title + 16 checksum + "PLAY"(4) + map(2) + mapmd5(16) + flags(1) + gt(1) + numfiles(1)
    if (bytes.length < 0x79) return fallback();
    if (bytes[0x60] != 0x50 || bytes[0x61] != 0x4C || bytes[0x62] != 0x41 || bytes[0x63] != 0x59) {
      return fallback();
    }
    final bd = ByteData.sublistView(bytes);
    final version = bytes[0x0C];
    final subversion = bytes[0x0D];
    final demoVersion = bytes[0x0E];
    final title = _readFixedLatin1(bytes, 0x10, 64).trim();
    final checksum = _hex(bytes, 0x50, 16);
    final mapNumber = bd.getUint16(0x64, Endian.little);
    final mapName = formatMapName(mapNumber);
    final demoFlags = bytes[0x76];
    final isTimeAttack = (demoFlags & 0x02) != 0;
    final gametype = bytes[0x77] == 1 ? 'Battle' : 'Race';
    final numAddons = bytes[0x78];

    var off = 0x79;
    final addons = <ReplayAddon>[];
    for (var i = 0; i < numAddons; i++) {
      final res = _readCstr(bytes, off);
      if (res == null) return fallback();
      final (name, nextOff) = res;
      off = nextOff;
      if (off + 16 > bytes.length) return fallback();
      final md5Hex = _hex(bytes, off, 16);
      off += 16;
      if (name.isNotEmpty) addons.add(ReplayAddon(name, md5Hex));
    }

    var playerName = '';
    var skin = '';
    var color = '';
    int? timeTics;
    var score = 0;

    if (isTimeAttack) {
      if (off + 18 <= bytes.length) {
        final rawTime = bd.getUint32(off, Endian.little);
        if (rawTime != 0xFFFFFFFF) timeTics = rawTime;
        off += 16; // time(4) + bestLap(4) + seed(4) + tics(4)
        final numNetvars = bd.getUint16(off, Endian.little);
        off += 2;
        var okNetvars = numNetvars <= 512;
        for (var i = 0; i < numNetvars && okNetvars; i++) {
          if (off + 2 > bytes.length) {
            okNetvars = false;
            break;
          }
          off += 2;
          final nv = _readCstr(bytes, off, maxLen: 512);
          if (nv == null) {
            okNetvars = false;
            break;
          }
          off = nv.$2;
        }
        if (okNetvars && off + 2 <= bytes.length) {
          off += 2; // слот игрока / префикс
          final pRes = _readCstr(bytes, off, maxLen: 64);
          if (pRes != null) {
            playerName = pRes.$1.trim();
            final sOff = pRes.$2;
            if (sOff + 32 <= bytes.length) {
              skin = _readFixedLatin1(bytes, sOff, 16).trim().toLowerCase();
              color = _readFixedLatin1(bytes, sOff + 16, 16).trim();
            }
          }
        }
      }
    } else {
      (playerName, skin, color, timeTics, score) = _parseLegacyKartStandings(
        tailBytes,
        cstrFields: false,
        isBattle: gametype == 'Battle',
      );
    }

    if (skin.isEmpty && kind != ReplayKind.custom) {
      final parts = p.basenameWithoutExtension(fileName).split('-');
      if (parts.length >= 3) skin = parts[1].toLowerCase();
    }

    return ReplayFile(
      path: path,
      relativePlayPath: relativePlayPath,
      folder: folder,
      fileName: fileName,
      kind: kind,
      size: size,
      modified: modified,
      validHeader: true,
      isKart: true,
      version: version,
      subversion: subversion,
      demoVersion: demoVersion,
      headerChecksum: checksum,
      mapNumber: mapNumber,
      mapName: mapName,
      title: title,
      gametype: gametype,
      addons: addons,
      timeTics: timeTics,
      score: score,
      playerName: playerName,
      skin: skin,
      color: color,
    );
  }

  static ReplayFile _parseBlanBytes(
    Uint8List bytes, {
    required Uint8List tailBytes,
    required String path,
    required String relativePlayPath,
    required String folder,
    required String fileName,
    required ReplayKind kind,
    required int size,
    required DateTime modified,
    required ReplayFile Function() fallback,
  }) {
    if (bytes.length < 0x5C + 4) return fallback();
    if (bytes[0x58] != 0x50 || bytes[0x59] != 0x4C || bytes[0x5A] != 0x41 || bytes[0x5B] != 0x59) {
      return fallback();
    }
    final bd = ByteData.sublistView(bytes);
    final version = bytes[0x0C];
    final subversion = bytes[0x0D];
    final demoVersion = bd.getUint16(0x0E, Endian.little);
    final title = _readFixedLatin1(bytes, 0x10, 64).trim();
    final checksum = _hex(bytes, 0x50, 8);

    final mapRes = _readCstr(bytes, 0x5C, maxLen: 64);
    if (mapRes == null) return fallback();
    final mapName = mapRes.$1.toUpperCase();
    var off = mapRes.$2 + 8 + 1; // maphash(8) + demoflags(1)
    if (off >= bytes.length) return fallback();

    var gametype = '';
    if (demoVersion >= 11) {
      final gtRes = _readCstr(bytes, off, maxLen: 32);
      if (gtRes == null) return fallback();
      gametype = gtRes.$1;
      off = gtRes.$2;
      for (var i = 0; i < 3; i++) {
        // serverName, shortDesc, motd
        final sRes = _readCstr(bytes, off, maxLen: 512);
        if (sRes == null) return fallback();
        off = sRes.$2;
      }
    }
    off += 2; // 2 байта перед счётчиком аддонов
    if (off >= bytes.length) return fallback();

    final numAddons = bytes[off++];
    final addons = _readAddonList(bytes, off, numAddons, hashBytes: 8, extraBytes: 1);
    if (addons == null) return fallback();

    final gtLower = gametype.toLowerCase();
    final gtLabel = gtLower == 'kart'
        ? 'Race'
        : (gametype.isEmpty ? '' : '${gametype[0].toUpperCase()}${gametype.substring(1)}');

    var (playerName, skin, color, timeTics, score) = _parseLegacyKartStandings(
      tailBytes,
      cstrFields: demoVersion > 12,
      isBattle: gtLower == 'battle',
    );
    if (skin.isEmpty && kind != ReplayKind.custom) {
      final parts = p.basenameWithoutExtension(fileName).split('-');
      if (parts.length >= 3) skin = parts[1].toLowerCase();
    }

    return ReplayFile(
      path: path,
      relativePlayPath: relativePlayPath,
      folder: folder,
      fileName: fileName,
      kind: kind,
      size: size,
      modified: modified,
      validHeader: true,
      isKart: true,
      isBlan: true,
      version: version,
      subversion: subversion,
      demoVersion: demoVersion,
      headerChecksum: checksum,
      mapName: mapName,
      title: title,
      gametype: gtLabel,
      addons: addons,
      timeTics: timeTics,
      score: score,
      playerName: playerName,
      skin: skin,
      color: color,
    );
  }

  static int _lastIndexOfBytes(Uint8List hay, List<int> needle, [int from = 0]) {
    if (needle.isEmpty || hay.length < needle.length) return -1;
    final start = from < 0 ? 0 : from;
    for (var i = hay.length - needle.length; i >= start; i--) {
      var ok = true;
      for (var j = 0; j < needle.length; j++) {
        if (hay[i + j] != needle[j]) {
          ok = false;
          break;
        }
      }
      if (ok) return i;
    }
    return -1;
  }

  static int _findKartStandingsOffset(Uint8List b) {
    final searchStart = b.length > 32768 ? b.length - 32768 : 0;
    // v2.0..v2.2: `{i\tstandings[` ; v2.4: `{#U\x01U\tstandings[`
    final m1 = [0x7B, 0x69, 0x09, ...latin1.encode('standings'), 0x5B];
    final m2 = [0x7B, 0x23, 0x55, 0x01, 0x55, 0x09, ...latin1.encode('standings'), 0x5B];
    final i1 = _lastIndexOfBytes(b, m1, searchStart);
    final i2 = _lastIndexOfBytes(b, m2, searchStart);
    return i1 > i2 ? i1 : i2;
  }

  static (Object?, int) _readUbjson(Uint8List b, int pos) {
    final bd = ByteData.sublistView(b);
    int readInt(int p0, int tag) => switch (tag) {
          0x69 /* 'i' */ => bd.getInt8(p0),
          0x55 /* 'U' */ => bd.getUint8(p0),
          0x49 /* 'I' */ => bd.getInt16(p0, Endian.big),
          0x6C /* 'l' */ => bd.getInt32(p0, Endian.big),
          0x4C /* 'L' */ => bd.getInt64(p0, Endian.big),
          _ => throw FormatException('UBJSON int tag $tag'),
        };
    int intSize(int tag) => switch (tag) {
          0x69 || 0x55 => 1,
          0x49 => 2,
          0x6C => 4,
          0x4C => 8,
          _ => 0,
        };
    (int, int) readTypedInt(int p0) {
      final t = b[p0++];
      final s = intSize(t);
      if (s == 0) throw FormatException('Invalid UBJSON length tag $t');
      return (readInt(p0, t), p0 + s);
    }

    (String, int) readStr(int p0) {
      final (len, next) = readTypedInt(p0);
      final s = latin1.decode(Uint8List.sublistView(b, next, next + len));
      return (s, next + len);
    }

    (Object?, int) parse(int p0) {
      final t = b[p0++];
      if (t == 0x53 /* 'S' */) return readStr(p0);
      if (t == 0x64 /* 'd' */) return (bd.getFloat32(p0, Endian.big), p0 + 4);
      if (t == 0x44 /* 'D' */) return (bd.getFloat64(p0, Endian.big), p0 + 8);
      if (t == 0x54 /* 'T' */) return (true, p0);
      if (t == 0x46 /* 'F' */) return (false, p0);
      if (t == 0x5A /* 'Z' */) return (null, p0);
      final isz = intSize(t);
      if (isz > 0) return (readInt(p0, t), p0 + isz);
      if (t == 0x5B /* '[' */) {
        final out = <Object?>[];
        if (b[p0] == 0x23 /* '#' */) {
          final (count, start) = readTypedInt(p0 + 1);
          var cur = start;
          for (var i = 0; i < count; i++) {
            final (v, next) = parse(cur);
            out.add(v);
            cur = next;
          }
          return (out, cur);
        }
        var cur = p0;
        while (b[cur] != 0x5D /* ']' */) {
          final (v, next) = parse(cur);
          out.add(v);
          cur = next;
        }
        return (out, cur + 1);
      }
      if (t == 0x7B /* '{' */) {
        final out = <String, Object?>{};
        if (b[p0] == 0x23 /* '#' */) {
          final (count, start) = readTypedInt(p0 + 1);
          var cur = start;
          for (var i = 0; i < count; i++) {
            final (k, kNext) = readStr(cur);
            final (v, vNext) = parse(kNext);
            out[k] = v;
            cur = vNext;
          }
          return (out, cur);
        }
        var cur = p0;
        while (b[cur] != 0x7D /* '}' */) {
          final (k, kNext) = readStr(cur);
          final (v, vNext) = parse(kNext);
          out[k] = v;
          cur = vNext;
        }
        return (out, cur + 1);
      }
      throw FormatException('Unsupported UBJSON tag $t');
    }

    return parse(pos);
  }

  static ReplayFile _readAndParseFile(
    File file, {
    required String relativePlayPath,
    required String folder,
    required FileStat st,
  }) {
    final raf = file.openSync();
    late Uint8List head;
    Uint8List? tail;
    try {
      head = raf.readSync(16384);
      if (st.size > 16384) {
        const tailMax = 8192;
        final tailStart = st.size > tailMax ? st.size - tailMax : 0;
        raf.setPositionSync(tailStart);
        tail = raf.readSync(st.size - tailStart);
      }
    } finally {
      raf.closeSync();
    }
    return parseBytes(
      head,
      tailBytes: tail,
      path: file.path,
      relativePlayPath: relativePlayPath,
      folder: folder,
      size: st.size,
      modified: st.modified,
    );
  }

  /// Сканирует реплеи SRB2 2.2 в `SRB2AL-Replays/`, `data/replay/` и `replay/` в фоне.
  static Future<List<ReplayFile>> scanInBackground(String gameFolder) =>
      Isolate.run(() => _scanSync(gameFolder));

  static List<ReplayFile> _scanSync(String gameFolder) {
    final out = <ReplayFile>[];
    final seenPaths = <String>{};

    void scanRoot(Directory dir, {required String baseForRelative, String? fixedFolder, bool skipTemp = false}) {
      if (!dir.existsSync()) return;
      final skipPrefix = skipTemp ? '${p.normalize(p.join(dir.path, tempFolder)).toLowerCase()}${Platform.pathSeparator}' : null;
      try {
        for (final e in dir.listSync(recursive: true, followLinks: false)) {
          if (e is! File) continue;
          if (!e.path.toLowerCase().endsWith('.lmp')) continue;
          final norm = p.normalize(e.path).toLowerCase();
          if (skipPrefix != null && norm.startsWith(skipPrefix)) continue;
          if (!seenPaths.add(norm)) continue;

          try {
            final st = e.statSync();
            final relDir = p.relative(p.dirname(e.path), from: dir.path);
            final folder = fixedFolder ?? (relDir == '.' ? '' : relDir);
            final relPlay = p.relative(e.path, from: baseForRelative);
            out.add(_readAndParseFile(e, relativePlayPath: relPlay, folder: folder, st: st));
          } catch (_) {}
        }
      } catch (_) {}
    }

    // 1. Импортированные лаунчером реплеи — прямо в корне игры (`SRB2AL-Replays/`, кроме временного `temp/`).
    scanRoot(Directory(importedDir(gameFolder)),
        baseForRelative: gameFolder, fixedFolder: importedFolder, skipTemp: true);
    // 2. Стандартная папка реплеев SRB2 2.2 (`data/replay/...`).
    final dataDir = p.join(gameFolder, 'data');
    scanRoot(Directory(p.join(dataDir, 'replay')), baseForRelative: dataDir);
    // 3. Корневая `replay/` (SRB2 Legacy / сборки без `data/`).
    scanRoot(Directory(p.join(gameFolder, 'replay')), baseForRelative: gameFolder);
    // 4. Ring Racers (`media/replay/...`).
    scanRoot(Directory(p.join(gameFolder, 'media', 'replay')), baseForRelative: gameFolder);

    out.sort((a, b) => b.modified.compareTo(a.modified));
    return out;
  }

  /// Объединяет идентичные файлы реплея в одной папке (например `-last`,
  /// `-time-best`, `-lap-best`, `-score-best`, `-rings-best` с одинаковым размером и контрольной суммой).
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
          ReplayKind.lapBest => 2,
          ReplayKind.scoreBest => 3,
          ReplayKind.ringsBest => 4,
          ReplayKind.custom => 5,
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
    final destFile = File(destPath);
    final st = await destFile.stat();
    return _readAndParseFile(
      destFile,
      relativePlayPath: p.relative(destPath, from: gameFolder),
      folder: importedFolder,
      st: st,
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
        throw const FormatException('Not a valid replay file (.lmp)');
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

  /// Пересобирает заголовок `.lmp` (SRB2 `demover >= 16`, SRB2Kart, Ring Racers, BlanKart)
  /// под указанный список аддонов и пересчитывает контрольную сумму заголовка.
  static Uint8List patchHeaderAddons(Uint8List sourceBytes, List<ReplayAddon> addons) {
    if (hasBlanMagic(sourceBytes)) {
      return _patchBlanHeaderAddons(sourceBytes, addons);
    }
    if (hasKartMagic(sourceBytes)) {
      return sourceBytes.length > 0x0C && sourceBytes[0x0C] < 2
          ? _patchSrb2KartHeaderAddons(sourceBytes, addons)
          : _patchKartHeaderAddons(sourceBytes, addons);
    }
    if (!hasSrb2Magic(sourceBytes) || sourceBytes.length < 0x39) {
      throw const FormatException('Not a valid replay file');
    }
    final demoVersion = sourceBytes[0x0E];
    if (demoVersion < 16) {
      return Uint8List.fromList(sourceBytes);
    }
    final bd = ByteData.sublistView(sourceBytes);
    final oldNumFiles = bd.getUint16(0x37, Endian.little);
    var off = 0x39;
    for (var i = 0; i < oldNumFiles; i++) {
      final res = _readCstr(sourceBytes, off, maxLen: 512);
      if (res == null) throw const FormatException('Corrupt replay file header');
      off = res.$2 + 16;
      if (off > sourceBytes.length) throw const FormatException('Corrupt replay file header');
    }

    final out = BytesBuilder(copy: false);
    // 0x00..0x36 (с временным местом под контрольную сумму 0x10..0x1F)
    out.add(Uint8List.sublistView(sourceBytes, 0, 0x37));
    final count = addons.length;
    out.addByte(count & 0xFF);
    out.addByte((count >> 8) & 0xFF);
    for (final a in addons) {
      out.add(latin1.encode(a.name));
      out.addByte(0);
      out.add(_hexToBytes(a.md5, 16));
    }
    out.add(Uint8List.sublistView(sourceBytes, off));

    final result = out.takeBytes();
    final digest = md5.convert(Uint8List.sublistView(result, 0x20)).bytes;
    result.setRange(0x10, 0x20, digest);
    return result;
  }

  static Uint8List _rewriteByteCountAddons(
    Uint8List sourceBytes, {
    required int countOffset,
    required int hashBytes,
    required int extraBytes,
    required int oldChecksumEnd,
    required bool useXxh3Checksum,
    required List<ReplayAddon> addons,
  }) {
    final oldNum = sourceBytes[countOffset];
    var off = countOffset + 1;
    final oldCompat = <String, int>{};
    for (var i = 0; i < oldNum; i++) {
      final res = _readCstr(sourceBytes, off, maxLen: 512);
      if (res == null) throw const FormatException('Corrupt replay file header');
      final next = res.$2 + hashBytes + extraBytes;
      if (next > sourceBytes.length) throw const FormatException('Corrupt replay file header');
      if (extraBytes > 0) {
        oldCompat.putIfAbsent(res.$1.toLowerCase(), () => sourceBytes[res.$2 + hashBytes]);
      }
      off = next;
    }

    final out = BytesBuilder(copy: false);
    out.add(Uint8List.sublistView(sourceBytes, 0, countOffset));
    final count = addons.length > 255 ? 255 : addons.length;
    out.addByte(count);
    for (var i = 0; i < count; i++) {
      final a = addons[i];
      out.add(latin1.encode(a.name));
      out.addByte(0);
      out.add(_hexToBytes(a.md5, hashBytes));
      if (extraBytes > 0) {
        out.addByte(a.compatMode != 0 ? a.compatMode : (oldCompat[a.name.toLowerCase()] ?? 0));
      }
    }
    out.add(Uint8List.sublistView(sourceBytes, off));

    final result = out.takeBytes();
    final newChecksumEnd = (oldChecksumEnd + result.length - sourceBytes.length).clamp(0x60, result.length);
    if (useXxh3Checksum) {
      // package:xxh3 не учитывает offsetInBytes у Uint8List.sublistView, поэтому делаем sublist.
      final h = xxh3(result.sublist(0x60, newChecksumEnd));
      for (var i = 0; i < 8; i++) {
        result[0x50 + i] = (h >> (8 * i)) & 0xFF;
      }
    } else {
      final digest = md5.convert(Uint8List.sublistView(result, 0x60, newChecksumEnd)).bytes;
      result.setRange(0x50, 0x60, digest);
    }
    return result;
  }

  static int _kartMarkerChecksumEnd(Uint8List bytes) {
    final start = bytes.length > 8192 ? bytes.length - 8192 : 0x60;
    final marker = _lastIndexOfBytes(bytes, const [0xFF, 0x80], start);
    if (marker >= 0) return marker + 2;
    return bytes.length > 0x60 ? bytes.length - 1 : bytes.length;
  }

  static Uint8List _patchSrb2KartHeaderAddons(Uint8List sourceBytes, List<ReplayAddon> addons) {
    if (sourceBytes.length < 0x79) {
      throw const FormatException('Not a valid SRB2Kart replay file');
    }
    return _rewriteByteCountAddons(
      sourceBytes,
      countOffset: 0x78,
      hashBytes: 16,
      extraBytes: 0,
      oldChecksumEnd: _kartMarkerChecksumEnd(sourceBytes),
      useXxh3Checksum: false,
      addons: addons,
    );
  }

  static Uint8List _patchBlanHeaderAddons(Uint8List sourceBytes, List<ReplayAddon> addons) {
    if (sourceBytes.length < 0x64) {
      throw const FormatException('Not a valid BlanKart replay file');
    }
    final demoVersion = ByteData.sublistView(sourceBytes).getUint16(0x0E, Endian.little);
    final mapRes = _readCstr(sourceBytes, 0x5C, maxLen: 64);
    if (mapRes == null) throw const FormatException('Corrupt replay file header');
    var off = mapRes.$2 + 8 + 1;
    if (demoVersion >= 11) {
      for (var i = 0; i < 4; i++) {
        final sRes = _readCstr(sourceBytes, off, maxLen: 512);
        if (sRes == null) throw const FormatException('Corrupt replay file header');
        off = sRes.$2;
      }
    }
    off += 2;
    if (off >= sourceBytes.length) throw const FormatException('Corrupt replay file header');

    return _rewriteByteCountAddons(
      sourceBytes,
      countOffset: off,
      hashBytes: 8,
      extraBytes: 1,
      oldChecksumEnd: _kartMarkerChecksumEnd(sourceBytes),
      useXxh3Checksum: true,
      addons: addons,
    );
  }

  static Uint8List _patchKartHeaderAddons(Uint8List sourceBytes, List<ReplayAddon> addons) {
    if (sourceBytes.length < 0x64 + 2 + 16 + 2 + 3) {
      throw const FormatException('Not a valid Ring Racers replay file');
    }
    final mapRes = _readCstr(sourceBytes, 0x64, maxLen: 64);
    if (mapRes == null) throw const FormatException('Corrupt replay file header');
    final gtRes = _readCstr(sourceBytes, mapRes.$2 + 16 + 2, maxLen: 64);
    if (gtRes == null) throw const FormatException('Corrupt replay file header');
    final countOffset = gtRes.$2 + 1;
    if (countOffset >= sourceBytes.length) throw const FormatException('Corrupt replay file header');

    final stIdx = _findKartStandingsOffset(sourceBytes);
    final oldChecksumEnd = (stIdx >= 5 && sourceBytes[stIdx - 5] == 1) ? stIdx - 5 : sourceBytes.length - 1;

    return _rewriteByteCountAddons(
      sourceBytes,
      countOffset: countOffset,
      hashBytes: 16,
      extraBytes: 0,
      oldChecksumEnd: oldChecksumEnd,
      useXxh3Checksum: false,
      addons: addons,
    );
  }

  static Uint8List _hexToBytes(String hex, int byteLen) {
    final out = Uint8List(byteLen);
    if (hex.length < byteLen * 2) return out;
    for (var i = 0; i < byteLen; i++) {
      out[i] = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16) ?? 0;
    }
    return out;
  }

  /// Создаёт `<gameFolder>/SRB2AL-Replays/temp/replay.lmp` с обновлённым списком
  /// аддонов [addonFilePaths] (базовые имена и реальные контрольные суммы) и пересчитанной суммой.
  /// Возвращает относительный путь для `-playdemo`.
  static Future<String> prepareTempReplay({
    required String sourcePath,
    required String gameFolder,
    required List<String> addonFilePaths,
  }) async {
    final bytes = await File(sourcePath).readAsBytes();
    final useXxh3 = hasBlanMagic(bytes);
    final addons = <ReplayAddon>[];
    for (final path in addonFilePaths) {
      final f = File(path);
      if (!await f.exists()) {
        throw FileSystemException('Addon file not found', path);
      }
      final String hashHex;
      if (useXxh3) {
        hashHex = await FileHash.xxh3OfFile(path) ?? '';
      } else {
        final digest = await md5.bind(f.openRead()).first;
        hashHex = digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      }
      addons.add(ReplayAddon(p.basename(path), hashHex));
    }
    final patched = patchHeaderAddons(bytes, addons);
    final dir = Directory(tempDir(gameFolder));
    await dir.create(recursive: true);
    await File(tempReplayPath(gameFolder)).writeAsBytes(patched, flush: true);
    return tempReplayRelativePlayPath();
  }

  /// Нормализует имя аддона/папки (без расширений и префикса `scr_`) для сопоставления.
  static String normalizeMatchKey(String raw) {
    var s = raw.toLowerCase();
    for (final ext in ['.pk3', '.wad', '.lua', '.soc', '.dat']) {
      if (s.endsWith(ext)) {
        s = s.substring(0, s.length - ext.length);
        break;
      }
    }
    if (s.startsWith('scr_')) s = s.substring(4);
    return s.replaceAll(RegExp(r'[^a-z0-9]+'), '');
  }

  static final Map<String, String> _gameDataStemCache = {};

  static String? _readGameDataStem(String path) {
    final norm = p.normalize(path).toLowerCase();
    if (_gameDataStemCache.containsKey(norm)) {
      final cached = _gameDataStemCache[norm]!;
      return cached.isEmpty ? null : cached;
    }
    final a = AddonArchive.open(path);
    if (a == null) return null;
    try {
      final defs = ProgressDefs();
      defs.addFiles([a]);
      final gd = defs.gameData?.trim().toLowerCase();
      final stem = gd == null || gd.isEmpty
          ? ''
          : (gd.endsWith('.dat') ? gd.substring(0, gd.length - 4) : gd);
      _gameDataStemCache[norm] = stem;
      return stem.isEmpty ? null : stem;
    } catch (_) {
      return null;
    } finally {
      a.close();
    }
  }

  static bool _nameMatchesFolder(String filePath, String folderLower, String folderCore) {
    final base = p.basenameWithoutExtension(filePath).toLowerCase();
    if (base == folderLower) return true;
    if (base.contains(folderLower)) return true;
    if (folderCore.length >= 4) {
      final baseCore = normalizeMatchKey(base);
      if (baseCore == folderCore || baseCore.contains(folderCore)) return true;
    }
    return false;
  }

  /// Определяет локальные аддоны для папок реплеев без списка аддонов в заголовке
  /// (`demoversion < 16`, например SRB2 Legacy `kimokawaiii` или SRB2 2.2 `scr_tei3`):
  /// 1) По `MainCfg -> GameData = <папка>.dat` в SOC аддона (с приоритетом файлов с похожим именем);
  /// 2) Запасной поиск по имени файла `.pk3`/`.wad`.
  static Future<Map<String, List<String>>> resolveAddonsByFolder({
    required List<String> folders,
    required List<List<String>> candidatePacks,
    required List<String> allLocalAddons,
  }) =>
      Isolate.run(() => _resolveAddonsByFolderSync(
            folders: folders,
            candidatePacks: candidatePacks,
            allLocalAddons: allLocalAddons,
          ));

  static Map<String, List<String>> _resolveAddonsByFolderSync({
    required List<String> folders,
    required List<List<String>> candidatePacks,
    required List<String> allLocalAddons,
  }) {
    final clean = <String>{
      for (final f in folders)
        if (f.isNotEmpty && f != 'main' && f != importedFolder) f,
    }.toList();
    if (clean.isEmpty) return const {};

    final wantedByLower = {for (final f in clean) f.toLowerCase(): f};
    final out = <String, List<String>>{};

    final orderedPacks = <List<String>>[
      for (final pack in candidatePacks)
        if (pack.isNotEmpty) pack,
      for (final f in allLocalAddons)
        if (f.toLowerCase().endsWith('.pk3') || f.toLowerCase().endsWith('.wad')) [f],
    ];

    void inspectPack(List<String> pack) {
      for (final file in pack) {
        final low = file.toLowerCase();
        if (!low.endsWith('.pk3') && !low.endsWith('.wad')) continue;
        final stem = _readGameDataStem(file);
        if (stem == null) continue;
        final original = wantedByLower[stem];
        if (original != null && !out.containsKey(original)) {
          out[original] = pack;
        }
      }
    }

    // 1. Сначала проверяем паки/файлы, чьё имя уже похоже на искомую папку (обычно 1–2 архива).
    final checkedPacks = <int>{};
    for (var i = 0; i < orderedPacks.length && out.length < clean.length; i++) {
      final pack = orderedPacks[i];
      final looksRelevant = clean.any((f) {
        if (out.containsKey(f)) return false;
        final fl = f.toLowerCase();
        final fc = normalizeMatchKey(fl);
        return pack.any((file) => _nameMatchesFolder(file, fl, fc));
      });
      if (!looksRelevant) continue;
      checkedPacks.add(i);
      inspectPack(pack);
    }

    // 2. Если для каких-то папок GameData не нашёлся — сканируем оставшиеся архивы.
    for (var i = 0; i < orderedPacks.length && out.length < clean.length; i++) {
      if (checkedPacks.contains(i)) continue;
      inspectPack(orderedPacks[i]);
    }

    // 3. Запасной вариант по имени файла `.pk3`/`.wad` (если у аддона не указан GameData).
    for (final f in clean) {
      if (out.containsKey(f)) continue;
      final fl = f.toLowerCase();
      final fc = normalizeMatchKey(fl);
      List<String>? best;
      for (final pack in orderedPacks) {
        if (pack.any((file) => normalizeMatchKey(p.basenameWithoutExtension(file)) == fc && fc.isNotEmpty)) {
          best = pack;
          break;
        }
        if (best == null && pack.any((file) => _nameMatchesFolder(file, fl, fc))) {
          best = pack;
        }
      }
      if (best != null) out[f] = best;
    }

    return out;
  }
}
