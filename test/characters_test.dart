import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
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
    final chars = CharacterScanner.scanAll([path], const [], startColor: 160, builtInSonic: true);
    expect(chars.map((c) => c.name), ['sonic', 'tails']);
    expect(chars[0].realname, 'Sonic');
    expect(chars.every((c) => c.icon != null && c.portrait != null), isTrue);
    final described = CharacterScanner.scanAll([path], const [],
        startColor: 160, builtInSonic: true, baseDescriptions: CharacterScanner.vanillaDescriptions);
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
    // Без PicName и charsel портрета нет — показывается иконка (face).
    final plain = p.join(dir.path, 'Plain.wad');
    await File(plain).writeAsBytes(buildWad([
      ('PLAYPAL', palette()),
      ('LIVPLAIN', patch2x2()),
      ('S_SKIN', ascii.encode('name = plain\nface = LIVPLAIN\n')),
      ('S_END', []),
    ]));
    final d = CharacterScanner.scanAll([plain], const [], baseDescriptions: CharacterScanner.vanillaDescriptions).single;
    expect((d.portrait, d.icon != null, d.description), (null, true, ''));
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
