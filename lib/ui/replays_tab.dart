import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../i18n.dart';
import '../models/game.dart';
import '../models/mod_item.dart';
import '../services/characters.dart';
import '../services/launch_settings.dart';
import '../services/map_preview.dart';
import '../services/replays.dart';
import '../utils/natural_compare.dart';
import 'build_split_button.dart';
import 'file_actions.dart';
import 'snack.dart';
import 'srb2_text.dart';

/// Вкладка «Реплеи» (экспериментальная): для SRB2 2.2 — просмотр повторов из
/// `data/replay/`, `replay/` и `SRB2AL-Replays/` в корне игры, импорт с диска
/// и по ссылке, подбор нужных аддонов по MD5 и запуск через `-playdemo`.
class ReplaysTab extends StatefulWidget {
  final GameDef game;
  final String? gameFolder;
  final LaunchSettings launch;

  /// Файлы игры по относительным путям (карты, скины, палитры).
  final Future<List<String>> Function(List<String> relative) gameFiles;

  /// Поиск аддонов из заголовка реплея на диске по MD5: возвращает `md5 -> path`.
  final Future<Map<String, String>> Function(List<ReplayAddon> addons) resolveLocalAddons;

  /// Поиск отсутствующего аддона в подключённых репозиториях по MD5.
  final (ModItem, ModFile)? Function(ReplayAddon addon) findRepoAddon;

  /// Скачать отсутствующий аддон из репозитория Autonomi.
  final Future<bool> Function(ModItem mod, ModFile file) onDownloadAddon;

  /// Доп. аддоны для просмотра реплеев (например, Spectator Camera).
  final List<ReplayExtraAddon> extraAddons;
  final ValueChanged<List<ReplayExtraAddon>> onExtraAddonsChanged;

  /// Запуск реплея: `playdemoArg` (относительный путь для `-playdemo`) и
  /// список локальных файлов аддонов для `-file`.
  final Future<void> Function(String playdemoArg, List<String> addonFiles, {String? executableId}) onPlay;

  const ReplaysTab({
    super.key,
    required this.game,
    required this.gameFolder,
    required this.launch,
    required this.gameFiles,
    required this.resolveLocalAddons,
    required this.findRepoAddon,
    required this.onDownloadAddon,
    this.extraAddons = const [],
    required this.onExtraAddonsChanged,
    required this.onPlay,
  });

  @override
  State<ReplaysTab> createState() => _ReplaysTabState();
}

class _ReplaysTabState extends State<ReplaysTab> {
  static const _allFoldersKey = '__all__';

  final _search = TextEditingController();
  String _selectedFolder = _allFoldersKey;
  bool _dragging = false;
  bool _busyImport = false;

  List<ReplayGroup> _groups = const [];
  bool _loading = false;
  Map<String, String> _localAddonsByMd5 = const {};

  // Кэш превью карт и скинов по набору локальных файлов аддонов (очередь по 1 изоляту за раз).
  final Map<String, Future<Map<String, MapPreview>>> _mapsCache = {};
  final Map<String, Future<Map<String, CharacterInfo>>> _charsCache = {};
  final List<(String, List<String>, bool isMaps, Completer<Object>)> _scanQueue = [];
  bool _drainingScan = false;

  @override
  void initState() {
    super.initState();
    _search.addListener(() {
      if (mounted) setState(() {});
    });
    _reload();
  }

  @override
  void didUpdateWidget(ReplaysTab old) {
    super.didUpdateWidget(old);
    if (old.gameFolder != widget.gameFolder || old.game.id != widget.game.id) {
      _selectedFolder = _allFoldersKey;
      _mapsCache.clear();
      _charsCache.clear();
      _reload();
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool get _supported => widget.game.engine == 'srb2';

  Future<void> _reload() async {
    final folder = widget.gameFolder;
    if (folder == null || !_supported) {
      if (mounted) {
        setState(() {
          _groups = const [];
          _localAddonsByMd5 = const {};
          _loading = false;
        });
      }
      return;
    }

    setState(() => _loading = true);
    try {
      final files = await ReplayScanner.scanInBackground(folder);
      final groups = ReplayScanner.groupDuplicates(files);
      final uniqueAddons = <String, ReplayAddon>{};
      for (final g in groups) {
        for (final a in g.primary.addons) {
          if (a.md5.isNotEmpty) uniqueAddons.putIfAbsent(a.md5, () => a);
        }
      }
      final resolved = uniqueAddons.isEmpty
          ? const <String, String>{}
          : await widget.resolveLocalAddons(uniqueAddons.values.toList());
      if (!mounted || widget.gameFolder != folder) return;
      setState(() {
        _groups = groups;
        _localAddonsByMd5 = resolved;
        _loading = false;
        if (_selectedFolder != _allFoldersKey &&
            !groups.any((g) => g.primary.folder == _selectedFolder)) {
          _selectedFolder = _allFoldersKey;
        }
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<String> _resolvedAddonPaths(ReplayFile r) => [
        for (final a in r.addons)
          if (_localAddonsByMd5[a.md5] case final path?) path,
      ];

  Future<Map<String, MapPreview>> _mapsFor(List<String> addonPaths) {
    final key = addonPaths.join('\u0000');
    return _mapsCache.putIfAbsent(key, () {
      final c = Completer<Object>();
      _scanQueue.add((key, addonPaths, true, c));
      _drainScanQueue();
      return c.future.then((v) => v as Map<String, MapPreview>);
    });
  }

  Future<Map<String, CharacterInfo>> _charsFor(List<String> addonPaths) {
    final key = addonPaths.join('\u0000');
    return _charsCache.putIfAbsent(key, () {
      final c = Completer<Object>();
      _scanQueue.add((key, addonPaths, false, c));
      _drainScanQueue();
      return c.future.then((v) => v as Map<String, CharacterInfo>);
    });
  }

  Future<void> _drainScanQueue() async {
    if (_drainingScan) return;
    _drainingScan = true;
    try {
      final baseMaps = await widget.gameFiles(widget.game.baseMapFiles);
      final baseSkins = await widget.gameFiles(widget.game.baseSkinFiles);
      final palettes = await widget.gameFiles(widget.game.paletteFiles);
      while (_scanQueue.isNotEmpty) {
        final (_, addonPaths, isMaps, completer) = _scanQueue.removeAt(0);
        try {
          if (isMaps) {
            final files = [...baseMaps, ...addonPaths];
            final list = await MapScanner.scanAllInBackground(files, palettes,
                pictureInsideMaps: widget.game.pictureInsideMaps);
            final byMap = <String, MapPreview>{};
            for (final m in list) {
              byMap[m.map.toUpperCase()] = m;
            }
            completer.complete(byMap);
          } else {
            final files = [...baseSkins, ...addonPaths];
            final list = await CharacterScanner.scanAllInBackground(files, palettes,
                colors: widget.game.skinColors,
                startColor: widget.game.skinStartColor,
                iconFrames: widget.game.skinIconFrames,
                portraits: widget.game.skinPortraits,
                builtInSonic: widget.game.builtInSonic,
                baseDescriptions:
                    widget.game.vanillaSkinDescriptions ? CharacterScanner.vanillaDescriptions : const {});
            final bySkin = <String, CharacterInfo>{};
            for (final ch in list) {
              bySkin[ch.name.toLowerCase()] = ch;
            }
            completer.complete(bySkin);
          }
        } catch (_) {
          completer.complete(isMaps ? <String, MapPreview>{} : <String, CharacterInfo>{});
        }
      }
    } finally {
      _drainingScan = false;
    }
  }

  List<int>? _rampForColor(String colorName) {
    if (colorName.isEmpty) return null;
    final want = colorName.toLowerCase();
    for (final (name, ramp) in widget.game.skinColors) {
      if (name.toLowerCase() == want) return ramp;
    }
    return null;
  }

  // --- Импорт реплеев в <корень игры>/SRB2AL-Replays/ ---

  Future<void> _importFromDisk() async {
    final folder = widget.gameFolder;
    if (folder == null) return;
    final picked = await openFiles(
      acceptedTypeGroups: [XTypeGroup(label: tr('SRB2 Replay'), extensions: ['lmp'])],
      confirmButtonText: tr('Import'),
    );
    if (picked.isEmpty || !mounted) return;
    await _importLocalPaths([for (final f in picked) f.path]);
  }

  Future<void> _importLocalPaths(Iterable<String> paths) async {
    final folder = widget.gameFolder;
    if (folder == null || _busyImport) return;
    final lmps = [
      for (final pth in paths)
        if (pth.toLowerCase().endsWith('.lmp')) pth,
    ];
    if (lmps.isEmpty) {
      if (mounted) {
        showSnack(context, SnackBar(content: Text(tr('Only .lmp replay files are supported.'))));
      }
      return;
    }

    setState(() => _busyImport = true);
    var count = 0;
    try {
      for (final src in lmps) {
        try {
          await ReplayScanner.importLocalFile(src, folder);
          count++;
        } catch (e) {
          if (mounted) {
            showSnack(context, SnackBar(content: Text('$e'), backgroundColor: Colors.red));
          }
        }
      }
      if (count > 0 && mounted) {
        _selectedFolder = ReplayScanner.importedFolder;
        await _reload();
        if (mounted) {
          showSnack(
            context,
            SnackBar(
              content: Text(tr('Imported {n} replay(s) to {folder}', {
                'n': count,
                'folder': ReplayScanner.importedFolder,
              })),
              backgroundColor: Colors.green,
            ),
          );
        }
      }
    } finally {
      if (mounted) setState(() => _busyImport = false);
    }
  }

  Future<void> _importFromUrl() async {
    final folder = widget.gameFolder;
    if (folder == null || _busyImport) return;
    final ctrl = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Download replay from URL')),
        content: SizedBox(
          width: 480,
          child: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: InputDecoration(
              labelText: tr('Replay URL (.lmp)'),
              hintText: 'https://example.com/MAP01-sonic-time-best.lmp',
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(tr('Cancel'))),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: Text(tr('Download')),
          ),
        ],
      ),
    );
    if (url == null || url.isEmpty || !mounted) return;

    setState(() => _busyImport = true);
    try {
      final imported = await ReplayScanner.downloadFromUrl(url, folder);
      if (!mounted) return;
      _selectedFolder = ReplayScanner.importedFolder;
      await _reload();
      if (mounted) {
        showSnack(
          context,
          SnackBar(
            content: Text(tr('Replay "{name}" downloaded to {folder}', {
              'name': imported.fileName,
              'folder': ReplayScanner.importedFolder,
            })),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        showSnack(
          context,
          SnackBar(
            content: Text(tr('Failed to download replay: {error}', {'error': '$e'})),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busyImport = false);
    }
  }

  Future<void> _saveCopy(ReplayFile replay) async {
    final folder = widget.gameFolder;
    if (folder == null) return;
    final ctrl = TextEditingController(text: replay.fileName);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Save replay copy')),
        content: SizedBox(
          width: 400,
          child: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: InputDecoration(
              labelText: tr('File name'),
              helperText: tr('Will be saved to {folder}', {'folder': ReplayScanner.importedFolder}),
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(tr('Cancel'))),
          ElevatedButton(onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()), child: Text(tr('Save'))),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    try {
      await ReplayScanner.importLocalFile(replay.path, folder, preferredName: name);
      if (!mounted) return;
      await _reload();
      if (mounted) {
        showSnack(
          context,
          SnackBar(
            content: Text(tr('Saved copy to {folder}', {'folder': ReplayScanner.importedFolder})),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) showSnack(context, SnackBar(content: Text('$e'), backgroundColor: Colors.red));
    }
  }

  Future<void> _deleteGroup(ReplayGroup group) async {
    final names = [for (final v in group.variants) v.fileName].join(', ');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Delete replay?')),
        content: Text(tr('Delete "{name}" from disk?', {'name': names})),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(tr('Cancel'))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(tr('Delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    for (final v in group.variants) {
      try {
        await File(v.path).delete();
      } catch (_) {}
    }
    await _reload();
  }

  List<String> _enabledExtraAddonPaths() => [
        for (final e in widget.extraAddons)
          if (e.enabled && File(e.path).existsSync()) e.path,
      ];

  String? _defaultAddonBrowseDir() {
    final folder = widget.gameFolder;
    if (folder == null) return null;
    final downloads = p.joinAll([folder, ...widget.game.downloadPath]);
    return Directory(downloads).existsSync() ? downloads : folder;
  }

  Future<void> _openExtraAddonsDialog() async {
    var list = List<ReplayExtraAddon>.of(widget.extraAddons);
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: Text(tr('Extra addons for replays')),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr('Loaded after the replay\'s own addons (for example, Spectator Camera). Replays with modified addons are launched via {temp}.', {
                    'temp': p.join(ReplayScanner.importedFolder, ReplayScanner.tempFolder, ReplayScanner.tempReplayName),
                  }),
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 12),
                if (list.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      tr('No extra addons added yet.'),
                      style: const TextStyle(color: Colors.grey),
                    ),
                  )
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 280),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: list.length,
                      itemBuilder: (ctx, i) {
                        final item = list[i];
                        final exists = File(item.path).existsSync();
                        return CheckboxListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          value: item.enabled,
                          onChanged: (v) {
                            setDlg(() => list[i] = (path: item.path, enabled: v ?? false));
                            widget.onExtraAddonsChanged(List.of(list));
                          },
                          title: Text(p.basename(item.path), overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            exists ? item.path : '${tr('Missing')}: ${item.path}',
                            style: TextStyle(fontSize: 11, color: exists ? Colors.grey : Colors.redAccent),
                            overflow: TextOverflow.ellipsis,
                          ),
                          secondary: IconButton(
                            icon: const Icon(Icons.delete_outline, size: 18),
                            tooltip: tr('Remove'),
                            onPressed: () {
                              setDlg(() => list.removeAt(i));
                              widget.onExtraAddonsChanged(List.of(list));
                            },
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            OutlinedButton.icon(
              icon: const Icon(Icons.add, size: 18),
              label: Text(tr('Add file...')),
              onPressed: () async {
                final picked = await openFiles(
                  initialDirectory: _defaultAddonBrowseDir(),
                  acceptedTypeGroups: [
                    XTypeGroup(label: 'SRB2 Addon', extensions: const ['lua', 'pk3', 'wad', 'soc']),
                  ],
                );
                if (picked.isEmpty) return;
                final existing = {for (final x in list) p.normalize(x.path).toLowerCase()};
                var changed = false;
                for (final f in picked) {
                  if (existing.add(p.normalize(f.path).toLowerCase())) {
                    list.add((path: f.path, enabled: true));
                    changed = true;
                  }
                }
                if (changed) {
                  setDlg(() {});
                  widget.onExtraAddonsChanged(List.of(list));
                }
              },
            ),
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(tr('Close'))),
          ],
        ),
      ),
    );
  }

  Future<void> _openEditReplayAddonsDialog(ReplayFile replay) async {
    final recorded = <(ReplayAddon addon, String? localPath, bool checked)>[
      for (final a in replay.addons)
        () {
          final lp = _localAddonsByMd5[a.md5];
          final ok = lp != null && File(lp).existsSync();
          return (a, ok ? lp : null, ok);
        }(),
    ];
    final recordedSet = {
      for (final r in recorded)
        if (r.$2 != null) p.normalize(r.$2!).toLowerCase(),
    };
    final custom = <(String path, bool checked)>[
      for (final pth in _enabledExtraAddonPaths())
        if (!recordedSet.contains(p.normalize(pth).toLowerCase())) (pth, true),
    ];

    final launch = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: Text(tr('Edit replay addons')),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr('Choose which addons to load with this replay. Modified launches are saved to {temp}.', {
                    'temp': p.join(ReplayScanner.importedFolder, ReplayScanner.tempFolder, ReplayScanner.tempReplayName),
                  }),
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 10),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 300),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      if (recorded.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(tr('Recorded in replay'),
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                        ),
                        for (var i = 0; i < recorded.length; i++)
                          CheckboxListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            value: recorded[i].$3,
                            onChanged: recorded[i].$2 == null
                                ? null
                                : (v) => setDlg(() => recorded[i] = (recorded[i].$1, recorded[i].$2, v ?? false)),
                            title: Text(recorded[i].$1.name, overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                              recorded[i].$2 ?? tr('Missing'),
                              style: TextStyle(
                                fontSize: 11,
                                color: recorded[i].$2 == null ? Colors.orangeAccent : Colors.grey,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      if (custom.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.only(top: 8, bottom: 4),
                          child: Text(tr('Added addons'),
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                        ),
                        for (var i = 0; i < custom.length; i++)
                          CheckboxListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            value: custom[i].$2,
                            onChanged: (v) => setDlg(() => custom[i] = (custom[i].$1, v ?? false)),
                            title: Text(p.basename(custom[i].$1), overflow: TextOverflow.ellipsis),
                            subtitle: Text(custom[i].$1,
                                style: const TextStyle(fontSize: 11, color: Colors.grey),
                                overflow: TextOverflow.ellipsis),
                            secondary: IconButton(
                              icon: const Icon(Icons.delete_outline, size: 18),
                              onPressed: () => setDlg(() => custom.removeAt(i)),
                            ),
                          ),
                      ],
                      if (recorded.isEmpty && custom.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(tr('No addons selected.'), style: const TextStyle(color: Colors.grey)),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            OutlinedButton.icon(
              icon: const Icon(Icons.add, size: 18),
              label: Text(tr('Add file...')),
              onPressed: () async {
                final picked = await openFiles(
                  initialDirectory: _defaultAddonBrowseDir(),
                  acceptedTypeGroups: [
                    XTypeGroup(label: 'SRB2 Addon', extensions: const ['lua', 'pk3', 'wad', 'soc']),
                  ],
                );
                if (picked.isEmpty) return;
                final seen = {
                  ...recordedSet,
                  for (final c in custom) p.normalize(c.$1).toLowerCase(),
                };
                for (final f in picked) {
                  if (seen.add(p.normalize(f.path).toLowerCase())) {
                    custom.add((f.path, true));
                  }
                }
                setDlg(() {});
              },
            ),
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(tr('Cancel'))),
            FilledButton.icon(
              icon: const Icon(Icons.play_arrow, size: 18),
              label: Text(tr('Play')),
              onPressed: () => Navigator.of(ctx).pop(true),
            ),
          ],
        ),
      ),
    );
    if (launch != true || !mounted) return;
    final editedFiles = <String>[
      for (final r in recorded)
        if (r.$3 && r.$2 != null) r.$2!,
      for (final c in custom)
        if (c.$2) c.$1,
    ];
    await _launchReplay(replay, editedFiles: editedFiles);
  }

  Future<void> _launchReplay(ReplayFile replay, {String? executableId, List<String>? editedFiles}) async {
    final folder = widget.gameFolder;
    if (folder == null) return;
    final missing = <ReplayAddon>[];
    final files = <String>[];
    var usedExtras = false;

    if (editedFiles != null) {
      files.addAll(editedFiles);
    } else {
      for (final a in replay.addons) {
        final path = _localAddonsByMd5[a.md5];
        if (path != null && File(path).existsSync()) {
          files.add(path);
        } else {
          missing.add(a);
        }
      }

      if (missing.isNotEmpty) {
        final downloadable = <(ModItem, ModFile)>[];
        for (final a in missing) {
          final match = widget.findRepoAddon(a);
          if (match != null) downloadable.add(match);
        }
        final action = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            icon: const Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent, size: 36),
            title: Text(tr('Missing replay addons')),
            content: SizedBox(
              width: 480,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tr('This replay was recorded with addon(s) not found on your disk:')),
                  const SizedBox(height: 8),
                  for (final a in missing)
                    Text('• ${a.name} (${a.md5.substring(0, a.md5.length >= 8 ? 8 : a.md5.length)})',
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(ctx).pop('cancel'), child: Text(tr('Cancel'))),
              if (downloadable.isNotEmpty)
                ElevatedButton.icon(
                  icon: const Icon(Icons.download),
                  label: Text(tr('Download ({n})', {'n': downloadable.length})),
                  onPressed: () => Navigator.of(ctx).pop('download'),
                ),
              TextButton(onPressed: () => Navigator.of(ctx).pop('anyway'), child: Text(tr('Launch anyway'))),
            ],
          ),
        );
        if (action == null || action == 'cancel' || !mounted) return;
        if (action == 'download') {
          for (final (mod, file) in downloadable) {
            await widget.onDownloadAddon(mod, file);
          }
          await _reload();
          if (!mounted) return;
          files.clear();
          missing.clear();
          for (final a in replay.addons) {
            final path = _localAddonsByMd5[a.md5];
            if (path != null && File(path).existsSync()) {
              files.add(path);
            } else {
              missing.add(a);
            }
          }
        }
      }

      final seen = {for (final f in files) p.normalize(f).toLowerCase()};
      for (final extra in _enabledExtraAddonPaths()) {
        if (seen.add(p.normalize(extra).toLowerCase())) {
          files.add(extra);
          usedExtras = true;
        }
      }
    }

    var playdemoArg = replay.relativePlayPath;
    final needsTemp = replay.validHeader &&
        replay.demoVersion >= 16 &&
        (editedFiles != null || missing.isNotEmpty || usedExtras || files.length != replay.addons.length);
    if (needsTemp) {
      try {
        playdemoArg = await ReplayScanner.prepareTempReplay(
          sourcePath: replay.path,
          gameFolder: folder,
          addonFilePaths: files,
        );
      } catch (e) {
        if (mounted) {
          showSnack(context, SnackBar(content: Text('$e'), backgroundColor: Colors.red));
        }
        return;
      }
    }

    await widget.onPlay(playdemoArg, files, executableId: executableId);
  }

  String _kindLabel(ReplayKind kind) => switch (kind) {
        ReplayKind.last => tr('Last'),
        ReplayKind.timeBest => tr('Best Time'),
        ReplayKind.scoreBest => tr('Best Score'),
        ReplayKind.ringsBest => tr('Best Rings'),
        ReplayKind.custom => tr('Saved'),
      };

  Color _kindColor(ReplayKind kind) => switch (kind) {
        ReplayKind.last => Colors.blueGrey,
        ReplayKind.timeBest => Colors.cyan,
        ReplayKind.scoreBest => Colors.amber,
        ReplayKind.ringsBest => Colors.orange,
        ReplayKind.custom => Colors.green,
      };

  String _folderDisplay(String key) {
    if (key == _allFoldersKey) return tr('All replays');
    if (key == ReplayScanner.importedFolder) return ReplayScanner.importedFolder;
    if (key == 'main') return tr('Vanilla (main)');
    if (key.isEmpty) return tr('replay (root)');
    return key;
  }

  List<String> _sortedFolders() {
    final counts = <String, int>{};
    for (final g in _groups) {
      counts.update(g.primary.folder, (n) => n + 1, ifAbsent: () => 1);
    }
    final keys = counts.keys.toList()
      ..sort((a, b) {
        if (a == ReplayScanner.importedFolder) return -1;
        if (b == ReplayScanner.importedFolder) return 1;
        if (a == 'main') return -1;
        if (b == 'main') return 1;
        if (a.isEmpty) return -1;
        if (b.isEmpty) return 1;
        return naturalCompare(a, b);
      });
    return keys;
  }

  List<ReplayGroup> _visibleGroups() {
    final q = _search.text.trim().toLowerCase();
    return [
      for (final g in _groups)
        if ((_selectedFolder == _allFoldersKey || g.primary.folder == _selectedFolder) &&
            (q.isEmpty ||
                g.primary.mapName.toLowerCase().contains(q) ||
                g.primary.playerName.toLowerCase().contains(q) ||
                g.primary.skin.toLowerCase().contains(q) ||
                g.primary.folder.toLowerCase().contains(q) ||
                g.primary.addons.any((a) => a.name.toLowerCase().contains(q)) ||
                g.variants.any((v) => v.fileName.toLowerCase().contains(q))))
          g,
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (!_supported) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            tr('Replays tab currently supports Sonic Robo Blast 2 (2.2) only.'),
            style: const TextStyle(color: Colors.grey, fontSize: 15),
          ),
        ),
      );
    }

    if (widget.gameFolder == null) {
      return Center(
        child: Text(
          tr('{game} folder is not set. Please configure it in Settings.', {'game': widget.game.name}),
          style: const TextStyle(color: Colors.grey, fontSize: 15),
        ),
      );
    }

    final folders = _sortedFolders();
    final counts = <String, int>{};
    for (final g in _groups) {
      counts.update(g.primary.folder, (n) => n + 1, ifAbsent: () => 1);
    }
    final visible = _visibleGroups();

    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) {
        setState(() => _dragging = false);
        _importLocalPaths(details.files.map((f) => f.path));
      },
      child: Stack(
        children: [
          Row(
            children: [
              // Левая панель: поиск и список папок.
              SizedBox(
                width: 270,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                      child: TextField(
                        controller: _search,
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.search, size: 18),
                          hintText: tr('Search map, player, addon...'),
                          isDense: true,
                          border: const OutlineInputBorder(),
                          suffixIcon: _search.text.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.clear, size: 16),
                                  onPressed: _search.clear,
                                ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        children: [
                          ListTile(
                            dense: true,
                            selected: _selectedFolder == _allFoldersKey,
                            leading: const Icon(Icons.video_library_outlined, size: 20),
                            title: Text(tr('All replays')),
                            trailing: Text('${_groups.length}', style: const TextStyle(color: Colors.grey)),
                            onTap: () => setState(() => _selectedFolder = _allFoldersKey),
                          ),
                          const Divider(height: 1),
                          for (final f in folders)
                            ListTile(
                              dense: true,
                              selected: _selectedFolder == f,
                              leading: Icon(
                                f == ReplayScanner.importedFolder
                                    ? Icons.folder_special_outlined
                                    : (f == 'main' ? Icons.sports_esports_outlined : Icons.folder_outlined),
                                size: 20,
                                color: f == ReplayScanner.importedFolder
                                    ? Theme.of(context).colorScheme.primary
                                    : null,
                              ),
                              title: Text(_folderDisplay(f), overflow: TextOverflow.ellipsis),
                              trailing: Text('${counts[f] ?? 0}', style: const TextStyle(color: Colors.grey)),
                              onTap: () => setState(() => _selectedFolder = f),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const VerticalDivider(width: 1),
              // Правая панель: кнопки импорта и список реплеев.
              Expanded(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${_folderDisplay(_selectedFolder)} (${visible.length})',
                              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                            ),
                          ),
                          if (_busyImport)
                            const Padding(
                              padding: EdgeInsets.only(right: 12),
                              child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                            ),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.extension_outlined, size: 18),
                            label: Text(_enabledExtraAddonPaths().isEmpty
                                ? tr('Extra addons')
                                : tr('Extra addons ({n})', {'n': _enabledExtraAddonPaths().length})),
                            onPressed: _openExtraAddonsDialog,
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.file_open_outlined, size: 18),
                            label: Text(tr('From disk...')),
                            onPressed: _busyImport ? null : _importFromDisk,
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.link, size: 18),
                            label: Text(tr('From URL...')),
                            onPressed: _busyImport ? null : _importFromUrl,
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(Icons.refresh),
                            tooltip: tr('Refresh'),
                            onPressed: _loading ? null : _reload,
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: _loading
                          ? const Center(child: CircularProgressIndicator())
                          : visible.isEmpty
                              ? Center(
                                  child: Padding(
                                    padding: const EdgeInsets.all(24),
                                    child: Text(
                                      _groups.isEmpty
                                          ? tr('No replays found in data/replay or SRB2AL-Replays.\nDrag & Drop .lmp files here or import from disk / URL.')
                                          : tr('Nothing matches your search.'),
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(color: Colors.grey),
                                    ),
                                  ),
                                )
                              : ListView.builder(
                                  padding: const EdgeInsets.all(16),
                                  itemCount: visible.length,
                                  itemBuilder: (context, idx) => _buildReplayCard(visible[idx]),
                                ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_dragging)
            Positioned.fill(
              child: Container(
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.14),
                child: Center(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.file_download_outlined, color: Theme.of(context).colorScheme.primary),
                          const SizedBox(width: 12),
                          Text(
                            tr('Drop .lmp replay files to import to {folder}',
                                {'folder': ReplayScanner.importedFolder}),
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildReplayCard(ReplayGroup group) {
    final r = group.primary;
    final addonPaths = _resolvedAddonPaths(r);
    final theme = Theme.of(context);
    final selectedBuild = widget.launch.selected;
    final versionMismatch = selectedBuild != null &&
        r.versionLabel.isNotEmpty &&
        RegExp(r'2\.2\.\d+').hasMatch(selectedBuild.name) &&
        !selectedBuild.name.contains(r.versionLabel);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Превью карты
                _buildMapThumb(r, addonPaths),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Название карты + бейджи вариантов
                      Row(
                        children: [
                          Expanded(child: _buildMapTitle(r, addonPaths)),
                          const SizedBox(width: 8),
                          for (final v in group.variants)
                            Padding(
                              padding: const EdgeInsets.only(left: 4),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                decoration: BoxDecoration(
                                  color: _kindColor(v.kind).withValues(alpha: 0.16),
                                  borderRadius: BorderRadius.circular(5),
                                  border: Border.all(color: _kindColor(v.kind).withValues(alpha: 0.45)),
                                ),
                                child: Text(
                                  v.kind == ReplayKind.custom ? v.fileName : _kindLabel(v.kind),
                                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _kindColor(v.kind)),
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      // Персонаж (иконка + игрок + скин/цвет) + статистика
                      Row(
                        children: [
                          if (r.validHeader && r.skin.isNotEmpty) ...[
                            _buildCharIcon(r, addonPaths),
                            const SizedBox(width: 8),
                          ],
                          if (r.validHeader)
                            Expanded(
                              child: Wrap(
                                spacing: 12,
                                runSpacing: 4,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  if (r.playerName.isNotEmpty)
                                    srb2Text(srb2TitleSpans(r.playerName),
                                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                                  if (r.skin.isNotEmpty)
                                    Text('${r.skin}${r.color.isNotEmpty ? ' · ${r.color}' : ''}',
                                        style: const TextStyle(fontSize: 12, color: Colors.grey)),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.timer_outlined, size: 14, color: Colors.grey),
                                      const SizedBox(width: 3),
                                      Text(r.formattedTime, style: const TextStyle(fontSize: 12)),
                                    ],
                                  ),
                                  if (r.score > 0)
                                    Text('${tr('Score')}: ${r.score}',
                                        style: const TextStyle(fontSize: 12, color: Colors.grey)),
                                  if (r.rings > 0)
                                    Text('${tr('Rings')}: ${r.rings}',
                                        style: const TextStyle(fontSize: 12, color: Colors.amber)),
                                  if (r.versionLabel.isNotEmpty)
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                      decoration: BoxDecoration(
                                        color: (versionMismatch ? Colors.orange : Colors.grey).withValues(alpha: 0.15),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        'v${r.versionLabel}',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: versionMismatch ? Colors.orangeAccent : Colors.grey,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            )
                          else
                            Expanded(
                              child: Text(
                                '${r.fileName} (${tr('Unknown header')})',
                                style: const TextStyle(color: Colors.grey),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                BuildSplitButton(
                  launch: widget.launch,
                  label: tr('Play'),
                  height: 36,
                  horizontalPadding: 14,
                  dropdownWidth: 32,
                  color: const Color(0xFF2E9E46),
                  onPressed: (exeId) => _launchReplay(r, executableId: exeId),
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert),
                  onSelected: (action) async {
                    if (action == 'edit_addons') {
                      await _openEditReplayAddonsDialog(r);
                    } else if (action == 'copy') {
                      await _saveCopy(r);
                    } else if (action == 'folder') {
                      await showFileInFolder(context, r.path);
                    } else if (action == 'delete') {
                      await _deleteGroup(group);
                    }
                  },
                  itemBuilder: (context) => [
                    if (r.validHeader && r.demoVersion >= 16)
                      PopupMenuItem(
                        value: 'edit_addons',
                        child: ListTile(
                          dense: true,
                          leading: const Icon(Icons.tune),
                          title: Text(tr('Edit addons & play...')),
                        ),
                      ),
                    if (!group.isImported)
                      PopupMenuItem(
                        value: 'copy',
                        child: ListTile(
                          dense: true,
                          leading: const Icon(Icons.save_alt),
                          title: Text(tr('Save copy to {folder}...', {'folder': ReplayScanner.importedFolder})),
                        ),
                      ),
                    PopupMenuItem(
                      value: 'folder',
                      child: ListTile(
                        dense: true,
                        leading: const Icon(Icons.folder_open),
                        title: Text(tr('Show in folder')),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: ListTile(
                        dense: true,
                        leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                        title: Text(tr('Delete')),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            if (r.addons.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final a in r.addons) _buildAddonChip(a, theme),
                ],
              ),
            ] else if (r.validHeader && r.demoVersion < 16 && r.folder != 'main' && r.folder != ReplayScanner.importedFolder) ...[
              const SizedBox(height: 6),
              Text(
                tr('Older replay format ({ver}): addon list is not stored inside the file.',
                    {'ver': r.versionLabel}),
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAddonChip(ReplayAddon a, ThemeData theme) {
    final localPath = _localAddonsByMd5[a.md5];
    if (localPath != null) {
      return Chip(
        visualDensity: VisualDensity.compact,
        avatar: const Icon(Icons.check_circle, size: 15, color: Colors.green),
        label: Text(a.name, style: const TextStyle(fontSize: 11)),
      );
    }
    final repoMatch = widget.findRepoAddon(a);
    if (repoMatch != null) {
      final (mod, file) = repoMatch;
      return ActionChip(
        visualDensity: VisualDensity.compact,
        avatar: Icon(Icons.download, size: 15, color: theme.colorScheme.primary),
        label: Text('${a.name} (${tr('Download')})', style: const TextStyle(fontSize: 11)),
        onPressed: () async {
          await widget.onDownloadAddon(mod, file);
          await _reload();
        },
      );
    }
    return Chip(
      visualDensity: VisualDensity.compact,
      avatar: const Icon(Icons.warning_amber_rounded, size: 15, color: Colors.orangeAccent),
      label: Text('${a.name} (${tr('Missing')})', style: const TextStyle(fontSize: 11, color: Colors.orangeAccent)),
    );
  }

  Widget _buildMapThumb(ReplayFile r, List<String> addonPaths) {
    const w = 84.0;
    const h = 52.0;
    Widget placeholder() => ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Image.asset('assets/map_unknown.png', width: w, height: h, fit: BoxFit.cover),
        );
    if (!r.validHeader || r.mapName.isEmpty) return placeholder();

    return FutureBuilder<Map<String, MapPreview>>(
      future: _mapsFor(addonPaths),
      builder: (context, snap) {
        final pic = snap.data?[r.mapName.toUpperCase()]?.image;
        if (pic == null) return placeholder();
        return ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Image.memory(pic, width: w, height: h, fit: BoxFit.cover, gaplessPlayback: true),
        );
      },
    );
  }

  Widget _buildMapTitle(ReplayFile r, List<String> addonPaths) {
    if (!r.validHeader || r.mapName.isEmpty) {
      return Text(r.fileName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15));
    }
    return FutureBuilder<Map<String, MapPreview>>(
      future: _mapsFor(addonPaths),
      builder: (context, snap) {
        final preview = snap.data?[r.mapName.toUpperCase()];
        final title = preview?.title ?? '';
        if (title.isEmpty) {
          return Text(r.mapName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15));
        }
        return srb2Text(
          [
            Srb2TextSpan('${r.mapName} — ', 0),
            ...srb2TitleSpans(title),
          ],
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
        );
      },
    );
  }

  Widget _buildCharIcon(ReplayFile r, List<String> addonPaths) {
    const size = 24.0;
    Widget fallback() => Image.asset('assets/char_unknown.png', width: size, height: size, filterQuality: FilterQuality.none);

    return FutureBuilder<Map<String, CharacterInfo>>(
      future: _charsFor(addonPaths),
      builder: (context, snap) {
        final ch = snap.data?[r.skin.toLowerCase()];
        if (ch == null) return fallback();
        final bytes = ch.iconWithRamp(_rampForColor(r.color)) ?? ch.icon;
        if (bytes == null) return fallback();
        return Image.memory(bytes, width: size, height: size, filterQuality: FilterQuality.none, gaplessPlayback: true);
      },
    );
  }
}
