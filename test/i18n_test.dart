import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:srb2_autonomi_launcher/i18n.dart';

void main() {
  test('Russian is found in lang/ and translates with placeholders', () async {
    final i18n = I18n.instance;
    await i18n.discover();
    expect(i18n.available.map((l) => l.code), containsAll(['en', 'ru']));
    expect(i18n.available.firstWhere((l) => l.code == 'ru').name, 'Русский');

    await i18n.load('ru');
    expect(tr('Settings'), 'Настройки');
    expect(tr('Added {n} executable(s)', {'n': 3}), 'Добавлено сборок: 3');
    expect(tr('Some string nobody translated'), 'Some string nobody translated');

    await i18n.load('en');
    expect(tr('Settings'), 'Settings');
    expect(tr('Added {n} executable(s)', {'n': 2}), 'Added 2 executable(s)');

    await i18n.load('xx'); // нет такого файла — английский
    expect(i18n.code, 'en');
  });

  test('every placeholder in ru.json matches its key', () {
    final ru = jsonDecode(File('lang/ru.json').readAsStringSync()) as Map<String, dynamic>;
    final ph = RegExp(r'\{\w+\}');
    for (final e in ru.entries) {
      if (e.key.startsWith('_')) continue;
      expect(ph.allMatches(e.value as String).map((m) => m[0]).toSet(),
          ph.allMatches(e.key).map((m) => m[0]).toSet(),
          reason: e.key);
    }
  });
}
