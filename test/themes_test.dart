import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:srb2_autonomi_launcher/theme/app_themes.dart';

void main() {
  test('colors: #RGB, #RRGGBB, #AARRGGBB', () {
    expect(LauncherTheme.parseColor('#1E5BFF'), const Color(0xFF1E5BFF));
    expect(LauncherTheme.parseColor('fff'), const Color(0xFFFFFFFF));
    expect(LauncherTheme.parseColor('#801E5BFF'), const Color(0x801E5BFF));
    expect(LauncherTheme.parseColor('blue'), isNull);
    expect(LauncherTheme.hex(const Color(0xFF1E5BFF)), '#1E5BFF');
    expect(LauncherTheme.hex(const Color(0x801E5BFF)), '#801E5BFF');
  });

  test('a theme from JSON and back; errors', () {
    final t = LauncherTheme.fromJson({'name': 'Ocean', 'seed': '#1E5BFF', 'background': '#0A0F1E'}, key: 'file:ocean');
    expect((t.name, t.dark, t.seed, t.background, t.accent), ('Ocean', true, const Color(0xFF1E5BFF), const Color(0xFF0A0F1E), null));
    expect(t.toJson(), {'name': 'Ocean', 'dark': true, 'seed': '#1E5BFF', 'background': '#0A0F1E'});
    expect(t.data.scaffoldBackgroundColor, const Color(0xFF0A0F1E));
    expect(() => LauncherTheme.fromJson({'seed': '#000'}, key: 'x'), throwsFormatException);
    expect(() => LauncherTheme.fromJson({'name': 'X', 'seed': 'nope'}, key: 'x'), throwsFormatException);
  });

  test('exact accent, panels and text are used', () {
    const t = LauncherTheme(
      key: 'x',
      name: 'X',
      seed: Colors.red,
      accent: Color(0xFF00FF00),
      panels: Color(0xFF101010),
      text: Color(0xFFEEEEEE),
    );
    final s = t.colorScheme;
    expect((s.primary, s.surface, s.onSurface), (const Color(0xFF00FF00), const Color(0xFF101010), const Color(0xFFEEEEEE)));
    expect(s.onPrimary, const Color(0xFF111111)); // на ярко-зелёном — тёмный текст
  });

  test('built-in themes look as before: the default dark window background', () {
    final data = AppThemes.builtIn.first.data;
    expect(data.scaffoldBackgroundColor, ThemeData.dark(useMaterial3: true).scaffoldBackgroundColor);
    expect(data.colorScheme.brightness, Brightness.dark);
  });

  test('the themes that come with the launcher are valid', () {
    final files = Directory('themes').listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList();
    expect(files, isNotEmpty);
    for (final f in files) {
      final t = LauncherTheme.fromJson(jsonDecode(f.readAsStringSync()) as Map<String, dynamic>, key: AppThemes.keyOf(f.path));
      expect(t.data, isA<ThemeData>(), reason: f.path);
    }
  });
}
