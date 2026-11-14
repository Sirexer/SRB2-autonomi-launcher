import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/game.dart';

/// Платформенные хелперы (Linux / Windows).
///
/// Чистые функции принимают явный флаг [windows], чтобы их можно было
/// тестировать на любой ОС.
class PlatformUtils {
  PlatformUtils._();

  static p.Context _ctx(bool windows) => windows ? p.windows : p.posix;

  /// Команда запуска SRB2 по умолчанию.
  static String defaultLaunchCommand({bool? windows, GameDef game = Games.srb2}) =>
      game.defaultCommand(windows: windows);

  /// Имена исполняемых файлов SRB2, которые ищем в папке игры,
  /// если пользователь не менял команду запуска.
  static List<String> knownExecutables({bool? windows, GameDef game = Games.srb2}) =>
      game.knownExecutables(windows: windows);

  /// Расширения аддонов, которые понимает `-file`.
  static const addonExtensions = ['wad', 'pk3', 'lua', 'soc'];

  static bool isAddonFile(String path) {
    final ext = p.extension(path).toLowerCase();
    return ext.length > 1 && addonExtensions.contains(ext.substring(1));
  }

  /// Разбивает строку команды на программу и аргументы с учётом кавычек:
  /// `"C:\Program Files\SRB2\srb2win.exe" -opengl` →
  /// `[C:\Program Files\SRB2\srb2win.exe, -opengl]`.
  ///
  /// На Windows обратный слэш — обычный символ пути, кавычки только двойные.
  /// На Linux работают и одинарные кавычки, а `\` экранирует следующий символ.
  static List<String> splitCommandLine(String input, {bool? windows}) {
    final win = windows ?? Platform.isWindows;
    final args = <String>[];
    final buf = StringBuffer();
    var inToken = false;
    String? quote;

    for (var i = 0; i < input.length; i++) {
      final c = input[i];
      if (quote != null) {
        if (c == quote) {
          quote = null;
        } else if (!win &&
            quote == '"' &&
            c == r'\' &&
            i + 1 < input.length &&
            (input[i + 1] == '"' || input[i + 1] == r'\')) {
          buf.write(input[++i]);
        } else {
          buf.write(c);
        }
      } else if (c == '"' || (!win && c == "'")) {
        quote = c;
        inToken = true;
      } else if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
        if (inToken) {
          args.add(buf.toString());
          buf.clear();
          inToken = false;
        }
      } else if (!win && c == r'\' && i + 1 < input.length) {
        buf.write(input[++i]);
        inToken = true;
      } else {
        buf.write(c);
        inToken = true;
      }
    }
    if (inToken) args.add(buf.toString());
    return args;
  }

  static const _windowsReservedNames = {
    'CON', 'PRN', 'AUX', 'NUL', //
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
  };

  /// Превращает имя файла из манифеста (чужие данные!) в простое имя,
  /// допустимое и на Windows, и на Linux, которое не может выйти за пределы
  /// папки `DOWNLOAD` (`../../.bashrc`, `..\x.dll`, `a.pk3:stream`, `NUL.pk3`).
  /// Результат одинаков на всех ОС. null — если ничего пригодного не осталось.
  static String? safeFileName(String raw) {
    var name = raw.split(RegExp(r'[/\\]')).last;
    name = name.replaceAll(RegExp(r'[<>:"|?*\x00-\x1F]'), '_');
    // Windows молча отбрасывает точки и пробелы в конце имени.
    name = name.replaceAll(RegExp(r'[. ]+$'), '').trim();
    if (name.isEmpty || name == '.' || name == '..') return null;
    final stem = name.split('.').first.toUpperCase();
    if (_windowsReservedNames.contains(stem)) name = '_$name';
    return name;
  }

  /// Берёт путь в кавычки, если в нём есть пробелы (для поля команды запуска).
  static String quoteIfNeeded(String path) =>
      path.contains(RegExp(r'\s')) ? '"$path"' : path;

  /// Приводит введённый/вставленный путь к нормальному виду:
  /// убирает пробелы и кавычки по краям («Копировать как путь» в Проводнике),
  /// понимает `file://`-URI, раскрывает `~` на Linux, убирает лишние и
  /// замыкающие разделители. На Windows все `/` превращаются в `\`.
  static String cleanUserPath(String input, {bool? windows, String? home}) {
    final win = windows ?? Platform.isWindows;
    var s = input.trim();
    if (s.length >= 2 &&
        ((s.startsWith('"') && s.endsWith('"')) ||
            (s.startsWith("'") && s.endsWith("'")))) {
      s = s.substring(1, s.length - 1).trim();
    }
    if (s.isEmpty) return '';

    if (s.startsWith('file://')) {
      try {
        s = Uri.parse(s).toFilePath(windows: win);
      } catch (_) {}
    }

    if (!win && (s == '~' || s.startsWith('~/'))) {
      final h = home ?? Platform.environment['HOME'];
      if (h != null && h.isNotEmpty) s = h + s.substring(1);
    }

    return _ctx(win).normalize(s);
  }

  /// Одинаковые ли пути (на Windows — без учёта регистра и вида слэшей).
  static bool samePath(String a, String b, {bool? windows}) =>
      _ctx(windows ?? Platform.isWindows).equals(a, b);

  /// Папки, где обычно лежат данные SRB2 (там же создаётся `DOWNLOAD`).
  /// Используется только как подсказка, если папка ещё не задана.
  static List<String> gameFolderCandidates([GameDef game = Games.srb2]) {
    if (Platform.isWindows) return const [];
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return const [];
    // Вторая — обычно Flatpak.
    return [for (final rel in game.linuxDataFolders) p.joinAll([home, ...rel.split('/')])];
  }

  static Future<String?> detectGameFolder([GameDef game = Games.srb2]) async {
    for (final dir in gameFolderCandidates(game)) {
      if (await Directory(dir).exists()) return dir;
    }
    return null;
  }

  /// Имя бинарника antd в релизах ant-sdk для текущей платформы,
  /// или null, если готовой сборки нет.
  static String? antdAssetName([Abi? abi]) {
    final a = abi ?? Abi.current();
    if (a == Abi.linuxX64) return 'antd-linux-amd64';
    if (a == Abi.linuxArm64) return 'antd-linux-arm64';
    // Windows на ARM запускает x64-сборку через эмуляцию.
    if (a == Abi.windowsX64 || a == Abi.windowsArm64) {
      return 'antd-windows-amd64.exe';
    }
    if (a == Abi.macosArm64) return 'antd-darwin-arm64';
    return null;
  }
}
