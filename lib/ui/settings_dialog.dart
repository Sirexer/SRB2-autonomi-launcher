import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../build_info.dart';
import '../services/app_log.dart';
import '../i18n.dart';
import '../models/game.dart';
import '../services/launch_settings.dart';
import '../services/platform_utils.dart';
import '../services/app_paths.dart';
import '../services/save_guard.dart';
import '../services/servers_store.dart';
import '../theme/app_themes.dart';
import 'addon_icon.dart';
import 'file_actions.dart';
import 'launch_panel.dart';
import 'snack.dart';

/// Что делать при запуске, если репозиторий по pointer указывает на новый
/// файл: обновить сразу, спросить или не проверять.
enum RepositoryUpdates { auto, ask, off }

/// Порядок тегов на странице аддона: по алфавиту или по группам (порядок
/// групп — как в tag_groups, внутри группы — по алфавиту).
enum TagOrder { alphabetical, groups }

/// Как показывать теги на странице аддона.
typedef TagDisplay = ({bool showGroup, TagOrder order, bool showAll});

/// Разделы настроек.
enum SettingsSection { general, game, addons, launch, servers, experimental }

/// Окно настроек: разделы слева, содержимое справа. Изменения применяются сразу.
class SettingsDialog extends StatefulWidget {
  final SettingsSection initialSection;
  final String? gameFolder;

  /// Меняет папку игры; возвращает текст ошибки или null.
  final Future<String?> Function(String folder) onGameFolderChanged;
  final String hiddenTags;
  final ValueChanged<String> onHiddenTagsChanged;
  final bool autoHideTags;
  final ValueChanged<bool> onAutoHideTagsChanged;

  /// Скачивать в `DOWNLOAD/<аддон>/<версия>/` (иначе прямо в DOWNLOAD).
  final bool versionFolders;
  final ValueChanged<bool> onVersionFoldersChanged;

  /// Экспериментальная вкладка «Плеер».
  final bool playerEnabled;
  final ValueChanged<bool> onPlayerEnabledChanged;
  final bool progressEnabled;
  final ValueChanged<bool> onProgressEnabledChanged;

  /// «Защита сохранений» (Experimental).
  final ValueChanged<bool> onSaveProtectionChanged;

  /// Аддоны, скрытые из Progress, и вернуть один.
  final List<String> progressHidden;
  final ValueChanged<String> onProgressUnhide;

  /// Показывать раздел «Другие загрузки» на вкладке Addons.
  final bool showOtherDownloads;
  final ValueChanged<bool> onShowOtherDownloadsChanged;
  final bool showFolderAddons;
  final ValueChanged<bool> onShowFolderAddonsChanged;

  /// Перезапуск демона Autonomi (antd); true — запустился.
  final Future<bool> Function() onRestartAutonomi;

  /// Какие обложки аддонов анимировать.
  final AddonIconAnimation iconAnimation;
  final ValueChanged<AddonIconAnimation> onIconAnimationChanged;
  final RepositoryUpdates repositoryUpdates;
  final ValueChanged<RepositoryUpdates> onRepositoryUpdatesChanged;

  /// Кнопка ⟳ у каждого репозитория.
  final bool repositoryUpdateButtons;
  final ValueChanged<bool> onRepositoryUpdateButtonsChanged;
  final TagDisplay tagDisplay;
  final ValueChanged<TagDisplay> onTagDisplayChanged;
  final String themeKey;
  final ValueChanged<String> onThemeChanged;
  final LaunchSettings launch;
  final ServersStore servers;

  const SettingsDialog({
    super.key,
    this.initialSection = SettingsSection.general,
    required this.gameFolder,
    required this.onGameFolderChanged,
    required this.hiddenTags,
    required this.onHiddenTagsChanged,
    required this.autoHideTags,
    required this.onAutoHideTagsChanged,
    required this.versionFolders,
    required this.onVersionFoldersChanged,
    required this.playerEnabled,
    required this.onPlayerEnabledChanged,
    required this.progressEnabled,
    required this.onProgressEnabledChanged,
    required this.onSaveProtectionChanged,
    this.progressHidden = const [],
    required this.onProgressUnhide,
    required this.showOtherDownloads,
    required this.onShowOtherDownloadsChanged,
    required this.showFolderAddons,
    required this.onShowFolderAddonsChanged,
    required this.onRestartAutonomi,
    required this.iconAnimation,
    required this.onIconAnimationChanged,
    required this.repositoryUpdates,
    required this.onRepositoryUpdatesChanged,
    required this.repositoryUpdateButtons,
    required this.onRepositoryUpdateButtonsChanged,
    required this.tagDisplay,
    required this.onTagDisplayChanged,
    required this.themeKey,
    required this.onThemeChanged,
    required this.launch,
    required this.servers,
  });

  /// Открывает настройки на нужном разделе.
  static Future<void> show(BuildContext context, SettingsDialog dialog) => showDialog(
        context: context,
        builder: (_) => dialog,
      );

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  /// Игра, чьи папка, сборки и серверы настраиваются.
  GameDef get _g => widget.launch.game;
  late SettingsSection _section = widget.initialSection;
  late String _themeKey = widget.themeKey;
  late final _folder = TextEditingController(text: widget.gameFolder ?? '');
  late final _tags = TextEditingController(text: widget.hiddenTags);
  late bool _versionFolders = widget.versionFolders;
  late bool _playerEnabled = widget.playerEnabled;
  late bool _progressEnabled = widget.progressEnabled;
  late final List<String> _progressHidden = List.of(widget.progressHidden);
  late bool _showOther = widget.showOtherDownloads;
  late bool _showFolder = widget.showFolderAddons;
  late AddonIconAnimation _iconAnimation = widget.iconAnimation;
  late RepositoryUpdates _repositoryUpdates = widget.repositoryUpdates;
  late bool _repoUpdateButtons = widget.repositoryUpdateButtons;
  late bool _autoHideTags = widget.autoHideTags;
  late TagDisplay _tagDisplay = widget.tagDisplay;

  void _setTagDisplay(TagDisplay v) {
    setState(() => _tagDisplay = v);
    widget.onTagDisplayChanged(v);
  }
  bool _restarting = false;
  bool? _restartOk;

  String? _folderError;
  bool _folderSaved = false;

  static const _sections = [
    (SettingsSection.general, Icons.tune, 'General'),
    (SettingsSection.game, Icons.folder_outlined, 'Game folder'),
    (SettingsSection.addons, Icons.extension_outlined, 'Addons'),
    (SettingsSection.launch, Icons.play_circle_outline, 'Launch'),
    (SettingsSection.servers, Icons.dns_outlined, 'Servers'),
    (SettingsSection.experimental, Icons.science_outlined, 'Experimental'),
  ];

  @override
  void initState() {
    super.initState();
    if (widget.gameFolder == null) {
      // Подсказка для Linux: ~/.srb2, ~/.ringracers (или папка Flatpak), если она существует.
      PlatformUtils.detectGameFolder(_g).then((dir) {
        if (dir != null && mounted && _folder.text.isEmpty) setState(() => _folder.text = dir);
      });
    }
  }

  @override
  void dispose() {
    _folder.dispose();
    _tags.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Dialog(
      insetPadding: const EdgeInsets.all(32),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 1100,
        height: 760,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Навигация по разделам.
            Container(
              width: 240,
              color: Colors.black.withValues(alpha: 0.25),
              padding: const EdgeInsets.fromLTRB(12, 20, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(tr('Settings'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 2),
                        // Папка, сборки и серверы — у каждой игры свои.
                        Text(_g.fullName, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                      ],
                    ),
                  ),
                  for (final (section, icon, label) in _sections)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: ListTile(
                        dense: true,
                        selected: _section == section,
                        selectedTileColor: accent.withValues(alpha: 0.18),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                        leading: Icon(icon, size: 20),
                        title: Text(tr(label), style: const TextStyle(fontSize: 14)),
                        onTap: () => setState(() => _section = section),
                      ),
                    ),
                ],
              ),
            ),
            // Содержимое раздела.
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(32, 16, 12, 0),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            tr(_sections.firstWhere((x) => x.$1 == _section).$3),
                            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: tr('Close'),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                  ),
                  const Divider(),
                  Expanded(child: _buildSection()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSection() {
    switch (_section) {
      case SettingsSection.general:
        return _page([_general()]);
      case SettingsSection.game:
        return _page([_game()]);
      case SettingsSection.addons:
        return _page([_addons()]);
      case SettingsSection.launch:
        return _launch();
      case SettingsSection.servers:
        return _page([_servers()]);
      case SettingsSection.experimental:
        return _page([_experimental()]);
    }
  }

  Widget _page(List<Widget> children) => ListView(
        padding: const EdgeInsets.fromLTRB(32, 8, 32, 32),
        children: children,
      );

  Widget _title(String text) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 6),
        child: Text(text, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
      );

  Widget _hint(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      );

  // --- Experimental ---

  Widget _experimental() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _hint(tr('Features that are still being tried out. They are off until you turn them on.')),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _playerEnabled,
          onChanged: (v) {
            setState(() => _playerEnabled = v);
            widget.onPlayerEnabledChanged(v);
          },
          title: Text(tr('Music player')),
          subtitle: Text(tr('A Music tab after Servers: music of all games from the game files, downloaded addons and files you open (OGG, MP3, FLAC, WAV, MIDI).')),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _progressEnabled,
          onChanged: (v) {
            setState(() => _progressEnabled = v);
            widget.onProgressEnabledChanged(v);
          },
          title: Text(tr('Progress')),
          subtitle: Text(tr('A Progress tab: single player progress of Sonic Robo Blast 2, SRB2 Legacy and their level '
              'packs (gamedata.dat and the addon\'s own GameData) — play time, records, emblems and secrets, like '
              'Statistics and Record Attack in the game.')),
        ),
        if (_progressEnabled && _progressHidden.isNotEmpty) ...[
          _hint(tr('Hidden from Progress:')),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final id in _progressHidden)
                InputChip(
                  label: Text(id),
                  deleteIcon: const Icon(Icons.visibility_outlined, size: 18),
                  deleteButtonTooltipMessage: tr('Show in Progress again'),
                  onDeleted: () {
                    setState(() => _progressHidden.remove(id));
                    widget.onProgressUnhide(id);
                  },
                ),
            ],
          ),
        ],
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: SaveGuard.enabled,
          onChanged: (v) {
            setState(() {});
            widget.onSaveProtectionChanged(v);
          },
          title: Text(tr('Save protection')),
          subtitle: Text(tr('Before the game starts, the launcher checks the save files it will use (progress and '
              'single player saves) and keeps the last whole copy of each. If a file is damaged (for example, the PC '
              'turned off while the game was saving), it is restored from the copy; the damaged file is kept.')),
        ),
      ],
    );
  }

  // --- General ---

  Widget _general() {
    final i18n = I18n.instance;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _title(tr('Language')),
        _hint(tr('Language files are in the "lang" folder next to the launcher.')),
        DropdownButtonFormField<String>(
          initialValue: i18n.code,
          decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
          items: [
            for (final l in i18n.available)
              DropdownMenuItem(
                value: l.code,
                child: Row(
                  children: [
                    // Флаг языка слева от названия (assets/flags); нет картинки — без него.
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: Image.asset('assets/flags/${l.flag}.png',
                          width: 22,
                          height: 16.5,
                          fit: BoxFit.fill,
                          errorBuilder: (_, _, _) => const SizedBox(width: 22)),
                    ),
                    const SizedBox(width: 10),
                    Text(l.name),
                  ],
                ),
              ),
          ],
          onChanged: (code) async {
            if (code == null) return;
            await i18n.load(code);
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('app_language', code);
            if (mounted) setState(() {});
          },
        ),
        const SizedBox(height: 16),
        _title(tr('Color theme')),
        DropdownButtonFormField<String>(
          initialValue: _themeKey,
          decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
          items: [
            for (final theme in AppThemes.availableThemes)
              DropdownMenuItem<String>(value: theme['key'] as String, child: Text(tr(theme['name'] as String))),
          ],
          onChanged: (val) {
            if (val == null) return;
            setState(() => _themeKey = val);
            widget.onThemeChanged(val);
          },
        ),
        const SizedBox(height: 16),
        _title('Autonomi'),
        _hint(tr('If addons or icons stopped loading, restart the Autonomi daemon (antd). '
            'The launcher also does it by itself when the daemon stops answering.')),
        Row(
          children: [
            OutlinedButton.icon(
              icon: _restarting
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.restart_alt, size: 18),
              label: Text(tr('Restart Autonomi')),
              onPressed: _restarting
                  ? null
                  : () async {
                      setState(() {
                        _restarting = true;
                        _restartOk = null;
                      });
                      final ok = await widget.onRestartAutonomi();
                      if (!mounted) return;
                      setState(() {
                        _restarting = false;
                        _restartOk = ok;
                      });
                    },
            ),
            const SizedBox(width: 12),
            if (_restartOk != null)
              Text(
                _restartOk! ? tr('Autonomi is running') : tr('Could not start Autonomi (antd). See the console for details.'),
                style: TextStyle(fontSize: 12, color: _restartOk! ? Colors.green : Colors.redAccent),
              ),
          ],
        ),
        const SizedBox(height: 16),
        _title(tr('Launcher build')),
        _hint(tr('When this launcher was built: compare it with the latest build to see if it is up to date.')),
        SelectableText(
          BuildInfo.isLocal ? tr('Local build (no build date)') : BuildInfo.summary,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        ),
        _title(tr('Launcher data')),
        _hint(AppPaths.portable
            ? tr('Portable mode (the file "portable" is next to the launcher): settings and cache are in the '
                'launcher folder.')
            : tr('Settings and cache. Put a file named "portable" next to the launcher to keep them in the launcher '
                'folder instead (portable mode).')),
        FutureBuilder<Directory>(
          future: getApplicationSupportDirectory(),
          builder: (context, snap) {
            final dir = snap.data?.path;
            if (dir == null) return const SizedBox.shrink();
            return Row(
              children: [
                Flexible(
                  child: SelectableText(dir, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.folder_open, size: 20),
                  tooltip: tr('Open folder'),
                  onPressed: () => openFolder(context, dir),
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  // --- Game folder ---

  Future<void> _saveFolder(String value) async {
    final error = await widget.onGameFolderChanged(value);
    if (!mounted) return;
    setState(() {
      _folderError = error;
      _folderSaved = error == null;
      if (error == null) _folder.text = PlatformUtils.cleanUserPath(value);
    });
  }

  Widget _game() {
    final isWin = Platform.isWindows;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _title(tr('{game} game folder', {'game': _g.name})),
        _hint(isWin
            ? tr('The folder with {file}. The game is started with it as the working folder, so the config and addons come from it even if the builds are elsewhere.',
                {'file': _g.mainFile})
            : tr('Usually ~/{folder}. The game is started with it as the working folder.',
                {'folder': _g.linuxDataFolders.first})),
        // Подсказка и ошибка — под строкой, а не внутри поля: иначе поле выше
        // кнопок и «Save» не на одной линии с ним.
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _folder,
                onChanged: (_) => setState(() {
                  _folderError = null;
                  _folderSaved = false;
                }),
                onSubmitted: _saveFolder,
                decoration: InputDecoration(
                  labelText: tr('Game folder path'),
                  hintText: isWin ? 'C:\\Games\\${_g.name}' : '~/${_g.linuxDataFolders.first}',
                  border: const OutlineInputBorder(),
                  enabledBorder: _folderError == null
                      ? null
                      : OutlineInputBorder(borderSide: BorderSide(color: Theme.of(context).colorScheme.error)),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.outlined(
              icon: const Icon(Icons.folder_open),
              tooltip: tr('Browse...'),
              onPressed: () async {
                final current = PlatformUtils.cleanUserPath(_folder.text);
                AppLog.action('open the getDirectoryPath dialog (settings_dialog.dart)');
                final dir = await getDirectoryPath(
                  initialDirectory: current.isNotEmpty && Directory(current).existsSync() ? current : null,
                  confirmButtonText: tr('Select'),
                );
                if (dir != null) await _saveFolder(dir);
              },
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () => _saveFolder(_folder.text),
              child: Text(tr('Save')),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 0, 0),
          child: Text(
            _folderError ??
                (_folderSaved
                    ? tr('Saved')
                    : tr('Addons are saved to its {dir} subfolder.', {'dir': _g.downloadPath.join('/')})),
            style: TextStyle(
              fontSize: 12,
              color: _folderError != null ? Theme.of(context).colorScheme.error : Colors.grey,
            ),
          ),
        ),
        if (isWin) ...[
          const SizedBox(height: 8),
          _hint(tr('Do not choose a folder inside C:\\Program Files: addons cannot be saved there without administrator rights.')),
        ],
      ],
    );
  }

  // --- Addons ---

  Widget _addons() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _title(tr('Hidden tags')),
        _hint(tr('Addons with these tags are not shown in the list. Separate tags with commas or spaces.')),
        TextField(
          controller: _tags,
          onChanged: widget.onHiddenTagsChanged,
          decoration: InputDecoration(
            labelText: tr('Tags to hide (e.g. nsfw, test)'),
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _autoHideTags,
          onChanged: (v) {
            setState(() => _autoHideTags = v);
            widget.onAutoHideTagsChanged(v);
          },
          title: Text(tr('Automatically add the tags recommended for hiding to the hidden tags')),
        ),
        _title(tr('Animated icons')),
        _hint(tr('Animated addon icons (GIF) are redrawn many times a second and use a lot of energy.')),
        DropdownButtonFormField<AddonIconAnimation>(
          initialValue: _iconAnimation,
          decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
          items: [
            DropdownMenuItem(value: AddonIconAnimation.all, child: Text(tr('Animate all icons'))),
            DropdownMenuItem(value: AddonIconAnimation.selected, child: Text(tr('Animate only the selected addon'))),
            DropdownMenuItem(value: AddonIconAnimation.none, child: Text(tr('Still pictures (first frame)'))),
          ],
          onChanged: (v) {
            if (v == null) return;
            setState(() => _iconAnimation = v);
            widget.onIconAnimationChanged(v);
          },
        ),
        _title(tr('Tags on the addon page')),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _tagDisplay.showGroup,
          onChanged: (v) => _setTagDisplay((showGroup: v, order: _tagDisplay.order, showAll: _tagDisplay.showAll)),
          title: Text(tr('Show the tag group')),
          subtitle: Text(tr('source:workshop instead of workshop')),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _tagDisplay.showAll,
          onChanged: (v) => _setTagDisplay((showGroup: _tagDisplay.showGroup, order: _tagDisplay.order, showAll: v)),
          title: Text(tr('Show all tags at once')),
          subtitle: Text(tr('Otherwise the first tags are shown and the rest behind "+N more"')),
        ),
        const SizedBox(height: 4),
        DropdownButtonFormField<TagOrder>(
          initialValue: _tagDisplay.order,
          decoration: InputDecoration(
              labelText: tr('Tag order'), border: const OutlineInputBorder(), isDense: true),
          items: [
            DropdownMenuItem(value: TagOrder.groups, child: Text(tr('By group (alphabetical within a group)'))),
            DropdownMenuItem(value: TagOrder.alphabetical, child: Text(tr('Alphabetical'))),
          ],
          onChanged: (v) {
            if (v == null) return;
            _setTagDisplay((showGroup: _tagDisplay.showGroup, order: v, showAll: _tagDisplay.showAll));
          },
        ),
        _title(tr('Repository updates')),
        _hint(tr('Repositories connected by pointer are checked when the launcher starts: the pointer may lead '
            'to a new file. The update button next to Add Repository checks them at any time.')),
        DropdownButtonFormField<RepositoryUpdates>(
          initialValue: _repositoryUpdates,
          decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
          items: [
            DropdownMenuItem(value: RepositoryUpdates.auto, child: Text(tr('Update automatically'))),
            DropdownMenuItem(value: RepositoryUpdates.ask, child: Text(tr('Ask before updating'))),
            DropdownMenuItem(value: RepositoryUpdates.off, child: Text(tr('Do not update'))),
          ],
          onChanged: (v) {
            if (v == null) return;
            setState(() => _repositoryUpdates = v);
            widget.onRepositoryUpdatesChanged(v);
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _repoUpdateButtons,
          onChanged: (v) {
            setState(() => _repoUpdateButtons = v);
            widget.onRepositoryUpdateButtonsChanged(v);
          },
          title: Text(tr('Update button next to each repository')),
          subtitle: Text(tr('Updates only that repository. Shown when more than one repository is connected by '
              'pointer.')),
        ),
        _title(tr('Addons not from your repositories')),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _showOther,
          onChanged: (v) {
            setState(() => _showOther = v);
            widget.onShowOtherDownloadsChanged(v);
          },
          title: Text(tr('Show other downloads')),
          subtitle: Text(tr('Addon files in the download folder that are not in your repositories (MD5 differs): downloaded from servers or by the game itself.')),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _showFolder,
          onChanged: (v) {
            setState(() => _showFolder = v);
            widget.onShowFolderAddonsChanged(v);
          },
          title: Text(tr('Show addons in the game folder')),
          subtitle: Text(tr('Addon files elsewhere in the game folder (e.g. addons/ or data/addons/) that are not in your repositories.')),
        ),
        _title(tr('Downloads')),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _versionFolders,
          onChanged: (v) {
            setState(() => _versionFolders = v);
            widget.onVersionFoldersChanged(v);
          },
          title: Text(tr('Separate folders for addons and versions')),
          subtitle: Text(_versionFolders
              ? tr('Files are saved to DOWNLOAD/<addon>/<version>/<file>: versions do not overwrite each other.')
              : tr('Files are saved directly to DOWNLOAD/<file>. If a file with the same name is already there, you will be asked what to do.')),
        ),
      ],
    );
  }

  // --- Launch ---

  Widget _launch() {
    final s = widget.launch;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(32, 8, 16, 32),
              children: [
                _title(tr('Executables')),
                _hint(tr('Builds you can start the game with. The star marks the default one; pick another one before launching on the Launch tab.')),
                for (final e in s.executables)
                  Card(
                    child: ListTile(
                      dense: true,
                      leading: IconButton(
                        icon: Icon(s.isDefault(e) ? Icons.star : Icons.star_border,
                            color: s.isDefault(e) ? Colors.amber : null),
                        tooltip: s.isDefault(e) ? tr('Default executable') : tr('Set as default'),
                        onPressed: s.isDefault(e) ? null : () => s.setDefault(e.id),
                      ),
                      title: Text(e.name),
                      subtitle: Text(e.command, style: const TextStyle(fontSize: 11)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit_outlined),
                            tooltip: tr('Edit'),
                            onPressed: () async {
                              final edited = await showExecutableDialog(context,
                                  initial: e, initialDirectory: widget.gameFolder);
                              if (edited != null) s.updateExecutable(edited);
                            },
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            tooltip: tr('Remove'),
                            onPressed: () => s.removeExecutable(e.id),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (s.executables.isEmpty)
                  _hint(tr('No executables: {cmd} is used.', {'cmd': PlatformUtils.defaultLaunchCommand(game: _g)})),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      icon: const Icon(Icons.add),
                      label: Text(tr('Add executable...')),
                      onPressed: () async {
                        final added = await showExecutableDialog(
                          context,
                          initialDirectory: widget.gameFolder,
                          suggestName: s.uniqueName,
                        );
                        if (added != null) s.addExecutable(added, select: false);
                      },
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.manage_search),
                      label: Text(tr('Find builds in folder...')),
                      onPressed: () => ExecutableSelector(settings: s, initialDirectory: widget.gameFolder)
                          .scanFolder(context),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- Servers ---

  /// Мастер-сервер: состояние (в сети / нет / не проверяли), название, адрес.
  Widget _masterCard(ServersStore store, String url) {
    final status = store.statusOf(url);
    final checking = store.checkingMasters.contains(url);
    final enabled = !store.disabledMasters.contains(url);
    final (Color color, String text) = checking
        ? (Colors.grey, tr('Checking...'))
        : !enabled
            ? (Colors.grey, tr('Off: the server list is not taken from it'))
        : status == null
            ? (Colors.grey, tr('Not checked yet'))
            : status.error == null
                ? (Colors.green, tr('Online · {n} server(s)', {'n': status.count ?? 0}))
                : (Colors.redAccent, tr('Offline: {error}', {'error': status.error!}));
    return Card(
      child: ListTile(
        dense: true,
        enabled: enabled,
        leading: checking
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(Icons.circle, size: 14, color: color),
        title: Text(store.masterName(url)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(url, style: const TextStyle(fontSize: 11)),
            Text(text, style: TextStyle(fontSize: 11, color: color), maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Tooltip(
              message: enabled ? tr('Turn off') : tr('Turn on'),
              child: Switch(value: enabled, onChanged: (v) => store.setMasterEnabled(url, v)),
            ),
            IconButton(
              icon: const Icon(Icons.wifi_find_outlined),
              tooltip: tr('Check'),
              onPressed: checking ? null : () => store.checkMaster(url),
            ),
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: tr('Edit'),
              onPressed: () async {
                final edited = await _masterDialog(name: store.masterName(url), url: url);
                if (edited == null) return;
                final (name, newUrl) = edited;
                await store.setMasters([
                  for (final m in store.masters) m == url ? '$name | $newUrl' : '${store.masterName(m)} | $m',
                ]);
                if (newUrl != url) store.checkMaster(newUrl);
              },
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: tr('Remove'),
              onPressed: store.masters.length <= 1
                  ? null
                  : () => store.setMasters([for (final m in store.masters) if (m != url) '${store.masterName(m)} | $m']),
            ),
          ],
        ),
      ),
    );
  }

  /// Название и адрес мастер-сервера; null — отмена.
  Future<(String, String)?> _masterDialog({String name = '', String url = ''}) {
    final nameField = TextEditingController(text: name);
    final urlField = TextEditingController(text: url);
    return showDialog<(String, String)>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(url.isEmpty ? tr('Add master server') : tr('Edit master server')),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameField,
                decoration: InputDecoration(labelText: tr('Name'), hintText: tr('Optional'), border: const OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: urlField,
                autofocus: url.isEmpty,
                decoration: InputDecoration(
                  labelText: tr('Address'),
                  hintText: 'https://ms.example.net/MS/0  ·  ms.example.net:28900',
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
          FilledButton(
            onPressed: () {
              final u = urlField.text.trim();
              if (u.isEmpty) return;
              Navigator.pop(context, (nameField.text.trim().replaceAll('|', ''), u));
            },
            child: Text(tr('Save')),
          ),
        ],
      ),
    );
  }

  Widget _servers() {
    final store = widget.servers;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _title(tr('Joining')),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: store.preloadAddons,
            onChanged: (v) => store.updateOptions((s) => s.preloadAddons = v ?? true),
            title: Text(tr('Load addons into the game before connecting')),
            subtitle: Text(tr('On: the game starts with the server\'s addons (-file, in the server\'s order) and then connects, without the "Loading addons" screen. Off: the game connects first and loads them itself. Missing addons are downloaded before joining in both cases.')),
          ),
          _title(tr('Master servers')),
          _hint(tr('Lists from all master servers are merged. The address is an http(s) URL or host:port '
              '(old SRB2 2.1 master servers, port 28900).')),
          for (final url in store.masters) _masterCard(store, url),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.add),
                label: Text(tr('Add master server')),
                onPressed: () async {
                  final added = await _masterDialog();
                  if (added == null) return;
                  final (name, url) = added;
                  await store.setMasters([...store.masterLines, '$name | $url']);
                  store.checkMaster(url);
                },
              ),
              TextButton.icon(
                icon: const Icon(Icons.wifi_find_outlined),
                label: Text(tr('Check all')),
                onPressed: () {
                  for (final url in store.masters) {
                    store.checkMaster(url);
                  }
                },
              ),
              TextButton(
                onPressed: () async {
                  await store.setMasters(_g.defaultMasters);
                  for (final url in store.masters) {
                    store.checkMaster(url);
                  }
                },
                child: Text(tr('Reset to defaults')),
              ),
              FilledButton.tonal(
                onPressed: () {
                  store.refresh();
                  showSnack(context, SnackBar(content: Text(tr('Refreshing the server list...'))));
                },
                child: Text(tr('Refresh the server list')),
              ),
            ],
          ),
          _title(tr('Favorite servers')),
          if (store.favorites.isEmpty)
            _hint(tr('No favorite servers yet. Add them with the star on the Servers tab.'))
          else
            for (final f in List.of(store.favorites))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.star, size: 18, color: Colors.amber),
                title: Text(f.name.isEmpty ? connectAddress(f.host, f.port) : f.name, overflow: TextOverflow.ellipsis),
                subtitle: f.name.isEmpty ? null : Text(connectAddress(f.host, f.port)),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  tooltip: tr('Remove from favorites'),
                  onPressed: () => store.removeFavorite(f.host, f.port),
                ),
              ),
          _title(tr('Server list')),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(tr('Hide unsupported servers')),
            subtitle: Text(tr('Servers that answer "Unsupported server (different game version)": another version '
                'of the game, you cannot join them. Your servers are always shown.')),
            value: store.hideUnsupported,
            onChanged: (v) => store.updateOptions((s) => s.hideUnsupported = v),
          ),
          _title(tr('Local server list')),
          _hint(tr('Servers seen on the master server are saved locally, so they stay in the list (marked with a clock) when the master server is down or the server leaves it. A server is removed when it has not answered for the chosen time.')),
          Row(
            children: [
              Text(tr('Remove servers not online for:')),
              const SizedBox(width: 12),
              DropdownButton<LocalListRetention>(
                value: store.retention,
                items: [
                  for (final r in LocalListRetention.values) DropdownMenuItem(value: r, child: Text(tr(r.label))),
                ],
                onChanged: (v) {
                  if (v != null) store.setRetention(v);
                },
              ),
            ],
          ),
          _hint(tr('{n} server(s) in the local list', {'n': store.known.length})),
        ],
      ),
    );
  }
}
