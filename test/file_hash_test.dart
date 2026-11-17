import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:srb2_autonomi_launcher/models/srb2_server.dart';
import 'package:srb2_autonomi_launcher/services/file_hash.dart';
import 'package:srb2_autonomi_launcher/services/server_files.dart';

/// XXH3-64 (BlanKart): значения — из эталонной библиотеки xxHash
/// (python xxhash.xxh3_64_hexdigest), в виде байтов little-endian.
void main() {
  Uint8List data(int n) => Uint8List.fromList([for (var i = 0; i < n; i++) (i * 31 + 7) & 0xFF]);
  String le(String bigEndianHex) =>
      [for (var i = 14; i >= 0; i -= 2) bigEndianHex.substring(i, i + 2)].join();

  const reference = [
    (0, '2d06800538d394c2'),
    (1, '4c5cca45d0f4811f'),
    (3, '15f7093b173d005c'),
    (16, '7e484c18d74895d0'),
    (17, '208bde5ee2bed407'),
    (128, 'f92b70eaa21a6288'),
    (129, 'f8f76713f2bb60fa'),
    (240, 'ccc7375172c41f03'),
    (241, '0b3b630948ce4a00'),
    (1000, '989765d0ea7a5ecd'),
    (1024, '23bc880ebf0d29c6'),
    (5000, '559fff92c2b7f8ee'),
    (100000, 'ccf90df7e7e37036'),
    (1048577, 'a52e79bed5526510'),
  ];

  test('xxh3 of bytes matches xxHash', () {
    for (final (n, hex) in reference) {
      expect(FileHash.xxh3Hex(data(n)), le(hex), reason: '$n bytes');
    }
  });

  test('xxh3 of a file (streamed) matches xxHash; downloads are checked with it', () async {
    final dir = await Directory.systemTemp.createTemp('xxh3');
    try {
      for (final (n, hex) in reference) {
        final f = File('${dir.path}/f$n.pk3')..writeAsBytesSync(data(n));
        expect(await FileHash.xxh3OfFile(f.path), le(hex), reason: '$n bytes');
      }
      final file = ServerFile(name: 'f5000.pk3', size: 5000, md5: le('559fff92c2b7f8ee'), willSend: ServerFileSend.yes, isFolder: false);
      expect(await ServerFileDownloader.checksumMatches('${dir.path}/f5000.pk3', file), isTrue);
      expect(await ServerFileDownloader.checksumMatches('${dir.path}/f1000.pk3', file), isFalse);
      // Уже скачанный файл находится по сумме, а не только по имени.
      Directory('${dir.path}/DOWNLOAD').createSync();
      File('${dir.path}/DOWNLOAD/f5000.pk3').writeAsBytesSync(data(4999) + [0]); // тот же размер, другая сумма
      final index = await LocalFileIndex.build(dir.path);
      expect(await index.find(file), '${dir.path}/f5000.pk3');
      // Зеркало BlanKart: без ?md5=.
      expect(ServerFileDownloader.mirrorUrl('http://x/files/', file).toString(), 'http://x/files/f5000.pk3');
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}
