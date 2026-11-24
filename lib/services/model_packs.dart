import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/game.dart';
import 'map_preview.dart' show AddonArchive, ArchiveEntry;

/// Строка списка моделей: `имя путь масштаб смещение`. Числа — как в
/// файле (чтобы не менять 3.0 на 3).
class ModelLine {
  final String name, path, scale, offset;
  const ModelLine(this.name, this.path, this.scale, this.offset);

  /// Имя для сравнения: игра не различает регистр.
  String get key => name.toUpperCase();

  String get text => '$name $path $scale $offset';
}

/// Прочитанный список моделей и где игра перестала бы его читать.
class ModelDat {
  final List<ModelLine> lines;

  /// Номер строки файла (с 1), на которой игра остановилась бы, и почему
  /// (`name`, `path`, `number`, `end`); null — дочитан весь.
  final int? stopLine;
  final String? stopReason;

  const ModelDat(this.lines, {this.stopLine, this.stopReason});

  /// Как `while (fscanf(f, "%Ns %31s %f %f", ...) == 4)` в игре: значения
  /// через любые пробелы; первое неверное значение обрывает чтение.
  static ModelDat parse(String text, ModelFormat f) {
    final tokens = <(String, int)>[];
    var line = 1;
    final re = RegExp(r'\S+|\n');
    for (final m in re.allMatches(text)) {
      if (m[0] == '\n') {
        line++;
      } else {
        tokens.add((m[0]!, line));
      }
    }
    final lines = <ModelLine>[];
    for (var i = 0; i < tokens.length; i += 4) {
      final (name, at) = tokens[i];
      if (i + 3 >= tokens.length) return ModelDat(lines, stopLine: at, stopReason: 'end');
      final path = tokens[i + 1].$1, scale = tokens[i + 2].$1, offset = tokens[i + 3].$1;
      if (name.length > f.nameMax) return ModelDat(lines, stopLine: at, stopReason: 'name');
      if (path.length > ModelFormat.pathMax) return ModelDat(lines, stopLine: at, stopReason: 'path');
      if (!isNumber(scale) || !isNumber(offset)) return ModelDat(lines, stopLine: at, stopReason: 'number');
      lines.add(ModelLine(name, path, scale, offset));
    }
    return ModelDat(lines);
  }

  /// Число целиком, как его прочтёт `%f` (иначе остаток сломает разбор).
  static bool isNumber(String s) => RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$').hasMatch(s);

  /// Текст списка: строка на модель, без комментариев и пустых строк.
  static String write(Iterable<ModelLine> lines) => lines.map((l) => '${l.text}\r\n').join();
}

/// Модель в наборе: строка списка и какие файлы для неё есть.
class PackModel {
  final ModelLine line;
  final bool hasModel, hasTexture, hasBlend;

  const PackModel(this.line, {this.hasModel = true, this.hasTexture = true, this.hasBlend = false});

  String get key => line.key;

  Map<String, Object?> toJson() => {
        'line': [line.name, line.path, line.scale, line.offset],
        if (!hasModel) 'no_model': true,
        if (!hasTexture) 'no_texture': true,
        if (hasBlend) 'blend': true,
      };

  static PackModel fromJson(Map<String, Object?> j) {
    final l = (j['line'] as List).cast<String>();
    return PackModel(ModelLine(l[0], l[1], l[2], l[3]),
        hasModel: j['no_model'] != true, hasTexture: j['no_texture'] != true, hasBlend: j['blend'] == true);
  }
}

/// Набор моделей в библиотеке лаунчера: `pack.json` и файлы в `files/`
/// (пути — как в строках списка).
class ModelPack {
  final String id;
  String name;
  final String dir;
  final List<PackModel> models;
  final int bytes;
  final DateTime added;

  /// Что было не так при добавлении (строки после обрыва и т.п.).
  final List<String> notes;

  ModelPack({
    required this.id,
    required this.name,
    required this.dir,
    required this.models,
    required this.bytes,
    required this.added,
    this.notes = const [],
  });

  /// Файл набора по пути из списка.
  String file(String path) => p.joinAll([dir, 'files', ...path.split('/')]);

  /// Модель с этим именем (последняя строка — как в игре).
  PackModel? model(String key) => models.lastWhereOrNull((m) => m.key == key);

  Map<String, Object?> toJson() => {
        'name': name,
        'added': added.toIso8601String(),
        'bytes': bytes,
        'notes': notes,
        'models': [for (final m in models) m.toJson()],
      };

  static ModelPack fromJson(String id, String dir, Map<String, Object?> j) => ModelPack(
        id: id,
        name: j['name'] as String? ?? id,
        dir: dir,
        bytes: (j['bytes'] as num?)?.toInt() ?? 0,
        added: DateTime.tryParse(j['added'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
        notes: [for (final n in j['notes'] as List? ?? const []) '$n'],
        models: [
          for (final m in j['models'] as List? ?? const []) PackModel.fromJson((m as Map).cast<String, Object?>()),
        ],
      );
}

extension<T> on List<T> {
  T? lastWhereOrNull(bool Function(T) test) {
    for (var i = length - 1; i >= 0; i--) {
      if (test(this[i])) return this[i];
    }
    return null;
  }
}

/// Какая версия модели с именем [key] попадёт в общий пак.
class ModelChoice {
  final String key;

  /// Версии из включённых наборов — по порядку наборов.
  final List<(ModelPack, PackModel)> candidates;

  /// Выбранная; null — модель выключена (или её нет).
  final (ModelPack, PackModel)? chosen;

  /// Выбрана вручную, а не по порядку наборов.
  final bool manual;

  const ModelChoice(this.key, this.candidates, this.chosen, {this.manual = false});

  bool get conflict => candidates.length > 1;
}

/// Что не так с моделью в собранном паке.
enum ModelProblem {
  /// Нет файла модели — в пак не попадёт.
  missingModel,

  /// Имя длиннее, чем читает игра — в пак не попадёт.
  longName,

  /// Нет своей текстуры (PNG): игра натянет на модель спрайт объекта
  /// (hw_md2.c, adjustTextureCoords) — так часто и задумано.
  missingTexture,

  /// Префикс PLAYER, а игра его не знает (SRB2Kart): имя не совпадёт со
  /// скином.
  playerPrefix,

  /// MD3, а игра читает только MD2 (SRB2 Legacy) — в пак не попадёт.
  md3NotSupported,
}

class BuildFile {
  final String src;

  /// Путь в папке моделей (через `/`).
  final String dest;
  const BuildFile(this.src, this.dest);
}

/// Собранный пак: строки списка и файлы.
class ModelBuild {
  final List<ModelLine> lines;
  final List<BuildFile> files;
  final Map<String, List<ModelProblem>> problems;

  /// Наборы, из которых что-то взято (по порядку).
  final List<String> packNames;

  ModelBuild(this.lines, this.files, this.problems, this.packNames);

  late final int bytes = files.fold(0, (s, f) {
    try {
      return s + File(f.src).lengthSync();
    } catch (_) {
      return s;
    }
  });

  String get datText => ModelDat.write(lines);
}

/// Резервная копия моделей игры (что было до установки или отката).
class ModelBackup {
  final String dir;
  final DateTime date;
  final int models;

  /// Только список (после очистки), папка моделей не трогалась.
  final bool listOnly;
  const ModelBackup(this.dir, this.date, this.models, {this.listOnly = false});
}

/// Строка списка моделей игры и что с ней.
class GameModelLine {
  /// Номер строки файла (с 1).
  final int number;

  /// Как в файле.
  final String text;

  /// Разобранная строка; null — игра на ней остановится (комментарий, не
  /// числа, слишком длинное имя или путь).
  final ModelLine? line;

  /// Путь к файлу модели, как он лежит на диске; null — файла нет.
  final String? found;

  const GameModelLine(this.number, this.text, this.line, this.found);

  bool get broken => line == null;
  bool get missing => line != null && found == null;

  /// Файл есть, но регистр букв другой: на Windows сработает, на Linux — нет.
  bool get wrongCase => line != null && found != null && found != line!.path;
  bool get ok => line != null && found != null && !wrongCase;
}

/// Список моделей в игре построчно: что игра прочтёт и что с файлами.
class GameModels {
  final List<GameModelLine> lines;

  /// Где игра перестанет читать список (номер строки); null — дочитает.
  final int? stopLine;

  const GameModels(this.lines, this.stopLine);

  /// Строки, которые прочтёт игра (до первой сломанной); имя → строка.
  /// Как в игре, у одинаковых имён действует последняя.
  Map<String, GameModelLine> get active {
    final out = <String, GameModelLine>{};
    for (final l in lines) {
      if (l.broken) break;
      out[l.line!.key] = l;
    }
    return out;
  }

  int get broken => lines.where((l) => l.broken).length;
  int get missing => lines.where((l) => l.missing).length;
  int get wrongCase => lines.where((l) => l.wrongCase).length;

  /// Есть что почистить: сломанные строки, модели без файлов, регистр.
  bool get needsCleaning => broken + missing + wrongCase > 0;
}

/// Что сейчас стоит в игре.
class InstalledModels {
  /// Строк в списке игры; null — списка нет.
  final int? models;

  /// Поставил лаунчер: когда и из каких наборов; null — не он (или давно
  /// изменено руками).
  final DateTime? installed;
  final List<String> packs;

  const InstalledModels(this.models, this.installed, this.packs);
}

/// Наборы моделей игры: библиотека, порядок, выбор версий, сборка в один
/// пак, установка в игру с резервной копией и откат.
class ModelLibrary {
  final GameDef game;
  final ModelFormat format;
  final Directory root;

  /// Наборы по порядку: выше — главнее при одинаковых именах.
  final List<ModelPack> packs;
  final Set<String> disabled;

  /// Имя модели → id набора, чья версия выбрана вручную ('' — выключена).
  final Map<String, String> choice;

  ModelLibrary._(this.game, this.format, this.root, this.packs, this.disabled, this.choice);

  /// Сколько резервных копий хранить в папке игры.
  static const keepBackups = 5;

  /// Папка для тестов вместо папки данных лаунчера.
  static Directory? rootOverride;

  static Future<Directory> _rootFor(GameDef g) async {
    final base = rootOverride ?? Directory(p.join((await getApplicationSupportDirectory()).path, 'model_packs'));
    return Directory(p.join(base.path, g.id));
  }

  static Future<ModelLibrary> load(GameDef g) async {
    final format = g.models;
    if (format == null) throw UnsupportedError('${g.name}: 3D models are not supported');
    final root = await _rootFor(g);
    final packs = <ModelPack>[];
    final disabled = <String>{};
    final choice = <String, String>{};
    var order = <String>[];
    try {
      final setup = File(p.join(root.path, 'setup.json'));
      if (await setup.exists()) {
        final j = jsonDecode(await setup.readAsString()) as Map<String, Object?>;
        order = [for (final x in j['order'] as List? ?? const []) '$x'];
        disabled.addAll([for (final x in j['disabled'] as List? ?? const []) '$x']);
        choice.addAll({
          for (final e in (j['choice'] as Map? ?? const {}).entries) '${e.key}': '${e.value}',
        });
      }
    } catch (_) {}
    if (await root.exists()) {
      final found = <String, ModelPack>{};
      await for (final e in root.list()) {
        if (e is! Directory) continue;
        final meta = File(p.join(e.path, 'pack.json'));
        if (!await meta.exists()) continue;
        try {
          final id = p.basename(e.path);
          found[id] = ModelPack.fromJson(id, e.path, jsonDecode(await meta.readAsString()) as Map<String, Object?>);
        } catch (_) {}
      }
      for (final id in order) {
        if (found.remove(id) case final pack?) packs.add(pack);
      }
      packs.addAll(found.values.toList()..sort((a, b) => a.added.compareTo(b.added)));
    }
    return ModelLibrary._(g, format, root, packs, disabled, choice);
  }

  Future<void> save() async {
    await root.create(recursive: true);
    disabled.removeWhere((id) => !packs.any((x) => x.id == id));
    choice.removeWhere((_, id) => id.isNotEmpty && !packs.any((x) => x.id == id));
    await File(p.join(root.path, 'setup.json')).writeAsString(jsonEncode({
      'order': [for (final x in packs) x.id],
      'disabled': disabled.toList(),
      'choice': choice,
    }));
  }

  bool enabled(ModelPack pack) => !disabled.contains(pack.id);

  // --- Наборы ---

  /// Добавляет набор из архива (.zip/.pk3) или папки со списком моделей;
  /// он встаёт первым. FormatException — списка моделей нет.
  Future<ModelPack> add(String source, {String? name}) async {
    await root.create(recursive: true);
    final title = name ?? _titleOf(source);
    final id = '${_slug(title)}-${DateTime.now().millisecondsSinceEpoch}';
    final dir = p.join(root.path, id);
    final fmt = format;
    final j = await Isolate.run(() => _import(source, dir, title, fmt));
    final pack = ModelPack.fromJson(id, dir, j);
    packs.insert(0, pack);
    await save();
    return pack;
  }

  Future<void> remove(ModelPack pack) async {
    packs.removeWhere((x) => x.id == pack.id);
    try {
      await Directory(pack.dir).delete(recursive: true);
    } catch (_) {}
    await save();
  }

  Future<void> rename(ModelPack pack, String name) async {
    pack.name = name.trim().isEmpty ? pack.name : name.trim();
    await File(p.join(pack.dir, 'pack.json')).writeAsString(jsonEncode(pack.toJson()));
  }

  /// Попадёт ли модель в пак: есть файл, имя не длиннее, чем читает игра,
  /// формат игра понимает (SRB2 Legacy — только MD2).
  bool fits(PackModel m) =>
      m.hasModel && m.line.name.length <= format.nameMax && (format.md3 || !m.line.path.toLowerCase().endsWith('.md3'));

  /// Модели набора, которые не попадут в пак.
  int brokenIn(ModelPack pack) => pack.models.where((m) => !fits(m)).length;

  /// Убирает из набора модели, которые не попадут в пак; сколько убрано.
  Future<int> cleanPack(ModelPack pack) async {
    final before = pack.models.length;
    pack.models.removeWhere((m) => !fits(m));
    await File(p.join(pack.dir, 'pack.json')).writeAsString(jsonEncode(pack.toJson()));
    return before - pack.models.length;
  }

  static String _titleOf(String source) {
    final base = p.basename(source.endsWith(Platform.pathSeparator) ? p.dirname(source) : source);
    final dot = base.lastIndexOf('.');
    return dot > 0 && File(source).existsSync() ? base.substring(0, dot) : base;
  }

  static String _slug(String s) {
    final x = s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    return x.isEmpty ? 'pack' : (x.length > 24 ? x.substring(0, 24) : x);
  }

  /// В изоляте: читает набор из [source] и копирует нужные файлы в [dir].
  /// Возвращает содержимое `pack.json`.
  static Map<String, Object?> _import(String source, String dir, String name, ModelFormat f) {
    final src = _PackSource.open(source, f);
    try {
      final datText = latin1.decode(src.read(src.dat!), allowInvalid: true);
      final dat = ModelDat.parse(datText, f);
      final notes = <String>[];
      if (dat.stopLine != null) {
        notes.add('stopped:${dat.stopLine}:${dat.stopReason}');
      }
      // Файл → под каким написанием он ляжет в набор (первое встреченное).
      final spelled = <String, String>{};
      String spell(String path) => spelled.putIfAbsent(path.toLowerCase(), () => path);
      final copied = <String>{};
      var bytes = 0;
      bool copy(String path) {
        final dest = spell(path);
        if (copied.contains(dest.toLowerCase())) return true;
        final entry = src.find(path);
        if (entry == null) return false;
        final out = File(p.joinAll([dir, 'files', ...dest.split('/')]));
        out.parent.createSync(recursive: true);
        final data = src.read(entry);
        out.writeAsBytesSync(data);
        bytes += data.length;
        copied.add(dest.toLowerCase());
        return true;
      }

      final models = <PackModel>[];
      for (final l in dat.lines) {
        final path = spell(l.path.replaceAll('\\', '/'));
        final stem = _stem(path);
        final hasModel = copy(path);
        final hasTexture = copy('$stem.png') || copy('$stem.pcx');
        final hasBlend = copy('${stem}_blend.png');
        models.add(PackModel(ModelLine(l.name, path, l.scale, l.offset),
            hasModel: hasModel, hasTexture: hasTexture, hasBlend: hasBlend));
      }
      final unused = src.modelFiles.where((x) => !copied.contains(x.toLowerCase())).length;
      if (unused > 0) notes.add('unused:$unused');
      final meta = {
        'name': name,
        'added': DateTime.now().toIso8601String(),
        'bytes': bytes,
        'notes': notes,
        'models': [for (final m in models) m.toJson()],
      };
      File(p.join(dir, 'pack.json'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(jsonEncode(meta));
      return meta;
    } catch (_) {
      try {
        Directory(dir).deleteSync(recursive: true);
      } catch (_) {}
      rethrow;
    } finally {
      src.close();
    }
  }

  /// Путь без расширения (к нему добавляются `.png`, `_blend.png`).
  static String _stem(String path) {
    final slash = path.lastIndexOf('/');
    final dot = path.lastIndexOf('.');
    return dot > slash ? path.substring(0, dot) : path;
  }

  // --- Выбор версий ---

  /// Все имена моделей включённых наборов и какая версия выбрана.
  List<ModelChoice> choices() {
    final byKey = <String, List<(ModelPack, PackModel)>>{};
    for (final pack in packs) {
      if (!enabled(pack)) continue;
      final seen = <String>{};
      for (final m in pack.models.reversed) {
        // В наборе — последняя строка с именем (как в игре).
        if (!seen.add(m.key)) continue;
        (byKey[m.key] ??= []).add((pack, m));
      }
    }
    final keys = byKey.keys.toList()..sort();
    return [
      for (final k in keys)
        () {
          final list = byKey[k]!;
          final want = choice[k];
          if (want == '') return ModelChoice(k, list, null, manual: true);
          final manual = want == null ? null : list.where((c) => c.$1.id == want).firstOrNull;
          // По порядку наборов — первая версия, которая попадёт в пак (с файлом
          // и не слишком длинным именем); если таких нет — просто первая.
          final usable = list.where((c) => fits(c.$2)).firstOrNull;
          return ModelChoice(k, list, manual ?? usable ?? list.first, manual: manual != null);
        }(),
    ];
  }

  /// Версия из набора [packId] ('' — выключить, null — по порядку наборов).
  Future<void> choose(String key, String? packId) async {
    if (packId == null) {
      choice.remove(key);
    } else {
      choice[key] = packId;
    }
    await save();
  }

  // --- Сборка ---

  /// Общий пак из выбранных версий.
  ModelBuild build() => planBuild(format, choices(), packs);

  /// Пути в общем паке: как в наборе, а при совпадении с файлом другого
  /// набора — в папке набора (`P2/…`); слишком длинный путь — короче.
  /// Текстуры идут за моделью: `путь.png`, `путь_blend.png`.
  static ModelBuild planBuild(ModelFormat f, List<ModelChoice> choices, List<ModelPack> order) {
    final lines = <ModelLine>[];
    final files = <BuildFile>[];
    final problems = <String, List<ModelProblem>>{};
    final used = <String>{};
    // Путь в паке (нижний регистр) → откуда (файл модели).
    final taken = <String, String>{};
    // Модель набора → её путь в паке (одна модель на несколько имён).
    final placed = <String, String>{};
    String code(ModelPack pack) => 'P${order.indexWhere((x) => x.id == pack.id) + 1}';

    for (final c in choices) {
      final chosen = c.chosen;
      if (chosen == null) continue;
      final (pack, m) = chosen;
      final issues = <ModelProblem>[];
      if (m.line.name.length > f.nameMax) issues.add(ModelProblem.longName);
      if (!m.hasModel) issues.add(ModelProblem.missingModel);
      if (!m.hasTexture) issues.add(ModelProblem.missingTexture);
      if (!f.playerPrefix && m.key.startsWith('PLAYER') && m.key.length > 6) issues.add(ModelProblem.playerPrefix);
      if (!f.md3 && m.line.path.toLowerCase().endsWith('.md3')) issues.add(ModelProblem.md3NotSupported);
      if (issues.isNotEmpty) problems[c.key] = issues;
      if (issues.contains(ModelProblem.longName) ||
          issues.contains(ModelProblem.missingModel) ||
          issues.contains(ModelProblem.md3NotSupported)) {
        continue;
      }

      final src = pack.file(m.line.path);
      var dest = placed[src];
      if (dest == null) {
        final ext = p.extension(m.line.path);
        bool free(String d) {
          final owner = taken[d.toLowerCase()];
          return (owner == null || owner == src) && d.length <= ModelFormat.pathMax;
        }

        final pc = code(pack);
        final candidates = [
          m.line.path,
          '$pc/${m.line.path}',
          '$pc/${p.posix.basename(m.line.path)}',
        ];
        dest = candidates.where(free).firstOrNull;
        for (var n = 1; dest == null; n++) {
          final d = '$pc/M$n$ext';
          if (free(d)) dest = d;
        }
        taken[dest.toLowerCase()] = src;
        placed[src] = dest;
        final stem = _stem(m.line.path), destStem = _stem(dest);
        files.add(BuildFile(src, dest));
        for (final (from, to) in [
          ('$stem.png', '$destStem.png'),
          ('$stem.pcx', '$destStem.pcx'),
          ('${stem}_blend.png', '${destStem}_blend.png'),
        ]) {
          final file = pack.file(from);
          if (File(file).existsSync()) files.add(BuildFile(file, to));
        }
      }
      used.add(pack.name);
      lines.add(ModelLine(m.line.name, dest, m.line.scale, m.line.offset));
    }
    return ModelBuild(lines, files, problems, [for (final x in order) if (used.contains(x.name)) x.name]);
  }

  // --- Игра ---

  String _folderIn(String gameFolder) => p.join(gameFolder, format.folder);
  String _datIn(String gameFolder) => p.join(gameFolder, format.datFile);
  String _backupsIn(String gameFolder) => p.join(gameFolder, '${format.folder}.srb2al-backups');

  /// Метка в папке моделей: её поставил лаунчер.
  static const _mark = '.srb2al-models.json';

  /// Что сейчас стоит в игре.
  Future<InstalledModels> installed(String gameFolder) async {
    int? count;
    try {
      final dat = File(_datIn(gameFolder));
      if (await dat.exists()) count = ModelDat.parse(latin1.decode(await dat.readAsBytes()), format).lines.length;
    } catch (_) {}
    try {
      final mark = File(p.join(_folderIn(gameFolder), _mark));
      if (await mark.exists()) {
        final j = jsonDecode(await mark.readAsString()) as Map<String, Object?>;
        return InstalledModels(count, DateTime.tryParse('${j['date']}'), [for (final x in j['packs'] as List? ?? const []) '$x']);
      }
    } catch (_) {}
    return InstalledModels(count, null, const []);
  }

  /// Ставит [build] в игру: старые список и папка уходят в резервную копию.
  Future<void> install(String gameFolder, ModelBuild build) async {
    final folder = _folderIn(gameFolder), dat = _datIn(gameFolder), backups = _backupsIn(gameFolder);
    final datName = format.datFile;
    final mark = jsonEncode({'date': DateTime.now().toIso8601String(), 'packs': build.packNames});
    await Isolate.run(() => _install(folder, dat, backups, datName, build, mark));
  }

  static void _install(String folder, String dat, String backups, String datName, ModelBuild build, String mark) {
    final stage = Directory('$folder.srb2al-new');
    if (stage.existsSync()) stage.deleteSync(recursive: true);
    stage.createSync(recursive: true);
    try {
      for (final f in build.files) {
        final out = File(p.joinAll([stage.path, ...f.dest.split('/')]));
        out.parent.createSync(recursive: true);
        File(f.src).copySync(out.path);
      }
      File(p.join(stage.path, _mark)).writeAsStringSync(mark);
      File('${stage.path}.dat').writeAsStringSync(build.datText);
    } catch (_) {
      _deleteQuietly(stage);
      _deleteQuietly(File('${stage.path}.dat'));
      rethrow;
    }
    final backup = _backupCurrent(folder, dat, backups, datName);
    try {
      stage.renameSync(folder);
      File('${stage.path}.dat').renameSync(dat);
    } catch (_) {
      // Вернуть как было.
      if (Directory(folder).existsSync() && !stage.existsSync()) Directory(folder).renameSync(stage.path);
      if (backup != null) _restore(backup, folder, dat, datName);
      _deleteQuietly(stage);
      _deleteQuietly(File('${stage.path}.dat'));
      rethrow;
    }
    _prune(backups);
  }

  /// Переносит текущие список и папку в новую резервную копию; null —
  /// переносить нечего.
  static String? _backupCurrent(String folder, String dat, String backups, String datName, {bool withFolder = true}) {
    final hasFolder = withFolder && Directory(folder).existsSync(), hasDat = File(dat).existsSync();
    if (!hasFolder && !hasDat) return null;
    final now = DateTime.now();
    String two(int x) => x.toString().padLeft(2, '0');
    var name = '${now.year}-${two(now.month)}-${two(now.day)}_${two(now.hour)}-${two(now.minute)}-${two(now.second)}';
    var dir = p.join(backups, name);
    for (var i = 2; Directory(dir).existsSync(); i++) {
      dir = p.join(backups, '${name}_$i');
    }
    Directory(dir).createSync(recursive: true);
    try {
      if (hasFolder) Directory(folder).renameSync(p.join(dir, p.basename(folder)));
      if (hasDat) File(dat).renameSync(p.join(dir, datName));
    } catch (_) {
      _restore(dir, folder, dat, datName);
      rethrow;
    }
    return dir;
  }

  static void _restore(String backup, String folder, String dat, String datName) {
    final bFolder = Directory(p.join(backup, p.basename(folder))), bDat = File(p.join(backup, datName));
    if (bFolder.existsSync() && !Directory(folder).existsSync()) bFolder.renameSync(folder);
    if (bDat.existsSync() && !File(dat).existsSync()) bDat.renameSync(dat);
    if (!bFolder.existsSync() && !bDat.existsSync()) _deleteQuietly(Directory(backup));
  }

  static void _prune(String backups) {
    final list = _backupDirs(backups);
    for (final d in list.skip(keepBackups)) {
      _deleteQuietly(Directory(d));
    }
  }

  /// Резервные копии, новые первыми.
  static List<String> _backupDirs(String backups) {
    final dir = Directory(backups);
    if (!dir.existsSync()) return const [];
    return [for (final e in dir.listSync()) if (e is Directory) e.path]..sort((a, b) => b.compareTo(a));
  }

  static void _deleteQuietly(FileSystemEntity e) {
    try {
      if (e.existsSync()) e.deleteSync(recursive: true);
    } catch (_) {}
  }

  /// Резервные копии в папке игры, новые первыми.
  Future<List<ModelBackup>> backups(String gameFolder) async {
    final out = <ModelBackup>[];
    for (final d in _backupDirs(_backupsIn(gameFolder))) {
      var models = 0;
      try {
        final dat = File(p.join(d, format.datFile));
        if (await dat.exists()) models = ModelDat.parse(latin1.decode(await dat.readAsBytes()), format).lines.length;
      } catch (_) {}
      final listOnly = !await Directory(p.join(d, format.folder)).exists();
      out.add(ModelBackup(d, (await Directory(d).stat()).modified, models, listOnly: listOnly));
    }
    return out;
  }

  /// Возвращает [backup] в игру; то, что стояло, уходит в новую копию.
  Future<void> rollback(String gameFolder, ModelBackup backup) async {
    final folder = _folderIn(gameFolder), dat = _datIn(gameFolder), backups = _backupsIn(gameFolder);
    final datName = format.datFile;
    final listOnly = backup.listOnly;
    await Isolate.run(() {
      // Копия только списка — меняется только список, папка остаётся.
      final current = _backupCurrent(folder, dat, backups, datName, withFolder: !listOnly);
      try {
        _restore(backup.dir, folder, dat, datName);
      } catch (_) {
        if (current != null) _restore(current, folder, dat, datName);
        rethrow;
      }
      _prune(backups);
    });
  }

  Future<void> deleteBackup(ModelBackup backup) => Directory(backup.dir).delete(recursive: true);

  /// Сколько моделей в игре изменится после установки [planned]: новые,
  /// другие (путь, масштаб, смещение) и те, что из игры пропадут.
  static int pendingChanges(List<ModelLine> planned, GameModels? game) {
    final inGame = game?.active ?? const <String, GameModelLine>{};
    var n = 0;
    final keys = <String>{};
    for (final l in planned) {
      keys.add(l.key);
      final g = inGame[l.key]?.line;
      if (g == null ||
          g.path.toLowerCase() != l.path.toLowerCase() ||
          g.scale != l.scale ||
          g.offset != l.offset ||
          inGame[l.key]!.found == null) {
        n++;
      }
    }
    return n + inGame.keys.where((k) => !keys.contains(k)).length;
  }

  // --- Список моделей в игре ---

  /// Читает список моделей игры построчно и ищет файлы моделей; null —
  /// списка нет.
  Future<GameModels?> gameModels(String gameFolder) {
    final folder = _folderIn(gameFolder), dat = _datIn(gameFolder), f = format;
    return Isolate.run(() => _readGame(folder, dat, f));
  }

  static GameModels? _readGame(String folder, String dat, ModelFormat f) {
    final file = File(dat);
    if (!file.existsSync()) return null;
    final text = latin1.decode(file.readAsBytesSync(), allowInvalid: true);
    final onDisk = <String, String>{};
    final dir = Directory(folder);
    if (dir.existsSync()) {
      for (final e in dir.listSync(recursive: true).whereType<File>()) {
        final rel = p.relative(e.path, from: folder).replaceAll('\\', '/');
        onDisk.putIfAbsent(rel.toLowerCase(), () => rel);
      }
    }
    final lines = <GameModelLine>[];
    int? stop;
    final raw = text.split('\n');
    for (var i = 0; i < raw.length; i++) {
      final t = raw[i].trim();
      if (t.isEmpty) continue;
      final parts = t.split(RegExp(r'\s+'));
      final ok = parts.length == 4 &&
          parts[0].length <= f.nameMax &&
          parts[1].length <= ModelFormat.pathMax &&
          ModelDat.isNumber(parts[2]) &&
          ModelDat.isNumber(parts[3]);
      if (!ok) {
        stop ??= i + 1;
        lines.add(GameModelLine(i + 1, t, null, null));
        continue;
      }
      final line = ModelLine(parts[0], parts[1].replaceAll('\\', '/'), parts[2], parts[3]);
      lines.add(GameModelLine(i + 1, t, line, onDisk[line.path.toLowerCase()]));
    }
    return GameModels(lines, stop);
  }

  /// Чистит список моделей игры: убирает сломанные строки и модели без
  /// файлов, исправляет регистр путей. Старый список — в резервную копию
  /// (только список). Сколько строк убрано.
  Future<int> cleanGame(String gameFolder) async {
    final game = await gameModels(gameFolder);
    if (game == null || !game.needsCleaning) return 0;
    final kept = [
      for (final l in game.lines)
        if (l.line != null && l.found != null) ModelLine(l.line!.name, l.found!, l.line!.scale, l.line!.offset),
    ];
    final folder = _folderIn(gameFolder), dat = _datIn(gameFolder), backups = _backupsIn(gameFolder);
    final datName = format.datFile;
    final text = ModelDat.write(kept);
    await Isolate.run(() {
      final backup = _backupCurrent(folder, dat, backups, datName, withFolder: false);
      try {
        File(dat).writeAsStringSync(text);
      } catch (_) {
        if (backup != null) _restore(backup, folder, dat, datName);
        rethrow;
      }
      _prune(backups);
    });
    return game.lines.length - kept.length;
  }

  // --- Zip ---

  /// Сохраняет [build] в zip: список и папка моделей, как в папке игры.
  Future<void> saveZip(ModelBuild build, String path) async {
    final folder = format.folder, datName = format.datFile;
    await Isolate.run(() {
      final zip = ZipWriter(path);
      try {
        zip.add(datName, Uint8List.fromList(latin1.encode(build.datText)));
        for (final f in build.files) {
          zip.add('$folder/${f.dest}', File(f.src).readAsBytesSync(), compress: !f.dest.toLowerCase().endsWith('.png'));
        }
      } finally {
        zip.close();
      }
    });
  }
}

/// Откуда добавляется набор: папка или архив. Ищет список моделей (в корне
/// или на уровень глубже) и папку моделей рядом с ним.
class _PackSource {
  final String? _dir;
  final AddonArchive? _zip;

  /// Список моделей (путь в папке или запись архива).
  final Object? dat;

  /// Файлы папки моделей: путь от неё (через `/`, нижний регистр) → файл.
  final Map<String, Object> _files;

  _PackSource._(this._dir, this._zip, this.dat, this._files);

  Iterable<String> get modelFiles => _files.keys;

  static const _datNames = ['models.dat', 'mdls.dat', 'blanmodels.dat', 'md2.dat'];
  static const _folderNames = ['models', 'mdls', 'md2'];

  static _PackSource open(String source, ModelFormat f) {
    final datNames = {f.datFile.toLowerCase(), ..._datNames};
    final folderNames = {f.folder.toLowerCase(), ..._folderNames};
    if (Directory(source).existsSync()) {
      // Корень или папка на уровень глубже (архив распакован в свою папку).
      final roots = [Directory(source), ...Directory(source).listSync().whereType<Directory>()];
      for (final r in roots) {
        final entries = r.listSync();
        final dat = entries.whereType<File>().where((e) => datNames.contains(p.basename(e.path).toLowerCase())).firstOrNull;
        if (dat == null) continue;
        // Папка формата игры — первой: её файлы главнее.
        final folders = entries.whereType<Directory>().where((e) => folderNames.contains(p.basename(e.path).toLowerCase())).toList()
          ..sort((a, b) => (p.basename(a.path).toLowerCase() == f.folder.toLowerCase() ? 0 : 1)
              .compareTo(p.basename(b.path).toLowerCase() == f.folder.toLowerCase() ? 0 : 1));
        final files = <String, Object>{};
        // Нет папки моделей — пути списка от папки со списком (набор, который
        // распаковывают прямо в models/, а список переносят на уровень выше).
        for (final d in folders.isEmpty ? [r] : folders) {
          for (final e in d.listSync(recursive: true).whereType<File>()) {
            if (e.path == dat.path) continue;
            final rel = p.relative(e.path, from: d.path).replaceAll('\\', '/');
            files.putIfAbsent(rel.toLowerCase(), () => e.path);
          }
        }
        return _PackSource._(source, null, dat.path, files);
      }
      throw FormatException('no ${f.datFile}');
    }
    final zip = AddonArchive.open(source);
    if (zip == null || !zip.isZip) {
      zip?.close();
      throw const FormatException('not a zip archive');
    }
    ArchiveEntry? dat;
    for (final e in zip.entries) {
      final parts = e.path.split('/');
      if (parts.length > 2 || !datNames.contains(parts.last.toLowerCase())) continue;
      if (dat == null || parts.length < dat.path.split('/').length) dat = e;
    }
    if (dat == null) {
      zip.close();
      throw FormatException('no ${f.datFile}');
    }
    final prefix = dat.path.contains('/') ? '${dat.path.substring(0, dat.path.lastIndexOf('/'))}/' : '';
    final files = <String, Object>{};
    for (final e in zip.entries) {
      if (!e.path.startsWith(prefix)) continue;
      final rest = e.path.substring(prefix.length);
      final slash = rest.indexOf('/');
      if (slash < 0 || !folderNames.contains(rest.substring(0, slash).toLowerCase())) continue;
      files.putIfAbsent(rest.substring(slash + 1).toLowerCase(), () => e);
    }
    if (files.isEmpty) {
      // Папки моделей нет — пути от папки со списком (см. выше).
      for (final e in zip.entries) {
        if (e.path.startsWith(prefix) && e != dat) files.putIfAbsent(e.path.substring(prefix.length).toLowerCase(), () => e);
      }
    }
    return _PackSource._(null, zip, dat, files);
  }

  /// Файл папки моделей по пути из списка (без учёта регистра).
  Object? find(String path) => _files[path.replaceAll('\\', '/').toLowerCase()];

  Uint8List read(Object entry) =>
      entry is ArchiveEntry ? _zip!.read(entry) : File(entry as String).readAsBytesSync();

  void close() {
    _zip?.close();
    assert(_dir == null || _zip == null);
  }
}

/// Простая запись zip: файлы по одному, сжатие deflate (PNG — без сжатия,
/// они и так сжаты). Без zip64: пак моделей меньше 4 ГБ.
class ZipWriter {
  final RandomAccessFile _out;
  final _central = BytesBuilder();
  var _count = 0;

  ZipWriter(String path) : _out = File(path).openSync(mode: FileMode.write);

  void add(String name, Uint8List data, {bool compress = true}) {
    final nameBytes = utf8.encode(name);
    final crc = crc32(data);
    var body = data;
    var method = 0;
    if (compress && data.isNotEmpty) {
      final z = Uint8List.fromList(ZLibCodec(raw: true, level: 6).encode(data));
      if (z.length < data.length) {
        body = z;
        method = 8;
      }
    }
    final offset = _out.positionSync();
    final local = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 0x0800, Endian.little) // имена в UTF-8
      ..setUint16(8, method, Endian.little)
      ..setUint32(14, crc, Endian.little)
      ..setUint32(18, body.length, Endian.little)
      ..setUint32(22, data.length, Endian.little)
      ..setUint16(26, nameBytes.length, Endian.little);
    _out
      ..writeFromSync(local.buffer.asUint8List())
      ..writeFromSync(nameBytes)
      ..writeFromSync(body);
    final c = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 20, Endian.little)
      ..setUint16(8, 0x0800, Endian.little)
      ..setUint16(10, method, Endian.little)
      ..setUint32(16, crc, Endian.little)
      ..setUint32(20, body.length, Endian.little)
      ..setUint32(24, data.length, Endian.little)
      ..setUint16(28, nameBytes.length, Endian.little)
      ..setUint32(42, offset, Endian.little);
    _central
      ..add(c.buffer.asUint8List())
      ..add(nameBytes);
    _count++;
  }

  void close() {
    final cd = _central.takeBytes();
    final at = _out.positionSync();
    final end = ByteData(22)
      ..setUint32(0, 0x06054b50, Endian.little)
      ..setUint16(8, _count, Endian.little)
      ..setUint16(10, _count, Endian.little)
      ..setUint32(12, cd.length, Endian.little)
      ..setUint32(16, at, Endian.little);
    _out
      ..writeFromSync(cd)
      ..writeFromSync(end.buffer.asUint8List())
      ..closeSync();
  }

  static final _table = List<int>.generate(256, (n) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    return c;
  });

  static int crc32(List<int> data) {
    var c = 0xFFFFFFFF;
    for (final b in data) {
      c = _table[(c ^ b) & 0xFF] ^ (c >> 8);
    }
    return c ^ 0xFFFFFFFF;
  }
}
