import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'game_progress.dart' show evalSocNumber, ProgressDefs;
import 'map_preview.dart';
import 'ubjson.dart';

/// Прогресс Dr. Robotnik's Ring Racers: `ringdata.dat` и `ringprofiles.prf`
/// из папки игры (оба — заголовок и UBJSON, как g_gamedata.cpp и
/// k_profiles.cpp) и описания кубков, медалей и испытаний из SOC игры.

/// Время в тиках (35 в секунду) по режимам, как `playtime` в ringdata.dat.
const ringModes = ['race', 'battle', 'prisons', 'special', 'timeattack', 'spbattack', 'tumble', 'netgame', 'custom', 'menus'];

/// Уровни сложности Гран-при (KARTSPEED_EASY…, KARTGP_MASTER): индекс в
/// `cups.<кубок>.records`.
const ringGpDifficulties = ['Relaxed', 'Intense', 'Vicious', 'Master'];

/// Оценка Гран-при (gp_rank_e: GRADE_E = 0 … GRADE_S = 5).
String ringGrade(int g) => g >= 0 && g <= 5 ? 'EDCBAS'[g] : '?';

/// Лучший результат кубка на одной сложности.
typedef RingCupRecord = ({int placement, int grade, bool emerald, String skin});

/// Рекорды карты: посещена / пройдена, Time Attack и SPB Attack (тики, 0 —
/// нет), сколько на ней сыграно.
class RingMapRecord {
  final bool visited, beaten, encore, spbAttack;
  final int bestTime, bestLap, spbTime, spbLap, timePlayed;

  const RingMapRecord({
    this.visited = false,
    this.beaten = false,
    this.encore = false,
    this.spbAttack = false,
    this.bestTime = 0,
    this.bestLap = 0,
    this.spbTime = 0,
    this.spbLap = 0,
    this.timePlayed = 0,
  });

  bool get hasRecord => bestTime > 0 || spbTime > 0;
}

/// Персонаж: победы, раунды, время в игре (тики).
typedef RingSkinRecord = ({int wins, int rounds, int time});

/// Содержимое ringdata.dat.
class RingData {
  static const versionMajor = 0xBA5ED321; // GD_VERSION_MAJOR

  final Map<String, int> playTime;
  final Map<String, int> rounds;
  final int totalRings, chaoKeys, timesBeaten;
  final List<bool> unlocked, conditionSets, emblems;
  final Map<String, List<RingCupRecord?>> cups;
  final Map<String, RingMapRecord> maps;
  final Map<String, RingSkinRecord> skins;

  RingData._(this.playTime, this.rounds, this.totalRings, this.chaoKeys, this.timesBeaten, this.unlocked,
      this.conditionSets, this.emblems, this.cups, this.maps, this.skins);

  /// Файла ещё нет (игра не запускалась).
  RingData.empty()
      : playTime = const {},
        rounds = const {},
        totalRings = 0,
        chaoKeys = 0,
        timesBeaten = 0,
        unlocked = const [],
        conditionSets = const [],
        emblems = const [],
        cups = const {},
        maps = const {},
        skins = const {};

  int get playTimeTotal => playTime['total'] ?? 0;
  int get unlockedCount => unlocked.where((x) => x).length;
  int get emblemsCollected => emblems.where((x) => x).length;

  bool collected(int emblem) => emblem >= 0 && emblem < emblems.length && emblems[emblem];

  /// Разбор файла: u32 версия (0xBA5ED321), u8 минорная, u8 «упал» и UBJSON.
  static RingData parse(Uint8List bytes) {
    if (bytes.length < 7 || ByteData.sublistView(bytes).getUint32(0, Endian.little) != versionMajor) {
      throw const FormatException('Not a Ring Racers ringdata.dat');
    }
    final j = Ubjson.decode(bytes, 6);
    if (j is! Map<String, Object?>) throw const FormatException('ringdata.dat: no data');
    return fromJson(j);
  }

  static RingData fromJson(Map<String, Object?> j) {
    Map<String, Object?> obj(Object? v) => v is Map<String, Object?> ? v : const {};
    int n(Object? v) => v is num ? v.toInt() : 0;
    List<bool> bools(Object? v) => v is List ? [for (final x in v) x == true] : const [];

    final cups = <String, List<RingCupRecord?>>{};
    for (final e in obj(j['cups']).entries) {
      final records = obj(e.value)['records'];
      if (records is! List) continue;
      cups[e.key.toUpperCase()] = [
        for (final r in records)
          if (r is Map<String, Object?> && n(r['bestplacement']) > 0)
            (placement: n(r['bestplacement']), grade: n(r['bestgrade']), emerald: r['gotemerald'] == true,
                skin: (r['bestskin'] as String?) ?? '')
          else
            null,
      ];
    }

    final maps = <String, RingMapRecord>{};
    for (final e in obj(j['maps']).entries) {
      final m = obj(e.value);
      final visited = obj(m['visited']);
      final stats = obj(m['stats']);
      final ta = obj(stats['timeattack']);
      final spb = obj(stats['spbattack']);
      maps[e.key.toUpperCase()] = RingMapRecord(
        visited: visited['visited'] == true,
        beaten: visited['beaten'] == true,
        encore: visited['encore'] == true,
        spbAttack: visited['spbattack'] == true,
        bestTime: n(ta['besttime']),
        bestLap: n(ta['bestlap']),
        spbTime: n(spb['besttime']),
        spbLap: n(spb['bestlap']),
        timePlayed: n(obj(stats['time'])['total']),
      );
    }

    final skins = <String, RingSkinRecord>{};
    for (final e in obj(j['skins']).entries) {
      final r = obj(obj(e.value)['records']);
      skins[e.key.toLowerCase()] = (wins: n(r['wins']), rounds: n(r['rounds']), time: n(obj(r['time'])['total']));
    }

    return RingData._(
      {for (final e in obj(j['playtime']).entries) e.key: n(e.value)},
      {for (final e in obj(j['rounds']).entries) e.key: n(e.value)},
      n(obj(j['rings'])['total']),
      n(obj(j['challengekeys'])['chaokeys']),
      n(j['timesBeaten']),
      bools(j['unlockables']),
      bools(j['conditionsets']),
      bools(j['emblems']),
      cups,
      maps,
      skins,
    );
  }
}

/// Профиль из ringprofiles.prf (ключи профиля не читаются и не хранятся).
class RingProfile {
  final String name, playerName, skin, color, follower;
  final int wins, rounds;

  const RingProfile(this.name, this.playerName, this.skin, this.color, this.follower, this.wins, this.rounds);

  /// "RINGPRFL", 4 резервных байта и UBJSON `{profiles: [...]}`.
  static List<RingProfile> parse(Uint8List bytes) {
    if (bytes.length < 13 || ascii.decode(bytes.sublist(0, 8), allowInvalid: true) != 'RINGPRFL') {
      throw const FormatException('Not a Ring Racers ringprofiles.prf');
    }
    final j = Ubjson.decode(bytes, 12);
    final list = j is Map<String, Object?> ? j['profiles'] : null;
    if (list is! List) return const [];
    int n(Object? v) => v is num ? v.toInt() : 0;
    String s(Object? v) => v is String ? v : '';
    return [
      for (final e in list)
        if (e is Map<String, Object?>)
          RingProfile(
            s(e['profilename']),
            s(e['playername']),
            s(e['skinname']).toLowerCase(),
            s(e['colorname']),
            s(e['followername']),
            n(e['records'] is Map ? (e['records'] as Map)['wins'] : 0),
            n(e['records'] is Map ? (e['records'] as Map)['rounds'] : 0),
          ),
    ];
  }
}

/// Кубок из SOC игры (`Cup RR_SNEAKER`: RealName, Icon, LevelList…).
class RingCup {
  final String id;
  String realName = '';
  String icon = '';
  final List<String> levels = [];
  String special = '';

  RingCup(this.id);

  /// RealName, иначе имя без RR_ («RR_SNEAKER» → «Sneaker»).
  String get title {
    if (realName.isNotEmpty) return realName;
    final base = id.startsWith('RR_') ? id.substring(3) : id;
    return base.isEmpty ? id : base[0] + base.substring(1).toLowerCase();
  }
}

/// Медаль (Emblem N): тип, карта, цель (тики для Time).
class RingMedal {
  final int number;
  String type = '';
  String map = '';
  String variable = '';

  RingMedal(this.number);

  int get target => evalSocNumber(variable);
}

/// Испытание (Unlockable N).
class RingChallenge {
  final int number;
  String name = '';
  String type = '';
  int conditionSet = 0;

  RingChallenge(this.number);
}

/// Описания из SOC игры: кубки (по порядку), медали, испытания, названия карт.
class RingDefs {
  final List<RingCup> cups = [];
  final Map<int, RingMedal> medals = {};
  final Map<int, RingChallenge> challenges = {};
  final Map<String, String> mapTitles = {};

  void addSoc(String text) {
    Object? current;
    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trim();
      if (line.isEmpty) {
        current = null;
        continue;
      }
      if (line.startsWith('#')) continue;
      final eq = line.indexOf('=');
      if (eq < 0) {
        final parts = line.split(RegExp(r'\s+'));
        final word = parts[0].toUpperCase();
        final arg = parts.length > 1 ? parts[1].toUpperCase() : '';
        final number = int.tryParse(arg) ?? 0;
        current = switch (word) {
          'CUP' when arg.isNotEmpty => _cup(arg),
          'EMBLEM' when number > 0 => medals[number] = RingMedal(number),
          'UNLOCKABLE' when number > 0 => challenges[number] = RingChallenge(number),
          _ => null,
        };
        continue;
      }
      final key = line.substring(0, eq).trim().toUpperCase();
      final value = line.substring(eq + 1).trim();
      switch (current) {
        case RingCup c:
          switch (key) {
            case 'REALNAME':
              c.realName = value;
            case 'ICON':
              c.icon = value.toUpperCase();
            case 'LEVELLIST':
              c.levels
                ..clear()
                ..addAll([for (final l in value.split(',')) if (l.trim().isNotEmpty) l.trim().toUpperCase()]);
            case 'SPECIALSTAGE':
              c.special = value.toUpperCase();
          }
        case RingMedal m:
          switch (key) {
            case 'TYPE':
              m.type = value.toUpperCase();
            case 'MAPNAME':
              m.map = value.toUpperCase();
            case 'VAR':
              m.variable = value;
          }
        case RingChallenge u:
          switch (key) {
            case 'NAME':
              u.name = value;
            case 'TYPE':
              u.type = value.toUpperCase();
            case 'CONDITIONSET':
              u.conditionSet = int.tryParse(value) ?? 0;
          }
      }
    }
  }

  /// Кубок [id]: уже объявленный (SOC может дополнять его) или новый в конце.
  RingCup _cup(String id) {
    final known = cups.where((c) => c.id == id).firstOrNull;
    if (known != null) return known;
    final cup = RingCup(id);
    cups.add(cup);
    return cup;
  }

  /// Медали карты [map] с их номерами (номер − 1 — бит в ringdata.dat).
  List<RingMedal> medalsOf(String map) => [
        for (final m in medals.values)
          if (m.map == map) m,
      ]..sort((a, b) => a.number - b.number);
}

/// Всё для вкладки: данные, профили, описания и значки кубков (PNG).
class RingProgress {
  final RingData data;
  final List<RingProfile> profiles;
  final RingDefs defs;
  final Map<String, Uint8List> cupIcons;
  final String dataPath;
  final DateTime? modified;

  RingProgress(this.data, this.profiles, this.defs, this.cupIcons, this.dataPath, this.modified);

  static const dataFile = 'ringdata.dat';
  static const profilesFile = 'ringprofiles.prf';

  static Future<RingProgress> load(String folder, List<String> gameFiles, List<String> paletteFiles) =>
      Isolate.run(() => loadSync(folder, gameFiles, paletteFiles));

  static RingProgress loadSync(String folder, List<String> gameFiles, List<String> paletteFiles) {
    final dataFile = File(p.join(folder, RingProgress.dataFile));
    final exists = dataFile.existsSync();
    final data = exists ? RingData.parse(dataFile.readAsBytesSync()) : RingData.empty();
    var profiles = const <RingProfile>[];
    try {
      final f = File(p.join(folder, profilesFile));
      if (f.existsSync()) profiles = RingProfile.parse(f.readAsBytesSync());
    } catch (_) {}

    final defs = RingDefs();
    final archives = [for (final f in gameFiles) if (AddonArchive.open(f) case final a?) a];
    final icons = <String, Uint8List>{};
    try {
      for (final a in archives) {
        for (final e in a.entries) {
          if (!ProgressDefs.isSocEntry(a, e) || e.size > 8 << 20) continue;
          try {
            defs.addSoc(latin1.decode(a.read(e), allowInvalid: true));
          } catch (_) {}
        }
        try {
          defs.mapTitles.addAll(MapScanner.levelTitles(a));
        } catch (_) {}
      }
      Uint8List? palette;
      var paletteRead = false;
      Uint8List? pal() {
        if (!paletteRead) {
          paletteRead = true;
          palette = MapScanner.findPalette(archives, paletteFiles);
        }
        return palette;
      }

      for (final c in defs.cups) {
        if (c.icon.isEmpty) continue;
        for (final a in archives.reversed) {
          final e = a.find(c.icon);
          if (e == null) continue;
          try {
            final png = _icon(a.read(e), pal);
            if (png != null) icons[c.id] = png;
          } catch (_) {}
          break;
        }
      }
    } finally {
      for (final a in archives) {
        a.close();
      }
    }
    return RingProgress(data, profiles, defs, icons, dataFile.path, exists ? dataFile.lastModifiedSync() : null);
  }

  /// Значок кубка: PNG как есть, Doom-патч — с прозрачностью.
  static Uint8List? _icon(Uint8List data, Uint8List? Function() palette) {
    if (data.length > 8 && data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47) return data;
    final pal = palette();
    if (pal == null) return null;
    final rgba = MapScanner.decodePatch(data, pal, mask: true);
    return rgba == null ? null : MapScanner.encodePng(rgba.$1, rgba.$2, rgba.$3);
  }
}
