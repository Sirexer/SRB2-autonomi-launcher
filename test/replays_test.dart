import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:srb2_autonomi_launcher/services/replays.dart';

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
}
