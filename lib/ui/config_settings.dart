import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../i18n.dart';
import '../models/game.dart';
import '../models/launch_config.dart';
import '../services/gamepad_service.dart';
import '../services/launch_settings.dart';
import '../services/srb2_config.dart';
import '../services/srb2_config_schema.dart';
import 'color_picker.dart';
import 'color_preview.dart';
import 'file_actions.dart';
import 'gamepad_tester_dialog.dart';
import 'snack.dart';

/// Редактор конфига игры (`config.cfg` и совместимые `.cfg`) в Настройках.
///
/// Изменения не записываются на диск до нажатия «Save»; состояние [isDirty]
/// передаётся наружу через [onDirtyChanged], чтобы диалог настроек не дал
/// уйти без сохранения или сброса.
class ConfigSettings extends StatefulWidget {
  final GameDef game;
  final String? gameFolder;
  final LaunchSettings? launch;
  final VoidCallback onConfigureFolder;
  final ValueChanged<bool> onDirtyChanged;

  const ConfigSettings({
    super.key,
    required this.game,
    required this.gameFolder,
    required this.launch,
    required this.onConfigureFolder,
    required this.onDirtyChanged,
  });

  @override
  State<ConfigSettings> createState() => ConfigSettingsState();
}

enum _AllVarFilter { all, modified, extra }

class ConfigSettingsState extends State<ConfigSettings> {
  Srb2ConfigDocument? _doc;
  String? _loadError;
  bool _loading = false;
  bool _saving = false;
  bool _hasBackup = false;
  ConfigSubTab _tab = ConfigSubTab.video;
  int _controlPlayer = 1;
  _AllVarFilter _allFilter = _AllVarFilter.all;

  final _searchCtrl = TextEditingController();
  final _controlsSearchCtrl = TextEditingController();
  final _tabsScrollCtrl = ScrollController();
  final Map<String, TextEditingController> _valueCtrls = {};
  late GameConfigSchema _schema = Srb2ConfigSchema.forGame(widget.game);

  bool get isDirty => _doc?.isDirty ?? false;

  @override
  void initState() {
    super.initState();
    _load(fromBuild: true);
  }

  @override
  void didUpdateWidget(ConfigSettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.game.id != widget.game.id || oldWidget.gameFolder != widget.gameFolder) {
      _schema = Srb2ConfigSchema.forGame(widget.game);
      if (_controlPlayer > _schema.maxPlayers) _controlPlayer = 1;
      _load(fromBuild: true);
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _controlsSearchCtrl.dispose();
    _tabsScrollCtrl.dispose();
    for (final c in _valueCtrls.values) {
      c.dispose();
    }
    _valueCtrls.clear();
    super.dispose();
  }

  void _notifyDirty() {
    widget.onDirtyChanged(_doc?.isDirty ?? false);
  }

  void _load({bool fromBuild = false}) {
    final folder = widget.gameFolder;
    final path = Srb2ConfigDocument.configPathFor(widget.game, folder);
    _loading = false;
    _loadError = null;
    _clearValueCtrls();

    if (path == null) {
      _doc = null;
      _hasBackup = false;
    } else {
      try {
        final doc = Srb2ConfigDocument.loadFileSync(path);
        _doc = doc;
        _hasBackup = doc.backupPath != null && File(doc.backupPath!).existsSync();
      } catch (e) {
        _doc = null;
        _loadError = e.toString();
        _hasBackup = false;
      }
    }

    if (fromBuild) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _notifyDirty();
      });
    } else {
      setState(() {});
      _notifyDirty();
    }
  }

  void _clearValueCtrls() {
    for (final c in _valueCtrls.values) {
      c.dispose();
    }
    _valueCtrls.clear();
  }

  void _syncValueCtrls() {
    final doc = _doc;
    if (doc == null) return;
    for (final entry in _valueCtrls.entries) {
      final val = doc.cvar(entry.key) ?? _defaultFor(entry.key);
      if (entry.value.text != val) {
        entry.value.text = val;
      }
    }
  }

  String _defaultFor(String name) => _schema.defaultFor(name) ?? '';

  TextEditingController _ctrlFor(String name, String initialValue) {
    final key = name.toLowerCase();
    return _valueCtrls.putIfAbsent(key, () => TextEditingController(text: initialValue));
  }

  void _setCvar(String name, String value, {bool syncController = false}) {
    final doc = _doc;
    if (doc == null) return;
    setState(() {
      doc.setCvar(name, value);
      if (syncController) {
        final c = _valueCtrls[name.toLowerCase()];
        if (c != null && c.text != value) c.text = value;
      }
    });
    _notifyDirty();
  }

  void _setControl(int player, String command, {String? primary, String? secondary}) {
    final doc = _doc;
    if (doc == null) return;
    setState(() {
      doc.setControl(player, command, primary: primary, secondary: secondary);
    });
    _notifyDirty();
  }

  /// Сбрасывает несохранённые правки до состояния на диске.
  void reset() {
    final doc = _doc;
    if (doc == null) return;
    setState(() {
      doc.reset();
      _syncValueCtrls();
    });
    _notifyDirty();
  }

  /// Записывает конфиг на диск (предварительно создав `.bak`).
  Future<bool> save() async {
    final doc = _doc;
    if (doc == null || _saving) return false;
    setState(() => _saving = true);
    try {
      final saved = doc.saveSync();
      final bakExists = saved.backupPath != null && File(saved.backupPath!).existsSync();
      if (!mounted) return true;
      setState(() {
        _doc = saved;
        _hasBackup = bakExists;
        _saving = false;
        _syncValueCtrls();
      });
      _notifyDirty();
      showSnack(
        context,
        SnackBar(content: Text(tr('Saved {file}', {'file': p.basename(saved.filePath!)}))),
      );
      return true;
    } catch (e) {
      if (!mounted) return false;
      setState(() => _saving = false);
      showSnack(
        context,
        SnackBar(content: Text(tr('Could not save config: {error}', {'error': e}))),
      );
      return false;
    }
  }

  Future<void> _restoreBackup() async {
    final bakPath = _doc?.backupPath;
    if (bakPath == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Restore backup?')),
        content: Text(tr('Values from {file} will be loaded into the editor. Press Save to write them to disk.',
            {'file': p.basename(bakPath)})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Restore'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final bakDoc = await Srb2ConfigDocument.loadFile(bakPath);
      setState(() {
        _doc?.applyFrom(bakDoc);
        _syncValueCtrls();
      });
      _notifyDirty();
    } catch (e) {
      if (!mounted) return;
      showSnack(context, SnackBar(content: Text(tr('Could not read backup: {error}', {'error': e}))));
    }
  }

  Future<void> _reloadFromDisk() async {
    if (isDirty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('Reload from disk?')),
          content: Text(tr('Unsaved changes in the editor will be lost.')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Reload'))),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    _load();
  }

  String? _launchOverrideNote(CvarSpec spec, String cvarName) {
    final opts = widget.launch?.options;
    if (opts == null) return null;
    final plusVal = opts.cvar(cvarName);
    if (plusVal.isNotEmpty) {
      return tr('Overridden by Launch (+{name} {val})', {'name': cvarName, 'val': plusVal});
    }
    switch (spec.launchOverride) {
      case 'renderer':
        if (opts.renderer == RendererMode.opengl) return tr('Overridden by Launch (-opengl)');
        if (opts.renderer == RendererMode.software) return tr('Overridden by Launch (-software)');
      case 'win':
        if (opts.has(LaunchFlags.windowed)) return tr('Overridden by Launch (-win)');
      case 'resolution':
        if (opts.customResolution) return tr('Overridden by Launch (-width / -height)');
      case 'nosound':
        if (opts.has(LaunchFlags.noSound)) return tr('Overridden by Launch (-nosound)');
      case 'nomusic':
        if (opts.has(LaunchFlags.noMusic)) return tr('Overridden by Launch (-nomusic)');
      case 'nomouse':
        if (opts.has(LaunchFlags.noMouse)) return tr('Overridden by Launch (-nomouse)');
      case 'nomousegrab':
        if (opts.has(LaunchFlags.noMouseGrab)) return tr('Overridden by Launch (-nomousegrab)');
      case 'nojoy':
        if (opts.has(LaunchFlags.noJoy)) return tr('Overridden by Launch (-nojoy)');
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.gameFolder == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.folder_off_outlined, size: 48, color: Colors.grey),
              const SizedBox(height: 12),
              Text(tr('Game folder is not configured for {game}.', {'game': widget.game.name}),
                  style: const TextStyle(fontSize: 15)),
              const SizedBox(height: 12),
              FilledButton.tonal(
                onPressed: widget.onConfigureFolder,
                child: Text(tr('Configure game folder')),
              ),
            ],
          ),
        ),
      );
    }

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(tr('Could not load config: {error}', {'error': _loadError!})),
              const SizedBox(height: 12),
              FilledButton.tonal(onPressed: _load, child: Text(tr('Retry'))),
            ],
          ),
        ),
      );
    }

    final doc = _doc;
    if (doc == null) return const SizedBox.shrink();

    final availableTabs = Srb2ConfigSchema.tabs;
    final activeTab = _tab;
    final cs = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Шапка файла и подсказки.
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 8, 32, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      doc.filePath!,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.grey),
                    ),
                  ),
                  if (_hasBackup)
                    TextButton.icon(
                      icon: const Icon(Icons.history, size: 18),
                      label: Text(tr('Restore backup')),
                      onPressed: _restoreBackup,
                    ),
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 20),
                    tooltip: tr('Reload from disk'),
                    onPressed: _reloadFromDisk,
                  ),
                  if (doc.existsOnDisk)
                    IconButton(
                      icon: const Icon(Icons.folder_open, size: 20),
                      tooltip: tr('Show in folder'),
                      onPressed: () => showFileInFolder(context, doc.filePath!),
                    ),
                ],
              ),
              if (!doc.existsOnDisk)
                _infoBanner(
                  Icons.info_outline,
                  cs.secondaryContainer,
                  tr('{file} was not found yet — it is created when the game runs, or you can save a new config now.',
                      {'file': Srb2ConfigDocument.configFileNameFor(widget.game)}),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    tr('Tip: close {game} before editing — the game overwrites its config file on exit.',
                        {'game': widget.game.name}),
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
            ],
          ),
        ),

        // Сабвкладки настроек: колёсико мыши над полосой крутит её по горизонтали.
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 4, 32, 4),
          child: Listener(
            onPointerSignal: (event) {
              if (event is PointerScrollEvent && _tabsScrollCtrl.hasClients) {
                final delta = event.scrollDelta.dy != 0 ? event.scrollDelta.dy : event.scrollDelta.dx;
                final max = _tabsScrollCtrl.position.maxScrollExtent;
                final next = (_tabsScrollCtrl.offset + delta).clamp(0.0, max);
                if (next != _tabsScrollCtrl.offset) {
                  _tabsScrollCtrl.jumpTo(next);
                }
              }
            },
            child: Scrollbar(
              controller: _tabsScrollCtrl,
              thickness: 4,
              radius: const Radius.circular(2),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(context).copyWith(
                    dragDevices: {PointerDeviceKind.touch, PointerDeviceKind.mouse},
                  ),
                  child: SingleChildScrollView(
                    controller: _tabsScrollCtrl,
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final (tab, label) in availableTabs)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ChoiceChip(
                              label: Text(tr(label)),
                              selected: activeTab == tab,
                              onSelected: (_) => setState(() => _tab = tab),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const Divider(height: 1),

        // Содержимое активной сабвкладки.
        Expanded(
          child: switch (activeTab) {
            ConfigSubTab.controls => _buildControlsTab(doc),
            ConfigSubTab.all => _buildAllVarsTab(doc),
            _ => _buildCuratedTab(doc, activeTab),
          },
        ),

        // Панель Сохранить / Сбросить.
        Container(
          padding: const EdgeInsets.fromLTRB(32, 10, 32, 14),
          decoration: BoxDecoration(
            color: doc.isDirty ? cs.tertiaryContainer.withValues(alpha: 0.35) : cs.surfaceContainerLow,
            border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
          ),
          child: Row(
            children: [
              Icon(
                doc.isDirty ? Icons.edit_note : Icons.check_circle_outline,
                size: 20,
                color: doc.isDirty ? cs.tertiary : Colors.grey,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  doc.isDirty
                      ? tr('Unsaved changes: {n}', {'n': doc.changedCount})
                      : tr('All changes saved'),
                  style: TextStyle(
                    fontWeight: doc.isDirty ? FontWeight.w600 : FontWeight.normal,
                    color: doc.isDirty ? cs.onSurface : Colors.grey,
                  ),
                ),
              ),
              OutlinedButton(
                onPressed: (!doc.isDirty || _saving) ? null : reset,
                child: Text(tr('Reset')),
              ),
              const SizedBox(width: 10),
              FilledButton.icon(
                icon: _saving
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.save_outlined, size: 18),
                label: Text(tr('Save')),
                onPressed: (!doc.isDirty || _saving) ? null : save,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _infoBanner(IconData icon, Color bg, String text) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
        child: Row(
          children: [
            Icon(icon, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: const TextStyle(fontSize: 12))),
          ],
        ),
      );

  // ==================== Кураторские сабвкладки ====================

  Widget _playerToggle({bool expandedLabel = false}) {
    final segments = [
      for (var i = 1; i <= _schema.maxPlayers; i++)
        ButtonSegment(
          value: i,
          label: Text(
            expandedLabel && _schema.maxPlayers <= 2
                ? (i == 1 ? tr('Player 1') : tr('Player 2 (Splitscreen)'))
                : tr('Player {n}', {'n': i}),
          ),
        ),
    ];
    return SegmentedButton<int>(
      segments: segments,
      selected: {_controlPlayer.clamp(1, _schema.maxPlayers)},
      onSelectionChanged: (v) => setState(() => _controlPlayer = v.first),
    );
  }

  Widget _buildCuratedTab(Srb2ConfigDocument doc, ConfigSubTab tab) {
    final tabSpecs = [
      for (final s in _schema.specs)
        if (s.tab == tab) s,
    ];

    final showPlayerToggle = tab == ConfigSubTab.playerCamera &&
        _schema.maxPlayers > 1 &&
        tabSpecs.any((s) => s.supportsMultiplePlayers);
    final player = tab == ConfigSubTab.playerCamera ? _controlPlayer.clamp(1, _schema.maxPlayers) : 1;

    final groups = <String, List<CvarSpec>>{};
    for (final s in tabSpecs) {
      groups.putIfAbsent(s.group, () => []).add(s);
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(32, 12, 32, 24),
      children: [
        if (showPlayerToggle)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(tr('Editing profile:'), style: const TextStyle(fontWeight: FontWeight.w600)),
                _playerToggle(expandedLabel: true),
              ],
            ),
          ),
        for (final entry in groups.entries) ...[
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 6),
            child: Text(tr(entry.key), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
          ),
          for (final spec in entry.value)
            if (spec.nameForPlayer(player) case final cvarName?)
              _buildSpecRow(doc, spec, cvarName),
        ],
      ],
    );
  }

  Widget _buildSpecRow(Srb2ConfigDocument doc, CvarSpec spec, String cvarName) {
    final current = doc.cvar(cvarName) ?? spec.defaultValue;
    final dirty = doc.isCvarDirty(cvarName);
    final isNonDefault = current != spec.defaultValue;
    final overrideNote = _launchOverrideNote(spec, cvarName);
    final cs = Theme.of(context).colorScheme;

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: dirty
            ? cs.primaryContainer.withValues(alpha: 0.22)
            : cs.surfaceContainerLow.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: dirty ? cs.primary.withValues(alpha: 0.55) : Theme.of(context).dividerColor.withValues(alpha: 0.5),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: 5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(tr(spec.label), style: const TextStyle(fontWeight: FontWeight.w500)),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      cvarName,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.grey),
                    ),
                    if (dirty) ...[
                      const SizedBox(width: 6),
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(color: cs.primary, shape: BoxShape.circle),
                      ),
                    ],
                  ],
                ),
                if (spec.description.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(tr(spec.description), style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  ),
                if (overrideNote != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      overrideNote,
                      style: TextStyle(fontSize: 11, color: Colors.amber.shade700, fontWeight: FontWeight.w500),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            flex: 4,
            child: Align(
              alignment: Alignment.centerRight,
              child: _buildSpecControl(spec, cvarName, current),
            ),
          ),
          if (isNonDefault)
            IconButton(
              icon: const Icon(Icons.restart_alt, size: 18),
              tooltip: tr('Default: {val}', {'val': spec.defaultValue}),
              onPressed: () => _setCvar(cvarName, spec.defaultValue, syncController: true),
            )
          else
            const SizedBox(width: 40),
        ],
      ),
    );
  }

  Widget _buildSpecControl(CvarSpec spec, String cvarName, String current) {
    switch (spec.kind) {
      case CvarKind.toggle:
        final val = CvarSpec.isTruthy(current);
        return Switch(
          value: val,
          onChanged: (v) => _setCvar(cvarName, v ? spec.trueValue : spec.falseValue),
        );

      case CvarKind.dropdown:
        final items = <String>[
          ...spec.options,
          if (!spec.options.any((o) => o.toLowerCase() == current.toLowerCase()) && current.isNotEmpty) current,
        ];
        final matched = items.firstWhere(
          (o) => o.toLowerCase() == current.toLowerCase(),
          orElse: () => items.first,
        );
        final dropdown = DropdownButtonFormField<String>(
          initialValue: matched,
          isExpanded: true,
          isDense: true,
          decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
          items: [
            for (final opt in items) DropdownMenuItem(value: opt, child: Text(opt, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) {
            if (v != null) _setCvar(cvarName, v);
          },
        );
        if (!spec.name.startsWith('joyaxis')) return dropdown;
        return Row(
          children: [
            Expanded(child: dropdown),
            const SizedBox(width: 6),
            IconButton.outlined(
              icon: const Icon(Icons.sensors, size: 18),
              tooltip: tr('Detect axis with gamepad'),
              onPressed: () async {
                final detected = await showDetectAxisDialog(
                  context,
                  game: widget.game,
                  actionLabel: tr(spec.label),
                  currentAxis: current,
                );
                if (detected != null && mounted) _setCvar(cvarName, detected);
              },
            ),
          ],
        );

      case CvarKind.sliderInt:
        final min = (spec.min ?? 0).round();
        final max = (spec.max ?? 100).round();
        final parsed = int.tryParse(current.trim());
        final clamped = (parsed ?? int.tryParse(spec.defaultValue) ?? min).clamp(min, max);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Expanded(
              child: Slider(
                value: clamped.toDouble(),
                min: min.toDouble(),
                max: max.toDouble(),
                divisions: (max - min) > 0 ? (max - min) : null,
                onChanged: (v) => _setCvar(cvarName, v.round().toString()),
              ),
            ),
            SizedBox(
              width: 40,
              child: Text(
                parsed == null ? current : '$clamped',
                textAlign: TextAlign.end,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ),
          ],
        );

      case CvarKind.color:
        final colors = widget.game.launchSkinColors;
        final ramp = colors
            .where((c) => c.$1.toLowerCase() == current.trim().toLowerCase())
            .map((c) => c.$2)
            .firstOrNull;
        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () async {
            final choices = [for (final c in colors) SkinColorChoice(c.$1, c.$2)];
            final picked = await showSkinColorPicker(
              context,
              Future.value(choices),
              current: current,
            );
            if (picked != null) _setCvar(cvarName, picked);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (ramp != null) ...[
                  ColorPreview(ramp, height: 28),
                  const SizedBox(width: 8),
                ],
                Text(current),
                const SizedBox(width: 4),
                const Icon(Icons.arrow_drop_down, size: 18),
              ],
            ),
          ),
        );

      case CvarKind.file:
      case CvarKind.folder:
        final ctrl = _ctrlFor(cvarName, current);
        return Row(
          children: [
            Expanded(
              child: TextField(
                controller: ctrl,
                onChanged: (v) => _setCvar(cvarName, v),
                decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
              ),
            ),
            const SizedBox(width: 6),
            IconButton.outlined(
              icon: const Icon(Icons.folder_open, size: 18),
              tooltip: tr('Browse...'),
              onPressed: () async {
                String? chosen;
                if (spec.kind == CvarKind.folder) {
                  chosen = await getDirectoryPath(initialDirectory: widget.gameFolder);
                } else {
                  final f = await openFile(
                    initialDirectory: widget.gameFolder,
                    acceptedTypeGroups: [
                      if (spec.fileExtensions.isNotEmpty)
                        XTypeGroup(label: cvarName, extensions: spec.fileExtensions),
                    ],
                  );
                  chosen = f?.path;
                }
                if (chosen == null) return;
                var value = chosen;
                final folder = widget.gameFolder;
                if (folder != null && p.isWithin(folder, chosen)) {
                  value = p.relative(chosen, from: folder).replaceAll('\\', '/');
                }
                _setCvar(cvarName, value, syncController: true);
              },
            ),
          ],
        );

      case CvarKind.integer:
      case CvarKind.decimal:
      case CvarKind.text:
        final ctrl = _ctrlFor(cvarName, current);
        return TextField(
          controller: ctrl,
          onChanged: (v) => _setCvar(cvarName, v),
          keyboardType: spec.kind == CvarKind.text
              ? TextInputType.text
              : TextInputType.numberWithOptions(decimal: spec.kind == CvarKind.decimal, signed: true),
          decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
        );
    }
  }

  // ==================== Сабвкладка «Управление» ====================

  Widget _buildControlsTab(Srb2ConfigDocument doc) {
    final q = _controlsSearchCtrl.text.trim().toLowerCase();
    final player = _controlPlayer.clamp(1, _schema.maxPlayers);
    final pControls = doc.controlsForPlayer(player);
    final knownCmds = {for (final a in _schema.controlActions) a.command.toLowerCase()};
    final extraBinds = [
      for (final b in pControls)
        if (!knownCmds.contains(b.command.toLowerCase()) && b.command != '(null)') b,
    ];

    final groupedBinds = <String, List<(ControlActionSpec, Srb2ControlBind)>>{};
    for (final spec in _schema.controlActions) {
      final bind = doc.control(player, spec.command) ??
          Srb2ControlBind(player: player, command: spec.command, primary: 'KEY0');
      if (q.isNotEmpty &&
          !spec.command.toLowerCase().contains(q) &&
          !tr(spec.label).toLowerCase().contains(q) &&
          !bind.primary.toLowerCase().contains(q) &&
          !bind.secondary.toLowerCase().contains(q)) {
        continue;
      }
      groupedBinds.putIfAbsent(spec.group, () => []).add((spec, bind));
    }
    for (final b in extraBinds) {
      if (q.isNotEmpty &&
          !b.command.toLowerCase().contains(q) &&
          !b.primary.toLowerCase().contains(q) &&
          !b.secondary.toLowerCase().contains(q)) {
        continue;
      }
      groupedBinds
          .putIfAbsent('Other binds', () => [])
          .add((ControlActionSpec(b.command, b.command, 'Other binds'), b));
    }

    final inputGroups = <String, List<(CvarSpec, String)>>{};
    for (final s in _schema.specs) {
      if (s.tab != ConfigSubTab.controls) continue;
      final cvarName = s.nameForPlayer(player);
      if (cvarName == null) continue;
      if (q.isNotEmpty &&
          !cvarName.toLowerCase().contains(q) &&
          !tr(s.label).toLowerCase().contains(q)) {
        continue;
      }
      inputGroups.putIfAbsent(s.group, () => []).add((s, cvarName));
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 12, 32, 8),
          child: Row(
            children: [
              _playerToggle(),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _controlsSearchCtrl,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: tr('Search action, key or setting...'),
                    prefixIcon: const Icon(Icons.search, size: 18),
                    isDense: true,
                    border: const OutlineInputBorder(),
                    suffixIcon: _controlsSearchCtrl.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () => setState(() => _controlsSearchCtrl.clear()),
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                icon: const Icon(Icons.sports_esports_outlined, size: 18),
                label: Text(tr('Gamepad tester')),
                onPressed: () => _openGamepadTester(doc, player),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(32, 4, 32, 24),
            children: [
              for (final g in groupedBinds.entries) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 6),
                  child: Text(tr(g.key), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                ),
                for (final (spec, bind) in g.value) _buildBindRow(doc, spec, bind),
              ],
              for (final g in inputGroups.entries) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 16, bottom: 6),
                  child: Text(tr(g.key), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                ),
                for (final (spec, cvarName) in g.value) _buildSpecRow(doc, spec, cvarName),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBindRow(Srb2ConfigDocument doc, ControlActionSpec spec, Srb2ControlBind bind) {
    final dirty = doc.isControlDirty(_controlPlayer, spec.command);
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 5),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: dirty
            ? cs.primaryContainer.withValues(alpha: 0.22)
            : cs.surfaceContainerLow.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: dirty ? cs.primary.withValues(alpha: 0.55) : Theme.of(context).dividerColor.withValues(alpha: 0.5),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr(spec.label), style: const TextStyle(fontWeight: FontWeight.w500)),
                Text(spec.command, style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.grey)),
              ],
            ),
          ),
          _keyChipButton(
            keyName: bind.primary,
            placeholder: 'KEY0',
            onPressed: () => _pickKey(bind, isSecondary: false),
          ),
          const SizedBox(width: 8),
          _keyChipButton(
            keyName: bind.secondary.isEmpty ? 'KEY0' : bind.secondary,
            placeholder: tr('Alt'),
            secondary: true,
            onPressed: () => _pickKey(bind, isSecondary: true),
          ),
          if (_schema.gamepadDetectControls.isNotEmpty) ...[
            const SizedBox(width: 6),
            if (_schema.gamepadDetectControls.contains(spec.command.toLowerCase()))
              IconButton.outlined(
                icon: const Icon(Icons.sensors, size: 18),
                tooltip: tr('Detect with gamepad'),
                onPressed: () => _detectGamepadControl(bind),
              )
            else
              const SizedBox(width: 40),
          ],
        ],
      ),
    );
  }

  Widget _keyChipButton({
    required String keyName,
    required String placeholder,
    required VoidCallback onPressed,
    bool secondary = false,
  }) {
    final isEmpty = keyName.isEmpty || keyName == 'KEY0';
    return SizedBox(
      width: 128,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          visualDensity: VisualDensity.compact,
        ),
        onPressed: onPressed,
        child: Text(
          (isEmpty ? placeholder : keyName).toUpperCase(),
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            color: isEmpty ? Colors.grey : null,
            fontStyle: (isEmpty && secondary) ? FontStyle.italic : FontStyle.normal,
          ),
        ),
      ),
    );
  }

  Future<void> _openGamepadTester(Srb2ConfigDocument doc, int player) async {
    final axisSpecs = <(CvarSpec, String)>[];
    String? deadzoneCvar;
    double initialDz = 0.125;
    String? deviceCvar;

    for (final s in _schema.specs) {
      final cname = s.nameForPlayer(player);
      if (cname == null) continue;
      if (s.name.startsWith('joyaxis')) {
        axisSpecs.add((s, cname));
      } else if (deadzoneCvar == null && (s.name == 'joy_deadzone' || s.name == 'joy_xdeadzone' || s.name == 'deadzone' || s.name == 'xdeadzone')) {
        deadzoneCvar = cname;
        initialDz = double.tryParse(doc.cvar(cname) ?? s.defaultValue) ?? 0.125;
      } else if (deviceCvar == null && (s.name == 'use_gamepad' || s.name == 'use_joystick')) {
        deviceCvar = cname;
      }
    }

    final currentAxes = <String, String>{
      for (final (s, cname) in axisSpecs) cname: doc.cvar(cname) ?? s.defaultValue,
    };

    final detectSet = _schema.gamepadDetectControls.toSet();
    final controlDetectSpecs = <(ControlActionSpec, String)>[
      for (final c in _schema.controlActions)
        if (detectSet.contains(c.command.toLowerCase()))
          (
            c,
            _currentGamepadBind(
              doc.control(player, c.command) ?? Srb2ControlBind(player: player, command: c.command, primary: 'KEY0'),
            ),
          ),
    ];

    await showGamepadTesterDialog(
      context,
      game: widget.game,
      player: player,
      axisSpecs: axisSpecs,
      currentValues: currentAxes,
      deadzoneCvar: deadzoneCvar,
      initialDeadzone: initialDz,
      deviceIndexCvar: deviceCvar,
      onCvarChanged: (cvar, value) => _setCvar(cvar, value, syncController: true),
      controlDetectSpecs: controlDetectSpecs,
      onControlBindChanged: (command, picked) {
        final cur = _doc?.control(player, command) ?? Srb2ControlBind(player: player, command: command, primary: 'KEY0');
        _applyGamepadBind(cur, picked);
      },
    );
  }

  static bool _isGamepadToken(String token) {
    final u = token.trim().toUpperCase();
    return u.startsWith('JOY') ||
        u.startsWith('HAT') ||
        u.startsWith('SEC_JOY') ||
        u.startsWith('SEC_HAT') ||
        u.startsWith('TRD_') ||
        u.startsWith('FOR_') ||
        u.startsWith('L-STICK') ||
        u.startsWith('R-STICK') ||
        u.startsWith('D-PAD') ||
        u.endsWith(' BUTTON') ||
        u.endsWith(' BUMPER') ||
        u.endsWith(' TRIGGER');
  }

  String _currentGamepadBind(Srb2ControlBind bind) {
    if (_isGamepadToken(bind.secondary)) return bind.secondary;
    if (_isGamepadToken(bind.primary)) return bind.primary;
    if (bind.secondary.isNotEmpty && bind.secondary != 'KEY0') return bind.secondary;
    return 'KEY0';
  }

  void _applyGamepadBind(Srb2ControlBind bind, String picked) {
    final primaryEmpty = bind.primary.isEmpty || bind.primary == 'KEY0';
    final putInPrimary = (primaryEmpty || _isGamepadToken(bind.primary)) &&
        (bind.secondary.isEmpty || bind.secondary == 'KEY0');
    _setControl(
      bind.player,
      bind.command,
      primary: putInPrimary ? picked : null,
      secondary: putInPrimary ? null : (picked == 'KEY0' ? '' : picked),
    );
  }

  Future<void> _detectGamepadControl(Srb2ControlBind bind) async {
    final picked = await showDetectGamepadControlDialog(
      context,
      game: widget.game,
      player: bind.player,
      actionLabel: bind.command,
      currentBind: _currentGamepadBind(bind),
    );
    if (picked == null || !mounted) return;
    _applyGamepadBind(bind, picked);
  }

  Future<void> _pickKey(Srb2ControlBind bind, {required bool isSecondary}) async {
    final current = isSecondary ? bind.secondary : bind.primary;
    final picked = await showKeyCaptureDialog(
      context,
      game: widget.game,
      player: bind.player,
      actionLabel: bind.command,
      currentKey: current,
    );
    if (picked == null || !mounted) return;
    _setControl(
      bind.player,
      bind.command,
      primary: isSecondary ? null : picked,
      secondary: isSecondary ? (picked == 'KEY0' ? '' : picked) : null,
    );
  }

  // ==================== Сабвкладка «Все переменные» ====================

  Widget _buildAllVarsTab(Srb2ConfigDocument doc) {
    final q = _searchCtrl.text.trim().toLowerCase();
    final entries = [
      for (final e in doc.entries)
        if ((q.isEmpty || e.key.toLowerCase().contains(q) || e.value.toLowerCase().contains(q)) &&
            (_allFilter == _AllVarFilter.all ||
                (_allFilter == _AllVarFilter.modified && doc.isCvarDirty(e.key)) ||
                (_allFilter == _AllVarFilter.extra && !_schema.isCuratedCvar(e.key))))
          e,
    ];

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 12, 32, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: tr('Search variable or value...'),
                    prefixIcon: const Icon(Icons.search, size: 18),
                    isDense: true,
                    border: const OutlineInputBorder(),
                    suffixIcon: _searchCtrl.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () => setState(() => _searchCtrl.clear()),
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SegmentedButton<_AllVarFilter>(
                segments: [
                  ButtonSegment(value: _AllVarFilter.all, label: Text(tr('All'))),
                  ButtonSegment(value: _AllVarFilter.modified, label: Text(tr('Changed'))),
                  ButtonSegment(value: _AllVarFilter.extra, label: Text(tr('Extra'))),
                ],
                selected: {_allFilter},
                onSelectionChanged: (v) => setState(() => _allFilter = v.first),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: Text(tr('Add')),
                onPressed: _addCustomCvarDialog,
              ),
            ],
          ),
        ),
        Expanded(
          child: entries.isEmpty
              ? Center(child: Text(tr('No variables match the filter.'), style: const TextStyle(color: Colors.grey)))
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(32, 4, 32, 24),
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    final dirty = doc.isCvarDirty(entry.key);
                    final ctrl = _ctrlFor(entry.key, entry.value);
                    final cs = Theme.of(context).colorScheme;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 5),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: dirty
                            ? cs.primaryContainer.withValues(alpha: 0.22)
                            : cs.surfaceContainerLow.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: dirty
                              ? cs.primary.withValues(alpha: 0.55)
                              : Theme.of(context).dividerColor.withValues(alpha: 0.4),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            flex: 4,
                            child: SelectableText(
                              entry.key,
                              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 5,
                            child: TextField(
                              controller: ctrl,
                              onChanged: (v) => _setCvar(entry.key, v),
                              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                              decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _addCustomCvarDialog() async {
    final nameCtrl = TextEditingController();
    final valCtrl = TextEditingController();
    final res = await showDialog<(String, String)>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Add console variable')),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: tr('Variable name'),
                  hintText: 'e.g. gr_fovchange',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: valCtrl,
                decoration: InputDecoration(
                  labelText: tr('Value'),
                  hintText: 'e.g. On',
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Cancel'))),
          FilledButton(
            onPressed: () {
              final n = nameCtrl.text.trim();
              if (!RegExp(r'^[A-Za-z0-9_]+$').hasMatch(n)) return;
              Navigator.pop(ctx, (n, valCtrl.text));
            },
            child: Text(tr('Add')),
          ),
        ],
      ),
    );
    nameCtrl.dispose();
    valCtrl.dispose();
    if (res == null || !mounted) return;
    _setCvar(res.$1, res.$2, syncController: true);
  }
}

/// Диалог захвата клавиши клавиатуры, кнопки мыши, колеса или кнопки геймпада.
Future<String?> showKeyCaptureDialog(
  BuildContext context, {
  required GameDef game,
  required int player,
  required String actionLabel,
  required String currentKey,
  GamepadService? gamepadService,
}) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => _KeyCaptureDialog(
      game: game,
      player: player,
      actionLabel: actionLabel,
      currentKey: currentKey,
      gamepadService: gamepadService,
    ),
  );
}

class _KeyCaptureDialog extends StatefulWidget {
  final GameDef game;
  final int player;
  final String actionLabel;
  final String currentKey;
  final GamepadService? gamepadService;

  const _KeyCaptureDialog({
    required this.game,
    required this.player,
    required this.actionLabel,
    required this.currentKey,
    this.gamepadService,
  });

  @override
  State<_KeyCaptureDialog> createState() => _KeyCaptureDialogState();
}

class _KeyCaptureDialogState extends State<_KeyCaptureDialog> {
  final _focus = FocusNode();
  late final _manualCtrl = TextEditingController(text: widget.currentKey);
  late final GamepadService _gamepad = widget.gamepadService ?? GamepadService();
  late final bool _ownsGamepad = widget.gamepadService == null;
  StreamSubscription<List<GamepadSnapshot>>? _padSub;
  final Map<int, Set<int>> _heldAtOpen = {};
  final Map<int, String?> _hatAtOpen = {};
  final Map<int, Map<String, double>> _axisBaselines = {};
  String? _connectedName;
  bool _done = false;

  void _finish([String? value]) {
    if (_done || !mounted) return;
    _done = true;
    _padSub?.cancel();
    _padSub = null;
    if (_ownsGamepad) _gamepad.stopPolling();
    Navigator.of(context).pop(value);
  }

  @override
  void initState() {
    super.initState();
    final init = _gamepad.pollOnce();
    _connectedName = init.isNotEmpty ? init.first.name : null;
    for (final d in init) {
      _heldAtOpen[d.deviceIndex] = Set.of(d.pressedButtons);
      _hatAtOpen[d.deviceIndex] = d.hat;
      _axisBaselines[d.deviceIndex] = {for (final a in d.axes) a.id: a.value};
    }
    _padSub = _gamepad.stream.listen((list) {
      if (_done || !mounted) return;
      final nextName = list.isNotEmpty ? list.first.name : null;
      if (_connectedName != nextName) {
        setState(() => _connectedName = nextName);
      }
      for (final d in list) {
        final held = _heldAtOpen[d.deviceIndex];
        held?.removeWhere((b) => !d.pressedButtons.contains(b));
        for (final b in d.pressedButtons) {
          if (held == null || !held.contains(b)) {
            _finish(GamepadNames.srb2ButtonBind(b, widget.game, widget.player));
            return;
          }
        }
        final openHat = _hatAtOpen[d.deviceIndex];
        if (d.hat == null) {
          _hatAtOpen[d.deviceIndex] = null;
        } else if (d.hat != openHat) {
          _finish(GamepadNames.srb2HatBind(d.hat!, widget.game, widget.player));
          return;
        }
        if (GamepadNames.usesSdlControllerNames(widget.game)) {
          final base = _axisBaselines.putIfAbsent(d.deviceIndex, () => {for (final a in d.axes) a.id: a.value});
          final stick = GamepadNames.detectStickBind(d, base);
          if (stick != null) {
            _finish(stick);
            return;
          }
        }
      }
    });
    if (_ownsGamepad) _gamepad.startPolling();
  }

  @override
  void dispose() {
    _done = true;
    _padSub?.cancel();
    if (_ownsGamepad) _gamepad.dispose();
    _focus.dispose();
    _manualCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(tr('Bind key: {action}', {'action': widget.actionLabel})),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Focus(
              focusNode: _focus,
              autofocus: true,
              onKeyEvent: (_, event) {
                if (event is KeyDownEvent) {
                  final mapped = Srb2ConfigSchema.logicalKeyToSrb2(event.logicalKey);
                  if (mapped != null) {
                    _finish(mapped);
                    return KeyEventResult.handled;
                  }
                }
                return KeyEventResult.ignored;
              },
              child: Listener(
                onPointerDown: (e) {
                  _focus.requestFocus();
                  if ((e.buttons & kPrimaryMouseButton) != 0) {
                    _finish('mouse1');
                  } else if ((e.buttons & kSecondaryMouseButton) != 0) {
                    _finish('mouse2');
                  } else if ((e.buttons & kMiddleMouseButton) != 0) {
                    _finish('mouse3');
                  }
                },
                onPointerSignal: (s) {
                  if (s is PointerScrollEvent) {
                    _finish(s.scrollDelta.dy < 0 ? 'wheel 1 up' : 'wheel 1 down');
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 16),
                  decoration: BoxDecoration(
                    color: cs.primaryContainer.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: cs.primary),
                  ),
                  child: Column(
                    children: [
                      const Icon(Icons.keyboard_outlined, size: 28),
                      const SizedBox(height: 6),
                      Text(
                        tr('Press any keyboard key, mouse button, wheel or gamepad button here...'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                      if (_connectedName != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          tr('Detected controller: {name}', {'name': _connectedName!}),
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 12, color: cs.primary),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    isExpanded: true,
                    isDense: true,
                    decoration: InputDecoration(
                      labelText: tr('Gamepad / special key'),
                      border: const OutlineInputBorder(),
                    ),
                    items: [
                      for (final k in Srb2ConfigSchema.quickKeyPresets)
                        DropdownMenuItem(value: k, child: Text(k.toUpperCase(), style: const TextStyle(fontFamily: 'monospace'))),
                    ],
                    onChanged: (v) {
                      if (v != null) _finish(v);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _manualCtrl,
                    decoration: InputDecoration(
                      labelText: tr('Or enter key name manually'),
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                    onSubmitted: (v) {
                      final trimmed = v.trim();
                      if (trimmed.isNotEmpty) _finish(trimmed);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: () {
                    final v = _manualCtrl.text.trim();
                    if (v.isNotEmpty) _finish(v);
                  },
                  child: Text(tr('Apply')),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => _finish('KEY0'),
          child: Text(tr('Clear (KEY0)')),
        ),
        TextButton(
          onPressed: () => _finish(),
          child: Text(tr('Cancel')),
        ),
      ],
    );
  }
}
