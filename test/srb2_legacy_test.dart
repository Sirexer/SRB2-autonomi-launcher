import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:srb2_autonomi_launcher/models/game.dart';
import 'package:srb2_autonomi_launcher/models/srb2_server.dart';
import 'package:srb2_autonomi_launcher/services/legacy_master.dart';
import 'package:srb2_autonomi_launcher/services/servers_store.dart';

/// Сообщение мастер-сервера 2.1: заголовок (id, type, room, length) и данные.
Uint8List msMessage(int type, List<int> body) {
  final b = ByteData(16)
    ..setInt32(4, type, Endian.big)
    ..setUint32(12, body.length, Endian.big);
  return Uint8List.fromList([...b.buffer.asUint8List(), ...body]);
}

/// msg_ext_server_t (108 байт).
Uint8List extServer(String ip, String port, String name, int room, String version) {
  final b = Uint8List(108);
  void put(int at, String s) => b.setRange(at, at + s.length, s.codeUnits);
  put(16, ip);
  put(56, port);
  put(64, name);
  ByteData.sublistView(b).setInt32(96, room, Endian.little);
  put(100, version);
  return b;
}

void main() {
  test('master address: http is not legacy, host:port is', () {
    expect(LegacyMaster.isLegacyAddress('https://ds.ms.srb2.org/MS/0'), isFalse);
    expect(LegacyMaster.isLegacyAddress('ms.srb2classic.net:28900'), isTrue);
    expect(LegacyMaster.parseAddress('ms.srb2classic.net:28900'), ('ms.srb2classic.net', 28900));
    expect(LegacyMaster.parseAddress('ms.example.net'), ('ms.example.net', 28900));
    expect(LegacyMaster.parseAddress('[::1]:5000'), ('::1', 5000));
  });

  test('messages are split until the empty one; a partial stream is not ready', () {
    final a = msMessage(217, [1, 2, 3]);
    final end = msMessage(217, const []);
    expect(LegacyMaster.splitMessages(Uint8List.fromList([...a, ...end]))!.single.$2, [1, 2, 3]);
    expect(LegacyMaster.splitMessages(a), isNull);
    expect(LegacyMaster.splitMessages(Uint8List.fromList(a.sublist(0, 17))), isNull);
    expect(LegacyMaster.splitMessages(end), isEmpty);
  });

  test('server and room records', () {
    final e = LegacyMaster.parseServer(extServer('203.0.113.7', '5029', 'Legacy \x82server', 33, '2.1.30'))!;
    expect((e.host, e.port, e.room, e.version), ('203.0.113.7', 5029, 33, '2.1.30'));
    expect(e.plainTitle, 'Legacy server');
    expect(LegacyMaster.parseServer(Uint8List(20)), isNull);

    final room = Uint8List(16 + 4 + 32 + 255);
    ByteData.sublistView(room).setInt32(16, 33, Endian.little);
    room.setRange(20, 26, 'Casual'.codeUnits);
    expect(LegacyMaster.parseRoom(room), (33, 'Casual'));
  });

  test('the list is fetched from a TCP master server (room -1 = all)', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final requests = <List<int>>[];
    server.listen((client) {
      client.listen((data) {
        requests.add(data);
        final bd = ByteData.sublistView(Uint8List.fromList(data));
        if (bd.getInt32(4, Endian.big) == LegacyMaster.getExtServers) {
          client.add(msMessage(217, extServer('203.0.113.7', '5029', 'One', 33, '2.1.30')));
          client.add(msMessage(217, extServer('203.0.113.8', '5030', 'Two', 28, '2.1.30')));
        }
        client.add(msMessage(0, const []));
      });
    });
    final list = await LegacyMaster.fetchServers('127.0.0.1:${server.port}');
    expect([for (final e in list) '${e.host}:${e.port}'], ['203.0.113.7:5029', '203.0.113.8:5030']);
    expect(ByteData.sublistView(Uint8List.fromList(requests.first)).getInt32(8, Endian.big), -1);
  });

  test('SRB2 Legacy server info: no packet-version prefix, numeric gametype', () {
    const proto = NetProtocol.legacy;
    final p = Uint8List(Srb2Protocol.headerSize + proto.offFileNeeded);
    const o = Srb2Protocol.headerSize;
    p[o] = 201;
    p[o + 1] = 30;
    p[o + 2] = 3; // игроков
    p[o + 3] = 8;
    p[o + 4] = 7; // GT_CTF
    p[o + 5] = 1; // modified
    p[o + 7] = 0x40; // dedicated
    p.setRange(o + 18, o + 18 + 6, 'Legacy'.codeUnits);
    p.setRange(o + 58, o + 58 + 5, 'Arena'.codeUnits);
    final info = Srb2Codec.parseServerInfo(p, proto)!;
    expect((info.application, info.version, info.subversion), ('SRB2', 201, 30));
    expect((info.players, info.maxPlayers, info.gametype, info.modified), (3, 8, 'CTF', true));
    expect((info.name, info.mapTitle, info.httpSource), ('Legacy', 'Arena', ''));

    p[o] = 202; // другая версия протокола — не наш ответ
    expect(Srb2Codec.parseServerInfo(p, proto), isNull);
    // Пакеты и файлы — как в 2.1: без PT_FILEACK, старая нумерация.
    expect((proto.ptTellFilesNeeded, proto.ptMoreFilesNeeded, proto.legacyFileTransfer), (29, 30, true));
    // PT_REQUESTFILE несёт и имя файла: сервер ищет файл по нему.
    expect(proto.requestFileWithName, isTrue);
  });

  test('master server names and "Name | address" lines', () {
    expect(ServersStore.parseMasterLine('My MS | ms.example.net:28900'), ('My MS', 'ms.example.net:28900'));
    expect(ServersStore.parseMasterLine(' https://ms.example.net/MS/0 '), ('', 'https://ms.example.net/MS/0'));
    final store = ServersStore(Games.srb2legacy);
    expect(store.masters, ['ms.srb2classic.net:28900', 'ms.weissblatt.cc:28900']);
    expect(store.masterName('ms.srb2classic.net:28900'), 'SRB2 Classic');
    expect(store.masterName('other.example.net:28900'), 'other.example.net');
    expect(store.masterName('https://ms.example.net/MS/0'), 'ms.example.net');
    expect(store.masterLines.first, 'SRB2 Classic | ms.srb2classic.net:28900');
  });

  test('Launch room list: rooms of the chosen master server', () async {
    Uint8List room(int id, String name) {
      final b = Uint8List(16 + 4 + 32 + 255);
      ByteData.sublistView(b).setInt32(16, id, Endian.little);
      b.setRange(20, 20 + name.length, name.codeUnits);
      return b;
    }

    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((client) {
      client.listen((data) {
        if (ByteData.sublistView(Uint8List.fromList(data)).getInt32(4, Endian.big) == LegacyMaster.getRooms) {
          client.add(msMessage(210, room(28, 'Casual')));
          client.add(msMessage(210, room(33, 'Standard')));
        }
        client.add(msMessage(0, const []));
      });
    });
    final store = ServersStore(Games.srb2legacy);
    expect(await store.fetchRooms('127.0.0.1:${server.port}'), {28: 'Casual', 33: 'Standard'});
    expect(Games.srb2legacy.hasHttpSource, isFalse);
    expect(Games.srb2.hasHttpSource, isTrue);
  });
}
