import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../i18n.dart';
import '../models/game.dart';
import '../services/app_log.dart';
import '../services/system_fonts.dart';
import '../theme/app_themes.dart';
import 'appearance_pickers.dart' show themeName;

/// Редактор темы: название, тёмная/светлая, цвета; справа — как это выглядит.
/// [base] — своя тема (правится она) или любая другая (сохраняется новой).
/// [asNew] — всегда новая тема на основе [base], даже своей: она сама не
/// меняется. Сохранённая тема или null.
Future<LauncherTheme?> showThemeEditor(BuildContext context, LauncherTheme base, {bool asNew = false}) =>
    showDialog<LauncherTheme>(
      context: context,
      builder: (_) => _ThemeEditor(base: base, asNew: asNew || !base.editable),
    );

class _ThemeEditor extends StatefulWidget {
  final LauncherTheme base;
  final bool asNew;
  const _ThemeEditor({required this.base, required this.asNew});

  @override
  State<_ThemeEditor> createState() => _ThemeEditorState();
}

class _ThemeEditorState extends State<_ThemeEditor> {
  // Новая тема — не своя: сохранится в свободный файл. Путь остаётся, чтобы
  // находились картинки и шрифт исходной темы.
  late LauncherTheme _t = widget.asNew
      ? widget.base.copyWith(name: tr('{name} (copy)', {'name': themeName(widget.base)}), editable: false)
      : widget.base;
  late final _name = TextEditingController(text: _t.name);
  late final _font = TextEditingController(text: _t.font ?? '');
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _font.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = tr('Enter a name'));
      return;
    }
    setState(() => _saving = true);
    try {
      final saved = await AppThemes.save(_t.copyWith(name: name));
      if (mounted) Navigator.pop(context, saved);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _t.copyWith(name: _name.text);
    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 980,
        height: (MediaQuery.sizeOf(context).height - 48).clamp(360, 680).toDouble(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
              child: Text(
                widget.asNew ? tr('New theme') : tr('Edit theme'),
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
            ),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 440,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(24, 8, 16, 16),
                      children: [
                        TextField(
                          controller: _name,
                          onChanged: (_) => setState(() => _error = null),
                          decoration: InputDecoration(
                            labelText: tr('Name'),
                            errorText: _error,
                            isDense: true,
                            border: const OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 14),
                        SegmentedButton<bool>(
                          segments: [
                            ButtonSegment(
                              value: true,
                              icon: const Icon(Icons.dark_mode_outlined),
                              label: Text(tr('Dark')),
                            ),
                            ButtonSegment(
                              value: false,
                              icon: const Icon(Icons.light_mode_outlined),
                              label: Text(tr('Light')),
                            ),
                          ],
                          selected: {_t.dark},
                          onSelectionChanged: (v) => setState(() => _t = _t.copyWith(dark: v.first)),
                        ),
                        const SizedBox(height: 10),
                        _colorRow(
                          tr('Main color'),
                          tr('All shades are made from it.'),
                          _t.seed,
                          (c) => _t = _t.copyWith(seed: c!),
                          optional: false,
                        ),
                        _colorRow(
                          tr('Accent'),
                          tr('Buttons, selection, the current tab.'),
                          _t.accent,
                          (c) => _t = _t.copyWith(accent: () => c),
                        ),
                        _colorRow(
                          tr('Background'),
                          tr('The window background.'),
                          _t.background,
                          (c) => _t = _t.copyWith(background: () => c),
                        ),
                        _colorRow(
                          tr('Panels'),
                          tr('Cards, dialogs, buttons of the tabs.'),
                          _t.panels,
                          (c) => _t = _t.copyWith(panels: () => c),
                        ),
                        _colorRow(tr('Text'), null, _t.text, (c) => _t = _t.copyWith(text: () => c)),
                        ..._backgroundSection(),
                        ..._fontSection(),
                        ..._shapeSection(),
                        ..._windowSection(),
                        ..._visualizerSection(),
                      ],
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: _ThemePreview(preview)),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      tr('Saved to the themes folder of the launcher data.'),
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                  TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: _saving ? null : _save, child: Text(tr('Save'))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Строка цвета: образец (нажать — выбрать), сброс у необязательных.
  Widget _colorRow(String title, String? hint, Color? color, void Function(Color?) set, {bool optional = true}) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text(
        color == null
            ? tr('Automatic (from the main color)')
            : LauncherTheme.hex(color) + (hint == null ? '' : ' · $hint'),
        style: const TextStyle(fontSize: 12),
      ),
      leading: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => _pick(title, color, set),
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            border: Border.all(color: Colors.grey),
          ),
          child: color == null ? const Icon(Icons.auto_awesome, size: 16, color: Colors.grey) : null,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.colorize_outlined),
            tooltip: tr('Choose a color'),
            onPressed: () => _pick(title, color, set),
          ),
          if (optional && color != null)
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: tr('Automatic'),
              onPressed: () => setState(() => set(null)),
            ),
        ],
      ),
    );
  }

  Future<void> _pick(String title, Color? color, void Function(Color?) set) async {
    final c = await showColorPicker(context, title, color ?? _t.colorScheme.primary);
    if (c != null && mounted) setState(() => set(c));
  }

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.only(top: 18, bottom: 4),
    child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
  );

  Widget _hint(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(text, style: const TextStyle(fontSize: 12, color: Colors.grey)),
  );

  /// Ползунок с подписью и значением.
  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    String Function(double) shown,
    ValueChanged<double> onChanged, {
    int? divisions,
  }) => Row(
    children: [
      SizedBox(width: 150, child: Text(label, style: const TextStyle(fontSize: 13))),
      Expanded(
        child: Slider(value: value.clamp(min, max), min: min, max: max, divisions: divisions, onChanged: onChanged),
      ),
      SizedBox(
        width: 48,
        child: Text(shown(value), textAlign: TextAlign.end, style: const TextStyle(fontSize: 12)),
      ),
    ],
  );

  /// Выбор файла картинки или шрифта; путь или null.
  Future<String?> _file(String label, List<String> extensions) async {
    AppLog.action('open the openFile dialog (theme_editor.dart)');
    final f = await openFile(
      acceptedTypeGroups: [XTypeGroup(label: label, extensions: extensions)],
    );
    return f?.path;
  }

  static const _imageTypes = ['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'];

  /// Строка файла: имя, «Выбрать», «Убрать».
  Widget _fileRow(String title, String? file, Future<void> Function() choose, VoidCallback? clear) => ListTile(
    contentPadding: EdgeInsets.zero,
    dense: true,
    title: Text(title),
    subtitle: Text(file == null ? tr('None') : p.basename(file), overflow: TextOverflow.ellipsis),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(icon: const Icon(Icons.image_outlined), tooltip: tr('Choose a file'), onPressed: choose),
        if (file != null && clear != null)
          IconButton(icon: const Icon(Icons.close), tooltip: tr('Remove'), onPressed: clear),
      ],
    ),
  );

  List<Widget> _backgroundSection() => [
    _section(tr('Background image')),
    _hint(tr('A picture behind the window. A game can have its own picture.')),
    _fileRow(tr('For all games'), _t.backgroundImage, () async {
      final f = await _file(tr('Images'), _imageTypes);
      if (f != null && mounted) setState(() => _t = _t.copyWith(backgroundImage: () => f));
    }, () => setState(() => _t = _t.copyWith(backgroundImage: () => null))),
    ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text(tr('Pictures for games'), style: const TextStyle(fontSize: 14)),
      subtitle: _t.backgroundImages.isEmpty
          ? null
          : Text(tr('{n} game(s)', {'n': _t.backgroundImages.length}), style: const TextStyle(fontSize: 12)),
      children: [
        for (final g in Games.enabled)
          _fileRow(g.name, _t.backgroundImages[g.id], () async {
            final f = await _file(tr('Images'), _imageTypes);
            if (f != null && mounted) {
              setState(() => _t = _t.copyWith(backgroundImages: {..._t.backgroundImages, g.id: f}));
            }
          }, () => setState(() => _t = _t.copyWith(backgroundImages: {..._t.backgroundImages}..remove(g.id)))),
      ],
    ),
    if (_t.hasImages) ...[
      _slider(
        tr('Dimming'),
        _t.backgroundDim,
        0,
        1,
        (v) => '${(v * 100).round()}%',
        (v) => setState(() => _t = _t.copyWith(backgroundDim: v)),
      ),
      _slider(
        tr('Blur'),
        _t.backgroundBlur,
        0,
        20,
        (v) => v.round().toString(),
        (v) => setState(() => _t = _t.copyWith(backgroundBlur: v)),
        divisions: 20,
      ),
      const SizedBox(height: 6),
      SegmentedButton<String>(
        segments: [
          ButtonSegment(value: 'cover', icon: const Icon(Icons.fit_screen_outlined), label: Text(tr('Fill'))),
          ButtonSegment(value: 'tile', icon: const Icon(Icons.grid_view), label: Text(tr('Tile'))),
          ButtonSegment(
            value: 'center',
            icon: const Icon(Icons.center_focus_strong_outlined),
            label: Text(tr('Center')),
          ),
        ],
        selected: {_t.backgroundFit},
        onSelectionChanged: (v) => setState(() => _t = _t.copyWith(backgroundFit: v.first)),
      ),
      if (_t.backgroundFit != 'cover')
        _slider(
          tr('Picture size'),
          _t.backgroundScale,
          0.25,
          4,
          (v) => '${(v * 100).round()}%',
          (v) => setState(() => _t = _t.copyWith(backgroundScale: (v * 20).round() / 20)),
        ),
    ],
  ];

  List<Widget> _fontSection() => [
    _section(tr('Font')),
    _hint(tr('The name of a font installed in the system, or a font file (.ttf, .otf).')),
    Row(
      children: [
        Expanded(
          child: TextField(
            controller: _font,
            onChanged: (v) => setState(() => _t = _t.copyWith(font: () => v.trim().isEmpty ? null : v.trim())),
            decoration: InputDecoration(hintText: tr('Default'), isDense: true, border: const OutlineInputBorder()),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.list_alt),
          tooltip: tr('Fonts of the system...'),
          onPressed: () async {
            final name = await showSystemFontPicker(context, _t.fontIsFile ? null : _t.font);
            if (name == null || !mounted) return;
            setState(() {
              _t = _t.copyWith(font: () => name.isEmpty ? null : name);
              _font.text = name;
            });
          },
        ),
        IconButton(
          icon: const Icon(Icons.font_download_outlined),
          tooltip: tr('Font file...'),
          onPressed: () async {
            final f = await _file(tr('Fonts'), const ['ttf', 'otf']);
            if (f == null || !mounted) return;
            final t = _t.copyWith(font: () => f);
            await AppThemes.ensureFont(t);
            if (!mounted) return;
            setState(() {
              _t = t;
              _font.text = f;
            });
          },
        ),
      ],
    ),
    _slider(
      tr('Text size'),
      _t.textScale,
      0.8,
      1.4,
      (v) => '${(v * 100).round()}%',
      (v) => setState(() => _t = _t.copyWith(textScale: (v * 20).round() / 20)),
      divisions: 12,
    ),
    _slider(
      tr('Thickness'),
      _t.fontWeight.toDouble(),
      -3,
      3,
      (v) => v == 0 ? '0' : (v > 0 ? '+${v.round()}' : '${v.round()}'),
      (v) => setState(() => _t = _t.copyWith(fontWeight: v.round())),
      divisions: 6,
    ),
    _slider(
      tr('Letter spacing'),
      _t.letterSpacing,
      -1,
      4,
      (v) => v.toStringAsFixed(2),
      (v) => setState(() => _t = _t.copyWith(letterSpacing: (v * 4).round() / 4)),
      divisions: 20,
    ),
    SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      value: _t.textShadow != null,
      onChanged: (v) => setState(
        () => _t = _t.copyWith(
          textShadow: () => v ? const Shadow(color: Color(0xAA000000), blurRadius: 3, offset: Offset(1, 1)) : null,
        ),
      ),
      title: Text(tr('Text shadow')),
    ),
    if (_t.textShadow case final sh?) ...[
      _colorRow(
        tr('Shadow color'),
        null,
        sh.color,
        (c) => _t = _t.copyWith(
          textShadow: () => Shadow(color: c ?? const Color(0xAA000000), blurRadius: sh.blurRadius, offset: sh.offset),
        ),
        optional: false,
      ),
      _slider(
        tr('Shadow blur'),
        sh.blurRadius,
        0,
        12,
        (v) => v.toStringAsFixed(1),
        (v) => setState(
          () => _t = _t.copyWith(
            textShadow: () => Shadow(color: sh.color, blurRadius: (v * 2).round() / 2, offset: sh.offset),
          ),
        ),
        divisions: 24,
      ),
      _slider(
        tr('Shadow X'),
        sh.offset.dx,
        -6,
        6,
        (v) => v.toStringAsFixed(1),
        (v) => setState(
          () => _t = _t.copyWith(
            textShadow: () =>
                Shadow(color: sh.color, blurRadius: sh.blurRadius, offset: Offset((v * 2).round() / 2, sh.offset.dy)),
          ),
        ),
        divisions: 24,
      ),
      _slider(
        tr('Shadow Y'),
        sh.offset.dy,
        -6,
        6,
        (v) => v.toStringAsFixed(1),
        (v) => setState(
          () => _t = _t.copyWith(
            textShadow: () =>
                Shadow(color: sh.color, blurRadius: sh.blurRadius, offset: Offset(sh.offset.dx, (v * 2).round() / 2)),
          ),
        ),
        divisions: 24,
      ),
    ],
  ];

  List<Widget> _shapeSection() => [
    _section(tr('Corners')),
    SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      value: _t.radius != null,
      onChanged: (v) => setState(() => _t = _t.copyWith(radius: () => v ? 12 : null)),
      title: Text(tr('Own corner rounding')),
      subtitle: Text(tr('Buttons, cards, windows and fields.')),
    ),
    if (_t.radius != null)
      _slider(
        tr('Rounding'),
        _t.radius!,
        0,
        28,
        (v) => v.round().toString(),
        (v) => setState(() => _t = _t.copyWith(radius: () => v.roundToDouble())),
        divisions: 28,
      ),
  ];

  List<Widget> _windowSection() => [
    _section(tr('Window')),
    _slider(
      tr('Opacity'),
      _t.windowOpacity,
      0.5,
      1,
      (v) => '${(v * 100).round()}%',
      (v) => setState(() => _t = _t.copyWith(windowOpacity: (v * 20).round() / 20)),
      divisions: 10,
    ),
    _hint(tr('The whole window, applied on saving. On Linux it needs a compositing window manager.')),
    const SizedBox(height: 6),
    Text(tr('Backdrop (Windows 11)'), style: const TextStyle(fontSize: 13)),
    const SizedBox(height: 4),
    SegmentedButton<String>(
      segments: [
        ButtonSegment(value: 'none', label: Text(tr('None'))),
        const ButtonSegment(value: 'mica', label: Text('Mica')),
        const ButtonSegment(value: 'acrylic', label: Text('Acrylic')),
      ],
      selected: {_t.backdrop},
      onSelectionChanged: Platform.isWindows ? (v) => setState(() => _t = _t.copyWith(backdrop: v.first)) : null,
    ),
    _hint(
      Platform.isWindows
          ? tr('Experimental: the window background lets the Windows backdrop through.')
          : tr('Only on Windows 11.'),
    ),
    if (_t.backdrop != 'none')
      _slider(
        tr('Backdrop tint'),
        _t.backdropOpacity,
        0,
        0.9,
        (v) => '${(v * 100).round()}%',
        (v) => setState(() => _t = _t.copyWith(backdropOpacity: (v * 20).round() / 20)),
      ),
    if (_t.backdrop != 'none')
      _hint(
        tr(
          'How much the theme background covers the blurred backdrop: 0% — only the backdrop. The blur '
          'strength itself is set by Windows.',
        ),
      ),
  ];

  List<Widget> _visualizerSection() => [
    _section(tr('Music visualizer')),
    _colorRow(tr('Top of the bars'), null, _t.visualizer.firstOrNull, (c) {
      final rest = _t.visualizer.length > 1 ? [_t.visualizer[1]] : const <Color>[];
      _t = _t.copyWith(visualizer: c == null ? const [] : [c, ...rest]);
    }),
    _colorRow(tr('Bottom of the bars'), null, _t.visualizer.length > 1 ? _t.visualizer[1] : null, (c) {
      final top = _t.visualizer.firstOrNull ?? _t.colorScheme.primary;
      _t = _t.copyWith(visualizer: c == null ? [top] : [top, c]);
    }),
  ];
}

/// Как выглядит тема: шапка с вкладками, карточка, кнопки.
class _ThemePreview extends StatelessWidget {
  final LauncherTheme theme;
  const _ThemePreview(this.theme);

  @override
  Widget build(BuildContext context) {
    final data = theme.data;
    return Theme(
      data: data,
      child: Builder(
        builder: (context) {
          final scheme = Theme.of(context).colorScheme;
          Widget tab(String label, bool on) => Padding(
            padding: const EdgeInsets.only(left: 6),
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: on ? scheme.primary : scheme.surfaceContainerHighest,
                foregroundColor: on ? scheme.onPrimary : scheme.onSurface.withValues(alpha: 0.75),
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(theme.radius ?? 6)),
              ),
              onPressed: () {},
              child: Text(label),
            ),
          );
          // Как в окне: масштаб текста и фон (картинка, затемнение).
          return ThemeBackground(
            theme: theme,
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(theme.textScale)),
              child: Material(
                color: data.scaffoldBackgroundColor,
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Sonic Robo Blast 2',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 18, color: scheme.onSurface),
                          ),
                        ),
                        tab(tr('Addons'), true),
                        tab(tr('Launch'), false),
                        tab(tr('Servers'), false),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Mystic Realm', style: Theme.of(context).textTheme.titleMedium),
                            const SizedBox(height: 4),
                            const Text('v5.1 · 12.4 MiB', style: TextStyle(color: Colors.grey, fontSize: 12)),
                            const SizedBox(height: 10),
                            const Wrap(
                              spacing: 6,
                              children: [
                                Chip(label: Text('Level pack'), visualDensity: VisualDensity.compact),
                                Chip(label: Text('Co-op'), visualDensity: VisualDensity.compact),
                              ],
                            ),
                            const SizedBox(height: 10),
                            const LinearProgressIndicator(value: 0.6),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                FilledButton.icon(
                                  onPressed: () {},
                                  icon: const Icon(Icons.download),
                                  label: Text(tr('Download')),
                                ),
                                const SizedBox(width: 8),
                                OutlinedButton(onPressed: () {}, child: Text(tr('Cancel'))),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      value: true,
                      onChanged: (_) {},
                      title: Text(tr('Music player')),
                      subtitle: Text(
                        tr('Features that are still being tried out. They are off until you turn them on.'),
                      ),
                    ),
                    ListTile(
                      leading: Icon(Icons.dns_outlined, color: scheme.primary),
                      title: const Text('SRB2 Server'),
                      subtitle: const Text('localhost:5029', style: TextStyle(color: Colors.grey)),
                      trailing: const Text('37 ms', style: TextStyle(color: Colors.green)),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Выбор цвета: образцы, оттенок/насыщенность/яркость и HEX.
Future<Color?> showColorPicker(BuildContext context, String title, Color initial) => showDialog<Color>(
  context: context,
  builder: (_) => _ColorPicker(title: title, initial: initial),
);

class _ColorPicker extends StatefulWidget {
  final String title;
  final Color initial;
  const _ColorPicker({required this.title, required this.initial});

  @override
  State<_ColorPicker> createState() => _ColorPickerState();
}

class _ColorPickerState extends State<_ColorPicker> {
  late HSVColor _hsv = HSVColor.fromColor(widget.initial.withValues(alpha: 1));
  late final _hex = TextEditingController(text: LauncherTheme.hex(_hsv.toColor()));

  static const _swatches = [
    Color(0xFF000000), Color(0xFF0B0B0B), Color(0xFF141218), Color(0xFF1E1E1E), Color(0xFF2B2B2B), //
    Color(0xFFF4F6FB), Color(0xFFFFFFFF), Color(0xFFE53935), Color(0xFFFF5722), Color(0xFFFF9800), //
    Color(0xFFFFC107), Color(0xFFFFEB3B), Color(0xFF8BC34A), Color(0xFF4CAF50), Color(0xFF009688), //
    Color(0xFF00BCD4), Color(0xFF2196F3), Color(0xFF1E5BFF), Color(0xFF3F51B5), Color(0xFF673AB7), //
    Color(0xFF9C27B0), Color(0xFFE91E63), Color(0xFF795548), Color(0xFF607D8B), Color(0xFF9E9E9E),
  ];

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  void _set(HSVColor v, {bool fromHex = false}) {
    setState(() => _hsv = v);
    if (!fromHex) _hex.text = LauncherTheme.hex(v.toColor());
  }

  Widget _slider(String label, double value, double max, ValueChanged<double> onChanged) => Row(
    children: [
      SizedBox(width: 116, child: Text(label, style: const TextStyle(fontSize: 13))),
      Expanded(
        child: Slider(value: value, max: max, onChanged: onChanged),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final color = _hsv.toColor();
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final c in _swatches)
                  InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => _set(HSVColor.fromColor(c)),
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: c == color ? Theme.of(context).colorScheme.primary : Colors.grey,
                          width: c == color ? 3 : 1,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            _slider(tr('Hue'), _hsv.hue, 360, (v) => _set(_hsv.withHue(v))),
            _slider(tr('Saturation'), _hsv.saturation, 1, (v) => _set(_hsv.withSaturation(v))),
            _slider(tr('Brightness'), _hsv.value, 1, (v) => _set(_hsv.withValue(v))),
            const SizedBox(height: 8),
            Row(
              children: [
                Container(
                  width: 56,
                  height: 40,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _hex,
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[#0-9a-fA-F]'))],
                    onChanged: (v) {
                      final c = LauncherTheme.parseColor(v);
                      if (c != null) _set(HSVColor.fromColor(c), fromHex: true);
                    },
                    decoration: const InputDecoration(labelText: 'HEX', isDense: true, border: OutlineInputBorder()),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
        FilledButton(onPressed: () => Navigator.pop(context, color), child: Text(tr('OK'))),
      ],
    );
  }
}

/// Выбор шрифта системы: поиск, каждый шрифт — своим начертанием.
/// Название, пустая строка (по умолчанию) или null (отмена).
Future<String?> showSystemFontPicker(BuildContext context, String? current) => showDialog<String>(
  context: context,
  builder: (_) => _SystemFontPicker(current: current),
);

class _SystemFontPicker extends StatefulWidget {
  final String? current;
  const _SystemFontPicker({this.current});

  @override
  State<_SystemFontPicker> createState() => _SystemFontPickerState();
}

class _SystemFontPickerState extends State<_SystemFontPicker> {
  final _search = TextEditingController();
  late final Future<List<String>> _fonts = SystemFonts.list();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('Fonts of the system')),
      content: SizedBox(
        width: 480,
        height: 460,
        child: Column(
          children: [
            TextField(
              controller: _search,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: tr('Search'),
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: FutureBuilder<List<String>>(
                future: _fonts,
                builder: (context, snap) {
                  if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                  final q = _search.text.trim().toLowerCase();
                  final list = [
                    for (final f in snap.data!)
                      if (q.isEmpty || f.toLowerCase().contains(q)) f,
                  ];
                  if (snap.data!.isEmpty) {
                    return Center(
                      child: Text(tr('Could not get the list of fonts.'), style: const TextStyle(color: Colors.grey)),
                    );
                  }
                  return ListView.builder(
                    itemCount: list.length + 1,
                    itemBuilder: (context, i) {
                      if (i == 0) {
                        return ListTile(
                          dense: true,
                          selected: widget.current == null,
                          title: Text(tr('Default')),
                          onTap: () => Navigator.pop(context, ''),
                        );
                      }
                      final f = list[i - 1];
                      return ListTile(
                        dense: true,
                        selected: f == widget.current,
                        title: Text(f, style: TextStyle(fontFamily: f, fontSize: 16)),
                        subtitle: Text(f, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                        onTap: () => Navigator.pop(context, f),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel')))],
    );
  }
}
