import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../i18n.dart';
import '../models/game.dart';
import '../services/app_log.dart';
import '../services/game_files.dart';
import '../services/launch_settings.dart';
import '../services/model_mesh.dart';
import '../services/model_packs.dart';
import 'color_preview.dart';
import 'file_actions.dart' show openFolder;
import 'model_preview_dialog.dart';
import 'snack.dart';

/// Настройки → Модели (у каждой игры свои): наборы моделей, какая версия
/// каждой модели идёт в общий пак, установка в игру, zip и откат.
class ModelsSettings extends StatefulWidget {
  final GameDef game;

  /// Папка игры (null — не задана).
  final String? gameFolder;
  final LaunchSettings? launch;

  const ModelsSettings({super.key, required this.game, required this.gameFolder, required this.launch});

  @override
  State<ModelsSettings> createState() => _ModelsSettingsState();
}

enum _Filter { all, inGame, conflicts, manual, problems }

/// Строка списка моделей: модель из наборов и/или то, что стоит в игре.
class _Row {
  final String key;
  final ModelChoice? choice;
  final GameModelLine? game;
  const _Row(this.key, this.choice, this.game);
}

class _ModelsSettingsState extends State<ModelsSettings> {
  ModelLibrary? _lib;
  InstalledModels? _installed;

  /// Список моделей игры построчно (null — списка нет или папка не задана).
  GameModels? _gameModels;
  List<ModelBackup> _backups = const [];
  bool _busy = false;
  String? _busyText;
  final _search = TextEditingController();
  _Filter _filter = _Filter.all;

  /// Свёрнутые группы списка: true — персонажи, false — объекты.
  final Set<bool> _collapsed = {};
  Future<Uint8List?>? _palette;

  /// Выбор версий и собранный пак — пересчитываются после изменений, а не
  /// при каждой перерисовке (сборка смотрит файлы на диске).
  List<ModelChoice>? _choices;
  ModelBuild? _build;

  void _changed() {
    _choices = null;
    _build = null;
    if (mounted) setState(() {});
  }

  ModelFormat get _format => widget.game.models!;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ModelsSettings old) {
    super.didUpdateWidget(old);
    if (old.game.id != widget.game.id || old.gameFolder != widget.gameFolder) {
      _palette = null;
      _load();
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (widget.game.models == null) return;
    final game = widget.game;
    final lib = await ModelLibrary.load(game);
    if (!mounted || widget.game.id != game.id) return;
    setState(() => _lib = lib);
    _changed();
    await _refreshGame();
  }

  Future<void> _refreshGame() async {
    final lib = _lib, folder = widget.gameFolder;
    if (lib == null || folder == null) {
      setState(() {
        _installed = null;
        _gameModels = null;
        _backups = const [];
      });
      return;
    }
    final installed = await lib.installed(folder);
    final backups = await lib.backups(folder);
    GameModels? game;
    try {
      game = await lib.gameModels(folder);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _installed = installed;
      _gameModels = game;
      _backups = backups;
    });
  }

  /// Палитра игры — для перекраски моделей в цвет игрока (один раз).
  /// Нет её в файлах игры — палитра SRB2 из лаунчера.
  Future<Uint8List?> _paletteFuture() => _palette ??= () async {
    final launch = widget.launch;
    if (launch != null) {
      try {
        final files = await GameFiles.resolveAsync(widget.game, widget.gameFolder, launch, widget.game.paletteFiles);
        final found = await compute(loadPlaypal, files);
        if (found != null) return found;
      } catch (_) {}
    }
    try {
      return await ColorPreview.builtInPalette();
    } catch (_) {
      return null;
    }
  }();

  /// Долгое дело с подписью; ошибка — в снизу.
  Future<void> _run(String text, Future<void> Function() job, {String? done}) async {
    setState(() {
      _busy = true;
      _busyText = text;
    });
    try {
      await job();
      if (mounted && done != null) showSnack(context, SnackBar(content: Text(done)));
    } catch (e) {
      AppLog.write('models: $text: $e');
      if (mounted) {
        showSnack(context, SnackBar(content: Text(_errorText(e)), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyText = null;
        });
      }
    }
  }

  String _errorText(Object e) {
    if (e is FormatException && e.message.startsWith('no ')) {
      return tr('No {file} in it: a model pack has {file} and the {folder} folder.', {
        'file': _format.datFile,
        'folder': _format.folder,
      });
    }
    if (e is FormatException) return e.message;
    if (e is FileSystemException) {
      return tr('Could not change the files: {error}. Close the game and try again.', {
        'error': e.osError?.message ?? e.message,
      });
    }
    return '$e';
  }

  // --- Наборы ---

  Future<void> _addArchive() async {
    AppLog.action('open the openFile dialog (models_settings.dart)');
    final file = await openFile(
      acceptedTypeGroups: [
        XTypeGroup(label: tr('Model pack'), extensions: const ['zip', 'pk3']),
      ],
    );
    if (file == null) return;
    await _add(file.path);
  }

  Future<void> _addFolder() async {
    AppLog.action('open the getDirectoryPath dialog (models_settings.dart)');
    final dir = await getDirectoryPath(confirmButtonText: tr('Select'));
    if (dir == null) return;
    await _add(dir);
  }

  Future<void> _add(String source, {String? name}) async {
    final lib = _lib;
    if (lib == null) return;
    await _run(tr('Adding the pack...'), () async {
      final pack = await lib.add(source, name: name);
      _changed();
      if (mounted) {
        showSnack(
          context,
          SnackBar(content: Text(tr('Added "{name}": {n} models', {'name': pack.name, 'n': '${pack.models.length}'}))),
        );
      }
    });
  }

  Future<void> _importGame() async {
    final folder = widget.gameFolder;
    if (folder == null) return;
    final now = DateTime.now();
    await _add(folder, name: tr('Game models {date}', {'date': _date(now)}));
  }

  Future<void> _rename(ModelPack pack) async {
    final c = TextEditingController(text: pack.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Rename')),
        content: TextField(controller: c, autofocus: true, onSubmitted: (v) => Navigator.pop(context, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, c.text), child: Text(tr('Save'))),
        ],
      ),
    );
    c.dispose();
    if (name == null || name.trim().isEmpty) return;
    await _lib!.rename(pack, name);
    _changed();
  }

  Future<void> _remove(ModelPack pack) async {
    if (!await _confirm(
      tr('Delete the pack "{name}"?', {'name': pack.name}),
      tr('Its files are removed from the launcher. What is installed in the game stays until you install again.'),
      tr('Delete'),
    )) {
      return;
    }
    await _lib!.remove(pack);
    _changed();
  }

  Future<bool> _confirm(String title, String text, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(text),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(action)),
          ],
        ),
      ) ==
      true;

  // --- Пак ---

  Future<void> _install() async {
    final lib = _lib, folder = widget.gameFolder;
    if (lib == null || folder == null) return;
    final build = _build ?? lib.build();
    if (!await _confirm(
      tr('Install {n} models into the game?', {'n': '${build.lines.length}'}),
      tr('What is in {folder}/ and {file} now is moved to a backup: you can roll back below.', {
        'folder': _format.folder,
        'file': _format.datFile,
      }),
      tr('Install'),
    )) {
      return;
    }
    await _run(tr('Installing...'), () async {
      await lib.install(folder, build);
      await _refreshGame();
    }, done: tr('Installed {n} models', {'n': '${build.lines.length}'}));
  }

  Future<void> _saveZip() async {
    final lib = _lib;
    if (lib == null) return;
    AppLog.action('open the getSaveLocation dialog (models_settings.dart)');
    final where = await getSaveLocation(
      suggestedName: '${widget.game.id}-models.zip',
      acceptedTypeGroups: [
        XTypeGroup(label: 'ZIP', extensions: const ['zip']),
      ],
    );
    if (where == null) return;
    final path = where.path.toLowerCase().endsWith('.zip') ? where.path : '${where.path}.zip';
    final build = _build ?? lib.build();
    await _run(tr('Saving...'), () => lib.saveZip(build, path), done: tr('Saved to {path}', {'path': path}));
  }

  Future<void> _cleanGame() async {
    final lib = _lib, folder = widget.gameFolder, game = _gameModels;
    if (lib == null || folder == null || game == null) return;
    if (!await _confirm(
      tr('Clean {file}?', {'file': _format.datFile}),
      tr(
        'Lines the game stops at and models without files are removed, file name case is fixed. '
        'The old {file} goes to a backup: you can roll back below.',
        {'file': _format.datFile},
      ),
      tr('Clean'),
    )) {
      return;
    }
    var removed = 0;
    await _run(tr('Cleaning...'), () async {
      removed = await lib.cleanGame(folder);
      await _refreshGame();
    });
    if (mounted) showSnack(context, SnackBar(content: Text(tr('Lines removed: {n}', {'n': '$removed'}))));
  }

  Future<void> _cleanPack(ModelPack pack) async {
    final removed = await _lib!.cleanPack(pack);
    _changed();
    if (mounted) showSnack(context, SnackBar(content: Text(tr('Lines removed: {n}', {'n': '$removed'}))));
  }

  Future<void> _rollback(ModelBackup b) async {
    final lib = _lib, folder = widget.gameFolder;
    if (lib == null || folder == null) return;
    if (!await _confirm(
      tr('Roll back to {date}?', {'date': _date(b.date)}),
      tr('What is installed now is moved to a new backup.'),
      tr('Roll back'),
    )) {
      return;
    }
    await _run(tr('Rolling back...'), () async {
      await lib.rollback(folder, b);
      await _refreshGame();
    }, done: tr('Rolled back'));
  }

  Future<void> _deleteBackup(ModelBackup b) async {
    if (!await _confirm(
      tr('Delete the backup of {date}?', {'date': _date(b.date)}),
      tr('It cannot be restored after that.'),
      tr('Delete'),
    )) {
      return;
    }
    await _run(tr('Deleting...'), () async {
      await _lib!.deleteBackup(b);
      await _refreshGame();
    });
  }

  // --- Модели ---

  Future<void> _open(ModelChoice c) async {
    final pick = await showModelPreview(context, widget.game, c, _paletteFuture());
    if (pick == null || !mounted) return;
    await _pick(c, pick);
  }

  Future<void> _pick(ModelChoice c, ModelPick pick) async {
    await _lib!.choose(c.key, switch (pick) {
      ModelPickAuto() => null,
      ModelPickOff() => '',
      ModelPickPack(:final packId) => packId,
    });
    _changed();
    if (mounted && widget.gameFolder != null) {
      showSnack(
        context,
        SnackBar(
          content: Text(tr('Chosen. The game gets it after "Install to the game".')),
          action: SnackBarAction(label: tr('Install'), onPressed: _install),
        ),
      );
    }
  }

  static String _date(DateTime t) {
    String two(int x) => x.toString().padLeft(2, '0');
    return '${two(t.day)}.${two(t.month)}.${t.year} ${two(t.hour)}:${two(t.minute)}';
  }

  static String _size(int bytes) {
    const units = ['B', 'KiB', 'MiB', 'GiB'];
    var v = bytes.toDouble();
    var u = 0;
    while (v >= 1024 && u < units.length - 1) {
      v /= 1024;
      u++;
    }
    return '${v.toStringAsFixed(u == 0 ? 0 : 1)} ${units[u]}';
  }

  static String _problemText(ModelProblem x, ModelFormat f) => switch (x) {
    ModelProblem.missingModel => tr('No model file: left out of the pack'),
    ModelProblem.longName => tr('Name longer than {n} characters: left out of the pack', {'n': '${f.nameMax}'}),
    ModelProblem.missingTexture => tr('No texture of its own: the game uses the sprite'),
    ModelProblem.playerPrefix => tr('The game does not know the PLAYER prefix: the name will not match a skin'),
    ModelProblem.md3NotSupported => tr('The game reads only MD2 models: left out of the pack'),
  };

  // --- Вид ---

  Widget _title(String text) => Padding(
    padding: const EdgeInsets.only(top: 18, bottom: 6),
    child: Text(text, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
  );

  Widget _hint(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text, style: const TextStyle(fontSize: 12, color: Colors.grey)),
  );

  @override
  Widget build(BuildContext context) {
    final format = widget.game.models;
    if (format == null) {
      return _hint(tr('3D models are not supported for {game} yet.', {'game': widget.game.name}));
    }
    final lib = _lib;
    if (lib == null) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final choices = _choices ??= lib.choices();
    final build = _build ??= ModelLibrary.planBuild(format, choices, lib.packs);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _hint(
          tr(
            'Models are shown only with the OpenGL renderer. Add model packs, choose which version of each model '
            'to use, and the launcher puts them together into one pack: {folder}/ and {file} in the game folder.',
            {'folder': format.folder, 'file': format.datFile},
          ),
        ),
        if (_busy)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 10),
                Text(_busyText ?? ''),
              ],
            ),
          ),
        _gameState(format),
        _pending(build, format),
        _title(tr('Packs')),
        _hint(tr('When packs have a model with the same name, the higher pack wins. Drag to reorder.')),
        _packs(lib),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.folder_zip_outlined, size: 18),
              label: Text(tr('Add pack (.zip)...')),
              onPressed: _busy ? null : _addArchive,
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.create_new_folder_outlined, size: 18),
              label: Text(tr('Add folder...')),
              onPressed: _busy ? null : _addFolder,
            ),
          ],
        ),
        _title(tr('Pack')),
        _summary(build, format),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              icon: const Icon(Icons.download_done, size: 18),
              label: Text(tr('Install to the game')),
              onPressed: _busy || widget.gameFolder == null || build.lines.isEmpty ? null : _install,
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.archive_outlined, size: 18),
              label: Text(tr('Save as .zip...')),
              onPressed: _busy || build.lines.isEmpty ? null : _saveZip,
            ),
          ],
        ),
        if (widget.gameFolder == null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: _hint(tr('Choose the game folder (Game folder section) to install the pack.')),
          ),
        _title(tr('Models ({n})', {'n': '${choices.length}'})),
        _models(choices, build, format),
        _title(tr('Backups')),
        _hint(
          tr(
            'Before installing or rolling back, the launcher moves what was in the game to {dir} in the game folder. '
            'The last {n} are kept.',
            {'dir': '${format.folder}.srb2al-backups', 'n': '${ModelLibrary.keepBackups}'},
          ),
        ),
        if (_backups.isEmpty)
          Text(tr('None'), style: const TextStyle(fontSize: 12, color: Colors.grey))
        else
          for (final b in _backups)
            Card(
              margin: const EdgeInsets.only(bottom: 4),
              child: ListTile(
                dense: true,
                leading: const Icon(Icons.history),
                title: Text(_date(b.date)),
                subtitle: Text(
                  [
                    tr('{n} models', {'n': '${b.models}'}),
                    if (b.listOnly) tr('only {file}', {'file': format.datFile}),
                  ].join(' · '),
                ),
                trailing: Wrap(
                  spacing: 4,
                  children: [
                    OutlinedButton(onPressed: _busy ? null : () => _rollback(b), child: Text(tr('Roll back'))),
                    IconButton(
                      tooltip: tr('Delete'),
                      icon: const Icon(Icons.delete_outline),
                      onPressed: _busy ? null : () => _deleteBackup(b),
                    ),
                  ],
                ),
              ),
            ),
      ],
    );
  }

  /// Выбранное ещё не в игре — заметная подсказка с кнопкой установки.
  Widget _pending(ModelBuild build, ModelFormat format) {
    if (widget.gameFolder == null || _lib == null || _lib!.packs.isEmpty) return const SizedBox.shrink();
    final n = ModelLibrary.pendingChanges(build.lines, _gameModels);
    final scheme = Theme.of(context).colorScheme;
    if (n == 0) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          children: [
            Icon(Icons.check_circle_outline, size: 18, color: Colors.green.shade400),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                tr('Everything chosen here is already in the game.'),
                style: TextStyle(color: Colors.green.shade400),
              ),
            ),
          ],
        ),
      );
    }
    return Card(
      margin: const EdgeInsets.only(top: 8),
      color: scheme.primary.withValues(alpha: 0.16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.primary.withValues(alpha: 0.6)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.info_outline, color: scheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('Not in the game yet: {n} models', {'n': '$n'}),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    tr('Packs and versions chosen here change the game only after "Install to the game".'),
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              icon: const Icon(Icons.download_done, size: 18),
              label: Text(tr('Install to the game')),
              onPressed: _busy || build.lines.isEmpty ? null : _install,
            ),
          ],
        ),
      ),
    );
  }

  /// Что стоит в игре сейчас.
  Widget _gameState(ModelFormat format) {
    final folder = widget.gameFolder;
    final installed = _installed;
    final extra = folder == null
        ? const <String>[]
        : [
            for (final f in format.extraDatFiles)
              if (File(p.join(folder, f)).existsSync()) f,
          ];
    return Card(
      margin: const EdgeInsets.only(top: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Icon(Icons.sports_esports_outlined),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    folder == null
                        ? tr('The game folder is not set')
                        : installed?.models == null
                        ? tr('No {file} in the game folder', {'file': format.datFile})
                        : tr('In the game: {n} models in {file}', {
                            'n': '${installed!.models}',
                            'file': format.datFile,
                          }),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (installed?.installed case final date?)
                    Text(
                      tr('Installed by the launcher {date}: {packs}', {
                        'date': _date(date),
                        'packs': installed!.packs.isEmpty ? '—' : installed.packs.join(', '),
                      }),
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    )
                  else if (installed?.models != null)
                    Text(
                      tr('Not installed by the launcher. Add it as a pack to keep its models.'),
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  if (_gameModels case final g? when g.needsCleaning) ...[
                    if (g.stopLine != null)
                      Text(
                        tr('The game stops reading {file} at line {line}: the models below it are not loaded.', {
                          'file': format.datFile,
                          'line': '${g.stopLine}',
                        }),
                        style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.error),
                      ),
                    if (g.missing > 0)
                      Text(
                        tr('No model file: {n}', {'n': '${g.missing}'}),
                        style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.error),
                      ),
                    if (g.wrongCase > 0)
                      Text(
                        tr('File name case differs (not found on Linux): {n}', {'n': '${g.wrongCase}'}),
                        style: TextStyle(fontSize: 12, color: Colors.orange.shade300),
                      ),
                  ],
                  for (final f in extra)
                    Text(
                      tr('The game also reads {file} after {main}: its lines replace models of the pack.', {
                        'file': f,
                        'main': format.datFile,
                      }),
                      style: TextStyle(fontSize: 12, color: Colors.orange.shade300),
                    ),
                ],
              ),
            ),
            if (_gameModels case final g? when g.needsCleaning)
              TextButton.icon(
                icon: const Icon(Icons.cleaning_services_outlined, size: 18),
                label: Text(tr('Clean {file}', {'file': format.datFile})),
                onPressed: _busy ? null : _cleanGame,
              ),
            if (folder != null && installed?.models != null)
              TextButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: Text(tr('Add as a pack')),
                onPressed: _busy ? null : _importGame,
              ),
            if (folder != null)
              IconButton(
                tooltip: tr('Open folder'),
                icon: const Icon(Icons.folder_open_outlined),
                onPressed: () => openFolder(context, folder),
              ),
          ],
        ),
      ),
    );
  }

  Widget _packs(ModelLibrary lib) {
    if (lib.packs.isEmpty) {
      return _hint(
        tr('No packs yet. Add a .zip with {file} and the {folder} folder, or a folder with them.', {
          'file': _format.datFile,
          'folder': _format.folder,
        }),
      );
    }
    return ReorderableListView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      onReorderItem: (from, to) async {
        lib.packs.insert(to, lib.packs.removeAt(from));
        _changed();
        await lib.save();
      },
      children: [
        for (var i = 0; i < lib.packs.length; i++)
          () {
            final pack = lib.packs[i];
            final notes = <String>[
              for (final n in pack.notes)
                if (n.startsWith('stopped:'))
                  tr('The game stops reading its list at line {line}: the lines below it were skipped.', {
                    'line': n.split(':')[1],
                  })
                else if (n.startsWith('unused:'))
                  tr('{n} files are not in its list and were not added.', {'n': n.split(':')[1]}),
            ];
            return Card(
              key: ValueKey(pack.id),
              margin: const EdgeInsets.only(bottom: 4),
              child: ListTile(
                dense: true,
                leading: ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_indicator)),
                title: Text(pack.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(
                  [
                    tr('{n} models', {'n': '${pack.models.length}'}),
                    _size(pack.bytes),
                    ...notes,
                  ].join(' · '),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Switch(
                      value: lib.enabled(pack),
                      onChanged: _busy
                          ? null
                          : (v) async {
                              v ? lib.disabled.remove(pack.id) : lib.disabled.add(pack.id);
                              _changed();
                              await lib.save();
                            },
                    ),
                    PopupMenuButton<String>(
                      onSelected: (v) => switch (v) {
                        'rename' => _rename(pack),
                        'folder' => openFolder(context, pack.dir),
                        'clean' => _cleanPack(pack),
                        _ => _remove(pack),
                      },
                      itemBuilder: (_) => [
                        if (lib.brokenIn(pack) case final n when n > 0)
                          PopupMenuItem(
                            value: 'clean',
                            child: Text(tr('Remove models without files ({n})', {'n': '$n'})),
                          ),
                        PopupMenuItem(value: 'rename', child: Text(tr('Rename'))),
                        PopupMenuItem(value: 'folder', child: Text(tr('Open folder'))),
                        PopupMenuItem(value: 'delete', child: Text(tr('Delete'))),
                      ],
                    ),
                  ],
                ),
              ),
            );
          }(),
      ],
    );
  }

  Widget _models(List<ModelChoice> choices, ModelBuild build, ModelFormat format) {
    final q = _search.text.trim().toUpperCase();
    final inGame = _gameModels?.active ?? const <String, GameModelLine>{};
    // Модели наборов и те, что есть только в игре (пропадут при установке).
    final rows = [
      for (final c in choices) _Row(c.key, c, inGame[c.key]),
      for (final e in inGame.entries)
        if (!choices.any((c) => c.key == e.key)) _Row(e.key, null, e.value),
    ]..sort((a, b) => a.key.compareTo(b.key));
    final shown = [
      for (final r in rows)
        if ((q.isEmpty ||
                r.key.contains(q) ||
                (r.game?.line?.path.toUpperCase().contains(q) ?? false) ||
                (r.choice?.candidates.any(
                      (x) => x.$2.line.path.toUpperCase().contains(q) || x.$1.name.toUpperCase().contains(q),
                    ) ??
                    false)) &&
            switch (_filter) {
              _Filter.all => true,
              _Filter.inGame => r.game != null,
              _Filter.conflicts => r.choice?.conflict ?? false,
              _Filter.manual => r.choice?.manual ?? false,
              _Filter.problems =>
                (build.problems[r.key]?.any((x) => x != ModelProblem.missingTexture) ?? false) ||
                    (r.game != null && !r.game!.ok),
            })
          r,
    ];
    final planned = {for (final l in build.lines) l.key: l};
    // Группы: персонажи (скины), затем объекты (спрайты); строка — либо
    // заголовок группы (bool), либо модель (_Row).
    final skins = [for (final r in shown) if (format.isSkin(r.key)) r];
    final objects = [for (final r in shown) if (!format.isSkin(r.key)) r];
    final items = <Object>[
      if (skins.isNotEmpty) true,
      if (!_collapsed.contains(true)) ...skins,
      if (objects.isNotEmpty) false,
      if (!_collapsed.contains(false)) ...objects,
    ];
    final counts = {true: skins.length, false: objects.length};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _search,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search, size: 20),
            hintText: tr('Name, file or pack'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        SegmentedButton<_Filter>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(value: _Filter.all, label: Text(tr('All'))),
            ButtonSegment(value: _Filter.inGame, label: Text(tr('In the game'))),
            ButtonSegment(value: _Filter.conflicts, label: Text(tr('Several versions'))),
            ButtonSegment(value: _Filter.manual, label: Text(tr('Chosen by you'))),
            ButtonSegment(value: _Filter.problems, label: Text(tr('Problems'))),
          ],
          selected: {_filter},
          onSelectionChanged: (v) => setState(() => _filter = v.first),
        ),
        const SizedBox(height: 6),
        Container(
          height: 380,
          decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).dividerColor),
            borderRadius: BorderRadius.circular(6),
          ),
          child: shown.isEmpty
              ? Center(
                  child: Text(tr('Nothing found'), style: const TextStyle(color: Colors.grey)),
                )
              : ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, i) {
                    final item = items[i];
                    if (item is bool) return _groupHeader(item, counts[item]!);
                    final r = item as _Row;
                    return SizedBox(
                      height: 56,
                      child: r.choice == null
                          ? _gameOnlyRow(r.game!)
                          : _modelRow(r.choice!, build.problems[r.key] ?? const [], format, r.game, planned[r.key]),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// Заголовок группы: персонажи или объекты; щелчок сворачивает.
  Widget _groupHeader(bool skins, int count) {
    final collapsed = _collapsed.contains(skins);
    return InkWell(
      onTap: () => setState(() => collapsed ? _collapsed.remove(skins) : _collapsed.add(skins)),
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.10),
        child: Row(
          children: [
            Icon(collapsed ? Icons.chevron_right : Icons.expand_more, size: 20),
            const SizedBox(width: 4),
            Icon(skins ? Icons.person_outline : Icons.category_outlined, size: 18),
            const SizedBox(width: 8),
            Text(
              skins ? tr('Characters (skins): {n}', {'n': '$count'}) : tr('Objects (sprites): {n}', {'n': '$count'}),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }

  /// Что с моделью в игре: стоит та же, другая или её нет.
  Widget _gameStatus(GameModelLine? game, ModelLine? planned) {
    final scheme = Theme.of(context).colorScheme;
    final (IconData icon, Color color, String text) = switch (game) {
      null => (Icons.remove_circle_outline, Colors.grey, tr('not in the game')),
      final g when g.missing => (
        Icons.error_outline,
        scheme.error,
        tr('in the game: no file {file}', {'file': g.line!.path}),
      ),
      final g
          when planned != null &&
              g.line!.path.toLowerCase() == planned.path.toLowerCase() &&
              g.line!.scale == planned.scale &&
              g.line!.offset == planned.offset =>
        (Icons.check_circle_outline, Colors.green.shade400, tr('in the game')),
      final g => (Icons.swap_horiz, Colors.orange.shade300, tr('in the game: {file}', {'file': g.line!.path})),
    };
    return Row(
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            text,
            style: TextStyle(fontSize: 12, color: color),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  /// Модель есть в игре, но ни в одном наборе: при установке пропадёт.
  Widget _gameOnlyRow(GameModelLine g) {
    final muted = TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          const Icon(Icons.sports_esports_outlined, size: 20, color: Colors.grey),
          const SizedBox(width: 10),
          Expanded(
            flex: 3,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(g.line!.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(g.line!.path, style: muted, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              tr('Only in the game: gone after installing (add the game models as a pack to keep it)'),
              style: TextStyle(fontSize: 12, color: Colors.orange.shade300),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 168),
        ],
      ),
    );
  }

  Widget _modelRow(
    ModelChoice c,
    List<ModelProblem> problems,
    ModelFormat format,
    GameModelLine? game,
    ModelLine? planned,
  ) {
    final chosen = c.chosen;
    final serious = problems.where((x) => x != ModelProblem.missingTexture).toList();
    final muted = TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant);
    return InkWell(
      onTap: () => _open(c),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Icon(Icons.view_in_ar_outlined, size: 20, color: chosen == null ? Colors.grey : null),
            const SizedBox(width: 10),
            Expanded(
              flex: 3,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    chosen?.$2.line.name ?? c.candidates.first.$2.line.name,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      decoration: chosen == null ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  Text(chosen?.$2.line.path ?? tr('Off'), style: muted, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            Expanded(
              flex: 3,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    chosen == null ? '' : chosen.$1.name + (c.manual ? ' · ${tr('chosen by you')}' : ''),
                    overflow: TextOverflow.ellipsis,
                    style: c.manual ? TextStyle(color: Theme.of(context).colorScheme.primary) : null,
                  ),
                  if (widget.gameFolder != null && _gameModels != null) _gameStatus(game, planned),
                ],
              ),
            ),
            // Значки — в колонке постоянной ширины: колонки строк не сдвигаются.
            SizedBox(
              width: 120,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (c.conflict)
                    Chip(
                      visualDensity: VisualDensity.compact,
                      label: Text(
                        tr('{n} versions', {'n': '${c.candidates.length}'}),
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  if (problems.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Tooltip(
                        message: problems.map((x) => _problemText(x, format)).join('\n'),
                        child: Icon(
                          serious.isNotEmpty ? Icons.error_outline : Icons.info_outline,
                          size: 20,
                          color: serious.isNotEmpty ? Theme.of(context).colorScheme.error : Colors.grey,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            PopupMenuButton<ModelPick>(
              tooltip: tr('Version'),
              icon: const Icon(Icons.more_vert, size: 20),
              onSelected: (pick) => _pick(c, pick),
              itemBuilder: (_) => [
                for (final (pack, m) in c.candidates)
                  CheckedPopupMenuItem(
                    value: ModelPickPack(pack.id),
                    checked: chosen?.$1.id == pack.id,
                    child: Text('${pack.name} · ${m.line.path}'),
                  ),
                const PopupMenuDivider(),
                PopupMenuItem(value: const ModelPickAuto(), enabled: c.manual, child: Text(tr('By pack order'))),
                PopupMenuItem(value: const ModelPickOff(), enabled: chosen != null, child: Text(tr('Turn off'))),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _summary(ModelBuild build, ModelFormat format) {
    var left = 0, sprites = 0;
    for (final l in build.problems.values) {
      if (l.contains(ModelProblem.missingModel) ||
          l.contains(ModelProblem.longName) ||
          l.contains(ModelProblem.md3NotSupported)) {
        left++;
      } else if (l.contains(ModelProblem.missingTexture)) {
        sprites++; // только у моделей, что попадут в пак
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tr('{n} models, {files} files, {size}', {
            'n': '${build.lines.length}',
            'files': '${build.files.length}',
            'size': _size(build.bytes),
          }),
        ),
        if (build.packNames.isNotEmpty)
          Text(
            tr('From: {packs}', {'packs': build.packNames.join(', ')}),
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        if (left > 0)
          Text(
            tr('{n} models are left out: no model file or the name is too long (see Problems).', {'n': '$left'}),
            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.error),
          ),
        if (sprites > 0)
          Text(
            tr('{n} models have no texture of their own: the game uses their sprites.', {'n': '$sprites'}),
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        Text(
          tr('File names are written exactly as in {file}, so the pack also works on Linux.', {'file': format.datFile}),
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
      ],
    );
  }
}
