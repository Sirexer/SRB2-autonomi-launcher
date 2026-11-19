import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/game.dart';

/// Папки, аддоны из которых не показываются во вкладке Addons («Другие
/// загрузки», «В папке игры») — только те, что не из репозиториев. У каждой
/// игры свои (Settings → Game folder). Папка внутри папки игры хранится
/// относительно неё: переедет вместе с ней.
class HiddenAddonFolders {
  HiddenAddonFolders._();

  static String _key(GameDef g) => g.key('hidden_addon_folders');

  /// Как записано (относительные — от папки игры).
  static Future<List<String>> stored(GameDef g) async =>
      (await SharedPreferences.getInstance()).getStringList(_key(g)) ?? const [];

  /// Полные пути папок для игры [g] с папкой [root].
  static Future<List<String>> resolved(GameDef g, String? root) async => [
        for (final f in await stored(g))
          if (p.isAbsolute(f)) p.normalize(f) else if (root != null) p.normalize(p.join(root, f)),
      ];

  static Future<void> add(GameDef g, String? root, String folder) async {
    final rel = root != null && (p.isWithin(root, folder) || p.equals(root, folder)) ? p.relative(folder, from: root) : folder;
    final list = [...await stored(g)];
    if (list.any((x) => p.equals(x, rel))) return;
    list.add(rel);
    await (await SharedPreferences.getInstance()).setStringList(_key(g), list);
  }

  static Future<void> remove(GameDef g, String folder) async {
    final list = [for (final x in await stored(g)) if (x != folder) x];
    await (await SharedPreferences.getInstance()).setStringList(_key(g), list);
  }

  /// Файл [file] лежит в одной из [folders] (на любой глубине).
  static bool hides(List<String> folders, String file) =>
      folders.any((d) => p.isWithin(d, file));
}
