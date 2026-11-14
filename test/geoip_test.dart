import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:srb2_autonomi_launcher/services/geoip.dart';

/// База в формате tools/build_geoip.py.
ByteData geoDb(List<(String, String)> ranges) {
  final b = BytesBuilder()..add('GEO4'.codeUnits);
  b.add((ByteData(4)..setUint32(0, ranges.length)).buffer.asUint8List());
  for (final (start, code) in ranges) {
    var ip = 0;
    for (final part in start.split('.')) {
      ip = ip * 256 + int.parse(part);
    }
    b.add((ByteData(4)..setUint32(0, ip)).buffer.asUint8List());
    b.add(code.codeUnits);
  }
  return ByteData.sublistView(b.toBytes());
}

void main() {
  final geo = GeoIp.fromBytes(geoDb([
    ('0.0.0.0', '--'),
    ('1.0.0.0', 'AU'),
    ('1.0.1.0', 'CN'),
    ('1.0.8.0', '--'),
    ('5.0.0.0', 'RU'),
    ('6.0.0.0', '--'),
    ('255.255.255.0', 'ZZ'),
  ]))!;

  test('country by IPv4 address', () {
    expect(geo.country('1.0.0.7'), 'AU');
    expect(geo.country('1.0.1.0'), 'CN');
    expect(geo.country('1.0.7.255'), 'CN');
    expect(geo.country('1.0.8.0'), isNull);
    expect(geo.country('5.18.0.1'), 'RU');
    expect(geo.country('0.1.2.3'), isNull);
    expect(geo.country('255.255.255.255'), isNull);
  });

  test('not an IPv4 address — unknown', () {
    expect(geo.country('ms.example.net'), isNull);
    expect(geo.country('::1'), isNull);
    expect(geo.country('1.2.3.256'), isNull);
    expect(geo.country('1.2.3'), isNull);
  });

  test('a broken file is not a database', () {
    expect(GeoIp.fromBytes(ByteData(4)), isNull);
    expect(GeoIp.fromBytes(ByteData.sublistView(Uint8List.fromList([...'GEO4'.codeUnits, 0, 0, 0, 9]))), isNull);
  });

  test('country names', () {
    expect(GeoIp.name('ru'), 'Russia');
    expect(GeoIp.name('QQ'), 'QQ');
  });
}
