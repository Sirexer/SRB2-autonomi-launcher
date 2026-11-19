import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:srb2_autonomi_launcher/models/game.dart';
import 'package:srb2_autonomi_launcher/services/hidden_addon_folders.dart';

void main() {
  test('folders inside the game folder are kept relative; files inside are hidden', () async {
    SharedPreferences.setMockInitialValues({});
    final root = p.join('/games', 'srb2');
    await HiddenAddonFolders.add(Games.srb2, root, p.join(root, 'addons', 'old'));
    await HiddenAddonFolders.add(Games.srb2, root, p.join('/elsewhere', 'mods'));
    await HiddenAddonFolders.add(Games.srb2, root, p.join(root, 'addons', 'old')); // уже есть
    expect(await HiddenAddonFolders.stored(Games.srb2), [p.join('addons', 'old'), p.join('/elsewhere', 'mods')]);
    // Папка игры переехала — относительная папка едет с ней.
    final moved = p.join('/new', 'srb2');
    final folders = await HiddenAddonFolders.resolved(Games.srb2, moved);
    expect(folders, [p.join(moved, 'addons', 'old'), p.join('/elsewhere', 'mods')]);
    expect(HiddenAddonFolders.hides(folders, p.join(moved, 'addons', 'old', 'sub', 'x.pk3')), isTrue);
    expect(HiddenAddonFolders.hides(folders, p.join(moved, 'addons', 'oldish.pk3')), isFalse);
    // У другой игры — свой список.
    expect(await HiddenAddonFolders.stored(Games.srb2kart), isEmpty);
    await HiddenAddonFolders.remove(Games.srb2, p.join('addons', 'old'));
    expect(await HiddenAddonFolders.stored(Games.srb2), [p.join('/elsewhere', 'mods')]);
  });
}
