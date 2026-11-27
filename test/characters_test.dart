import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:srb2_autonomi_launcher/models/game.dart';
import 'package:srb2_autonomi_launcher/services/characters.dart';
import 'package:srb2_autonomi_launcher/services/map_preview.dart';

import 'map_preview_test.dart' show buildWad, buildZip, patch2x2, palette, fakePng;

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('chars_'));
  tearDown(() => dir.delete(recursive: true));

  test('S_SKIN fields: one word per value, comments', () {
    final f = CharacterScanner.parseSkin('# comment\r\nname = Sonic\nrealname = Metal_Sonic  // x\n// hidden = 1\nfacewant = SONWANT\n');
    expect(f['name'], 'Sonic');
    expect(f['realname'], 'Metal_Sonic');
    expect(f['facewant'], 'SONWANT');
    expect(f.containsKey('hidden'), isFalse);
  });

  test('PNG encoder writes valid chunks', () {
    final png = MapScanner.encodePng(1, 1, Uint8List.fromList([255, 0, 0, 255]));
    expect(png.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    expect(ascii.decode(png.sublist(12, 16)), 'IHDR');
    expect(png.sublist(png.length - 4), [0xAE, 0x42, 0x60, 0x82]); // CRC блока IEND
  });

  test('WAD: skins with S_END, XTRAC0 icon from the skin range, palette', () async {
    final path = p.join(dir.path, 'player.dta');
    await File(path).writeAsBytes(buildWad([
      ('PLAYPAL', palette()),
      ('S_SKIN', ascii.encode('name = sonic\nrealname = Sonic\n')),
      ('PLAYA1', [0]),
      ('XTRAC0', patch2x2()),
      ('S_END', []),
      ('S_SKIN2', ascii.encode('name = tails\n')),
      ('PLAYA1', [0]),
      ('S_END', []),
      ('XTRAC0', fakePng), // вне скина — не его иконка
    ]));
    final chars = CharacterScanner.scanAll([path], const []);
    expect(chars.map((c) => c.name), ['sonic', 'tails']);
    expect(chars[0].realname, 'Sonic');
    expect(chars[0].icon!.sublist(1, 4), ascii.encode('PNG'));
    expect(chars[1].realname, 'tails');
    expect(chars[1].icon, isNull);
  });

  test('PK3: several skins in folders without S_END, Kart face lumps; order across files', () async {
    final base = p.join(dir.path, 'characters.pk3');
    await File(base).writeAsBytes(buildZip([
      ('Skins/S_SKIN', ascii.encode('name = amy\n')),
      ('Skins/XTRAC0.png', fakePng),
    ]));
    final addon = p.join(dir.path, 'CL_Pack.pk3');
    await File(addon).writeAsBytes(buildZip([
      ('skins/char1/S_SKIN', ascii.encode('name = Fox\nrealname = Mr_Fox\n')),
      ('skins/char1/XTRAC0.png', fakePng),
      ('skins/char2/S_SKIN', ascii.encode('name = kart\nfacewant = KARTWANT\n')),
      ('skins/char2/KARTWANT.png', [0x89, 0x50, 0x4E, 0x47, 7]),
    ]));
    final chars = CharacterScanner.scanAll([base, addon], const []);
    expect(chars.map((c) => c.name), ['amy', 'fox', 'kart']);
    expect(chars[1].realname, 'Mr Fox');
    expect(chars[1].icon, fakePng);
    expect(chars[2].icon!.last, 7);
    expect(chars[2].file, addon);
  });

  test('kart stats: kartspeed and kartweight 1..9 like GETKARTSTAT; missing — none', () async {
    final path = p.join(dir.path, 'karts.pk3');
    await File(path).writeAsBytes(buildZip([
      ('skins/a/S_SKIN', ascii.encode('name = fast\nkartspeed = 8\nkartweight = 2\n')),
      ('skins/b/S_SKIN', ascii.encode('name = odd\nkartspeed = 12\nkartweight = 0\n')),
      ('skins/c/S_SKIN', ascii.encode('name = plain\n')),
    ]));
    final chars = CharacterScanner.scanAll([path], const []);
    expect([for (final c in chars) (c.name, c.kartSpeed, c.kartWeight)], [
      ('fast', 8, 2),
      ('odd', 9, 1),
      ('plain', null, null),
    ]);
    expect((Games.srb2kart.kartStats, Games.drrr.kartStats, Games.srb2.kartStats), (true, true, false));
  });

  test('SRB2Kart/BlanKart: Sonic from the game code, P_SKIN patches, faces from other files, renamed repeats',
      () async {
    final chars = p.join(dir.path, 'chars.kart');
    await File(chars).writeAsBytes(buildZip([
      ('PLAYWANT.png', fakePng),
      ('KNUXWANT.png', [0x89, 0x50, 0x4E, 0x47, 9]),
    ]));
    final main = p.join(dir.path, 'main.pk3');
    await File(main).writeAsBytes(buildZip([
      ('Skins/knuckles/S_SKIN', ascii.encode('name = knuckles\nfacewant = KNUXWANT\nkartspeed = 5\nkartweight = 5\n')),
      ('Skins/P_SKIN', ascii.encode('name = sonic\nrealname = Classic_Sonic\nkartspeed = 9\n')),
      ('Skins/again/S_SKIN', ascii.encode('name = knuckles\n')),
    ]));
    final list = CharacterScanner.scanAll([chars, main], const [], builtInSonic: BuiltInSonic.kart);
    expect([for (final c in list) (c.name, c.realname, c.kartSpeed, c.kartWeight)], [
      ('sonic', 'Classic Sonic', 9, 2), // из кода (8/2), P_SKIN поменял имя и скорость
      ('knuckles', 'knuckles', 5, 5),
      ('knuckles2', 'knuckles', null, null), // повтор имени — «имя+номер»
    ]);
    expect(list[0].icon, fakePng); // PLAYWANT из chars.kart
    expect(list[1].icon!.last, 9); // facewant из другого файла
    expect((Games.srb2kart.builtInSonic, Games.drrr.builtInSonic), (BuiltInSonic.kart, BuiltInSonic.none));
  });

  test('palette: the first PLAYPAL inside a file, like the game (W_CheckNumForNamePwad)', () async {
    final path = p.join(dir.path, 'main.pk3');
    final first = List<int>.generate(768, (i) => 1);
    final second = List<int>.generate(768, (i) => 2);
    await File(path).writeAsBytes(buildZip([
      ('Palette/PLAYPAL.pal', first),
      ('Compat/PLAYPAL.pal', second),
    ]));
    final a = AddonArchive.open(path)!;
    try {
      expect(MapScanner.findPalette([a], const [])!.first, 1);
    } finally {
      a.close();
    }
  });

  test('BlanKart palettes: compat files (srb2.srb, *.kart, K*) get PALREMAP, the others the main palette', () async {
    // Основная палитра: цвет i = (i, 0, 0); PALREMAP: i → 255 - i.
    final pal = [for (var i = 0; i < 256; i++) ...[i, 0, 0]];
    final remap = [for (var i = 0; i < 256; i++) 255 - i];
    final main = p.join(dir.path, 'main.pk3');
    await File(main).writeAsBytes(buildZip([
      ('Palette/PLAYPAL.pal', pal),
      ('PALREMAP.lmp', remap),
      ('INVREMAP.lmp', remap),
    ]));
    final r = PaletteResolver(const [], [main]);
    expect(r.forFile(p.join(dir.path, 'main.pk3'))!.sublist(0, 6), [0, 0, 0, 1, 0, 0]);
    for (final name in ['chars.kart', 'srb2.srb', 'KC_supermitpack.pk3', 'kl_track.wad']) {
      expect(r.forFile(p.join(dir.path, name))!.sublist(0, 6), [255, 0, 0, 254, 0, 0], reason: name);
    }
    for (final name in ['mappatch.pk3', 'DRL_RR_Fixes.pk3', 'chars.pk3']) {
      expect(r.forFile(p.join(dir.path, name))!.sublist(0, 3), [0, 0, 0], reason: name);
    }
    // Без PALREMAP (SRB2, SRB2Kart, Ring Racers) — одна палитра на всё.
    final plain = p.join(dir.path, 'srb2.pk3');
    await File(plain).writeAsBytes(buildZip([('Palette/PLAYPAL.pal', pal)]));
    expect(PaletteResolver(const [], [plain]).forFile(p.join(dir.path, 'chars.kart'))!.sublist(0, 3), [0, 0, 0]);
  });

  test('PK3: sprites outside the S_SKIN folder are taken in archive order, as the game does', () async {
    final path = p.join(dir.path, 'characters.pk3');
    await File(path).writeAsBytes(buildZip([
      ('Skins/Sonic/S_SKIN', ascii.encode('name = sonic\n')),
      ('Sprites/Sonic/XTRAC0.png', fakePng),
      ('Skins/Tails/S_SKIN', ascii.encode('name = tails\n')),
      ('Sprites/Tails/XTRAC0.png', [0x89, 0x50, 0x4E, 0x47, 9]),
    ]));
    final chars = CharacterScanner.scanAll([path], const []);
    expect(chars.map((c) => c.name), ['sonic', 'tails']);
    expect(chars[0].icon, fakePng);
    expect(chars[1].icon!.last, 9);
  });

  test('XTRAB0 portrait is taken as is', () async {
    final path = p.join(dir.path, 'CL_Portrait.pk3');
    await File(path).writeAsBytes(buildZip([
      ('Skins/S_SKIN', ascii.encode('name = sonic\n')),
      ('Skins/XTRAB0.png', [0x89, 0x50, 0x4E, 0x47, 42]),
      ('Skins/XTRAC0.png', fakePng),
    ]));
    final c = CharacterScanner.scanAll([path], const []).single;
    expect(c.portrait!.last, 42);
    expect(c.icon, fakePng);
  });

  test('no XTRAC0 icon: the select picture is used, and the other way round', () async {
    final path = p.join(dir.path, 'CL_Half.pk3');
    await File(path).writeAsBytes(buildZip([
      ('Skins/A/S_SKIN', ascii.encode('name = onlyportrait\n')),
      ('Skins/A/XTRAB0.png', [0x89, 0x50, 0x4E, 0x47, 42]),
      ('Skins/B/S_SKIN', ascii.encode('name = onlyicon\n')),
      ('Skins/B/XTRAC0.png', fakePng),
    ]));
    final chars = CharacterScanner.scanAll([path], const []);
    expect(chars[0].icon!.last, 42);
    expect(chars[1].portrait, fakePng);
  });

  test('neither: the standing sprite STNDA2; STNDA8 is mirrored to look the same', () async {
    // patch2x2, отражённый по горизонтали (столбцы местами).
    final mirrored = Uint8List.fromList([
      2, 0, 2, 0, 0, 0, 0, 0,
      16, 0, 0, 0, 22, 0, 0, 0,
      0, 1, 0, 3, 0, 0xFF,
      0, 2, 0, 1, 2, 0, 0xFF,
    ]);
    Future<CharacterInfo> scan(String file, String lump, Uint8List data) async {
      final path = p.join(dir.path, file);
      await File(path).writeAsBytes(buildWad([
        ('PLAYPAL', palette()),
        ('S_SKIN', ascii.encode('name = stand\n')),
        ('STNDA1', [0]),
        (lump, data),
        ('S_END', []),
      ]));
      return CharacterScanner.scanAll([path], const []).single;
    }

    final a2 = await scan('a2.wad', 'STNDA2A8', patch2x2());
    final a8 = await scan('a8.wad', 'STNDA8', mirrored);
    expect(a2.icon, isNotNull);
    expect(a8.icon, a2.icon);
    expect(a8.portrait, a2.portrait);
  });

  test('custom colors from SOC and Lua, lookup by name', () {
    final soc = CharacterScanner.parseSocColors('FREESLOT\nSKINCOLOR_FIRECOPPER\n\n'
        'SKINCOLOR SKINCOLOR_FIRECOPPER\nNAME = Firecopper\n'
        'RAMP = 187,186,186,44,44,43,42,61,60,58,56,53,52,64,84,88\nINVCOLOR = 44\nACCESSIBLE = true\n');
    expect(soc.single.$1, 'Firecopper');
    expect(soc.single.$2.first, 187);
    final lua = CharacterScanner.parseLuaColors('freeslot("SKINCOLOR_ICE")\n'
        'skincolors[SKINCOLOR_ICE] = {\n  name = "Ice",\n  ramp = {1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16},\n  invcolor = 44,\n}\n');
    expect(lua.single.$1, 'Ice');
    expect(lua.single.$2.last, 16);
    final all = <SkinColor>[('None', List.filled(16, 0)), ('Blue', List.filled(16, 150)), ...soc, ...lua];
    expect(CharacterScanner.findColor(all, 'blue')!.first, 150);
    expect(CharacterScanner.findColor(all, 'SKINCOLOR_FIRECOPPER')!.first, 187);
    expect(CharacterScanner.findColor(all, '1')!.first, 150);
    expect(CharacterScanner.findColor(all, 'Nope'), isNull);
  });

  test('prefcolor recolors startcolor..startcolor+15; team ramp re-renders', () async {
    final path = p.join(dir.path, 'CL_Fox.wad');
    await File(path).writeAsBytes(buildWad([
      ('PLAYPAL', palette()),
      ('SOC_COL', ascii.encode('SKINCOLOR SKINCOLOR_X\nNAME = Firecopper\nRAMP = 200,201,202,203,204,205,206,207,208,209,210,211,212,213,214,215\n')),
      ('S_SKIN', ascii.encode('name = fox\nstartcolor = 1\nprefcolor = Firecopper\n')),
      ('XTRAC0', patch2x2()),
      ('S_END', []),
    ]));
    final fox = CharacterScanner.scanAll([path], const []).single;
    expect(fox.prefColor, 'Firecopper');
    expect(firstPixel(fox.icon!), [200, 10, 20, 255]); // индекс 1 → ramp[0] = 200
    final red = fox.iconWithRamp(List.generate(16, (i) => 100 + i))!;
    expect(firstPixel(red), [100, 10, 20, 255]);
  });

  test('SRB2 2.1 (Legacy): built-in Sonic, face icon and charsel portrait', () async {
    final path = p.join(dir.path, 'player.dta');
    await File(path).writeAsBytes(buildWad([
      ('PLAYPAL', palette()),
      ('GX_START', []),
      ('CHRSONIC', patch2x2()),
      ('CHRTAILS', patch2x2()),
      ('LIVSONIC', patch2x2()),
      ('LIVTAILS', patch2x2()),
      ('GX_END', []),
      ('S_START', []),
      ('PLAYA1', [0]),
      ('S_END', []),
      ('S_SKIN', ascii.encode('name = tails\nrealname = Tails\ncharsel = CHRTAILS\nface = LIVTAILS\nprefcolor = Orange\n')),
      ('TAILA1', [0]),
      ('S_END', []),
    ]));
    final chars = CharacterScanner.scanAll([path], const [], startColor: 160, builtInSonic: BuiltInSonic.legacy);
    expect(chars.map((c) => c.name), ['sonic', 'tails']);
    expect(chars[0].realname, 'Sonic');
    expect(chars.every((c) => c.icon != null && c.portrait != null), isTrue);
    final described = CharacterScanner.scanAll([path], const [],
        startColor: 160, builtInSonic: BuiltInSonic.legacy, baseDescriptions: CharacterScanner.vanillaDescriptions);
    expect(described[0].description, contains('fastest of the three'));
    expect(described[1].description, contains('most mobile'));
    // Без builtInSonic (SRB2 2.2) Соника из кода нет.
    expect(CharacterScanner.scanAll([path], const []).map((c) => c.name), ['tails']);
  });

  test('SRB2 2.1: the character select picture comes from SOC PicName, then charsel', () async {
    final path = p.join(dir.path, 'GreenEyes.wad');
    await File(path).writeAsBytes(buildWad([
      ('PLAYPAL', palette()),
      ('SOC_PLAY', ascii.encode('Character 3\nSkinName = greeneyes\nPicName = GEPIC\nPlayerText = ^2Green^0.#\n')),
      ('GEPIC', patch2x2()),
      ('LIVGREEN', patch2x2()),
      ('S_SKIN', ascii.encode('name = greeneyes\nface = LIVGREEN\n')),
      ('S_END', []),
    ]));
    final c = CharacterScanner.scanAll([path], const []).single;
    expect(c.portrait, isNotNull);
    expect(c.description, '^2Green^0.');
    // Без PicName и charsel портретом становится иконка (face).
    final plain = p.join(dir.path, 'Plain.wad');
    await File(plain).writeAsBytes(buildWad([
      ('PLAYPAL', palette()),
      ('LIVPLAIN', patch2x2()),
      ('S_SKIN', ascii.encode('name = plain\nface = LIVPLAIN\n')),
      ('S_END', []),
    ]));
    final d = CharacterScanner.scanAll([plain], const [], baseDescriptions: CharacterScanner.vanillaDescriptions).single;
    expect((d.icon != null, d.description), (true, ''));
    expect(d.portrait, d.icon);
    final sonic = CharacterScanner.scanAll([plain], const [], baseDescriptions: CharacterScanner.vanillaDescriptions);
    expect(sonic.single.name, 'plain');
  });

  test('Ring Racers: skins/<name>/ folders, XTRAB0 icon whatever the zip order', () async {
    final path = p.join(dir.path, 'chars.pk3');
    await File(path).writeAsBytes(buildZip([
      ('skins/sonic/XTRAB0.png', fakePng),
      ('skins/sonic/STINA1.png', fakePng),
      ('skins/sonic/S_SKIN', ascii.encode('name = sonic\n')),
      ('skins/tails/S_SKIN', ascii.encode('name = tails\n')),
      ('skins/tails/STINA1.png', fakePng),
    ]));
    final chars = CharacterScanner.scanAll([path], const [], iconFrames: 'BAC', portraits: false);
    expect(chars.map((c) => c.name), ['sonic', 'tails']);
    expect(chars[0].icon, isNotNull);
    expect(chars[0].portrait, isNull);
    expect(chars[1].icon, isNull); // спрайты Соника — не его
  });

  test('Ring Racers: a player is matched to a character by name (realname, then name)', () {
    final chars = [
      CharacterInfo('sonic', 'Sonic', null, 'chars.pk3'),
      CharacterInfo('metalsonic', 'Metal Sonic', null, 'chars.pk3'),
      CharacterInfo('eggman', 'Dr. Eggman', null, 'chars.pk3'),
    ];
    expect(CharacterScanner.findByName(chars, 'Metal Sonic')?.name, 'metalsonic');
    expect(CharacterScanner.findByName(chars, ' metal_sonic ')?.name, 'metalsonic');
    expect(CharacterScanner.findByName(chars, 'eggman')?.name, 'eggman');
    expect(CharacterScanner.findByName(chars, 'xXSonicXx'), isNull);
    expect(CharacterScanner.findByName(chars, ''), isNull);
  });

  test('LZF: literal runs and overlapping back references', () {
    // "abc" литералами, затем 6 байт с расстояния 3: abcabcabc.
    final out = AddonArchive.lzfDecompress(Uint8List.fromList([2, 97, 98, 99, 0x80, 2]), 9);
    expect(ascii.decode(out), 'abcabcabc');
    expect(() => AddonArchive.lzfDecompress(Uint8List.fromList([0x80, 9]), 4), throwsFormatException);
  });

  test('ZWAD (compressed SRB2 2.1 WAD): skins are read, nameless ones still count', () async {
    List<int> lzfLiterals(List<int> data) => [
          for (var i = 0; i < data.length; i += 32) ...[
            (data.length - i < 32 ? data.length - i : 32) - 1,
            ...data.sublist(i, data.length - i < 32 ? data.length : i + 32),
          ],
        ];
    List<int> u32(int v) => [v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255];
    final lumps = <(String, List<int>)>[
      ('S_SKIN', [...u32(0), ...ascii.encode('realname = Nobody\n')]), // не сжат, без name
      ('S_END', []),
      ('S_SKIN1', () {
        final text = ascii.encode('name = Hinote\r\nface = HINOLIFE\r\nprefcolor = purple\r\n');
        return [...u32(text.length), ...lzfLiterals(text)];
      }()),
      ('S_END', []),
    ];
    final body = <int>[];
    final table = <int>[];
    for (final (name, data) in lumps) {
      table.addAll([...u32(12 + body.length), ...u32(data.length), ...ascii.encode(name.padRight(8, '\x00'))]);
      body.addAll(data);
    }
    final path = p.join(dir.path, 'old.wad');
    await File(path).writeAsBytes([...ascii.encode('ZWAD'), ...u32(lumps.length), ...u32(12 + body.length), ...body, ...table]);
    final chars = CharacterScanner.scanAll([path], const []);
    expect([for (final c in chars) (c.name, c.realname)], [('skin', 'Nobody'), ('hinote', 'hinote')]);
    expect(chars[1].prefColor, 'purple');
  });

  test('super/inaccessible colors parse accessible flag and group into pulse animation', () {
    final soc = CharacterScanner.parseSocColorDefs(
      'SKINCOLOR SKINCOLOR_SUPERNEON1\nNAME = Super Neon 1\nRAMP = 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1\nACCESSIBLE = false\n\n'
      'SKINCOLOR SKINCOLOR_SUPERNEON2\nNAME = Super Neon 2\nRAMP = 2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2\nACCESSIBLE = no\n\n'
      'SKINCOLOR SKINCOLOR_NORMAL\nNAME = Emerald\nRAMP = 3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3\n',
    );
    expect(soc.map((d) => (d.name, d.accessible)), [
      ('Super Neon 1', false),
      ('Super Neon 2', false),
      ('Emerald', true),
    ]);

    final lua = CharacterScanner.parseLuaColorDefs(
      'skincolors[SKINCOLOR_SUPERICE1] = { name = "Super Ice 1", ramp = {1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1}, accessible = false }\n'
      'skincolors[SKINCOLOR_SUPERICE3] = { name = "Super Ice 3", ramp = {3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3}, accessible = false }\n'
      'skincolors[SKINCOLOR_SUPERICE2] = { name = "Super Ice 2", ramp = {2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2}, accessible = false }\n',
    );
    expect(lua.every((d) => !d.accessible), isTrue);

    final grouped = CharacterScanner.groupColors(
      [for (final d in [...soc, ...lua]) (d.name, d.ramp)],
      hidden: {for (final d in [...soc, ...lua]) if (!d.accessible) d.name.toLowerCase()},
    );
    expect(grouped.map((g) => (g.name, g.ramps.length, g.selectable)), [
      ('Super Neon', 2, false),
      ('Emerald', 1, true),
      ('Super Ice', 3, false),
    ]);
    // Кадры отсортированы по шагу: 1, 2, 3.
    expect(grouped[2].ramps.map((r) => r.first), [1, 2, 3]);
    expect(CharacterScanner.pulseIndices(5), [0, 1, 2, 3, 4, 3, 2, 1]);
  });
}

/// Первый пиксель PNG (RGBA, фильтр None) — для проверки перекраски.
List<int> firstPixel(Uint8List png) {
  var p = 8;
  final idat = BytesBuilder();
  while (p < png.length) {
    final len = ByteData.sublistView(png, p, p + 4).getUint32(0);
    final type = ascii.decode(png.sublist(p + 4, p + 8));
    if (type == 'IDAT') idat.add(png.sublist(p + 8, p + 8 + len));
    p += 12 + len;
  }
  final raw = ZLibCodec().decode(idat.toBytes());
  return raw.sublist(1, 5); // байт фильтра, затем RGBA
}
