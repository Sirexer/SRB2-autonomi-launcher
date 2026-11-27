import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'characters.dart';
import 'map_preview.dart';

/// Свой режим игры из SOC (`GameType ...`) или Lua (`G_AddGametype{...}`).
class GametypeInfo {
  /// Название — его игра сравнивает с `-gametype` (G_GetGametypeByName).
  final String name;

  /// Identifier — константа GT_... для Lua ('' — как название).
  final String identifier;
  final String description;

  /// TypeOfLevel режима (SOC `TypeOfLevel = Coop,Hangout`, Lua
  /// `typeoflevel = TOL_COOP|TOL_HANGOUT`): какие карты он берёт. Имена в
  /// верхнем регистре без TOL_; пусто — неизвестно.
  final List<String> levels;

  const GametypeInfo(this.name, this.identifier, this.description, [this.levels = const []]);
}

/// Категории аддонов, скачанных с серверов. Аддон попадает в первую
/// подходящую по этому порядку.
enum AddonCategory { characters, gametypes, maps, skincolors, misc }

/// Что внутри файла аддона.
class AddonContents {
  /// Персонажи: "realname (name)".
  final List<String> characterNames;
  final List<GametypeInfo> gametypes;

  /// Карты: "MAP01 Greenflower 1" (имя и название из SOC).
  final List<String> mapNames;

  /// Свои цвета персонажей (имя и ramp).
  final List<SkinColor> colors;

  const AddonContents(
      {this.characterNames = const [], this.gametypes = const [], this.mapNames = const [], this.colors = const []});

  Map<String, Object?> toJson() => {
        'c': characterNames,
        'g': [for (final g in gametypes) [g.name, g.identifier, g.description, g.levels]],
        'm': mapNames,
        'k': [for (final (name, ramp) in colors) [name, ramp]],
      };

  static AddonContents fromJson(Map<String, Object?> j) => AddonContents(
        characterNames: [for (final c in j['c'] as List? ?? const []) c as String],
        gametypes: [
          for (final g in (j['g'] as List? ?? const []).cast<List>())
            GametypeInfo(g[0] as String, g[1] as String, g[2] as String,
                g.length > 3 ? [for (final l in g[3] as List) l as String] : const []),
        ],
        mapNames: [for (final m in j['m'] as List? ?? const []) m as String],
        colors: [
          for (final k in (j['k'] as List? ?? const []).cast<List>())
            (k[0] as String, [for (final x in k[1] as List) x as int]),
        ],
      );

  int get characters => characterNames.length;
  int get maps => mapNames.length;
  int get skincolors => colors.length;

  /// Несколько файлов (версия аддона) — одним списком.
  static AddonContents merge(Iterable<AddonContents> all) => AddonContents(
        characterNames: [for (final c in all) ...c.characterNames],
        gametypes: [for (final c in all) ...c.gametypes],
        mapNames: [for (final c in all) ...c.mapNames],
        colors: [for (final c in all) ...c.colors],
      );

  /// Есть ли [query] (в нижнем регистре) среди карт, режимов, персонажей, цветов.
  bool matches(String query) =>
      characterNames.any((n) => n.toLowerCase().contains(query)) ||
      mapNames.any((n) => n.toLowerCase().contains(query)) ||
      gametypes.any((g) => g.name.toLowerCase().contains(query) || g.identifier.toLowerCase().contains(query)) ||
      colors.any((c) => c.$1.toLowerCase().contains(query));

  AddonCategory get category => characters > 0
      ? AddonCategory.characters
      : gametypes.isNotEmpty
          ? AddonCategory.gametypes
          : maps > 0
              ? AddonCategory.maps
              : skincolors > 0
                  ? AddonCategory.skincolors
                  : AddonCategory.misc;
}

class AddonAnalyzer {
  AddonAnalyzer._();

  static Future<Map<String, AddonContents>> _analyzeChunk(List<String> paths) =>
      Isolate.run(() => {for (final p in paths) p: analyzeSafe(p)});

  /// Разбор в фоне (несколько изолятов с паузами, чтобы интерфейс оставался
  /// плавным). Каждый файл — отдельно; [onBatch] получает пачки по мере
  /// готовности.
  static Future<Map<String, AddonContents>> analyzeAllInBackground(
    List<String> paths, {
    void Function(Map<String, AddonContents> batch)? onBatch,
  }) async {
    final out = <String, AddonContents>{};
    if (paths.isEmpty) return out;
    final workers = math.min(paths.length, math.max(1, math.min(Platform.numberOfProcessors ~/ 2, 3)));
    final chunkSize = paths.length <= 24 ? math.max(1, (paths.length / (workers * 2)).ceil()) : 10;
    final chunks = <List<String>>[
      for (var i = 0; i < paths.length; i += chunkSize) paths.sublist(i, math.min(i + chunkSize, paths.length)),
    ];
    final pool = math.min(workers, chunks.length);
    var nextChunk = 0;
    Future<void> worker() async {
      while (nextChunk < chunks.length) {
        final chunk = chunks[nextChunk++];
        Map<String, AddonContents> found;
        try {
          found = await _analyzeChunk(chunk);
        } catch (_) {
          found = {for (final p in chunk) p: analyzeSafe(p)};
        }
        if (found.isNotEmpty) {
          out.addAll(found);
          onBatch?.call(found);
        }
        if (nextChunk < chunks.length) {
          await Future<void>.delayed(const Duration(milliseconds: 8));
        }
      }
    }

    await Future.wait([for (var i = 0; i < pool; i++) worker()]);
    return out;
  }

  static AddonContents analyzeSafe(String path) {
    try {
      return analyze(path);
    } catch (_) {
      return const AddonContents();
    }
  }

  static AddonContents analyze(String path) {
    final a = AddonArchive.open(path);
    if (a == null) {
      // .lua / .soc отдельным файлом.
      try {
        final text = latin1.decode(File(path).readAsBytesSync(), allowInvalid: true);
        final lower = path.toLowerCase();
        final isLua = lower.endsWith('.lua');
        return AddonContents(
          gametypes: isLua ? parseLuaGametypes(text) : parseSocGametypes(text),
          colors: isLua ? CharacterScanner.parseLuaColors(text) : CharacterScanner.parseSocColors(text),
        );
      } catch (_) {
        return const AddonContents();
      }
    }
    try {
      final characters = <String>[];
      for (final e in a.entries) {
        if (e.name.length < 6 || !e.name.startsWith('S_SKIN')) continue;
        try {
          final f = CharacterScanner.parseSkin(latin1.decode(a.read(e), allowInvalid: true));
          final name = (f['name'] ?? '').toLowerCase();
          if (name.isEmpty) continue;
          characters.add('${(f['realname'] ?? name).replaceAll('_', ' ')} ($name)');
        } catch (_) {}
      }
      final titles = MapScanner.levelTitles(a);
      return AddonContents(
        characterNames: characters,
        gametypes: gametypesIn(a),
        mapNames: [
          for (final m in MapScanner.mapNames(a)) titles[m] == null ? m : '$m ${titles[m]}',
        ],
        colors: CharacterScanner.customColors(a),
      );
    } catch (_) {
      return const AddonContents();
    } finally {
      a.close();
    }
  }

  /// Режимы из SOC и Lua архива (те же lumps, что грузит игра).
  static List<GametypeInfo> gametypesIn(AddonArchive a) {
    final out = <GametypeInfo>[];
    final lua = <String>[];
    for (final e in a.entries) {
      final lower = e.lowerPath;
      final isSoc = a.isZip
          ? lower.startsWith('soc/')
          : e.name == 'MAINCFG' || e.name == 'OBJCTCFG' || e.name.startsWith('SOC_');
      final isLua = a.isZip ? lower.startsWith('lua/') || lower == 'init.lua' : e.name.startsWith('LUA_');
      if ((!isSoc && !isLua) || e.size > 8 << 20) continue;
      try {
        final text = latin1.decode(a.read(e), allowInvalid: true);
        if (isSoc) {
          out.addAll(parseSocGametypes(text));
        } else {
          lua.add(text);
        }
      } catch (_) {}
    }
    // G_AddGametype может быть в одном Lua-файле, а таблицы режимов — в другом.
    final registers = lua.any((t) => t.contains('G_AddGametype'));
    for (final text in lua) {
      out.addAll(parseLuaGametypes(text, registers: registers));
    }
    return out;
  }

  static String _unquote(String v) {
    final t = v.trim();
    return t.length >= 2 && t.startsWith('"') && t.endsWith('"') ? t.substring(1, t.length - 1) : t;
  }

  /// SOC: `GameType <название>` + `Identifier = ...`, `Description = ...`.
  static List<GametypeInfo> parseSocGametypes(String text) {
    final out = <GametypeInfo>[];
    String? name;
    var id = '';
    var desc = '';
    var levels = <String>[];
    void flush() {
      if (name != null && name!.isNotEmpty) out.add(GametypeInfo(name!, id, desc, levels));
      name = null;
      id = '';
      desc = '';
      levels = [];
    }

    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) {
        if (line.isEmpty) flush();
        continue;
      }
      final eq = line.indexOf('=');
      if (eq < 0) {
        flush();
        final m = RegExp(r'^gametype\s+(.+)$', caseSensitive: false).firstMatch(line);
        if (m != null) name = m.group(1)!.trim();
        continue;
      }
      if (name == null) continue;
      final key = line.substring(0, eq).trim().toUpperCase();
      final value = _unquote(line.substring(eq + 1));
      if (key == 'IDENTIFIER') id = value;
      if (key == 'DESCRIPTION') desc = value;
      if (key == 'TYPEOFLEVEL') {
        levels = [
          for (final t in value.split(RegExp(r'[,|]')))
            if (t.trim().isNotEmpty) t.trim().toUpperCase().replaceFirst(RegExp(r'^TOL_'), ''),
        ];
      }
    }
    flush();
    return out;
  }

  /// Lua: `G_AddGametype({ name = "...", identifier = "...", ... })` — в
  /// одну строку или в несколько.
  /// [registers] — в аддоне где-то есть G_AddGametype (таблицы режимов и
  /// вызов бывают в разных файлах); null — смотреть только этот текст.
  static List<GametypeInfo> parseLuaGametypes(String text, {bool? registers}) {
    // Таблицу режима могут собрать отдельно и передать переменной:
    //   table.insert(RSP.GT, { name = "FFA", identifier = "ffa", ... })
    //   for i = 1, #RSP.GT do G_AddGametype(RSP.GT[i]) end
    // Поэтому если в файле есть G_AddGametype, берём все таблицы с
    // name = "..." и полями режима (identifier, typeoflevel, rules...).
    if (!(registers ?? text.contains('G_AddGametype'))) return const [];
    final out = <GametypeInfo>[];
    final seen = <int>{};
    final gametypeField = RegExp(r'\b(identifier|typeoflevel|rules|intermissiontype)\s*=', caseSensitive: false);
    for (final m in RegExp(r'\bname\s*=\s*"', caseSensitive: false).allMatches(text)) {
      final start = _enclosingBrace(text, m.start);
      if (start < 0 || !seen.add(start)) continue;
      final end = _matchingBrace(text, start);
      final body = text.substring(start + 1, end);
      // Прямо в G_AddGametype({...}) — режим; иначе нужны поля режима
      // (чтобы не принять за режим цвет, скин и т.п.).
      final direct = RegExp(r'G_AddGametype\s*\(\s*$').hasMatch(text.substring(start < 64 ? 0 : start - 64, start));
      if (!direct && !gametypeField.hasMatch(body)) continue;
      String field(String key) =>
          RegExp('\\b$key\\s*=\\s*"((?:[^"\\\\]|\\\\.)*)"', caseSensitive: false).firstMatch(body)?.group(1) ?? '';
      final name = _cleanLua(field('name'));
      // typeoflevel = TOL_COOP|TOL_HANGOUT
      final tol = RegExp(r'\btypeoflevel\s*=\s*([^,}\n]+)', caseSensitive: false).firstMatch(body)?.group(1) ?? '';
      final levels = [for (final t in RegExp(r'\bTOL_(\w+)').allMatches(tol)) t.group(1)!.toUpperCase()];
      if (name.isNotEmpty) {
        out.add(GametypeInfo(name, _cleanLua(field('identifier')), _cleanLua(field('description')), levels));
      }
    }
    return out;
  }

  /// Позиция '{' таблицы, внутри которой стоит [pos]; -1 — нет.
  static int _enclosingBrace(String text, int pos) {
    var depth = 0;
    for (var i = pos - 1; i >= 0; i--) {
      final c = text.codeUnitAt(i);
      if (c == 0x7D) depth++; // }
      if (c == 0x7B) {
        if (depth == 0) return i;
        depth--;
      }
    }
    return -1;
  }

  /// Позиция парной '}' (строки в кавычках пропускаются); конец текста — если нет.
  static int _matchingBrace(String text, int open) {
    var depth = 0;
    var inString = false;
    for (var i = open; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      if (inString) {
        if (c == 0x5C) {
          i++; // экранированный символ
        } else if (c == 0x22) {
          inString = false;
        }
        continue;
      }
      if (c == 0x22) inString = true;
      if (c == 0x7B) depth++;
      if (c == 0x7D && --depth == 0) return i;
    }
    return text.length;
  }

  /// Строка Lua для показа: без кодов цвета \x80–\x8F и лишних '\'.
  static String _cleanLua(String s) => s
      .replaceAll(RegExp(r'\\x[0-9A-Fa-f]{2}'), '')
      .replaceAll(r'\"', '"')
      .replaceAll(r'\n', ' ')
      .replaceAll('\\', '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

}
