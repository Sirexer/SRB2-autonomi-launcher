import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:srb2_autonomi_launcher/models/game.dart';
import 'package:srb2_autonomi_launcher/models/srb2_server.dart';
import 'package:srb2_autonomi_launcher/services/custom_games.dart';

/// packaging/another_games.json, что идёт со сборкой, читается.
void main() {
  test('bundled another_games.json: BlanKart', () {
    final defs = CustomGames.parse(File('packaging/another_games.json').readAsStringSync());
    final games = [for (final d in defs) Games.fromDefinition(d)];
    final blan = games.single;
    expect((blan.id, blan.name, blan.engine, blan.isCustom), ('srb2blankart', 'BlanKart', 'srb2kart', true));
    // Протокол описан в файле целиком — совпадает со встроенным.
    expect(defs.single['protocol'], isA<Map>());
    final p = blan.protocol, b = NetProtocol.blankart;
    expect([
      p.application, p.packetVersion, p.version, p.subversion, p.hasPacketVersionPrefix, p.formatVersion(2, 0),
      p.ptClientQuit, p.ptAskInfo, p.ptServerInfo, p.ptPlayerInfo, p.ptRequestFile, p.ptFileFragment, p.ptFileAck,
      p.ptFileReceived, p.ptTellFilesNeeded, p.ptMoreFilesNeeded, p.fileEntryHasFolder, p.fileHashBytes,
      p.fileEntryExtra, p.preloadFiles, p.playerInfoSize, p.offPlayerTeam, p.offPlayerSkin, p.playerSkinWide, p.offPlayerScore,
      p.offPlayerTime, p.requestFileWithName, p.legacyFileTransfer, p.gametypeNames, p.baseSkins, p.willSend(1),
      p.willSend(2), p.willSend(0), p.offApplication, p.offVersion, p.offPlayers, p.offRefuseReason, p.offGametype,
      p.offModified, p.offFlags, p.offFileCount, p.offLevelTime, p.offServerName, p.offMapName, p.offMapTitle,
      p.offActNum, p.offIsZone, p.offHttpSource, p.offAvgPowerLevel, p.offFileNeeded,
    ], [
      b.application, b.packetVersion, b.version, b.subversion, b.hasPacketVersionPrefix, b.formatVersion(2, 0),
      b.ptClientQuit, b.ptAskInfo, b.ptServerInfo, b.ptPlayerInfo, b.ptRequestFile, b.ptFileFragment, b.ptFileAck,
      b.ptFileReceived, b.ptTellFilesNeeded, b.ptMoreFilesNeeded, b.fileEntryHasFolder, b.fileHashBytes,
      b.fileEntryExtra, b.preloadFiles, b.playerInfoSize, b.offPlayerTeam, b.offPlayerSkin, b.playerSkinWide, b.offPlayerScore,
      b.offPlayerTime, b.requestFileWithName, b.legacyFileTransfer, b.gametypeNames, b.baseSkins, b.willSend(1),
      b.willSend(2), b.willSend(0), b.offApplication, b.offVersion, b.offPlayers, b.offRefuseReason, b.offGametype,
      b.offModified, b.offFlags, b.offFileCount, b.offLevelTime, b.offServerName, b.offMapName, b.offMapTitle,
      b.offActNum, b.offIsZone, b.offHttpSource, b.offAvgPowerLevel, b.offFileNeeded,
    ]);
    expect(blan.serversUrl('https://ms.blankart.cc/MS/1'),
        'https://ms.blankart.cc/MS/1/games/SRB2Kart/12/servers?v=2.2');
    expect(blan.addonBase, 'srb2kart');
    expect(blan.downloadPath, ['addons', 'DOWNLOAD']); // как у самой игры (d_main.cpp: addonsdir/DOWNLOAD)
    expect(blan.protocol.preloadFiles, isFalse);
    expect(blan.ownAddonFiles, contains('main.pk3'));
    expect((defs.single['icon'] as String).startsWith('data:image/png;base64,'), isTrue);
  });
}
