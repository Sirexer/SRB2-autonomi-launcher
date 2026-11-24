import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../models/game.dart';
import 'launch_settings.dart';
import 'server_files.dart';

/// Где лежат файлы самой игры (srb2.pk3, zones.pk3, bios.pk3...).
///
/// Игра ищет их в рабочей папке, а если там нет — рядом с exe и в стандартных
/// папках (I_LocateWad). У многих сборки лежат в `bin/<сборка>/`, а данные —
/// в общей папке `data`, поэтому смотрим и папки сборок, и их `data`.
class GameFiles {
  GameFiles._();

  static List<String> dirs(GameDef game, String? folder, Iterable<String> programs) {
    final out = <String>[];
    void add(String d) {
      final n = p.normalize(d);
      if (!out.any((x) => p.equals(x, n))) out.add(n);
    }

    if (folder != null) {
      add(folder);
      add(p.join(folder, 'data'));
    }
    for (final prog in programs) {
      if (!prog.contains('/') && !prog.contains(r'\')) continue; // команда из PATH (flatpak и т.п.)
      final abs = p.isAbsolute(prog) || folder == null ? prog : p.join(folder, prog);
      final dir = p.dirname(abs);
      add(dir);
      add(p.join(dir, 'data'));
      add(p.dirname(dir));
      add(p.join(p.dirname(dir), 'data'));
    }
    if (!Platform.isWindows && game == Games.srb2) {
      for (final d in ['/usr/local/share/games/SRB2', '/usr/local/games/SRB2', '/usr/share/games/SRB2', '/usr/games/SRB2']) {
        add(d);
      }
    }
    return out;
  }

  /// Полные пути файлов игры [relative] (тех, что нашлись).
  static List<String> resolve(GameDef game, String? folder, LaunchSettings launch, List<String> relative) {
    final searchDirs = dirs(game, folder, launch.executables.map((e) => e.program));
    return [
      for (final rel in relative)
        if (_find(searchDirs, rel) case final path?) path,
    ];
  }

  /// То же, но если файла нет на обычных местах — ищет его по имени вглубь
  /// папки игры и папок сборок (до 5 уровней: data/Assets/Required/zones.pk3).
  static Future<List<String>> resolveAsync(
      GameDef game, String? folder, LaunchSettings launch, List<String> relative) async {
    final programs = launch.executables.map((e) => e.program).toList();
    final searchDirs = dirs(game, folder, programs);
    // Вглубь — только из папки игры и папок самих сборок, не из их
    // родительских папок: там часто лежат другие версии игры («Sonic Robo
    // Blast 2 (All Versions)\SRB2 2.2\», «…\SRB2 Legacy\»), и находился
    // чужой player.dta — иконки персонажей другой игры.
    final roots = <String>[
      if (folder != null) folder,
      for (final d in searchDirs)
        if ((folder == null || !p.isWithin(folder, d) && !p.equals(folder, d)) && isBuildDir(d, programs, folder)) d,
    ];
    final out = List<String?>.filled(relative.length, null);
    final missing = <(int, String)>[];
    for (var i = 0; i < relative.length; i++) {
      final rel = relative[i];
      final direct = _find(searchDirs, rel);
      if (direct != null) {
        out[i] = direct;
      } else {
        missing.add((i, p.basename(rel)));
      }
    }
    if (missing.isNotEmpty) {
      final deep = await _deepFindAll(roots, [for (final m in missing) m.$2]);
      for (final (i, name) in missing) {
        out[i] = deep[name.toLowerCase()];
      }
    }
    return [for (final path in out) ?path];
  }

  /// [d] — папка exe сборки или её `data` (не родительская папка сборки).
  static bool isBuildDir(String d, List<String> programs, String? folder) {
    for (final prog in programs) {
      if (!prog.contains('/') && !prog.contains(r'\')) continue;
      final abs = p.isAbsolute(prog) || folder == null ? prog : p.join(folder, prog);
      final dir = p.normalize(p.dirname(abs));
      if (p.equals(d, dir) || p.equals(d, p.join(dir, 'data'))) return true;
    }
    return false;
  }

  static final Map<String, String?> _deepCache = {};

  /// Ищет все отсутствующие файлы из [names] за один обход в фоновом изоляте,
  /// чтобы не блокировать цикл событий главного потока при проверке папки игры.
  static Future<Map<String, String?>> _deepFindAll(List<String> roots, List<String> names) async {
    final prefix = '${roots.join('|')}|';
    final result = <String, String?>{};
    final uncached = <String>{};
    for (final name in names) {
      final lower = name.toLowerCase();
      final key = '$prefix$lower';
      if (_deepCache.containsKey(key)) {
        result[lower] = _deepCache[key];
      } else {
        uncached.add(lower);
      }
    }
    if (uncached.isEmpty || roots.isEmpty) return result;

    final skipped = LocalFileIndex.skippedFolders;
    final found = await Isolate.run(() {
      final hits = <String, String>{};
      final remaining = Set<String>.from(uncached);
      void walk(Directory dir, int depth) {
        if (remaining.isEmpty) return;
        final subdirs = <Directory>[];
        try {
          for (final e in dir.listSync(followLinks: false)) {
            if (e is File) {
              final base = p.basename(e.path).toLowerCase();
              if (remaining.remove(base)) {
                hits[base] = e.path;
                if (remaining.isEmpty) return;
              }
            } else if (e is Directory && depth > 0 && !skipped.contains(p.basename(e.path).toLowerCase())) {
              subdirs.add(e);
            }
          }
        } catch (_) {
          return;
        }
        for (final d in subdirs) {
          walk(d, depth - 1);
          if (remaining.isEmpty) return;
        }
      }

      for (final r in roots) {
        walk(Directory(r), 5);
        if (remaining.isEmpty) break;
      }
      return hits;
    });

    for (final lower in uncached) {
      final path = found[lower];
      _deepCache['$prefix$lower'] = path;
      result[lower] = path;
    }
    return result;
  }

  static String? _find(List<String> dirs, String rel) {
    for (final d in dirs) {
      final path = p.joinAll([d, ...rel.split('/')]);
      if (File(path).existsSync()) return path;
    }
    return null;
  }
}
