import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/game.dart';
import 'app_paths.dart';

/// Свои игры (форки: BlanKart и т.п.) — описания в JSON, на основе одной из
/// встроенных игр (см. [Games.fromDefinition] и docs/custom-games.md).
///
/// - Описания хранятся в настройках лаунчера; иконка — в папке данных
///   (`games/<id>.png`).
/// - Файл с описаниями: одна игра (объект), список игр или `{"games": [...]}`.
///   `another_games.json` рядом с лаунчером предлагается при первом запуске.
/// - Выключенные игры (и встроенные, кроме SRB2) — в [Games.disabled].
class CustomGames {
  CustomGames._();

  static const _kGames = 'custom_games';
  static const _kDisabled = 'games_disabled';

  /// Файл с описаниями игр, который идёт со сборкой.
  static const bundledFile = 'another_games.json';

  /// Загружает свои игры и выключенные — до первого обращения к [Games].
  static Future<void> load(SharedPreferences prefs) async {
    Games.disabled = (prefs.getStringList(_kDisabled) ?? const []).toSet()..remove(Games.srb2.id);
    final out = <GameDef>[];
    final dir = await _iconDir();
    for (final raw in prefs.getStringList(_kGames) ?? const <String>[]) {
      try {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        final icon = j['icon_file'] is String ? p.join(dir, j['icon_file'] as String) : null;
        final def = Map<String, dynamic>.from(j)..remove('icon_file');
        final g = Games.fromDefinition(def, iconFile: icon != null && File(icon).existsSync() ? icon : null);
        if (!out.any((x) => x.id == g.id)) out.add(g);
      } catch (_) {
        // Описание от старой/новой версии лаунчера, которое уже не читается.
      }
    }
    Games.custom = out;
  }

  static Future<String> _iconDir() async => p.join((await getApplicationSupportDirectory()).path, 'games');

  /// Описания игр из текста JSON: объект игры, список или `{"games": [...]}`.
  static List<Map<String, dynamic>> parse(String text) {
    final j = jsonDecode(text);
    final list = j is List ? j : (j is Map && j['games'] is List ? j['games'] as List : [j]);
    final out = [for (final x in list) if (x is Map) Map<String, dynamic>.from(x)];
    if (out.isEmpty) throw const FormatException('No game definitions in the file');
    return out;
  }

  /// Описания из файла [path] и проверка каждого: (описание, игра или null,
  /// ошибка или null). Иконка с путём — относительно папки файла.
  static Future<List<(Map<String, dynamic>, GameDef?, String?)>> readFile(String path) async {
    final defs = parse(await File(path).readAsString());
    return [
      for (final d in defs) _check(d),
    ];
  }

  static (Map<String, dynamic>, GameDef?, String?) _check(Map<String, dynamic> d) {
    try {
      return (d, Games.fromDefinition(d), null);
    } on FormatException catch (e) {
      return (d, null, e.message);
    }
  }

  /// `another_games.json` рядом с лаунчером (у AppImage — и внутри); null — нет.
  static String? bundledPath() {
    for (final dir in {AppPaths.launcherDir, p.dirname(Platform.resolvedExecutable)}) {
      final f = File(p.join(dir, bundledFile));
      if (f.existsSync()) return f.path;
    }
    return null;
  }

  /// Добавляет (или заменяет с тем же id) игру по описанию [def]. Иконка:
  /// `data:image/...;base64,...` или путь относительно [baseDir].
  static Future<GameDef> add(SharedPreferences prefs, Map<String, dynamic> def, {String? baseDir}) async {
    final g0 = Games.fromDefinition(def); // проверка до записи
    final stored = Map<String, dynamic>.from(def)..remove('icon');
    String? iconPath;
    final icon = def['icon'];
    if (icon is String && icon.trim().isNotEmpty) {
      try {
        final dir = await _iconDir();
        await Directory(dir).create(recursive: true);
        final name = '${g0.id}.png';
        final target = p.join(dir, name);
        final v = icon.trim();
        if (v.startsWith('data:')) {
          final comma = v.indexOf(',');
          if (comma > 0) await File(target).writeAsBytes(base64Decode(v.substring(comma + 1)));
        } else {
          final src = p.isAbsolute(v) || baseDir == null ? v : p.join(baseDir, v);
          await File(src).copy(target);
        }
        if (File(target).existsSync()) {
          stored['icon_file'] = name;
          iconPath = target;
        }
      } catch (_) {
        // Нет иконки — будет иконка основы.
      }
    }
    final g = Games.fromDefinition(Map<String, dynamic>.from(stored)..remove('icon_file'), iconFile: iconPath);
    Games.custom = [for (final x in Games.custom) if (x.id != g.id) x, g];
    Games.disabled.remove(g.id);
    await _save(prefs, replace: g.id, stored: stored);
    return g;
  }

  /// Обновляет уже добавленные игры из another_games.json сборки: новая
  /// версия лаунчера может исправить их описание. Игры, которых у
  /// пользователя нет (отказался или убрал), не добавляются. Сколько обновлено.
  static Future<int> refreshFromBundled(SharedPreferences prefs) async {
    final path = bundledPath();
    if (path == null) return 0;
    final List<(Map<String, dynamic>, GameDef?, String?)> found;
    try {
      found = await readFile(path);
    } catch (_) {
      return 0;
    }
    var updated = 0;
    for (final (def, game, _) in found) {
      if (game == null) continue;
      final have = Games.custom.where((g) => g.id == game.id).firstOrNull;
      if (have == null) continue;
      final plain = Map<String, dynamic>.from(def)..remove('icon');
      if (jsonEncode(plain) == jsonEncode(have.definition)) continue;
      final wasEnabled = Games.isEnabled(have);
      await add(prefs, def, baseDir: p.dirname(path));
      if (!wasEnabled) await setEnabled(prefs, game.id, false);
      updated++;
    }
    return updated;
  }

  /// Убирает свою игру из лаунчера (сама игра на диске остаётся). Вернуть —
  /// только снова из JSON.
  static Future<void> remove(SharedPreferences prefs, String id) async {
    Games.custom = [for (final x in Games.custom) if (x.id != id) x];
    Games.disabled.remove(id);
    await _save(prefs, removeId: id);
    try {
      final f = File(p.join(await _iconDir(), '$id.png'));
      if (f.existsSync()) await f.delete();
    } catch (_) {}
  }

  /// Включить/выключить игру (SRB2 не выключается).
  static Future<void> setEnabled(SharedPreferences prefs, String id, bool enabled) async {
    if (id == Games.srb2.id) return;
    enabled ? Games.disabled.remove(id) : Games.disabled.add(id);
    await prefs.setStringList(_kDisabled, Games.disabled.toList()..sort());
  }

  static Future<void> _save(SharedPreferences prefs, {String? replace, Map<String, dynamic>? stored, String? removeId}) async {
    final list = <String>[];
    for (final raw in prefs.getStringList(_kGames) ?? const <String>[]) {
      try {
        final id = (jsonDecode(raw) as Map)['id']?.toString().toLowerCase();
        if (id == replace || id == removeId) continue;
      } catch (_) {
        continue;
      }
      list.add(raw);
    }
    if (stored != null) list.add(jsonEncode(stored));
    await prefs.setStringList(_kGames, list);
    await prefs.setStringList(_kDisabled, Games.disabled.toList()..sort());
  }

  /// Описание игры [g] одним файлом — с иконкой внутри (base64).
  static Future<String> export(GameDef g) async {
    final def = Map<String, dynamic>.from(g.definition ?? const {})..remove('icon_file');
    final icon = g.iconFile;
    if (icon != null && File(icon).existsSync()) {
      def['icon'] = 'data:image/png;base64,${base64Encode(await File(icon).readAsBytes())}';
    } else {
      def.remove('icon');
    }
    return const JsonEncoder.withIndent('  ').convert({'games': [def]});
  }
}
