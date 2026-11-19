import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Тема лаунчера: цвета и, по желанию, картинка на фоне, шрифт, скругление
/// углов, прозрачность окна и цвета визуализации музыки.
///
/// Темы-файлы (`*.json`) лежат в папке `themes` рядом с лаунчером (идут со
/// сборкой) и в папке `themes` данных лаунчера (свои, из редактора). Файлы
/// темы (картинки, шрифт) — рядом с её JSON (путь относительно него):
/// ```json
/// {
///   "name": "Ocean",
///   "dark": true,
///   "seed": "#1E5BFF",
///   "accent": "#5B8CFF",
///   "background": "#0A0F1E",
///   "panels": "#111A2E",
///   "text": "#E6ECFF",
///   "background_image": "ocean.jpg",
///   "background_images": {"srb2kart": "kart.jpg"},
///   "background_dim": 0.6,
///   "background_blur": 4,
///   "font": "Ubuntu",
///   "text_scale": 1.1,
///   "radius": 14,
///   "window_opacity": 0.95,
///   "backdrop": "mica",
///   "visualizer": ["#00E5FF", "#2962FF"]
/// }
/// ```
/// Обязательны только `name` и `seed`.
class LauncherTheme {
  /// Ключ в настройках: у встроенных — `deepOrange`..., у файлов — `file:<имя файла>`.
  final String key;
  final String name;
  final bool dark;

  /// Основной цвет: из него Material строит все оттенки.
  final Color seed;

  /// Точный цвет акцента (кнопки, выделение); null — оттенок из [seed].
  final Color? accent;

  /// Фон окна; null — по умолчанию.
  final Color? background;

  /// Панели, карточки и окна; null — из [seed].
  final Color? panels;

  /// Цвет текста; null — по умолчанию.
  final Color? text;

  /// Картинка на фоне (путь как в JSON: относительно файла темы) и свои
  /// картинки для игр (код игры → путь).
  final String? backgroundImage;
  final Map<String, String> backgroundImages;

  /// Насколько фон окна закрывает картинку (0 — картинка как есть, 1 — не видна).
  final double backgroundDim;

  /// Размытие картинки, пикселей.
  final double backgroundBlur;

  /// Как картинка ложится на окно: `cover` — растянута на всё окно, `tile` —
  /// повторяется плиткой, `center` — одна, по центру.
  final String backgroundFit;

  /// Масштаб картинки для `tile` и `center` (1 — как есть).
  final double backgroundScale;

  /// Насколько фон темы закрывает подложку Windows 11 (0 — подложка как есть).
  final double backdropOpacity;

  /// Шрифт: название системного шрифта или файл `.ttf`/`.otf` рядом с темой.
  final String? font;

  /// Толщина шрифта относительно обычной: -3 (тоньше) … +3 (жирнее).
  final int fontWeight;

  /// Межбуквенный интервал, логических пикселей (0 — как у шрифта).
  final double letterSpacing;

  /// Тень текста; null — без тени.
  final Shadow? textShadow;

  /// Масштаб текста (1 — как обычно).
  final double textScale;

  /// Скругление углов кнопок, карточек, окон и полей; null — как обычно.
  final double? radius;

  /// Непрозрачность окна (1 — обычное окно).
  final double windowOpacity;

  /// Подложка окна на Windows 11: `none`, `mica`, `acrylic`.
  final String backdrop;

  /// Цвета визуализации музыки (сверху вниз); пусто — цвет акцента.
  final List<Color> visualizer;

  /// Файл темы (null — встроенная) и можно ли его менять (своя тема).
  final String? path;
  final bool editable;

  const LauncherTheme({
    required this.key,
    required this.name,
    this.dark = true,
    required this.seed,
    this.accent,
    this.background,
    this.panels,
    this.text,
    this.backgroundImage,
    this.backgroundImages = const {},
    this.backgroundDim = 0.55,
    this.backgroundBlur = 0,
    this.backgroundFit = 'cover',
    this.backgroundScale = 1,
    this.backdropOpacity = 0.35,
    this.font,
    this.fontWeight = 0,
    this.letterSpacing = 0,
    this.textShadow,
    this.textScale = 1,
    this.radius,
    this.windowOpacity = 1,
    this.backdrop = 'none',
    this.visualizer = const [],
    this.path,
    this.editable = false,
  });

  static const backdrops = ['none', 'mica', 'acrylic'];
  static const fits = ['cover', 'tile', 'center'];

  LauncherTheme copyWith({
    String? key,
    String? name,
    bool? dark,
    Color? seed,
    Color? Function()? accent,
    Color? Function()? background,
    Color? Function()? panels,
    Color? Function()? text,
    String? Function()? backgroundImage,
    Map<String, String>? backgroundImages,
    double? backgroundDim,
    double? backgroundBlur,
    String? backgroundFit,
    double? backgroundScale,
    double? backdropOpacity,
    String? Function()? font,
    int? fontWeight,
    double? letterSpacing,
    Shadow? Function()? textShadow,
    double? textScale,
    double? Function()? radius,
    double? windowOpacity,
    String? backdrop,
    List<Color>? visualizer,
    String? Function()? path,
    bool? editable,
  }) =>
      LauncherTheme(
        key: key ?? this.key,
        name: name ?? this.name,
        dark: dark ?? this.dark,
        seed: seed ?? this.seed,
        accent: accent == null ? this.accent : accent(),
        background: background == null ? this.background : background(),
        panels: panels == null ? this.panels : panels(),
        text: text == null ? this.text : text(),
        backgroundImage: backgroundImage == null ? this.backgroundImage : backgroundImage(),
        backgroundImages: backgroundImages ?? this.backgroundImages,
        backgroundDim: backgroundDim ?? this.backgroundDim,
        backgroundBlur: backgroundBlur ?? this.backgroundBlur,
        backgroundFit: backgroundFit ?? this.backgroundFit,
        backgroundScale: backgroundScale ?? this.backgroundScale,
        backdropOpacity: backdropOpacity ?? this.backdropOpacity,
        font: font == null ? this.font : font(),
        fontWeight: fontWeight ?? this.fontWeight,
        letterSpacing: letterSpacing ?? this.letterSpacing,
        textShadow: textShadow == null ? this.textShadow : textShadow(),
        textScale: textScale ?? this.textScale,
        radius: radius == null ? this.radius : radius(),
        windowOpacity: windowOpacity ?? this.windowOpacity,
        backdrop: backdrop ?? this.backdrop,
        visualizer: visualizer ?? this.visualizer,
        path: path == null ? this.path : path(),
        editable: editable ?? this.editable,
      );

  static Color? parseColor(Object? v) {
    if (v is! String) return null;
    var h = v.trim().replaceFirst('#', '');
    if (h.length == 3) h = h.split('').map((c) => '$c$c').join();
    if (h.length == 6) h = 'FF$h';
    if (h.length != 8) return null;
    final n = int.tryParse(h, radix: 16);
    return n == null ? null : Color(n);
  }

  static String hex(Color c) {
    final argb = c.toARGB32();
    final rgb = (argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();
    final a = argb >>> 24;
    return a == 0xFF ? '#$rgb' : '#${a.toRadixString(16).padLeft(2, '0').toUpperCase()}$rgb';
  }

  /// Тень текста из `{"color": "#000000AA", "blur": 3, "x": 1, "y": 1}`.
  static Shadow? _shadow(Object? v) {
    if (v is! Map) return null;
    final color = parseColor(v['color']) ?? const Color(0xAA000000);
    return Shadow(
      color: color,
      blurRadius: _num(v['blur'], 2, 0, 20),
      offset: Offset(_num(v['x'], 1, -10, 10), _num(v['y'], 1, -10, 10)),
    );
  }

  static double _num(Object? v, double fallback, double min, double max) =>
      v is num ? v.toDouble().clamp(min, max) : fallback;

  /// Тема из JSON; ошибка в описании — [FormatException].
  static LauncherTheme fromJson(Map<String, dynamic> j, {required String key, String? path, bool editable = false}) {
    final name = j['name'] is String ? (j['name'] as String).trim() : '';
    final seed = parseColor(j['seed']);
    if (name.isEmpty) throw const FormatException('"name" is missing');
    if (seed == null) throw const FormatException('"seed" must be a color like "#1E5BFF"');
    String? str(String k) => j[k] is String && (j[k] as String).trim().isNotEmpty ? (j[k] as String).trim() : null;
    final images = j['background_images'];
    final vis = j['visualizer'];
    final backdrop = str('backdrop')?.toLowerCase() ?? 'none';
    return LauncherTheme(
      key: key,
      name: name,
      dark: j['dark'] is bool ? j['dark'] as bool : true,
      seed: seed,
      accent: parseColor(j['accent']),
      background: parseColor(j['background']),
      panels: parseColor(j['panels']),
      text: parseColor(j['text']),
      backgroundImage: str('background_image'),
      backgroundImages: {
        if (images is Map)
          for (final e in images.entries)
            if (e.value is String && '${e.value}'.trim().isNotEmpty) '${e.key}'.toLowerCase(): '${e.value}'.trim(),
      },
      backgroundDim: _num(j['background_dim'], 0.55, 0, 1),
      backgroundBlur: _num(j['background_blur'], 0, 0, 40),
      backgroundFit: fits.contains(str('background_fit')) ? str('background_fit')! : 'cover',
      backgroundScale: _num(j['background_scale'], 1, 0.1, 8),
      backdropOpacity: _num(j['backdrop_opacity'], 0.35, 0, 1),
      font: str('font'),
      fontWeight: _num(j['font_weight'], 0, -3, 3).round(),
      letterSpacing: _num(j['letter_spacing'], 0, -2, 6),
      textShadow: _shadow(j['text_shadow']),
      textScale: _num(j['text_scale'], 1, 0.7, 1.6),
      radius: j['radius'] is num ? _num(j['radius'], 0, 0, 40) : null,
      windowOpacity: _num(j['window_opacity'], 1, 0.4, 1),
      backdrop: backdrops.contains(backdrop) ? backdrop : 'none',
      visualizer: [
        if (vis is String) ?parseColor(vis),
        if (vis is List)
          for (final c in vis) ?parseColor(c),
      ],
      path: path,
      editable: editable,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'dark': dark,
        'seed': hex(seed),
        if (accent != null) 'accent': hex(accent!),
        if (background != null) 'background': hex(background!),
        if (panels != null) 'panels': hex(panels!),
        if (text != null) 'text': hex(text!),
        if (backgroundImage != null) 'background_image': backgroundImage,
        if (backgroundImages.isNotEmpty) 'background_images': backgroundImages,
        if (hasImages) 'background_dim': double.parse(backgroundDim.toStringAsFixed(2)),
        if (hasImages && backgroundBlur > 0) 'background_blur': backgroundBlur.round(),
        if (hasImages && backgroundFit != 'cover') 'background_fit': backgroundFit,
        if (hasImages && backgroundFit != 'cover' && backgroundScale != 1)
          'background_scale': double.parse(backgroundScale.toStringAsFixed(2)),
        if (font != null) 'font': font,
        if (fontWeight != 0) 'font_weight': fontWeight,
        if (letterSpacing != 0) 'letter_spacing': double.parse(letterSpacing.toStringAsFixed(2)),
        if (textShadow case final sh?)
          'text_shadow': {
            'color': hex(sh.color),
            'blur': double.parse(sh.blurRadius.toStringAsFixed(1)),
            'x': double.parse(sh.offset.dx.toStringAsFixed(1)),
            'y': double.parse(sh.offset.dy.toStringAsFixed(1)),
          },
        if (textScale != 1) 'text_scale': double.parse(textScale.toStringAsFixed(2)),
        if (radius != null) 'radius': radius!.round(),
        if (windowOpacity < 1) 'window_opacity': double.parse(windowOpacity.toStringAsFixed(2)),
        if (backdrop != 'none') 'backdrop': backdrop,
        if (backdrop != 'none') 'backdrop_opacity': double.parse(backdropOpacity.toStringAsFixed(2)),
        if (visualizer.isNotEmpty) 'visualizer': [for (final c in visualizer) hex(c)],
      };

  bool get hasImages => backgroundImage != null || backgroundImages.isNotEmpty;

  /// Путь файла темы (картинки, шрифта) на диске: относительно JSON темы.
  String? resolve(String? file) {
    if (file == null) return null;
    if (p.isAbsolute(file) || path == null) return file;
    return p.normalize(p.join(p.dirname(path!), file));
  }

  /// Картинка для игры [gameId]: своя у игры, иначе общая; null — нет.
  String? imageFor(String gameId) => resolve(backgroundImages[gameId.toLowerCase()] ?? backgroundImage);

  /// Шрифт из файла (а не системный).
  bool get fontIsFile {
    final f = font?.toLowerCase() ?? '';
    return f.endsWith('.ttf') || f.endsWith('.otf');
  }

  /// Семейство шрифта для Flutter: системное название или загруженный файл.
  String? get fontFamily => font == null ? null : (fontIsFile ? AppThemes.loadedFonts[resolve(font)] : font);

  /// Подложка Windows 11 включена (на других системах — нет).
  bool get usesBackdrop => backdrop != 'none' && Platform.isWindows;

  /// Цвет фона окна (у встроенных тёмных — как раньше).
  Color get windowBackground => background ?? (dark ? ThemeData.dark(useMaterial3: true).scaffoldBackgroundColor : colorScheme.surface);

  /// Цвет, который читается на [c]: белый или почти чёрный.
  static Color onColor(Color c) =>
      ThemeData.estimateBrightnessForColor(c) == Brightness.dark ? Colors.white : const Color(0xFF111111);

  /// Оттенок [c] светлее (dark) или темнее (light) на [t] (0..1).
  Color _step(Color c, double t) => Color.lerp(c, dark ? Colors.white : Colors.black, t)!;

  ColorScheme get colorScheme {
    var s = ColorScheme.fromSeed(seedColor: seed, brightness: dark ? Brightness.dark : Brightness.light);
    if (accent case final a?) {
      s = s.copyWith(primary: a, onPrimary: onColor(a), primaryContainer: Color.lerp(a, s.surface, 0.6));
    }
    if (panels case final c?) {
      s = s.copyWith(
        surface: c,
        surfaceContainerLowest: c,
        surfaceContainerLow: _step(c, 0.02),
        surfaceContainer: _step(c, 0.04),
        surfaceContainerHigh: _step(c, 0.07),
        surfaceContainerHighest: _step(c, 0.10),
        onSurface: text ?? onColor(c),
      );
    }
    if (text case final t?) {
      s = s.copyWith(onSurface: t, onSurfaceVariant: t.withValues(alpha: 0.75));
    }
    return s;
  }

  ThemeData get data {
    final base = dark ? ThemeData.dark(useMaterial3: true) : ThemeData.light(useMaterial3: true);
    final scheme = colorScheme;
    var theme = base.copyWith(
      colorScheme: scheme,
      // Уведомления — всплывающие карточки с крестиком, а не полоса внизу окна.
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        width: 560,
        showCloseIcon: true,
        shape: radius == null ? null : RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius!)),
      ),
      extensions: [
        LauncherExtras(
          visualizerTop: visualizer.isEmpty ? null : visualizer.first,
          visualizerBottom: visualizer.length < 2 ? null : visualizer[1],
          radius: radius,
        ),
      ],
    );
    // Картинка на фоне или подложка Windows: окно прозрачное, фон рисуется под ним.
    final seeThrough = hasImages || usesBackdrop;
    if (background != null || !dark || seeThrough) {
      final bg = seeThrough ? Colors.transparent : windowBackground;
      theme = theme.copyWith(
        scaffoldBackgroundColor: bg,
        canvasColor: seeThrough ? windowBackground : bg,
        appBarTheme: theme.appBarTheme.copyWith(backgroundColor: bg, surfaceTintColor: Colors.transparent),
      );
    }
    if (text != null) {
      theme = theme.copyWith(
        textTheme: theme.textTheme.apply(bodyColor: text, displayColor: text),
        iconTheme: theme.iconTheme.copyWith(color: text),
      );
    }
    if (fontFamily case final f?) {
      theme = theme.copyWith(
        textTheme: theme.textTheme.apply(fontFamily: f),
        primaryTextTheme: theme.primaryTextTheme.apply(fontFamily: f),
      );
    }
    // Толщина, интервал и тень — у всех стилей текста темы (тексты в окне
    // наследуют их, если не задают своё).
    if (fontWeight != 0 || letterSpacing != 0 || textShadow != null) {
      // Толщина стилей приходит из типографики Material 3 позже (Theme.of):
      // берём её оттуда.
      final geometry = Typography.material2021().englishLike;
      TextStyle style(TextStyle s, TextStyle? geom) {
        var out = s;
        if (fontWeight != 0) {
          final w = s.fontWeight ?? geom?.fontWeight ?? FontWeight.w400;
          // w100…w900 — шаг 100.
          final i = ((w.value ~/ 100) - 1 + fontWeight).clamp(0, FontWeight.values.length - 1);
          out = out.copyWith(fontWeight: FontWeight.values[i]);
        }
        if (letterSpacing != 0) out = out.copyWith(letterSpacing: letterSpacing);
        if (textShadow != null) out = out.copyWith(shadows: [textShadow!]);
        return out;
      }

      TextTheme all(TextTheme t) => TextTheme(
            displayLarge: t.displayLarge == null ? null : style(t.displayLarge!, geometry.displayLarge),
            displayMedium: t.displayMedium == null ? null : style(t.displayMedium!, geometry.displayMedium),
            displaySmall: t.displaySmall == null ? null : style(t.displaySmall!, geometry.displaySmall),
            headlineLarge: t.headlineLarge == null ? null : style(t.headlineLarge!, geometry.headlineLarge),
            headlineMedium: t.headlineMedium == null ? null : style(t.headlineMedium!, geometry.headlineMedium),
            headlineSmall: t.headlineSmall == null ? null : style(t.headlineSmall!, geometry.headlineSmall),
            titleLarge: t.titleLarge == null ? null : style(t.titleLarge!, geometry.titleLarge),
            titleMedium: t.titleMedium == null ? null : style(t.titleMedium!, geometry.titleMedium),
            titleSmall: t.titleSmall == null ? null : style(t.titleSmall!, geometry.titleSmall),
            bodyLarge: t.bodyLarge == null ? null : style(t.bodyLarge!, geometry.bodyLarge),
            bodyMedium: t.bodyMedium == null ? null : style(t.bodyMedium!, geometry.bodyMedium),
            bodySmall: t.bodySmall == null ? null : style(t.bodySmall!, geometry.bodySmall),
            labelLarge: t.labelLarge == null ? null : style(t.labelLarge!, geometry.labelLarge),
            labelMedium: t.labelMedium == null ? null : style(t.labelMedium!, geometry.labelMedium),
            labelSmall: t.labelSmall == null ? null : style(t.labelSmall!, geometry.labelSmall),
          );
      theme = theme.copyWith(textTheme: all(theme.textTheme), primaryTextTheme: all(theme.primaryTextTheme));
    }
    if (radius case final r?) {
      final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(r));
      final big = RoundedRectangleBorder(borderRadius: BorderRadius.circular(r * 1.4));
      theme = theme.copyWith(
        filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(shape: shape)),
        elevatedButtonTheme: ElevatedButtonThemeData(style: ElevatedButton.styleFrom(shape: shape)),
        outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(shape: shape)),
        textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(shape: shape)),
        segmentedButtonTheme: SegmentedButtonThemeData(style: SegmentedButton.styleFrom(shape: shape)),
        cardTheme: theme.cardTheme.copyWith(shape: shape),
        dialogTheme: theme.dialogTheme.copyWith(shape: big),
        chipTheme: theme.chipTheme.copyWith(shape: shape),
        popupMenuTheme: theme.popupMenuTheme.copyWith(shape: shape),
        tooltipTheme: theme.tooltipTheme.copyWith(
          decoration: BoxDecoration(
            color: dark ? const Color(0xF0303030) : const Color(0xF0616161),
            borderRadius: BorderRadius.circular(r / 2),
          ),
        ),
        inputDecorationTheme: theme.inputDecorationTheme.copyWith(
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(r)),
        ),
      );
    }
    return theme;
  }
}

/// Что темы задают помимо ThemeData: цвета визуализации музыки.
@immutable
class LauncherExtras extends ThemeExtension<LauncherExtras> {
  final Color? visualizerTop;
  final Color? visualizerBottom;

  /// Скругление углов темы (для своих кнопок, например вкладок); null — как обычно.
  final double? radius;
  const LauncherExtras({this.visualizerTop, this.visualizerBottom, this.radius});

  @override
  LauncherExtras copyWith({Color? visualizerTop, Color? visualizerBottom, double? radius}) => LauncherExtras(
        visualizerTop: visualizerTop ?? this.visualizerTop,
        visualizerBottom: visualizerBottom ?? this.visualizerBottom,
        radius: radius ?? this.radius,
      );

  @override
  LauncherExtras lerp(LauncherExtras? other, double t) => t < 0.5 || other == null ? this : other;
}

/// Все темы: встроенные и из папок `themes`.
class AppThemes {
  AppThemes._();

  static const String deepOrange = 'deepOrange';
  static const String blue = 'blue';
  static const String green = 'green';
  static const String purple = 'purple';

  static const builtIn = [
    LauncherTheme(key: deepOrange, name: 'Deep Orange', seed: Colors.deepOrange),
    LauncherTheme(key: blue, name: 'Cyber Blue', seed: Colors.blue),
    LauncherTheme(key: green, name: 'Emerald Green', seed: Colors.green),
    LauncherTheme(key: purple, name: 'Purple Night', seed: Colors.purple),
  ];

  /// Встроенные и найденные в папках; файлы с ошибкой — в [errors].
  static List<LauncherTheme> all = List.of(builtIn);
  static final Map<String, String> errors = {};

  /// Код выбранной игры: у темы может быть своя картинка для игры.
  static final currentGame = ValueNotifier<String>('srb2');

  /// Загруженные файлы шрифтов: путь → семейство.
  static final Map<String, String> loadedFonts = {};

  static LauncherTheme byKey(String key) =>
      all.where((t) => t.key == key).firstOrNull ?? builtIn.first;

  static ThemeData getThemeData(String key) => byKey(key).data;

  /// Загружает шрифт темы из файла (один раз); без файла — ничего.
  static Future<void> ensureFont(LauncherTheme t) async {
    if (!t.fontIsFile) return;
    final file = t.resolve(t.font)!;
    if (loadedFonts.containsKey(file)) return;
    try {
      final bytes = await File(file).readAsBytes();
      final family = 'srb2al_theme_font_${loadedFonts.length}';
      final loader = FontLoader(family)..addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
      loadedFonts[file] = family;
    } catch (e) {
      debugPrint('theme font $file: $e');
    }
  }

  /// Папка тем рядом с лаунчером (идёт со сборкой; при запуске из
  /// исходников — в текущей папке).
  static Directory get bundledDir {
    final candidates = [
      p.join(p.dirname(Platform.resolvedExecutable), 'themes'),
      p.join(Directory.current.path, 'themes'),
    ];
    for (final c in candidates) {
      if (Directory(c).existsSync()) return Directory(c);
    }
    return Directory(candidates.first);
  }

  /// Свои темы: папка `themes` в данных лаунчера.
  static Future<Directory> userDir() async =>
      Directory(p.join((await getApplicationSupportDirectory()).path, 'themes'));

  static String keyOf(String path) => 'file:${p.basenameWithoutExtension(path).toLowerCase()}';

  /// Ищет темы в папках (свои важнее идущих со сборкой с тем же именем файла).
  static Future<void> load() async {
    final found = <String, LauncherTheme>{};
    errors.clear();
    Future<void> scan(Directory dir, bool editable) async {
      try {
        if (!await dir.exists()) return;
        final files = await dir.list().where((e) => e is File && p.extension(e.path).toLowerCase() == '.json').toList();
        files.sort((a, b) => a.path.compareTo(b.path));
        for (final f in files) {
          try {
            final j = jsonDecode(await (f as File).readAsString());
            if (j is! Map) throw const FormatException('not a JSON object');
            final t = LauncherTheme.fromJson(Map<String, dynamic>.from(j), key: keyOf(f.path), path: f.path, editable: editable);
            await ensureFont(t);
            found[t.key] = t;
          } catch (e) {
            errors[f.path] = e is FormatException ? e.message : '$e';
          }
        }
      } catch (_) {}
    }

    await scan(bundledDir, false);
    await scan(await userDir(), true);
    all = [...builtIn, ...found.values];
  }

  /// Сохраняет свою тему (новую — под свободным именем файла). Картинки и
  /// шрифт из других папок копируются к ней (`<имя темы>-<файл>`). Новая тема.
  static Future<LauncherTheme> save(LauncherTheme t) async {
    final dir = await userDir();
    await dir.create(recursive: true);
    var path = t.editable ? t.path : null;
    if (path == null) {
      final base = t.name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9а-яё]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
      final stem = base.isEmpty ? 'theme' : base;
      var i = 1;
      do {
        path = p.join(dir.path, '${i == 1 ? stem : '${stem}_$i'}.json');
        i++;
      } while (File(path).existsSync() || all.any((x) => x.key == keyOf(path!)));
    }
    final stem = p.basenameWithoutExtension(path);

    // Новая тема на основе другой: её файлы копируются, а не делятся — иначе
    // удаление исходной темы унесло бы и их.
    final fromStem = t.path == null ? null : '${p.basenameWithoutExtension(t.path!)}-';

    /// Файл темы — в папку своих тем; путь — относительно неё.
    Future<String?> keep(String? file) async {
      final src = t.resolve(file);
      if (src == null) return null;
      if (t.editable && p.isWithin(dir.path, src)) return p.relative(src, from: dir.path);
      if (!File(src).existsSync()) return file;
      var base = p.basename(src);
      if (fromStem != null && base.startsWith(fromStem)) base = base.substring(fromStem.length);
      final name = '$stem-$base';
      await File(src).copy(p.join(dir.path, name));
      return name;
    }

    final images = <String, String>{};
    for (final e in t.backgroundImages.entries) {
      final v = await keep(e.value);
      if (v != null) images[e.key] = v;
    }
    final kept = t.copyWith(
      backgroundImage: () => null,
      backgroundImages: images,
      font: () => null,
    );
    final image = await keep(t.backgroundImage);
    final font = t.fontIsFile ? await keep(t.font) : t.font;
    final json = kept.copyWith(backgroundImage: () => image, font: () => font).toJson();
    await File(path).writeAsString('${const JsonEncoder.withIndent('  ').convert(json)}\n');
    final saved = LauncherTheme.fromJson(json, key: keyOf(path), path: path, editable: true);
    await ensureFont(saved);
    all = [for (final x in all) if (x.key != saved.key) x, saved];
    return saved;
  }

  static Future<void> delete(LauncherTheme t) async {
    if (!t.editable || t.path == null) return;
    try {
      await File(t.path!).delete();
      // Файлы, скопированные для этой темы.
      final stem = p.basenameWithoutExtension(t.path!);
      for (final e in Directory(p.dirname(t.path!)).listSync()) {
        if (e is File && p.basename(e.path).startsWith('$stem-')) await e.delete();
      }
    } catch (_) {}
    all = [for (final x in all) if (x.key != t.key) x];
    // Была такая же тема со сборкой — она снова видна.
    await load();
  }
}

/// Фон окна темы: цвет, картинка (своя у игры), затемнение и размытие.
/// Рисуется под окном лаунчера ([LauncherTheme.data] делает его прозрачным).
class ThemeBackground extends StatelessWidget {
  final LauncherTheme theme;
  final Widget child;
  const ThemeBackground({super.key, required this.theme, required this.child});

  @override
  Widget build(BuildContext context) {
    if (!theme.hasImages && !theme.usesBackdrop) return child;
    return ValueListenableBuilder<String>(
      valueListenable: AppThemes.currentGame,
      builder: (context, game, _) {
        final image = theme.imageFor(game);
        final bg = theme.windowBackground;
        // С подложкой Windows фон полупрозрачный: сквозь него видно Mica/Acrylic.
        final base = theme.usesBackdrop ? bg.withValues(alpha: theme.backdropOpacity) : bg;
        return Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: base),
            if (image != null) ...[
              // Своя граница перерисовки: фон рисуется один раз, а не с каждым кадром окна.
              RepaintBoundary(
                child: _BackgroundPicture(
                  path: image,
                  fit: theme.backgroundFit,
                  scale: theme.backgroundScale,
                  blur: theme.backgroundBlur,
                ),
              ),
              ColoredBox(color: bg.withValues(alpha: theme.backgroundDim)),
            ],
            child,
          ],
        );
      },
    );
  }
}

/// Картинка фона. Чтобы не держать сотни мегабайт: файл декодируется один
/// раз и сразу уменьшенным (на всё окно — до размера экрана, плитка и центр —
/// не больше 2048 px), размытие тоже применяется один раз к готовой картинке,
/// а не к слою размером с окно на каждом кадре.
class _BackgroundPicture extends StatefulWidget {
  final String path;
  final String fit;
  final double scale;
  final double blur;
  const _BackgroundPicture({required this.path, required this.fit, required this.scale, required this.blur});

  @override
  State<_BackgroundPicture> createState() => _BackgroundPictureState();
}

class _BackgroundPictureState extends State<_BackgroundPicture> {
  ui.Image? _image;

  /// Пикселей картинки на логический пиксель экрана (для [RawImage.scale]).
  double _pixelsPerPoint = 1;
  String? _loaded;
  int _generation = 0;

  String get _key => '${widget.path}|${widget.fit}|${widget.scale}|${widget.blur}';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded != _key) _load();
  }

  @override
  void didUpdateWidget(_BackgroundPicture old) {
    super.didUpdateWidget(old);
    if (_loaded != _key) _load();
  }

  @override
  void dispose() {
    _generation++;
    _image?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final key = _key;
    _loaded = key;
    final gen = ++_generation;
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    final display = ui.PlatformDispatcher.instance.displays.firstOrNull?.size ?? const Size(2560, 1440);
    final cover = widget.fit == 'cover';
    try {
      final bytes = await File(widget.path).readAsBytes();
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      var natural = 0;
      final codec = await ui.instantiateImageCodecWithSize(buffer, getTargetSize: (w, h) {
        natural = w;
        // На всё окно: не больше экрана (с запасом на его сторону); иначе — не больше 2048.
        final limit = cover
            ? math.max(display.width / w, display.height / h)
            : math.min(2048 / w, 2048 / h);
        final k = math.min(1.0, limit);
        return ui.TargetImageSize(width: math.max(1, (w * k).round()), height: math.max(1, (h * k).round()));
      });
      var image = (await codec.getNextFrame()).image;
      codec.dispose();
      // Плитка и центр: на экране картинка в scale раз больше своих пикселей.
      final perPoint = cover ? 1.0 : image.width / (math.max(1, natural) * widget.scale);
      if (widget.blur > 0) {
        // Размытие в пикселях картинки; у плитки края переходят друг в друга.
        final sigma = cover ? widget.blur * dpr * image.width / math.max(1.0, display.width) : widget.blur * perPoint;
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawImage(
          image,
          Offset.zero,
          Paint()
            ..imageFilter = ui.ImageFilter.blur(
              sigmaX: math.max(0.1, sigma),
              sigmaY: math.max(0.1, sigma),
              tileMode: widget.fit == 'tile' ? TileMode.repeated : TileMode.clamp,
            ),
        );
        final picture = recorder.endRecording();
        final blurred = await picture.toImage(image.width, image.height);
        picture.dispose();
        image.dispose();
        image = blurred;
      }
      if (!mounted || gen != _generation) {
        image.dispose();
        return;
      }
      final old = _image;
      setState(() {
        _image = image;
        _pixelsPerPoint = perPoint;
      });
      old?.dispose();
    } catch (e) {
      debugPrint('theme background ${widget.path}: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) return const SizedBox.expand();
    final tile = widget.fit == 'tile';
    return SizedBox.expand(
      child: RawImage(
        image: image,
        scale: widget.fit == 'cover' ? 1 : _pixelsPerPoint,
        fit: widget.fit == 'cover' ? BoxFit.cover : BoxFit.none,
        repeat: tile ? ImageRepeat.repeat : ImageRepeat.noRepeat,
        alignment: tile ? Alignment.topLeft : Alignment.center,
        filterQuality: FilterQuality.medium,
      ),
    );
  }
}

