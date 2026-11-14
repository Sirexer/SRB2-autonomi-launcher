import 'dart:typed_data';

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:srb2_autonomi_launcher/services/game_progress.dart';

import 'map_preview_test.dart' show buildZip;

/// gamedata.dat SRB2 2.2 (формат G_SaveGameData); [legacy] — SRB2 2.1 /
/// Legacy: старый заголовок, байт modded, 16 доп. эмблем, 32 секрета, у
/// рекорда нет лишнего байта.
Uint8List gamedata({
  bool legacy = false,
  int playTime = 35 * 3600,
  Map<int, int> visited = const {},
  Set<int> collected = const {},
  Set<int> extra = const {},
  Set<int> unlocked = const {},
  int beaten = 0,
  Map<int, (int, int, int)> records = const {},
  Map<int, List<(int, int, int)>> nights = const {},
}) {
  final b = BytesBuilder();
  void u8(int v) => b.addByte(v);
  void u16(int v) => b.add((ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List());
  void u32(int v) => b.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
  void bits(int n, Set<int> set) {
    for (var i = 0; i < n; i += 8) {
      var v = 0;
      for (var j = 0; j < 8 && i + j < n; j++) {
        if (set.contains(i + j)) v |= 1 << j;
      }
      u8(v);
    }
  }

  u32(legacy ? GameData.compatId : GameData.id);
  u32(playTime);
  if (legacy) {
    u8(0); // modded
  } else {
    u32(0x12345678); // хэш мода
  }
  for (var i = 1; i <= GameData.numMaps; i++) {
    u8(visited[i] ?? 0);
  }
  bits(512, collected);
  bits(legacy ? 16 : 48, extra);
  bits(legacy ? 32 : 80, unlocked);
  bits(128, const {});
  u32(beaten);
  u32(0);
  u32(0);
  for (var i = 1; i <= GameData.numMaps; i++) {
    final r = records[i] ?? (0, 0, 0);
    u32(r.$1);
    u32(r.$2);
    u16(r.$3);
    if (!legacy) u8(0);
  }
  for (var i = 1; i <= GameData.numMaps; i++) {
    final n = nights[i];
    if (n == null) {
      u8(0);
      continue;
    }
    u8(n.length - 1);
    for (final (score, grade, time) in n) {
      u32(score);
      u8(grade);
      u32(time);
    }
  }
  return b.toBytes();
}

const soc = '''
Level 1
Levelname = Greenflower
Act = 1
TypeOfLevel = Singleplayer,Co-op
RecordAttack = true

Level 2
Levelname = Greenflower
Act = 2
TypeOfLevel = Singleplayer,Co-op
RecordAttack = true

Level 50
LevelName = Floral Field
TypeOfLevel = Singleplayer,NiGHTS
NiGHTSAttack = true

Level M0
LevelName = Jade Valley
TypeOfLevel = Match,Tag

Level Z0
Levelname = Tutorial
TypeOfLevel = Singleplayer
HideInStats = true

Emblem
Hint = Right in sight.\\\\Look up.
Type = Global
Tag = 0
MapNum = 1
Sprite = A
Color = SKINCOLOR_BLUE

Emblem
Type = Time
Var = 30*TICRATE
MapNum = 1
Sprite = T
Color = SKINCOLOR_GREY

Emblem
Type = NGrade
Var = GRADE_A
MapNum = 50
Sprite = Q
Color = SKINCOLOR_CYAN

ExtraEmblem 1
Name = Game Complete
Objective = Complete 1P Mode
Sprite = U

Unlockable 1
Name = Record Attack
Objective = Complete Greenflower Zone
Type = RecordAttack

Unlockable 2
Name = Play as Fang
Objective = Complete Arid Canyon Zone
NoChecklist = true
''';

void main() {
  test('map numbers and SOC numbers', () {
    expect(mapNumber('1'), 1);
    expect(mapNumber('MAP05'), 5);
    expect(mapNumber('A0'), 100);
    expect(mapNumber('M0'), 100 + 12 * 36);
    expect(mapNumber('Z0'), 100 + 25 * 36);
    expect(mapNumber('nope'), 0);
    expect(evalSocNumber('30*TICRATE'), 1050);
    expect(evalSocNumber('200'), 200);
    expect(evalSocNumber('GRADE_A'), 5);
    expect(formatTics(1729), '0:49.40');
    expect(formatTics(14915, hours: true), '0:07:06.14');
    expect(nightsGrade(6), 'S');
  });

  test('gamedata.dat: records, emblems, statistics levels and combined records', () {
    final data = GameData.parse(gamedata(
      playTime: 54016852,
      visited: {1: MapVisit.visited | MapVisit.beaten, 50: MapVisit.visited, 100 + 12 * 36: 1, 100 + 25 * 36: 1},
      collected: {0, 2},
      extra: {0},
      unlocked: {0},
      beaten: 10,
      records: {1: (12345, 1729, 200), 2: (500, 0, 10)},
      nights: {
        50: [(30000, 5, 1400), (30000, 5, 1400)],
      },
    ));
    expect(data.totalPlayTime, 54016852);
    expect(data.timesBeaten, 10);
    expect(data.records[1], (score: 12345, time: 1729, rings: 200));
    expect(data.nights[50]!.first.grade, 5);

    final defs = ProgressDefs()..addSoc(soc, main: true);
    // Как Statistics: одиночные, не HideInStats, посещённые.
    expect([for (final l in defs.statsLevels(data)) l.map], [1, 50]);
    expect(defs.levels[1]!.fullTitle, 'Greenflower Zone 1');
    expect(defs.emblems.length, 3);
    expect(defs.emblems[0].hint, 'Right in sight.\nLook up.');
    expect(defs.emblems[1].target, 1050);
    expect([for (final (i, e) in defs.emblemsOf(1)) '$i${e.sprite}'], ['0A', '1T']);
    expect(defs.unlockables[2]!.noChecklist, isTrue);

    final p = ProgressData(data, defs, 'gamedata.dat', DateTime(2026), const {});
    expect((p.emblemsCollected, p.emblemCount), (3, 4));
    expect(p.collected(0) && !p.collected(1) && p.collected(2), isTrue);
    // Greenflower 2 без времени — не закончен.
    expect(p.combined, (score: 12845, time: 1729, rings: 210, unfinished: 1));
  });

  test('not a gamedata.dat', () {
    expect(() => GameData.parse(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8])), throwsFormatException);
    expect(() => GameData.parse(Uint8List.sublistView(gamedata(), 0, 100)), throwsFormatException);
  });

  test('the progress name hash is the one the game writes', () {
    expect(GameData.nameHash('main'), 0x7C6FB7CE); // ванильный gamedata.dat
    expect(GameData.nameHash('DreamUniverse'), GameData.nameHash('dreamuniverse'));
  });

  test('addon SOC: secrets only after its own GameData, Clear wipes the game ones', () {
    final noData = ProgressDefs()
      ..addSoc(soc, main: true)
      ..addSoc('Emblem\nType = Global\nMapNum = 1\n\nClear All\n');
    expect(noData.gameData, isNull);
    expect(noData.emblems.length, 3); // без GameData игра их игнорирует
    expect(noData.levels.length, 5);

    final pack = ProgressDefs()
      ..addSoc(soc, main: true)
      ..addSoc('''MainCfg
GameData = MyPack.dat

Clear All

Level 1
LevelName = Mystic Woods
TypeOfLevel = Singleplayer
RecordAttack = true

Emblem
Type = Global
MapNum = 1
Sprite = A

Unlockable 1
ConditionSet = -1

Unlockable 2
Name = Bonus Stage
Objective = Get all emblems
ConditionSet = 5
''');
    expect(pack.gameData, 'mypack.dat');
    expect(pack.levels.keys, [1]);
    expect(pack.levels[1]!.name, 'Mystic Woods');
    expect(pack.emblems.length, 1);
    expect(pack.trackable, isTrue);
    expect([for (final u in pack.unlockables.values) if (u.listed) u.number], [2]);

    // Настройки сервера: GameData, Clear All и «открыть всё» — следить не за чем.
    final server = ProgressDefs()
      ..addSoc(soc, main: true)
      ..addSoc('Maincfg\r\nGamedata = DreamUniverse.dat\r\n\r\nCLEAR ALL\r\n\r\nLevel 99\r\nHidden = true\r\n\r\n'
          'Unlockable 1\r\nConditionSet = -1\r\n');
    expect(server.gameData, 'dreamuniverse.dat');
    expect(server.trackable, isFalse);
  });

  test('discovery: vanilla, level packs with their own GameData, files without an addon', () async {
    final dir = await Directory.systemTemp.createTemp('progress_');
    addTearDown(() => dir.delete(recursive: true));
    final base = p.join(dir.path, 'srb2.pk3');
    File(base).writeAsBytesSync(buildZip([('SOC/SOC_HEAD.txt', ascii.encode(soc))]));
    final packSoc = 'MainCfg\nGameData = mypack.dat\n\nClear All\n\nLevel 1\nLevelName = Mystic Woods\n'
        'TypeOfLevel = Singleplayer\nRecordAttack = true\n\nEmblem\nType = Global\nMapNum = 1\nSprite = A\n';
    final v2 = p.join(dir.path, 'MyPack-v2.pk3');
    File(v2).writeAsBytesSync(buildZip([('SOC/MAIN.soc', ascii.encode(packSoc))]));
    final v1 = p.join(dir.path, 'MyPack-v1.pk3');
    File(v1).writeAsBytesSync(buildZip([('SOC/MAIN.soc', ascii.encode(packSoc))]));
    final server = p.join(dir.path, 'DU_Server.pk3');
    File(server).writeAsBytesSync(buildZip([
      ('SOC/MAINCFG.soc', ascii.encode('Maincfg\nGamedata = DreamUniverse.dat\n\nCLEAR ALL\n\nUnlockable 1\nConditionSet = -1\n')),
    ]));
    final maps = p.join(dir.path, 'JustMaps.wad');
    File(maps).writeAsBytesSync(buildZip([('SOC/LEVELS.soc', ascii.encode('Level 1\nLevelName = X\n'))]));

    File(p.join(dir.path, 'gamedata.dat')).writeAsBytesSync(gamedata(collected: {0}));
    // Прогресс аддона: хэш имени «mypack».
    File(p.join(dir.path, 'mypack.dat')).writeAsBytesSync(gamedata(collected: {0})
      ..buffer.asByteData().setUint32(8, GameData.nameHash('mypack'), Endian.little));
    // Файл без аддона: с рекордом — показывается, пустой — нет.
    File(p.join(dir.path, 'oldpack.dat')).writeAsBytesSync(gamedata(records: {5: (100, 350, 10)})
      ..buffer.asByteData().setUint32(8, GameData.nameHash('oldpack'), Endian.little));
    File(p.join(dir.path, 'empty.dat')).writeAsBytesSync(gamedata()
      ..buffer.asByteData().setUint32(8, GameData.nameHash('empty'), Endian.little));
    File(p.join(dir.path, 'notdata.dat')).writeAsStringSync('hello');

    final packs = ProgressPack.discoverSync(dir.path, [base], [
      (title: 'My Pack', files: [v2], inQueue: false),
      (title: 'My Pack (old)', files: [v1], inQueue: true),
      (title: 'Dream Universe server', files: [server], inQueue: false),
      (title: 'Just maps', files: [maps], inQueue: false),
    ]);
    expect([for (final p in packs) p.id], ['gamedata.dat', 'mypack.dat', 'oldpack.dat']);
    final vanilla = packs[0];
    // Ванильный gamedata.dat с хэшем 0x12345678 — не «main»: чужой.
    expect((vanilla.started, vanilla.foreign, vanilla.emblems, vanilla.emblemsCollected), (true, true, 4, 1));
    final mine = packs[1];
    // Версия из очереди запуска важнее.
    expect((mine.title, mine.started, mine.foreign), ('My Pack (old)', true, false));
    expect(mine.files, [v1]);
    expect((mine.emblems, mine.emblemsCollected), (1, 1));
    expect(packs[2].orphan, isTrue);

    final data = ProgressData.loadSync(packs[2].gamedataPath, [base], const [], false);
    expect([for (final l in data.defs.statsLevels(data.data)) l.fullTitle], ['MAP05']);
    final notStarted = ProgressData.loadSync(p.join(dir.path, 'nope.dat'), [base], [v2]);
    expect((notStarted.modified, notStarted.defs.statsLevels(notStarted.data, unvisited: true).length), (null, 1));
  });

  test('multiplayer special stages are left out, unless they are the single player ones too', () {
    String level(int n, String name) => 'Level $n\nLevelName = $name\nTypeOfLevel = Singleplayer,Co-op\n\n';
    final data = GameData.parse(gamedata(visited: {for (final m in [50, 57, 60, 66, 67]) m: 1}));
    final vanilla = ProgressDefs()
      ..addSoc([for (final m in [50, 57, 60, 66, 67]) level(m, 'Stage $m')].join(), main: true);
    expect([for (final l in vanilla.statsLevels(data)) l.map], [50, 57, 67]);

    // SStage_Start = SMPStage_Start: те же этапы и в одиночной игре — остаются.
    final same = ProgressDefs()
      ..addSoc('MainCfg\nSStage_Start = 60\nSMPStage_Start = 60\n\n', main: true)
      ..addSoc([for (final m in [50, 57, 60, 66, 67]) level(m, 'Stage $m')].join(), main: true);
    expect([for (final l in same.statsLevels(data)) l.map], [50, 57, 60, 66, 67]);

    // Номер карты буквами: SMPStage_Start = A0 (100).
    final letters = ProgressDefs()..addSoc('MainCfg\nSMPStage_Start = A0\n\n', main: true);
    expect(letters.mpSpecialStageStart, 100);
  });

  test('a level pack shows its own levels, not the vanilla ones it did not clear', () async {
    final dir = await Directory.systemTemp.createTemp('progress_');
    addTearDown(() => dir.delete(recursive: true));
    String level(String n, String name) => 'Level $n\nLevelName = $name\nTypeOfLevel = Singleplayer\nRecordAttack = true\n\n';
    final base = p.join(dir.path, 'srb2.pk3');
    File(base).writeAsBytesSync(buildZip([
      ('SOC/SOC_HEAD.txt', ascii.encode([level('1', 'Greenflower'), level('2', 'Greenflower'), level('50', 'Floral Field')].join())),
    ]));
    // Пак без Clear Levels: свои карты A1 и 51 (свой спецэтап), эмблема на ванильной MAP02.
    final packSoc = 'MainCfg\nGameData = mine.dat\n\n${level('A1', 'Mystic Woods')}${level('51', 'Own Special')}'
        'Emblem\nType = Global\nMapNum = 2\nSprite = A\n';
    final pack = p.join(dir.path, 'Mine.pk3');
    File(pack).writeAsBytesSync(buildZip([
      ('SOC/MAIN.soc', ascii.encode(packSoc)),
      ('Maps/MAPA1.wad', ascii.encode('PWAD')),
      ('Maps/MAP51.wad', ascii.encode('PWAD')),
    ]));
    final data = ProgressData.loadSync(p.join(dir.path, 'mine.dat'), [base], [pack]);
    expect([for (final l in data.defs.statsLevels(data.data, unvisited: true)) l.map], [2, 51, 101]);
    // Сама игра — все уровни.
    final vanilla = ProgressData.loadSync(p.join(dir.path, 'gamedata.dat'), [base]);
    expect([for (final l in vanilla.defs.statsLevels(vanilla.data, unvisited: true)) l.map], [1, 2, 50]);
  });

  test('SRB2 Legacy (2.1): gamedata.dat without the record byte, emblems and secrets from the game code', () {
    final data = GameData.parse(gamedata(
      legacy: true,
      visited: {1: 3},
      collected: {0, 154},
      extra: {0},
      unlocked: {0},
      records: {1: (12345, 35 * 60, 150), 1035: (1, 2, 3)},
      nights: {50: [(90000, 5, 3500), (90000, 5, 3500)]},
    ));
    expect(data.modId, isNull);
    expect(data.records[1], (score: 12345, time: 2100, rings: 150));
    expect(data.records[1035], (score: 1, time: 2, rings: 3));
    expect(data.nights[50]!.first.grade, 5);
    expect((data.collected.length, data.extraCollected.length, data.unlocked.length), (512, 16, 32));

    final defs = ProgressDefs()..addLegacyDefaults();
    expect((defs.emblems.length, defs.extraEmblems.length), (155, 5));
    expect(defs.emblems.first.hint, startsWith('Go get your feet wet'));
    expect(defs.emblems[6].type, EmblemType.time);
    expect(defs.emblems[6].target, 20 * 35);
    // Заголовки меню (EXTRA LEVELS, BONUS LEVELS) — не секреты.
    expect(defs.unlockables.values.where((u) => u.listed).length, 15);
    expect(ProgressDefs.isLegacyGame([r'C:\Games\SRB2 Legacy\srb2.srb']), isTrue);
    expect(ProgressDefs.isLegacyGame(['/games/srb2/srb2.pk3']), isFalse);

    // Аддон со своим GameData: `Emblem 2` заменяет вторую эмблему, `Clear Emblems` — все.
    final pack = ProgressDefs()
      ..addLegacyDefaults()
      ..addSoc('MainCfg\nGameData = pack.dat\n\nEmblem 2\nType = Global\nMapNum = 5\nSprite = Z\n');
    expect((pack.emblems.length, pack.emblems[1].map, pack.emblems[1].fromAddon), (155, 5, true));
    final cleared = ProgressDefs()
      ..addLegacyDefaults()
      ..addSoc('MainCfg\nGameData = pack.dat\n\nClear Emblems\n\nEmblem 3\nType = Global\nMapNum = 7\n');
    expect((cleared.emblems.length, cleared.emblems[2].map), (3, 7));
  });

  test('SRB2Kart: kartdata.dat (matches, time and lap records), medals from the game code, race levels', () async {
    final b = BytesBuilder();
    void u8(int v) => b.addByte(v);
    void u32(int v) => b.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
    void bits(int n, Set<int> set) {
      for (var i = 0; i < n; i += 8) {
        var v = 0;
        for (var j = 0; j < 8 && i + j < n; j++) {
          if (set.contains(i + j)) v |= 1 << j;
        }
        u8(v);
      }
    }

    u32(GameData.compatId);
    u32(35 * 600); // время в игре
    u32(123); // матчей
    u8(0); // modded
    for (var i = 1; i <= GameData.numMaps; i++) {
      u8(i == 1 ? 3 : 0);
    }
    bits(512, {0, 24});
    bits(16, {0});
    bits(32, {0, 1});
    bits(128, const {});
    u32(2); // пройдено кубков
    u32(0);
    for (var i = 1; i <= GameData.numMaps; i++) {
      u32(i == 1 ? 3000 : 0); // время
      u32(i == 1 ? 980 : 0); // круг
    }
    final bytes = b.toBytes();
    final data = GameData.parseKart(bytes);
    expect((data.totalPlayTime, data.matchesPlayed, data.timesBeaten), (35 * 600, 123, 2));
    expect((data.records[1]!.time, data.bestLaps[1], data.records.length), (3000, 980, 1));
    expect((data.collected.length, data.extraCollected.length, data.unlocked.length), (512, 16, 32));
    expect(() => GameData.parseKart(Uint8List.fromList(bytes.sublist(0, 100))), throwsFormatException);

    final defs = ProgressDefs()..addKartDefaults();
    expect((defs.emblems.length, defs.extraEmblems.length, defs.unlockables.length), (110, 5, 7));
    // Медали Green Hills: золотая (время разработчиков) и серебряная.
    final gh = defs.emblemsOf(1);
    expect([for (final (_, e) in gh) (e.type, e.sprite, e.target)], [
      (EmblemType.time, 'A', 3021),
      (EmblemType.time, 'B', 110 * 35),
    ]);

    // Уровни — гоночные (TOL_RACE), без скрытых в меню и Statistics.
    defs.addSoc('Level 1\nLevelName = Green Hills\nTypeOfLevel = Race\nRecordAttack = true\n\n'
        'Level 2\nLevelName = Battle Map\nTypeOfLevel = Match\n\n'
        'Level 3\nLevelName = Hidden\nTypeOfLevel = Race\nHideInMenu = true\n\n'
        'Level 4\nLevelName = Dark Race\nTypeOfLevel = Race\nRecordAttack = true\n', main: true);
    expect([for (final l in defs.statsLevels(data, unvisited: true)) l.map], [1, 4]);
    // Сумма рекордов — по картам Record Attack, как в игре.
    final pd = ProgressData(data, defs, 'kartdata.dat', null, const {});
    expect((pd.combined.time, pd.combined.unfinished), (3000, 1));

    // Пак игры — kartdata.dat, а не gamedata.dat.
    final dir = await Directory.systemTemp.createTemp('kart_');
    addTearDown(() => dir.delete(recursive: true));
    File(p.join(dir.path, 'kartdata.dat')).writeAsBytesSync(bytes);
    final packs = ProgressPack.discoverSync(dir.path, const [], const [], kart: true, gameTitle: 'SRB2Kart');
    expect((packs.single.id, packs.single.started, packs.single.gamedataPath),
        (ProgressPack.vanillaId, true, p.join(dir.path, 'kartdata.dat')));
    expect(packs.single.emblems, 115); // 110 медалей + 5 доп. эмблем
    expect(packs.single.emblemsCollected, 3);
  });
}
