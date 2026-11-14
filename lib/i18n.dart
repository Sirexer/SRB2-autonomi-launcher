import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

/// Язык из папки lang.
class LanguageInfo {
  final String code;
  final String name;

  /// Флаг (код страны для assets/flags): поле `_flag` файла языка, иначе
  /// по коду языка.
  final String flag;
  const LanguageInfo(this.code, this.name, [this.flag = '']);

  static String flagFor(String code) => switch (code) {
        'en' => 'gb',
        'uk' || 'ua' => 'ua',
        'pt' => 'br',
        _ => code,
      };
}

/// Переводы интерфейса.
///
/// Файлы лежат в папке `lang` рядом с исполняемым файлом лаунчера
/// (`lang/ru.json`, `lang/de.json`...). Ключи — английские строки интерфейса,
/// значения — перевод; `{name}` — подстановки. Поле `_language` — название
/// языка в списке настроек, `_flag` — его флаг (код страны: ru, br, de...).
/// Английский встроен; непереведённая строка
/// показывается по-английски.
class I18n extends ChangeNotifier {
  I18n._();
  static final I18n instance = I18n._();

  static const english = LanguageInfo('en', 'English', 'gb');

  String code = 'en';
  Map<String, String> _strings = {};
  List<LanguageInfo> available = [english];

  /// Папка lang: рядом с exe (сборка, AppImage), иначе в текущей папке
  /// (запуск из исходников, тесты).
  static Directory get langDir {
    final candidates = [
      p.join(p.dirname(Platform.resolvedExecutable), 'lang'),
      p.join(Directory.current.path, 'lang'),
    ];
    for (final c in candidates) {
      if (Directory(c).existsSync()) return Directory(c);
    }
    return Directory(candidates.first);
  }

  /// Ищет языки в папке lang.
  Future<void> discover() async {
    final found = <LanguageInfo>[english];
    try {
      await for (final e in langDir.list()) {
        if (e is! File || p.extension(e.path).toLowerCase() != '.json') continue;
        final langCode = p.basenameWithoutExtension(e.path);
        if (langCode == 'en' || langCode.startsWith('_')) continue;
        try {
          final j = jsonDecode(await e.readAsString());
          final name = j is Map && j['_language'] is String ? j['_language'] as String : langCode;
          final flag = j is Map && j['_flag'] is String ? j['_flag'] as String : LanguageInfo.flagFor(langCode);
          found.add(LanguageInfo(langCode, name, flag.toLowerCase()));
        } catch (_) {
          // Битый файл — пропускаем.
        }
      }
    } catch (_) {}
    found.sort((a, b) => a.code == 'en' ? -1 : (b.code == 'en' ? 1 : a.name.compareTo(b.name)));
    available = found;
  }

  /// Загружает язык; при ошибке остаётся английский.
  Future<void> load(String langCode) async {
    var strings = <String, String>{};
    var loaded = 'en';
    if (langCode != 'en') {
      try {
        final j = jsonDecode(await File(p.join(langDir.path, '$langCode.json')).readAsString());
        if (j is Map) {
          strings = {
            for (final e in j.entries)
              if (e.value is String && !'${e.key}'.startsWith('_')) '${e.key}': e.value as String,
          };
          loaded = langCode;
        }
      } catch (_) {}
    }
    _strings = strings;
    code = loaded;
    notifyListeners();
  }

  String tr(String key, [Map<String, Object?>? args]) {
    var s = _strings[key];
    if (s == null || s.isEmpty) s = key;
    if (args != null) {
      args.forEach((k, v) => s = s!.replaceAll('{$k}', '$v'));
    }
    return s!;
  }

  /// Перерисовывает всё приложение после смены языка (строки берутся через
  /// [tr] при построении, поэтому достаточно пометить все элементы).
  static void rebuildAll(BuildContext context) {
    void mark(Element e) {
      e.markNeedsBuild();
      e.visitChildren(mark);
    }

    (context as Element).visitChildren(mark);
  }
}

/// Перевод строки интерфейса: `tr('Settings')`, `tr('Added {n} file(s)', {'n': 3})`.
String tr(String key, [Map<String, Object?>? args]) => I18n.instance.tr(key, args);
