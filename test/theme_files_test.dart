import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:srb2_autonomi_launcher/theme/app_themes.dart';

class _Paths extends PathProviderPlatform {
  final String dir;
  _Paths(this.dir);
  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('saving a theme copies its pictures next to it; deleting removes them', () async {
    final tmp = await Directory.systemTemp.createTemp('themes');
    try {
      PathProviderPlatform.instance = _Paths(p.join(tmp.path, 'data'));
      final pics = Directory(p.join(tmp.path, 'pictures'))..createSync();
      File(p.join(pics.path, 'sky.jpg')).writeAsBytesSync([1, 2, 3]);
      File(p.join(pics.path, 'kart.png')).writeAsBytesSync([4, 5]);

      final saved = await AppThemes.save(LauncherTheme(
        key: 'new',
        name: 'My Sky',
        seed: const Color(0xFF1E5BFF),
        backgroundImage: p.join(pics.path, 'sky.jpg'),
        backgroundImages: {'srb2kart': p.join(pics.path, 'kart.png')},
        backgroundBlur: 4,
        font: 'Inter',
        radius: 16,
        windowOpacity: 0.9,
        backdrop: 'mica',
        visualizer: const [Color(0xFFFF00FF), Color(0xFF00E5FF)],
      ));
      final dir = p.join(tmp.path, 'data', 'themes');
      expect(saved.path, p.join(dir, 'my_sky.json'));
      expect((saved.key, saved.editable), ('file:my_sky', true));
      final json = jsonDecode(File(saved.path!).readAsStringSync()) as Map<String, dynamic>;
      expect(json['background_image'], 'my_sky-sky.jpg');
      expect(json['background_images'], {'srb2kart': 'my_sky-kart.png'});
      expect((json['background_blur'], json['font'], json['radius'], json['window_opacity'], json['backdrop']),
          (4, 'Inter', 16, 0.9, 'mica'));
      expect(json['visualizer'], ['#FF00FF', '#00E5FF']);
      expect(File(p.join(dir, 'my_sky-sky.jpg')).readAsBytesSync(), [1, 2, 3]);
      // Картинки по игре: своя у Kart, общая у остальных.
      expect(saved.imageFor('srb2kart'), p.join(dir, 'my_sky-kart.png'));
      expect(saved.imageFor('srb2'), p.join(dir, 'my_sky-sky.jpg'));

      // Найдена при загрузке папок.
      await AppThemes.load();
      expect(AppThemes.byKey('file:my_sky').name, 'My Sky');

      await AppThemes.delete(AppThemes.byKey('file:my_sky'));
      expect(File(p.join(dir, 'my_sky-sky.jpg')).existsSync(), isFalse);
      expect(AppThemes.all.any((t) => t.key == 'file:my_sky'), isFalse);
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });

  test('a new theme based on your own goes to a new file with its own copies', () async {
    final tmp = await Directory.systemTemp.createTemp('themes');
    try {
      PathProviderPlatform.instance = _Paths(p.join(tmp.path, 'data'));
      final pic = File(p.join(tmp.path, 'sky.jpg'))..writeAsBytesSync([1, 2, 3]);
      final original = await AppThemes.save(
          LauncherTheme(key: 'new', name: 'Sky', seed: const Color(0xFF1E5BFF), backgroundImage: pic.path));
      final before = File(original.path!).readAsStringSync();

      // Как «Новая тема» в редакторе: та же тема, но не своя и с тем же именем.
      final copy = await AppThemes.save(original.copyWith(editable: false, radius: () => 20));
      final dir = p.join(tmp.path, 'data', 'themes');
      expect(copy.path, p.join(dir, 'sky_2.json'));
      expect(File(original.path!).readAsStringSync(), before);
      final json = jsonDecode(File(copy.path!).readAsStringSync()) as Map<String, dynamic>;
      expect(json['background_image'], 'sky_2-sky.jpg');

      await AppThemes.delete(original);
      expect(File(copy.imageFor('srb2')!).readAsBytesSync(), [1, 2, 3]);
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });

  test('a theme with a picture makes the window see-through; values are clamped', () {
    final t = LauncherTheme.fromJson({
      'name': 'X',
      'seed': '#123456',
      'background_image': 'a.png',
      'text_scale': 5,
      'window_opacity': 0.1,
      'backdrop': 'glass',
      'radius': 100,
    }, key: 'x', path: '/themes/x.json');
    expect(t.data.scaffoldBackgroundColor, const Color(0x00000000));
    expect((t.textScale, t.windowOpacity, t.backdrop, t.radius), (1.6, 0.4, 'none', 40.0));
    expect(t.resolve(t.backgroundImage), p.join('/themes', 'a.png'));
    expect((t.backgroundFit, t.backgroundScale, t.backdropOpacity), ('cover', 1.0, 0.35));
  });

  test('tiled picture and backdrop tint go to JSON and back', () {
    final t = LauncherTheme.fromJson({
      'name': 'Rings',
      'seed': '#1030E0',
      'background_image': 'rings.png',
      'background_fit': 'tile',
      'background_scale': 0.5,
      'backdrop': 'acrylic',
      'backdrop_opacity': 0.1,
    }, key: 'x');
    expect((t.backgroundFit, t.backgroundScale, t.backdropOpacity), ('tile', 0.5, 0.1));
    final j = t.toJson();
    expect((j['background_fit'], j['background_scale'], j['backdrop_opacity']), ('tile', 0.5, 0.1));
    expect(LauncherTheme.fromJson({'name': 'X', 'seed': '#000', 'background_fit': 'mosaic'}, key: 'x').backgroundFit, 'cover');
  });

  test('font weight, letter spacing and text shadow: JSON and the text styles', () {
    final t = LauncherTheme.fromJson({
      'name': 'Shadowy',
      'seed': '#1030E0',
      'font_weight': 2,
      'letter_spacing': 0.5,
      'text_shadow': {'color': '#80000000', 'blur': 3, 'x': 1, 'y': 2},
    }, key: 'x');
    expect((t.fontWeight, t.letterSpacing), (2, 0.5));
    expect(t.textShadow, const Shadow(color: Color(0x80000000), blurRadius: 3, offset: Offset(1, 2)));
    final j = t.toJson();
    expect(j['text_shadow'], {'color': '#80000000', 'blur': 3.0, 'x': 1.0, 'y': 2.0});
    expect((j['font_weight'], j['letter_spacing']), (2, 0.5));
    final body = t.data.textTheme.bodyMedium!;
    expect(body.shadows, [t.textShadow]);
    expect(body.letterSpacing, 0.5);
    // Обычный текст (w400) стал на две ступени жирнее.
    expect(body.fontWeight, FontWeight.w600);
  });
}
