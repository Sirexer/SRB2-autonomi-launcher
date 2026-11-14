import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:srb2_autonomi_launcher/models/srb2_server.dart';
import 'package:srb2_autonomi_launcher/services/srb2_file_transfer.dart';

/// Сервер, раздающий файлы как FileSendTicker в SRB2 2.2.15: фрагменты
/// проходами (iteration), неподтверждённые досылаются на следующем проходе.
class FakeFileServer {
  final RawDatagramSocket socket;
  final Map<int, Uint8List> files;
  final int fragmentSize;
  final Set<int> refuse;
  final NetProtocol proto;

  final List<int> requested = [];

  /// Имена из PT_REQUESTFILE (только Ring Racers).
  final List<String> requestedNames = [];
  final Set<int> received = {};
  final Map<int, Set<int>> acked = {};
  int quits = 0;

  final List<int> _queue = [];
  bool _sending = false;
  InternetAddress? _client;
  int? _clientPort;

  FakeFileServer._(this.socket, this.files, this.fragmentSize, this.refuse, this.proto) {
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? d;
      while ((d = socket.receive()) != null) {
        _onPacket(d!);
      }
    });
  }

  static Future<FakeFileServer> start(Map<int, Uint8List> files,
      {int fragmentSize = 100, Set<int> refuse = const {}, NetProtocol proto = NetProtocol.srb2}) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    return FakeFileServer._(socket, files, fragmentSize, refuse, proto);
  }

  int get port => socket.port;

  int fragments(int id) => max(1, (files[id]!.length + fragmentSize - 1) ~/ fragmentSize);

  void _onPacket(Datagram d) {
    final pkt = Uint8List.fromList(d.data);
    final bd = ByteData.sublistView(pkt);
    final type = Srb2Codec.packetType(pkt);
    if (type == proto.ptRequestFile) {
      _client = d.address;
      _clientPort = d.port;
      var i = 8;
      while (i < pkt.length && pkt[i] != 0xFF) {
        final id = pkt[i++];
        if (proto.requestFileWithName) {
          // Ring Racers: после номера — имя файла (READSTRINGN).
          final end = pkt.indexOf(0, i);
          requestedNames.add(String.fromCharCodes(pkt, i, end));
          i = end + 1;
        }
        requested.add(id);
        if (!refuse.contains(id)) _queue.add(id);
      }
      _pump();
      return;
    }
    switch (type == proto.ptFileAck
        ? Srb2FileTransfer.ptFileAck
        : type == proto.ptFileReceived
            ? Srb2FileTransfer.ptFileReceived
            : type == proto.ptClientQuit
                ? Srb2FileTransfer.ptClientQuit
                : -1) {
      case Srb2FileTransfer.ptFileAck:
        final id = pkt[8];
        final segments = pkt[10];
        expect(pkt.length, 8 + 3 + segments * 8, reason: 'ack size must match numsegments');
        for (var k = 0; k < segments; k++) {
          final start = bd.getUint32(11 + k * 8, Endian.little);
          final bits = bd.getUint32(15 + k * 8, Endian.little);
          expect(start % 32, 0);
          expect(start < fragments(id), isTrue, reason: 'server closes the connection otherwise');
          for (var j = 0; j < 32; j++) {
            if (bits & (1 << j) != 0) (acked[id] ??= {}).add(start + j);
          }
        }
      case Srb2FileTransfer.ptFileReceived:
        received.add(pkt[8]);
      case Srb2FileTransfer.ptClientQuit:
        quits++;
      default:
        break;
    }
  }

  Future<void> _pump() async {
    if (_sending) return;
    _sending = true;
    while (_queue.isNotEmpty) {
      final id = _queue.first;
      final data = files[id]!;
      final n = fragments(id);
      acked[id] ??= {};
      var iteration = 1;
      while (!received.contains(id) && acked[id]!.length < n && iteration < 80 && quits == 0) {
        for (var i = 0; i < n; i++) {
          if (acked[id]!.contains(i)) continue;
          if (iteration == 1 && i % 4 == 1) continue; // "потерянные" пакеты
          final pos = i * fragmentSize;
          final len = min(fragmentSize, data.length - pos);
          final head = Uint8List(12);
          ByteData.sublistView(head)
            ..setUint8(0, id)
            ..setUint32(1, data.length, Endian.little)
            ..setUint8(5, iteration)
            ..setUint32(6, pos, Endian.little)
            ..setUint16(10, fragmentSize, Endian.little); // как в игре: всегда FILEFRAGMENTSIZE
          socket.send(
            Srb2Codec.buildPacket(proto.ptFileFragment, [...head, ...data.sublist(pos, pos + len)]),
            _client!,
            _clientPort!,
          );
        }
        iteration++;
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
      _queue.removeAt(0);
    }
    _sending = false;
  }

  void close() => socket.close();
}

Uint8List randomBytes(int n, int seed) {
  final r = Random(seed);
  return Uint8List.fromList([for (var i = 0; i < n; i++) r.nextInt(256)]);
}

ServerFile describe(String name, Uint8List data) => ServerFile(
      name: name,
      size: data.length,
      md5: crypto.md5.convert(data).toString(),
      willSend: ServerFileSend.yes,
      isFolder: false,
    );

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('srb2_transfer_'));
  tearDown(() => dir.delete(recursive: true));

  test('downloads several files with packet loss and cleans up', () async {
    final a = randomBytes(2500, 1); // 25 фрагментов
    final b = randomBytes(7777, 2); // 78 фрагментов (больше двух сегментов по 32)
    final empty = Uint8List(0);
    final server = await FakeFileServer.start({0: a, 3: b, 4: empty});
    addTearDown(server.close);

    final transfer = Srb2FileTransfer('127.0.0.1', server.port);
    var lastProgress = 0;
    await transfer.download(
      fileId: 0,
      file: describe('a.pk3', a),
      targetPath: p.join(dir.path, 'a.pk3'),
      onProgress: (got, total) => lastProgress = got,
    );
    await transfer.download(fileId: 3, file: describe('b.wad', b), targetPath: p.join(dir.path, 'sub', 'b.wad'));
    await transfer.download(fileId: 4, file: describe('empty.lua', empty), targetPath: p.join(dir.path, 'empty.lua'));
    await transfer.close();

    expect(await File(p.join(dir.path, 'a.pk3')).readAsBytes(), a);
    expect(await File(p.join(dir.path, 'sub', 'b.wad')).readAsBytes(), b);
    expect(await File(p.join(dir.path, 'empty.lua')).length(), 0);
    expect(lastProgress, a.length);

    expect(server.requested, [0, 3, 4]);
    expect(server.received, containsAll([0, 3, 4]));
    // Никогда не подтверждаем все фрагменты: сервер SRB2 тогда может
    // зависнуть в FileSendTicker. Конец файла — только PT_FILERECEIVED.
    expect(server.acked[0]!.length, lessThan(server.fragments(0)));
    expect(server.acked[3]!.length, lessThan(server.fragments(3)));
    expect(server.acked[4] ?? const <int>{}, isEmpty);
    expect(server.quits, greaterThan(0), reason: 'the server must be told to stop sending');
    expect(dir.listSync(recursive: true).where((e) => e.path.endsWith('.part')), isEmpty);
  });

  test('Ring Racers: request carries file names, other packet numbers', () async {
    final a = randomBytes(1500, 7);
    final b = randomBytes(300, 8);
    final server = await FakeFileServer.start({1: a, 2: b}, proto: NetProtocol.ringRacers);
    addTearDown(server.close);

    final transfer = Srb2FileTransfer('127.0.0.1', server.port, protocol: NetProtocol.ringRacers);
    await transfer.download(fileId: 1, file: describe('KR_Track.pk3', a), targetPath: p.join(dir.path, 'a.pk3'));
    await transfer.download(fileId: 2, file: describe('chars.pk3', b), targetPath: p.join(dir.path, 'b.pk3'));
    await transfer.close();

    expect(await File(p.join(dir.path, 'a.pk3')).readAsBytes(), a);
    expect(await File(p.join(dir.path, 'b.pk3')).readAsBytes(), b);
    expect(server.requested, [1, 2]);
    expect(server.requestedNames, ['KR_Track.pk3', 'chars.pk3']);
    expect(server.received, containsAll([1, 2]));
    expect(server.quits, greaterThan(0));
  });

  test('a file the server refuses fails without leaving files behind', () async {
    final a = randomBytes(500, 3);
    final server = await FakeFileServer.start({0: a}, refuse: {0});
    addTearDown(server.close);

    final transfer = Srb2FileTransfer('127.0.0.1', server.port);
    final target = p.join(dir.path, 'a.pk3');
    await expectLater(
      transfer.download(
        fileId: 0,
        file: describe('a.pk3', a),
        targetPath: target,
        startTimeout: const Duration(seconds: 1),
      ),
      throwsA(isA<TransferException>()),
    );
    await transfer.close();
    expect(await File(target).exists(), isFalse);
    expect(await File('$target.part').exists(), isFalse);
  });

  test('wrong MD5 is rejected', () async {
    final a = randomBytes(1000, 4);
    final server = await FakeFileServer.start({0: a});
    addTearDown(server.close);

    final transfer = Srb2FileTransfer('127.0.0.1', server.port);
    final target = p.join(dir.path, 'a.pk3');
    final wrong = ServerFile(
      name: 'a.pk3',
      size: a.length,
      md5: '0' * 32,
      willSend: ServerFileSend.yes,
      isFolder: false,
    );
    await expectLater(
      transfer.download(fileId: 0, file: wrong, targetPath: target),
      throwsA(isA<TransferException>().having((e) => e.message, 'message', 'MD5 mismatch')),
    );
    await transfer.close();
    expect(await File(target).exists(), isFalse);
  });

  test('cancel stops the download', () async {
    final big = randomBytes(200000, 5);
    final server = await FakeFileServer.start({0: big}, fragmentSize: 50);
    addTearDown(server.close);

    final transfer = Srb2FileTransfer('127.0.0.1', server.port);
    var cancel = false;
    Timer(const Duration(milliseconds: 150), () => cancel = true);
    await expectLater(
      transfer.download(
        fileId: 0,
        file: describe('big.pk3', big),
        targetPath: p.join(dir.path, 'big.pk3'),
        isCancelled: () => cancel,
      ),
      throwsA(isA<TransferCancelled>()),
    );
    await transfer.close();
    expect(server.quits, greaterThan(0));
    expect(await File(p.join(dir.path, 'big.pk3.part')).exists(), isFalse);
  });

  test('file ids are one byte, 0xFF is the terminator', () {
    expect(Srb2FileTransfer.canRequest(0), isTrue);
    expect(Srb2FileTransfer.canRequest(254), isTrue);
    expect(Srb2FileTransfer.canRequest(255), isFalse);
    expect(Srb2FileTransfer.canRequest(-1), isFalse);
  });
}
