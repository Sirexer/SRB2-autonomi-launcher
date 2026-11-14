import 'package:flutter_test/flutter_test.dart';
import 'package:srb2_autonomi_launcher/models/mod_item.dart';
import 'package:srb2_autonomi_launcher/services/addon_updates.dart';

ModItem addon(String id, Map<String, List<(String, String)>> versions) => ModItem.fromJson({
      'id': id,
      'name': 'Addon $id',
      'files': [
        for (final v in versions.entries)
          for (final (name, md5) in v.value) {'name': name, 'version': v.key, 'hash': '$name$md5', 'md5': md5},
      ],
    }, source: 'Hub');

String key(String version, String name) => '$version\u0000$name';

void main() {
  test('downloaded version: the newest one with a file of its own', () {
    final mod = addon('1', {
      '1.0': [('main_v1.pk3', 'a1'), ('music.pk3', 'm')],
      '2.0': [('main_v2.pk3', 'a2'), ('music.pk3', 'm')], // музыка не менялась
    });
    // Есть старый main и общая музыка: скачана 1.0, вышла 2.0.
    final old = {key('1.0', 'main_v1.pk3'), key('1.0', 'music.pk3'), key('2.0', 'music.pk3')};
    expect(AddonUpdates.installed(mod, old)?.name, '1.0');
    expect(AddonUpdates.update(mod, old)?.$2.name, '2.0');
    // Есть новый main: обновлять нечего.
    final fresh = {key('2.0', 'main_v2.pk3'), key('2.0', 'music.pk3')};
    expect(AddonUpdates.installed(mod, fresh)?.name, '2.0');
    expect(AddonUpdates.update(mod, fresh), isNull);
    // Только общий файл: версия неясна — считается самой новой, где он есть.
    expect(AddonUpdates.update(mod, {key('1.0', 'music.pk3'), key('2.0', 'music.pk3')}), isNull);
    expect(AddonUpdates.installed(mod, const {}), isNull);
    // Одна версия — обновлений не бывает.
    final single = addon('2', {'1.0': [('x.pk3', 'x')]});
    expect(AddonUpdates.update(single, {key('1.0', 'x.pk3')}), isNull);
  });

  test('repository diff: new addons and addons with new versions', () {
    final before = [
      addon('1', {'1.0': [('a.pk3', 'a')]}),
      addon('2', {'1.0': [('b.pk3', 'b')]}),
    ];
    final after = [
      addon('1', {'1.0': [('a.pk3', 'a')]}),
      addon('2', {'1.0': [('b.pk3', 'b')], '1.1': [('b11.pk3', 'c')]}),
      addon('3', {'1.0': [('n.pk3', 'n')]}),
    ];
    final d = AddonUpdates.diff(before, after);
    expect([for (final m in d.added) m.id], ['3']);
    expect([for (final m in d.updated) m.id], ['2']);
  });
}
