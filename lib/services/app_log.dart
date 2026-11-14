import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_activity.dart';

/// Журнал лаунчера для поиска зависаний: `logs/launcher.log` в папке данных
/// (прошлый запуск — `launcher.old.log`). Пишет запуск, смену активности
/// окна, открытие системных диалогов, ошибки и — главное — «сторожа»: раз
/// в 2 секунды Dart спрашивает основной поток окна (поток Windows, где
/// работают системные диалоги) и записывает, если тот перестал отвечать
/// и что было перед этим.
class AppLog {
  AppLog._();

  static File? _file;
  static String _last = 'start';
  static DateTime _lastAt = DateTime.now();

  /// Путь к журналу (для подсказок пользователю); null — не открыт.
  static String? get path => _file?.path;

  static Future<void> init() async {
    try {
      final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'logs'));
      await dir.create(recursive: true);
      final file = File(p.join(dir.path, 'launcher.log'));
      if (await file.exists()) await file.rename(p.join(dir.path, 'launcher.old.log'));
      _file = file;
      write('launcher started (${Platform.operatingSystem} ${Platform.operatingSystemVersion})');
      AppActivity.visible.addListener(() => write('window ${AppActivity.visible.value ? 'shown' : 'minimized'}'));
      AppActivity.focused.addListener(() => write('window ${AppActivity.focused.value ? 'focused' : 'unfocused'}'));
      _startWatchdog();
    } catch (_) {
      _file = null; // без журнала лаунчер работает как обычно
    }
  }

  /// Строка в журнал (сразу на диск: при зависании ничего не теряется).
  static void write(String message) {
    final file = _file;
    if (file == null) return;
    try {
      file.writeAsStringSync('${DateTime.now().toIso8601String()} $message\n', mode: FileMode.append);
    } catch (_) {}
  }

  /// Что лаунчер начал делать (открыть диалог и т.п.) — сторож назовёт это,
  /// если сразу после основной поток перестанет отвечать.
  static void action(String what) {
    _last = what;
    _lastAt = DateTime.now();
    write('> $what');
  }

  /// У собранного лаунчера на Windows консоли нет: запись в stdout/stderr
  /// там падает («Неверный дескриптор»).
  static final bool _hasConsole = !(Platform.isWindows && kReleaseMode);

  /// Сообщение для отладки: в консоль (если она есть) и, если [file], в журнал.
  static void console(String message, {bool file = true}) {
    if (_hasConsole) {
      try {
        stderr.writeln(message);
      } catch (_) {}
    }
    if (file) write(message);
  }

  static void error(Object e, [StackTrace? st]) {
    write('ERROR $e${st == null ? '' : '\n$st'}');
  }

  // Канал, у которого нет обработчика: ответ (ошибка «нет плагина») всё
  // равно проходит через основной поток окна — этого и достаточно.
  static const _ping = MethodChannel('robonomi/watchdog');
  static DateTime? _waitingSince;
  static bool _reported = false;

  static void _startWatchdog() {
    Timer.periodic(const Duration(seconds: 2), (_) async {
      final since = _waitingSince;
      if (since != null) {
        final stuck = DateTime.now().difference(since);
        if (stuck > const Duration(seconds: 4) && (!_reported || stuck.inSeconds % 30 < 2)) {
          _reported = true;
          write('WATCHDOG: the window thread does not answer for ${stuck.inSeconds} s; '
              'last action: "$_last" at ${_lastAt.toIso8601String()}');
        }
        return;
      }
      _waitingSince = DateTime.now();
      try {
        await _ping.invokeMethod<void>('ping');
      } on MissingPluginException {
        // ожидаемо: ответ пришёл
      } catch (_) {}
      if (_reported) {
        write('WATCHDOG: the window thread answers again after '
            '${DateTime.now().difference(_waitingSince!).inSeconds} s');
      }
      _reported = false;
      _waitingSince = null;
    });
  }

  /// Ошибки, которые иначе ушли бы только в консоль.
  static void catchErrors() {
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      error(details.exception, details.stack);
      previous?.call(details);
    };
    PlatformDispatcher.instance.onError = (e, st) {
      error(e, st);
      return false;
    };
  }
}
