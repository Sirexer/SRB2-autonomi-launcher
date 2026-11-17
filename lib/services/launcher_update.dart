import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../build_info.dart';
import '../i18n.dart';
import 'app_log.dart';

/// Файл релиза (zip для Windows, AppImage для Linux).
class ReleaseAsset {
  final String name;
  final String url;
  final int size;

  /// SHA-256 (hex), если GitHub его знает (поле `digest`).
  final String? sha256;

  const ReleaseAsset(this.name, this.url, this.size, this.sha256);
}

/// Релиз лаунчера на GitHub.
class LauncherRelease {
  final String tag;
  final String name;

  /// Список изменений (описание релиза, Markdown).
  final String changelog;
  final DateTime? published;
  final String pageUrl;
  final List<ReleaseAsset> assets;

  const LauncherRelease({
    required this.tag,
    required this.name,
    required this.changelog,
    required this.published,
    required this.pageUrl,
    required this.assets,
  });

  static LauncherRelease? fromJson(Object? j) {
    if (j is! Map || j['draft'] == true || j['tag_name'] is! String) return null;
    return LauncherRelease(
      tag: j['tag_name'] as String,
      name: (j['name'] is String && (j['name'] as String).trim().isNotEmpty) ? (j['name'] as String).trim() : j['tag_name'] as String,
      changelog: j['body'] is String ? (j['body'] as String).trim() : '',
      published: DateTime.tryParse('${j['published_at'] ?? ''}'),
      pageUrl: '${j['html_url'] ?? LauncherUpdate.releasesPage}',
      assets: [
        for (final a in (j['assets'] is List ? j['assets'] as List : const []))
          if (a is Map && a['name'] is String && a['browser_download_url'] is String)
            ReleaseAsset(
              a['name'] as String,
              a['browser_download_url'] as String,
              a['size'] is int ? a['size'] as int : 0,
              '${a['digest'] ?? ''}'.startsWith('sha256:') ? '${a['digest']}'.substring(7).toLowerCase() : null,
            ),
      ],
    );
  }

  /// Файл для этой системы: zip на Windows, AppImage на Linux; null — нет.
  ReleaseAsset? get assetForThisSystem {
    for (final a in assets) {
      final n = a.name.toLowerCase();
      if (Platform.isWindows && n.endsWith('.zip') && n.contains('windows')) return a;
      if (Platform.isLinux && n.endsWith('.appimage')) return a;
    }
    return null;
  }
}

/// Обновление самого лаунчера из релизов GitHub.
///
/// - Какая версия у нас — тег релиза, с которым собран лаунчер
///   (`--dart-define=BUILD_VERSION=beta-release2`). Сборки без него
///   сравниваются по времени сборки.
/// - Windows (папка из zip): архив распаковывается рядом, заменяемые файлы
///   переименовываются в `*.old` (работающий exe и его dll так можно), новые
///   встают на их место; `*.old` удаляются при следующем запуске. Свои файлы
///   пользователя (`user_data`, свой `pointer.txt`, свои языки) не трогаются.
/// - Linux: AppImage заменяется целиком (`$APPIMAGE`). Не из AppImage — только
///   страница релиза.
class LauncherUpdate {
  LauncherUpdate._();

  static const repository = 'Sirexer/SRB2-autonomi-launcher';
  static const releasesPage = 'https://github.com/$repository/releases';
  /// Список релизов (для проверки можно подменить: `--dart-define=UPDATE_API=...`).
  static const _api = String.fromEnvironment('UPDATE_API',
      defaultValue: 'https://api.github.com/repos/$repository/releases?per_page=20');

  /// Папка, куда распаковывается архив обновления (рядом с лаунчером).
  static const _stagingName = '.update';
  static const _oldSuffix = '.old';

  /// Список `*.old`, оставшихся от обновления (удаляются при запуске):
  /// чужие файлы с таким окончанием не трогаем.
  static const _oldListName = '.update_old.txt';

  /// Файлы, которые пользователь мог поменять: остаются как есть.
  static const _keepIfPresent = {'pointer.txt'};

  /// Релизы, новые сверху (без черновиков).
  static Future<List<LauncherRelease>> releases() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..userAgent = 'SRB2-Autonomi-Launcher';
    try {
      final req = await client.getUrl(Uri.parse(_api)).timeout(const Duration(seconds: 15));
      req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final resp = await req.close().timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) throw HttpException('HTTP ${resp.statusCode}');
      final text = await resp.transform(utf8.decoder).join().timeout(const Duration(seconds: 20));
      final list = [
        for (final j in jsonDecode(text) as List)
          ?LauncherRelease.fromJson(j),
      ];
      list.sort((a, b) => (b.published ?? DateTime(0)).compareTo(a.published ?? DateTime(0)));
      return list;
    } finally {
      client.close(force: true);
    }
  }

  /// Время сборки из [BuildInfo.date] («2026-11-12 05:55 UTC»).
  static DateTime? get buildTime {
    final d = BuildInfo.date.trim();
    if (d.isEmpty) return null;
    return DateTime.tryParse('${d.replaceAll(' UTC', '').replaceFirst(' ', 'T')}Z');
  }

  /// Последний релиз, если он новее этой сборки; null — обновлений нет.
  /// Локальная сборка (без даты и версии) обновлений не ищет, если не [anyBuild].
  static LauncherRelease? newerOf(List<LauncherRelease> list, {bool anyBuild = false}) =>
      newerFor(list, version: BuildInfo.version, built: buildTime, anyBuild: anyBuild);

  /// То же для сборки с версией [version] и временем [built].
  static LauncherRelease? newerFor(List<LauncherRelease> list,
      {required String version, required DateTime? built, bool anyBuild = false}) {
    if (list.isEmpty) return null;
    final latest = list.first;
    final own = version.trim();
    if (own.isNotEmpty) {
      if (latest.tag == own) return null;
      final mine = list.where((r) => r.tag == own).firstOrNull;
      if (mine != null) {
        final a = latest.published, b = mine.published;
        return a != null && b != null && !a.isAfter(b) ? null : latest;
      }
      // Нашего тега нет среди релизов (удалён) — по времени сборки.
    }
    if (built == null) return anyBuild ? latest : null;
    // Релиз публикуется после сборки своих файлов: запас, чтобы сборка
    // самого этого релиза не считала его новее себя.
    final published = latest.published;
    if (published == null) return null;
    return published.isAfter(built.add(const Duration(hours: 3))) ? latest : null;
  }

  /// Можно ли установить обновление само; иначе причина (тогда — страница релиза).
  static String? cannotInstallReason(LauncherRelease r) {
    if (r.assetForThisSystem == null) return tr('the release has no file for this system');
    if (Platform.isLinux && _appImage == null) return tr('the launcher is not started from an AppImage');
    if (!Platform.isWindows && !Platform.isLinux) return tr('this system is not supported');
    final dir = Platform.isWindows ? _appDir : p.dirname(_appImage!);
    try {
      final probe = File(p.join(dir, '.write_test_$pid'));
      probe.writeAsStringSync('');
      probe.deleteSync();
    } catch (_) {
      return tr('no permission to write to {folder}', {'folder': dir});
    }
    return null;
  }

  static String get _appDir => p.dirname(Platform.resolvedExecutable);
  static String? get _appImage {
    final a = Platform.environment['APPIMAGE'];
    return a != null && a.isNotEmpty && File(a).existsSync() ? a : null;
  }

  /// Скачивает файл релиза и проверяет размер и SHA-256. Путь к файлу.
  static Future<String> download(ReleaseAsset asset, {void Function(int got, int total)? onProgress}) async {
    // AppImage — сразу рядом с собой (замена — переименованием в той же папке).
    final String target;
    if (Platform.isLinux) {
      target = '${_appImage!}.new';
    } else {
      final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'update'));
      await dir.create(recursive: true);
      target = p.join(dir.path, asset.name);
    }
    final part = File('$target.part');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = 'SRB2-Autonomi-Launcher';
    try {
      final req = await client.getUrl(Uri.parse(asset.url));
      final resp = await req.close();
      if (resp.statusCode != 200) throw HttpException('HTTP ${resp.statusCode}');
      final total = resp.contentLength > 0 ? resp.contentLength : asset.size;
      final sink = part.openWrite();
      var got = 0;
      try {
        await for (final chunk in resp.timeout(const Duration(seconds: 60))) {
          sink.add(chunk);
          got += chunk.length;
          onProgress?.call(got, total);
        }
      } finally {
        await sink.close();
      }
      if (asset.size > 0 && got != asset.size) throw const FormatException('Size mismatch');
      if (asset.sha256 != null) {
        final digest = await sha256.bind(part.openRead()).first;
        if ('$digest' != asset.sha256) throw const FormatException('SHA-256 mismatch');
      }
      final f = File(target);
      if (await f.exists()) await f.delete();
      await part.rename(target);
      return target;
    } catch (_) {
      if (await part.exists()) await part.delete();
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  /// Ставит скачанное обновление [file] на место текущей версии.
  static Future<void> install(String file) async {
    if (Platform.isLinux) {
      final appImage = _appImage!;
      await Process.run('chmod', ['755', file]);
      // Linux позволяет заменить работающий файл: старый живёт, пока открыт.
      await File(file).rename(appImage);
      AppLog.console('[update] AppImage replaced: $appImage');
      return;
    }
    await _installWindows(file);
  }

  static Future<void> _installWindows(String zip) async {
    final appDir = _appDir;
    final staging = Directory(p.join(appDir, _stagingName));
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create();
    // Expand-Archive есть в любой Windows 10/11; на всякий случай — tar.
    var r = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      "Expand-Archive -LiteralPath '${zip.replaceAll("'", "''")}' -DestinationPath '${staging.path.replaceAll("'", "''")}' -Force",
    ]);
    if (r.exitCode != 0) r = await Process.run('tar', ['-xf', zip, '-C', staging.path]);
    if (r.exitCode != 0) throw ProcessException('Expand-Archive', [zip], '${r.stderr}', r.exitCode);

    // Корень архива — папка с exe (на случай, если всё лежит в подпапке).
    final exeName = p.basename(Platform.resolvedExecutable);
    var root = staging.path;
    if (!File(p.join(root, exeName)).existsSync()) {
      final inner = staging.listSync().whereType<Directory>().where((d) => File(p.join(d.path, exeName)).existsSync());
      if (inner.isEmpty) throw FormatException('$exeName is not in the update');
      root = inner.first.path;
    }

    final List<(String, String?)> moved;
    try {
      moved = await replaceFiles(root, appDir);
    } finally {
      try {
        await staging.delete(recursive: true);
      } catch (_) {}
    }
    try {
      await File(zip).delete();
    } catch (_) {}
    await rememberOld(appDir, moved);
    AppLog.console('[update] ${moved.length} file(s) replaced in $appDir');
  }

  /// Ставит файлы из [root] в [appDir]: старые — в `*.old`, свой
  /// `pointer.txt` остаётся. Ошибка — всё возвращается как было.
  /// (новый файл, его старая копия или null).
  static Future<List<(String, String?)>> replaceFiles(String root, String appDir) async {
    final moved = <(String target, String? old)>[];
    try {
      for (final e in Directory(root).listSync(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        final rel = p.relative(e.path, from: root);
        final target = p.join(appDir, rel);
        if (_keepIfPresent.contains(rel.toLowerCase()) && File(target).existsSync()) continue;
        await Directory(p.dirname(target)).create(recursive: true);
        String? old;
        if (File(target).existsSync()) {
          old = await _freeOldName(target);
          await File(target).rename(old);
        }
        await e.rename(target);
        moved.add((target, old));
      }
    } catch (e) {
      // Вернуть как было.
      for (final (target, old) in moved.reversed) {
        try {
          if (File(target).existsSync()) await File(target).delete();
          if (old != null) await File(old).rename(target);
        } catch (_) {}
      }
      rethrow;
    }
    return moved;
  }

  /// `<файл>.old`; если прошлый `.old` ещё занят — `<файл>.old2`...
  static Future<String> _freeOldName(String target) async {
    for (var i = 1;; i++) {
      final name = '$target$_oldSuffix${i == 1 ? '' : i}';
      final f = File(name);
      if (!f.existsSync()) return name;
      try {
        await f.delete();
        return name;
      } catch (_) {
        // Ещё загружен (не перезапускались) — следующее имя.
      }
    }
  }

  /// Запускает новую версию и закрывает эту.
  static Future<Never> restart() async {
    final exe = Platform.isLinux && _appImage != null ? _appImage! : Platform.resolvedExecutable;
    // Без переменных старого AppImage (его библиотеки и точка монтирования).
    final env = Map<String, String>.from(Platform.environment);
    if (env.containsKey('LAUNCHER_ORIG_LD_LIBRARY_PATH')) {
      final orig = env.remove('LAUNCHER_ORIG_LD_LIBRARY_PATH') ?? '';
      orig.isEmpty ? env.remove('LD_LIBRARY_PATH') : env['LD_LIBRARY_PATH'] = orig;
      for (final k in ['APPDIR', 'APPIMAGE', 'ARGV0', 'OWD']) {
        env.remove(k);
      }
    }
    // --new-instance: старое окно ещё закрывается, проверка «один лаунчер» не мешает.
    await Process.start(exe, ['--new-instance'],
        mode: ProcessStartMode.detached,
        workingDirectory: p.dirname(exe),
        environment: env,
        includeParentEnvironment: false);
    exit(0);
  }

  /// При запуске: убрать остатки прошлого обновления (`*.old`, распаковку).
  static Future<void> cleanup() async {
    try {
      if (Platform.isWindows) {
        await cleanupIn(_appDir);
      } else if (_appImage case final a?) {
        for (final f in [File('$a.new'), File('$a.new.part')]) {
          if (f.existsSync()) await f.delete();
        }
      }
    } catch (e) {
      AppLog.console('[update] cleanup: $e');
    }
  }

  /// Удаляет `*.old` из списка прошлого обновления в [appDir] (занятые —
  /// в следующий раз) и распаковку.
  static Future<void> cleanupIn(String appDir) async {
    final staging = Directory(p.join(appDir, _stagingName));
    if (staging.existsSync()) await staging.delete(recursive: true);
    final list = File(p.join(appDir, _oldListName));
    if (!list.existsSync()) return;
    final left = <String>[];
    for (final rel in await list.readAsLines()) {
      if (rel.trim().isEmpty || p.isAbsolute(rel) || p.split(rel).contains('..')) continue;
      final f = File(p.join(appDir, rel));
      try {
        if (f.existsSync()) await f.delete();
      } catch (_) {
        left.add(rel); // ещё занят
      }
    }
    left.isEmpty ? await list.delete() : await list.writeAsString(left.join('\n'));
  }

  /// Записывает, какие `*.old` убрать при следующем запуске.
  static Future<void> rememberOld(String appDir, List<(String, String?)> moved) => File(p.join(appDir, _oldListName))
      .writeAsString('${[for (final (_, old) in moved) if (old != null) p.relative(old, from: appDir)].join('\n')}\n',
          mode: FileMode.append);
}
