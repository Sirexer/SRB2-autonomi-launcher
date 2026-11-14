import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:srb2_autonomi_launcher/models/game.dart';
import 'package:srb2_autonomi_launcher/models/launch_config.dart';
import 'package:srb2_autonomi_launcher/models/srb2_server.dart';
import 'package:srb2_autonomi_launcher/services/srb2_file_transfer.dart';

const helloMd5 = '5d41402abc4b2a76b9719d911017c592';
const kart = NetProtocol.srb2Kart;

List<int> _md5Bytes(String hex) =>
    [for (var i = 0; i < 32; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];

List<int> kartFileEntry(String name, int size, String md5, {int willSend = 1}) => [
      1 + (willSend << 4),
      size & 0xFF, (size >> 8) & 0xFF, (size >> 16) & 0xFF, (size >> 24) & 0xFF,
      ...latin1.encode(name), 0,
      ..._md5Bytes(md5),
    ];

void _put(Uint8List b, int offset, List<int> bytes) => b.setRange(offset, offset + bytes.length, bytes);

/// serverinfo_pak SRB2Kart 1.6 (смещения — offsetof упакованной структуры).
Uint8List fakeKartServerInfo({int gametype = 2, required List<List<int>> files}) {
  final fileBytes = [for (final f in files) ...f];
  final b = Uint8List(382 + fileBytes.length);
  b[0] = 255;
  b[1] = 0;
  _put(b, 2, ascii.encode('SRB2Kart'));
  b[18] = 1;
  b[19] = 6;
  b[20] = 3; // игроков
  b[21] = 16;
  b[22] = gametype;
  b[23] = 1; // modified
  b[24] = 0; // cheats
  b[25] = 0x42; // kartspeed 2 + dedicated
  b[26] = files.length;
  ByteData.sublistView(b).setUint32(31, 35 * 30, Endian.little);
  _put(b, 35, ascii.encode('Kart Server'));
  _put(b, 67, ascii.encode('MAP01'));
  _put(b, 75, ascii.encode('Green Hills'));
  b[125] = 1; // iszone
  _put(b, 126, ascii.encode('http://kart.example/'));
  b.setRange(382, b.length, fileBytes);
  return Srb2Codec.buildPacket(kart.ptServerInfo, b);
}

int _cmpAck(int a, int b) {
  final d = a - b;
  return d >= 127 || d < -128 ? -d : d;
}

/// Сервер SRB2Kart: фрагменты "надёжными" пакетами (ack в заголовке), не
/// больше 96 неподтверждённых, переотправка без подтверждения (d_net.c).
class FakeKartServer {
  final RawDatagramSocket socket;
  final Map<int, Uint8List> files;
  final int fragmentSize;
  final List<String> requestedNames = [];
  int quits = 0;
  int resent = 0;

  int _nextAck = 1;
  int _remoteFirstAck = 0;
  final Map<int, Uint8List> _unacked = {};
  final List<int> _queue = [];
  InternetAddress? _client;
  int? _clientPort;
  Timer? _timer;
  final Set<int> _dropOnce = {};

  FakeKartServer._(this.socket, this.files, this.fragmentSize) {
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? d;
      while ((d = socket.receive()) != null) {
        _onPacket(d!);
      }
    });
    _timer = Timer.periodic(const Duration(milliseconds: 30), (_) => _tick());
  }

  static Future<FakeKartServer> start(Map<int, Uint8List> files, {int fragmentSize = 100}) async =>
      FakeKartServer._(await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0), files, fragmentSize);

  int get port => socket.port;

  void _onPacket(Datagram d) {
    final pkt = Uint8List.fromList(d.data);
    final type = Srb2Codec.packetType(pkt);
    if (type == null) return;
    // Processackpak: ackreturn — всё до него получено.
    final ret = pkt[5];
    if (ret != 0 && _cmpAck(_remoteFirstAck, ret) < 0) {
      _remoteFirstAck = ret;
      _unacked.removeWhere((ack, _) => _cmpAck(ack, ret) <= 0);
    }
    if (type == NetProtocol.ptNothing) {
      for (var i = 8; i < pkt.length; i++) {
        if (pkt[i] != 0) _unacked.remove(pkt[i]);
      }
    } else if (type == kart.ptRequestFile) {
      _client = d.address;
      _clientPort = d.port;
      var i = 8;
      while (i < pkt.length && pkt[i] != 0xFF) {
        final id = pkt[i++];
        final end = pkt.indexOf(0, i);
        requestedNames.add(String.fromCharCodes(pkt, i, end));
        i = end + 1;
        _queue.add(id);
      }
    } else if (type == kart.ptClientQuit) {
      quits++;
    }
  }

  int _filePos = 0;
  int _sentPackets = 0;

  void _tick() {
    final client = _client;
    if (client == null || quits > 0) return;
    // Переотправка неподтверждённых (NODETIMEOUT).
    for (final pkt in _unacked.values) {
      socket.send(pkt, client, _clientPort!);
      resent++;
    }
    // Новые фрагменты, пока окно (96) не заполнено.
    var budget = 8;
    while (budget-- > 0 && _queue.isNotEmpty && _cmpAck((_remoteFirstAck + 96) % 256, _nextAck) >= 0) {
      final id = _queue.first;
      final data = files[id]!;
      final size = min(fragmentSize, data.length - _filePos);
      final last = _filePos + size == data.length;
      final head = Uint8List(7);
      ByteData.sublistView(head)
        ..setUint8(0, id)
        ..setUint32(1, _filePos | (last ? 0x80000000 : 0), Endian.little)
        ..setUint16(5, size, Endian.little);
      final pkt = Srb2Codec.buildPacket(kart.ptFileFragment, [...head, ...data.sublist(_filePos, _filePos + size)]);
      final ack = _nextAck;
      _nextAck = (_nextAck + 1) & 0xFF;
      if (_nextAck == 0) _nextAck = 1;
      // Заголовок с ack: контрольная сумма считается с ним.
      pkt[4] = ack;
      ByteData.sublistView(pkt).setUint32(0, Srb2Codec.checksum(pkt), Endian.little);
      _unacked[ack] = pkt;
      if (++_sentPackets % 5 != 2 || !_dropOnce.add(ack)) {
        socket.send(pkt, client, _clientPort!); // каждый 5-й в первый раз "теряется"
      }
      _filePos += size;
      if (last) {
        _queue.removeAt(0);
        _filePos = 0;
      }
    }
  }

  bool get allAcked => _unacked.isEmpty;

  void close() {
    _timer?.cancel();
    socket.close();
  }
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
  test('serverinfo: numeric gametype, no refuse reason, map name', () {
    final info = Srb2Codec.parseServerInfo(
      fakeKartServerInfo(files: [kartFileEntry('kl_track.pk3', 2048, helloMd5)]),
      kart,
    )!;
    expect(info.application, 'SRB2Kart');
    expect(info.versionString, '1.6');
    expect(info.isCompatible, isTrue);
    expect(info.name, 'Kart Server');
    expect(info.players, 3);
    expect(info.maxPlayers, 16);
    expect(info.gametype, 'Race');
    expect(info.refuseReason, -1);
    expect(info.modified, isTrue);
    expect(info.isDedicated, isTrue);
    expect(info.kartSpeed, 2);
    expect(info.mapName, 'MAP01');
    expect(info.fullMapTitle, 'Green Hills ZONE');
    expect(info.httpSource, 'http://kart.example/');
    expect(info.files.single.name, 'kl_track.pk3');
    expect(info.files.single.willSend, ServerFileSend.yes);
    expect(Srb2Codec.parseServerInfo(fakeKartServerInfo(gametype: 3, files: []), kart)!.gametype, 'Battle');
  });

  test('game definition', () {
    expect(Games.byId('Kart'), Games.srb2kart);
    expect(Games.srb2kart.serversUrl('https://ms.kartkrew.org/ms/api'),
        'https://ms.kartkrew.org/ms/api/games/SRB2Kart/10/servers?v=2.2');
    final o = LaunchOptions()
      ..net = NetMode.host
      ..room = '33';
    expect(o.toArgs(game: Games.srb2kart), ['-server']);
  });

  test('legacy download: reliable fragments are acknowledged, losses resent', () async {
    final dir = await Directory.systemTemp.createTemp('kart_transfer_');
    addTearDown(() => dir.delete(recursive: true));
    final a = randomBytes(25000, 1); // 250 фрагментов — номера ack идут по кругу
    final b = randomBytes(333, 2);
    final server = await FakeKartServer.start({0: a, 1: b});
    addTearDown(server.close);

    final transfer = Srb2FileTransfer('127.0.0.1', server.port, protocol: kart);
    await transfer.download(fileId: 0, file: describe('big.pk3', a), targetPath: p.join(dir.path, 'big.pk3'));
    await transfer.download(fileId: 1, file: describe('small.lua', b), targetPath: p.join(dir.path, 'small.lua'));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(server.allAcked, isTrue, reason: 'every reliable packet must be acknowledged');
    await transfer.close();

    expect(await File(p.join(dir.path, 'big.pk3')).readAsBytes(), a);
    expect(await File(p.join(dir.path, 'small.lua')).readAsBytes(), b);
    expect(server.requestedNames, ['big.pk3', 'small.lua']);
    expect(server.resent, greaterThan(0));
    expect(server.quits, greaterThan(0));
  });
}
