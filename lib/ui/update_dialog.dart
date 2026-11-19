import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../build_info.dart';
import '../i18n.dart';
import '../services/antd_daemon.dart';
import '../services/app_log.dart';
import '../services/launcher_update.dart';
import 'file_actions.dart' show cleanChildEnvironment;
import 'snack.dart';

/// Настройки обновлений лаунчера.
class UpdatePrefs {
  UpdatePrefs._();

  /// Проверять при запуске (по умолчанию да).
  static const checkKey = 'update_check';

  /// Пропущенная версия (тег): о ней при запуске больше не спрашиваем.
  static const skippedKey = 'update_skipped';
}

/// Версия этой сборки для показа: тег релиза, время сборки или «локальная».
String currentLauncherVersion() {
  if (BuildInfo.version.isNotEmpty) return BuildInfo.version;
  if (BuildInfo.date.isNotEmpty) return tr('build of {date}', {'date': BuildInfo.date});
  return tr('local build');
}

/// При запуске: есть новая версия (и её не пропустили) — окно обновления.
Future<void> checkLauncherUpdateOnStart(BuildContext context) async {
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(UpdatePrefs.checkKey) == false) return;
  final List<LauncherRelease> list;
  try {
    list = await LauncherUpdate.releases();
  } catch (e) {
    AppLog.console('[update] could not check: $e');
    return;
  }
  final newer = LauncherUpdate.newerOf(list);
  AppLog.console('[update] current ${currentLauncherVersion()}, latest ${list.firstOrNull?.tag ?? '-'}');
  if (newer == null || prefs.getString(UpdatePrefs.skippedKey) == newer.tag || !context.mounted) return;
  await showDialog<void>(context: context, barrierDismissible: false, builder: (_) => UpdateDialog(release: newer));
}

/// Кнопка «Проверить обновления»: окно с новой версией или сообщение, что
/// стоит последняя (пропущенная версия здесь показывается).
Future<void> checkLauncherUpdateNow(BuildContext context) async {
  final List<LauncherRelease> list;
  try {
    list = await LauncherUpdate.releases();
  } catch (e) {
    if (context.mounted) {
      showSnack(context,
          SnackBar(content: Text(tr('Could not check for updates: {error}', {'error': e})), backgroundColor: Colors.red));
    }
    return;
  }
  if (!context.mounted) return;
  final newer = LauncherUpdate.newerOf(list, anyBuild: true);
  if (newer == null) {
    showSnack(
        context,
        SnackBar(
            content: Text([
          tr('You have the latest version ({version}).', {'version': currentLauncherVersion()}),
          if (list.isNotEmpty) tr('Latest release: {version}.', {'version': list.first.name}),
        ].join(' '))));
    return;
  }
  await showDialog<void>(context: context, barrierDismissible: false, builder: (_) => UpdateDialog(release: newer));
}

/// Открывает ссылку в браузере.
Future<void> openUrl(String url) async {
  try {
    if (Platform.isWindows) {
      await Process.start('rundll32', ['url.dll,FileProtocolHandler', url], mode: ProcessStartMode.detached);
    } else {
      final env = cleanChildEnvironment();
      await Process.start(Platform.isMacOS ? 'open' : 'xdg-open', [url],
          mode: ProcessStartMode.detached, environment: env, includeParentEnvironment: env == null);
    }
  } catch (e) {
    AppLog.console('[update] could not open $url: $e');
  }
}

enum _Stage { ask, downloading, installing, failed }

/// Вышла новая версия: что нового и кнопки «Обновить сейчас», «Позже»,
/// «Пропустить это обновление».
class UpdateDialog extends StatefulWidget {
  final LauncherRelease release;
  const UpdateDialog({super.key, required this.release});

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  _Stage _stage = _Stage.ask;
  double? _progress;
  String _error = '';
  late final String? _cannot = LauncherUpdate.cannotInstallReason(widget.release);

  Future<void> _update() async {
    final asset = widget.release.assetForThisSystem!;
    setState(() {
      _stage = _Stage.downloading;
      _progress = null;
    });
    try {
      final file = await LauncherUpdate.download(asset, onProgress: (got, total) {
        if (mounted && total > 0) setState(() => _progress = got / total);
      });
      if (!mounted) return;
      setState(() => _stage = _Stage.installing);
      await AntdDaemon.shutdown(); // новая версия запустит свой
      await LauncherUpdate.install(file);
      AppLog.console('[update] installed ${widget.release.tag}, restarting');
      await LauncherUpdate.restart();
    } catch (e) {
      AppLog.console('[update] failed: $e');
      if (!mounted) return;
      setState(() {
        _stage = _Stage.failed;
        _error = '$e';
      });
      // Демон мог остановиться — запустить снова.
      AntdDaemon.ensureRunning();
    }
  }

  Future<void> _skip() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(UpdatePrefs.skippedKey, widget.release.tag);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.release;
    final busy = _stage == _Stage.downloading || _stage == _Stage.installing;
    return AlertDialog(
      icon: Icon(Icons.system_update_alt, size: 36, color: Theme.of(context).colorScheme.primary),
      title: Text(tr('Update available: {version}', {'version': r.name})),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              [
                tr('You have {version}.', {'version': currentLauncherVersion()}),
                if (r.published != null) tr('Released {date}.', {'date': _date(r.published!.toLocal())}),
              ].join(' '),
              style: const TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 12),
            Text(tr('What\'s new'), style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: r.changelog.isEmpty
                      ? Text(tr('No description.'), style: const TextStyle(color: Colors.grey))
                      : ChangelogText(r.changelog),
                ),
              ),
            ),
            const SizedBox(height: 12),
            ..._status(),
          ],
        ),
      ),
      actions: busy
          ? const []
          : [
              if (_stage == _Stage.ask) TextButton(onPressed: _skip, child: Text(tr('Skip this update'))),
              TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Later'))),
              if (_cannot != null || _stage == _Stage.failed)
                TextButton(onPressed: () => openUrl(r.pageUrl), child: Text(tr('Open the download page'))),
              if (_cannot == null)
                FilledButton(
                  onPressed: _update,
                  child: Text(_stage == _Stage.failed ? tr('Try again') : tr('Update now')),
                ),
            ],
    );
  }

  List<Widget> _status() {
    switch (_stage) {
      case _Stage.ask:
        return [
          Text(
            _cannot == null
                ? tr('The launcher downloads the new version, replaces itself and restarts. Your settings, addons and '
                    'a running game are not affected.')
                : tr('The launcher cannot update itself here ({reason}): download the new version from the release page.',
                    {'reason': _cannot}),
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ];
      case _Stage.downloading:
        return [
          Text(tr('Downloading the update...')),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: _progress),
        ];
      case _Stage.installing:
        return [
          Text(tr('Installing; the launcher will restart...')),
          const SizedBox(height: 6),
          const LinearProgressIndicator(),
        ];
      case _Stage.failed:
        return [
          Text(tr('The update failed: {error}', {'error': _error}), style: const TextStyle(color: Colors.redAccent)),
        ];
    }
  }

  static String _date(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// Описание релиза (Markdown GitHub) простым текстом: заголовки жирным,
/// списки с точками, ссылки — их текстом.
class ChangelogText extends StatelessWidget {
  final String markdown;
  const ChangelogText(this.markdown, {super.key});

  static String _inline(String s) => s
      .replaceAllMapped(RegExp(r'!?\[([^\]]*)\]\([^)]*\)'), (m) => m[1]!)
      .replaceAll(RegExp(r'\*\*|__|`'), '')
      .replaceAllMapped(RegExp(r'(^|\s)[*_]([^*_\s][^*_]*)[*_](?=\s|$)'), (m) => '${m[1]}${m[2]}');

  @override
  Widget build(BuildContext context) {
    final lines = markdown.replaceAll('\r\n', '\n').split('\n');
    final out = <Widget>[];
    for (final raw in lines) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) {
        out.add(const SizedBox(height: 6));
        continue;
      }
      final heading = RegExp(r'^\s*(#{1,6})\s+(.*)$').firstMatch(line);
      final bullet = RegExp(r'^(\s*)[-*+]\s+(.*)$').firstMatch(line);
      final numbered = RegExp(r'^(\s*)(\d+)[.)]\s+(.*)$').firstMatch(line);
      if (heading != null) {
        out.add(Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 2),
          child: Text(_inline(heading[2]!),
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: heading[1]!.length <= 2 ? 15 : 14)),
        ));
      } else if (bullet != null || numbered != null) {
        final indent = (bullet?[1] ?? numbered![1]!).length;
        final mark = bullet != null ? '•' : '${numbered![2]}.';
        final text = bullet?[2] ?? numbered![3]!;
        out.add(Padding(
          padding: EdgeInsets.only(left: 4.0 + indent * 6, bottom: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 18, child: Text(mark)),
              Expanded(child: SelectableText(_inline(text))),
            ],
          ),
        ));
      } else {
        out.add(Padding(padding: const EdgeInsets.only(bottom: 2), child: SelectableText(_inline(line))));
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: out);
  }
}
