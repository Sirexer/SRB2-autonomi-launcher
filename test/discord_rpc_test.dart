import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:srb2_autonomi_launcher/i18n.dart';
import 'package:srb2_autonomi_launcher/services/discord_rpc.dart';

void main() {
  test('IPC framing round-trips UTF-8 JSON and handles split packets', () {
    final frame1 = encodeDiscordIpcFrame(0, {'v': 1, 'client_id': DiscordRpcService.defaultApplicationId});
    final frame2 = encodeDiscordIpcFrame(1, {'cmd': 'SET_ACTIVITY', 'text': 'Привет, SRB2!'});
    final combined = Uint8List.fromList([...frame1, ...frame2]);

    // Неполный буфер не теряет хвост и ждёт остатка.
    final partial = decodeDiscordIpcFrames(Uint8List.sublistView(combined, 0, frame1.length + 5));
    expect(partial.$1.length, 1);
    expect(partial.$1.first.$1, 0);
    expect(partial.$2, frame1.length);

    final full = decodeDiscordIpcFrames(combined);
    expect(full.$1.length, 2);
    expect(full.$1[0].$2['client_id'], '1576010079444926635');
    expect(full.$1[1].$2['text'], 'Привет, SRB2!');
    expect(full.$2, combined.length);
  });

  test('DiscordPresence clamps fields to Discord limits and formats activity JSON', () {
    final longState = 'A' * 150;
    final p = DiscordPresence(
      type: 2,
      details: 'X',
      state: longState,
      startMs: 1700000000500,
      endMs: 1700000120500,
      largeImage: 'srb2',
      largeText: 'Sonic Robo Blast 2',
      smallImage: 'music',
      smallText: 'Music player',
    );
    final json = p.toActivityJson();
    expect(json['type'], 2);
    expect(json['details'], 'X '); // >= 2 символов
    expect((json['state'] as String).length, 128);
    expect((json['state'] as String).endsWith('...'), isTrue);
    expect(json['timestamps'], {'start': 1700000000, 'end': 1700000120});
    expect(json['assets'], {
      'large_image': 'srb2',
      'large_text': 'Sonic Robo Blast 2',
      'small_image': 'music',
      'small_text': 'Music player',
    });

    // Корректное JSON-кодирование без исключений.
    expect(jsonDecode(jsonEncode(json)), isA<Map<String, Object?>>());
  });

  test('buildLauncherPresence reflects tabs and active music player', () async {
    await I18n.instance.load('en');
    final browsing = buildLauncherPresence(
      gameId: 'srb2',
      gameName: 'Sonic Robo Blast 2',
      tab: 'addons',
      sessionStartMs: 1000000,
      selectedModName: 'Emerald Pack',
    );
    expect(browsing.type, 0);
    expect(browsing.details, 'Sonic Robo Blast 2');
    expect(browsing.state, 'Browsing addons: Emerald Pack');
    expect(browsing.largeImage, 'launcher');
    expect(browsing.smallImage, 'srb2');

    final launch = buildLauncherPresence(
      gameId: 'srb2kart',
      gameName: 'SRB2Kart',
      tab: 'launch',
      sessionStartMs: 1000000,
      queueCount: 5,
    );
    expect(launch.state, 'Ready to launch (5 addons)');

    final serverTab = buildLauncherPresence(
      gameId: 'srb2',
      gameName: 'Sonic Robo Blast 2',
      tab: 'servers',
      sessionStartMs: 1000000,
      selectedServerName: "Sonic's Hangout (4/16)",
    );
    expect(serverTab.type, 0);
    expect(serverTab.state, "Server: Sonic's Hangout (4/16)");

    final listening = buildLauncherPresence(
      gameId: 'srb2',
      gameName: 'Sonic Robo Blast 2',
      tab: 'addons',
      sessionStartMs: 1000000,
      playingTrack: (
        title: 'Greenflower Zone Act 1',
        authors: 'JTE',
        gameId: 'srb2',
        sourceName: 'Emerald Pack',
        duration: const Duration(seconds: 95),
        startMs: 2000000,
      ),
    );
    expect(listening.type, 2);
    expect(listening.details, 'Greenflower Zone Act 1');
    expect(listening.state, 'JTE');
    expect(listening.startMs, 2000000);
    expect(listening.endMs, 2095000);
    expect(listening.largeImage, 'launcher');
    expect(listening.largeText, 'Emerald Pack');
    expect(listening.smallImage, 'music');
    expect(listening.smallText, 'Music player');

    final listeningFile = buildLauncherPresence(
      gameId: 'srb2',
      gameName: 'Sonic Robo Blast 2',
      tab: 'player',
      sessionStartMs: 1000000,
      playingTrack: (
        title: 'Custom Song',
        authors: '',
        gameId: '',
        sourceName: 'custom_track.ogg',
        duration: null,
        startMs: 2000000,
      ),
    );
    expect(listeningFile.type, 2);
    expect(listeningFile.state, 'Music player');
    expect(listeningFile.largeImage, 'launcher');
    expect(listeningFile.largeText, 'custom_track.ogg');
    expect(listeningFile.smallImage, 'music');

    final watching = buildLauncherPresence(
      gameId: 'srb2',
      gameName: 'Sonic Robo Blast 2',
      tab: 'replays',
      sessionStartMs: 1000000,
      playingTrack: (
        title: 'Ignored',
        authors: '',
        gameId: 'srb2',
        sourceName: 'srb2.pk3',
        duration: null,
        startMs: 2000000,
      ),
      watchingReplay: (
        gameId: 'srb2',
        gameName: 'Sonic Robo Blast 2',
        character: 'Sonic',
        levelPack: 'Mystic Realm',
        map: 'MAP01 — Jade Valley',
        startMs: 3000000,
      ),
    );
    expect(watching.type, 3);
    expect(watching.details, 'Mystic Realm · MAP01 — Jade Valley');
    expect(watching.state, 'Character: Sonic');
    expect(watching.startMs, 3000000);
    expect(watching.largeImage, 'launcher');
    expect(watching.smallImage, 'srb2');
  });

  test('isProcessAlive detects current pid and invalid pid', () {
    expect(isProcessAlive(pid), isTrue);
    expect(isProcessAlive(-1), isFalse);
  });

  test('DiscordRpcService updates and disposes cleanly', () async {
    final rpc = DiscordRpcService();
    expect(rpc.enabled, isFalse);
    expect(DiscordRpcService.defaultApplicationId, '1576010079444926635');
    rpc.update(const DiscordPresence(details: 'Sonic Robo Blast 2', state: 'Browsing addons'));
    await rpc.setEnabled(true);
    rpc.clear();
    await rpc.setEnabled(false);
    rpc.dispose();
  });
}
