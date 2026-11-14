import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'characters.dart';
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
  final bool visited, beaten, encore, spbAttack, mysticMelody;
  final int bestTime, bestLap, spbTime, spbLap, timePlayed;

  /// Баллончик с краской, собранный на карте: номер в [RingData.sprayCans];
  /// [sprayBonus] — бонус вместо баллончика; [noSprayCan] — не собран.
  final int sprayCan;
  static const noSprayCan = 0xFFFF, sprayBonus = 0xFFFE; // MCAN_INVALID, MCAN_BONUS

  const RingMapRecord({
    this.visited = false,
    this.beaten = false,
    this.encore = false,
    this.spbAttack = false,
    this.mysticMelody = false,
    this.bestTime = 0,
    this.bestLap = 0,
    this.spbTime = 0,
    this.spbLap = 0,
    this.timePlayed = 0,
    this.sprayCan = noSprayCan,
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

  /// Цвета баллончиков по порядку (`spraycans_v2`); у карты — номер в нём.
  final List<String> sprayCans;

  RingData._(this.playTime, this.rounds, this.totalRings, this.chaoKeys, this.timesBeaten, this.unlocked,
      this.conditionSets, this.emblems, this.cups, this.maps, this.skins, this.sprayCans);

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
        skins = const {},
        sprayCans = const [];

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
        mysticMelody: visited['mysticmelody'] == true,
        sprayCan: m.containsKey('spraycan') ? n(m['spraycan']) : RingMapRecord.noSprayCan,
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
      [for (final c in (j['spraycans_v2'] is List ? j['spraycans_v2'] as List : const [])) '$c'],
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

  /// Изумруд кубка (EmeraldNum): 1–7 — Chaos, 8–14 — Super, 0 — нет (в игре
  /// вместо него «+»).
  int emeraldNum = 0;

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

  /// Значок `GOTIT<sprite>`, цвет (SKINCOLOR_…, без него — Gold), Tag
  /// (AUTOMEDAL_BRONZE… — медали за время) и Flags (ME_SPBATTACK).
  String sprite = 'A';
  String color = '';
  String tag = '';
  String flags = '';

  RingMedal(this.number);

  int get target => evalSocNumber(variable);

  /// Тип: 1 — Global (спрятана на трассе), 2 — Map (пройти трассу), 3 —
  /// Time; 0 — неизвестен.
  int get kind => switch (type) {
        'GLOBAL' || '1' => 1,
        'MAP' || '2' => 2,
        'TIME' || '3' => 3,
        _ => 0,
      };

  /// Flags числом: ME_ENCORE / GE_NOTMEDAL = 1, ME_SPBATTACK / GE_TIMED = 2,
  /// GE_FOLLOWER = 4; можно через `|` или `+`.
  int get flagBits {
    var bits = 0;
    for (final t in flags.toUpperCase().split(RegExp(r'[|+\s]+'))) {
      bits |= switch (t) {
        'ME_ENCORE' || 'GE_NOTMEDAL' => 1,
        'ME_SPBATTACK' || 'GE_TIMED' => 2,
        'GE_FOLLOWER' => 4,
        _ => int.tryParse(t) ?? 0,
      };
    }
    return bits;
  }

  /// Медаль SPB Attack (у Map и Time).
  bool get spb => kind != 1 && flagBits & 2 != 0;

  /// Пройти в Encore (у Map и Time).
  bool get encore => kind != 1 && flagBits & 1 != 0;

  /// Global без GE_NOTMEDAL: не медаль — игра её в статистике не показывает.
  bool get notMedal => kind == 1 && flagBits & 1 != 0;

  /// Медаль за время: 0 — бронза, 1 — серебро, 2 — золото, 3 — платина; null —
  /// другая.
  int? get autoMedal => switch (tag.toUpperCase()) {
        'AUTOMEDAL_BRONZE' || '-4' => 0,
        'AUTOMEDAL_SILVER' || '-3' => 1,
        'AUTOMEDAL_GOLD' || '-2' => 2,
        'AUTOMEDAL_PLATINUM' || '-1' => 3,
        _ => null,
      };

  /// Цвет значка (M_GetEmblemColor: без цвета — золото).
  String get colorName => color.isEmpty || color == '0' ? 'Gold' : color;
}

/// Название трассы, как G_BuildMapTitle: «LevelName ZoneTitle Act»; без
/// ZoneTitle — «Zone», если нет NoZone (LF_NOZONE).
class RingLevelTitle {
  String name = '';
  String zone = '';
  int act = 0;
  bool noZone = false;

  String get title {
    if (name.isEmpty) return '';
    final z = zone.isNotEmpty ? ' $zone' : (noZone ? '' : ' Zone');
    return '$name$z${act > 0 ? ' $act' : ''}';
  }
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

  /// Заголовки уровней из SOC: название по G_BuildMapTitle.
  final Map<String, RingLevelTitle> levels = {};

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
          'LEVEL' when arg.isNotEmpty => levels.putIfAbsent(MapScanner.socLevelMap(arg) ?? arg, RingLevelTitle.new),
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
            case 'EMERALDNUM':
              c.emeraldNum = int.tryParse(value) ?? 0;
          }
        case RingMedal m:
          switch (key) {
            case 'TYPE':
              m.type = value.toUpperCase();
            case 'MAPNAME':
              m.map = value.toUpperCase();
            case 'VAR':
              m.variable = value;
            case 'SPRITE':
              // Буква A–Z или номер (1 = A), как reademblemdata.
              final v = value.toUpperCase();
              final n = int.tryParse(v);
              if (n != null && n >= 1 && n <= 26) {
                m.sprite = String.fromCharCode(64 + n);
              } else if (v.isNotEmpty && v.codeUnitAt(0) >= 65 && v.codeUnitAt(0) <= 90) {
                m.sprite = v[0];
              }
            case 'COLOR':
              m.color = value;
            case 'TAG':
              m.tag = value;
            case 'FLAGS':
              m.flags = value;
          }
        case RingLevelTitle l:
          switch (key) {
            case 'LEVELNAME':
              l.name = value;
            case 'ZONETITLE':
              l.zone = value;
            case 'ACT':
              l.act = int.tryParse(value) ?? 0;
            case 'NOZONE':
              final v = value.toUpperCase();
              l.noZone = v.startsWith('T') || v.startsWith('Y') || (int.tryParse(v) ?? 0) != 0;
            case 'LEVELFLAGS':
              final v = value.toUpperCase();
              l.noZone = v.contains('LF_NOZONE') || ((int.tryParse(v) ?? 0) & 2) != 0;
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

  /// Значки из графики игры (PNG), ключи — [medalArt], [sprayCanArt],
  /// [emeraldArt], [rankArt] и `NEEDIT`, `GOTBON`, `GOTMEL`, `PLUS`.
  final Map<String, Uint8List> art;

  /// Каких значков не нашлось или чем их заменили (для журнала).
  final List<String> artNotes;
  final String dataPath;
  final DateTime? modified;

  RingProgress(this.data, this.profiles, this.defs, this.cupIcons, this.art, this.dataPath, this.modified,
      [this.artNotes = const []]);

  static const dataFile = 'ringdata.dat';
  static const profilesFile = 'ringprofiles.prf';

  static String medalArt(RingMedal m) => 'GOTIT${m.sprite}:${m.colorName}';
  static String sprayCanArt(String color) => 'GOTCAN:$color';

  /// Изумруд [n] (1–14): полученный — в цвете Chaos Emerald, иначе пустой.
  static String emeraldArt(int n, bool got) => got ? 'EMER:$n' : (n > 7 ? 'SUPER2' : 'EMERW');
  static String rankArt(int grade) => 'RANK$grade';

  /// [colors] — встроенные цвета игры (для перекраски медалей, баллончиков,
  /// изумрудов — как R_GetTranslationColormap: индексы 96–111).
  static Future<RingProgress> load(String folder, List<String> gameFiles, List<String> paletteFiles,
          List<SkinColor> colors) =>
      Isolate.run(() => loadSync(folder, gameFiles, paletteFiles, colors));

  static RingProgress loadSync(String folder, List<String> gameFiles, List<String> paletteFiles,
      [List<SkinColor> colors = const []]) {
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
    final art = <String, Uint8List>{};
    final notes = <String>[];
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
      // Полные названия, как в игре: с ZoneTitle / «Zone».
      for (final e in defs.levels.entries) {
        if (e.value.title.isNotEmpty) defs.mapTitles[e.key] = e.value.title;
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
      _art(art, notes, archives, pal, colors, data, defs);
    } finally {
      for (final a in archives) {
        a.close();
      }
    }
    return RingProgress(
        data, profiles, defs, icons, art, dataFile.path, exists ? dataFile.lastModifiedSync() : null, notes);
  }

  /// Значки статистики и Гран-при (graphics/Menus/Statistics, Emerald HUD,
  /// Rank/Cup Select, консольный шрифт): перекрашенные — только нужные.
  static void _art(Map<String, Uint8List> out, List<String> notes, List<AddonArchive> archives,
      Uint8List? Function() palette, List<SkinColor> colors, RingData data, RingDefs defs) {
    final patches = <String, (int, int, Uint8List, Uint8List)?>{};
    (int, int, Uint8List, Uint8List)? patch(String lump) => patches.putIfAbsent(lump, () {
          for (final a in archives.reversed) {
            final e = a.find(lump);
            if (e == null) continue;
            try {
              return MapScanner.decodePatchIndexed(a.read(e));
            } catch (_) {
              return null;
            }
          }
          return null;
        });
    void put(String key, String lump, [String? color, String fallbackColor = '']) {
      if (out.containsKey(key)) return;
      final pt = patch(lump);
      final pal = palette();
      if (pal == null) {
        if (notes.isEmpty) notes.add('no PLAYPAL in the game files');
        return;
      }
      if (pt == null) {
        notes.add('no graphic $lump');
        return;
      }
      var ramp = color == null ? null : CharacterScanner.findColor(colors, color);
      if (color != null && ramp == null && fallbackColor.isNotEmpty) {
        notes.add('$key: color "$color" unknown, $fallbackColor instead');
        ramp = CharacterScanner.findColor(colors, fallbackColor);
      }
      if (color != null && ramp == null) {
        notes.add('$key: color "$color" unknown');
        return;
      }
      out[key] = CharacterScanner.render(pt.$1, pt.$2, pt.$3, pt.$4, pal, 96, ramp);
    }

    put('NEEDIT', 'NEEDIT');
    put('GOTBON', 'GOTBON');
    put('GOTMEL', 'GOTMEL');
    put('PLUS', 'STCFN043');
    put('EMERW', 'K_EMERW');
    put('SUPER2', 'K_SUPER2');
    for (var n = 1; n <= 14; n++) {
      put(emeraldArt(n, true), n > 7 ? 'K_SUPER1' : 'K_EMERC', 'Chaos Emerald ${(n - 1) % 7 + 1}');
    }
    // Оценка — в своём цвете (K_GetGradeColor).
    const gradeColors = ['Blue', 'Turtle', 'Orange', 'Red', 'Magenta', 'Pigeon'];
    for (var g = 0; g <= 5; g++) {
      put(rankArt(g), 'R_CUPRN${'EDCBAS'[g]}', gradeColors[g]);
    }
    // Медаль: GOTIT<буква> (нет такой — GOTITA) в её цвете; неизвестный цвет
    // — золото, как M_GetEmblemColor.
    for (final m in defs.medals.values) {
      if (!data.collected(m.number - 1)) continue;
      final lump = patch('GOTIT${m.sprite}') != null ? 'GOTIT${m.sprite}' : 'GOTITA';
      put(medalArt(m), lump, m.colorName, 'Gold');
    }
    for (final rec in data.maps.values) {
      if (rec.sprayCan < data.sprayCans.length) {
        final c = data.sprayCans[rec.sprayCan];
        put(sprayCanArt(c), 'GOTCAN', c);
      }
    }
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
