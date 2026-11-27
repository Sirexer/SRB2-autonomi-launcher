import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/game.dart';

/// Привязка клавиш (`setcontrol`, `setcontrol2`, `setcontrol3`, `setcontrol4`) для одной команды.
class Srb2ControlBind {
  /// 1 для `setcontrol`, 2..4 для `setcontrol2`..`setcontrol4`.
  final int player;
  final String command;
  String primary;
  String secondary;

  /// Дополнительные клавиши (в Ring Racers бывает 3-я привязка).
  final List<String> extraKeys;

  Srb2ControlBind({
    required this.player,
    required this.command,
    required this.primary,
    this.secondary = '',
    List<String> extraKeys = const [],
  }) : extraKeys = List<String>.from(extraKeys);

  Srb2ControlBind copy() => Srb2ControlBind(
        player: player,
        command: command,
        primary: primary,
        secondary: secondary,
        extraKeys: extraKeys,
      );

  bool sameAs(Srb2ControlBind other) {
    if (player != other.player ||
        command.toLowerCase() != other.command.toLowerCase() ||
        primary != other.primary ||
        secondary != other.secondary ||
        extraKeys.length != other.extraKeys.length) {
      return false;
    }
    for (var i = 0; i < extraKeys.length; i++) {
      if (extraKeys[i] != other.extraKeys[i]) return false;
    }
    return true;
  }

  String toConfigLine() {
    final prefix = player >= 2 ? 'setcontrol$player' : 'setcontrol';
    final k1 = primary.trim().isEmpty ? 'KEY0' : primary.trim();
    final k2 = secondary.trim();
    final extras = [for (final k in extraKeys) if (k.trim().isNotEmpty && k.trim() != 'KEY0') k.trim()];
    if ((k2.isEmpty || k2 == 'KEY0') && extras.isEmpty) {
      return '$prefix "$command" "$k1"';
    }
    final buf = StringBuffer('$prefix "$command" "$k1" "${k2.isEmpty ? 'KEY0' : k2}"');
    for (final k in extras) {
      buf.write(' "$k"');
    }
    return buf.toString();
  }
}

enum _LineKind { raw, cvar, control }

class _ParsedLine {
  final _LineKind kind;
  final String raw;
  final String? key; // lowercased cvar name or '1:cmd'/'2:cmd'
  final String? origName;
  final int? player;
  final String? command;

  const _ParsedLine.raw(this.raw)
      : kind = _LineKind.raw,
        key = null,
        origName = null,
        player = null,
        command = null;

  const _ParsedLine.cvar(this.raw, this.key, this.origName)
      : kind = _LineKind.cvar,
        player = null,
        command = null;

  const _ParsedLine.control(this.raw, this.key, this.player, this.command)
      : kind = _LineKind.control,
        origName = null;
}

/// Документ конфига игры в формате Doom/SRB2 (`config.cfg`, `kartconfig.cfg` и т.д.).
///
/// Читает строки файла, сохраняет порядок, `//`-комментарии и неизвестные строки,
/// отслеживает несохранённые изменения и перед перезаписью создаёт резервную копию `.bak`.
class Srb2ConfigDocument {
  final String? filePath;
  final bool existsOnDisk;
  final String _lineEnding;
  final List<_ParsedLine> _lines;

  /// Исходное состояние на диске (или последнего сохранения).
  final Map<String, String> _initialCvars;
  final Map<String, String> _initialOrigNames;
  final Map<String, Srb2ControlBind> _initialControls;

  /// Текущее редактируемое состояние.
  final Map<String, String> _cvars;
  final Map<String, String> _origNames;
  final Map<String, Srb2ControlBind> _controls;
  final List<String> _controlOrder;

  Srb2ConfigDocument._({
    required this.filePath,
    required this.existsOnDisk,
    required this._lineEnding,
    required this._lines,
    required Map<String, String> initialCvars,
    required Map<String, String> initialOrigNames,
    required Map<String, Srb2ControlBind> initialControls,
    required this._controlOrder,
  })  : _initialCvars = initialCvars,
        _initialOrigNames = initialOrigNames,
        _initialControls = initialControls,
        _cvars = Map<String, String>.from(initialCvars),
        _origNames = Map<String, String>.from(initialOrigNames),
        _controls = {for (final e in initialControls.entries) e.key: e.value.copy()};

  /// Имя `.cfg`-файла конфига для указанной игры (из определения игры или основы).
  static String configFileNameFor(GameDef game) => game.configFileName;

  static String? configPathFor(GameDef game, String? gameFolder) {
    if (gameFolder == null || gameFolder.trim().isEmpty) return null;
    return p.join(gameFolder, configFileNameFor(game));
  }

  static Future<Srb2ConfigDocument> loadFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      return parse('', filePath: path, existsOnDisk: false);
    }
    final content = await file.readAsString();
    return parse(content, filePath: path, existsOnDisk: true);
  }

  static Srb2ConfigDocument loadFileSync(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      return parse('', filePath: path, existsOnDisk: false);
    }
    return parse(file.readAsStringSync(), filePath: path, existsOnDisk: true);
  }

  /// Разбирает текст `.cfg` в [Srb2ConfigDocument].
  static Srb2ConfigDocument parse(
    String content, {
    String? filePath,
    bool existsOnDisk = true,
  }) {
    final lineEnding = content.contains('\r\n') ? '\r\n' : '\n';
    final rawLines = content.isEmpty ? <String>[] : content.split(RegExp(r'\r?\n'));
    // Убираем финальный пустой элемент от завершающего перевода строки.
    if (rawLines.isNotEmpty && rawLines.last.isEmpty) {
      rawLines.removeLast();
    }

    final parsedLines = <_ParsedLine>[];
    final cvars = <String, String>{};
    final origNames = <String, String>{};
    final controls = <String, Srb2ControlBind>{};
    final controlOrder = <String>[];

    final cvarRe = RegExp(r'^\s*([A-Za-z0-9_]+)\s+"(.*)"\s*$');
    final controlRe = RegExp(r'^\s*setcontrol([234]?)\s+(.+?)\s*$', caseSensitive: false);

    for (final line in rawLines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('//')) {
        parsedLines.add(_ParsedLine.raw(line));
        continue;
      }

      final cm = controlRe.firstMatch(line);
      if (cm != null) {
        final suffix = cm.group(1) ?? '';
        final player = suffix.isEmpty ? 1 : (int.tryParse(suffix) ?? 1);
        final tokens = _parseQuotedTokens(cm.group(2)!);
        if (tokens.length >= 2) {
          final cmd = tokens[0];
          final k1 = tokens[1];
          final k2 = tokens.length >= 3 ? tokens[2] : '';
          final extras = tokens.length >= 4 ? tokens.sublist(3) : const <String>[];
          final key = '$player:${cmd.toLowerCase()}';
          final bind = Srb2ControlBind(
            player: player,
            command: cmd,
            primary: k1,
            secondary: k2,
            extraKeys: extras,
          );
          if (!controls.containsKey(key)) controlOrder.add(key);
          controls[key] = bind;
          parsedLines.add(_ParsedLine.control(line, key, player, cmd));
          continue;
        }
      }

      final vm = cvarRe.firstMatch(line);
      if (vm != null) {
        final name = vm.group(1)!;
        final value = vm.group(2)!;
        final key = name.toLowerCase();
        cvars[key] = value;
        origNames[key] = name;
        parsedLines.add(_ParsedLine.cvar(line, key, name));
        continue;
      }

      parsedLines.add(_ParsedLine.raw(line));
    }

    return Srb2ConfigDocument._(
      filePath: filePath,
      existsOnDisk: existsOnDisk,
      lineEnding: lineEnding,
      lines: parsedLines,
      initialCvars: cvars,
      initialOrigNames: origNames,
      initialControls: controls,
      controlOrder: controlOrder,
    );
  }

  static List<String> _parseQuotedTokens(String input) {
    final result = <String>[];
    final re = RegExp(r'"([^"]*)"');
    for (final m in re.allMatches(input)) {
      result.add(m.group(1)!);
    }
    return result;
  }

  /// Все переменные, которые сейчас есть в документе (ключи в оригинальном регистре).
  List<MapEntry<String, String>> get entries {
    final seen = <String>{};
    final out = <MapEntry<String, String>>[];
    for (final line in _lines) {
      if (line.kind == _LineKind.cvar && line.key != null) {
        final k = line.key!;
        if (_cvars.containsKey(k) && seen.add(k)) {
          out.add(MapEntry(_origNames[k] ?? line.origName ?? k, _cvars[k]!));
        }
      }
    }
    for (final k in _cvars.keys) {
      if (seen.add(k)) {
        out.add(MapEntry(_origNames[k] ?? k, _cvars[k]!));
      }
    }
    return out;
  }

  List<Srb2ControlBind> controlsForPlayer(int player) => [
        for (final key in _controlOrder)
          if (_controls[key]?.player == player) _controls[key]!,
      ];

  String? cvar(String name) => _cvars[name.toLowerCase()];

  bool hasCvar(String name) => _cvars.containsKey(name.toLowerCase());

  Srb2ControlBind? control(int player, String command) =>
      _controls['$player:${command.toLowerCase()}'];

  void setCvar(String name, String value) {
    final key = name.toLowerCase();
    final sanitized = value.replaceAll('\r', '').replaceAll('\n', '');
    _origNames.putIfAbsent(key, () => name);
    _cvars[key] = sanitized;
  }

  void setControl(int player, String command, {String? primary, String? secondary}) {
    final key = '$player:${command.toLowerCase()}';
    var bind = _controls[key];
    if (bind == null) {
      bind = Srb2ControlBind(
        player: player,
        command: command,
        primary: primary ?? 'KEY0',
        secondary: secondary ?? '',
      );
      _controls[key] = bind;
      _controlOrder.add(key);
      return;
    }
    if (primary != null) bind.primary = primary;
    if (secondary != null) bind.secondary = secondary;
  }

  bool isCvarDirty(String name) {
    final key = name.toLowerCase();
    return _cvars[key] != _initialCvars[key];
  }

  bool isControlDirty(int player, String command) {
    final key = '$player:${command.toLowerCase()}';
    final cur = _controls[key];
    final init = _initialControls[key];
    if (cur == null && init == null) return false;
    if (cur == null || init == null) return true;
    return !cur.sameAs(init);
  }

  int get changedCount {
    var count = 0;
    final allCvarKeys = {..._initialCvars.keys, ..._cvars.keys};
    for (final k in allCvarKeys) {
      if (_cvars[k] != _initialCvars[k]) count++;
    }
    final allControlKeys = {..._initialControls.keys, ..._controls.keys};
    for (final k in allControlKeys) {
      final a = _controls[k];
      final b = _initialControls[k];
      if (a == null || b == null || !a.sameAs(b)) count++;
    }
    return count;
  }

  bool get isDirty => changedCount > 0;

  /// Сбрасывает все несохранённые правки.
  void reset() {
    _cvars
      ..clear()
      ..addAll(_initialCvars);
    _origNames
      ..clear()
      ..addAll(_initialOrigNames);
    _controls
      ..clear()
      ..addAll({for (final e in _initialControls.entries) e.key: e.value.copy()});
    _controlOrder
      ..clear()
      ..addAll(_initialControls.keys);
  }

  /// Заменяет текущие значения из другого документа (например, из `.bak`), сохраняя
  /// несохранённый статус до явного Save.
  void applyFrom(Srb2ConfigDocument source) {
    for (final entry in source.entries) {
      setCvar(entry.key, entry.value);
    }
    for (final player in const [1, 2, 3, 4]) {
      for (final b in source.controlsForPlayer(player)) {
        setControl(player, b.command, primary: b.primary, secondary: b.secondary);
      }
    }
  }

  /// Собирает текст `.cfg` файла, сохраняя комментарии и порядок исходных строк.
  String serialize() {
    // Если одна переменная встречается в файле дважды — обновляем последнюю строку.
    final lastCvarLine = <String, int>{};
    final lastControlLine = <String, int>{};
    for (var i = 0; i < _lines.length; i++) {
      final line = _lines[i];
      if (line.kind == _LineKind.cvar && line.key != null) {
        lastCvarLine[line.key!] = i;
      } else if (line.kind == _LineKind.control && line.key != null) {
        lastControlLine[line.key!] = i;
      }
    }

    final out = <String>[];
    final writtenCvars = <String>{};
    final writtenControls = <String>{};

    for (var i = 0; i < _lines.length; i++) {
      final line = _lines[i];
      if (line.kind == _LineKind.cvar && line.key != null && lastCvarLine[line.key!] == i) {
        final k = line.key!;
        final val = _cvars[k];
        if (val != null) {
          writtenCvars.add(k);
          final name = line.origName ?? _origNames[k] ?? k;
          out.add('$name "$val"');
          continue;
        }
      } else if (line.kind == _LineKind.control && line.key != null && lastControlLine[line.key!] == i) {
        final k = line.key!;
        final bind = _controls[k];
        if (bind != null) {
          writtenControls.add(k);
          out.add(bind.toConfigLine());
          continue;
        }
      }
      out.add(line.raw);
    }

    for (final k in _cvars.keys) {
      if (!writtenCvars.contains(k)) {
        out.add('${_origNames[k] ?? k} "${_cvars[k]!}"');
      }
    }
    for (final k in _controlOrder) {
      if (!writtenControls.contains(k) && _controls[k] != null) {
        out.add(_controls[k]!.toConfigLine());
      }
    }

    if (out.isEmpty) return '';
    return '${out.join(_lineEnding)}$_lineEnding';
  }

  /// Путь к резервной копии (рядом с конфигом).
  String? get backupPath => filePath == null ? null : '$filePath.bak';

  /// Сохраняет изменения на диск; при наличии файла на диске предварительно
  /// записывает копию в `.bak`. Возвращает обновлённый документ.
  Future<Srb2ConfigDocument> save() async {
    final path = filePath;
    if (path == null) {
      throw StateError('No config file path specified');
    }
    final file = File(path);
    await file.parent.create(recursive: true);
    if (await file.exists()) {
      await file.copy('$path.bak');
    }
    final text = serialize();
    await file.writeAsString(text);
    return Srb2ConfigDocument.parse(text, filePath: path, existsOnDisk: true);
  }

  /// Синхронный вариант [save] для быстрого сохранения небольших `.cfg`-файлов.
  Srb2ConfigDocument saveSync() {
    final path = filePath;
    if (path == null) {
      throw StateError('No config file path specified');
    }
    final file = File(path);
    file.parent.createSync(recursive: true);
    if (file.existsSync()) {
      file.copySync('$path.bak');
    }
    final text = serialize();
    file.writeAsStringSync(text);
    return Srb2ConfigDocument.parse(text, filePath: path, existsOnDisk: true);
  }
}
