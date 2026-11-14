import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:srb2_autonomi_launcher/services/app_paths.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('app_paths_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('pointer.txt: the first line that is not a comment, without autonomi://', () {
    expect(AppPaths.pointerIn(tmp.path), isNull);
    File(p.join(tmp.path, 'pointer.txt')).writeAsStringSync('# repository\n\n  autonomi://4745e89c  extra\nother\n');
    expect(AppPaths.pointerIn(tmp.path), '4745e89c');
    File(p.join(tmp.path, 'pointer.txt')).writeAsStringSync('\n# only a comment\n');
    expect(AppPaths.pointerIn(tmp.path), isNull);
  });

  test('portable settings: one JSON file, kept between starts', () async {
    final path = p.join(tmp.path, 'shared_preferences.json');
    final store = await PortablePreferencesStore.open(path);
    await store.setValue('String', 'flutter.app_language', 'ru');
    await store.setValue('StringList', 'flutter.queue', <String>['a.pk3', 'b.wad']);
    await store.setValue('Bool', 'flutter.progress_enabled', true);
    await store.remove('flutter.progress_enabled');

    final again = await PortablePreferencesStore.open(path);
    expect(await again.getAll(), {
      'flutter.app_language': 'ru',
      'flutter.queue': ['a.pk3', 'b.wad'],
    });
    expect(await again.getAll(), isA<Map<String, Object>>());
    expect((await again.getAll())['flutter.queue'], isA<List<String>>());
    await again.clear();
    expect(await (await PortablePreferencesStore.open(path)).getAll(), isEmpty);
  });
}
