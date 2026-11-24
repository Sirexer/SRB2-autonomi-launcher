import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../i18n.dart';
import '../models/game.dart';
import '../services/app_log.dart';
import '../services/custom_games.dart';
import '../services/platform_utils.dart';
import 'appearance_pickers.dart';
import 'game_icon.dart';
import 'games_settings.dart' show gameSubtitle;

/// Что выбрано в мастере первого запуска.
class FirstRunChoice {
  /// Подключить репозиторий из pointer.txt.
  final bool connectRepository;

  /// Встроенные игры, которые выключены (SRB2 — никогда).
  final Set<String> disabledGames;

  /// Свои игры из another_games.json, которые добавить, и те, от которых
  /// отказались (если были добавлены раньше — убрать).
  final List<Map<String, dynamic>> addGames;
  final Set<String> declinedGames;

  /// Папки и сборки игр (код игры → пути; пустые не указаны).
  final Map<String, ({String folder, String executable})> paths;

  final bool player;
  final bool progress;
  final bool replays;
  final bool saveProtection;

  const FirstRunChoice({
    required this.connectRepository,
    required this.disabledGames,
    required this.addGames,
    required this.declinedGames,
    required this.paths,
    required this.player,
    required this.progress,
    required this.replays,
    required this.saveProtection,
  });
}

enum _Step { appearance, repository, games, experimental }

/// Мастер первого запуска: язык и тема, репозиторий из pointer.txt (если
/// есть), игры (какие показывать, затем их папки и сборки — по желанию),
/// экспериментальные функции.
class FirstRunWizard extends StatefulWidget {
  /// Pointer из pointer.txt; null — шага с репозиторием нет.
  final String? pointer;

  /// Описания из another_games.json: (описание, игра или null, ошибка).
  final List<(Map<String, dynamic>, GameDef?, String?)> bundledGames;

  /// Тема сейчас и её смена (сразу видна).
  final String themeKey;
  final ValueChanged<String> onThemeChanged;

  /// Уже указанные папка и сборка игры (если мастер открыт не впервые).
  final Future<String?> Function(GameDef game) folderOf;
  final Future<String?> Function(GameDef game) executableOf;

  final bool player;
  final bool progress;
  final bool replays;
  final bool saveProtection;

  const FirstRunWizard({
    super.key,
    this.pointer,
    this.bundledGames = const [],
    required this.themeKey,
    required this.onThemeChanged,
    required this.folderOf,
    required this.executableOf,
    required this.player,
    required this.progress,
    this.replays = false,
    required this.saveProtection,
  });

  static Future<FirstRunChoice?> show(BuildContext context, FirstRunWizard wizard) => showDialog<FirstRunChoice>(
        context: context,
        barrierDismissible: false,
        builder: (_) => wizard,
      );

  @override
  State<FirstRunWizard> createState() => _FirstRunWizardState();
}

class _FirstRunWizardState extends State<FirstRunWizard> {
  late final List<_Step> _steps = [
    _Step.appearance,
    if (widget.pointer != null) _Step.repository,
    _Step.games,
    _Step.experimental,
  ];
  int _index = 0;

  /// Шаг «Игры» из двух страниц: выбор игр, затем их папки и сборки.
  bool _gamePaths = false;

  late String _theme = widget.themeKey;
  bool _connect = true;
  late final Set<String> _disabled = {
    for (final g in Games.builtIn)
      if (!Games.isEnabled(g)) g.id,
  };

  /// Свои игры из файла: какие отмечены (по умолчанию — все без ошибок).
  late final List<(Map<String, dynamic>, GameDef)> _bundled = [
    for (final (def, game, _) in widget.bundledGames)
      if (game != null) (def, game),
  ];
  late final Set<String> _addIds = {for (final (_, g) in _bundled) g.id};

  /// Поля путей по коду игры: папка и сборка.
  final Map<String, TextEditingController> _folders = {};
  final Map<String, TextEditingController> _exes = {};

  late bool _player = widget.player;
  late bool _progress = widget.progress;
  late bool _replays = widget.replays;
  late bool _saveProtection = widget.saveProtection;

  _Step get _step => _steps[_index];
  bool get _last => _index == _steps.length - 1;

  /// Игры, которые будут в переключателе.
  List<GameDef> get _chosenGames => [
        for (final g in Games.builtIn)
          if (g == Games.srb2 || !_disabled.contains(g.id)) g,
        for (final (_, g) in _bundled)
          if (_addIds.contains(g.id)) g,
        for (final g in Games.custom)
          if (Games.isEnabled(g) && !_bundled.any((b) => b.$2.id == g.id)) g,
      ];

  @override
  void dispose() {
    for (final c in [..._folders.values, ..._exes.values]) {
      c.dispose();
    }
    super.dispose();
  }

  void _next() {
    if (_step == _Step.games && !_gamePaths) {
      _prepareGamePaths();
      setState(() => _gamePaths = true);
    } else if (_last) {
      _finish();
    } else {
      setState(() => _index++);
    }
  }

  void _back() {
    if (_step == _Step.games && _gamePaths) {
      setState(() => _gamePaths = false);
    } else {
      setState(() {
        _index--;
        // Назад на «Игры» — к последней странице шага.
        if (_step == _Step.games) _gamePaths = true;
      });
    }
  }

  /// Поля путей для выбранных игр: уже указанные пути, иначе найденная
  /// папка игры и сборка в ней.
  void _prepareGamePaths() {
    for (final g in _chosenGames) {
      if (_folders.containsKey(g.id)) continue;
      final folder = _folders[g.id] = TextEditingController();
      final exe = _exes[g.id] = TextEditingController();
      () async {
        final known = await widget.folderOf(g) ?? await PlatformUtils.detectGameFolder(g);
        final knownExe = await widget.executableOf(g);
        if (!mounted) return;
        setState(() {
          if (folder.text.isEmpty && known != null) folder.text = known;
          if (exe.text.isEmpty) exe.text = knownExe ?? _findExecutable(g, folder.text) ?? '';
        });
      }();
    }
  }

  /// Сборка игры [g] в папке [folder] по известным именам; null — нет.
  static String? _findExecutable(GameDef g, String folder) {
    if (folder.trim().isEmpty) return null;
    final names = Platform.isWindows ? g.windowsExecutables : g.linuxExecutables;
    for (final name in names) {
      final f = File(p.join(folder.trim(), name));
      if (f.existsSync()) return f.path;
    }
    return null;
  }

  String? _folderError(String id) {
    final v = PlatformUtils.cleanUserPath(_folders[id]?.text ?? '');
    return v.isEmpty || Directory(v).existsSync() ? null : tr('Folder does not exist');
  }

  /// Сборка: путь к файлу или команда без папки (есть в PATH).
  String? _exeError(String id) {
    final v = PlatformUtils.cleanUserPath(_exes[id]?.text ?? '');
    if (v.isEmpty || !v.contains('/') && !v.contains(r'\')) return null;
    return File(v).existsSync() ? null : tr('No such file');
  }

  bool get _pathsOk => _chosenGames.every((g) => _folderError(g.id) == null && _exeError(g.id) == null);

  void _finish() {
    Navigator.pop(
      context,
      FirstRunChoice(
        connectRepository: widget.pointer != null && _connect,
        disabledGames: _disabled,
        addGames: [for (final (def, g) in _bundled) if (_addIds.contains(g.id)) def],
        declinedGames: {for (final (_, g) in _bundled) if (!_addIds.contains(g.id)) g.id},
        paths: {
          for (final g in _chosenGames)
            if (PlatformUtils.cleanUserPath(_folders[g.id]?.text ?? '').isNotEmpty ||
                PlatformUtils.cleanUserPath(_exes[g.id]?.text ?? '').isNotEmpty)
              g.id: (
                folder: PlatformUtils.cleanUserPath(_folders[g.id]?.text ?? ''),
                executable: PlatformUtils.cleanUserPath(_exes[g.id]?.text ?? ''),
              ),
        },
        player: _player,
        progress: _progress,
        replays: _replays,
        saveProtection: _saveProtection,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final canGoOn = !(_step == _Step.games && _gamePaths) || _pathsOk;
    return Dialog(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: SizedBox(
        width: 680,
        height: (MediaQuery.sizeOf(context).height - 48).clamp(360, 680).toDouble(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 24, 28, 4),
              child: Text(tr('Welcome to SRB2 Autonomi Launcher'),
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 0, 28, 12),
              child: Text(tr('A few questions before you start. Everything can be changed later in Settings.'),
                  style: const TextStyle(fontSize: 13, color: Colors.grey)),
            ),
            _stepper(accent),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                // Своя прокрутка у каждой страницы — не с середины прошлой.
                key: ValueKey((_step, _gamePaths)),
                padding: const EdgeInsets.fromLTRB(28, 16, 28, 16),
                children: switch (_step) {
                  _Step.appearance => _appearance(),
                  _Step.repository => _repository(),
                  _Step.games => _gamePaths ? _paths() : _games(),
                  _Step.experimental => _experimental(),
                },
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              child: Row(
                children: [
                  Text(tr('Step {n} of {total}', {'n': _index + 1, 'total': _steps.length}),
                      style: const TextStyle(color: Colors.grey)),
                  const Spacer(),
                  if (_index > 0 || _gamePaths) TextButton(onPressed: _back, child: Text(tr('Back'))),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: canGoOn ? _next : null,
                    child: Text(_last ? tr('Finish') : tr('Next')),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Шаги наверху: пройденные и текущий подсвечены.
  Widget _stepper(Color accent) {
    String label(_Step s) => switch (s) {
          _Step.appearance => tr('Language'),
          _Step.repository => tr('Repository'),
          _Step.games => tr('Games'),
          _Step.experimental => tr('Experimental'),
        };
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 0, 28, 12),
      child: Row(
        children: [
          for (var i = 0; i < _steps.length; i++) ...[
            if (i > 0)
              Expanded(
                child: Container(
                  height: 2,
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  color: i <= _index ? accent : Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
            CircleAvatar(
              radius: 12,
              backgroundColor: i <= _index ? accent : Theme.of(context).colorScheme.outlineVariant,
              child: i < _index
                  ? Icon(Icons.check, size: 14, color: Theme.of(context).colorScheme.onPrimary)
                  : Text('${i + 1}',
                      style: TextStyle(
                          fontSize: 12,
                          color: i <= _index
                              ? Theme.of(context).colorScheme.onPrimary
                              : Theme.of(context).colorScheme.onSurface)),
            ),
            const SizedBox(width: 6),
            Text(label(_steps[i]),
                style: TextStyle(fontWeight: i == _index ? FontWeight.bold : FontWeight.normal)),
          ],
        ],
      ),
    );
  }

  Widget _hint(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(text, style: const TextStyle(fontSize: 13, color: Colors.grey)),
      );

  Widget _title(String text) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 8),
        child: Text(text, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
      );

  List<Widget> _appearance() => [
        _title(tr('Language')),
        _hint(tr('The language of your system is chosen if the launcher has it.')),
        LanguageDropdown(onChanged: () {
          if (mounted) setState(() {});
        }),
        const SizedBox(height: 24),
        _title(tr('Color theme')),
        ThemeDropdown(
          value: _theme,
          onChanged: (v) {
            setState(() => _theme = v);
            widget.onThemeChanged(v);
          },
        ),
      ];

  List<Widget> _repository() => [
        _hint(tr('Addons are downloaded from repositories on the Autonomi network. pointer.txt next to the launcher '
            'names a repository to start with.')),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: _connect,
          onChanged: (v) => setState(() => _connect = v ?? false),
          title: Text(tr('Download and connect this repository')),
          subtitle: SelectableText(widget.pointer!, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ),
        _hint(tr('It is downloaded in the background once Autonomi starts. Other repositories can be added later '
            'with "Add Repository".')),
      ];

  List<Widget> _games() => [
        _hint(tr('Which games to show in the game switcher. Turned-off games can be turned on later in '
            'Settings → Games.')),
        for (final g in Games.builtIn)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            value: g == Games.srb2 || !_disabled.contains(g.id),
            onChanged: g == Games.srb2
                ? null
                : (v) => setState(() => v == true ? _disabled.remove(g.id) : _disabled.add(g.id)),
            secondary: GameIcon(g, size: 32),
            title: Text(g.fullName),
            subtitle: Text(g == Games.srb2 ? tr('Always on') : gameSubtitle(g)),
          ),
        if (_bundled.isNotEmpty) ...[
          const Divider(height: 16),
          _hint(tr('Custom games (forks) that come with the launcher. A game you skip is not added; it can be added '
              'later only from its JSON (Settings → Games → Add games from JSON).')),
          for (final (_, g) in _bundled)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              value: _addIds.contains(g.id),
              onChanged: (v) => setState(() => v == true ? _addIds.add(g.id) : _addIds.remove(g.id)),
              secondary: GameIcon(g, size: 32),
              title: Text(g.fullName),
              subtitle: Text(gameSubtitle(g)),
            ),
        ],
      ];

  /// Папки и сборки выбранных игр (необязательно).
  List<Widget> _paths() => [
        _hint(tr('Where the games are: the game folder (config, saves, addons) and the executable that starts the '
            'game. Optional — leave empty and set it later in Settings → Game folder and Launch.')),
        for (final g in _chosenGames) _gamePathsCard(g),
      ];

  Widget _gamePathsCard(GameDef g) {
    final folder = _folders[g.id]!;
    final exe = _exes[g.id]!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GameIcon(g, size: 24),
              const SizedBox(width: 8),
              Text(g.fullName, style: const TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 8),
          _pathField(
            controller: folder,
            label: tr('Game folder'),
            hint: Platform.isWindows ? tr('The folder with {file}', {'file': g.mainFile}) : '~/${g.linuxDataFolders.firstOrNull ?? ''}',
            error: _folderError(g.id),
            icon: Icons.folder_open,
            tooltip: tr('Choose folder'),
            onChanged: () {
              // Нашлась папка — сборка в ней, если поле сборки пустое.
              if (exe.text.trim().isEmpty) exe.text = _findExecutable(g, PlatformUtils.cleanUserPath(folder.text)) ?? '';
            },
            pick: () async {
              AppLog.action('open the getDirectoryPath dialog (first_run_wizard.dart)');
              final current = PlatformUtils.cleanUserPath(folder.text);
              return getDirectoryPath(initialDirectory: Directory(current).existsSync() ? current : null);
            },
          ),
          const SizedBox(height: 8),
          _pathField(
            controller: exe,
            label: tr('Executable'),
            hint: Platform.isWindows ? g.windowsCommand : g.linuxCommand,
            error: _exeError(g.id),
            icon: Icons.insert_drive_file_outlined,
            tooltip: tr('Choose file'),
            pick: () async {
              AppLog.action('open the openFile dialog (first_run_wizard.dart)');
              final current = PlatformUtils.cleanUserPath(folder.text);
              final file = await openFile(initialDirectory: Directory(current).existsSync() ? current : null);
              return file?.path;
            },
          ),
        ],
      ),
    );
  }

  Widget _pathField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required String? error,
    required IconData icon,
    required String tooltip,
    required Future<String?> Function() pick,
    VoidCallback? onChanged,
  }) =>
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: (_) => setState(() => onChanged?.call()),
              decoration: InputDecoration(
                labelText: label,
                hintText: hint,
                errorText: error,
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: Icon(icon),
            tooltip: tooltip,
            onPressed: () async {
              final path = await pick();
              if (path == null || !mounted) return;
              setState(() {
                controller.text = path;
                onChanged?.call();
              });
            },
          ),
        ],
      );

  List<Widget> _experimental() => [
        _hint(tr('Features that are still being tried out. They are off until you turn them on.')),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _player,
          onChanged: (v) => setState(() => _player = v),
          title: Text(tr('Music player')),
          subtitle: Text(tr('A Music tab after Servers: music of all games from the game files, downloaded addons and files you open (OGG, MP3, FLAC, WAV, MIDI).')),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _progress,
          onChanged: (v) => setState(() => _progress = v),
          title: Text(tr('Progress')),
          subtitle: Text(tr('A Progress tab: single player progress of Sonic Robo Blast 2, SRB2 Legacy and their level '
              'packs (gamedata.dat and the addon\'s own GameData) — play time, records, emblems and secrets, like '
              'Statistics and Record Attack in the game.')),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _replays,
          onChanged: (v) => setState(() => _replays = v),
          title: Text(tr('Replays')),
          subtitle: Text(tr('A Replays tab for Sonic Robo Blast 2: browse recorded .lmp replays, import or download '
              'them into SRB2AL-Replays, inspect maps, characters and required addons, and play them back.')),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _saveProtection,
          onChanged: (v) => setState(() => _saveProtection = v),
          title: Text(tr('Save protection')),
          subtitle: Text(tr('Before the game starts, the launcher checks the save files it will use (progress and '
              'single player saves) and keeps the last whole copy of each. If a file is damaged (for example, the PC '
              'turned off while the game was saving), it is restored from the copy; the damaged file is kept.')),
        ),
      ];
}

/// Свои игры из another_games.json рядом с лаунчером (пусто — файла нет
/// или он не читается).
Future<List<(Map<String, dynamic>, GameDef?, String?)>> bundledGameDefinitions() async {
  final path = CustomGames.bundledPath();
  if (path == null) return const [];
  try {
    return await CustomGames.readFile(path);
  } catch (_) {
    return const [];
  }
}
