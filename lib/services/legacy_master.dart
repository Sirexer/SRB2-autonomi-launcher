import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models/srb2_server.dart';

/// Старый мастер-сервер SRB2 2.1 (SRB2 Legacy, src/mserv.c): не HTTP, а TCP
/// на порту 28900. Адрес — `хост:порт` (`ms.srb2classic.net:28900`).
///
/// Сообщение: заголовок 16 байт — id, type, room, length (type/room/length
/// в сетевом порядке байт) — и `length` байт данных. На запрос приходит по
/// сообщению на запись; пустое (length 0) — конец списка.
class LegacyMaster {
  LegacyMaster._();

  static const getRooms = 210; // GET_ROOMS_MSG
  static const getBanned = 215; // GET_BANNED_MSG — вместо списка: вы забанены
  static const getExtServers = 217; // GET_EXT_SERVER_MSG

  static const defaultPort = 28900;
  static const _headerSize = 16;
  static const _maxMessage = 1024; // PACKET_SIZE

  /// Мастер-сервер задан не ссылкой http(s), а `хост:порт` — старый протокол.
  static bool isLegacyAddress(String master) {
    final m = master.trim().toLowerCase();
    return m.isNotEmpty && !m.startsWith('http://') && !m.startsWith('https://');
  }

  /// `ms.example.net:28900`, `ms.example.net`, `[::1]:28900` → (хост, порт).
  static (String, int) parseAddress(String master) {
    var m = master.trim();
    if (m.startsWith('[')) {
      final end = m.indexOf(']');
      if (end > 0) {
        final port = m.length > end + 2 && m[end + 1] == ':' ? int.tryParse(m.substring(end + 2)) : null;
        return (m.substring(1, end), port ?? defaultPort);
      }
    }
    final colon = m.lastIndexOf(':');
    // Один двоеточие — порт; несколько — голый IPv6-адрес без порта.
    if (colon > 0 && m.indexOf(':') == colon) {
      final port = int.tryParse(m.substring(colon + 1));
      if (port != null) return (m.substring(0, colon), port);
      m = m.substring(0, colon);
    }
    return (m, defaultPort);
  }

  static Uint8List request(int type, int room) {
    final b = ByteData(_headerSize);
    b.setInt32(4, type, Endian.big);
    b.setInt32(8, room, Endian.big);
    b.setUint32(12, 0, Endian.big);
    return b.buffer.asUint8List();
  }

  /// Режет поток на сообщения до пустого (конец списка): (тип, данные).
  /// null — поток ещё не полон.
  static List<(int, Uint8List)>? splitMessages(Uint8List stream) {
    final out = <(int, Uint8List)>[];
    final bd = ByteData.sublistView(stream);
    var p = 0;
    while (p + _headerSize <= stream.length) {
      final type = bd.getInt32(p + 4, Endian.big);
      final length = bd.getUint32(p + 12, Endian.big);
      if (length > _maxMessage) throw const FormatException('Bad master server answer');
      if (length == 0) return out;
      if (p + _headerSize + length > stream.length) return null;
      out.add((type, Uint8List.sublistView(stream, p + _headerSize, p + _headerSize + length)));
      p += _headerSize + length;
    }
    return null;
  }

  static String _cString(Uint8List b, int offset, int max) {
    var end = offset;
    while (end < offset + max && end < b.length && b[end] != 0) {
      end++;
    }
    // По символу на байт: в названии бывают коды цвета SRB2.
    return String.fromCharCodes(b, offset, end);
  }

  /// msg_ext_server_t: header[16] ip[40] port[8] name[32] room(INT32) version[8].
  static MasterServerEntry? parseServer(Uint8List m) {
    if (m.length < 16 + 40 + 8 + 32 + 4) return null;
    final host = _cString(m, 16, 40).trim();
    final port = int.tryParse(_cString(m, 56, 8).trim());
    if (host.isEmpty || port == null) return null;
    return MasterServerEntry(
      host: host,
      port: port,
      title: _cString(m, 64, 32),
      version: m.length >= 108 ? _cString(m, 100, 8) : '',
      room: ByteData.sublistView(m).getInt32(96, Endian.little),
    );
  }

  /// msg_rooms_t: header[16] id(INT32) name[32] motd[255] → (номер, название).
  static (int, String)? parseRoom(Uint8List m) {
    if (m.length < 16 + 4 + 1) return null;
    final name = latin1.decode(_cString(m, 20, 32).codeUnits, allowInvalid: true).trim();
    return name.isEmpty ? null : (ByteData.sublistView(m).getInt32(16, Endian.little), name);
  }

  static Future<List<(int, Uint8List)>> _ask(String host, int port, int type, int room) async {
    final socket = await Socket.connect(host, port, timeout: const Duration(seconds: 8));
    try {
      socket.add(request(type, room));
      await socket.flush();
      final data = BytesBuilder(copy: false);
      await for (final chunk in socket.timeout(const Duration(seconds: 10))) {
        data.add(chunk);
        final messages = splitMessages(data.toBytes());
        if (messages != null) return messages;
        if (data.length > 4 << 20) throw const FormatException('The master server answer is too long');
      }
      // Сервер закрыл соединение без пустого сообщения — что успело прийти.
      return splitMessages(Uint8List.fromList([...data.toBytes(), ...Uint8List(_headerSize)])) ?? const [];
    } finally {
      socket.destroy();
    }
  }

  /// Серверы всех комнат (room -1, как «All» в меню игры).
  static Future<List<MasterServerEntry>> fetchServers(String master) async {
    final (host, port) = parseAddress(master);
    final messages = await _ask(host, port, getExtServers, -1);
    return [
      for (final (_, body) in messages)
        if (parseServer(body) case final entry?) entry,
    ];
  }

  /// Комнаты: номер → название. Пусто — не ответил (не обязательно).
  static Future<Map<int, String>> fetchRooms(String master) async {
    final (host, port) = parseAddress(master);
    final messages = await _ask(host, port, getRooms, 0);
    return {
      for (final (type, body) in messages)
        if (type != getBanned)
          if (parseRoom(body) case (final id, final name)) id: name,
    };
  }
}
