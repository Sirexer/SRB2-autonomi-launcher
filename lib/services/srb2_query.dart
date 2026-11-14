import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../models/srb2_server.dart';

/// Результат опроса сервера.
class ServerQueryResult {
  final ServerInfo? info;
  final List<ServerPlayer> players;
  final int? pingMs;
  final String? error;
  final DateTime time;

  ServerQueryResult({this.info, this.players = const [], this.pingMs, this.error})
      : time = DateTime.now();

  bool get isOnline => info != null;

  /// Сервер ответил, но это другая версия игры (его ответ не разобрать).
  bool get isUnsupported => error?.startsWith('Unsupported server') ?? false;

  /// Боты. Отдельного флага в протоколе нет: в serverinfo число игроков —
  /// только люди (D_NumPlayers без ботов в Ring Racers), а в списке игроков
  /// есть все, вместе с ботами. Разница — боты.
  int get botCount {
    final humans = info?.players;
    if (humans == null) return 0;
    final extra = players.length - humans;
    return extra > 0 ? extra : 0;
  }

  /// Все игроки — боты (людей нет), значит каждого можно пометить как бота.
  bool get allBots => botCount > 0 && botCount == players.length;
}

class _Pending {
  final Stopwatch stopwatch = Stopwatch();
  final Completer<ServerInfo> info = Completer();
  final Completer<List<ServerPlayer>> players = Completer();
  Completer<MoreFiles>? moreFiles;
  int? pingMs;
}

/// Опрос серверов SRB2 напрямую по UDP — так же, как это делает игра
/// (PT_ASKINFO → PT_SERVERINFO + PT_PLAYERINFO). Мастер-сервер не нужен.
class Srb2QueryClient {
  /// Протокол игры (SRB2 или Ring Racers).
  final NetProtocol protocol;

  Srb2QueryClient({this.protocol = NetProtocol.srb2});

  RawDatagramSocket? _v4;
  RawDatagramSocket? _v6;
  final Map<String, _Pending> _pending = {};

  Future<RawDatagramSocket> _socketFor(InternetAddress address) async {
    if (address.type == InternetAddressType.IPv6) {
      return _v6 ??= await _bind(InternetAddress.anyIPv6);
    }
    return _v4 ??= await _bind(InternetAddress.anyIPv4);
  }

  Future<RawDatagramSocket> _bind(InternetAddress any) async {
    final socket = await RawDatagramSocket.bind(any, 0);
    socket.listen(
      (event) {
        if (event != RawSocketEvent.read) return;
        Datagram? d;
        while ((d = socket.receive()) != null) {
          _onPacket(d!);
        }
      },
      // Windows сообщает «сеть недоступна» (errno 1231: IPv6 без IPv6-сети,
      // ICMP unreachable) ошибкой сокета: это не повод для необработанной
      // ошибки — такой сервер просто не ответит.
      onError: (Object _) {},
    );
    return socket;
  }

  static String _key(InternetAddress a, int port) => '${a.address}:$port';

  void _onPacket(Datagram d) {
    final q = _pending[_key(d.address, d.port)];
    if (q == null) return;
    final data = Uint8List.fromList(d.data);
    final type = Srb2Codec.packetType(data);
    if (type == null) return;
    if (type == protocol.ptServerInfo) {
      if (q.info.isCompleted) return;
      q.pingMs ??= q.stopwatch.elapsedMilliseconds;
      final info = Srb2Codec.parseServerInfo(data, protocol);
      if (info != null) {
        q.info.complete(info);
      } else {
        q.info.completeError(const FormatException('Unsupported server (different game version)'));
      }
    } else if (type == protocol.ptPlayerInfo) {
      if (!q.players.isCompleted) q.players.complete(Srb2Codec.parsePlayerInfo(data, protocol));
    } else if (type == protocol.ptMoreFilesNeeded) {
      final more = Srb2Codec.parseMoreFiles(data, protocol);
      final c = q.moreFiles;
      if (more != null && c != null && !c.isCompleted) c.complete(more);
    }
  }

  static Future<InternetAddress> resolve(String host) async {
    final ip = InternetAddress.tryParse(host);
    if (ip != null) return ip;
    final found = await InternetAddress.lookup(host);
    if (found.isEmpty) throw SocketException('Host not found: $host');
    // IPv4 предпочтительнее: игра тоже работает в основном по IPv4.
    return found.firstWhere((a) => a.type == InternetAddressType.IPv4, orElse: () => found.first);
  }

  /// Опрашивает сервер. [timeout] — ожидание первого ответа (запрос
  /// повторяется раз в секунду на случай потери UDP-пакета).
  Future<ServerQueryResult> query(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 3),
    bool fullFileList = true,
  }) async {
    final InternetAddress address;
    final RawDatagramSocket socket;
    try {
      address = await resolve(host);
      socket = await _socketFor(address);
    } catch (e) {
      return ServerQueryResult(error: e is SocketException ? e.message : '$e');
    }

    final key = _key(address, port);
    if (_pending.containsKey(key)) {
      return ServerQueryResult(error: 'Already querying');
    }
    final q = _Pending();
    _pending[key] = q;

    Timer? resend;
    try {
      q.stopwatch.start();
      final packet = Srb2Codec.askInfo(DateTime.now().millisecondsSinceEpoch & 0xFFFFFFFF, protocol);
      socket.send(packet, address, port);
      resend = Timer.periodic(const Duration(seconds: 1), (_) {
        try {
          if (!q.info.isCompleted) socket.send(packet, address, port);
        } catch (_) {} // сеть недоступна — ответа не будет, ждём тайм-аута
      });

      var info = await q.info.future.timeout(timeout);
      resend.cancel();

      // PT_PLAYERINFO сервер шлёт сразу после PT_SERVERINFO.
      final players = await q.players.future
          .timeout(const Duration(milliseconds: 800), onTimeout: () => const <ServerPlayer>[]);

      if (fullFileList && info.hasMoreFiles) {
        info = info.withFiles(await _fetchRemainingFiles(socket, address, port, q, info.files));
      }
      return ServerQueryResult(info: info, players: players, pingMs: q.pingMs);
    } on TimeoutException {
      return ServerQueryResult(error: 'No response');
    } on FormatException catch (e) {
      return ServerQueryResult(error: e.message, pingMs: q.pingMs);
    } catch (e) {
      return ServerQueryResult(error: '$e');
    } finally {
      resend?.cancel();
      _pending.remove(key);
    }
  }

  /// Если аддонов много, сервер присылает остаток по PT_TELLFILESNEEDED.
  Future<List<ServerFile>> _fetchRemainingFiles(
    RawDatagramSocket socket,
    InternetAddress address,
    int port,
    _Pending q,
    List<ServerFile> first,
  ) async {
    final files = [...first];
    for (var round = 0; round < 64; round++) {
      final c = Completer<MoreFiles>();
      q.moreFiles = c;
      MoreFiles? more;
      for (var attempt = 0; attempt < 3 && more == null; attempt++) {
        socket.send(Srb2Codec.tellFilesNeeded(files.length, protocol), address, port);
        try {
          more = await c.future.timeout(const Duration(milliseconds: 1200));
        } on TimeoutException {
          more = null;
        }
      }
      if (more == null || more.files.isEmpty) break;
      if (more.first != files.length) break; // не тот кусок — не рискуем
      files.addAll(more.files);
      if (!more.more) break;
    }
    q.moreFiles = null;
    return files;
  }

  void close() {
    _v4?.close();
    _v6?.close();
    _v4 = null;
    _v6 = null;
  }
}
