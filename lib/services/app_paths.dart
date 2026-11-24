import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

/// Где лаунчер хранит настройки и кэш.
///
/// - Обычно — в папке данных системы: `%APPDATA%\SRB2 Autonomi Launcher`,
///   `~/.local/share/com.srb2.autonomi_launcher`. Папка данных тестовых
///   сборок переезжает туда при первом запуске ([_moveOldDataFolder]).
/// - **Портативный режим**: рядом с лаунчером лежит файл `portable` (или
///   `portable.txt`) — всё хранится в папке `user_data` рядом с ним (удобно
///   на флешке или для готовой папки тестерам).
///
/// [init] — до первого обращения к SharedPreferences и path_provider.
class AppPaths {
  AppPaths._();

  /// Портативный режим: папка данных — [portableDir].
  static bool get portable => portableDir != null;
  static String? portableDir;

  /// Что произошло при запуске (для журнала: он открывается позже).
  static final List<String> startupLog = [];

  static const portableMarkers = ['portable', 'portable.txt'];
  static const portableFolder = 'user_data';
  static const pointerFile = 'pointer.txt';

  /// Папка лаунчера: где лежит exe; у AppImage — где лежит сам .AppImage
  /// (внутри — только для чтения).
  static String get launcherDir {
    final appImage = Platform.environment['APPIMAGE'];
    if (appImage != null && appImage.isNotEmpty) return p.dirname(appImage);
    return p.dirname(Platform.resolvedExecutable);
  }

  static Future<void> init() async {
    final base = launcherDir;
    if (portableMarkers.any((m) => File(p.join(base, m)).existsSync())) {
      try {
        final dir = p.join(base, portableFolder);
        Directory(dir).createSync(recursive: true);
        PathProviderPlatform.instance = PortablePathProvider(dir, PathProviderPlatform.instance);
        SharedPreferencesStorePlatform.instance =
            await PortablePreferencesStore.open(p.join(dir, 'shared_preferences.json'));
        portableDir = dir;
        startupLog.add('portable mode: data in $dir');
        return;
      } catch (e) {
        // Папка только для чтения и т.п. — обычная папка данных.
        startupLog.add('portable mode failed ($e): using the usual data folder');
      }
    }
    await _moveOldDataFolder();
  }

  /// Папка данных тестовых сборок ([_testBuildFolders]) переезжает в
  /// нынешнюю, если её ещё нет или она пустая; опустевшая папка над ней
  /// удаляется.
  static Future<void> _moveOldDataFolder() async {
    try {
      final now = (await getApplicationSupportDirectory()).path;
      final base = p.dirname(now);
      final candidates = [for (final f in _testBuildFolders) p.joinAll([base, ...f])];
      final old = candidates.where((c) => !p.equals(c, now) && Directory(c).existsSync()).firstOrNull;
      if (old == null) return;
      final target = Directory(now);
      if (target.existsSync()) {
        if (target.listSync().isNotEmpty) return;
        target.deleteSync();
      }
      Directory(old).renameSync(now);
      startupLog.add('moved the data folder $old -> $now');
      final parent = Directory(p.dirname(old));
      if (!p.equals(parent.path, base) && parent.existsSync() && parent.listSync().isEmpty) parent.deleteSync();
    } catch (e) {
      startupLog.add('could not move the old data folder: $e');
    }
  }

  /// Где лежали данные тестовых сборок (относительно папки данных системы).
  /// Нужны, пока у тестеров могут остаться такие папки.
  static List<List<String>> get _testBuildFolders => Platform.isWindows
      ? const [
          ['SRB2 Workshop', 'SRB2 Autonomi Launcher'],
          ['SRB2 Workshop', 'SRB2 Workshop Launcher'],
        ]
      : const [
          ['com.srb2.workshop_launcher'],
        ];

  /// Pointer репозитория из `pointer.txt` рядом с лаунчером (у AppImage — и
  /// внутри него): первая непустая строка не с `#`; `autonomi://` убирается.
  /// null — файла нет.
  static String? pointerFromFile() {
    for (final dir in {launcherDir, p.dirname(Platform.resolvedExecutable)}) {
      final v = pointerIn(dir);
      if (v != null) return v;
    }
    return null;
  }

  /// Pointer из `pointer.txt` в папке [dir]; null — файла нет или он пуст.
  static String? pointerIn(String dir) {
    final f = File(p.join(dir, pointerFile));
    if (!f.existsSync()) return null;
    try {
      for (final raw in f.readAsLinesSync()) {
        final line = raw.trim();
        if (line.isEmpty || line.startsWith('#')) continue;
        final v = line.replaceFirst(RegExp('^autonomi://', caseSensitive: false), '').split(RegExp(r'\s')).first;
        if (v.isNotEmpty) return v;
      }
    } catch (_) {}
    return null;
  }

  /// Папка для установки сборок игры (`user_data/builds` или `%APPDATA%/.../builds`).
  static Future<Directory> buildsDir() async {
    final support = (await getApplicationSupportDirectory()).path;
    final dir = Directory(p.join(support, 'builds'));
    await dir.create(recursive: true);
    return dir;
  }

  /// Папка для скачанных архивов наборов 3D-моделей (`user_data/models` или `%APPDATA%/.../models`).
  static Future<Directory> modelsDir() async {
    final support = (await getApplicationSupportDirectory()).path;
    final dir = Directory(p.join(support, 'models'));
    await dir.create(recursive: true);
    return dir;
  }
}

/// Папки path_provider в портативном режиме: данные и кэш — в [dir], прочее
/// (временная папка, «Документы», «Загрузки») — как у системы.
class PortablePathProvider extends PathProviderPlatform {
  final String dir;
  final PathProviderPlatform system;
  PortablePathProvider(this.dir, this.system);

  @override
  Future<String?> getApplicationSupportPath() async => dir;

  @override
  Future<String?> getApplicationCachePath() async {
    final cache = Directory(p.join(dir, 'cache'));
    await cache.create(recursive: true);
    return cache.path;
  }

  @override
  Future<String?> getTemporaryPath() => system.getTemporaryPath();

  @override
  Future<String?> getApplicationDocumentsPath() => system.getApplicationDocumentsPath();

  @override
  Future<String?> getDownloadsPath() => system.getDownloadsPath();
}

/// Настройки (SharedPreferences) в одном JSON-файле — в том же виде, что у
/// SharedPreferences на Windows и Linux (`shared_preferences.json`).
class PortablePreferencesStore extends InMemorySharedPreferencesStore {
  final File file;
  PortablePreferencesStore._(this.file, Map<String, Object> data) : super.withData(data);

  static Future<PortablePreferencesStore> open(String path) async {
    final file = File(path);
    final data = <String, Object>{};
    try {
      if (file.existsSync()) {
        final j = jsonDecode(await file.readAsString());
        if (j is Map) {
          for (final e in j.entries) {
            final v = e.value;
            if (v == null) continue;
            data['${e.key}'] = v is List ? v.map((x) => '$x').toList() : v as Object;
          }
        }
      }
    } catch (_) {}
    return PortablePreferencesStore._(file, data);
  }

  Future<bool> _writing = Future.value(true);

  /// Записи — по очереди (через временный файл).
  Future<bool> _save() => _writing = _writing.then((_) async {
        try {
          final all = await getAllWithPrefix('');
          final tmp = File('${file.path}.tmp');
          await tmp.writeAsString(jsonEncode(all));
          await tmp.rename(file.path);
          return true;
        } catch (_) {
          return false;
        }
      });

  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      await super.setValue(valueType, key, value) && await _save();

  @override
  Future<bool> remove(String key) async => await super.remove(key) && await _save();

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) async =>
      await super.clearWithParameters(parameters) && await _save();
}
