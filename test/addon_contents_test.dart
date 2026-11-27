import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:srb2_autonomi_launcher/models/game.dart';
import 'package:srb2_autonomi_launcher/services/addon_contents.dart';
import 'package:srb2_autonomi_launcher/services/app_activity.dart';
import 'package:srb2_autonomi_launcher/services/map_preview.dart';
import 'package:srb2_autonomi_launcher/services/server_files.dart';
import 'package:srb2_autonomi_launcher/ui/gametype_choice.dart';

import 'map_preview_test.dart' show buildWad, buildZip;

void main() {
  test('SOC gametype', () {
    final g = AddonAnalyzer.parseSocGametypes('GameType Hangout\nTypeOfLevel = Coop,Hangout\n'
        'Identifier = "hangout"\nRules = GTR_SPECTATORS|GTR_FRIENDLY\n'
        'Description = "Chill out from the battles."\n#\n');
    expect(g.single.name, 'Hangout');
    expect(g.single.identifier, 'hangout');
    expect(g.single.description, 'Chill out from the battles.');
    expect(g.single.levels, ['COOP', 'HANGOUT']);
  });

  test('Lua gametype, multi-line and one line', () {
    final multi = AddonAnalyzer.parseLuaGametypes('G_AddGametype({\n    name = "Hangout",\n'
        '    identifier = "hangout",\n    typeoflevel = TOL_COOP|TOL_HANGOUT,\n    description = "Relax."\n})');
    expect(multi.single.name, 'Hangout');
    expect(multi.single.identifier, 'hangout');
    expect(multi.single.levels, ['COOP', 'HANGOUT']);
    final one = AddonAnalyzer.parseLuaGametypes(
        'G_AddGametype({name = "Tag Plus", identifier = "tagplus", typeoflevel = TOL_TAG}) G_AddGametype({name="X"})');
    expect(one.map((g) => g.name), ['Tag Plus', 'X']);
  });

  test('Lua gametypes built as tables and registered in a loop (RingSlingerPlus)', () {
    final text = File('test/fixtures/rsp_gametype.lua').readAsStringSync(encoding: latin1);
    final g = AddonAnalyzer.parseLuaGametypes(text);
    expect(g.map((x) => x.name), ['FFA', 'Team - FFA', 'Hot Potato', 'HeadHunt', 'Duel', 'Duel Arena']);
    expect(g.map((x) => x.identifier), ['ffa', 'teamffa', 'hotpotato', 'headhunt', 'duel', 'duelarena']);
    expect(g.first.description, startsWith('Free For All Match mode'));
    expect(g[2].levels, ['HOTPOTATO', 'MATCH']);
    expect(g[4].description, startsWith('"1 VS 1", just between you.'));
    // Таблицы без G_AddGametype в аддоне — не режимы.
    expect(AddonAnalyzer.parseLuaGametypes(text, registers: false), isEmpty);
    // Цвет (name = ..., ramp = ...) рядом с G_AddGametype — не режим.
    expect(
        AddonAnalyzer.parseLuaGametypes('skincolors[SKINCOLOR_A] = {name = "A", ramp = {1}}\nG_AddGametype(x)'),
        isEmpty);
  });

  test('category: first match in the order characters, gametypes, maps, colors, misc', () async {
    final dir = await Directory.systemTemp.createTemp('contents_');
    addTearDown(() => dir.delete(recursive: true));
    final pack = p.join(dir.path, 'pack.pk3');
    await File(pack).writeAsBytes(buildZip([
      ('Lua/gt.lua', ascii.encode('G_AddGametype({name = "Hangout", identifier = "hangout"})')),
      ('Maps/MAP01.wad', buildWad([('MAP01', []), ('THINGS', [0])])),
    ]));
    final c = AddonAnalyzer.analyze(pack);
    expect(c.category, AddonCategory.gametypes);
    expect(c.maps, 1);
    // Поиск по содержимому: карта и режим.
    expect(c.matches('map01'), isTrue);
    expect(c.matches('hangout'), isTrue);
    expect(c.matches('sonic'), isFalse);

    final chars = p.join(dir.path, 'chars.wad');
    await File(chars).writeAsBytes(buildWad([('S_SKIN', ascii.encode('name = x\n')), ('S_END', [])]));
    expect(AddonAnalyzer.analyze(chars).category, AddonCategory.characters);
    expect(AddonAnalyzer.analyze(chars).characterNames, ['x (x)']);

    final lua = p.join(dir.path, 'colors.lua');
    await File(lua).writeAsString('skincolors[SKINCOLOR_A] = {name = "A", ramp = {1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16}}');
    expect(AddonAnalyzer.analyze(lua).category, AddonCategory.skincolors);
    expect(AddonAnalyzer.analyze(lua).matches('a'), isTrue);

    final misc = p.join(dir.path, 'misc.lua');
    await File(misc).writeAsString('print("hi")');
    expect(AddonAnalyzer.analyze(misc).category, AddonCategory.misc);
  });

  test('contents survive the disk cache (JSON)', () {
    const c = AddonContents(
      characterNames: ['Tangle (tangle)'],
      gametypes: [GametypeInfo('Hangout', 'hangout', 'Chill out', ['COOP', 'HANGOUT'])],
      mapNames: ['MAP01 Greenflower 1'],
      colors: [('Mint', [96, 97, 98])],
    );
    final back = AddonContents.fromJson(jsonDecode(jsonEncode(c.toJson())) as Map<String, Object?>);
    expect(back.characterNames, c.characterNames);
    expect([for (final g in back.gametypes) (g.name, g.identifier, g.description)], [('Hangout', 'hangout', 'Chill out')]);
    expect(back.gametypes.single.levels, ['COOP', 'HANGOUT']);
    expect(back.mapNames, c.mapNames);
    expect(back.colors.single.$1, 'Mint');
    expect(back.colors.single.$2, [96, 97, 98]);
    expect(back.category, AddonCategory.characters);
    expect(AddonContents.fromJson(const {}).category, AddonCategory.misc);
  });

  test('background work waits while the window is hidden', () async {
    await AppActivity.whenVisible(); // окно видно — сразу
    AppActivity.visible.value = false;
    var done = false;
    final wait = AppActivity.whenVisible().then((_) => done = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(done, isFalse);
    AppActivity.visible.value = true;
    await wait;
    expect(done, isTrue);
  });

  test('which gametypes a map supports (TypeOfLevel)', () {
    expect(Games.srb2.gametypeLevels('Co-op'), ['COOP']);
    expect(Games.srb2.gametypeLevels('hide & seek'), ['TAG']);
    expect(Games.srb2.gametypeLevels('Hangout'), isNull); // не встроенный
    expect(GameDef.normalizeLevelType('Single Player'), 'SOLO');
    expect(GameDef.normalizeLevelType('CO-OP'), 'COOP');
    expect(GameDef.normalizeLevelType('TOL_MATCH'), 'MATCH');
    // Карта GFZ: одиночная, co-op, competition, race.
    const gfz = ['Singleplayer', 'Co-op', 'Competition', 'Race'];
    expect(GameDef.levelFits(gfz, Games.srb2.gametypeLevels('Co-op')!), isTrue);
    expect(GameDef.levelFits(gfz, Games.srb2.gametypeLevels('Match')!), isFalse);
    expect(GameDef.levelFits(gfz, ['COOP', 'HANGOUT']), isTrue); // свой режим на co-op картах
    expect(GameDef.levelFits(const ['Match'], ['HOTPOTATO']), isFalse);
    expect(GameDef.levelFits(const [], ['MATCH']), isTrue); // режимы карты неизвестны
    expect(GameDef.levelFits(gfz, const []), isTrue); // режимы режима неизвестны
    expect(GameDef.levelFits(const ['Battle'], Games.srb2kart.gametypeLevels('Battle')!), isTrue);
  });

  test('gametypes offered for a map', () {
    const gfz = MapPreview('MAP01', 'Greenflower 1', null, types: ['Singleplayer', 'Co-op', 'Competition', 'Race']);
    const custom = [
      GametypeInfo('Hangout', 'hangout', '', ['COOP', 'HANGOUT']),
      GametypeInfo('Hot Potato', 'hotpotato', '', ['HOTPOTATO', 'MATCH']),
      GametypeInfo('Mystery', 'mystery', ''), // TypeOfLevel не знаем — не предлагаем
      GametypeInfo('hangout', 'hangout2', '', ['COOP']), // повтор имени
    ];
    final (builtIn, fitting) = gametypesForMap(Games.srb2, gfz, custom);
    expect(builtIn, ['Co-op', 'Competition', 'Race']);
    expect(fitting.map((g) => g.name), ['Hangout']);
    // Режимы карты неизвестны — предлагать нечего.
    final (none, noneCustom) = gametypesForMap(Games.srb2, const MapPreview('MAP02', '', null), custom);
    expect(none, isEmpty);
    expect(noneCustom, isEmpty);
  });

  test('analyzeAllInBackground streams batches with unsendable callback and LocalFileIndex.shared deduplicates', () async {
    final dir = Directory.systemTemp.createTempSync('srb2_addon_bg_');
    addTearDown(() => dir.deleteSync(recursive: true));

    final files = <String>[];
    for (var i = 0; i < 6; i++) {
      final path = p.join(dir.path, 'sub$i', 'char_$i.wad');
      Directory(p.dirname(path)).createSync(recursive: true);
      await File(path).writeAsBytes(buildWad([('S_SKIN', ascii.encode('name = c$i\n')), ('S_END', [])]));
      files.add(path);
    }

    // ReceivePort непередаваем через SendPort — замыкание onBatch не должно утечь в изолят.
    final port = ReceivePort();
    final streamed = <String, AddonContents>{};
    var calls = 0;
    try {
      final all = await AddonAnalyzer.analyzeAllInBackground(
        files,
        onBatch: (b) {
          port.sendPort;
          calls++;
          streamed.addAll(b);
        },
      );
      expect(all.keys, unorderedEquals(files));
      expect(streamed.keys, unorderedEquals(files));
      expect(calls, greaterThan(0));
      expect(all[files.first]!.category, AddonCategory.characters);
    } finally {
      port.close();
    }

    final results = await Future.wait([
      LocalFileIndex.shared(dir.path, force: true),
      LocalFileIndex.shared(dir.path),
    ]);
    expect(identical(results[0], results[1]), isTrue);
    expect(results[0].paths, unorderedEquals(files));
  });
}
