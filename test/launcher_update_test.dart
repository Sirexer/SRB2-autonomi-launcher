import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:srb2_autonomi_launcher/services/launcher_update.dart';

void main() {
  Map<String, Object?> release(String tag, String published, {bool draft = false, String body = ''}) => {
        'tag_name': tag,
        'name': tag,
        'draft': draft,
        'body': body,
        'published_at': published,
        'html_url': 'https://github.com/x/y/releases/tag/$tag',
        'assets': [
          {
            'name': 'SRB2-Autonomi-Launcher-windows-x64.zip',
            'browser_download_url': 'https://example/w.zip',
            'size': 10,
            'digest': 'sha256:ABCDEF',
          },
          {'name': 'SRB2-Autonomi-Launcher-x86_64.AppImage', 'browser_download_url': 'https://example/l', 'size': 20},
        ],
      };

  final r2 = LauncherRelease.fromJson(release('beta-release2', '2026-11-10T12:00:00Z'))!;
  final r3 = LauncherRelease.fromJson(release('beta-release3', '2026-11-20T12:00:00Z', body: '## New\n- a'))!;
  final list = [r3, r2];

  test('release from the GitHub API', () {
    expect(LauncherRelease.fromJson(release('x', '2026-01-01T00:00:00Z', draft: true)), isNull);
    expect((r3.tag, r3.changelog, r3.published, r3.assets.length), ('beta-release3', '## New\n- a', DateTime.utc(2026, 11, 20, 12), 2));
    expect(r3.assets.first.sha256, 'abcdef');
    expect(r3.assets.last.sha256, isNull);
    final asset = r3.assetForThisSystem!;
    expect(asset.name, Platform.isWindows ? 'SRB2-Autonomi-Launcher-windows-x64.zip' : 'SRB2-Autonomi-Launcher-x86_64.AppImage');
  });

  test('is there a newer version', () {
    // По тегу сборки.
    expect(LauncherUpdate.newerFor(list, version: 'beta-release3', built: null), isNull);
    expect(LauncherUpdate.newerFor(list, version: 'beta-release2', built: null)?.tag, 'beta-release3');
    // Сборка без тега: по времени сборки (сам релиз публикуется чуть позже своей сборки).
    expect(LauncherUpdate.newerFor(list, version: '', built: DateTime.utc(2026, 11, 20, 11, 40)), isNull);
    expect(LauncherUpdate.newerFor(list, version: '', built: DateTime.utc(2026, 11, 12))?.tag, 'beta-release3');
    // Локальная сборка: не при запуске, по кнопке — да.
    expect(LauncherUpdate.newerFor(list, version: '', built: null), isNull);
    expect(LauncherUpdate.newerFor(list, version: '', built: null, anyBuild: true)?.tag, 'beta-release3');
    expect(LauncherUpdate.newerFor(const [], version: 'x', built: null), isNull);
  });

  test('files are replaced, the old ones kept as .old and removed on the next start', () async {
    final tmp = await Directory.systemTemp.createTemp('upd');
    try {
      final app = Directory(p.join(tmp.path, 'app'))..createSync();
      final root = Directory(p.join(tmp.path, 'new'))..createSync();
      void write(Directory d, String rel, String text) {
        final f = File(p.join(d.path, rel));
        f.parent.createSync(recursive: true);
        f.writeAsStringSync(text);
      }

      write(app, 'srb2al.exe', 'old exe');
      write(app, 'data/app.so', 'old so');
      write(app, 'pointer.txt', 'my pointer');
      write(app, 'lang/xx.json', 'my language');
      write(app, 'user_data/prefs.json', 'settings');
      write(root, 'srb2al.exe', 'new exe');
      write(root, 'data/app.so', 'new so');
      write(root, 'data/new.dat', 'added');
      write(root, 'pointer.txt', 'bundled pointer');
      write(root, 'lang/ru.json', 'ru');

      final moved = await LauncherUpdate.replaceFiles(root.path, app.path);
      await LauncherUpdate.rememberOld(app.path, moved);
      String read(String rel) => File(p.join(app.path, rel)).readAsStringSync();
      expect(read('srb2al.exe'), 'new exe');
      expect(read('data/app.so'), 'new so');
      expect(read('data/new.dat'), 'added');
      expect(read('pointer.txt'), 'my pointer'); // свой pointer.txt остаётся
      expect(read('lang/xx.json'), 'my language'); // свой язык остаётся
      expect(read('user_data/prefs.json'), 'settings');
      expect(read('srb2al.exe.old'), 'old exe');

      await LauncherUpdate.cleanupIn(app.path);
      expect(File(p.join(app.path, 'srb2al.exe.old')).existsSync(), isFalse);
      expect(File(p.join(app.path, 'data/app.so.old')).existsSync(), isFalse);
      expect(read('srb2al.exe'), 'new exe');
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });

  test('a failed replacement puts everything back', () async {
    final tmp = await Directory.systemTemp.createTemp('upd');
    try {
      final app = Directory(p.join(tmp.path, 'app'))..createSync();
      final root = Directory(p.join(tmp.path, 'new'))..createSync();
      File(p.join(app.path, 'a.txt')).writeAsStringSync('old a');
      File(p.join(root.path, 'a.txt')).writeAsStringSync('new a');
      // На месте папки в новой версии — файл: создать её нельзя.
      File(p.join(app.path, 'sub')).writeAsStringSync('a file');
      File(p.join(root.path, 'sub', 'b.txt'))
        ..parent.createSync()
        ..writeAsStringSync('b');
      await expectLater(LauncherUpdate.replaceFiles(root.path, app.path), throwsA(anything));
      expect(File(p.join(app.path, 'a.txt')).readAsStringSync(), 'old a');
      expect(File(p.join(app.path, 'a.txt.old')).existsSync(), isFalse);
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });
}
