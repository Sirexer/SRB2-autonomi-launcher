import 'dart:convert';
import 'dart:io';

import 'app_log.dart';

/// Шрифты, установленные в системе (названия семейств), для выбора в теме.
/// Linux — `fc-list`; Windows — список шрифтов .NET (как в Word), иначе
/// реестр. Ищется один раз.
class SystemFonts {
  SystemFonts._();

  static Future<List<String>>? _cached;

  static Future<List<String>> list() => _cached ??= _find();

  static Future<List<String>> _find() async {
    try {
      final names = Platform.isWindows ? await _windows() : await _fontconfig();
      final out = names.map((n) => n.trim()).where((n) => n.isNotEmpty && !n.startsWith('.')).toSet().toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return out;
    } catch (e) {
      AppLog.console('[fonts] could not list the system fonts: $e');
      return const [];
    }
  }

  /// `fc-list : family` — строка на шрифт, у переведённых названий — через
  /// запятую (берём первое).
  static Future<List<String>> _fontconfig() async {
    final r = await Process.run('fc-list', [':', 'family'], stdoutEncoding: utf8);
    if (r.exitCode != 0) return const [];
    return [
      for (final line in const LineSplitter().convert('${r.stdout}'))
        if (line.trim().isNotEmpty) line.split(',').first.replaceAll(r'\-', '-'),
    ];
  }

  static Future<List<String>> _windows() async {
    final r = await Process.run(
      'powershell',
      [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        '[Console]::OutputEncoding = [Text.Encoding]::UTF8; Add-Type -AssemblyName System.Drawing; '
            '(New-Object System.Drawing.Text.InstalledFontCollection).Families | ForEach-Object { \$_.Name }',
      ],
      stdoutEncoding: utf8,
    ).timeout(const Duration(seconds: 20));
    final names = const LineSplitter().convert('${r.stdout}');
    if (r.exitCode == 0 && names.isNotEmpty) return names;
    return _registry();
  }

  /// Запасной путь: имена из реестра («Arial Bold (TrueType)» → Arial).
  static Future<List<String>> _registry() async {
    final out = <String>[];
    for (final hive in ['HKLM', 'HKCU']) {
      final r = await Process.run('reg', ['query', '$hive\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Fonts']);
      for (final line in const LineSplitter().convert('${r.stdout}')) {
        final m = RegExp(r'^\s{2,}(.+?)\s+REG_SZ\s').firstMatch(line);
        if (m == null) continue;
        final name = m[1]!.replaceAll(RegExp(r'\s*\((TrueType|OpenType|All res)\)$', caseSensitive: false), '');
        for (final part in name.split(' & ')) {
          out.add(familyOf(part));
        }
      }
    }
    return out;
  }

  static final _styleWords = RegExp(
      r'(\s+(Regular|Bold|Italic|Oblique|Light|Thin|Medium|Semibold|SemiBold|Demibold|DemiBold|Black|Heavy|'
      r'ExtraBold|Extrabold|ExtraLight|Extralight|UltraLight|SemiLight|Semilight|Book|Condensed|Narrow))+$');

  /// Название семейства без слов начертания: «Segoe UI Bold Italic» → «Segoe UI».
  static String familyOf(String name) {
    final f = name.trim().replaceAll(_styleWords, '').trim();
    return f.isEmpty ? name.trim() : f;
  }
}
