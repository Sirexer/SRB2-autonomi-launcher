import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../i18n.dart';
import '../models/game.dart';
import '../services/game_progress.dart';
import '../services/launch_settings.dart';
import '../services/map_preview.dart';
import '../services/platform_utils.dart';
import 'build_split_button.dart';
import 'save_guard_dialogs.dart';
import 'srb2_text.dart';

/// Вкладка Progress (экспериментальная): прогресс одиночной игры SRB2 2.2
/// — ванильной (gamedata.dat) и аддонов со своим GameData: сводка как экран
/// Statistics и карточки уровней как Record Attack.
class ProgressTab extends StatefulWidget {
  final GameDef game;

  /// Папка игры (там gamedata.dat); null — не задана.
  final String? gameFolder;

  /// Файлы игры по относительным путям (srb2.pk3 и т.п.).
  final Future<List<String>> Function(List<String> relative) gameFiles;

  /// Аддоны, у которых может быть свой прогресс (скачанные и в папке игры).
  final Future<List<ProgressCandidate>> Function() candidates;

  /// Скрытые из списка (имена файлов прогресса) и скрыть ещё один.
  final Set<String> hidden;
  final void Function(String id) onHide;

  /// Сборки игры — для выпадающего меню выбора сборки рядом с «Играть».
  final LaunchSettings launch;

  /// Играть: игра только с этими файлами (пусто — ванильная), без
  /// параметров Launch и -warp — так игра сохраняет прогресс.
  final void Function(List<String> files, {String? executableId}) onPlay;

  /// «Add Map Pack»: добавить левелпак из файлов на диске (у SRB2 Legacy
  /// аддонов в репозиториях нет); id добавленного пака или null.
  final Future<String?> Function()? onAddPack;

  /// Пак добавлен вручную — его можно убрать из Progress (файлы остаются).
  final bool Function(List<String> files)? isManual;
  final Future<void> Function(List<String> files)? onRemovePack;

  /// Ручная правка файлов пака (какие и в каком порядке грузятся): новый id
  /// пака или null (не сохранено).
  final Future<String?> Function(ProgressPack pack, List<String> files)? onEditPack;

  /// «Копии сохранений»: true — какой-то файл заменён копией.
  final Future<bool> Function()? onBackups;

  const ProgressTab({
    super.key,
    required this.game,
    required this.gameFolder,
    required this.gameFiles,
    required this.candidates,
    required this.hidden,
    required this.onHide,
    required this.launch,
    required this.onPlay,
    this.onAddPack,
    this.isManual,
    this.onRemovePack,
    this.onEditPack,
    this.onBackups,
  });

  /// Открыть прогресс аддона (из его карточки на вкладке Addons).
  static final selectRequest = ValueNotifier<String?>(null);

  /// Файлы прогресса заменены (восстановлены из копии): прочитать заново.
  static void invalidate() => _ProgressTabState._invalidate();

  @override
  State<ProgressTab> createState() => _ProgressTabState();
}

class _ProgressTabState extends State<ProgressTab> {
  // Между открытиями вкладки: выбранный аддон, список и прочитанные файлы.
  static String _selected = ProgressPack.vanillaId;
  static bool _unvisited = false;
  static Future<List<ProgressPack>>? _packsCache;

  /// Для какой игры и папки [_packsCache].
  static String? _packsCacheKey;
  static final Map<String, (DateTime?, Future<ProgressData>)> _dataCache = {};
  static final Map<String, Future<Uint8List?>> _pictures = {};

  /// Картинки уровней — по очереди, одним фоновым изолятом за раз и
  /// пачками: поиск открывает архивы игры и распаковывает карты, и десятки
  /// изолятов разом (по одному на карточку) съедали память так, что лаунчер
  /// падал (особенно при переходе на вкладку Servers с её фоновой работой).
  static final List<(List<String>, String, Completer<Uint8List?>)> _pictureQueue = [];
  static bool _drainingPictures = false;

  Future<void> _drainPictures() async {
    if (_drainingPictures) return;
    _drainingPictures = true;
    try {
      final base = await widget.gameFiles(widget.game.baseMapFiles);
      final palettes = await widget.gameFiles(widget.game.paletteFiles);
      while (_pictureQueue.isNotEmpty) {
        // Пачка карт одного аддона.
        final packFiles = _pictureQueue.first.$1;
        final batch = [
          for (final q in _pictureQueue) if (listEquals(q.$1, packFiles)) q,
        ].take(6).toList();
        _pictureQueue.removeWhere(batch.contains);
        final files = [...base, ...packFiles];
        final maps = [for (final q in batch) q.$2];
        List<Uint8List?> found;
        try {
          found = await Isolate.run(() => [
                for (final m in maps)
                  MapScanner.findPicture(files: files, map: m, title: '', paletteFiles: palettes),
              ]);
        } catch (_) {
          found = List.filled(batch.length, null);
        }
        for (var i = 0; i < batch.length; i++) {
          batch[i].$3.complete(found[i]);
        }
      }
    } finally {
      _drainingPictures = false;
    }
  }

  Future<List<ProgressPack>>? _packs;

  @override
  void initState() {
    super.initState();
    _packs = _discover();
    _takeRequest();
    ProgressTab.selectRequest.addListener(_takeRequest);
  }

  @override
  void dispose() {
    ProgressTab.selectRequest.removeListener(_takeRequest);
    super.dispose();
  }

  void _takeRequest() {
    final id = ProgressTab.selectRequest.value;
    if (id == null) return;
    ProgressTab.selectRequest.value = null;
    setState(() => _selected = id);
  }

  @override
  void didUpdateWidget(ProgressTab old) {
    super.didUpdateWidget(old);
    if (old.gameFolder != widget.gameFolder || old.game != widget.game) _reload();
  }

  static void _invalidate() {
    _packsCache = null;
    _dataCache.clear();
  }

  /// Перечитать всё: список аддонов и файлы прогресса.
  void _reload() {
    _invalidate();
    final packs = _discover();
    setState(() {
      _packs = packs;
    });
  }

  Future<List<ProgressPack>>? _discover() {
    final folder = widget.gameFolder;
    if (!widget.game.hasProgress || folder == null) return null;
    final key = '${widget.game.id}|$folder';
    if (_packsCacheKey != key) {
      _packsCacheKey = key;
      _packsCache = null;
    }
    return _packsCache ??= () async {
      final files = await _gameFiles();
      // Пока только аддоны из репозиториев; файлы прогресса без аддона не ищем.
      return ProgressPack.discover(folder, files, await widget.candidates(),
          orphans: false, gameTitle: widget.game.fullName, kart: _kart);
    }();
  }

  /// SRB2Kart: kartdata.dat, медали, время и круг.
  bool get _kart => widget.game.id == 'srb2kart';

  Future<List<String>> _gameFiles() async {
    final files = await widget.gameFiles(widget.game.baseMapFiles);
    final palettes = await widget.gameFiles(widget.game.paletteFiles);
    return [...palettes.where((f) => !files.contains(f)), ...files];
  }

  /// Прогресс аддона; файл не изменился с прошлого раза — из кэша.
  Future<ProgressData> _data(ProgressPack pack) {
    DateTime? modified;
    try {
      modified = File(pack.gamedataPath).lastModifiedSync();
    } catch (_) {}
    final key = '${pack.gamedataPath}|${pack.files.join('|')}';
    final c = _dataCache[key];
    if (c != null && c.$1 == modified) return c.$2;
    final future = (() async =>
        ProgressData.load(pack.gamedataPath, await _gameFiles(), pack.files, !pack.orphan, _kart))();
    _dataCache[key] = (modified, future);
    return future;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.game.hasProgress) {
      return _message(Icons.info_outline, tr('Progress is shown only for Sonic Robo Blast 2, SRB2 Legacy, SRB2Kart and Ring Racers for now.'));
    }
    if (widget.gameFolder == null) {
      return _message(Icons.folder_off_outlined, tr('Set the game folder in Settings: gamedata.dat is there.'));
    }
    return FutureBuilder<List<ProgressPack>>(
      future: _packs,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
        if (snap.hasError) {
          return _message(Icons.error_outline, tr('Could not read gamedata.dat: {error}', {'error': snap.error!}),
              retry: true);
        }
        final packs = [for (final p in snap.data!) if (p.vanilla || !widget.hidden.contains(p.id)) p];
        final pack = packs.where((p) => p.id == _selected).firstOrNull ?? packs.first;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(packs, pack),
            Expanded(
              child: FutureBuilder<ProgressData>(
                key: ValueKey(pack.id),
                future: _data(pack),
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snap.hasError) {
                    if (snap.error is FormatException && File(pack.gamedataPath).existsSync()) {
                      return DamagedSaveView(
                          gameId: widget.game.id, path: pack.gamedataPath, error: snap.error!, onRestored: _reload);
                    }
                    return _message(Icons.error_outline,
                        tr('Could not read {file}: {error}', {'file': pack.id, 'error': snap.error!}),
                        retry: true);
                  }
                  return _buildProgress(snap.data!, pack);
                },
              ),
            ),
          ],
        );
      },
    );
  }

  /// «Играть»; пока запуск готовится (проверка сохранений) — «Checking…».
  Widget _playButton(List<String> files, {bool enabled = true}) => BuildSplitButton(
        launch: widget.launch,
        label: tr('Play game'),
        enabled: enabled,
        height: 40,
        horizontalPadding: 18,
        dropdownWidth: 34,
        onPressed: (exeId) => widget.onPlay(files, executableId: exeId),
      );

  /// Значки прохождения в списке: пройдена, на 100%, в Ultimate.
  List<Widget> _badges(ProgressPack p) {
    Widget badge(String text, String tip, Color color) => Padding(
          padding: const EdgeInsets.only(left: 6),
          child: Tooltip(
            message: tip,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.18),
                border: Border.all(color: color),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(text, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: color)),
            ),
          ),
        );
    return [
      if (p.complete)
        badge('100%', tr('Completed 100%: the game is beaten and all emblems are collected'), Colors.amber)
      else if (p.timesBeaten > 0)
        badge(tr('Beaten'), tr('The game is beaten'), Colors.green),
      if (p.timesBeatenUltimate > 0) badge('Ultimate', tr('Beaten in Ultimate mode'), Colors.redAccent),
    ];
  }

  /// Выбор: игра или аддон, скрыть аддон, показывать ли непосещённые уровни.
  Widget _header(List<ProgressPack> packs, ProgressPack pack) {
    String status(ProgressPack p) => p.orphan
        ? tr('addon not found')
        : !p.started
            ? tr('not started')
            : p.emblems > 0
                ? tr('emblems {got}/{all}', {'got': p.emblemsCollected, 'all': p.emblems})
                : tr('started');
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      child: Row(
        children: [
          Flexible(
            child: DropdownButton<String>(
              value: pack.id,
              isExpanded: true,
              items: [
                for (final p in packs)
                  DropdownMenuItem(
                    value: p.id,
                    child: Row(
                      children: [
                        Icon(p.vanilla ? Icons.sports_esports : (p.orphan ? Icons.help_outline : Icons.extension),
                            size: 18, color: Colors.grey),
                        const SizedBox(width: 8),
                        Flexible(child: Text(p.title, overflow: TextOverflow.ellipsis)),
                        const SizedBox(width: 8),
                        Text('· ${status(p)}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                        ..._badges(p),
                      ],
                    ),
                  ),
              ],
              onChanged: (v) => setState(() => _selected = v ?? ProgressPack.vanillaId),
            ),
          ),
          const SizedBox(width: 8),
          if (!pack.vanilla && (widget.isManual?.call(pack.files) ?? false))
            IconButton(
              icon: const Icon(Icons.playlist_remove),
              tooltip: tr('Remove this map pack from Progress (its files stay)'),
              onPressed: () async {
                await widget.onRemovePack?.call(pack.files);
                _selected = ProgressPack.vanillaId;
                _reload();
              },
            )
          else if (!pack.vanilla)
            IconButton(
              icon: const Icon(Icons.visibility_off_outlined),
              tooltip: tr('Hide from Progress (show it again in Settings)'),
              onPressed: () {
                widget.onHide(pack.id);
                setState(() => _selected = ProgressPack.vanillaId);
              },
            ),
          if (!pack.vanilla && !pack.orphan && widget.onEditPack != null)
            IconButton(
              icon: const Icon(Icons.edit_note),
              tooltip: tr('Edit the files of this map pack (which files, in what order)'),
              onPressed: () => _editFiles(pack),
            ),
          if (widget.onBackups != null)
            IconButton(
              icon: const Icon(Icons.history),
              tooltip: tr('Save backups'),
              onPressed: () async {
                if (await widget.onBackups!() && mounted) _reload();
              },
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: tr('Reload'),
            onPressed: _reload,
          ),
          if (widget.onAddPack != null)
            Tooltip(
              message: tr('Add a level pack from files on your computer (one or several files): its progress shows '
                  'here if it has its own GameData.'),
              child: TextButton.icon(
                icon: const Icon(Icons.library_add_outlined),
                label: Text(tr('Add Map Pack')),
                onPressed: () async {
                  final id = await widget.onAddPack!();
                  if (id == null || !mounted) return;
                  _selected = id;
                  _reload();
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _message(IconData icon, String text, {bool retry = false}) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 48, color: Colors.grey),
              const SizedBox(height: 12),
              Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey)),
              if (retry) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.refresh),
                  label: Text(tr('Reload')),
                  onPressed: _reload,
                ),
              ],
            ],
          ),
        ),
      );

  Widget _buildProgress(ProgressData d, ProgressPack pack) {
    final levels = d.defs.statsLevels(d.data, unvisited: _unvisited || !pack.started);
    final unlockables = [
      for (final u in (d.defs.unlockables.values.toList()..sort((a, b) => a.number - b.number)))
        if (u.listed) u,
    ];
    final accent = Theme.of(context).colorScheme.primary;
    return LayoutBuilder(
      builder: (context, box) {
        final columns = (box.maxWidth / 470).floor().clamp(1, 4);
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (pack.foreign)
              Card(
                color: Colors.orange.withValues(alpha: 0.15),
                child: ListTile(
                  leading: const Icon(Icons.warning_amber, color: Colors.orangeAccent),
                  title: Text(tr('{file} was written for another addon or game: the game will not accept it.',
                      {'file': pack.id})),
                ),
              ),
            if (pack.orphan)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.help_outline),
                  title: Text(tr('The addon of {file} is not found among your downloads: '
                      'levels are shown by map number, without names and emblems.', {'file': pack.id})),
                ),
              ),
            _summary(d, pack),
            const SizedBox(height: 20),
            _sectionTitle(tr('Levels ({n})', {'n': levels.length}), accent),
            if (levels.isEmpty)
              Text(tr('No levels visited yet.'), style: const TextStyle(color: Colors.grey))
            else
              for (var i = 0; i < levels.length; i += columns)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var j = i; j < i + columns; j++) ...[
                          if (j > i) const SizedBox(width: 10),
                          Expanded(
                              child: j < levels.length ? _levelCard(d, pack, levels[j]) : const SizedBox.shrink()),
                        ],
                      ],
                    ),
                  ),
                ),
            if (d.defs.extraEmblems.isNotEmpty) ...[
              const SizedBox(height: 10),
              _sectionTitle(tr('Extra emblems'), accent),
              Wrap(children: [for (var i = 0; i < d.defs.extraEmblems.length; i++) _cell(_extraEmblem(d, i))]),
            ],
            if (unlockables.isNotEmpty) ...[
              const SizedBox(height: 20),
              _sectionTitle(tr('Secrets'), accent),
              Wrap(children: [for (final u in unlockables) _cell(_unlockable(d, u))]),
            ],
          ],
        );
      },
    );
  }

  /// Строка списка эмблем и секретов — колонками по ширине окна.
  static Widget _cell(Widget child) => SizedBox(width: 380, child: child);

  Widget _sectionTitle(String text, Color accent) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(text, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: accent)),
      );

  // --- Сводка (Statistics) ---

  Widget _summary(ProgressData d, ProgressPack pack) {
    final c = d.combined;
    final t = d.data.totalPlayTime ~/ 35;
    final playTime = tr('{h} h {m} min {s} s', {'h': t ~/ 3600, 'm': t ~/ 60 % 60, 's': t % 60});
    Widget stat(String label, String value, {Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(width: 80, child: Text(label, maxLines: 1, style: const TextStyle(color: Colors.grey))),
              Text(value, style: TextStyle(fontWeight: FontWeight.bold, color: color)),
            ],
          ),
        );
    final unfinished = c.unfinished > 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _summaryStats(d, pack, stat, playTime, unfinished, c)),
            const SizedBox(width: 16),
            // Справа: «Играть» и непосещённые уровни.
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Tooltip(
                  message: pack.vanilla
                      ? tr('Start the game without addons and without the Launch parameters, so it saves your progress.')
                      : tr('Start the game with only this level pack: no Launch parameters, no other addons and no '
                          '-warp, so the game saves your progress.'),
                  child: _playButton(pack.files, enabled: !pack.orphan),
                ),
                const SizedBox(height: 10),
                FilterChip(
                  label: Text(tr('Unvisited levels')),
                  tooltip: tr('Also show levels you have not visited yet (the game hides them in Statistics)'),
                  selected: _unvisited || !pack.started,
                  onSelected: pack.started ? (v) => setState(() => _unvisited = v) : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _summaryStats(ProgressData d, ProgressPack pack, Widget Function(String, String, {Color? color}) stat,
      String playTime, bool unfinished, ({int score, int time, int rings, int unfinished}) c) {
    return Wrap(
          spacing: 40,
          runSpacing: 16,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr('Total play time'), style: const TextStyle(color: Colors.grey)),
                Text(playTime, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 10),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (d.icons['EMBLICON'] case final icon?) ...[
                      _pixel(icon, 22),
                      const SizedBox(width: 8),
                    ],
                    Text('× ${d.emblemsCollected}/${d.emblemCount}',
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  ],
                ),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr('Combined records'), style: const TextStyle(color: Colors.grey)),
                Text(
                  unfinished ? tr('{n} unfinished', {'n': c.unfinished}) : tr('complete'),
                  style: TextStyle(color: unfinished ? Colors.redAccent : Colors.green, fontSize: 12),
                ),
                const SizedBox(height: 4),
                if (!_kart) stat(tr('Score'), '${c.score}'),
                stat(tr('Time'), formatTics(c.time, hours: true)),
                if (!_kart) stat(tr('Rings'), '${c.rings}'),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Kart: сыграно матчей (за них — доп. эмблемы), кубки Гран-при пройдены.
                if (_kart) ...[
                  Text(tr('Matches played'), style: const TextStyle(color: Colors.grey)),
                  Text('${d.data.matchesPlayed}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(tr('Grand Prix won: {n}', {'n': d.data.timesBeaten})),
                ] else ...[
                  Text(tr('Game completed'), style: const TextStyle(color: Colors.grey)),
                  Text(tr('{n} time(s)', {'n': d.data.timesBeaten}),
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(tr('with all emeralds: {n}', {'n': d.data.timesBeatenWithEmeralds})),
                  Text(tr('in Ultimate mode: {n}', {'n': d.data.timesBeatenUltimate})),
                ],
              ],
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Tooltip(
                  message: d.path,
                  child: Text(d.path,
                      maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                ),
                Text(
                    d.modified == null
                        ? tr('Not started yet: the game creates the file when you play this addon.')
                        : tr('Saved by the game: {time}', {'time': _formatDate(d.modified!)}),
                    style: const TextStyle(fontSize: 11, color: Colors.grey)),
              ],
              ),
            ),
          ],
    );
  }

  /// Ручная правка файлов пака: какие файлы и в каком порядке грузятся.
  Future<void> _editFiles(ProgressPack pack) async {
    final files = await showDialog<List<String>>(
      context: context,
      builder: (_) => _PackFilesDialog(title: pack.title, files: pack.files),
    );
    if (files == null || !mounted || listEquals(files, pack.files)) return;
    final id = await widget.onEditPack!(pack, files);
    if (id == null || !mounted) return;
    _selected = id;
    _reload();
  }

  static String _formatDate(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.day)}.${two(t.month)}.${t.year} ${two(t.hour)}:${two(t.minute)}';
  }

  /// Пиксельная картинка без сглаживания.
  static Widget _pixel(Uint8List png, double size) => Image.memory(png,
      width: size, height: size, fit: BoxFit.contain, filterQuality: FilterQuality.none, gaplessPlayback: true);

  // --- Уровень (Record Attack) ---

  Widget _levelCard(ProgressData d, ProgressPack pack, ProgressLevel level) {
    final emblems = d.defs.emblemsOf(level.map);
    final record = d.data.records[level.map];
    final nights = d.data.nights[level.map];
    final visited = d.data.mapVisited[level.map - 1];
    final mapName = MapScanner.mapName(level.map);
    ProgressEmblem? target(EmblemType t) => emblems.where((e) => e.$2.type == t).firstOrNull?.$2;
    int? targetIndex(EmblemType t) => emblems.where((e) => e.$2.type == t).firstOrNull?.$1;

    Widget emblemIcon(int index, ProgressEmblem e, {double size = 22}) {
      final got = d.collected(index);
      final png = d.icon(e.sprite, e.color, got);
      // Подсказка эмблемы — с цветами SRB2 (^2yellow^ и т.п.).
      return srb2Tooltip(
        TextSpan(children: [
          // Подсказка эмблемы — из SOC игры (с цветами), остальное — перевод.
          if (e.type == EmblemType.global && e.hint.isNotEmpty) srb2RichText(e.hint) else TextSpan(text: _emblemText(e)),
          TextSpan(text: '\n${got ? tr('Collected') : tr('Not collected yet')}'),
        ]),
        Padding(
          padding: const EdgeInsets.only(right: 2),
          child: png == null
              ? Icon(got ? Icons.star : Icons.star_border, size: size, color: got ? Colors.amber : Colors.grey)
              : _pixel(png, size),
        ),
      );
    }

    Widget row(String label, String value, {String? goal, EmblemType? emblem}) {
      final i = emblem == null ? null : targetIndex(emblem);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          children: [
            SizedBox(
              width: 64,
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.grey, fontSize: 12)),
            ),
            Expanded(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: value, style: const TextStyle(fontWeight: FontWeight.bold)),
                  if (goal != null) TextSpan(text: '  ($goal)', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                ]),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (i != null) emblemIcon(i, d.defs.emblems[i], size: 18),
          ],
        ),
      );
    }

    final timeGoal = target(EmblemType.time);
    final ringsGoal = target(EmblemType.rings);
    final scoreGoal = target(EmblemType.score);
    final gradeGoal = target(EmblemType.nightsGrade);
    final nightsTimeGoal = target(EmblemType.nightsTime);
    final flags = [
      if (visited & MapVisit.beaten != 0) (Icons.flag, tr('Beaten')),
      if (visited & MapVisit.allEmeralds != 0) (Icons.diamond_outlined, tr('Beaten with all emeralds')),
      if (visited & MapVisit.ultimate != 0) (Icons.local_fire_department_outlined, tr('Beaten in Ultimate mode')),
      if (visited & MapVisit.perfect != 0) (Icons.workspace_premium_outlined, tr('Perfect bonus')),
    ];

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Column(
              children: [
                _picture(pack, level),
                const SizedBox(height: 6),
                Text(mapName, style: const TextStyle(fontSize: 11, color: Colors.grey)),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  srb2Title(level.fullTitle,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold), maxLines: 2),
                  if (level.subtitle.isNotEmpty)
                    srb2Title(level.subtitle, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      for (final (i, e) in emblems) emblemIcon(i, e),
                      const Spacer(),
                      for (final (icon, tip) in flags)
                        Tooltip(message: tip, child: Icon(icon, size: 16, color: Colors.amber)),
                    ],
                  ),
                  const Divider(height: 14),
                  if (nights != null && nights.isNotEmpty) ...[
                    row(tr('Grade'), nightsGrade(nights[0].grade),
                        goal: gradeGoal == null ? null : nightsGrade(gradeGoal.target), emblem: EmblemType.nightsGrade),
                    row(tr('Score'), '${nights[0].score}'),
                    row(tr('Time'), formatTics(nights[0].time),
                        goal: nightsTimeGoal == null ? null : formatTics(nightsTimeGoal.target),
                        emblem: EmblemType.nightsTime),
                    if (nights.length > 2)
                      for (var m = 1; m < nights.length; m++)
                        Text(
                          tr('Mare {n}: {grade} · {score} · {time}', {
                            'n': m,
                            'grade': nightsGrade(nights[m].grade),
                            'score': nights[m].score,
                            'time': formatTics(nights[m].time),
                          }),
                          style: const TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                  ] else if (_kart) ...[
                    // Kart: лучшее время и лучший круг (медали — значками выше).
                    row(tr('Time'), record == null || record.time == 0 ? '—' : formatTics(record.time),
                        goal: timeGoal == null ? null : formatTics(timeGoal.target), emblem: EmblemType.time),
                    row(tr('Lap'), d.data.bestLaps[level.map] == null ? '—' : formatTics(d.data.bestLaps[level.map]!)),
                  ] else if (record != null || level.recordAttack) ...[
                    row(tr('Score'), record == null ? '—' : '${record.score}',
                        goal: scoreGoal == null ? null : '${scoreGoal.target}', emblem: EmblemType.score),
                    row(tr('Time'), record == null || record.time == 0 ? '—' : formatTics(record.time),
                        goal: timeGoal == null ? null : formatTics(timeGoal.target), emblem: EmblemType.time),
                    row(tr('Rings'), record == null ? '—' : '${record.rings}',
                        goal: ringsGoal == null ? null : '${ringsGoal.target}', emblem: EmblemType.rings),
                  ] else
                    Text(tr('No Record Attack on this level.'),
                        style: const TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Что нужно для эмблемы — для подсказки.
  static String _emblemText(ProgressEmblem e) => switch (e.type) {
        EmblemType.global => e.hint.isEmpty ? tr('Hidden on the level') : e.hint,
        EmblemType.time => tr('Time: beat {time}', {'time': formatTics(e.target)}),
        EmblemType.rings => tr('Rings: collect {n}', {'n': e.target}),
        EmblemType.score => tr('Score: get {n}', {'n': e.target}),
        EmblemType.nightsGrade => tr('NiGHTS: grade {grade} or better', {'grade': nightsGrade(e.target)}),
        EmblemType.nightsTime => tr('NiGHTS: beat {time}', {'time': formatTics(e.target)}),
        EmblemType.skin => tr('Beat the level as a certain character'),
        EmblemType.map => tr('Beat the level'),
        EmblemType.unknown => tr('Emblem'),
      };

  /// Картинка уровня: из файлов аддона (они грузятся после игры и заменяют
  /// её карты), затем из файлов игры.
  Widget _picture(ProgressPack pack, ProgressLevel level) {
    const w = 128.0, h = 80.0;
    Widget placeholder() =>
        Image.asset('assets/map_unknown.png', width: w, height: h, fit: BoxFit.cover, filterQuality: FilterQuality.none);
    final map = MapScanner.mapName(level.map);
    final future = _pictures.putIfAbsent('${widget.gameFolder}|${pack.files.join('|')}|$map', () {
      final c = Completer<Uint8List?>();
      _pictureQueue.add((pack.files, map, c));
      _drainPictures();
      return c.future;
    });
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: FutureBuilder<Uint8List?>(
        future: future,
        builder: (context, snap) {
          final image = snap.data;
          if (image == null) {
            return snap.connectionState == ConnectionState.done
                ? placeholder()
                : const SizedBox(width: w, height: h, child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
          }
          return Image.memory(image,
              width: w,
              height: h,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.none,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => placeholder());
        },
      ),
    );
  }

  // --- Дополнительные эмблемы и секреты ---

  Widget _extraEmblem(ProgressData d, int i) {
    final e = d.defs.extraEmblems[i];
    final got = i < d.data.extraCollected.length && d.data.extraCollected[i];
    final png = d.icon(e.sprite, e.color, got);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: png == null
          ? Icon(got ? Icons.star : Icons.star_border, color: got ? Colors.amber : Colors.grey)
          : _pixel(png, 24),
      title: srb2Title(e.name, maxLines: 2),
      subtitle: Text.rich(srb2RichText(e.objective)),
    );
  }

  Widget _unlockable(ProgressData d, Unlockable u) {
    final i = u.number - 1;
    final got = i >= 0 && i < d.data.unlocked.length && d.data.unlocked[i];
    // Как в чек-листе игры: скрытый (NoChecklist) и не открытый — «???».
    final secret = !got && u.noChecklist;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(got ? Icons.lock_open : Icons.lock_outline, color: got ? Colors.green : Colors.grey),
      title: secret ? const Text('???') : srb2Title(u.name, maxLines: 2),
      subtitle: Text.rich(srb2RichText(u.objective)),
    );
  }
}

/// Файлы левелпака для Progress: порядок загрузки (перетаскиванием),
/// убрать файл, добавить ещё. Возвращает новый список или null (отмена).
class _PackFilesDialog extends StatefulWidget {
  final String title;
  final List<String> files;

  const _PackFilesDialog({required this.title, required this.files});

  @override
  State<_PackFilesDialog> createState() => _PackFilesDialogState();
}

class _PackFilesDialogState extends State<_PackFilesDialog> {
  late final List<String> _files = [...widget.files];

  Future<void> _add() async {
    final picked = await openFiles(acceptedTypeGroups: [
      XTypeGroup(label: tr('Game addons'), extensions: [
        for (final e in PlatformUtils.addonExtensions) ...[e, e.toUpperCase()],
      ]),
    ], confirmButtonText: tr('Add'));
    if (!mounted || picked.isEmpty) return;
    setState(() {
      for (final f in picked) {
        final path = p.normalize(f.path);
        if (!_files.any((x) => PlatformUtils.samePath(x, path))) _files.add(path);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('Files of {name}', {'name': widget.title})),
      content: SizedBox(
        width: 620,
        height: 360,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('The game loads them from top to bottom: the pack\'s SOC (GameData, levels, emblems) is read in '
                'this order. Drag to reorder.'),
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 8),
            Expanded(
              // DragBoundary: перетаскиваемый файл не выходит за рамку списка.
              child: DragBoundary(
                child: ReorderableListView.builder(
                buildDefaultDragHandles: false,
                dragBoundaryProvider: DragBoundary.forRectOf,
                itemCount: _files.length,
                onReorderItem: (from, to) => setState(() => _files.insert(to, _files.removeAt(from))),
                itemBuilder: (context, i) {
                  final f = _files[i];
                  final exists = File(f).existsSync();
                  return ListTile(
                    key: ValueKey(f),
                    dense: true,
                    leading: ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_indicator)),
                    title: Text('${i + 1}. ${p.basename(f)}'),
                    subtitle: Text(exists ? f : tr('Missing: {path}', {'path': f}),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: exists ? Colors.grey : Colors.redAccent)),
                    trailing: IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      tooltip: tr('Remove from the list'),
                      onPressed: () => setState(() => _files.removeAt(i)),
                    ),
                  );
                },
              ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(icon: const Icon(Icons.add), label: Text(tr('Add files...')), onPressed: _add),
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
        FilledButton(
          onPressed: _files.isEmpty ? null : () => Navigator.pop(context, _files),
          child: Text(tr('Save')),
        ),
      ],
    );
  }
}
