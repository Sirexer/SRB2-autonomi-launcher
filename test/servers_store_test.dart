import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:srb2_autonomi_launcher/services/servers_store.dart';

Map<String, dynamic> known(String host, DateTime seen) =>
    {'host': host, 'port': 5029, 'title': host, 'version': '2.2.15', 'room': 0, 'seen': seen.toIso8601String()};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.now();

  test('local list: servers older than the retention are removed, the rest are marked local', () async {
    SharedPreferences.setMockInitialValues({
      'servers_retention': 'week',
      'servers_known': jsonEncode({
        'servers': [
          known('fresh.example', now.subtract(const Duration(days: 2))),
          known('stale.example', now.subtract(const Duration(days: 10))),
        ],
      }),
    });
    final store = ServersStore();
    await store.load();
    expect(store.known.keys, ['fresh.example:5029']);
    final row = store.rows.single;
    expect(row.fromLocal, isTrue);
    expect(row.lastSeen, isNotNull);
    expect(store.usingCache, isTrue);

    await store.setRetention(LocalListRetention.off);
    expect(store.known, isEmpty);
    expect(store.rows, isEmpty);
  });

  test('forever keeps everything; favourites are never marked local', () async {
    SharedPreferences.setMockInitialValues({
      'servers_retention': 'forever',
      'servers_known': jsonEncode({
        'servers': [known('old.example', now.subtract(const Duration(days: 999)))],
      }),
      'servers_favorites': jsonEncode([
        {'host': 'mine.example', 'port': 5029, 'name': 'Mine'},
      ]),
    });
    final store = ServersStore();
    await store.load();
    final rows = {for (final r in store.rows) r.host: r};
    expect(rows.keys, containsAll(['old.example', 'mine.example']));
    expect(rows['mine.example']!.fromLocal, isFalse);
    expect(rows['old.example']!.fromLocal, isTrue);
  });

  test('the old cache is migrated into the local list', () async {
    SharedPreferences.setMockInitialValues({
      'servers_cache': jsonEncode({
        'time': now.toIso8601String(),
        'servers': [
          {'host': 'cached.example', 'port': 5030, 'title': 'C', 'version': '2.2.15', 'room': 0},
        ],
      }),
    });
    final store = ServersStore();
    await store.load();
    expect(store.retention, LocalListRetention.month); // по умолчанию
    expect(store.known.keys, ['cached.example:5030']);
  });

  test('options are saved and loaded; hide offline is on by default', () async {
    SharedPreferences.setMockInitialValues({});
    final store = ServersStore();
    await store.load();
    expect(store.hideOffline, isTrue);
    expect(store.preloadAddons, isTrue);
    await store.updateOptions((s) {
      s.preloadAddons = false;
      s.modifiedOnly = true;
      s.shownGametypes.add('match');
    });
    final again = ServersStore();
    await again.load();
    expect(again.preloadAddons, isFalse);
    expect(again.modifiedOnly, isTrue);
    expect(again.shownGametypes, {'match'});
  });
}
