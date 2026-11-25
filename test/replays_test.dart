import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:srb2_autonomi_launcher/services/file_hash.dart';
import 'package:srb2_autonomi_launcher/services/replays.dart';
import 'package:srb2_autonomi_launcher/services/server_files.dart';
import 'package:xxh3/xxh3.dart';

import 'map_preview_test.dart' show buildZip;

Uint8List _buildReplayBytes({
  int version = 202,
  int subversion = 15,
  int demoVersion = 17,
  int mapNumber = 1,
  List<int>? checksum,
  List<(String name, List<int> md5)>? addons,
  int timeTics = 0xFFFFFFFF,
  int score = 12340,
  int rings = 42,
  String playerName = 'Sonic',
  String skin = 'sonic',
  String color = 'Blue',
}) {
  final out = BytesBuilder();
  // 0x00..0x0B: \xf0SRB2Replay\x0f
  out.add(const [0xF0, 0x53, 0x52, 0x42, 0x32, 0x52, 0x65, 0x70, 0x6C, 0x61, 0x79, 0x0F]);
  out.addByte(version);
  out.addByte(subversion);
  out.addByte(demoVersion);
  out.addByte(0); // reserved
  // 0x10..0x1F: 16-byte checksum
  out.add(checksum ?? List<int>.filled(16, 0xAB));
  // 0x20..0x23: "PLAY"
  out.add(latin1.encode('PLAY'));
  // 0x24..0x25: uint16 LE gamemap
  out.add([mapNumber & 0xFF, (mapNumber >> 8) & 0xFF]);
  // 0x26..0x35: 16-byte mapmd5
  out.add(List<int>.filled(16, 0xCD));
  // 0x36: demoflags
  out.addByte(0);

  if (demoVersion >= 16) {
    final list = addons ?? const [];
    out.add([list.length & 0xFF, (list.length >> 8) & 0xFF]);
    for (final (name, md5) in list) {
      out.add(latin1.encode(name));
      out.addByte(0);
      out.add(md5);
    }
  }

  // uint32 LE timeTics, uint32 LE score, uint16 LE rings, 4-byte seed
  out.add([
    timeTics & 0xFF,
    (timeTics >> 8) & 0xFF,
    (timeTics >> 16) & 0xFF,
    (timeTics >> 24) & 0xFF,
  ]);
  out.add([
    score & 0xFF,
    (score >> 8) & 0xFF,
    (score >> 16) & 0xFF,
    (score >> 24) & 0xFF,
  ]);
  out.add([rings & 0xFF, (rings >> 8) & 0xFF]);
  out.add(const [1, 2, 3, 4]); // seed

  void writeFixed(String s, int len) {
    final encoded = latin1.encode(s);
    for (var i = 0; i < len; i++) {
      out.addByte(i < encoded.length ? encoded[i] : 0);
    }
  }

  writeFixed(playerName, 16);
  writeFixed(skin, 16);
  writeFixed(color, 32);
  return out.toBytes();
}

void main() {
  test('formatMapName converts classic and extended map numbers', () {
    expect(ReplayScanner.formatMapName(1), 'MAP01');
    expect(ReplayScanner.formatMapName(99), 'MAP99');
    expect(ReplayScanner.formatMapName(100), 'MAPA0');
    expect(ReplayScanner.formatMapName(114), 'MAPAE');
    expect(ReplayScanner.formatMapName(136), 'MAPB0');
    expect(ReplayScanner.formatMapName(140), 'MAPB4');
  });

  test('parseBytes reads SRB2 2.2.15 header with addons and time', () {
    final bytes = _buildReplayBytes(
      subversion: 15,
      demoVersion: 17,
      mapNumber: 1,
      addons: [
        ('cool_levels.pk3', List<int>.generate(16, (i) => i)),
        ('extra_char.wad', List<int>.filled(16, 0xFF)),
      ],
      timeTics: 35 * 62 + 7, // 1:02.20
      score: 54321,
      rings: 99,
      playerName: 'Player1',
      skin: 'tails',
      color: 'Orange',
    );

    final replay = ReplayScanner.parseBytes(
      bytes,
      path: r'C:\srb2\data\replay\main\MAP01-tails-time-best.lmp',
      relativePlayPath: r'replay\main\MAP01-tails-time-best.lmp',
      folder: 'main',
      size: bytes.length,
      modified: DateTime(2026, 1, 1),
    );

    expect(replay.validHeader, isTrue);
    expect(replay.versionLabel, '2.2.15');
    expect(replay.mapName, 'MAP01');
    expect(replay.addons, hasLength(2));
    expect(replay.addons[0].name, 'cool_levels.pk3');
    expect(replay.addons[0].md5, '000102030405060708090a0b0c0d0e0f');
    expect(replay.addons[1].name, 'extra_char.wad');
    expect(replay.addons[1].md5, 'ffffffffffffffffffffffffffffffff');
    expect(replay.formattedTime, '1:02.20');
    expect(replay.score, 54321);
    expect(replay.rings, 99);
    expect(replay.playerName, 'Player1');
    expect(replay.skin, 'tails');
    expect(replay.color, 'Orange');
    expect(replay.kind, ReplayKind.timeBest);
  });

  test('parseBytes handles demoversion < 16 and unfinished run', () {
    final bytes = _buildReplayBytes(
      subversion: 9,
      demoVersion: 14,
      mapNumber: 140,
      timeTics: 0xFFFFFFFF,
    );

    final replay = ReplayScanner.parseBytes(
      bytes,
      path: r'C:\srb2\data\replay\main\MAPB4-sonic-last.lmp',
      relativePlayPath: r'replay\main\MAPB4-sonic-last.lmp',
      folder: 'main',
      size: bytes.length,
      modified: DateTime(2026, 1, 1),
    );

    expect(replay.validHeader, isTrue);
    expect(replay.versionLabel, '2.2.9');
    expect(replay.mapName, 'MAPB4');
    expect(replay.addons, isEmpty);
    expect(replay.timeTics, isNull);
    expect(replay.formattedTime, '—');
    expect(replay.kind, ReplayKind.last);
  });

  test('groupDuplicates merges identical runs in the same folder', () {
    final checksum = List<int>.filled(16, 0x11);
    final b1 = _buildReplayBytes(checksum: checksum);
    ReplayFile makeFile(String folder, String name, {List<int>? sum}) => ReplayScanner.parseBytes(
          sum == null ? b1 : _buildReplayBytes(checksum: sum),
          path: p.join(folder, name),
          relativePlayPath: p.join('replay', folder, name),
          folder: folder,
          size: b1.length,
          modified: DateTime(2026, 1, 2),
        );

    final groups = ReplayScanner.groupDuplicates([
      makeFile('main', 'MAP01-sonic-rings-best.lmp'),
      makeFile('main', 'MAP01-sonic-last.lmp'),
      makeFile('main', 'MAP01-sonic-time-best.lmp'),
      makeFile('other', 'MAP01-sonic-last.lmp'),
      makeFile('main', 'MAP01-sonic-custom.lmp', sum: List<int>.filled(16, 0x22)),
    ]);

    expect(groups, hasLength(3));
    final merged = groups.firstWhere((g) => g.variants.length == 3);
    expect(merged.primary.kind, ReplayKind.last);
    expect(merged.variants.map((v) => v.kind), [
      ReplayKind.last,
      ReplayKind.timeBest,
      ReplayKind.ringsBest,
    ]);
  });

  test('importLocalFile copies into SRB2AL-Replays and resolves name collisions', () async {
    final temp = await Directory.systemTemp.createTemp('srb2_replay_test_');
    try {
      final gameFolder = p.join(temp.path, 'game');
      await Directory(gameFolder).create(recursive: true);
      final src = File(p.join(temp.path, 'MAP01-sonic-time-best.lmp'));
      await src.writeAsBytes(_buildReplayBytes(timeTics: 35 * 10));

      final first = await ReplayScanner.importLocalFile(src.path, gameFolder);
      final second = await ReplayScanner.importLocalFile(src.path, gameFolder);

      expect(first.folder, ReplayScanner.importedFolder);
      expect(first.isImported, isTrue);
      expect(first.relativePlayPath, p.join('SRB2AL-Replays', 'MAP01-sonic-time-best.lmp'));
      expect(File(first.path).existsSync(), isTrue);

      expect(second.fileName, 'MAP01-sonic-time-best (2).lmp');
      expect(File(second.path).existsSync(), isTrue);

      final scanned = await ReplayScanner.scanInBackground(gameFolder);
      expect(scanned, hasLength(2));
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test('patchHeaderAddons rewrites addon table and recomputes 0x10..0x1F checksum', () {
    final original = _buildReplayBytes(
      demoVersion: 17,
      addons: [
        ('old_addon.pk3', List<int>.filled(16, 0x12)),
      ],
      score: 9999,
      rings: 77,
      playerName: 'Tails',
      skin: 'tails',
      color: 'Orange',
    );

    final patched = ReplayScanner.patchHeaderAddons(original, [
      const ReplayAddon('main_pack.pk3', '00112233445566778899aabbccddeeff'),
      const ReplayAddon('L_SpectatorCamera_V2.3.lua', 'ffeeddccbbaa99887766554433221100'),
    ]);

    final expectedDigest = md5.convert(Uint8List.sublistView(patched, 0x20)).bytes;
    expect(Uint8List.sublistView(patched, 0x10, 0x20), expectedDigest);

    final parsed = ReplayScanner.parseBytes(
      patched,
      path: r'C:\srb2\SRB2AL-Replays\temp\replay.lmp',
      relativePlayPath: r'SRB2AL-Replays\temp\replay.lmp',
      folder: ReplayScanner.importedFolder,
      size: patched.length,
      modified: DateTime(2026, 1, 1),
    );
    expect(parsed.validHeader, isTrue);
    expect(parsed.score, 9999);
    expect(parsed.rings, 77);
    expect(parsed.playerName, 'Tails');
    expect(parsed.addons, hasLength(2));
    expect(parsed.addons[0].name, 'main_pack.pk3');
    expect(parsed.addons[0].md5, '00112233445566778899aabbccddeeff');
    expect(parsed.addons[1].name, 'L_SpectatorCamera_V2.3.lua');
    expect(parsed.addons[1].md5, 'ffeeddccbbaa99887766554433221100');
  });

  test('prepareTempReplay writes SRB2AL-Replays/temp/replay.lmp and scan ignores temp folder', () async {
    final temp = await Directory.systemTemp.createTemp('srb2_replay_temp_');
    try {
      final gameFolder = p.join(temp.path, 'game');
      final origReplay = File(p.join(gameFolder, 'data', 'replay', 'main', 'MAP01-sonic-last.lmp'));
      await origReplay.parent.create(recursive: true);
      await origReplay.writeAsBytes(_buildReplayBytes(
        addons: [('missing_addon.pk3', List<int>.filled(16, 0x55))],
      ));

      final luaFile = File(p.join(temp.path, 'L_SpectatorCamera_V2.3.lua'));
      await luaFile.writeAsString('-- camera script\n');
      final luaMd5 = md5.convert(await luaFile.readAsBytes()).toString();

      final relPlay = await ReplayScanner.prepareTempReplay(
        sourcePath: origReplay.path,
        gameFolder: gameFolder,
        addonFilePaths: [luaFile.path],
      );

      expect(relPlay, p.join('SRB2AL-Replays', 'temp', 'replay.lmp'));
      final tempFile = File(ReplayScanner.tempReplayPath(gameFolder));
      expect(tempFile.existsSync(), isTrue);

      final parsedTemp = ReplayScanner.parseBytes(
        await tempFile.readAsBytes(),
        path: tempFile.path,
        relativePlayPath: relPlay,
        folder: ReplayScanner.importedFolder,
        size: tempFile.lengthSync(),
        modified: DateTime.now(),
      );
      expect(parsedTemp.addons, hasLength(1));
      expect(parsedTemp.addons.single.name, 'L_SpectatorCamera_V2.3.lua');
      expect(parsedTemp.addons.single.md5, luaMd5);

      // В списке реплеев SRB2AL-Replays/temp/replay.lmp не должен появляться — только оригинал.
      final scanned = await ReplayScanner.scanInBackground(gameFolder);
      expect(scanned, hasLength(1));
      expect(scanned.single.path, origReplay.path);
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test('scans and parses SRB2 Legacy root replay/ folder replays (2.1.x, demover 11)', () async {
    final temp = await Directory.systemTemp.createTemp('srb2_legacy_replay_test_');
    try {
      final gameFolder = p.join(temp.path, 'legacy');
      final replayFile = File(p.join(gameFolder, 'replay', 'main', 'MAP01-sonic-last.lmp'));
      await replayFile.parent.create(recursive: true);
      await replayFile.writeAsBytes(_buildReplayBytes(
        version: 201,
        subversion: 30,
        demoVersion: 11,
        mapNumber: 1,
        timeTics: 571, // 0:16.31
        score: 101400,
        rings: 13,
        playerName: 'Sirexer',
        skin: 'sonic',
        color: 'Blue',
      ));

      final scanned = await ReplayScanner.scanInBackground(gameFolder);
      expect(scanned, hasLength(1));
      final r = scanned.single;
      expect(r.validHeader, isTrue);
      expect(r.versionLabel, '2.1.30');
      expect(r.demoVersion, 11);
      expect(r.mapName, 'MAP01');
      expect(r.formattedTime, '0:16.31');
      expect(r.score, 101400);
      expect(r.rings, 13);
      expect(r.playerName, 'Sirexer');
      expect(r.skin, 'sonic');
      expect(r.color, 'Blue');
      expect(r.addons, isEmpty);
      expect(r.folder, 'main');
      expect(r.relativePlayPath, p.join('replay', 'main', 'MAP01-sonic-last.lmp'));
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test('resolveAddonsByFolder finds level packs by SOC GameData and filename fallback', () async {
    final temp = await Directory.systemTemp.createTemp('srb2_folder_addon_test_');
    try {
      // Левелпак в PK3 с нестандартным именем файла, но MAINCFG/SOC GameData = kimokawaiii.dat
      final customPk3 = File(p.join(temp.path, 'pack_from_event_v1.pk3'))
        ..writeAsBytesSync(buildZip([
          ('soc/!MAIN.soc', utf8.encode('MainCfg\nGameData = kimokawaiii.dat\n')),
          ('maps/MAP01.wad', utf8.encode('PWAD')),
        ]));

      // Левелпак без GameData, но совпадающий по имени файла (`scr_sugoi_v1-2.wad` -> `sugoi`)
      final byNameWad = File(p.join(temp.path, 'scr_sugoi_v1-2.wad'));
      await byNameWad.writeAsString('PWAD');

      final matched = await ReplayScanner.resolveAddonsByFolder(
        folders: ['kimokawaiii', 'sugoi', 'main', 'unknown_mod'],
        candidatePacks: const [],
        allLocalAddons: [customPk3.path, byNameWad.path],
      );

      expect(matched['kimokawaiii'], [customPk3.path]);
      expect(matched['sugoi'], [byNameWad.path]);
      expect(matched.containsKey('main'), isFalse);
      expect(matched.containsKey('unknown_mod'), isFalse);
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test('parses and patches Ring Racers (\xf0KartReplay\x0f) in media/replay', () async {
    final temp = await Directory.systemTemp.createTemp('drrr_replay_test_');
    try {
      final gameFolder = p.join(temp.path, 'drrr');
      final replayFile = File(p.join(gameFolder, 'media', 'replay', 'ringracers', 'RR_765STADIUM-carol-lap-best.lmp'));
      await replayFile.parent.create(recursive: true);

      final bytes = _buildKartReplayBytes(
        subversion: 2,
        demoVersion: 12,
        title: '765 Stadium Zone - Record Attack',
        mapName: 'RR_765STADIUM',
        addons: [('CustomTrack.pk3', List<int>.filled(16, 0x33))],
        skins: ['eggman', 'sonic', 'carol'],
        standingsDemoSkin: 2,
        standingsName: 'Sirexer',
        standingsColor: 'Orange',
        standingsTime: 4005, // 1:54.42
      );
      await replayFile.writeAsBytes(bytes);

      final scanned = await ReplayScanner.scanInBackground(gameFolder);
      expect(scanned, hasLength(1));
      final r = scanned.single;
      expect(r.validHeader, isTrue);
      expect(r.isKart, isTrue);
      expect(r.supportsEmbeddedAddons, isTrue);
      expect(r.versionLabel, '2.2');
      expect(r.kind, ReplayKind.lapBest);
      expect(r.mapName, 'RR_765STADIUM');
      expect(r.title, '765 Stadium Zone - Record Attack');
      expect(r.gametype, 'Race');
      expect(r.addons, hasLength(1));
      expect(r.addons.single.name, 'CustomTrack.pk3');
      expect(r.playerName, 'Sirexer');
      expect(r.skin, 'carol');
      expect(r.color, 'Orange');
      expect(r.formattedTime, '1:54.42');
      expect(r.folder, 'ringracers');
      expect(r.relativePlayPath, p.join('media', 'replay', 'ringracers', 'RR_765STADIUM-carol-lap-best.lmp'));

      // Патчим заголовок (убираем/добавляем аддоны) и проверяем пересчёт 0x50..0x5F без standings
      final patched = ReplayScanner.patchHeaderAddons(bytes, [
        const ReplayAddon('A.pk3', '00112233445566778899aabbccddeeff'),
        const ReplayAddon('B.lua', 'ffeeddccbbaa99887766554433221100'),
      ]);
      final stMarker = utf8.encode('{i\tstandings[');
      var tailStart = -1;
      for (var i = patched.length - stMarker.length; i >= 0; i--) {
        var ok = true;
        for (var j = 0; j < stMarker.length; j++) {
          if (patched[i + j] != stMarker[j]) {
            ok = false;
            break;
          }
        }
        if (ok) {
          tailStart = i - 5;
          break;
        }
      }
      expect(tailStart, greaterThan(0x60));
      expect(
        Uint8List.sublistView(patched, 0x50, 0x60),
        md5.convert(Uint8List.sublistView(patched, 0x60, tailStart)).bytes,
      );
      final parsedPatched = ReplayScanner.parseBytes(
        patched,
        path: r.path,
        relativePlayPath: r.relativePlayPath,
        folder: r.folder,
        size: patched.length,
        modified: DateTime.now(),
      );
      expect(parsedPatched.addons.map((a) => a.name), ['A.pk3', 'B.lua']);
      expect(parsedPatched.playerName, 'Sirexer');
      expect(parsedPatched.skin, 'carol');
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test('parses and patches SRB2Kart (v1.x, demover 2) Time Attack and online replays in replay/', () async {
    final temp = await Directory.systemTemp.createTemp('srb2kart_replays_');
    try {
      final taDir = Directory(p.join(temp.path, 'replay', 'kart'));
      final onlineDir = Directory(p.join(temp.path, 'replay', 'online'));
      await taDir.create(recursive: true);
      await onlineDir.create(recursive: true);

      final taBytes = _buildSrb2KartReplayBytes(
        subversion: 6,
        title: 'Green Hills Zone - Time Attack',
        mapNumber: 1,
        demoFlags: 0x03,
        gametype: 0,
        timeTics: 3688,
        playerName: '{RU}Sirexer',
        skin: 'sonic',
        color: 'Orange',
      );
      await File(p.join(taDir.path, 'MAP01-sonic-last.lmp')).writeAsBytes(taBytes);

      final addonMd5 = List<int>.generate(16, (i) => i + 0x20);
      final onBytes = _buildSrb2KartReplayBytes(
        subversion: 3,
        title: 'Dirty Desert Rush - Server',
        mapNumber: 584,
        demoFlags: 0xA1,
        gametype: 0,
        addons: [('KL_Host.pk3', addonMd5)],
        timeTics: 6199,
        playerName: 'Winner',
        skin: 'quote',
        color: 'Navy',
      );
      final onPath = p.join(onlineDir.path, 'race.lmp');
      await File(onPath).writeAsBytes(onBytes);

      final list = await ReplayScanner.scanInBackground(temp.path);
      expect(list, hasLength(2));
      final ta = list.firstWhere((r) => r.folder == 'kart');
      expect(ta.validHeader, isTrue);
      expect(ta.isKart, isTrue);
      expect(ta.versionLabel, '1.6');
      expect(ta.mapName, 'MAP01');
      expect(ta.gametype, 'Race');
      expect(ta.timeTics, 3688);
      expect(ta.playerName, '{RU}Sirexer');
      expect(ta.skin, 'sonic');
      expect(ta.color, 'Orange');
      expect(ta.addons, isEmpty);

      final on = list.firstWhere((r) => r.folder == 'online');
      expect(on.validHeader, isTrue);
      expect(on.supportsEmbeddedAddons, isTrue);
      expect(on.versionLabel, '1.3');
      expect(on.mapName, 'MAPNG');
      expect(on.addons.map((a) => a.name), ['KL_Host.pk3']);
      expect(on.playerName, 'Winner');
      expect(on.skin, 'quote');
      expect(on.color, 'Navy');
      expect(on.timeTics, 6199);

      final patched = ReplayScanner.patchHeaderAddons(onBytes, const [
        ReplayAddon('Extra.lua', '00112233445566778899aabbccddeeff'),
      ]);
      final marker = _findLastBytes(patched, const [0xFF, 0x80]);
      expect(marker, greaterThan(0x79));
      expect(
        Uint8List.sublistView(patched, 0x50, 0x60),
        md5.convert(Uint8List.sublistView(patched, 0x60, marker + 2)).bytes,
      );
      final reparsed = ReplayScanner.parseBytes(
        patched,
        path: on.path,
        relativePlayPath: on.relativePlayPath,
        folder: on.folder,
        size: patched.length,
        modified: DateTime.now(),
      );
      expect(reparsed.addons.map((a) => a.name), ['Extra.lua']);
      expect(reparsed.playerName, 'Winner');
      expect(reparsed.timeTics, 6199);
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test('parses and patches BlanKart (ðBlanReplay ) in media/replay and resolves XXH3 addons', () async {
    final temp = await Directory.systemTemp.createTemp('blankart_replays_');
    try {
      final replayDir = Directory(p.join(temp.path, 'media', 'replay', 'online', 'v2.0'));
      final addonsDir = Directory(p.join(temp.path, 'addons'));
      await replayDir.create(recursive: true);
      await addonsDir.create(recursive: true);

      final addonFile = File(p.join(addonsDir.path, 'KR_Pack.pk3'));
      final addonData = Uint8List.fromList(utf8.encode('blankart-addon-payload'));
      await addonFile.writeAsBytes(addonData);
      final xxhHex = FileHash.xxh3Hex(addonData);
      expect(xxhHex.length, 16);

      final xxhBytes = <int>[
        for (var i = 0; i < 8; i++) int.parse(xxhHex.substring(i * 2, i * 2 + 2), radix: 16),
      ];
      final blanBytes = _buildBlanKartReplayBytes(
        title: 'Midnight Channel - BlanKart server',
        mapName: 'MAP30',
        gametype: 'kart',
        addons: [('KR_Pack.pk3', xxhBytes, 1)],
        playerName: 'Dogima',
        skin: 'kiryu',
        color: 'Grey',
        timeTics: 5026,
      );
      final lmpPath = p.join(replayDir.path, 'blan.lmp');
      await File(lmpPath).writeAsBytes(blanBytes);

      final list = await ReplayScanner.scanInBackground(temp.path);
      expect(list, hasLength(1));
      final r = list.single;
      expect(r.validHeader, isTrue);
      expect(r.isKart, isTrue);
      expect(r.isBlan, isTrue);
      expect(r.versionLabel, '2.0');
      expect(r.mapName, 'MAP30');
      expect(r.gametype, 'Race');
      expect(r.folder, p.join('online', 'v2.0'));
      expect(r.relativePlayPath, p.join('media', 'replay', 'online', 'v2.0', 'blan.lmp'));
      expect(r.playerName, 'Dogima');
      expect(r.skin, 'kiryu');
      expect(r.color, 'Grey');
      expect(r.timeTics, 5026);
      expect(r.addons, hasLength(1));
      expect(r.addons.single.name, 'KR_Pack.pk3');
      expect(r.addons.single.md5, xxhHex);
      expect(r.addons.single.compatMode, 1);

      final index = await LocalFileIndex.build(temp.path);
      expect(await index.findByName('KR_Pack.pk3', xxhHex), addonFile.path);
      expect(await index.findByName('KR_Pack.pk3', '0000000000000000'), isNull);

      final tempRel = await ReplayScanner.prepareTempReplay(
        sourcePath: lmpPath,
        gameFolder: temp.path,
        addonFilePaths: [addonFile.path],
      );
      expect(tempRel, ReplayScanner.tempReplayRelativePlayPath());
      final patchedBytes = await File(ReplayScanner.tempReplayPath(temp.path)).readAsBytes();
      final marker = _findLastBytes(patchedBytes, const [0xFF, 0x80]);
      final expectedH = xxh3(patchedBytes.sublist(0x60, marker + 2));
      for (var i = 0; i < 8; i++) {
        expect(patchedBytes[0x50 + i], (expectedH >> (8 * i)) & 0xFF);
      }
      final parsedPatched = ReplayScanner.parseBytes(
        patchedBytes,
        path: r.path,
        relativePlayPath: tempRel,
        folder: r.folder,
        size: patchedBytes.length,
        modified: DateTime.now(),
      );
      expect(parsedPatched.addons.single.md5, xxhHex);
      expect(parsedPatched.addons.single.compatMode, 1);
      expect(parsedPatched.playerName, 'Dogima');
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test('finds root bonuschars.kart by name when MD5 differs and updates hash via temp replay', () async {
    final temp = await Directory.systemTemp.createTemp('kart_root_addon_');
    try {
      final replayDir = Directory(p.join(temp.path, 'replay', 'online'));
      await replayDir.create(recursive: true);
      final rootAddon = File(p.join(temp.path, 'bonuschars.kart'));
      final diskBytes = Uint8List.fromList(utf8.encode('bonuschars-v1.6-disk'));
      await rootAddon.writeAsBytes(diskBytes);
      final diskMd5 = md5.convert(diskBytes).toString();

      final oldMd5Bytes = List<int>.filled(16, 0x43);
      final onBytes = _buildSrb2KartReplayBytes(
        subversion: 3,
        addons: [('bonuschars.kart', oldMd5Bytes)],
      );
      final lmpPath = p.join(replayDir.path, 'race.lmp');
      await File(lmpPath).writeAsBytes(onBytes);

      final index = await LocalFileIndex.build(temp.path);
      expect(await index.findByName('bonuschars.kart', '43' * 16), isNull);
      expect(index.firstByName('bonuschars.kart'), rootAddon.path);

      final tempRel = await ReplayScanner.prepareTempReplay(
        sourcePath: lmpPath,
        gameFolder: temp.path,
        addonFilePaths: [rootAddon.path],
      );
      expect(tempRel, ReplayScanner.tempReplayRelativePlayPath());
      final patchedBytes = await File(ReplayScanner.tempReplayPath(temp.path)).readAsBytes();
      final reparsed = ReplayScanner.parseBytes(
        patchedBytes,
        path: lmpPath,
        relativePlayPath: tempRel,
        folder: 'online',
        size: patchedBytes.length,
        modified: DateTime.now(),
      );
      expect(reparsed.addons.single.name, 'bonuschars.kart');
      expect(reparsed.addons.single.md5, diskMd5);
    } finally {
      await temp.delete(recursive: true);
    }
  });
}

int _findLastBytes(Uint8List hay, List<int> needle) {
  for (var i = hay.length - needle.length; i >= 0; i--) {
    var ok = true;
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return -1;
}

void _writeFixed(BytesBuilder out, String s, int len) {
  final b = latin1.encode(s);
  for (var i = 0; i < len; i++) {
    out.addByte(i < b.length ? b[i] : 0);
  }
}

Uint8List _buildSrb2KartReplayBytes({
  int subversion = 6,
  String title = 'SRB2Kart',
  int mapNumber = 1,
  int demoFlags = 0xA1,
  int gametype = 0,
  List<(String, List<int>)> addons = const [],
  int timeTics = 3500,
  String playerName = 'Sonic',
  String skin = 'sonic',
  String color = 'Blue',
}) {
  final out = BytesBuilder();
  out.add(const [0xF0, 0x4B, 0x61, 0x72, 0x74, 0x52, 0x65, 0x70, 0x6C, 0x61, 0x79, 0x0F]);
  out.add([1, subversion, 2, 0]);
  _writeFixed(out, title, 64);
  out.add(List<int>.filled(16, 0)); // MD5 placeholder 0x50..0x5F
  out.add(latin1.encode('PLAY'));
  out.add([mapNumber & 0xFF, (mapNumber >> 8) & 0xFF]);
  out.add(List<int>.filled(16, 0xAA)); // mapmd5
  out.addByte(demoFlags);
  out.addByte(gametype);
  out.addByte(addons.length);
  for (final (name, sum) in addons) {
    out.add(latin1.encode(name));
    out.addByte(0);
    out.add(sum);
  }
  if ((demoFlags & 0x02) != 0) {
    out.add([
      timeTics & 0xFF,
      (timeTics >> 8) & 0xFF,
      (timeTics >> 16) & 0xFF,
      (timeTics >> 24) & 0xFF,
      0x58, 0x04, 0x00, 0x00,
      0x01, 0x02, 0x03, 0x04,
      0x10, 0x00, 0x00, 0x00,
    ]);
    out.add(const [0x01, 0x00, 0xCE, 0x18, 0x33, 0x00, 0x00, 0x00]); // 1 netvar + slot prefix
    out.add(latin1.encode(playerName));
    out.addByte(0);
    _writeFixed(out, skin, 16);
    _writeFixed(out, color, 16);
    out.add(const [0x00, 0x10, 0xFF]);
    final full = out.takeBytes();
    full.setRange(0x50, 0x60, md5.convert(Uint8List.sublistView(full, 0x60, full.length - 1)).bytes);
    return full;
  }

  out.add(const [0x01, 0x02, 0x03, 0x04, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00]); // seed + tics + 0 netvars
  out.add(const [0x01, 0x10, 0x01, 0xFF, 0x80]);
  final checksumEnd = out.length;
  out.add(const [0x00, 0x01]);
  _writeFixed(out, playerName, 16);
  _writeFixed(out, skin, 16);
  _writeFixed(out, color, 16);
  out.add([
    timeTics & 0xFF,
    (timeTics >> 8) & 0xFF,
    (timeTics >> 16) & 0xFF,
    (timeTics >> 24) & 0xFF,
    0xFE, 0xFF, 0xFF, 0xFF, 0xFF,
  ]);
  final full = out.takeBytes();
  full.setRange(0x50, 0x60, md5.convert(Uint8List.sublistView(full, 0x60, checksumEnd)).bytes);
  return full;
}

Uint8List _buildBlanKartReplayBytes({
  String title = 'BlanKart server',
  String mapName = 'MAP30',
  String gametype = 'kart',
  List<(String, List<int>, int)> addons = const [],
  String playerName = 'Dogima',
  String skin = 'kiryu',
  String color = 'Grey',
  int timeTics = 5000,
}) {
  final out = BytesBuilder();
  out.add(const [0xF0, 0x42, 0x6C, 0x61, 0x6E, 0x52, 0x65, 0x70, 0x6C, 0x61, 0x79, 0x0F]);
  out.add([2, 0, 17, 0]);
  _writeFixed(out, title, 64);
  out.add(List<int>.filled(8, 0)); // XXH3 placeholder 0x50..0x57
  out.add(latin1.encode('PLAY'));
  out.add(latin1.encode(mapName));
  out.addByte(0);
  out.add(List<int>.filled(8, 0xEE)); // maphash
  out.addByte(0xA1); // demoflags
  for (final s in [gametype, 'BlanKart server', '', 'Welcome!']) {
    out.add(latin1.encode(s));
    out.addByte(0);
  }
  out.add(const [0x00, 0x02]); // extra bytes before numAddons
  out.addByte(addons.length);
  for (final (name, sum8, compat) in addons) {
    out.add(latin1.encode(name));
    out.addByte(0);
    out.add(sum8);
    out.addByte(compat);
  }
  out.add(const [0x11, 0x22, 0x33, 0x44, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00]); // seed + tics + 0 netvars
  out.add(const [0x01, 0x10, 0x01, 0xFF, 0x80]);
  final checksumEnd = out.length;
  out.add(const [0x00, 0x01]);
  for (final s in [playerName, skin, color]) {
    out.add(latin1.encode(s));
    out.addByte(0);
  }
  out.add([
    timeTics & 0xFF,
    (timeTics >> 8) & 0xFF,
    (timeTics >> 16) & 0xFF,
    (timeTics >> 24) & 0xFF,
    0xFE, 0xFF, 0xFF, 0xFF, 0xFF,
  ]);
  final full = out.takeBytes();
  final h = xxh3(full.sublist(0x60, checksumEnd));
  for (var i = 0; i < 8; i++) {
    full[0x50 + i] = (h >> (8 * i)) & 0xFF;
  }
  return full;
}

Uint8List _buildKartReplayBytes({
  int version = 2,
  int subversion = 2,
  int demoVersion = 12,
  String title = 'Ring Racers',
  String mapName = 'RR_TEST',
  String gametype = 'Race',
  List<(String, List<int>)> addons = const [],
  List<String> skins = const ['sonic'],
  int standingsDemoSkin = 0,
  String standingsName = 'Player',
  String standingsColor = 'Blue',
  int standingsTime = 3500,
}) {
  final out = BytesBuilder();
  out.add(const [0xF0, 0x4B, 0x61, 0x72, 0x74, 0x52, 0x65, 0x70, 0x6C, 0x61, 0x79, 0x0F]);
  out.add([version, subversion, demoVersion, 0]);
  final titleBytes = latin1.encode(title);
  for (var i = 0; i < 64; i++) {
    out.addByte(i < titleBytes.length ? titleBytes[i] : 0);
  }
  out.add(List<int>.filled(16, 0)); // placeholder checksum at 0x50..0x5F
  out.add(latin1.encode('PLAY'));
  out.add(latin1.encode(mapName));
  out.addByte(0);
  out.add(List<int>.filled(16, 0xCD)); // mapmd5
  out.add(const [0x0B, 0x00]); // demoflags
  out.add(latin1.encode(gametype));
  out.addByte(0);
  out.addByte(5); // speed/flags
  out.addByte(addons.length);
  for (final (name, sum) in addons) {
    out.add(latin1.encode(name));
    out.addByte(0);
    out.add(sum);
  }
  out.addByte(skins.length);
  for (final s in skins) {
    final sb = latin1.encode(s);
    for (var i = 0; i < 16; i++) {
      out.addByte(i < sb.length ? sb[i] : 0);
    }
    out.add(const [2, 2, 0, 0, 0, 0]);
  }
  out.add(const [0x00, 0x10, 0x01, 0xFF, 0x80]); // dummy demo tics
  final tailStart = out.length;

  final ub = BytesBuilder();
  void ubStr(String s) {
    final b = latin1.encode(s);
    ub.addByte(0x69); // 'i'
    ub.addByte(b.length);
    ub.add(b);
  }

  ub.addByte(0x7B); // '{'
  ubStr('standings');
  ub.addByte(0x5B); // '['
  ub.addByte(0x7B); // '{'
  ubStr('demoskin');
  ub.add([0x69, standingsDemoSkin]);
  ubStr('name');
  ub.addByte(0x53);
  ubStr(standingsName);
  ubStr('skincolor');
  ub.addByte(0x53);
  ubStr(standingsColor);
  ubStr('timeorscore');
  ub.add([0x6C, (standingsTime >> 24) & 0xFF, (standingsTime >> 16) & 0xFF, (standingsTime >> 8) & 0xFF, standingsTime & 0xFF]);
  ub.add([0x7D, 0x5D, 0x7D]); // '}]}'
  final ubBytes = ub.takeBytes();

  out.addByte(0x01);
  out.add([
    ubBytes.length & 0xFF,
    (ubBytes.length >> 8) & 0xFF,
    (ubBytes.length >> 16) & 0xFF,
    (ubBytes.length >> 24) & 0xFF,
  ]);
  out.add(ubBytes);
  out.addByte(0xFF);

  final full = out.takeBytes();
  full.setRange(0x50, 0x60, md5.convert(Uint8List.sublistView(full, 0x60, tailStart)).bytes);
  return full;
}
