import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:srb2_autonomi_launcher/models/game.dart';
import 'package:srb2_autonomi_launcher/models/srb2_server.dart';
import 'package:srb2_autonomi_launcher/services/custom_games.dart';

/// Пакеты BlanKart, собранные поле за полем по его src/d_clisrv.h
/// (serverinfo_pak, plrinfo) и d_netfil.c (PutFileNeeded).
void main() {
  // Встроенный протокол и тот же, описанный в packaging/another_games.json.
  final fromJson = Games.fromDefinition(
          CustomGames.parse(File('packaging/another_games.json').readAsStringSync()).single)
      .protocol;
  for (final (label, proto) in [('built-in', NetProtocol.blankart), ('another_games.json', fromJson)]) {
    group(label, () => packets(proto));
  }

  test('protocol by name for custom games', () {
    expect(NetProtocol.byName('BlanKart'), same(NetProtocol.blankart));
    expect(NetProtocol.byName('drrr'), same(NetProtocol.ringRacers));
    expect(NetProtocol.byName('nope'), isNull);
  });

  test('protocol object: base and differences', () {
    final p = NetProtocol.fromJson({
      'base': 'srb2kart',
      'packet_version': 7,
      'packets': {'tell_files_needed': 40},
      'server_info': {'refuse_reason': 21, 'map_name': null},
      'gametype_names': {'2': 'Race', '5': 'Sprint'},
    });
    expect((p.application, p.packetVersion, p.ptTellFilesNeeded, p.ptMoreFilesNeeded), ('SRB2Kart', 7, 40, 33));
    expect((p.offRefuseReason, p.offMapName, p.offFileNeeded), (21, null, 382));
    expect(p.gametypeNames, {2: 'Race', 5: 'Sprint'});
    expect(p.legacyFileTransfer, isTrue); // от основы
    expect(p.formatVersion(1, 6), '1.6');
  });

  test('protocol errors', () {
    for (final (v, error) in [
      ('nope', 'unknown protocol "nope"'),
      ({'packet_version': 2}, 'needs "base"'),
      ({'base': 'x'}, 'unknown protocol base "x"'),
      ({'base': 'srb2', 'packets': {'ask_info': 'a'}}, 'packets."ask_info"'),
      ({'base': 'srb2', 'will_send': 'maybe'}, '"will_send"'),
      ({'base': 'srb2', 'version_format': 'x'}, '"version_format"'),
    ]) {
      expect(() => NetProtocol.fromJson(v), throwsA(isA<FormatException>().having((e) => e.message, 'message', contains(error))));
    }
    expect(
        () => Games.fromDefinition({'id': 'fork', 'name': 'Fork', 'base': 'srb2', 'protocol': {'base': 'x'}}),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', startsWith('fork: '))));
  });
}

void packets(NetProtocol proto) {
  List<int> str(String s, int len) => [...ascii.encode(s), ...List.filled(len - s.length, 0)];
  List<int> u16(int v) => [v & 0xFF, v >> 8];
  List<int> u32(int v) => [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

  test('serverinfo: packetversion 2, 8-byte maphash, files with a 64-bit hash', () {
    final b = <int>[
      255, 2, // _255, packetversion
      ...str('SRB2Kart', 16), // application
      2, 0, // version, subversion ("2.0")
      1, 2, 3, 4, // commit
      5, 16, 0, // players, maxplayer, refusereason
      ...str('Race', 24), // gametypename
      1, 0, 0x20, // modifiedgame, cheatsenabled, kartvars
      3, // fileneedednum
      ...u32(0), ...u32(35 * 90), // time, leveltime
      ...str('Blan Server', 32),
      ...str('Green Hills', 33),
      ...List.filled(8, 0xAB), // maphash
      1, 1, // actnum, iszone
      ...str('', 256), // httpsource
      ...u16(5000), // avgpwrlv
      // fileneeded: status, size, name\0, hash(8), compatmode
      // статус: старшие 4 бита — WILLSEND_YES 0, WILLSEND_NO 1, WILLSEND_TOOLARGE 2
      0x01, ...u32(1234), ...ascii.encode('blan.pk3'), 0, ...List.filled(8, 0x11), 0,
      0x11, ...u32(99), ...ascii.encode('nope.wad'), 0, ...List.filled(8, 0x22), 1,
      0x21, ...u32(5), ...ascii.encode('big.pk3'), 0, ...List.filled(8, 0x33), 0,
    ];
    expect(b.length - 3 * (1 + 4 + 8 + 1) - 9 - 9 - 8, proto.offFileNeeded); // смещения сходятся со структурой
    final info = Srb2Codec.parseServerInfo(Srb2Codec.buildPacket(proto.ptServerInfo, b), proto)!;
    expect((info.application, info.version, info.subversion, info.players, info.maxPlayers), ('SRB2Kart', 2, 0, 5, 16, ));
    expect((info.gametype, info.name, info.mapTitle, info.actNum, info.avgPowerLevel), ('Race', 'Blan Server', 'Green Hills', 1, 5000));
    expect(info.levelTimeTics, 35 * 90);
    expect([for (final f in info.files) (f.name, f.size, f.md5, f.willSend)], [
      ('blan.pk3', 1234, '1111111111111111', ServerFileSend.yes),
      ('nope.wad', 99, '2222222222222222', ServerFileSend.no),
      ('big.pk3', 5, '3333333333333333', ServerFileSend.tooLarge),
    ]);
    // Другая версия пакета (Ring Racers — 0) — не BlanKart.
    b[1] = 0;
    expect(Srb2Codec.parseServerInfo(Srb2Codec.buildPacket(proto.ptServerInfo, b), proto), isNull);
  });

  test('playerinfo: 33-byte records, 16-bit skin', () {
    List<int> player(int num, String name, int team, int skin, int score, int seconds) =>
        [num, ...str(name, 22), team, ...u16(skin), 0, ...u32(score), ...u16(seconds)];
    final b = <int>[
      ...player(0, 'Sirexer', 0, 3, 120, 60),
      ...player(255, '', 0, 0, 0, 0), // пустой слот
      ...player(2, 'Tester', 255, 0xFFFF, 0, 5),
      for (var i = 3; i < 32; i++) ...player(255, '', 0, 0, 0, 0),
    ];
    expect(b.length, 32 * 33);
    final players = Srb2Codec.parsePlayerInfo(Srb2Codec.buildPacket(proto.ptPlayerInfo, b), proto);
    expect([for (final p in players) (p.num, p.name, p.team, p.skinName, p.score, p.secondsInServer)], [
      (0, 'Sirexer', 0, 'Eggman', 120, 60),
      (2, 'Tester', 255, '', 0, 5),
    ]);
  });
}
