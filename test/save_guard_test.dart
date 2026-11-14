import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:srb2_autonomi_launcher/services/game_progress.dart';
import 'package:srb2_autonomi_launcher/services/ring_progress.dart';
import 'package:srb2_autonomi_launcher/services/save_guard.dart';

/// gamedata.dat SRB2 2.2 с временем в игре [playTime] (тики).
Uint8List gamedata(int playTime) {
  final b = BytesBuilder();
  void u32(int v) => b.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
  u32(GameData.id);
  u32(playTime);
  u32(GameData.nameHash('main'));
  b.add(Uint8List(GameData.numMaps)); // visited
  b.add(Uint8List(64 + 6 + 10 + 16)); // эмблемы, доп. эмблемы, секреты, условия
  u32(1);
  u32(0);
  u32(0);
  b.add(Uint8List(GameData.numMaps * 11)); // рекорды
  b.add(Uint8List(GameData.numMaps)); // NiGHTS
  return b.toBytes();
}

/// ringdata.dat: заголовок и UBJSON `{playtime: {total: N}}`.
Uint8List ringdata(int playTime) {
  final b = BytesBuilder();
  b.add((ByteData(4)..setUint32(0, RingData.versionMajor, Endian.little)).buffer.asUint8List());
  b.add([0, 0]);
  void key(String k) => b.add([0x69, k.length, ...ascii.encode(k)]); // i<len><name>
  b.addByte(0x7B); // {
  key('playtime');
  b.addByte(0x7B);
  key('total');
  b.addByte(0x6C); // l: int32 big-endian
  b.add((ByteData(4)..setInt32(0, playTime)).buffer.asUint8List());
  b.addByte(0x7D);
  b.addByte(0x7D);
  return b.toBytes();
}

/// Слот одиночной игры: "version N" в 16 байтах, данные, маркер 0x1d.
Uint8List savegame({int prefix = 0}) => Uint8List.fromList([
      ...List.filled(prefix, 1),
      ...ascii.encode('version 202'),
      ...List.filled(5, 0),
      1, 2, 3, 0x1d,
    ]);

/// WAD с одним lump'ом [name].
Uint8List wad(String name, String text) {
  final data = ascii.encode(text);
  final b = BytesBuilder();
  void u32(int v) => b.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
  b.add(ascii.encode('PWAD'));
  u32(1);
  u32(12 + data.length);
  b.add(data);
  u32(12);
  u32(data.length);
  b.add([...ascii.encode(name), ...List.filled(8 - name.length, 0)]);
  return b.toBytes();
}

void main() {
  late Directory tmp;
  late String game;

  /// Проверка файлов игры [gameId] и левелпаков с [gameData].
  Future<List<SaveEvent>> run(String gameId, {required bool repair, List<String> gameData = const []}) =>
      SaveGuard.check(gameId, game, repair: repair, only: SaveGuard.targetsFor(gameId, gameData));

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('save_guard_test');
    game = p.join(tmp.path, 'game');
    Directory(game).createSync();
    SaveGuard.rootOverride = p.join(tmp.path, 'backups');
    SaveGuard.settle = Duration.zero;
    SaveGuard.enabled = true;
    SaveGuard.resetMemory();
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  File file(String name) => File(p.join(game, name));
  List<FileSystemEntity> damaged() {
    final d = Directory(p.join(tmp.path, 'backups', 'Damaged'));
    return d.existsSync() ? d.listSync() : const [];
  }

  test('what is a save and when it is whole', () {
    expect(SaveGuard.kindOf('srb2', 'GameData.dat'), SaveKind.srbData);
    expect(SaveGuard.kindOf('srb2legacy', 'srb2sav3.ssg'), SaveKind.srbSave);
    expect(SaveGuard.kindOf('srb2kart', 'kartdata.dat'), SaveKind.kartData);
    expect(SaveGuard.kindOf('drrr', 'ringprofiles.prf'), SaveKind.ringProfiles);
    expect(SaveGuard.kindOf('drrr', 'gpringsav.bkp'), SaveKind.ringSave);
    expect(SaveGuard.kindOf('drrr', 'ringdata.dat.bak'), isNull);
    expect(SaveGuard.kindOf('srb2', 'srb2.pk3'), isNull);

    expect(SaveGuard.validate(SaveKind.srbData, gamedata(700)), (ok: true, playTime: 700));
    expect(SaveGuard.validate(SaveKind.srbData, gamedata(700).sublist(0, 5000)).ok, isFalse); // обрезан
    expect(SaveGuard.validate(SaveKind.srbData, Uint8List(20000)).ok, isFalse); // нули
    expect(SaveGuard.validate(SaveKind.ringData, ringdata(42)), (ok: true, playTime: 42));
    expect(SaveGuard.validate(SaveKind.ringData, ringdata(42).sublist(0, 20)).ok, isFalse);
    expect(SaveGuard.validate(SaveKind.srbSave, savegame()).ok, isTrue);
    expect(SaveGuard.validate(SaveKind.ringSave, savegame(prefix: 1)).ok, isTrue);
    expect(SaveGuard.validate(SaveKind.srbSave, savegame().sublist(0, 18)).ok, isFalse);
    expect(SaveGuard.validate(SaveKind.srbSave, Uint8List(64)).ok, isFalse);
  });

  test('a damaged file is put aside and replaced by the last whole copy', () async {
    file('gamedata.dat').writeAsBytesSync(gamedata(1000));
    file('srb2sav1.ssg').writeAsBytesSync(savegame());
    file('notes.txt').writeAsStringSync('not a save');
    expect(await run('srb2', repair: true), isEmpty);
    final copies = await SaveGuard.backups('srb2', game);
    expect([for (final b in copies) (b.file, b.playTime)], [('gamedata.dat', 1000), ('srb2sav1.ssg', null)]);

    // ПК выключился во время записи: файл из нулей, сохранение обрезано.
    file('gamedata.dat').writeAsBytesSync(Uint8List(300));
    file('srb2sav1.ssg').writeAsBytesSync(savegame().sublist(0, 10));
    SaveGuard.resetMemory();
    final events = await run('srb2', repair: true);
    expect([for (final e in events) (e.type, e.file)],
        unorderedEquals([(SaveEventType.restored, 'gamedata.dat'), (SaveEventType.restored, 'srb2sav1.ssg')]));
    expect(file('gamedata.dat').readAsBytesSync(), gamedata(1000));
    expect(file('srb2sav1.ssg').readAsBytesSync(), savegame());
    // Повреждённые — в одной папке, с датой и игрой в имени.
    expect(damaged().length, 2);
    expect(damaged().map((e) => p.basename(e.path)), everyElement(contains(' srb2 ')));
    expect(File(events.first.brokenCopy!).existsSync(), isTrue);
  });

  test('background check only backs up, never repairs', () async {
    file('gamedata.dat').writeAsBytesSync(gamedata(1000));
    await run('srb2', repair: true);
    file('gamedata.dat').writeAsBytesSync(Uint8List(300));
    file('gamedata.dat').setLastModifiedSync(DateTime.now().subtract(const Duration(minutes: 1)));
    SaveGuard.resetMemory();
    expect(await run('srb2', repair: false), isEmpty);
    expect(file('gamedata.dat').lengthSync(), 300);
    expect(damaged(), isEmpty);
  });

  test('less play time than in the copy: the copy stays until the player decides', () async {
    file('gamedata.dat').writeAsBytesSync(gamedata(5000));
    await run('srb2', repair: true);
    file('gamedata.dat').writeAsBytesSync(gamedata(10));
    SaveGuard.resetMemory();
    final events = await run('srb2', repair: true);
    expect(events.single.type, SaveEventType.decreased);
    expect((events.single.backupPlayTime, events.single.currentPlayTime), (5000, 10));
    expect((await SaveGuard.backups('srb2', game)).single.playTime, 5000);

    // «Восстановить копию»: нынешний файл откладывается как замененный.
    final moved = await SaveGuard.restore('srb2', game, 'gamedata.dat');
    expect(moved, endsWith('(replaced)'));
    expect(file('gamedata.dat').readAsBytesSync(), gamedata(5000));

    // «Это я сбросил»: копия — нынешний файл.
    file('gamedata.dat').writeAsBytesSync(gamedata(10));
    SaveGuard.resetMemory();
    final again = await run('srb2', repair: true);
    await SaveGuard.keepCurrent(again.single);
    expect((await SaveGuard.backups('srb2', game)).single.playTime, 10);
    SaveGuard.resetMemory();
    expect(await run('srb2', repair: true), isEmpty);
  });

  test("Ring Racers: the game's own .bak is used when it is newer", () async {
    file('ringdata.dat').writeAsBytesSync(ringdata(100));
    await run('drrr', repair: true);
    file('ringdata.dat.bak').writeAsBytesSync(ringdata(200));
    file('ringdata.dat').writeAsBytesSync(ringdata(300).sublist(0, 12));
    SaveGuard.resetMemory();
    final e = (await run('drrr', repair: true)).single;
    expect((e.type, e.fromGameBackup, e.backupPlayTime), (SaveEventType.restored, true, 200));
    expect(file('ringdata.dat').readAsBytesSync(), ringdata(200));
  });

  test('damaged without a copy: reported once, nothing is touched', () async {
    file('kartdata.dat').writeAsBytesSync(Uint8List(100));
    file('other.dat').writeAsBytesSync(Uint8List(100)); // не сохранение игры и без копии
    final e = await run('srb2kart', repair: true);
    expect([for (final x in e) (x.type, x.file)], [(SaveEventType.brokenNoBackup, 'kartdata.dat')]);
    expect(await run('srb2kart', repair: true), isEmpty);
    expect(file('kartdata.dat').lengthSync(), 100);
    expect(damaged(), isEmpty);
  });

  test('only the files of what is launched are checked', () async {
    final vanilla = SaveGuard.targetsFor('srb2', const []);
    expect(vanilla.wants('srb2', 'gamedata.dat'), isTrue);
    expect(vanilla.wants('srb2', 'srb2sav12.ssg'), isTrue);
    expect(vanilla.wants('srb2', 'mypack.dat'), isFalse);
    expect(vanilla.wants('srb2', 'mypack1.ssg'), isFalse);
    final pack = SaveGuard.targetsFor('srb2', const ['mypack.dat']);
    expect(pack.wants('srb2', 'MyPack.dat'), isTrue);
    expect(pack.wants('srb2', 'mypack3.ssg'), isTrue);
    expect(pack.wants('srb2', 'gamedata.dat'), isTrue); // игра пишет и его, переключаясь на GameData пака
    expect(pack.wants('srb2', 'otherpack.dat'), isFalse);
    final ring = SaveGuard.targetsFor('drrr', const ['custom.dat']);
    expect([for (final n in ['ringdata.dat', 'ringprofiles.prf', 'gpringsav.bkp', 'custom.dat', 'gpcustom.bkp', 'x.dat'])
        ring.wants('drrr', n)], [true, true, true, true, true, false]);

    file('gamedata.dat').writeAsBytesSync(gamedata(1));
    file('mypack.dat').writeAsBytesSync(gamedata(2));
    file('otherpack.dat').writeAsBytesSync(Uint8List(10)); // повреждён, но не нужен
    expect(await run('srb2', repair: true), isEmpty);
    expect([for (final b in await SaveGuard.backups('srb2', game)) b.file], ['gamedata.dat']);
    expect(await run('srb2', repair: true, gameData: ['mypack.dat']), isEmpty);
    expect([for (final b in await SaveGuard.backups('srb2', game)) b.file], ['gamedata.dat', 'mypack.dat']);
  });

  test('GameData of the launched files, from MainCfg', () async {
    final soc = File(p.join(tmp.path, 'pack.soc'))..writeAsStringSync('MainCfg\nGameData = MyPack.dat\n');
    final w = File(p.join(tmp.path, 'pack.wad'))..writeAsBytesSync(wad('MAINCFG', 'MAINCFG Category\nGAMEDATA = other.dat'));
    final plain = File(p.join(tmp.path, 'chars.wad'))..writeAsBytesSync(wad('SOC_CHAR', 'Character 1\nName = x'));
    expect(await SaveGuard.gameDataOf([soc.path, w.path, plain.path, p.join(tmp.path, 'missing.pk3')]),
        {'mypack.dat', 'other.dat'});
    // Второй раз — из кэша (файлы не менялись).
    expect(await SaveGuard.gameDataOf([w.path]), {'other.dat'});
  });

  test('Progress tab: a damaged file can be replaced by its copy', () async {
    file('gamedata.dat').writeAsBytesSync(gamedata(900));
    await run('srb2', repair: true);
    file('gamedata.dat').writeAsBytesSync(gamedata(900).sublist(0, 100));
    final source = await SaveGuard.sourceFor('srb2', game, 'gamedata.dat');
    expect((source?.fromGame, source?.check.playTime), (false, 900));
    final e = await SaveGuard.repair('srb2', game, 'gamedata.dat');
    expect(e?.type, SaveEventType.restored);
    expect(file('gamedata.dat').readAsBytesSync(), gamedata(900));
    expect(damaged().length, 1);
    expect(await SaveGuard.sourceFor('srb2', game, 'nothing.dat'), isNull);
  });

  test('turned off: nothing happens', () async {
    SaveGuard.enabled = false;
    file('gamedata.dat').writeAsBytesSync(gamedata(1));
    expect(await run('srb2', repair: true), isEmpty);
    expect(await SaveGuard.backups('srb2', game), isEmpty);
  });
}
