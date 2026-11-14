import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:srb2_autonomi_launcher/models/game.dart';
import 'package:srb2_autonomi_launcher/models/launch_config.dart';
import 'package:srb2_autonomi_launcher/services/game_files.dart';
import 'package:srb2_autonomi_launcher/services/launch_settings.dart';

void main() {
  test('game files are not taken from other versions next to the build', () async {
    final dir = await Directory.systemTemp.createTemp('game_files_');
    addTearDown(() => dir.delete(recursive: true));
    // AllVersions/SRB2_22_Test/srb2win.exe + srb2.pk3; рядом AllVersions/SRB2_Legacy/player.dta;
    // папка игры (DOWNLOAD) — AllVersions/SRB2_22.
    final all = p.join(dir.path, 'AllVersions');
    final build = p.join(all, 'SRB2_22_Test');
    final folder = p.join(all, 'SRB2_22');
    await File(p.join(build, 'srb2win.exe')).create(recursive: true);
    final pk3 = File(p.join(build, 'srb2.pk3'));
    await pk3.create(recursive: true);
    final zones = File(p.join(build, 'data', 'Assets', 'zones.pk3'));
    await zones.create(recursive: true);
    await File(p.join(all, 'SRB2_Legacy', 'player.dta')).create(recursive: true);
    await Directory(p.join(folder, 'DOWNLOAD')).create(recursive: true);

    SharedPreferences.setMockInitialValues({});
    final launch = LaunchSettings();
    await launch.load();
    launch.executables
      ..clear()
      ..add(LaunchExecutable(id: 'b', name: 'Test', command: p.join(build, 'srb2win.exe')));
    final found = await GameFiles.resolveAsync(Games.srb2, folder, launch, ['srb2.pk3', 'player.dta', 'zones.pk3']);
    // srb2.pk3 — рядом со сборкой, zones.pk3 — вглубь из папки сборки; player.dta соседней версии — нет.
    expect(found, [pk3.path, zones.path]);
  });
}
