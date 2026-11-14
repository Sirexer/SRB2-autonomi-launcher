import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:srb2_autonomi_launcher/models/game.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:srb2_autonomi_launcher/services/game_files.dart';
import 'package:srb2_autonomi_launcher/services/launch_settings.dart';
import 'package:srb2_autonomi_launcher/services/map_preview.dart';

/// WAD из списка (имя, данные).
Uint8List buildWad(List<(String, List<int>)> lumps) {
  final data = BytesBuilder();
  final dir = BytesBuilder();
  var offset = 12;
  for (final (name, bytes) in lumps) {
    final entry = ByteData(16)
      ..setInt32(0, offset, Endian.little)
      ..setInt32(4, bytes.length, Endian.little);
    final e = entry.buffer.asUint8List();
    e.setRange(8, 8 + name.length, ascii.encode(name));
    dir.add(e);
    data.add(bytes);
    offset += bytes.length;
  }
  final head = ByteData(12)
    ..setInt32(4, lumps.length, Endian.little)
    ..setInt32(8, offset, Endian.little);
  final h = head.buffer.asUint8List()..setRange(0, 4, ascii.encode('PWAD'));
  return Uint8List.fromList([...h, ...data.toBytes(), ...dir.toBytes()]);
}

/// Zip (PK3): файлы со сжатием deflate.
Uint8List buildZip(List<(String, List<int>)> files) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  for (final (name, bytes) in files) {
    final packed = ZLibCodec(raw: true).encode(bytes);
    final nameBytes = utf8.encode(name);
    final local = out.length;
    final lh = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(8, 8, Endian.little)
      ..setUint32(18, packed.length, Endian.little)
      ..setUint32(22, bytes.length, Endian.little)
      ..setUint16(26, nameBytes.length, Endian.little);
    out
      ..add(lh.buffer.asUint8List())
      ..add(nameBytes)
      ..add(packed);
    final ch = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(10, 8, Endian.little)
      ..setUint32(20, packed.length, Endian.little)
      ..setUint32(24, bytes.length, Endian.little)
      ..setUint16(28, nameBytes.length, Endian.little)
      ..setUint32(42, local, Endian.little);
    central
      ..add(ch.buffer.asUint8List())
      ..add(nameBytes);
  }
  final cdOffset = out.length;
  final cd = central.toBytes();
  out.add(cd);
  final eocd = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, files.length, Endian.little)
    ..setUint16(10, files.length, Endian.little)
    ..setUint32(12, cd.length, Endian.little)
    ..setUint32(16, cdOffset, Endian.little);
  out.add(eocd.buffer.asUint8List());
  return out.toBytes();
}

/// Doom-патч 2×2: столбец 0 — цвета 1 и 2, столбец 1 — только верхний пиксель цвета 3.
Uint8List patch2x2() => Uint8List.fromList([
      2, 0, 2, 0, 0, 0, 0, 0, // ширина, высота, смещения
      16, 0, 0, 0, 23, 0, 0, 0, // начала столбцов
      0, 2, 0, 1, 2, 0, 0xFF, // столбец 0: top 0, len 2, pad, данные, pad, конец
      0, 1, 0, 3, 0, 0xFF, // столбец 1
    ]);

Uint8List palette() {
  final pal = Uint8List(768);
  for (var i = 0; i < 256; i++) {
    pal[i * 3] = i; // R = номер цвета
    pal[i * 3 + 1] = 10;
    pal[i * 3 + 2] = 20;
  }
  return pal;
}

const fakePng = [0x89, 0x50, 0x4E, 0x47, 1, 2, 3];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('maps_'));
  tearDown(() => dir.delete(recursive: true));

  test('map numbers like the game', () {
    expect(MapScanner.mapNumber('MAP01'), 1);
    expect(MapScanner.mapNumber('MAPA0'), 100);
    expect(MapScanner.mapNumber('MAPZZ'), 1035);
    expect(MapScanner.mapNumber('RR_TEST'), 0);
    for (final n in [1, 99, 100, 135, 1035]) {
      expect(MapScanner.mapNumber(MapScanner.mapName(n)), n);
    }
    expect(MapScanner.socLevelMap('1'), 'MAP01');
    expect(MapScanner.socLevelMap('a1'), 'MAPA1');
    expect(MapScanner.socLevelMap('RR_Test'), 'RR_TEST');
  });

  test('SOC level headers', () {
    final t = MapScanner.parseSoc('Level 1\nLevelname = Greenflower\nAct = 1\n\n'
        'Level A1\r\nLEVELNAME = Alpha Zone # comment\r\nAct = 0\r\n'
        'Character 1\nLevelname = not a level\n');
    expect(t, {'MAP01': 'Greenflower 1', 'MAPA1': 'Alpha Zone'});
  });

  test('Doom patch is decoded with the palette, transparent as black', () {
    final (w, h, rgb) = MapScanner.decodePatch(patch2x2(), palette())!;
    expect((w, h), (2, 2));
    expect(rgb.sublist(0, 3), [1, 10, 20]); // (0,0)
    expect(rgb.sublist(3, 6), [3, 10, 20]); // (1,0)
    expect(rgb.sublist(6, 9), [2, 10, 20]); // (0,1)
    expect(rgb.sublist(9, 12), [0, 0, 0]); // (1,1) — пусто
    final bmp = MapScanner.encodeBmp(w, h, rgb);
    expect(ascii.decode(bmp.sublist(0, 2)), 'BM');
    expect(bmp.length, 54 + 8 * 2); // строки выровнены по 4 байта
  });

  test('WAD: map markers, MAPxxP picture, MAINCFG title, own palette', () async {
    final wad = buildWad([
      ('PLAYPAL', palette()),
      ('MAINCFG', ascii.encode('Level 1\nLevelname = Test Zone\nAct = 2\n')),
      ('MAP01', []),
      ('THINGS', [0, 0]),
      ('LINEDEFS', [0]),
      ('MAP02', []),
      ('TEXTMAP', ascii.encode('namespace="srb2";')),
      ('ENDMAP', []),
      ('MAP01P', patch2x2()),
    ]);
    final path = p.join(dir.path, 'test.wad');
    await File(path).writeAsBytes(wad);
    final maps = MapScanner.scan(path, const []);
    expect(maps.map((m) => m.map), ['MAP01', 'MAP02']);
    expect(maps[0].title, 'Test Zone 2');
    expect(ascii.decode(maps[0].image!.sublist(0, 2)), 'BM');
    expect(maps[1].image, isNull); // без картинки — заглушка в интерфейсе
  });

  test('PK3: maps folder, PNG picture, SOC folder, PICTURE inside a map, palette from the game', () async {
    final gamePalette = p.join(dir.path, 'srb2.pk3');
    await File(gamePalette).writeAsBytes(buildZip([('Palettes/PLAYPAL.pal', palette())]));
    final rrMap = buildWad([
      ('RR_TEST', []),
      ('TEXTMAP', ascii.encode('x')),
      ('PICTURE', patch2x2()),
      ('ENDMAP', []),
    ]);
    final pk3 = buildZip([
      ('Maps/MAPA1.wad', buildWad([('MAPA1', []), ('THINGS', [0])])),
      ('Maps/RR_TEST.wad', rrMap),
      ('Maps/readme.txt', ascii.encode('not a map')),
      ('Graphics/MAPA1P.png', fakePng),
      ('SOC/levels.soc', ascii.encode('Level A1\nLevelname = Alpha\n\nLevel RR_TEST\nLevelname = Test Run\n')),
    ]);
    final path = p.join(dir.path, 'addon.pk3');
    await File(path).writeAsBytes(pk3);

    final maps = MapScanner.scan(path, [p.join(dir.path, 'missing.pk3'), gamePalette]);
    expect(maps.map((m) => m.map), ['MAPA1', 'RR_TEST']);
    expect(maps[0].title, 'Alpha');
    expect(maps[0].image, fakePng);
    expect(maps[1].title, 'Test Run');
    expect(ascii.decode(maps[1].image!.sublist(0, 2)), 'BM');
  });

  test('PK3: a map as lumps in the Maps folder (marker, THINGS... / TEXTMAP)', () async {
    final gamePalette = p.join(dir.path, 'srb2.pk3');
    await File(gamePalette).writeAsBytes(buildZip([('Palettes/PLAYPAL.pal', palette())]));
    final pk3 = buildZip([
      ('Maps/MAPA0', []),
      ('Maps/THINGS', [0]),
      ('Maps/LINEDEFS', [0]),
      ('Maps/SECTORS', [0]),
      ('Maps/MAPA1', []),
      ('Maps/TEXTMAP', ascii.encode('x')),
      ('Maps/PICTURE', patch2x2()),
      ('Maps/ENDMAP', []),
      ('Maps/readme.txt', ascii.encode('not a map')),
      ('SOC/levels.soc', ascii.encode('Level A0\nLevelname = Folder Zone\nTypeOfLevel = Race\n')),
    ]);
    final path = p.join(dir.path, 'folder.pk3');
    await File(path).writeAsBytes(pk3);

    final maps = MapScanner.scan(path, [gamePalette]);
    expect(maps.map((m) => m.map), ['MAPA0', 'MAPA1']);
    expect(maps[0].title, 'Folder Zone');
    expect(maps[0].types, ['Race']);
    expect(maps[0].image, isNull); // PICTURE следующей карты — не её
    expect(ascii.decode(maps[1].image!.sublist(0, 2)), 'BM');

    final archive = AddonArchive.open(path)!;
    try {
      expect(MapScanner.mapNames(archive), ['MAPA0', 'MAPA1']);
    } finally {
      archive.close();
    }
  });

  test('server map picture: last file wins, lookup by name or by title', () async {
    final base = p.join(dir.path, 'zones.pk3');
    await File(base).writeAsBytes(buildZip([
      ('Maps/MAP01.wad', buildWad([('MAP01', []), ('THINGS', [0])])),
      ('Graphics/MAP01P.png', [0x89, 0x50, 0x4E, 0x47, 9]),
    ]));
    final addon = p.join(dir.path, 'replace.wad');
    await File(addon).writeAsBytes(buildWad([
      ('PLAYPAL', palette()),
      ('MAINCFG', ascii.encode('Level RR_TEST\nLevelname = Test Run\n')),
      ('MAP01', []),
      ('THINGS', [0]),
      ('MAP01P', fakePng),
      ('RR_TEST', []),
      ('TEXTMAP', ascii.encode('x')),
      ('PICTURE', patch2x2()),
      ('ENDMAP', []),
    ]));
    final byName = MapScanner.findPicture(files: [base, addon], map: 'map01', title: '', paletteFiles: const []);
    expect(byName, fakePng); // аддон загружен позже — его картинка
    final baseOnly = MapScanner.findPicture(files: [base], map: 'MAP01', title: '', paletteFiles: const []);
    expect(baseOnly!.last, 9);
    // Ring Racers: имени нет, сервер шлёт "Test Run Zone" — ищем по названию.
    final byTitle = MapScanner.findPicture(files: [addon], map: '', title: 'Test Run  Zone', paletteFiles: const []);
    expect(ascii.decode(byTitle!.sublist(0, 2)), 'BM');
    expect(MapScanner.findPicture(files: [addon], map: 'MAP99', title: '', paletteFiles: const []), isNull);
  });

  test('SOC: title map and hidden levels', () {
    final info = MapScanner.parseSocInfo('MainCfg Category\nTitleMap = Z0\n\n'
        'Level 2\nLevelname = Secret\nHidden = true\n\nLevel 3\nLevelname = Open\nHidden = false\n');
    expect(info.titleMap, 'MAPZ0');
    expect(info.hidden, {'MAP02': true, 'MAP03': false});
    expect(MapScanner.socTitleMap('99'), 'MAP99');
    expect(MapScanner.socTitleMap('RR_Title'), 'RR_TITLE');
  });

  test('all maps of the game and the queue: later files replace, title map marked', () async {
    final game = p.join(dir.path, 'srb2.pk3');
    await File(game).writeAsBytes(buildZip([
      ('Palettes/PLAYPAL.pal', palette()),
      ('SOC/main.soc', ascii.encode('MainCfg Category\nTitleMap = 99\n\nLevel 1\nLevelname = Base\n')),
      ('Maps/MAP01.wad', buildWad([('MAP01', []), ('THINGS', [0])])),
      ('Maps/MAP99.wad', buildWad([('MAP99', []), ('THINGS', [0])])),
      ('Graphics/MAP01P.lmp', patch2x2()),
    ]));
    final addon = p.join(dir.path, 'addon.wad');
    await File(addon).writeAsBytes(buildWad([
      ('MAINCFG', ascii.encode('Level 1\nLevelname = Replaced\n\nLevel 2\nLevelname = New\nHidden = 1\n')),
      ('MAP01', []),
      ('THINGS', [0]),
      ('MAP02', []),
      ('THINGS', [0]),
      ('MAP02P', fakePng),
    ]));
    final maps = MapScanner.scanAll([game, addon], const []);
    expect(maps.map((m) => m.map), ['MAP01', 'MAP02', 'MAP99']);
    expect(maps[0].title, 'Replaced');
    expect(ascii.decode(maps[0].image!.sublist(0, 2)), 'BM'); // палитра из srb2.pk3
    expect(maps[1].image, fakePng);
    expect(maps[1].hidden, isTrue);
    expect(maps[2].isTitleMap, isTrue);
  });

  test('PK3: SOC and maps in subfolders with any names, Clear Levels drops earlier maps', () async {
    final base = p.join(dir.path, 'zones.pk3');
    await File(base).writeAsBytes(buildZip([
      ('SOC/MainCFG/1.LevelHeaders/1.Vanilla_SOC.soc', ascii.encode('Level 1\nLevelname = Greenflower\nAct = 1\n')),
      ('Maps/Vanilla/MAP01.wad', buildWad([('MAP01', []), ('THINGS', [0])])),
    ]));
    final pack = p.join(dir.path, 'pack.pk3');
    await File(pack).writeAsBytes(buildZip([
      ('SOC/Levels/part2.txt', ascii.encode('Level T0\nLevelname = Quiet Waterfalls\nNoZone = 1\n')),
      ('Maps/MAPT0.wad', buildWad([('MAPT0', []), ('THINGS', [0])])),
    ]));
    var maps = MapScanner.scanAll([base, pack], const []);
    expect({for (final m in maps) m.map: m.title}, {'MAP01': 'Greenflower 1', 'MAPT0': 'Quiet Waterfalls'});

    final clearing = p.join(dir.path, 'clearing.pk3');
    await File(clearing).writeAsBytes(buildZip([
      ('SOC/MAINCFG', ascii.encode('Maincfg Category\nCustomVersion = 2.0\n\nClear Levels\n\nLevel A1\nLevelname = Only\n')),
      ('Maps/MAPA1.wad', buildWad([('MAPA1', []), ('THINGS', [0])])),
    ]));
    maps = MapScanner.scanAll([base, pack, clearing], const []);
    expect({for (final m in maps) m.map: m.title}, {'MAPA1': 'Only'});
  });

  test('game files are found deep inside the game folder', () async {
    final root = p.join(dir.path, 'Game');
    final zones = File(p.join(root, 'data', 'Assets', 'Required', 'zones.pk3'));
    await zones.create(recursive: true);
    await File(p.join(root, 'screenshots', 'srb2.pk3')).create(recursive: true); // эту папку не смотрим
    SharedPreferences.setMockInitialValues({});
    final launch = LaunchSettings();
    await launch.load();
    final found = await GameFiles.resolveAsync(Games.srb2, root, launch, ['srb2.pk3', 'zones.pk3']);
    expect(found, [zones.path]);
  });

  test('game files are looked up next to the builds and in data/', () {
    final root = p.join(dir.path, 'SRB2');
    final exe = p.join(root, 'bin', 'x64', 'srb2win.exe');
    final dirs = GameFiles.dirs(Games.srb2, root, [exe, 'flatpak']);
    expect(dirs, containsAll([root, p.join(root, 'data'), p.join(root, 'bin', 'x64'), p.join(root, 'bin', 'data')]));
  });

  test('copies like "MAPTO (1).wad" are skipped, TypeOfLevel is read', () async {
    final pack = p.join(dir.path, 'dups.pk3');
    await File(pack).writeAsBytes(buildZip([
      ('SOC/SOC_HEAD.txt', ascii.encode('Level 1\nLevelname = Greenflower\nTypeOfLevel = Singleplayer,Co-op,Competition,Race\n')),
      ('Maps/MAP01.wad', buildWad([('MAP01', []), ('THINGS', [0])])),
      ('Maps/MAPTO (1).wad', buildWad([('MAPTO', []), ('THINGS', [0])])),
      ('Level select pictures/MAP01P.png', fakePng),
    ]));
    final maps = MapScanner.scanAll([pack], const []);
    expect(maps.single.map, 'MAP01');
    expect(maps.single.types, ['Singleplayer', 'Co-op', 'Competition', 'Race']);
    expect(maps.single.image, fakePng);
  });

  test('WAD: OBJCTCFG is a SOC too', () async {
    final path = p.join(dir.path, 'obj.wad');
    await File(path).writeAsBytes(buildWad([
      ('OBJCTCFG', ascii.encode('Level 7\nLevelname = Seven\n')),
      ('MAP07', []),
      ('THINGS', [0]),
    ]));
    expect(MapScanner.scan(path, const []).single.title, 'Seven');
  });

  test('no palette: Doom patches give no picture; not an archive: nothing', () async {
    final path = p.join(dir.path, 'nopal.wad');
    await File(path).writeAsBytes(buildWad([('MAP05', []), ('THINGS', [0]), ('MAP05P', patch2x2())]));
    final maps = MapScanner.scan(path, const []);
    expect(maps.single.map, 'MAP05');
    expect(maps.single.image, isNull);

    final lua = p.join(dir.path, 'script.lua');
    await File(lua).writeAsString('print("hi")');
    expect(MapScanner.scan(lua, const []), isEmpty);
  });
}
