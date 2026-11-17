import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:xxh3/xxh3.dart';

/// Контрольные суммы файлов не-MD5. BlanKart вместо MD5 шлёт XXH3-64 всего
/// файла (src/w_wad.c, hashfile): 8 байт UINT64 little-endian — в
/// [ServerFile.md5] они записаны hex по порядку байтов (16 символов).
class FileHash {
  FileHash._();

  /// Сумма в виде MD5 (32 hex-символа); иначе — XXH3-64 (16).
  static bool isMd5(String hash) => hash.length == 32;

  /// XXH3-64 (seed 0) байтов [data] — в том же виде, что приходит от сервера.
  static String xxh3Hex(Uint8List data) => _hex(xxh3(data));

  /// XXH3-64 файла (в отдельном изоляте); null — не прочитать.
  static Future<String?> xxh3OfFile(String path) async {
    try {
      return await Isolate.run(() async {
        final file = File(path);
        if (!await file.exists()) return null;
        final state = xxh3Stream();
        await for (final chunk in file.openRead()) {
          state.update(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
        }
        return _hex(state.digest());
      });
    } catch (_) {
      return null;
    }
  }

  /// UINT64 → hex байтов little-endian (как WRITEUINT64 в пакете).
  static String _hex(int v) {
    final b = StringBuffer();
    for (var i = 0; i < 8; i++) {
      b.write(((v >> (8 * i)) & 0xFF).toRadixString(16).padLeft(2, '0'));
    }
    return b.toString();
  }
}
