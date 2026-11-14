import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:srb2_autonomi_launcher/models/srb2_server.dart';
import 'package:srb2_autonomi_launcher/services/server_files.dart';
import 'package:srb2_autonomi_launcher/services/srb2_query.dart';

// --- Сборка пакетов как на сервере SRB2 2.2.15 (раскладка serverinfo_pak) ---

const helloMd5 = '5d41402abc4b2a76b9719d911017c592'; // md5("hello")

List<int> _md5Bytes(String hex) =>
    [for (var i = 0; i < 32; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];

List<int> fileEntry(String name, int size, String md5, {int willSend = 0, bool folder = false}) => [
      1 + (willSend << 4),
      folder ? 1 : 0,
      size & 0xFF, (size >> 8) & 0xFF, (size >> 16) & 0xFF, (size >> 24) & 0xFF,
      ...latin1.encode(name), 0,
      ..._md5Bytes(md5),
    ];

void _putString(Uint8List b, int offset, List<int> bytes) => b.setRange(offset, offset + bytes.length, bytes);

Uint8List fakeServerInfo({int flags = 0, required List<List<int>> files}) {
  final fileBytes = [for (final f in files) ...f];
  final b = Uint8List(406 + fileBytes.length);
  b[0] = 255;
  b[1] = 5; // PACKETVERSION
  _putString(b, 2, ascii.encode('SRB2'));
  b[18] = 202;
  b[19] = 15;
  b[20] = 3;
  b[21] = 16;
  b[22] = 0;
  _putString(b, 23, ascii.encode('Co-op'));
  b[47] = 1; // modified
  b[49] = flags;
  b[50] = files.length;
  ByteData.sublistView(b).setUint32(55, 35 * 65, Endian.little); // 1:05 на карте
  _putString(b, 59, [0x82, ...ascii.encode('My '), 0x80, ...ascii.encode('Server')]); // цветовые коды
  _putString(b, 91, ascii.encode('MAP01'));
  _putString(b, 99, ascii.encode('GREENFLOWER'));
  b[148] = 1; // act
  b[149] = 1; // zone
  _putString(b, 150, ascii.encode('http://mirror.example/files/'));
  b.setRange(406, b.length, fileBytes);
  return Srb2Codec.buildPacket(Srb2Protocol.ptServerInfo, b);
}

Uint8List fakePlayerInfo() {
  final b = Uint8List(32 * 36);
  for (var i = 0; i < 32; i++) {
    b[i * 36] = 255; // пустые слоты
  }
  final s = 3 * 36;
  b[s] = 3;
  _putString(b, s + 1, ascii.encode('Sonic Fan'));
  b[s + 27] = 0; // играет
  b[s + 28] = 1; // Tails
  ByteData.sublistView(b)
    ..setUint32(s + 30, 12345, Endian.little)
    ..setUint16(s + 34, 125, Endian.little);
  return Srb2Codec.buildPacket(Srb2Protocol.ptPlayerInfo, b);
}

Uint8List fakeMoreFiles(int first, List<List<int>> files, {bool more = false}) {
  final head = Uint8List(6);
  ByteData.sublistView(head).setInt32(0, first, Endian.little);
  head[4] = files.length;
  head[5] = more ? 1 : 0;
  return Srb2Codec.buildPacket(Srb2Protocol.ptMoreFilesNeeded, [...head, for (final f in files) ...f]);
}

void main() {
  group('codec', () {
    test('askInfo packet layout and checksum', () {
      final pkt = Srb2Codec.askInfo(0x01020304);
      expect(pkt.length, 13);
      expect(pkt[6], Srb2Protocol.ptAskInfo);
      expect(pkt[8], 202);
      expect(pkt.sublist(9), [4, 3, 2, 1]);
      expect(Srb2Codec.packetType(pkt), Srb2Protocol.ptAskInfo);
      final broken = Uint8List.fromList(pkt)..[9] ^= 0xFF;
      expect(Srb2Codec.packetType(broken), isNull);
      expect(Srb2Codec.packetType(Uint8List(4)), isNull);
    });

    test('checksum matches NetbufferChecksum by hand', () {
      final pkt = Srb2Codec.buildPacket(12, [202, 0, 0, 0, 0]);
      // c = 0x1234567 + сумма byte[i] * (i - 3) для i >= 4
      final expected = 0x1234567 + 12 * (6 - 3) + 202 * (8 - 3);
      expect(ByteData.sublistView(pkt).getUint32(0, Endian.little), expected);
    });

    test('serverinfo: fields, colour codes stripped, files', () {
      final pkt = fakeServerInfo(files: [
        fileEntry('CL_Tails.pk3', 1024, helloMd5),
        fileEntry('secret.wad', 2048, helloMd5, willSend: 1),
        fileEntry('mods', 0, helloMd5, folder: true),
      ]);
      final info = Srb2Codec.parseServerInfo(pkt)!;
      expect(info.name, 'My Server');
      expect(info.versionString, '2.2.15');
      expect(info.isCompatible, isTrue);
      expect(info.players, 3);
      expect(info.maxPlayers, 16);
      expect(info.gametype, 'Co-op');
      expect(info.modified, isTrue);
      expect(info.fullMapTitle, 'GREENFLOWER ZONE 1');
      expect(info.levelTimeTics ~/ 35, 65);
      expect(info.httpSource, 'http://mirror.example/files/');
      expect(info.refuseText, 'Joinable');
      expect(info.files.map((f) => f.name), ['CL_Tails.pk3', 'secret.wad', 'mods']);
      expect(info.files[0].size, 1024);
      expect(info.files[0].md5, helloMd5);
      expect(info.files[0].willSend, ServerFileSend.yes);
      expect(info.files[1].willSend, ServerFileSend.no);
      expect(info.files[2].isFolder, isTrue);
    });

    test('serverinfo of another packet version is rejected', () {
      final pkt = fakeServerInfo(files: []);
      pkt[9] = 4; // packetversion
      expect(Srb2Codec.parseServerInfo(pkt), isNull);
    });

    test('playerinfo skips empty slots', () {
      final players = Srb2Codec.parsePlayerInfo(fakePlayerInfo());
      expect(players, hasLength(1));
      expect(players.single.name, 'Sonic Fan');
      expect(players.single.skinName, 'Tails');
      expect(players.single.score, 12345);
      expect(players.single.secondsInServer, 125);
      expect(players.single.isSpectator, isFalse);
    });

    test('morefiles', () {
      final more = Srb2Codec.parseMoreFiles(fakeMoreFiles(2, [fileEntry('x.pk3', 5, helloMd5)], more: true))!;
      expect(more.first, 2);
      expect(more.more, isTrue);
      expect(more.files.single.name, 'x.pk3');
    });
  });

  group('master server', () {
    test('server list: rooms, url-encoded titles, versions', () {
      const body = '0\n'
          '1.2.3.4 5029 My%20Server 2.2.15\n'
          '5.6.7.8 5030 Old 2.2.13\n'
          '\n'
          '33\n'
          '2001:db8::1 5029 Casual 2.2.15\n'
          'garbage line\n';
      final list = MasterServerParser.parseServers(body);
      expect(list.map((e) => '${e.host}:${e.port}'), ['1.2.3.4:5029', '5.6.7.8:5030', '2001:db8::1:5029']);
      expect(list.first.title, 'My Server');
      expect(list[1].version, '2.2.13');
      expect(list.last.room, 33);
    });

    test('rooms', () {
      const body = '0\nAll\nEvery server\n\n\n33\nStandard\nVanilla games\n\n\n';
      expect(MasterServerParser.parseRooms(body), {0: 'All', 33: 'Standard'});
    });

    test('empty or broken body', () {
      expect(MasterServerParser.parseServers(''), isEmpty);
      expect(MasterServerParser.parseServers('<html>error</html>'), isEmpty);
    });
  });

  test('parseServerAddress', () {
    expect(parseServerAddress('1.2.3.4'), ('1.2.3.4', 5029));
    expect(parseServerAddress(' play.example.com:5030 '), ('play.example.com', 5030));
    expect(parseServerAddress('[2001:db8::1]:5040'), ('2001:db8::1', 5040));
    expect(parseServerAddress('2001:db8::1'), ('2001:db8::1', 5029));
    expect(parseServerAddress('srb2://host:5031/'), ('host', 5031));
    expect(parseServerAddress('host:99999'), isNull);
    expect(parseServerAddress(''), isNull);
  });

  test('UDP query against a fake SRB2 server (with more files)', () async {
    final server = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    var tellFirst = -1;
    server.listen((event) {
      if (event != RawSocketEvent.read) return;
      final d = server.receive();
      if (d == null) return;
      final pkt = Uint8List.fromList(d.data);
      switch (Srb2Codec.packetType(pkt)) {
        case Srb2Protocol.ptAskInfo:
          server.send(
            fakeServerInfo(flags: Srb2Protocol.svLotsOfAddons, files: [fileEntry('a.pk3', 1, helloMd5)]),
            d.address,
            d.port,
          );
          server.send(fakePlayerInfo(), d.address, d.port);
        case Srb2Protocol.ptTellFilesNeeded:
          tellFirst = ByteData.sublistView(pkt).getInt32(8, Endian.little);
          server.send(
            fakeMoreFiles(tellFirst, [fileEntry('b.pk3', 2, helloMd5), fileEntry('c.pk3', 3, helloMd5)]),
            d.address,
            d.port,
          );
        default:
          break;
      }
    });

    final client = Srb2QueryClient();
    addTearDown(client.close);
    final result = await client.query('127.0.0.1', server.port);
    expect(result.error, isNull);
    expect(result.info!.name, 'My Server');
    expect(result.info!.files.map((f) => f.name), ['a.pk3', 'b.pk3', 'c.pk3']);
    expect(tellFirst, 1);
    expect(result.players.single.name, 'Sonic Fan');
    expect(result.pingMs, isNotNull);
  });

  test('UDP query of a silent port times out', () async {
    final silent = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(silent.close);
    final client = Srb2QueryClient();
    addTearDown(client.close);
    final result = await client.query('127.0.0.1', silent.port, timeout: const Duration(milliseconds: 600));
    expect(result.isOnline, isFalse);
    expect(result.error, 'No response');
  });

  group('server files', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('srb2_files_'));
    tearDown(() => dir.delete(recursive: true));

    const file = ServerFile(name: 'test.pk3', size: 5, md5: helloMd5, willSend: ServerFileSend.yes, isFolder: false);

    test('local index finds a file by name and MD5 in subfolders', () async {
      final nested = File(p.join(dir.path, 'DOWNLOAD', 'Some Addon', '1.0', 'TEST.pk3'));
      await nested.create(recursive: true);
      await nested.writeAsString('hello');
      final index = await LocalFileIndex.build(dir.path);
      expect(await index.find(file), nested.path);

      await nested.writeAsString('other!'); // другой размер — кэш MD5 обновится
      final index2 = await LocalFileIndex.build(dir.path);
      expect(await index2.find(file), isNull);
      expect(index2.hasOtherVersion(file), isTrue);
    });

    test('target path does not overwrite another version', () async {
      final downloads = p.join(dir.path, 'DOWNLOAD');
      expect(await ServerFileDownloader.targetPath(downloads, file), p.join(downloads, 'test.pk3'));
      await File(p.join(downloads, 'test.pk3')).create(recursive: true);
      await File(p.join(downloads, 'test.pk3')).writeAsString('older');
      expect(
        await ServerFileDownloader.targetPath(downloads, file),
        p.join(downloads, 'test', helloMd5.substring(0, 8), 'test.pk3'),
      );
    });

    test('mirror URL like SRB2 builds it', () {
      expect(
        ServerFileDownloader.mirrorUrl('https://m.example/srb2/', file).toString(),
        'https://m.example/srb2/test.pk3?md5=$helloMd5',
      );
      expect(ServerFileDownloader.isUsableMirror(''), isFalse);
      expect(ServerFileDownloader.isUsableMirror('ftp://x'), isFalse);
      expect(ServerFileDownloader.isUsableMirror('http://x.org/a'), isTrue);
    });

    test('mirror download verifies MD5', () async {
      final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => http.close(force: true));
      var body = 'hello';
      http.listen((req) {
        expect(req.uri.path, '/files/test.pk3');
        expect(req.uri.queryParameters['md5'], helloMd5);
        req.response
          ..write(body)
          ..close();
      });
      final source = 'http://127.0.0.1:${http.port}/files';
      final target = p.join(dir.path, 'DOWNLOAD', 'test.pk3');

      await ServerFileDownloader.downloadFromMirror(httpSource: source, file: file, targetPath: target);
      expect(await File(target).readAsString(), 'hello');

      body = 'HELLO'; // тот же размер, другой MD5
      final target2 = p.join(dir.path, 'DOWNLOAD', 'other.pk3');
      await expectLater(
        ServerFileDownloader.downloadFromMirror(
          httpSource: source,
          file: const ServerFile(name: 'test.pk3', size: 5, md5: helloMd5, willSend: ServerFileSend.yes, isFolder: false),
          targetPath: target2,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(await File(target2).exists(), isFalse);
      expect(await File('$target2.part').exists(), isFalse);
    });
  });
}
