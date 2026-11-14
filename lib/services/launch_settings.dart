import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/game.dart';
import '../models/launch_config.dart';
import '../utils/natural_compare.dart';
import 'platform_utils.dart';

/// Найденный при сканировании папки исполняемый файл.
class FoundExecutable {
  final String path;
  final String name;

  /// Похоже на сборку игры (в имени есть "srb2", "ringracers"...) — отмечается сразу.
  final bool likelySrb2;

  const FoundExecutable(this.path, this.name, this.likelySrb2);
}

/// Настройки вкладки Launch: экзешники, галочки, доп. параметры.
/// Хранятся в SharedPreferences, общие для всех экзешников одной игры;
/// у каждой игры — свои (ключи с префиксом игры).
class LaunchSettings extends ChangeNotifier {
  final GameDef game;

  LaunchSettings([this.game = Games.srb2]);

  String get _kExecutables => game.key('launch_executables');
  String get _kDefault => game.key('launch_default_executable');
  String get _kOptions => game.key('launch_options');
  String get _kExtra => game.key('launch_extra_params');
  String get _kPresets => game.key('launch_extra_presets');
  static const _kLegacyCommand = 'srb2_launch_command';

  final List<LaunchExecutable> executables = [];
  final List<LaunchProfile> profiles = [];

  /// Имя последнего выбранного/сохранённого профиля.
  String? currentProfile;
  LaunchOptions options = LaunchOptions();
  String extraParams = '';
  String? defaultId;
  String? _selectedId;
  bool loaded = false;

  LaunchExecutable? byId(String? id) {
    for (final e in executables) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// Выбранный перед запуском экзешник (по умолчанию — отмеченный звёздочкой).
  LaunchExecutable? get selected =>
      byId(_selectedId) ?? byId(defaultId) ?? (executables.isEmpty ? null : executables.first);

  /// Сборка по умолчанию (звёздочка).
  LaunchExecutable? get defaultExecutable => byId(defaultId) ?? executables.firstOrNullValue;

  bool isDefault(LaunchExecutable e) => (byId(defaultId) ?? executables.firstOrNullValue)?.id == e.id;

  /// Команда выбранного экзешника; если список пуст — стандартная для ОС.
  String get command => selected?.command ?? PlatformUtils.defaultLaunchCommand(game: game);

  /// Полная командная строка без `-file`: программа, её аргументы,
  /// галочки и дополнительные параметры. [connectTo] — подключиться к серверу.
  /// [executableId] — запустить другой сборкой, а не выбранной. [skinColor] —
  /// родной цвет персонажа (для «Всегда родной цвет»).
  List<String> commandLine({String? connectTo, String? executableId, String skinColor = ''}) {
    var parts = PlatformUtils.splitCommandLine(byId(executableId)?.command ?? command);
    if (parts.isEmpty) parts = [PlatformUtils.defaultLaunchCommand(game: game)];
    final opts = connectTo == null ? options : options.forJoining(connectTo);
    return [...parts, ...opts.toArgs(game: game, skinColor: skinColor), ...PlatformUtils.splitCommandLine(extraParams)];
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();

    executables.clear();
    final raw = prefs.getString(_kExecutables);
    if (raw != null) {
      try {
        for (final j in jsonDecode(raw) as List) {
          final e = LaunchExecutable.fromJson(j);
          if (e != null) executables.add(e);
        }
      } catch (_) {}
      defaultId = prefs.getString(_kDefault);
    } else {
      // Переход со старой единственной "Launch command" из настроек (только SRB2).
      final legacy = game == Games.srb2 ? prefs.getString(_kLegacyCommand)?.trim() ?? '' : '';
      final cmd = legacy.isEmpty ? PlatformUtils.defaultLaunchCommand(game: game) : legacy;
      final isPath = cmd.contains('/') || cmd.contains(r'\');
      final exe = LaunchExecutable(
        id: LaunchExecutable.newId(),
        name: isPath ? LaunchExecutable.suggestName(cmd) : game.name,
        command: cmd,
      );
      executables.add(exe);
      defaultId = exe.id;
      await _saveExecutables();
    }
    _selectedId = defaultId;

    options = LaunchOptions.fromJson(_decode(prefs.getString(_kOptions)));
    extraParams = prefs.getString(_kExtra) ?? '';

    profiles.clear();
    final rawPresets = _decode(prefs.getString(_kPresets));
    if (rawPresets is List) {
      for (final j in rawPresets) {
        final preset = LaunchProfile.fromJson(j);
        if (preset != null) profiles.add(preset);
      }
    }

    loaded = true;
    notifyListeners();
  }

  static dynamic _decode(String? raw) {
    if (raw == null) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  // --- Экзешники ---

  void select(String? id) {
    _selectedId = id;
    notifyListeners();
  }

  void addExecutable(LaunchExecutable e, {bool select = true}) {
    executables.add(e);
    defaultId ??= e.id;
    if (select) _selectedId = e.id;
    notifyListeners();
    _saveExecutables();
  }

  void updateExecutable(LaunchExecutable e) {
    final i = executables.indexWhere((x) => x.id == e.id);
    if (i < 0) return;
    executables[i] = e;
    notifyListeners();
    _saveExecutables();
  }

  void removeExecutable(String id) {
    executables.removeWhere((e) => e.id == id);
    if (defaultId == id) defaultId = executables.isEmpty ? null : executables.first.id;
    if (_selectedId == id) _selectedId = defaultId;
    notifyListeners();
    _saveExecutables();
  }

  void setDefault(String id) {
    defaultId = id;
    notifyListeners();
    _saveExecutables();
  }

  /// Имя для нового экзешника: [preferred] или имя файла ("srb2win");
  /// если оно занято — с папкой ("srb2win (x32)"), затем с номером.
  String uniqueName(String command, {String? preferred, Iterable<String> alsoTaken = const []}) {
    final taken = {
      for (final e in executables) e.name.toLowerCase(),
      for (final t in alsoTaken) t.toLowerCase(),
    };
    bool free(String n) => !taken.contains(n.toLowerCase());

    final stem = preferred ?? LaunchExecutable.suggestName(command);
    if (free(stem)) return stem;
    final folder = LaunchExecutable.folderName(command);
    final withFolder = folder.isEmpty || stem.contains('($folder)') ? stem : '$stem ($folder)';
    if (free(withFolder)) return withFolder;
    for (var i = 2;; i++) {
      final numbered = '$withFolder $i';
      if (free(numbered)) return numbered;
    }
  }

  /// Уже есть экзешник с этим файлом?
  bool hasProgram(String path) =>
      executables.any((e) => PlatformUtils.samePath(e.program, path));

  Future<void> _saveExecutables() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kExecutables, jsonEncode(executables.map((e) => e.toJson()).toList()));
    if (defaultId == null) {
      await prefs.remove(_kDefault);
    } else {
      await prefs.setString(_kDefault, defaultId!);
    }
  }

  // --- Галочки и параметры ---

  void updateOptions(void Function(LaunchOptions o) change) {
    change(options);
    notifyListeners();
    SharedPreferences.getInstance()
        .then((prefs) => prefs.setString(_kOptions, jsonEncode(options.toJson())));
  }

  void setExtraParams(String value) {
    extraParams = value;
    notifyListeners();
    SharedPreferences.getInstance().then((prefs) => prefs.setString(_kExtra, value));
  }

  /// Сброс: галочки, консольные команды и доп. параметры — как по умолчанию
  /// (сборки и профили не трогаем).
  void resetOptions() {
    options = LaunchOptions();
    extraParams = '';
    currentProfile = null;
    notifyListeners();
    SharedPreferences.getInstance().then((prefs) async {
      await prefs.setString(_kOptions, jsonEncode(options.toJson()));
      await prefs.setString(_kExtra, '');
    });
  }

  int profileIndexOf(String name) => profiles.indexWhere((x) => x.name == name.trim());

  /// Сохраняет текущие галочки, доп. параметры и [queue] как профиль
  /// (профиль с тем же именем заменяется).
  void saveProfile(String name, List<String>? queue) {
    final profile = LaunchProfile(
      name: name.trim(),
      params: extraParams.trim(),
      options: options.toJson(),
      queue: queue == null ? null : List.of(queue),
    );
    if (profile.name.isEmpty) return;
    final i = profileIndexOf(profile.name);
    if (i >= 0) {
      profiles[i] = profile;
    } else {
      profiles.add(profile);
    }
    currentProfile = profile.name;
    notifyListeners();
    _savePresets();
  }

  /// Применяет профиль: галочки и доп. параметры; очередь возвращает
  /// вызывающему (она хранится на главном экране) или null.
  List<String>? applyProfile(LaunchProfile profile) {
    if (profile.options != null) {
      options = LaunchOptions.fromJson(profile.options);
      SharedPreferences.getInstance()
          .then((prefs) => prefs.setString(_kOptions, jsonEncode(options.toJson())));
    }
    setExtraParams(profile.params);
    currentProfile = profile.name;
    notifyListeners();
    return profile.queue;
  }

  void removeProfile(int index) {
    if (index < 0 || index >= profiles.length) return;
    if (profiles[index].name == currentProfile) currentProfile = null;
    profiles.removeAt(index);
    notifyListeners();
    _savePresets();
  }

  Future<void> _savePresets() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPresets, jsonEncode(profiles.map((x) => x.toJson()).toList()));
  }

  // --- Поиск сборок в папке ---

  /// Ищет исполняемые файлы в [root] и его подпапках первого уровня
  /// (`bin\x32\srb2win.exe`, `bin\TSoURDt3rd_x64\...`). Сам лаунчер пропускается.
  static Future<List<FoundExecutable>> findExecutables(String root,
      {List<String> hints = const ['srb2']}) async {
    final found = <String>[];
    final self = Platform.resolvedExecutable;

    Future<void> scan(Directory dir, int depth) async {
      try {
        await for (final e in dir.list(followLinks: false)) {
          if (e is File) {
            if (!PlatformUtils.samePath(e.path, self) && await _isExecutable(e)) found.add(e.path);
          } else if (e is Directory && depth > 0) {
            await scan(e, depth - 1);
          }
        }
      } catch (_) {
        // Нет доступа к папке — пропускаем.
      }
    }

    await scan(Directory(root), 1);
    found.sort(naturalCompare);

    // Имя = имя файла; если одинаковых несколько (srb2win в x32 и x64) —
    // "srb2win (x32)", "srb2win (x64)".
    final perStem = <String, int>{};
    for (final f in found) {
      perStem.update(p.basenameWithoutExtension(f).toLowerCase(), (n) => n + 1, ifAbsent: () => 1);
    }

    final result = <FoundExecutable>[];
    for (final f in found) {
      final stem = p.basenameWithoutExtension(f);
      final dir = p.dirname(f);
      final name = perStem[stem.toLowerCase()]! > 1 && !PlatformUtils.samePath(dir, root)
          ? '$stem (${p.basename(dir)})'
          : stem;
      final lower = stem.toLowerCase();
      result.add(FoundExecutable(f, name, hints.any((h) => lower.contains(h.toLowerCase()))));
    }
    return result;
  }

  static Future<bool> _isExecutable(File f) async {
    final ext = p.extension(f.path).toLowerCase();
    if (Platform.isWindows) return ext == '.exe';
    // Linux: файлы с флагом исполнения без расширения или AppImage (не .so и т.п.).
    if (ext.isNotEmpty && ext != '.appimage' && ext != '.x86_64') return false;
    try {
      final st = await f.stat();
      return (st.mode & 0x49) != 0; // любой из битов 0o111
    } catch (_) {
      return false;
    }
  }
}

extension on List<LaunchExecutable> {
  LaunchExecutable? get firstOrNullValue => isEmpty ? null : first;
}
