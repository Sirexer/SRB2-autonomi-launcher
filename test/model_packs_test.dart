import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:srb2_autonomi_launcher/models/game.dart';
import 'package:srb2_autonomi_launcher/services/map_preview.dart';
import 'package:srb2_autonomi_launcher/services/model_packs.dart';

import 'map_preview_test.dart' show buildZip;

/// Папка набора: список и файлы (путь в папке моделей → содержимое).
Directory makePack(Directory parent, String name, String dat, Map<String, String> files,
    {String datName = 'models.dat', String folder = 'models'}) {
  final dir = Directory(p.join(parent.path, name))..createSync(recursive: true);
  File(p.join(dir.path, datName)).writeAsStringSync(dat);
  for (final e in files.entries) {
    File(p.joinAll([dir.path, folder, ...e.key.split('/')]))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(e.value);
  }
  return dir;
}

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('models');
    ModelLibrary.rootOverride = Directory(p.join(tmp.path, 'library'));
  });
  tearDown(() {
    ModelLibrary.rootOverride = null;
    tmp.deleteSync(recursive: true);
  });

  test('models.dat is read like the game does: a bad line stops the rest', () {
    final ok = ModelDat.parse('SONIC  CHERRI2/SONIC.md3 3.0 0.0\r\n\r\nRING OBJE/RING.md3\t1.5 -2\n', ModelFormat.srb2);
    expect([for (final l in ok.lines) l.text], ['SONIC CHERRI2/SONIC.md3 3.0 0.0', 'RING OBJE/RING.md3 1.5 -2']);
    expect(ok.stopLine, isNull);

    final comment = ModelDat.parse('RING OBJE/RING.md3 1 0\n# my models\nBUZZ ENMY/BUZZ.md3 1 0\n', ModelFormat.srb2);
    expect((comment.lines.length, comment.stopLine, comment.stopReason), (1, 2, 'number'));

    final longPath = ModelDat.parse('RING A/VERY/LONG/PATH/TO/THE/RING/MODEL.md3 1 0', ModelFormat.srb2);
    expect((longPath.lines.length, longPath.stopReason), (0, 'path'));

    // SRB2Kart читает имя до 19 символов, SRB2 — до 25.
    const name = 'TWENTYCHARACTERSNAME';
    expect(ModelDat.parse('$name a.md3 1 0', ModelFormat.srb2kart).stopReason, 'name');
    expect(ModelDat.parse('$name a.md3 1 0', ModelFormat.srb2).lines.length, 1);
  });

  test('characters and objects: PLAYER prefix, sprite names are 4 characters', () {
    final srb2 = ModelFormat.srb2, kart = ModelFormat.srb2kart;
    expect([for (final n in ['SONIC', 'metalsonic', 'PLAYERFANG', 'FANG', 'RING', 'BUZZ', 'AMY']) srb2.isSkin(n)],
        [true, true, true, false, false, false, true]);
    // SRB2Kart не знает PLAYER: PLAYERFANG — просто длинное имя скина.
    expect((kart.isSkin('PLAYERFANG'), kart.isSkin('KART')), (true, false));
  });

  test('model formats of the games', () {
    expect((Games.srb2.models!.datFile, Games.srb2kart.models!.datFile, Games.drrr.models!.nameMax), ('models.dat', 'mdls.dat', 23));
    expect((Games.srb2legacy.models!.datFile, Games.srb2legacy.models!.md3), ('md2.dat', false));
    final blankart = Games.fromDefinition({
      'id': 'blankart_test',
      'name': 'BlanKart',
      'base': 'srb2kart',
      'models': {'file': 'models.dat', 'folder': 'models', 'name_max': 25, 'extra_files': ['blanmodels.dat']},
    });
    expect((blankart.models!.datFile, blankart.models!.folder, blankart.models!.nameMax), ('models.dat', 'models', 25));
    expect(blankart.models!.extraDatFiles, ['blanmodels.dat']);
    // Не задано — как у основы (SRB2Kart не знает PLAYER).
    expect(blankart.models!.playerPrefix, isFalse);
    expect(Games.fromDefinition({'id': 'no_models', 'name': 'X', 'base': 'srb2', 'models': false}).models, isNull);
    // Без "models" — как у основы.
    final fork = Games.fromDefinition({'id': 'kart_fork', 'name': 'Fork', 'base': 'srb2kart'});
    expect(fork.models!.datFile, 'mdls.dat');
  });

  test('adding a pack: only the files in models.dat, names spelled as in the list', () async {
    final src = makePack(tmp, 'Cherri', 'SONIC CHERRI2/SONIC.md3 3.0 0.0\r\nAMY CHERRI2/AMY.md3 3.0 0.0\r\nROSY CHERRI2/AMY.md3 3.0 0.0\r\nGONE OBJE/GONE.md3 1 0\r\n', {
      'CHERRI2/SONIC.md3': 'sonic',
      'CHERRI2/SONIC.png': 'sonic png',
      'CHERRI2/SONIC_Blend.png': 'blend', // регистр не как в списке
      'CHERRI2/AMY.md3': 'amy',
      'PLAY/UNUSED.md3': 'unused',
    });
    final lib = await ModelLibrary.load(Games.srb2);
    final pack = await lib.add(src.path);
    expect(pack.name, 'Cherri');
    final byName = {for (final m in pack.models) m.key: m};
    expect((byName['SONIC']!.hasModel, byName['SONIC']!.hasTexture, byName['SONIC']!.hasBlend), (true, true, true));
    expect((byName['AMY']!.hasTexture, byName['GONE']!.hasModel), (false, false));
    expect(File(pack.file('CHERRI2/SONIC_blend.png')).readAsStringSync(), 'blend');
    expect(File(pack.file('PLAY/UNUSED.md3')).existsSync(), isFalse);
    expect(pack.notes, ['unused:1']);

    // Перечитывается из библиотеки.
    final again = await ModelLibrary.load(Games.srb2);
    expect([for (final x in again.packs) x.name], ['Cherri']);
  });

  test('a pack from a zip with a folder inside; SRB2Kart uses mdls', () async {
    final zip = File(p.join(tmp.path, 'kart.zip'))
      ..writeAsBytesSync(buildZip([
        ('Kart Models/mdls.dat', utf8.encode('sonic K/SONIC.md3 1 0\n')),
        ('Kart Models/mdls/K/SONIC.md3', utf8.encode('k')),
        ('Kart Models/mdls/K/sonic.png', utf8.encode('t')),
      ]));
    final lib = await ModelLibrary.load(Games.srb2kart);
    final pack = await lib.add(zip.path);
    expect((pack.name, pack.models.single.hasModel, pack.models.single.hasTexture), ('kart', true, true));

    expect(() => lib.add(makePack(tmp, 'empty', '', {}, datName: 'readme.txt').path), throwsA(isA<FormatException>()));
  });

  test('versions: order of packs, manual choice, off; one pack for the game', () async {
    final a = makePack(tmp, 'A', 'SONIC S/SONIC.md3 3.0 0.0\nRING O/RING.md3 1 0\n',
        {'S/SONIC.md3': 'a-sonic', 'S/SONIC.png': 'a', 'O/RING.md3': 'a-ring', 'O/RING.png': 'r'});
    final b = makePack(tmp, 'B', 'SONIC S/SONIC.md3 2.5 0.0\nTAILS S/TAILS.md3 3 0\n',
        {'S/SONIC.md3': 'b-sonic', 'S/SONIC.png': 'b', 'S/SONIC_blend.png': 'bb', 'S/TAILS.md3': 'b-tails'});
    final lib = await ModelLibrary.load(Games.srb2);
    final packA = await lib.add(a.path);
    final packB = await lib.add(b.path); // добавленный последним — первый
    expect([for (final x in lib.packs) x.name], ['B', 'A']);

    var choices = {for (final c in lib.choices()) c.key: c};
    expect(choices.keys, ['RING', 'SONIC', 'TAILS']);
    expect((choices['SONIC']!.conflict, choices['SONIC']!.chosen!.$1.id), (true, packB.id));

    // Своя версия: Соник из A; одинаковые пути S/SONIC.md3 не затирают друг друга.
    await lib.choose('SONIC', packA.id);
    var build = lib.build();
    expect([for (final l in build.lines) l.text], [
      'RING O/RING.md3 1 0',
      'SONIC S/SONIC.md3 3.0 0.0',
      'TAILS S/TAILS.md3 3 0',
    ]);
    expect(build.problems, {'TAILS': [ModelProblem.missingTexture]});

    // Выключить Тейлза; набор A выключен — Соник снова из B.
    await lib.choose('TAILS', '');
    lib.disabled.add(packA.id);
    await lib.save();
    choices = {for (final c in lib.choices()) c.key: c};
    expect((choices['SONIC']!.chosen!.$1.id, choices['TAILS']!.chosen, choices.containsKey('RING')), (packB.id, null, false));
    build = lib.build();
    expect([for (final l in build.lines) l.text], ['SONIC S/SONIC.md3 2.5 0.0']);
    expect([for (final f in build.files) f.dest], ['S/SONIC.md3', 'S/SONIC.png', 'S/SONIC_blend.png']);
  });

  test('by pack order a version without a model file is skipped', () async {
    final top = makePack(tmp, 'Top', 'ARMF L/SHIELD_NONE.md2 0.0 0.0\n', {});
    final low = makePack(tmp, 'Low', 'ARMF OBJE/ARMF.md3 3 0\n', {'OBJE/ARMF.md3': 'm'});
    final lib = await ModelLibrary.load(Games.srb2);
    final lowPack = await lib.add(low.path);
    await lib.add(top.path);
    final c = lib.choices().single;
    expect((c.conflict, c.chosen!.$1.id, c.manual), (true, lowPack.id, false));
    expect([for (final l in lib.build().lines) l.text], ['ARMF OBJE/ARMF.md3 3 0']);
  });

  test('build: same path from two packs goes to the pack folder; long paths get shorter', () {
    ModelPack pack(String id, List<PackModel> models) =>
        ModelPack(id: id, name: id, dir: p.join(tmp.path, id), models: models, bytes: 0, added: DateTime(2026));
    final a = pack('a', [const PackModel(ModelLine('SONIC', 'PLAY/SONIC.md3', '3', '0'))]);
    final b = pack('b', [
      const PackModel(ModelLine('METALSONIC', 'PLAY/SONIC.md3', '3', '0')),
      const PackModel(ModelLine('KNUCKLES', 'CHARACTERS/KNUX/KNUCKLES.md3', '3', '0')),
      const PackModel(ModelLine('FANG', 'CHARACTERS/FANG/VERYLONGNAME.md3', '3', '0')),
      const PackModel(ModelLine('ROSY', 'PLAY/SONIC.md3', '3', '0')),
    ]);
    final choices = [
      for (final (pk, m) in [(a, a.models[0]), ...[for (final m in b.models) (b, m)]]) ModelChoice(m.key, [(pk, m)], (pk, m)),
    ];
    final build = ModelLibrary.planBuild(ModelFormat.srb2, choices, [a, b]);
    expect({for (final l in build.lines) l.name: l.path}, {
      'SONIC': 'PLAY/SONIC.md3',
      'METALSONIC': 'P2/PLAY/SONIC.md3',
      'KNUCKLES': 'CHARACTERS/KNUX/KNUCKLES.md3',
      'FANG': 'P2/VERYLONGNAME.md3', // P2/CHARACTERS/FANG/… — длиннее 31
      'ROSY': 'P2/PLAY/SONIC.md3', // та же модель — тот же файл
    });
    expect(build.files.where((f) => f.dest.endsWith('.md3')).length, 4);
  });

  test('install: old models go to a backup; roll back; save a zip', () async {
    final game = Directory(p.join(tmp.path, 'game'))..createSync();
    // Что стояло в игре до лаунчера.
    makePack(tmp, 'game', 'RING OLD/RING.md3 1 0\n', {'OLD/RING.md3': 'old'});
    final src = makePack(tmp, 'Pack', 'SONIC S/SONIC.md3 3 0\n', {'S/SONIC.md3': 'new', 'S/SONIC.png': 'png'});
    final lib = await ModelLibrary.load(Games.srb2);
    await lib.add(src.path);
    final build = lib.build();

    await lib.install(game.path, build);
    expect(File(p.join(game.path, 'models.dat')).readAsStringSync(), 'SONIC S/SONIC.md3 3 0\r\n');
    expect(File(p.join(game.path, 'models', 'S', 'SONIC.md3')).readAsStringSync(), 'new');
    final now = await lib.installed(game.path);
    expect((now.models, now.installed != null), (1, true));
    expect(now.packs, ['Pack']);
    var backups = await lib.backups(game.path);
    expect(backups.single.models, 1);
    expect(File(p.join(backups.single.dir, 'models', 'OLD', 'RING.md3')).readAsStringSync(), 'old');

    // Откат: старое вернулось, поставленное — в новой копии.
    await lib.rollback(game.path, backups.single);
    expect(File(p.join(game.path, 'models.dat')).readAsStringSync(), 'RING OLD/RING.md3 1 0\n');
    expect((await lib.installed(game.path)).installed, isNull);
    backups = await lib.backups(game.path);
    expect(backups.length, 1);
    expect(File(p.join(backups.single.dir, 'models', 'S', 'SONIC.md3')).existsSync(), isTrue);

    // Zip: тот же список и папка.
    final zipPath = p.join(tmp.path, 'out.zip');
    await lib.saveZip(build, zipPath);
    final zip = AddonArchive.open(zipPath)!;
    try {
      expect([for (final e in zip.entries) e.path], ['models.dat', 'models/S/SONIC.md3', 'models/S/SONIC.png']);
      expect(utf8.decode(zip.read(zip.entries[1])), 'new');
    } finally {
      zip.close();
    }
  });

  test('SRB2 Legacy: md2.dat and the md2 folder, only MD2 models', () async {
    expect((Games.srb2legacy.models!.datFile, Games.srb2legacy.models!.folder, Games.srb2legacy.models!.nameMax), ('md2.dat', 'md2', 19));
    final zip = File(p.join(tmp.path, 'jeck.zip'))
      ..writeAsBytesSync(buildZip([
        ('md2.dat', utf8.encode('POINTY PLAY/PSONIC.md2 3.0 0.0\r\nRING OBJE/RING.md3 1 0\r\n')),
        ('md2/PLAY/PSONIC.md2', utf8.encode('m')),
        ('md2/PLAY/PSONIC.png', utf8.encode('t')),
        ('md2/OBJE/RING.md3', utf8.encode('m')),
      ]));
    final lib = await ModelLibrary.load(Games.srb2legacy);
    final pack = await lib.add(zip.path);
    expect(pack.models.map((m) => m.hasModel), [true, true]);
    final build = lib.build();
    expect([for (final l in build.lines) l.text], ['POINTY PLAY/PSONIC.md2 3.0 0.0']);
    expect(build.problems['RING'], contains(ModelProblem.md3NotSupported));
    expect(lib.brokenIn(pack), 1);
    final game = Directory(p.join(tmp.path, 'legacy'))..createSync();
    await lib.install(game.path, build);
    expect(File(p.join(game.path, 'md2.dat')).readAsStringSync(), 'POINTY PLAY/PSONIC.md2 3.0 0.0\r\n');
    expect(File(p.join(game.path, 'md2', 'PLAY', 'PSONIC.md2')).existsSync(), isTrue);
  });

  test('a zip without a models folder: paths start next to models.dat', () async {
    final zip = File(p.join(tmp.path, 'LFMAIN.zip'))
      ..writeAsBytesSync(buildZip([
        ('models.dat', utf8.encode('SONIC LFMAIN/SONICV3.md3 3.0 0.0\r\nGONE LFMAIN/NEO.md2 3 0\r\n')),
        ('LFMAIN/SONICV3.md3', utf8.encode('model')),
        ('LFMAIN/SONICV3.png', utf8.encode('png')),
      ]));
    final lib = await ModelLibrary.load(Games.srb2);
    final pack = await lib.add(zip.path);
    expect([for (final m in pack.models) (m.key, m.hasModel, m.hasTexture)], [('SONIC', true, true), ('GONE', false, false)]);
    expect(File(pack.file('LFMAIN/SONICV3.md3')).readAsStringSync(), 'model');
    expect(pack.notes, isEmpty); // сам models.dat — не «лишний файл»

    // Модели без файлов можно убрать из набора.
    expect(lib.brokenIn(pack), 1);
    expect(await lib.cleanPack(pack), 1);
    expect((await ModelLibrary.load(Games.srb2)).packs.single.models.map((m) => m.key), ['SONIC']);
  });

  test('the game list: what the game reads, cleaning it, rolling the cleaning back', () async {
    final game = Directory(p.join(tmp.path, 'game'))..createSync();
    const dat = 'SONIC PLAY/SONIC.md3 3 0\r\nAMY PLAY/AMY.md3 3 0\r\nRING obje/ring.md3 1 0\r\n# old\r\nTAILS PLAY/TAILS.md3 3 0\r\n';
    makePack(tmp, 'game', dat, {'PLAY/SONIC.md3': 's', 'OBJE/RING.md3': 'r', 'PLAY/TAILS.md3': 't'});
    final lib = await ModelLibrary.load(Games.srb2);
    final g = (await lib.gameModels(game.path))!;
    expect((g.stopLine, g.broken, g.missing, g.wrongCase, g.needsCleaning), (4, 1, 1, 1, true));
    // Игра читает до строки с комментарием: TAILS ниже не загружается.
    expect(g.active.keys, ['SONIC', 'AMY', 'RING']);
    expect(g.active['RING']!.found, 'OBJE/RING.md3');

    expect(await lib.cleanGame(game.path), 2); // комментарий и AMY без файла
    expect(File(p.join(game.path, 'models.dat')).readAsStringSync(),
        'SONIC PLAY/SONIC.md3 3 0\r\nRING OBJE/RING.md3 1 0\r\nTAILS PLAY/TAILS.md3 3 0\r\n');
    expect((await lib.gameModels(game.path))!.needsCleaning, isFalse);
    // Копия — только список; папка моделей на месте.
    final backups = await lib.backups(game.path);
    expect((backups.single.listOnly, backups.single.models), (true, 3));
    expect(File(p.join(game.path, 'models', 'PLAY', 'SONIC.md3')).existsSync(), isTrue);

    await lib.rollback(game.path, backups.single);
    expect(File(p.join(game.path, 'models.dat')).readAsStringSync(), dat);
    expect(File(p.join(game.path, 'models', 'PLAY', 'SONIC.md3')).existsSync(), isTrue);
  });

  test('changes not in the game yet', () {
    const planned = [ModelLine('SONIC', 'S/SONIC.md3', '3', '0'), ModelLine('RING', 'O/RING.md3', '1', '0')];
    GameModels game(List<(String, String?)> lines) => GameModels([
          for (final (i, (text, found)) in lines.indexed)
            () {
              final t = text.split(' ');
              return GameModelLine(i + 1, text, ModelLine(t[0], t[1], t[2], t[3]), found);
            }(),
        ], null);
    expect(ModelLibrary.pendingChanges(planned, null), 2);
    expect(ModelLibrary.pendingChanges(planned, game([('SONIC s/sonic.md3 3 0', 's/sonic.md3'), ('RING O/RING.md3 1 0', 'O/RING.md3')])), 0);
    // Другой масштаб, файла нет, лишняя модель в игре — по одной.
    expect(
        ModelLibrary.pendingChanges(planned, game([
          ('SONIC S/SONIC.md3 2.5 0', 'S/SONIC.md3'),
          ('RING O/RING.md3 1 0', null),
          ('TAILS T/TAILS.md3 3 0', 'T/TAILS.md3'),
        ])),
        3);
  });

  test('zip writer: CRC-32 and deflate read back', () {
    expect(ZipWriter.crc32(utf8.encode('123456789')), 0xCBF43926);
    final path = p.join(tmp.path, 'a.zip');
    final big = Uint8List.fromList(List.filled(5000, 65));
    ZipWriter(path)
      ..add('a/big.txt', big)
      ..add('b.png', Uint8List.fromList([1, 2, 3]), compress: false)
      ..close();
    final zip = AddonArchive.open(path)!;
    try {
      expect(zip.entries.first.method, 8);
      expect(zip.read(zip.entries.first), big);
      expect(zip.read(zip.entries.last), [1, 2, 3]);
    } finally {
      zip.close();
    }
  });

  test('nested zip folders, backslashes, and sourceKey persistence work', () async {
    final zip = File(p.join(tmp.path, 'PEPPERMODELS-v1.12.zip'))
      ..writeAsBytesSync(buildZip([
        (r'PEPPERMODELS-v1.12\PEPPERMODELS\models.dat', utf8.encode('SONIC PLAY/SONIC.md3 2.0 0.0\r\n')),
        (r'PEPPERMODELS-v1.12\PEPPERMODELS\models\PLAY\SONIC.md3', utf8.encode('md3')),
        (r'PEPPERMODELS-v1.12\PEPPERMODELS\models\PLAY\SONIC.png', utf8.encode('tex')),
      ]));
    final lib = await ModelLibrary.load(Games.srb2);
    final pack = await lib.add(zip.path, name: 'Paper Models 1.12', sourceKey: 'mod:key:1');
    expect(pack.models.length, 1);
    expect(pack.models.single.hasModel, isTrue);
    expect(pack.models.single.hasTexture, isTrue);
    expect(pack.sourceKey, 'mod:key:1');
    expect((await ModelLibrary.load(Games.srb2)).packs.single.sourceKey, 'mod:key:1');
  });

  test('falls back to README txt and supports multiple versions inside one pack', () async {
    final zip = File(p.join(tmp.path, 'PEPPER-txt.zip'))
      ..writeAsBytesSync(buildZip([
        (
          'Read Please!.txt',
          utf8.encode(
            'SONIC PEPPERMODELS/PREVIEW/SONIC.md3 2.5 0.0\r\n'
            'TSWP PEPPERMODELS/PREVIEW/BATTLE/TSWP.md3 2.5 0.0\r\n'
            '------------- Put these into your models.dat file -------------\r\n'
            ' PEPPERMODELS/BONUS/SONIC.md3 2.4 0.0\r\n',
          ),
        ),
        ('PEPPERMODELS/PREVIEW/SONIC.md3', utf8.encode('md3-sonic-preview')),
        ('PEPPERMODELS/PREVIEW/SONIC.png', utf8.encode('png-sonic')),
        ('PEPPERMODELS/SONIC.md3', utf8.encode('md3-sonic-main')),
        ('PEPPERMODELS/BONUS/SONIC.md3', utf8.encode('md3-sonic-bonus')),
        ('PEPPERMODELS/PREVIEW/BATTLE/TSWP.md3', utf8.encode('md3-tswp')),
      ]));
    final lib = await ModelLibrary.load(Games.srb2);
    final pack = await lib.add(zip.path);

    // SONIC должен получить 3 версии внутри одного пака (основная PREVIEW — первая/выбранная).
    final choices = lib.choices();
    final sonic = choices.firstWhere((c) => c.key == 'SONIC');
    expect(sonic.conflict, isTrue);
    expect(sonic.chosen!.$2.line.path, 'PEPPERMODELS/PREVIEW/SONIC.md3');
    expect(sonic.candidates.map((c) => c.$2.line.path).toSet(), {
      'PEPPERMODELS/PREVIEW/SONIC.md3',
      'PEPPERMODELS/SONIC.md3',
      'PEPPERMODELS/BONUS/SONIC.md3',
    });

    // Пользователь выбирает бонусную версию внутри того же пака — выбор сохраняется и попадает в сборку.
    await lib.choose('SONIC', '${pack.id}|PEPPERMODELS/BONUS/SONIC.md3');
    final reloaded = await ModelLibrary.load(Games.srb2);
    final chosenBonus = reloaded.choices().firstWhere((c) => c.key == 'SONIC');
    expect(chosenBonus.manual, isTrue);
    expect(chosenBonus.chosen!.$2.line.path, 'PEPPERMODELS/BONUS/SONIC.md3');

    // Сборка автоматически укорачивает путь длиннее ModelFormat.pathMax (31).
    final build = reloaded.build();
    expect(build.lines.any((l) => l.key == 'TSWP' && l.path.length <= ModelFormat.pathMax), isTrue);
  });
}
