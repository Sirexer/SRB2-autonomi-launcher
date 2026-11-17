import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../models/srb2_server.dart';
import 'server_files.dart';
import 'srb2_query.dart';

/// Ошибка скачивания с сервера (понятный пользователю текст).
class TransferException implements Exception {
  final String message;
  const TransferException(this.message);
  @override
  String toString() => message;
}

/// Скачивание отменено пользователем.
class TransferCancelled extends TransferException {
  const TransferCancelled() : super('Cancelled');
}

/// Скачивание аддонов прямо с сервера SRB2 тем же UDP-протоколом, что и игра
/// (src/netcode/d_netfil.c), без подключения к игре:
///
/// 1. PT_REQUESTFILE: [номер файла, 0xFF] — номер = позиция в списке аддонов сервера.
/// 2. Сервер шлёт PT_FILEFRAGMENT по ~1 КБ проходами (iteration).
/// 3. Мы подтверждаем фрагменты PT_FILEACK (битовые маски по 32 фрагмента),
///    сервер досылает недостающее на следующем проходе.
/// 4. Получив всё — PT_FILERECEIVED.
///
/// У сервера нет таймаута для таких клиентов, поэтому [close] обязательно
/// шлёт PT_CLIENTQUIT — иначе сервер продолжит слать фрагменты.
///
/// Важно: никогда не подтверждать ВСЕ фрагменты файла. FileSendTicker
/// сервера пропускает подтверждённые фрагменты циклом и заканчивает отправку,
/// только когда «подтверждённый размер» (по целому фрагменту за каждый, и за
/// последний неполный тоже) равен размеру файла — то есть почти никогда. Если
/// подтверждено всё, а PT_FILERECEIVED ещё не дошёл, этот цикл бесконечен и
/// сервер зависает намертво. Игра так не делает: фрагмент, которым файл
/// завершился, она не подтверждает, а шлёт PT_FILERECEIVED. Мы — так же.
class Srb2FileTransfer {
  static const ptClientQuit = 11;
  static const ptRequestFile = 15;
  static const ptFileFragment = 24;
  static const ptFileAck = 25;
  static const ptFileReceived = 26;

  /// Заголовок filetx_pak: fileid(1) filesize(4) iteration(1) position(4) size(2).
  static const fragmentHeader = 12;
  static const _maxSegmentsPerAck = 64; // 512 байт, как в игре

  /// Заголовок filetx_pak SRB2Kart: fileid(1) position(4) size(2).
  static const legacyFragmentHeader = 7;

  final String host;
  final int port;

  /// Протокол игры: номера пакетов и формат PT_REQUESTFILE.
  final NetProtocol protocol;

  RawDatagramSocket? _socket;
  InternetAddress? _address;
  _Job? _job;
  final Set<int> _finished = {};
  DateTime _lastReceivedReply = DateTime(0);

  Srb2FileTransfer(this.host, this.port, {this.protocol = NetProtocol.srb2});

  /// PT_REQUESTFILE: SRB2 — [номер, 0xFF]; Ring Racers — [номер, имя\0, 0xFF].
  List<int> _requestPayload(int fileId, String name) => [
        fileId,
        if (protocol.requestFileWithName) ...[...latin1.encode(_baseName(name)), 0],
        0xFF,
      ];

  static String _baseName(String name) {
    final i = name.lastIndexOf(RegExp(r'[/\\]'));
    return i < 0 ? name : name.substring(i + 1);
  }

  /// Номер файла в протоколе — один байт, 0xFF зарезервирован.
  static bool canRequest(int fileId) => fileId >= 0 && fileId < 0xFF;

  Future<void> open() async {
    _address = await Srb2QueryClient.resolve(host);
    // Отдельный сокет (порт) — сервер заведёт под нас новый узел.
    _socket = await RawDatagramSocket.bind(
      _address!.type == InternetAddressType.IPv6 ? InternetAddress.anyIPv6 : InternetAddress.anyIPv4,
      0,
    );
    _socket!.listen(
      (event) {
        if (event != RawSocketEvent.read) return;
        Datagram? d;
        while ((d = _socket?.receive()) != null) {
          _onPacket(d!);
        }
      },
      onError: (Object _) {}, // «сеть недоступна» и т.п. — скачивание упрётся в тайм-аут
    );
  }

  void _send(int type, List<int> payload) {
    final socket = _socket;
    final address = _address;
    if (socket == null || address == null) return;
    try {
      socket.send(
        Srb2Codec.buildPacket(type, payload, ackReturn: protocol.legacyFileTransfer ? _firstAck : 0),
        address,
        port,
      );
    } catch (_) {} // сеть недоступна — ответа не будет, сработает тайм-аут
  }

  // --- Подтверждения "надёжных" пакетов (SRB2Kart, d_net.c) ---
  //
  // Сервер шлёт фрагменты с номером ack (1..255, по кругу без 0) и держит
  // не больше 96 неподтверждённых, переотправляя их, пока не придёт
  // подтверждение. Мы, как игра (Processackpak/Net_SendAcks), шлём
  // ackreturn — последний номер, до которого всё получено подряд, — и
  // PT_NOTHING со списком номеров, пришедших не по порядку.

  int _firstAck = 0;
  final List<int> _ackQueue = [];
  bool _acksPending = false;
  int _fragmentsSinceAck = 0;

  static int _cmpAck(int a, int b) {
    final d = a - b;
    return d >= 127 || d < -128 ? -d : d;
  }

  static int _nextAck(int a) {
    final n = (a + 1) & 0xFF;
    return n == 0 ? 1 : n;
  }

  void _gotReliable(int ack) {
    _acksPending = true; // и на повтор отвечаем: наше подтверждение могло потеряться
    if (_cmpAck(ack, _firstAck) <= 0 || _ackQueue.contains(ack)) return;
    if (ack == _nextAck(_firstAck)) {
      _firstAck = ack;
      while (_ackQueue.remove(_nextAck(_firstAck))) {
        _firstAck = _nextAck(_firstAck);
      }
      _ackQueue.removeWhere((a) => _cmpAck(a, _firstAck) <= 0);
    } else if (_ackQueue.length < _maxAckQueue - 1) {
      _ackQueue.add(ack);
    }
  }

  static const _maxAckQueue = 96; // MAXACKTOSEND

  void _sendNetAcks() {
    if (!_acksPending) return;
    _acksPending = false;
    _fragmentsSinceAck = 0;
    final payload = Uint8List(_maxAckQueue);
    for (var i = 0; i < _ackQueue.length; i++) {
      payload[i] = _ackQueue[i];
    }
    _send(NetProtocol.ptNothing, payload);
  }

  /// Фрагмент SRB2Kart: filetx_pak { fileid; position (старший бит — последний
  /// фрагмент); size; data }.
  void _onLegacyFragment(Uint8List data) {
    const o = Srb2Protocol.headerSize;
    if (data.length < o + legacyFragmentHeader) return;
    final bd = ByteData.sublistView(data);
    final fileId = data[o];
    final rawPosition = bd.getUint32(o + 1, Endian.little);
    final size = bd.getUint16(o + 5, Endian.little);
    final end = math.min(o + legacyFragmentHeader + size, data.length);
    final payload = Uint8List.sublistView(data, o + legacyFragmentHeader, end);

    if (++_fragmentsSinceAck >= 8) _sendNetAcks();
    final job = _job;
    if (job == null || job.fileId != fileId) return;
    job.onLegacyFragment(rawPosition & 0x7FFFFFFF, payload, rawPosition & 0x80000000 != 0);
  }

  void _onPacket(Datagram d) {
    if (d.port != port || d.address.address != _address?.address) return;
    final data = Uint8List.fromList(d.data);
    final type = Srb2Codec.packetType(data);
    if (type == null) return;
    if (protocol.legacyFileTransfer) {
      if (data[4] != 0) _gotReliable(data[4]);
      if (type == protocol.ptFileFragment) _onLegacyFragment(data);
      return;
    }
    if (type != protocol.ptFileFragment) return;
    if (data.length < Srb2Protocol.headerSize + fragmentHeader) return;

    const o = Srb2Protocol.headerSize;
    final bd = ByteData.sublistView(data);
    final fileId = data[o];
    final fileSize = bd.getUint32(o + 1, Endian.little);
    final iteration = data[o + 5];
    final position = bd.getUint32(o + 6, Endian.little);
    final fragmentSize = bd.getUint16(o + 10, Endian.little);
    final payload = Uint8List.sublistView(data, o + fragmentHeader);

    final job = _job;
    if (job == null || job.fileId != fileId) {
      // Хвосты уже скачанного файла (наше подтверждение потерялось) — повторяем.
      if (_finished.contains(fileId) &&
          DateTime.now().difference(_lastReceivedReply) > const Duration(milliseconds: 200)) {
        _lastReceivedReply = DateTime.now();
        _send(protocol.ptFileReceived, [fileId]);
      }
      return;
    }
    job.onFragment(fileSize, iteration, position, fragmentSize, payload);
  }

  /// Скачивает файл [fileId] (позиция в списке аддонов сервера) в [targetPath].
  /// Размер и MD5 проверяются; при ошибке файл не остаётся на диске.
  Future<void> download({
    required int fileId,
    required ServerFile file,
    required String targetPath,
    void Function(int received, int total)? onProgress,
    bool Function()? isCancelled,
    Duration startTimeout = const Duration(seconds: 8),
    Duration stallTimeout = const Duration(seconds: 20),
  }) async {
    if (_socket == null) await open();
    if (!canRequest(fileId)) {
      throw const TransferException('The server lists too many addons to request this one');
    }

    final part = File('$targetPath.part');
    await part.parent.create(recursive: true);
    final raf = await part.open(mode: FileMode.write);
    final job = _Job(fileId, raf, onProgress);
    // В SRB2Kart размер файла в фрагментах не передаётся (только у последнего).
    if (protocol.legacyFileTransfer && file.size > 0) job.total = file.size;
    _job = job;

    Timer? ticker;
    var requests = 0;
    final started = DateTime.now();
    try {
      final request = _requestPayload(fileId, file.name);
      _send(protocol.ptRequestFile, request);
      requests++;

      ticker = Timer.periodic(const Duration(milliseconds: 50), (_) {
        if (job.done.isCompleted) return;
        if (isCancelled?.call() ?? false) {
          job.fail(const TransferCancelled());
          return;
        }
        if (protocol.legacyFileTransfer) {
          _sendNetAcks();
        } else {
          _flushAcks(job);
        }

        final now = DateTime.now();
        if (job.lastFragment == null) {
          // Запрос мог потеряться — повторяем (дубликат сервер отработает,
          // а лишние фрагменты мы закроем PT_FILERECEIVED).
          final waited = now.difference(started);
          if (waited > startTimeout) {
            job.fail(const TransferException(
              'The server did not send the file (downloads are disabled or the file is too large)',
            ));
          } else if (waited > Duration(milliseconds: 2500 * requests) &&
              requests < (protocol.legacyFileTransfer ? 2 : 3)) {
            // SRB2Kart поставит файл в очередь ещё раз и пришлёт его дважды,
            // поэтому повторяем запрос только один раз.
            _send(protocol.ptRequestFile, request);
            requests++;
          }
        } else if (now.difference(job.lastFragment!) > stallTimeout) {
          job.fail(const TransferException('The server stopped sending the file'));
        }
      });

      await job.done.future;
      ticker.cancel();
      if (protocol.legacyFileTransfer) {
        _sendNetAcks();
      } else {
        _flushAcks(job);
        _finished.add(fileId);
        // Без гарантии доставки — шлём с повтором; если всё же потеряется,
        // сервер пришлёт неподтверждённый фрагмент ещё раз, и мы ответим снова.
        for (var i = 0; i < 3; i++) {
          _send(protocol.ptFileReceived, [fileId]);
          if (i < 2) await Future<void>.delayed(const Duration(milliseconds: 30));
        }
      }
      await raf.close();

      final total = job.total ?? 0;
      if (file.size > 0 && total != file.size) {
        throw TransferException('Size mismatch: expected ${file.size}, got $total');
      }
      if (!await ServerFileDownloader.checksumMatches(part.path, file)) {
        throw TransferException(file.md5.length == 32 ? 'MD5 mismatch' : 'Checksum mismatch');
      }
      await part.rename(targetPath);
    } catch (_) {
      try {
        await raf.close();
      } catch (_) {}
      if (await part.exists()) await part.delete();
      rethrow;
    } finally {
      ticker?.cancel();
      if (identical(_job, job)) _job = null;
    }
  }

  /// Отправляет накопленные подтверждения: сегменты по 32 фрагмента,
  /// не больше 64 сегментов в пакете.
  void _flushAcks(_Job job) {
    if (job.pendingAcks.isEmpty) return;
    final indices = job.pendingAcks.toList()..sort();
    job.pendingAcks.clear();

    final segments = <int, int>{}; // начало (кратно 32) → биты
    for (final i in indices) {
      final start = i - i % 32;
      segments[start] = (segments[start] ?? 0) | (1 << (i - start));
    }
    final entries = segments.entries.toList();
    for (var from = 0; from < entries.length; from += _maxSegmentsPerAck) {
      final chunk = entries.sublist(from, math.min(from + _maxSegmentsPerAck, entries.length));
      final payload = Uint8List(3 + chunk.length * 8);
      payload[0] = job.fileId;
      payload[1] = job.iteration;
      payload[2] = chunk.length;
      final bd = ByteData.sublistView(payload);
      for (var k = 0; k < chunk.length; k++) {
        bd.setUint32(3 + k * 8, chunk[k].key, Endian.little);
        bd.setUint32(3 + k * 8 + 4, chunk[k].value, Endian.little);
      }
      _send(protocol.ptFileAck, payload);
    }
  }

  /// Сообщает серверу, что мы уходим (он перестанет слать фрагменты), и закрывает сокет.
  Future<void> close() async {
    if (protocol.legacyFileTransfer) {
      _acksPending = true;
      _sendNetAcks();
    }
    for (var i = 0; i < 3; i++) {
      _send(protocol.ptClientQuit, const []);
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    _socket?.close();
    _socket = null;
  }
}

/// Состояние скачивания одного файла.
class _Job {
  final int fileId;
  final RandomAccessFile raf;
  final void Function(int received, int total)? onProgress;
  final Completer<void> done = Completer();
  final Set<int> pendingAcks = {};

  int? total;
  int fragmentSize = 0;
  int iteration = 0;
  int received = 0;
  Uint8List? have;
  DateTime? lastFragment;

  _Job(this.fileId, this.raf, this.onProgress);

  void fail(TransferException e) {
    if (!done.isCompleted) done.completeError(e);
  }

  /// Позиции уже записанных фрагментов (SRB2Kart: размер фрагмента не передаётся).
  final Set<int> _legacyPositions = {};

  void onLegacyFragment(int position, Uint8List data, bool last) {
    if (done.isCompleted) return;
    lastFragment = DateTime.now();
    if (last) total = position + data.length;
    final size = total;
    if (size != null && position + data.length > size) {
      return fail(const TransferException('The server sent more data than the file size'));
    }
    if (data.isNotEmpty && _legacyPositions.add(position)) {
      try {
        raf.setPositionSync(position);
        raf.writeFromSync(data);
      } catch (e) {
        return fail(TransferException('Cannot write the file: $e'));
      }
      received += data.length;
      if (size != null) onProgress?.call(received, size);
    }
    if (size != null && received >= size) done.complete();
  }

  void onFragment(int fileSize, int iter, int position, int fragSize, Uint8List data) {
    if (done.isCompleted) return;
    if (total == null) {
      if (fragSize == 0) return fail(const TransferException('Bad fragment size from the server'));
      total = fileSize;
      fragmentSize = fragSize;
      have = Uint8List(fileSize ~/ fragSize + 1);
      if (fileSize == 0) {
        // Пустой файл: сервер шлёт один фрагмент без данных. Не
        // подтверждаем его (см. выше) — только PT_FILERECEIVED.
        lastFragment = DateTime.now();
        done.complete();
        return;
      }
    }
    if (fileSize != total || fragSize != fragmentSize || position >= total!) return;

    lastFragment = DateTime.now();
    iteration = math.max(iteration, iter);
    final index = position ~/ fragmentSize;
    // Повторный фрагмент тоже подтверждаем: значит, прошлое подтверждение потерялось.
    pendingAcks.add(index);
    if (have![index] != 0) return;

    final length = math.min(data.length, total! - position);
    try {
      raf.setPositionSync(position);
      raf.writeFromSync(data, 0, length);
    } catch (e) {
      return fail(TransferException('Cannot write the file: $e'));
    }
    have![index] = 1;
    received += length;
    onProgress?.call(received, total!);
    if (received >= total!) {
      // Файл собран этим фрагментом — его не подтверждаем, как игра: иначе
      // сервер может зависнуть (см. описание класса). Конец — PT_FILERECEIVED.
      pendingAcks.remove(index);
      done.complete();
    }
  }
}
