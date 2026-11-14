import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../models/skin_colors_data.dart';
import 'characters.dart';
import 'kart_progress_data.dart';
import 'legacy_progress_data.dart';
import 'map_preview.dart';

/// Прогресс одиночной игры SRB2 2.2: `gamedata.dat` из папки игры и
/// описания уровней, эмблем и секретов из SOC игры (srb2.pk3) — как экран
/// Statistics и Record Attack в игре. Пока только ванильная игра.

/// Флаги посещения карты (mapvisited, MV_*).
class MapVisit {
  static const visited = 1, beaten = 2, allEmeralds = 4, ultimate = 8, perfect = 16, perfectRecordAttack = 32;
  static const any = 63; // MV_MAX
}

/// Рекорд Record Attack: очки, время (тики, 35 в секунду), кольца.
typedef MainRecord = ({int score, int time, int rings});

/// Рекорд NiGHTS одного mare (0 — весь уровень): очки, оценка (0 F … 6 S), время.
typedef NightsMare = ({int score, int grade, int time});

/// Содержимое gamedata.dat (G_LoadGameData в SRB2 2.2).
class GameData {
  static const id = 0x86E4A27C; // GAMEDATA_ID
  static const compatId = 0xFCAFE211; // COMPAT_GAMEDATA_ID (ранние 2.2)
  static const numMaps = 1035;

  final int totalPlayTime;

  /// Хэш имени прогресса (timeattackfolder: «main» у игры, имя файла без
  /// `.dat` у аддона); null — старый формат, хэша нет.
  final int? modId;
  final List<int> mapVisited;
  final List<bool> collected;
  final List<bool> extraCollected;
  final List<bool> unlocked;
  final List<bool> achieved;
  final int timesBeaten, timesBeatenWithEmeralds, timesBeatenUltimate;
  final Map<int, MainRecord> records;
  final Map<int, List<NightsMare>> nights;

  /// SRB2Kart: сыграно матчей и лучший круг по картам (тики).
  final int matchesPlayed;
  final Map<int, int> bestLaps;

  GameData._(this.totalPlayTime, this.modId, this.mapVisited, this.collected, this.extraCollected, this.unlocked,
      this.achieved, this.timesBeaten, this.timesBeatenWithEmeralds, this.timesBeatenUltimate, this.records, this.nights,
      [this.matchesPlayed = 0, this.bestLaps = const {}]);

  /// Прогресса ещё нет (в аддон не играли).
  GameData.empty()
      : totalPlayTime = 0,
        modId = null,
        mapVisited = List.filled(numMaps, 0),
        collected = const [],
        extraCollected = const [],
        unlocked = const [],
        achieved = const [],
        timesBeaten = 0,
        timesBeatenWithEmeralds = 0,
        timesBeatenUltimate = 0,
        records = const {},
        nights = const {},
        matchesPlayed = 0,
        bestLaps = const {};

  /// Есть ли что показать: рекорды, собранные эмблемы или пройденные уровни.
  bool get hasProgress =>
      records.isNotEmpty ||
      nights.isNotEmpty ||
      collected.contains(true) ||
      extraCollected.contains(true) ||
      mapVisited.any((v) => v & MapVisit.beaten != 0);

  /// Хэш имени, как quickncasehash в игре: так она проверяет, что файл —
  /// прогресс именно этого аддона.
  static int nameHash(String name) {
    var x = 5381;
    for (final c in name.toLowerCase().codeUnits) {
      x = ((x * 33) ^ c) & 0xFFFFFFFF;
    }
    return x;
  }

  /// Разбор файла; FormatException — не тот формат или файл повреждён.
  ///
  /// Старый заголовок (0xFCAFE211) пишут и SRB2 2.1 / SRB2 Legacy, и ранние
  /// 2.2; у 2.1 после рекорда нет лишнего байта. Берём разбор, который
  /// прочёл файл ровно до конца.
  static GameData parse(Uint8List bytes) {
    (GameData, int)? first;
    FormatException? error;
    try {
      first = _parse(bytes, recordByte: true);
      if (first.$2 == bytes.length || first.$1.modId != null) return first.$1;
    } on FormatException catch (e) {
      error = e;
    }
    try {
      final (legacy, end) = _parse(bytes, recordByte: false);
      if (end == bytes.length || first == null) return legacy;
    } on FormatException catch (_) {
      if (first == null) throw error!;
    }
    return first!.$1;
  }

  /// kartdata.dat SRB2Kart (G_LoadGameData в Kart-Public): заголовок
  /// 0xFCAFE211, время в игре, сыграно матчей, байт modded, посещённые карты,
  /// эмблемы (512), доп. эмблемы (16), секреты (32), условия (128), пройдено
  /// игр (и со всеми изумрудами), рекорды карт — время и круг (u32 + u32).
  static GameData parseKart(Uint8List bytes) {
    final bd = ByteData.sublistView(bytes);
    var pos = 0;
    int u8() {
      if (pos + 1 > bytes.length) throw const FormatException('kartdata.dat is cut short');
      return bytes[pos++];
    }

    int u32() {
      if (pos + 4 > bytes.length) throw const FormatException('kartdata.dat is cut short');
      final v = bd.getUint32(pos, Endian.little);
      pos += 4;
      return v;
    }

    List<bool> bits(int n) {
      final out = <bool>[];
      while (out.length < n) {
        final b = u8();
        for (var j = 0; j < 8 && out.length < n; j++) {
          out.add((b >> j) & 1 == 1);
        }
      }
      return out;
    }

    if (bytes.length < 4 || u32() != compatId) throw const FormatException('Not an SRB2Kart kartdata.dat');
    final playTime = u32();
    final matches = u32();
    u8(); // modded
    final visited = [for (var i = 0; i < numMaps; i++) u8()];
    final collected = bits(512);
    final extra = bits(16);
    final unlocked = bits(32);
    final achieved = bits(128);
    final beaten = u32(), withEmeralds = u32();
    final records = <int, MainRecord>{};
    final laps = <int, int>{};
    for (var i = 0; i < numMaps; i++) {
      final time = u32(), lap = u32();
      if (time != 0) records[i + 1] = (score: 0, time: time, rings: 0);
      if (lap != 0) laps[i + 1] = lap;
    }
    return GameData._(playTime, null, visited, collected, extra, unlocked, achieved, beaten, withEmeralds, 0, records,
        const {}, matches, laps);
  }

  static (GameData, int) _parse(Uint8List bytes, {required bool recordByte}) {
    final bd = ByteData.sublistView(bytes);
    var pos = 0;
    void need(int n) {
      if (pos + n > bytes.length) throw const FormatException('gamedata.dat is cut short');
    }

    int u8() {
      need(1);
      return bytes[pos++];
    }

    int u16() {
      need(2);
      final v = bd.getUint16(pos, Endian.little);
      pos += 2;
      return v;
    }

    int u32() {
      need(4);
      final v = bd.getUint32(pos, Endian.little);
      pos += 4;
      return v;
    }

    List<bool> bits(int n) {
      final out = <bool>[];
      while (out.length < n) {
        final b = u8();
        for (var j = 0; j < 8 && out.length < n; j++) {
          out.add((b >> j) & 1 == 1);
        }
      }
      return out;
    }

    final version = u32();
    if (version != id && version != compatId) {
      throw const FormatException('Not an SRB2 gamedata.dat');
    }
    final compat = version == compatId;
    final playTime = u32();
    int? modId;
    if (compat) {
      u8(); // modded
    } else {
      modId = u32(); // хэш мода (timeattackfolder)
    }
    final visited = [for (var i = 0; i < numMaps; i++) u8()];
    final collected = bits(512);
    final extra = bits(compat ? 16 : 48);
    final unlocked = bits(compat ? 32 : 80);
    final achieved = bits(128);
    final beaten = u32(), withEmeralds = u32(), ultimate = u32();
    final records = <int, MainRecord>{};
    for (var i = 0; i < numMaps; i++) {
      final score = u32(), time = u32(), rings = u16();
      if (recordByte || !compat) u8();
      if (score != 0 || time != 0 || rings != 0) records[i + 1] = (score: score, time: time, rings: rings);
    }
    final nights = <int, List<NightsMare>>{};
    for (var i = 0; i < numMaps; i++) {
      final mares = u8();
      if (mares == 0) continue;
      nights[i + 1] = [
        for (var m = 0; m <= mares; m++) (score: u32(), grade: u8(), time: u32()),
      ];
    }
    return (
      GameData._(playTime, modId, visited, collected, extra, unlocked, achieved, beaten, withEmeralds, ultimate,
          records, nights),
      pos,
    );
  }
}

/// Уровень из SOC (Level N).
class ProgressLevel {
  final int map;
  String name = '';
  String subtitle = '';
  int act = 0;
  bool noZone = false;
  List<String> types = const [];
  bool recordAttack = false;
  bool nightsAttack = false;
  bool hideInStats = false;

  ProgressLevel(this.map);

  /// Одиночная игра (TOL_SP) — такие уровни показывает Statistics.
  bool get singlePlayer => types.any((t) => _levelType(t) == 'SOLO');
  bool get isNights => types.any((t) => _levelType(t) == 'NIGHTS');

  /// SRB2Kart: гоночная карта (TOL_RACE) — такие показывает Statistics.
  bool get race => types.any((t) => _levelType(t) == 'RACE');

  /// «Greenflower Zone 1», как в заголовке уровня: Zone — если нет NoZone,
  /// номер акта — если он есть.
  String get fullTitle {
    final zone = noZone || name.isEmpty ? '' : ' Zone';
    final a = act > 0 ? ' $act' : '';
    return '$name$zone$a';
  }

  static String _levelType(String t) {
    final n = t.toUpperCase().replaceFirst(RegExp(r'^TOL_'), '').replaceAll(RegExp(r'[^A-Z0-9]'), '');
    return n == 'SP' || n == 'SINGLE' || n == 'SINGLEPLAYER' ? 'SOLO' : n;
  }
}

/// Тип эмблемы (ET_* в m_cond.h).
enum EmblemType { global, skin, map, score, time, rings, nightsGrade, nightsTime, unknown }

class ProgressEmblem {
  /// Объявлена аддоном (не SOC самой игры).
  final bool fromAddon;

  ProgressEmblem({this.fromAddon = false});

  EmblemType type = EmblemType.unknown;
  int map = 0;
  int tag = 0;
  String sprite = 'A';
  String color = '';
  String hint = '';
  String variable = '';

  /// Цель для Score / Rings / NTime и т.п.: число; время — в тиках.
  int get target => evalSocNumber(variable);
}

class ExtraEmblem {
  String name = '';
  String objective = '';
  String sprite = 'A';
  String color = '';
}

class Unlockable {
  final int number;
  String name = '';
  String objective = '';
  String type = '';
  bool noChecklist = false;

  /// ConditionSet: -1 — открыт сразу (так серверные аддоны «открывают всё»).
  int conditionSet = 0;
  Unlockable(this.number);

  /// Настоящий секрет для чек-листа: с названием и условием.
  bool get listed => name.isNotEmpty && conditionSet >= 0 && type.toUpperCase() != 'HEADER';
}

/// Всё, что SOC игры говорит о прогрессе.
class ProgressDefs {
  final Map<int, ProgressLevel> levels = {};
  final List<ProgressEmblem> emblems = [];
  final List<ExtraEmblem> extraEmblems = [];
  final Map<int, Unlockable> unlockables = {};

  /// `GameData = …` из MainCfg (в нижнем регистре): свой файл прогресса
  /// аддона; null — не объявлен.
  String? gameData;

  /// Первый спецэтап (SStage_Start, их 7 и ещё один) и первый
  /// мультиплеерный спецэтап (SMPStage_Start, их 7) — как в G_SetGameModified.
  int specialStageStart = 50;
  int mpSpecialStageStart = 60;

  /// SRB2 2.1 / Legacy: эмблемы и секреты по умолчанию — из кода игры
  /// ([addLegacyDefaults]), цвета значков — из таблицы 2.1.
  bool legacy = false;

  /// SRB2Kart ([addKartDefaults]): уровни — гоночные (TOL_RACE), рекорды —
  /// время и круг, цвета значков — из таблицы Kart.
  bool kart = false;

  /// Эмблемы, дополнительные эмблемы и секреты SRB2 2.1 (в m_cond.c игры,
  /// не в SOC) — до SOC игры и аддона.
  void addLegacyDefaults() {
    legacy = true;
    _addCodeDefaults(legacyEmblems, legacyExtraEmblems, legacyUnlockables);
  }

  /// То же для SRB2Kart: медали (золотые — время разработчиков, серебряные),
  /// доп. эмблемы за матчи и секреты (кубки, Hard, Encore…).
  void addKartDefaults() {
    kart = true;
    _addCodeDefaults(kartEmblems, kartExtraEmblems, kartUnlockables);
  }

  void _addCodeDefaults(
      List<(EmblemType, int, String, String, String, String)> codeEmblems,
      List<(String, String, int, String, String)> codeExtra,
      List<(String, String, int, String, bool)> codeUnlockables) {
    for (final (type, map, sprite, color, variable, hint) in codeEmblems) {
      emblems.add(ProgressEmblem()
        ..type = type
        ..map = map
        ..sprite = sprite
        ..color = color
        ..variable = variable
        ..hint = hint);
    }
    for (final (name, objective, _, sprite, color) in codeExtra) {
      extraEmblems.add(ExtraEmblem()
        ..name = name
        ..objective = objective
        ..sprite = sprite
        ..color = color);
    }
    for (var i = 0; i < codeUnlockables.length; i++) {
      final (name, objective, conditionSet, type, noChecklist) = codeUnlockables[i];
      unlockables[i + 1] = Unlockable(i + 1)
        ..name = name
        ..objective = objective
        ..conditionSet = conditionSet
        ..type = type
        ..noChecklist = noChecklist;
    }
  }

  /// Файлы игры SRB2 2.1 / Legacy (главный файл — srb2.srb, у 2.2 — srb2.pk3).
  static bool isLegacyGame(List<String> gameFiles) =>
      gameFiles.any((f) => f.replaceAll('\\', '/').split('/').last.toLowerCase() == 'srb2.srb');

  /// Карты, которые есть в файлах левелпака (MAPxx в WAD, maps/ в PK3);
  /// null — смотрим саму игру (или у пака своих карт нет): всё показываем.
  Set<int>? packMaps;

  /// Уровень левелпака, а не игры: его карта есть в файлах пака или на нём
  /// эмблема пака. Заголовки ванильных уровней (и спецэтапов) остаются от
  /// srb2.pk3, если пак не сделал Clear Levels, — такие в прогрессе пака
  /// не показываем.
  bool isPackLevel(int map) =>
      packMaps == null || packMaps!.contains(map) || emblems.any((e) => e.fromAddon && e.map == map);

  /// Мультиплеерный спецэтап, который не входит в одиночные спецэтапы: в
  /// прогрессе его не показываем.
  bool isMultiplayerSpecialStage(int map) =>
      map >= mpSpecialStageStart &&
      map <= mpSpecialStageStart + 6 &&
      !(map >= specialStageStart && map <= specialStageStart + 7);

  /// Разбирает SOC [text] (блоки Level, Emblem, ExtraEmblem, Unlockable и
  /// MainCfg) — эмблемы нумеруются по порядку объявления, как в игре. Как в
  /// DEH_LoadDehackedFile: аддон ([main] = false) может задать эмблемы,
  /// секреты и `Clear …`, только объявив раньше свой GameData.
  void addSoc(String text, {bool main = false}) {
    Object? current;
    var mainCfg = false;
    bool secretsAllowed() => main || gameData != null;
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
        final arg = parts.length > 1 ? parts[1] : '';
        mainCfg = word == 'MAINCFG';
        if (word == 'CLEAR' && secretsAllowed()) _clear(arg.toUpperCase());
        current = switch (word) {
          'LEVEL' when mapNumber(arg) > 0 => levels.putIfAbsent(mapNumber(arg), () => ProgressLevel(mapNumber(arg))),
          // `Emblem N` заменяет N-ю эмблему (как reademblemdata), без номера — следующая.
          'EMBLEM' when secretsAllowed() =>
            _put(emblems, int.tryParse(arg), 512, ProgressEmblem(fromAddon: !main), ProgressEmblem.new),
          'EXTRAEMBLEM' when secretsAllowed() => _put(extraEmblems, int.tryParse(arg), 48, ExtraEmblem(), ExtraEmblem.new),
          'UNLOCKABLE' when secretsAllowed() && int.tryParse(arg) != null =>
            unlockables.putIfAbsent(int.parse(arg), () => Unlockable(int.parse(arg))),
          _ => null,
        };
        continue;
      }
      final key = line.substring(0, eq).trim().toUpperCase();
      final value = line.substring(eq + 1).trim();
      if (mainCfg) {
        final word = value.split(RegExp(r'\s')).first;
        switch (key) {
          case 'GAMEDATA' when word.isNotEmpty:
            gameData = word.toLowerCase();
          case 'SSTAGE_START' when mapNumber(word) > 0:
            specialStageStart = mapNumber(word);
          case 'SMPSTAGE_START' when mapNumber(word) > 0:
            mpSpecialStageStart = mapNumber(word);
        }
        continue;
      }
      switch (current) {
        case ProgressLevel l:
          switch (key) {
            case 'LEVELNAME':
              l.name = value;
            case 'SUBTITLE':
              l.subtitle = value;
            case 'ACT':
              l.act = int.tryParse(value) ?? 0;
            case 'NOZONE':
              l.noZone = _yes(value);
            case 'TYPEOFLEVEL':
              l.types = [for (final t in value.split(RegExp(r'[,|]'))) if (t.trim().isNotEmpty) t.trim()];
            case 'RECORDATTACK':
              l.recordAttack = _yes(value);
            case 'NIGHTSATTACK':
              l.nightsAttack = _yes(value);
            case 'HIDEINSTATS':
              l.hideInStats = _yes(value);
            case 'HIDEINMENU' when kart && _yes(value):
              l.hideInStats = true; // Kart прячет из Statistics и скрытое в меню
          }
        case ProgressEmblem e:
          switch (key) {
            case 'TYPE':
              e.type = switch (value.toUpperCase()) {
                'GLOBAL' => EmblemType.global,
                'SKIN' => EmblemType.skin,
                'MAP' => EmblemType.map,
                'SCORE' => EmblemType.score,
                'TIME' => EmblemType.time,
                'RINGS' => EmblemType.rings,
                'NGRADE' => EmblemType.nightsGrade,
                'NTIME' => EmblemType.nightsTime,
                _ => EmblemType.unknown,
              };
            case 'MAPNUM':
              e.map = mapNumber(value);
            case 'TAG':
              e.tag = int.tryParse(value) ?? 0;
            case 'SPRITE':
              e.sprite = value.isEmpty ? 'A' : value[0].toUpperCase();
            case 'COLOR':
              e.color = value;
            case 'HINT':
              e.hint = value.replaceAll(r'\\', '\n');
            case 'VAR':
              e.variable = value;
          }
        case ExtraEmblem e:
          switch (key) {
            case 'NAME':
              e.name = value;
            case 'OBJECTIVE':
              e.objective = value;
            case 'SPRITE':
              e.sprite = value.isEmpty ? 'A' : value[0].toUpperCase();
            case 'COLOR':
              e.color = value;
          }
        case Unlockable u:
          switch (key) {
            case 'NAME':
              u.name = value;
            case 'OBJECTIVE':
              u.objective = value;
            case 'TYPE':
              u.type = value;
            case 'NOCHECKLIST':
              u.noChecklist = _yes(value);
            case 'CONDITIONSET':
              u.conditionSet = int.tryParse(value) ?? 0;
          }
      }
    }
  }

  /// `Clear All` / `Clear Levels` / `Clear Emblems` и т.п. (clear_* в игре).
  void _clear(String what) {
    final all = what == 'ALL';
    if (all || what == 'UNLOCKABLES') unlockables.clear();
    if (all || what == 'EMBLEMS') emblems.clear();
    if (all || what == 'EXTRAEMBLEMS') extraEmblems.clear();
    if (all || what == 'LEVELS') levels.clear();
  }

  /// Есть что отслеживать: эмблемы или одиночные уровни с Record Attack /
  /// NiGHTS Attack. Нет — это не левелпак (например, настройки сервера,
  /// которые только «открывают всё»).
  bool get trackable =>
      emblems.isNotEmpty ||
      extraEmblems.isNotEmpty ||
      levels.values.any((l) => l.name.isNotEmpty && (kart ? l.race : l.singlePlayer && (l.recordAttack || l.nightsAttack)));

  /// Ставит [item] на место [number] (с 1; пропуски — пустыми), без номера
  /// или вне 1..[max] — в конец.
  static T _put<T>(List<T> list, int? number, int max, T item, T Function() empty) {
    if (number == null || number < 1 || number > max) {
      list.add(item);
      return item;
    }
    while (list.length < number) {
      list.add(empty());
    }
    list[number - 1] = item;
    return item;
  }

  static bool _yes(String v) {
    final u = v.trim().toUpperCase();
    return u.startsWith('T') || u.startsWith('Y') || u == 'ON' || (int.tryParse(u) ?? 0) != 0;
  }

  /// Эмблемы карты [map] с их номерами (номер — бит в gamedata).
  List<(int, ProgressEmblem)> emblemsOf(int map) => [
        for (var i = 0; i < emblems.length; i++)
          if (emblems[i].map == map) (i, emblems[i]),
      ];

  /// Уровни для статистики, как M_Statistics: с названием, одиночные, не
  /// HideInStats и посещённые.
  /// [unvisited] — и ещё не посещённые (в игре их в Statistics нет).
  /// Уровней в SOC нет (прогресс без аддона) — карты из рекордов.
  List<ProgressLevel> statsLevels(GameData data, {bool unvisited = false}) {
    if (levels.isEmpty) {
      final maps = {...data.records.keys, ...data.nights.keys}.toList()..sort();
      return [
        for (final m in maps)
          ProgressLevel(m)
            ..name = MapScanner.mapName(m)
            ..noZone = true
            ..types = const ['Singleplayer']
            ..recordAttack = data.records.containsKey(m),
      ];
    }
    return [
      for (final l in (levels.values.toList()..sort((a, b) => a.map - b.map)))
        if (l.name.isNotEmpty &&
            (kart ? l.race : l.singlePlayer) &&
            !l.hideInStats &&
            !isMultiplayerSpecialStage(l.map) &&
            isPackLevel(l.map) &&
            l.map <= data.mapVisited.length &&
            (unvisited || data.mapVisited[l.map - 1] & MapVisit.any != 0))
          l,
    ];
  }

  /// SOC из файлов [files] по порядку загрузки ([main] — файлы самой игры).
  void addFiles(List<AddonArchive> archives, {bool main = false}) {
    for (final a in archives) {
      for (final e in a.entries) {
        if (!isSocEntry(a, e) || e.size > 8 << 20) continue;
        try {
          addSoc(latin1.decode(a.read(e), allowInvalid: true), main: main);
        } catch (_) {}
      }
    }
  }

  /// SOC-запись архива, как их грузит игра: папка SOC/ в PK3, SOC_* и MAINCFG.
  static bool isSocEntry(AddonArchive a, ArchiveEntry e) => a.isZip
      ? e.lowerPath.startsWith('soc/') || e.name.startsWith('SOC_') || e.name == 'MAINCFG'
      : e.name.startsWith('SOC_') || e.name == 'MAINCFG' || e.name == 'OBJCTCFG';
}

/// Номер карты по записи SOC: `1`, `MAP01`, `A1`, `MAPA1` (M_MapNumber).
int mapNumber(String s) {
  var w = s.trim().toUpperCase();
  if (w.startsWith('MAP')) w = w.substring(3);
  final n = int.tryParse(w);
  if (n != null) return n > 0 && n <= GameData.numMaps ? n : 0;
  if (w.length != 2) return 0;
  final first = w.codeUnitAt(0) - 0x41;
  final c = w.codeUnitAt(1);
  final second = c >= 0x30 && c <= 0x39 ? c - 0x30 : (c >= 0x41 && c <= 0x5A ? c - 0x41 + 10 : -1);
  if (first < 0 || first > 25 || second < 0) return 0;
  return 100 + first * 36 + second;
}

/// Число из SOC: `200`, `30*TICRATE`, `GRADE_A`, `5*MUSICRATE` (тики).
int evalSocNumber(String s) {
  const consts = {
    'TICRATE': 35,
    'MUSICRATE': 1000,
    'GRADE_F': 0,
    'GRADE_E': 1,
    'GRADE_D': 2,
    'GRADE_C': 3,
    'GRADE_B': 4,
    'GRADE_A': 5,
    'GRADE_S': 6,
  };
  var result = 1;
  var any = false;
  for (final part in s.toUpperCase().split('*')) {
    final t = part.trim();
    final v = int.tryParse(t) ?? consts[t];
    if (v == null) return 0;
    result *= v;
    any = true;
  }
  return any ? result : 0;
}

/// Время в тиках → «0:49.40» (с часами — «1:02:03.04»).
String formatTics(int tics, {bool hours = false}) {
  final cs = (tics % 35) * 100 ~/ 35;
  final total = tics ~/ 35;
  String two(int v) => v.toString().padLeft(2, '0');
  if (hours) return '${total ~/ 3600}:${two(total ~/ 60 % 60)}:${two(total % 60)}.${two(cs)}';
  return '${total ~/ 60}:${two(total % 60)}.${two(cs)}';
}

/// Оценка NiGHTS буквой.
String nightsGrade(int g) => g >= 0 && g <= 6 ? 'FEDCBAS'[g] : '?';

/// Прогресс целиком: файл, SOC и картинки значков эмблем (PNG).
class ProgressData {
  final GameData data;
  final ProgressDefs defs;
  final String path;

  /// Когда игра сохранила файл; null — файла ещё нет (не играли).
  final DateTime? modified;

  /// `GOTITx|цвет` → значок собранной эмблемы, `NEEDIT` — несобранной,
  /// `EMBLICON` — значок в сводке.
  final Map<String, Uint8List> icons;

  ProgressData(this.data, this.defs, this.path, this.modified, this.icons);

  int get emblemCount => defs.emblems.length + defs.extraEmblems.length;
  int get emblemsCollected =>
      [for (var i = 0; i < defs.emblems.length; i++) if (i < data.collected.length && data.collected[i]) i].length +
      [for (var i = 0; i < defs.extraEmblems.length; i++) if (i < data.extraCollected.length && data.extraCollected[i]) i]
          .length;

  bool collected(int emblem) => emblem < data.collected.length && data.collected[emblem];

  /// Сумма рекордов по уровням Record Attack (M_DrawLevelStats): очки,
  /// время, кольца и сколько уровней без полного рекорда.
  ({int score, int time, int rings, int unfinished}) get combined {
    var score = 0, time = 0, rings = 0, unfinished = 0;
    for (final l in defs.levels.values) {
      // Kart (M_DrawLevelStats): сумма лучшего времени по картам Record
      // Attack (LF2_RECORDATTACK), без рекорда — «не пройдено».
      if (defs.kart) {
        if (!l.recordAttack || !defs.isPackLevel(l.map)) continue;
        final t = data.records[l.map]?.time ?? 0;
        if (t == 0) {
          unfinished++;
        } else {
          time += t;
        }
        continue;
      }
      if (!l.recordAttack || !defs.isPackLevel(l.map)) continue;
      final r = data.records[l.map];
      if (r == null) {
        unfinished++;
        continue;
      }
      score += r.score;
      time += r.time;
      rings += r.rings;
      if (r.score == 0 || r.time == 0 || r.rings == 0) unfinished++;
    }
    return (score: score, time: time, rings: rings, unfinished: unfinished);
  }

  /// Значок эмблемы спрайта [sprite] цвета [color]; null — нет картинки.
  Uint8List? icon(String sprite, String color, bool got) => got ? icons['GOTIT$sprite|$color'] : icons['NEEDIT'];

  /// Прогресс [gamedataPath] (файла может ещё не быть — пустой) с SOC и
  /// графикой файлов игры [gameFiles] и аддона [packFiles] (они грузятся
  /// после игры; их значки эмблем важнее).
  /// [gameSoc] = false — прогресс без аддона: уровней игры не берём (номера
  /// карт там чужие), только её графику.
  /// [kart] — SRB2Kart: kartdata.dat и медали из кода игры.
  static Future<ProgressData> load(String gamedataPath, List<String> gameFiles,
          [List<String> packFiles = const [], bool gameSoc = true, bool kart = false]) =>
      Isolate.run(() => loadSync(gamedataPath, gameFiles, packFiles, gameSoc, kart));

  static ProgressData loadSync(String gamedataPath, List<String> gameFiles,
      [List<String> packFiles = const [], bool gameSoc = true, bool kart = false]) {
    final file = File(gamedataPath);
    final exists = file.existsSync();
    final bytes = exists ? file.readAsBytesSync() : null;
    final data = bytes == null ? GameData.empty() : (kart ? GameData.parseKart(bytes) : GameData.parse(bytes));
    final defs = ProgressDefs();
    final base = [for (final f in gameFiles) if (AddonArchive.open(f) case final a?) a];
    final pack = [for (final f in packFiles) if (AddonArchive.open(f) case final a?) a];
    try {
      if (gameSoc && kart) {
        defs.addKartDefaults();
      } else if (gameSoc && ProgressDefs.isLegacyGame(gameFiles)) {
        defs.addLegacyDefaults();
      }
      if (gameSoc) defs.addFiles(base, main: true);
      defs.addFiles(pack);
      // Левелпак поверх игры: только его уровни (если у него есть свои карты).
      if (gameSoc && pack.isNotEmpty) {
        final own = {
          for (final a in pack)
            for (final name in MapScanner.mapNames(a))
              if (MapScanner.mapNumber(name) > 0) MapScanner.mapNumber(name),
        };
        if (own.isNotEmpty) defs.packMaps = own;
      }
      final icons = _icons([...base, ...pack], defs, gameFiles);
      return ProgressData(data, defs, gamedataPath, exists ? file.lastModifiedSync() : null, icons);
    } finally {
      for (final a in [...base, ...pack]) {
        a.close();
      }
    }
  }

  /// Значки эмблем: GOTITx в цвете эмблемы (как R_GetTranslationColormap
  /// TC_DEFAULT: индексы 96–111 — ramp цвета), NEEDIT и EMBLICON как есть.
  static Map<String, Uint8List> _icons(List<AddonArchive> archives, ProgressDefs defs, List<String> files) {
    final palette = MapScanner.findPalette(archives, files);
    final out = <String, Uint8List>{};
    if (palette == null) return out;
    Uint8List? lump(String name) {
      for (final a in archives.reversed) {
        final e = a.find(name);
        if (e == null) continue;
        try {
          return a.read(e);
        } catch (_) {}
      }
      return null;
    }

    Uint8List? draw(String name, List<int>? ramp) {
      final data = lump(name);
      if (data == null) return null;
      // PNG (у некоторых аддонов значки свои) — как есть, без перекраски.
      if (data.length > 8 && data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47) return data;
      final indexed = MapScanner.decodePatchIndexed(data);
      if (indexed == null) return null;
      // Цвет перекрашивает индексы 96–111 (2.2) или 160–175 (2.1).
      return CharacterScanner.render(
          indexed.$1, indexed.$2, indexed.$3, indexed.$4, palette, defs.legacy || defs.kart ? 160 : 96, ramp);
    }

    for (final name in ['NEEDIT', 'EMBLICON']) {
      if (draw(name, null) case final png?) out[name] = png;
    }
    final wanted = {
      for (final e in defs.emblems) (e.sprite, e.color),
      for (final e in defs.extraEmblems) (e.sprite, e.color),
    };
    for (final (sprite, color) in wanted) {
      final ramp = color.isEmpty
          ? null
          : CharacterScanner.findColor(
              defs.kart
                  ? VanillaSkinColors.srb2kart
                  : defs.legacy
                      ? VanillaSkinColors.srb2legacy
                      : VanillaSkinColors.srb2,
              color);
      if (draw('GOTIT$sprite', ramp) case final png?) out['GOTIT$sprite|$color'] = png;
    }
    return out;
  }
}

/// Аддон, у которого может быть свой прогресс: название, файлы (в порядке
/// загрузки), стоит ли он в очереди запуска.
typedef ProgressCandidate = ({String title, List<String> files, bool inQueue});

/// Чей прогресс показывать: ванильная игра, аддон со своим GameData или
/// файл прогресса, для которого аддон не найден.
class ProgressPack {
  /// Имя файла прогресса в нижнем регистре: `gamedata.dat` — игра.
  final String id;
  final String title;

  /// Файлы аддона (пусто — игра или аддон не найден).
  final List<String> files;
  final String gamedataPath;

  /// Файл прогресса есть (в аддон уже играли).
  final bool started;

  /// Файл прогресса без аддона.
  final bool orphan;

  /// Хэш в файле не совпал с именем — файл не от этого аддона.
  final bool foreign;
  final int emblems, emblemsCollected;

  /// Сколько раз пройдена игра (аддон) и сколько — в режиме Ultimate.
  final int timesBeaten, timesBeatenUltimate;

  /// Пройдена на 100%: игра пройдена и собраны все эмблемы (вместе с
  /// дополнительными); Ultimate для этого не нужен.
  bool get complete => timesBeaten > 0 && emblems > 0 && emblemsCollected >= emblems;

  const ProgressPack({
    required this.id,
    required this.title,
    required this.files,
    required this.gamedataPath,
    required this.started,
    this.orphan = false,
    this.foreign = false,
    this.emblems = 0,
    this.emblemsCollected = 0,
    this.timesBeaten = 0,
    this.timesBeatenUltimate = 0,
  });

  bool get vanilla => id == vanillaId;
  static const vanillaId = 'gamedata.dat';

  /// Ищет аддоны со своим прогрессом среди [candidates] (как в игре:
  /// `GameData` в MainCfg; без него игра прогресс аддона не сохраняет) и
  /// файлы прогресса без аддона в [gameFolder]. Аддоны без эмблем и без
  /// одиночных уровней с Record Attack (настройки сервера и т.п.)
  /// пропускаются. Первым — ванильная игра.
  /// [orphans] = false — без файлов прогресса, для которых аддон не найден.
  /// [gameTitle] — название ванильной игры в списке.
  /// [kart] — SRB2Kart: прогресс игры — kartdata.dat (id пака всё равно
  /// [vanillaId]), формат и медали — Kart.
  static Future<List<ProgressPack>> discover(
          String gameFolder, List<String> gameFiles, List<ProgressCandidate> candidates,
          {bool orphans = true, String gameTitle = 'Sonic Robo Blast 2', bool kart = false}) =>
      Isolate.run(() =>
          discoverSync(gameFolder, gameFiles, candidates, orphans: orphans, gameTitle: gameTitle, kart: kart));

  /// Файл прогресса самой игры: gamedata.dat, у SRB2Kart — kartdata.dat.
  static String vanillaFile({bool kart = false}) => kart ? 'kartdata.dat' : vanillaId;

  static List<ProgressPack> discoverSync(
      String gameFolder, List<String> gameFiles, List<ProgressCandidate> candidates,
      {bool orphans = true, String gameTitle = 'Sonic Robo Blast 2', bool kart = false}) {
    List<String> socTexts(List<String> files) {
      final out = <String>[];
      for (final f in files) {
        final a = AddonArchive.open(f);
        if (a == null) continue;
        try {
          for (final e in a.entries) {
            if (!ProgressDefs.isSocEntry(a, e) || e.size > 8 << 20) continue;
            try {
              out.add(latin1.decode(a.read(e), allowInvalid: true));
            } catch (_) {}
          }
        } finally {
          a.close();
        }
      }
      return out;
    }

    GameData? readData(String path) {
      try {
        final f = File(path);
        if (!f.existsSync()) return null;
        return kart ? GameData.parseKart(f.readAsBytesSync()) : GameData.parse(f.readAsBytesSync());
      } catch (_) {
        return null;
      }
    }

    String nameOf(String file) {
      final n = file.toLowerCase();
      return n.endsWith('.dat') ? n.substring(0, n.length - 4) : n;
    }

    ProgressPack summary(String id, String title, List<String> files, ProgressDefs? defs,
        {bool orphan = false, String? file}) {
      final path = file ?? '$gameFolder${Platform.pathSeparator}$id';
      final data = readData(path);
      final foreign = data?.modId != null && data!.modId != GameData.nameHash(id == vanillaId ? 'main' : nameOf(id));
      final p = defs == null ? null : ProgressData(data ?? GameData.empty(), defs, path, null, const {});
      return ProgressPack(
        id: id,
        title: title,
        files: files,
        gamedataPath: path,
        started: data != null,
        orphan: orphan,
        foreign: foreign,
        timesBeaten: data?.timesBeaten ?? 0,
        timesBeatenUltimate: data?.timesBeatenUltimate ?? 0,
        emblems: p?.emblemCount ?? 0,
        emblemsCollected: p == null
            ? [...?data?.collected, ...?data?.extraCollected].where((b) => b).length
            : p.emblemsCollected,
      );
    }

    final baseTexts = socTexts(gameFiles);
    final legacy = !kart && ProgressDefs.isLegacyGame(gameFiles);
    ProgressDefs defsWith(List<String> packTexts) {
      final defs = ProgressDefs();
      if (kart) defs.addKartDefaults();
      if (legacy) defs.addLegacyDefaults();
      for (final t in baseTexts) {
        defs.addSoc(t, main: true);
      }
      for (final t in packTexts) {
        defs.addSoc(t);
      }
      return defs;
    }

    final out = [
      summary(vanillaId, gameTitle, const [], defsWith(const []),
          file: '$gameFolder${Platform.pathSeparator}${vanillaFile(kart: kart)}'),
    ];
    final seen = <String>{vanillaId, vanillaFile(kart: kart)};
    // Сначала из очереди запуска: одна и та же игра у разных версий аддона.
    final ordered = [...candidates.where((c) => c.inQueue), ...candidates.where((c) => !c.inQueue)];
    for (final c in ordered) {
      final texts = socTexts(c.files);
      if (!texts.any((t) => t.toLowerCase().contains('gamedata'))) continue;
      final defs = defsWith(texts);
      final id = defs.gameData;
      if (id == null || !seen.add(id) || !defs.trackable) continue;
      out.add(summary(id, c.title, c.files, defs));
    }

    // Файлы прогресса без аддона — если в них есть что показать.
    if (!orphans) return out;
    try {
      for (final f in Directory(gameFolder).listSync().whereType<File>()) {
        final id = f.uri.pathSegments.last.toLowerCase();
        if (!id.endsWith('.dat') || seen.contains(id)) continue;
        final data = readData(f.path);
        if (data == null || data.modId != GameData.nameHash(nameOf(id)) || !data.hasProgress) continue;
        seen.add(id);
        out.add(summary(id, f.uri.pathSegments.last, const [], null, orphan: true, file: f.path));
      }
    } catch (_) {}
    return out;
  }
}
