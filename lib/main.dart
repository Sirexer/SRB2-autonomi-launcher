import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show AppExitResponse;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;
import 'services/app_log.dart';
import 'services/addon_updates.dart';
import 'services/app_paths.dart';
import 'services/notices.dart';
import 'services/custom_games.dart';
import 'services/hidden_addon_folders.dart';
import 'ui/first_run_wizard.dart';
import 'ui/update_dialog.dart';
import 'services/launcher_update.dart';
import 'services/save_guard.dart';
import 'services/launch_state.dart';
import 'services/game_progress.dart';
import 'services/downloads.dart';
import 'models/game.dart';
import 'models/launch_config.dart';
import 'models/mod_item.dart';
import 'services/addon_contents.dart';
import 'services/app_activity.dart';
import 'services/json_file_cache.dart';
import 'services/characters.dart';
import 'services/game_files.dart';
import 'services/manifest_service.dart';
import 'services/music.dart';
import 'services/music_player.dart';
import 'services/replays.dart';
import 'services/server_files.dart';
import 'services/map_preview.dart';
import 'services/autonomi_service.dart';
import 'services/addon_paths.dart';
import 'services/antd_daemon.dart';
import 'services/launch_settings.dart';
import 'services/platform_utils.dart';
import 'services/search_query.dart';
import 'services/servers_store.dart';
import 'services/tag_groups.dart';
import 'services/state_history.dart';
import 'ui/add_manifest_dialog.dart';
import 'ui/addon_icon.dart';
import 'ui/color_picker.dart';
import 'ui/downloads_button.dart';
import 'ui/ring_progress_tab.dart';
import 'ui/gametype_choice.dart';
import 'ui/file_actions.dart';
import 'ui/character_picker.dart';
import 'ui/color_preview.dart';
import 'ui/kept_scroll.dart';
import 'ui/launch_panel.dart';
import 'ui/player_tab.dart';
import 'ui/progress_tab.dart';
import 'ui/replays_tab.dart';
import 'ui/save_guard_dialogs.dart';
import 'ui/notifications_button.dart';
import 'ui/game_icon.dart';
import 'ui/map_picker.dart';
import 'ui/servers_tab.dart';
import 'ui/settings_dialog.dart';
import 'build_info.dart';
import 'i18n.dart';
import 'theme/app_themes.dart';
import 'services/window_effects.dart';
import 'ui/snack.dart';
import 'ui/srb2_text.dart';
import 'services/model_packs.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // Папка данных: портативный режим (файл portable рядом с лаунчером) или
  // системная (папка прошлого имени лаунчера переезжает) — до всего прочего.
  await AppPaths.init();
  // Журнал для поиска зависаний (logs/launcher.log в папке данных).
  await AppLog.init();
  AppLog.catchErrors();
  AppPaths.startupLog.forEach(AppLog.write);
  AppLog.write('build: ${BuildInfo.isLocal ? 'local' : BuildInfo.summary}');
  // На Windows рисует Impeller (по умолчанию во Flutter); --skia включает
  // Skia (windows/runner/main.cpp) — в журнале видно, какой.
  if (Platform.isWindows) AppLog.write('renderer: ${args.contains('--skia') ? 'Skia' : 'Impeller (default)'}');
  // Кэш расшифрованных картинок: по умолчанию до 100 МБ — для лаунчера
  // (обложки, превью карт, иконки — все маленькие) хватает и 40.
  PaintingBinding.instance.imageCache.maximumSizeBytes = 40 << 20;
  // Язык интерфейса: файлы в папке lang рядом с лаунчером.
  final prefs = await SharedPreferences.getInstance();
  // Свои игры (описания в JSON) и выключенные — до первого обращения к играм.
  await CustomGames.load(prefs);
  // Остатки прошлого обновления лаунчера (*.old, распаковка).
  unawaited(LauncherUpdate.cleanup());
  await I18n.instance.discover();
  // Темы из папок themes (рядом с лаунчером и свои).
  await AppThemes.load();
  // Пока язык не выбран (мастер первого запуска, Settings) — язык системы.
  await I18n.instance.load(prefs.getString('app_language') ?? I18n.instance.systemLanguage());
  // Ошибка построения части окна — не серое поле, а понятный текст
  // (и подробности в консоли), чтобы такие ошибки было видно сразу.
  ErrorWidget.builder = (details) => Material(
        color: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            'Display error: ${details.exceptionAsString()}',
            style: const TextStyle(color: Colors.redAccent, fontSize: 12),
          ),
        ),
      );
  runApp(const SRB2LauncherApp());
}

/// Запись кэша MD5: действительна, пока размер и время изменения файла не менялись.
class _Md5Entry {
  final int size;
  final int mtime;
  final String md5;
  const _Md5Entry(this.size, this.mtime, this.md5);

  Map<String, dynamic> toJson() => {'s': size, 'm': mtime, 'h': md5};
  static _Md5Entry? fromJson(dynamic j) {
    if (j is! Map) return null;
    final s = j['s'], m = j['m'], h = j['h'];
    if (s is int && m is int && h is String) return _Md5Entry(s, m, h);
    return null;
  }
}

/// Что делать, если файлов из очереди нет на диске.
enum _MissingChoice { cancel, remove, launch }

/// Что делать, если на месте скачиваемого файла лежит другой.
enum _ReplaceChoice { replace, keepBoth, rename, move, cancel }

/// Что сделать со старым файлом, MD5 которого не совпал.
enum _ConflictAction { replace, delete, rename, move }

/// Снимок очереди запуска для отмены/повтора: файлы, выключенные и выбор,
/// который зависит от аддонов (режим, персонаж, цвет, карта -warp).
typedef _QueueState = ({List<String> queue, Set<String> off, String gametype, String skin, String color, String warp});

/// Новый файл репозитория по pointer: прежнее название, новое, текст, pointer.
typedef _RepoUpdate = ({String title, String name, String text, String pointer});

/// Одни и те же файлы (пути сравниваются как в системе).
bool listEqualsPaths(List<String> a, List<String> b) =>
    a.length == b.length && [for (var i = 0; i < a.length; i++) PlatformUtils.samePath(a[i], b[i])].every((x) => x);

/// Скачивание файла аддона репозитория в очереди.
class _RepoDownload {
  final ModItem mod;
  final ModFile file;

  /// Куда сохранить (папка и замена старого файла выбраны при нажатии).
  final String path;
  final DownloadItem item;
  final done = Completer<bool>();

  _RepoDownload(this.mod, this.file, this.path, this.item);
}

class SRB2LauncherApp extends StatefulWidget {
  const SRB2LauncherApp({super.key});

  @override
  State<SRB2LauncherApp> createState() => _SRB2LauncherAppState();
}

class _SRB2LauncherAppState extends State<SRB2LauncherApp> {
  String _currentThemeKey = AppThemes.deepOrange;

  @override
  void initState() {
    super.initState();
    _loadTheme();
    I18n.instance.addListener(_onLanguageChanged);
  }

  @override
  void dispose() {
    I18n.instance.removeListener(_onLanguageChanged);
    super.dispose();
  }

  /// Смена языка: перерисовываем всё (включая открытые окна).
  void _onLanguageChanged() {
    if (!mounted) return;
    setState(() {});
    I18n.rebuildAll(context);
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final savedTheme = prefs.getString('app_theme_key');
    if (savedTheme != null) {
      setState(() => _currentThemeKey = savedTheme);
    }
    // Прозрачность окна — после первого кадра (окно уже есть).
    WidgetsBinding.instance.addPostFrameCallback((_) => WindowEffects.apply(AppThemes.byKey(_currentThemeKey)));
  }

  Future<void> _setTheme(String key) async {
    setState(() => _currentThemeKey = key);
    WindowEffects.apply(AppThemes.byKey(key));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_theme_key', key);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: tr('SRB2 Autonomi Launcher'),
      debugShowCheckedModeBanner: false,
      theme: AppThemes.getThemeData(_currentThemeKey),
      // Тема: масштаб текста и фон (картинка, затемнение) под всем окном.
      builder: (context, child) {
        final t = AppThemes.byKey(_currentThemeKey);
        var out = child ?? const SizedBox.shrink();
        if (t.textScale != 1) {
          out = MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(t.textScale)),
            child: out,
          );
        }
        return ThemeBackground(theme: t, child: out);
      },
      home: MainLauncherScreen(
        currentThemeKey: _currentThemeKey,
        onThemeChanged: (newKey) => _setTheme(newKey),
      ),
    );
  }
}

class MainLauncherScreen extends StatefulWidget {
  final String currentThemeKey;
  final ValueChanged<String> onThemeChanged;

  const MainLauncherScreen({
    super.key,
    required this.currentThemeKey,
    required this.onThemeChanged,
  });

  @override
  State<MainLauncherScreen> createState() => _MainLauncherScreenState();
}

class _MainLauncherScreenState extends State<MainLauncherScreen> {
  Map<String, String> rawManifests = {};

  /// Репозитории, подключённые через pointer: название → адрес pointer. При
  /// запуске они перечитываются — pointer может вести уже на новый файл.
  final Map<String, String> _repoPointers = {};

  /// Репозитории по pointer, обновлённые из файла: pointer остаётся, но при
  /// запуске сам не применяется (чтобы не затереть файл) — только кнопкой
  /// «Обновить репозитории»; после обновления по pointer снова обычный.
  final Set<String> _pointerManualOnly = {};
  Map<String, List<ModItem>> manifestGroups = {};
  Map<String, String> cachedImages = {};

  ModItem? selectedMod;
  /// ModFile.key файла, который сейчас скачивается.
  String? downloadingFileKey;

  /// Уровни скачанных файлов (путь + размер + время изменения → результат).
  final Map<String, Future<List<MapPreview>>> _mapPreviews = {};

  /// Где лежит проверенный файл выбранной версии (ModFile.key → путь).
  Map<String, String> _localPaths = {};

  /// Файл с тем же именем, но другим MD5 (ModFile.key → путь).
  Map<String, String> _conflictPaths = {};

  /// Пути к исполняемым файлам установленных сборок (ModFile.key → exePath).
  final Map<String, String> _installedBuildExes = {};

  Future<void> _saveInstalledBuilds() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('installed_build_exes', jsonEncode(_installedBuildExes));
  }

  /// Избранные аддоны (ModItem.key) и фильтр "только избранные".
  final Set<String> _favoriteAddons = {};
  bool _favoritesOnly = false;

  /// Скрывать аддоны, ни одного файла которых нет в папке игры.
  bool _hideNotDownloaded = false;

  /// Аддоны, у которых в папке игры есть хотя бы один файл (по имени).
  final Set<String> _downloadedKeys = {};


  /// Плеер (экспериментально, включается в настройках).
  final MusicPlayer _player = MusicPlayer();
  bool _playerEnabled = false;

  /// Вкладка Progress (экспериментальная) включена.
  bool _progressEnabled = false;

  /// Вкладка Replays (экспериментальная, SRB2 2.2) включена.
  bool _replaysEnabled = false;

  /// Аддоны, скрытые из Progress (имена файлов прогресса).
  final Set<String> _progressHidden = {};

  /// Прогресс аддона для строки в его карточке (по файлам).
  final Map<String, Future<ProgressPack?>> _packProgress = {};

  /// Левелпаки, добавленные в Progress вручную («Add Map Pack»): у каждой
  /// игры свои (у SRB2 Legacy аддонов в репозиториях нет).
  final Map<String, List<ProgressCandidate>> _progressPacks = {};

  /// Номера экспериментальных вкладок; null — вкладка выключена.
  int? get _playerTab => _playerEnabled ? 3 : null;
  int? get _progressTab => _progressEnabled ? 3 + (_playerEnabled ? 1 : 0) : null;
  int? get _replaysTab => _replaysEnabled ? 3 + (_playerEnabled ? 1 : 0) + (_progressEnabled ? 1 : 0) : null;

  /// Файлы в папке загрузок, которых нет в репозиториях — скачаны с серверов
  /// (лаунчером или самой игрой), и что в них.
  List<String> _serverAddonFiles = [];

  /// Аддоны в остальной папке игры (например, data/addons/Levels), которых нет
  /// в репозиториях.
  List<String> _folderAddonFiles = [];

  /// Что внутри файлов обоих списков.
  Map<String, AddonContents> _serverAddonInfo = {};

  /// Развёрнутые группы списка аддонов (репозитории, категории, «Другие
  /// загрузки»); по умолчанию всё свёрнуто. Хранятся здесь, а не в самих
  /// ExpansionTile (так состояние не теряется, когда группа пересоздаётся), и
  /// только до выхода из лаунчера. При поиске всё развёрнуто — иначе находки
  /// прятались бы в свёрнутых группах.
  final Set<String> _expandedGroups = {};

  /// Меняется по «Развернуть/Свернуть все»: группы пересоздаются с новым
  /// состоянием (своё ExpansionTile помнит только начальное).
  int _groupsGen = 0;
  String get _groupKeySuffix => '$_groupsGen${_searchQuery.isNotEmpty ? ':search' : ''}';

  bool _groupExpanded(String id) => _searchQuery.isNotEmpty || _expandedGroups.contains(id);

  /// Все группы списка аддонов — для «Развернуть все».
  Set<String> _allGroupIds() => {
        for (final e in _visibleGroups.entries) ...[
          'repo:${e.key}',
          for (final mod in e.value) 'repo:${e.key}:${mod.category}',
        ],
        for (final group in ['other', 'folder']) ...[
          group,
          for (final (category, _, _) in _categoryOrder) '$group:${category.name}',
        ],
      };

  void _setAllGroupsExpanded(bool expanded) {
    setState(() {
      if (expanded) {
        _expandedGroups.addAll(_allGroupIds());
      } else {
        _expandedGroups.clear();
      }
      _groupsGen++;
    });
  }

  /// Какие обложки аддонов анимировать (настройка).
  AddonIconAnimation _iconAnimation = AddonIconAnimation.all;

  /// Теги на странице аддона (Settings → Addons): с группой или без,
  /// порядок, все сразу или часть.
  TagDisplay _tagDisplay = (showGroup: true, order: TagOrder.groups, showAll: true);

  Future<void> _setIconAnimation(AddonIconAnimation v) async {
    setState(() => _iconAnimation = v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('addon_icon_animation', v.name);
  }

  /// Прокрутка панели параметров Launch — сохраняется при смене вкладок.
  final _launchOptionsScroll = KeptScrollController();

  void _setGroupExpanded(String id, bool expanded) {
    if (expanded ? !_expandedGroups.add(id) : !_expandedGroups.remove(id)) return;
    // Перестроить список: иначе свёрнутая родительская группа при открытии
    // заново создаст вложенные по старым (развёрнутым) настройкам.
    setState(() {});
  }

  /// Прокрутка списка аддонов и карточек — сохраняется при смене вкладок.
  final _addonsListScroll = KeptScrollController();
  final Map<String, KeptScrollController> _cardScrolls = {};
  KeptScrollController _cardScroll(String key) => _cardScrolls.putIfAbsent(key, KeptScrollController.new);

  /// Содержимое скачанных аддонов репозиториев (ключ аддона → карты, режимы...).
  final Map<String, AddonContents> _modContents = {};

  /// Показывать раздел «Другие загрузки» (настройка).
  bool _showOtherDownloads = true;

  /// Показывать раздел «В папке игры».
  bool _showFolderAddons = true;

  /// Идёт обновление разделов «Другие загрузки» / «В папке игры» (кнопка).
  bool _refreshingLocal = false;

  /// Раскрыт ли заголовок группы сейчас — для стрелки в нём (своя стрелка
  /// рядом с кнопкой; ключ — как у ExpansionTile).
  final Map<String, bool> _tileOpen = {};
  bool _groupOpen(String id) => _tileOpen['$id:$_groupKeySuffix'] ?? _groupExpanded(id);
  void _groupToggled(String id, bool v) {
    _tileOpen['$id:$_groupKeySuffix'] = v;
    _setGroupExpanded(id, v);
    setState(() {});
  }

  /// Справа в заголовке группы: кнопка действия и стрелка — у всех групп
  /// в одних и тех же столбцах.
  Widget _groupTrailing(String id, Widget action) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [action, Icon(_groupOpen(id) ? Icons.expand_less : Icons.expand_more)],
      );

  Future<void> _refreshLocalAddons() async {
    setState(() => _refreshingLocal = true);
    try {
      await _refreshServerAddons(rescan: true);
    } finally {
      if (mounted) setState(() => _refreshingLocal = false);
    }
  }

  /// Выбранный файл из раздела «Скачано с серверов» (вместо аддона репозитория).
  String? _selectedLocalFile;

  /// Что внутри скачанных файлов (режимы игры и т.п.), по пути+размеру+времени.
  final Map<String, Future<AddonContents>> _fileContents = {};

  /// Выбранная версия аддона (ModItem.key → имя версии).
  final Map<String, String> _selectedVersions = {};
  bool _md5CacheDirty = false;
  double downloadProgress = 0.0;
  int downloadedBytes = 0;
  String downloadStage = 'downloading';
  int chunksDone = 0;
  int chunksTotal = 0;

  String? srb2FolderPath;

  /// Экзешники, галочки и доп. параметры вкладки Launch.
  /// Текущая игра (переключатель в заголовке). Папка, очередь, сборки,
  /// параметры и серверы — у каждой игры свои.
  GameDef _game = Games.srb2;
  final Map<String, LaunchSettings> _launchByGame = {};
  final Map<String, ServersStore> _serversByGame = {};
  LaunchSettings get _launch => _launchByGame.putIfAbsent(_game.id, () => LaunchSettings(_game)..load());

  /// Мастер-серверы, избранные серверы и результаты опроса (вкладка Servers).
  ServersStore get _servers => _serversByGame.putIfAbsent(_game.id, () => ServersStore(_game)..load());

  // Ключи настроек текущей игры (у SRB2 — прежние).
  String get _kFolder => _folderKey(_game);
  static String _folderKey(GameDef g) => g == Games.srb2 ? 'srb2_folder_path' : g.key('folder_path');

  /// Папка игры [g] из настроек (у текущей — выбранная сейчас).
  Future<String?> _folderOf(GameDef g) async {
    if (g == _game) return srb2FolderPath;
    final prefs = await SharedPreferences.getInstance();
    final path = PlatformUtils.cleanUserPath(prefs.getString(_folderKey(g)) ?? '');
    return path.isEmpty ? null : path;
  }

  /// Сборки игры [g] (по ним ищутся её файлы); загружаются при первом обращении.
  Future<LaunchSettings> _launchOf(GameDef g) async {
    final existing = _launchByGame[g.id];
    if (existing != null) return existing;
    final settings = LaunchSettings(g);
    _launchByGame[g.id] = settings;
    await settings.load();
    return settings;
  }
  String get _kQueue => _game == Games.srb2 ? 'srb2_launch_queue' : _game.key('launch_queue');
  String get _kQueueOff => _game.key('launch_queue_disabled');

  /// Выключенные записи очереди: остаются в списке, но не грузятся в игру.
  final Set<String> _disabledQueue = {};

  /// Включённые записи очереди — то, что уйдёт в -file.
  List<String> get _activeQueue => [for (final e in selectedFilesQueue) if (!_disabledQueue.contains(e)) e];

  /// Профили хранят выключенные записи с этой пометкой в начале.
  static const _offMark = '\u0000off\u0000';

  /// Файлы игры (srb2.pk3 и т.п.): в папке игры, её data или рядом со сборками.
  Future<List<String>> _gameFiles(List<String> relative) =>
      GameFiles.resolveAsync(_game, srb2FolderPath, _launch, relative);

  /// Репозитории с аддонами только для текущей игры (поле games в манифесте).
  Map<String, List<ModItem>> get _visibleGroups => {
        for (final e in manifestGroups.entries)
          e.key: [
            for (final mod in e.value)
              if (mod.forGame(_game.id, orBase: _game.addonBase) case final m?) m,
          ],
      };
  List<String> selectedFilesQueue = [];
  int _currentTab = 0;
  bool _extraTabsExpanded = false;

  // Черный список тегов (хранится через запятую или пробелы)
  String blacklistedTagsString = '';

  /// Теги, которые репозиторий советует скрыть (`hide_tags`), добавлять в
  /// скрытые (Settings → Addons и окно «Подключить репозиторий»; по
  /// умолчанию включено). Выключено — не добавляются.
  bool _autoHideTags = true;

  List<String> get blacklistedTags => blacklistedTagsString
      .toLowerCase()
      .split(RegExp(r'[\s,]+'))
      .where((t) => t.isNotEmpty)
      .toList();

  final Map<String, _Md5Entry> _md5Cache = {};
  int _checkToken = 0;

  Map<String, String> fileStatuses = {};
  Map<String, String> localMd5Cache = {};

  bool daemonReady = false;
  late final AppLifecycleListener _lifecycle;

  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  /// Разобранная строка поиска (слова, -слова, группа:тег, -группа:тег).
  AddonQuery get _query {
    final grouping = _tagGrouping;
    final c = _queryCache;
    if (c == null || c.$1 != _searchQuery || !identical(c.$2, grouping)) {
      _queryCache = (
        _searchQuery,
        grouping,
        AddonQuery.parse(_searchQuery, isTagGroup: (id) => grouping.byId(id) != null),
      );
    }
    return _queryCache!.$3;
  }

  (String, TagGrouping, AddonQuery)? _queryCache;
  final _searchFocus = FocusNode();

  /// Панель всех тегов под строкой поиска открыта.
  bool _showTagPanel = false;

  /// Теги аддонов текущей игры и сколько аддонов с каждым (теги из чёрного
  /// списка не предлагаются). По убыванию числа, затем по алфавиту.
  List<(String, int)> get _gameTags {
    final counts = <String, int>{};
    for (final mods in _visibleGroups.values) {
      for (final mod in mods) {
        for (final tag in {for (final t in mod.tags) normalizeTag(t)}) {
          if (tag.isEmpty || blacklistedTags.contains(tag) || blacklistedTags.contains(_tagGrouping.qualified(tag))) {
            continue;
          }
          counts[tag] = (counts[tag] ?? 0) + 1;
        }
      }
    }
    final out = [for (final e in counts.entries) (e.key, e.value)];
    out.sort((a, b) => a.$2 != b.$2 ? b.$2 - a.$2 : a.$1.compareTo(b.$1));
    return out;
  }

  /// Подсказки тегов для набираемого слова (от двух букв, `-` — исключить):
  /// теги, где оно есть в имени или в `группа:тег` (сначала начинающиеся с
  /// него). Выбор подставляет тег с группой. (группа:тег, число аддонов).
  List<(String, int)> _tagSuggestions(String text) {
    final (_, token) = currentSearchToken(text);
    var body = token.toLowerCase().replaceAll('"', '');
    if (body.startsWith('-')) body = body.substring(1);
    if (body.length < 2) return const [];
    final grouping = _tagGrouping;
    final query = _query;
    final all = [
      for (final (tag, count) in _gameTags)
        if (grouping.qualified(tag) case final q when !query.tags.contains(q) && !query.excludedTags.contains(q))
          (q, count),
    ];
    String name(String q) => q.substring(q.indexOf(':') + 1);
    final starts = [for (final t in all) if (name(t.$1).startsWith(body) || t.$1.startsWith(body)) t];
    final contains = [for (final t in all) if (!starts.contains(t) && t.$1.contains(body)) t];
    return [...starts, ...contains].take(30).toList();
  }

  /// Сколько тегов видно на странице аддона, пока список не раскрыт.
  static const _collapsedTagCount = 8;
  bool _tagsExpanded = false;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        // Музыку и медиаклавиши — до выхода: иначе звук играет и после
        // закрытия окна, а процесс не завершается.
        await _player.shutdown();
        AntdDaemon.stop();
        return AppExitResponse.exit;
      },
      // Запасной вариант, если окно закрыли без запроса на выход.
      onDetach: () {
        _player.shutdown();
        AntdDaemon.stop();
      },
      // Свёрнутое окно — фоновая работа ждёт, плеер не обновляет экран.
      onStateChange: (state) {
        AppActivity.visible.value =
            state != AppLifecycleState.hidden && state != AppLifecycleState.paused && state != AppLifecycleState.detached;
        AppActivity.focused.value = state == AppLifecycleState.resumed;
      },
    );
    _loadSavedData();
    HardwareKeyboard.instance.addHandler(_onMediaKey);
    HardwareKeyboard.instance.addHandler(_onQueueUndoKey);
    // Демон перезапущен (завис) — доступен снова: докачиваем недостающие картинки.
    _antdRestarted = AntdDaemon.restarted.listen((_) {
      if (!mounted) return;
      setState(() => daemonReady = true);
      _retryModImages();
    });
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.toLowerCase().trim();
      });
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onMediaKey);
    HardwareKeyboard.instance.removeHandler(_onQueueUndoKey);
    _antdRestarted?.cancel();
    _playerRescan?.cancel();
    _saveBackupTimer?.cancel();
    _lifecycle.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    for (final l in _launchByGame.values) {
      l.dispose();
    }
    for (final s in _serversByGame.values) {
      s.dispose();
    }
    _addonsListScroll.dispose();
    _launchOptionsScroll.dispose();
    for (final c in _cardScrolls.values) {
      c.dispose();
    }
    _player.dispose();
    super.dispose();
  }

  Future<void> _loadSavedData() async {
    // Демон (при первом запуске — ещё и скачивание antd) стартует параллельно,
    // чтобы список аддонов и настройки появились сразу, а не после его запуска.
    final daemonFuture = AntdDaemon.ensureRunning();
    final prefs = await SharedPreferences.getInstance();
    final savedGame = Games.byId(prefs.getString('app_game'));
    _game = Games.isEnabled(savedGame) ? savedGame : Games.srb2; // выключенная — SRB2
    AppThemes.currentGame.value = _game.id; // своя картинка темы у игры
    // Экзешники (старая "Launch command" переносится в список автоматически)
    // и серверы текущей игры загружаются при первом обращении.
    _launch;
    _servers;

    try {
      final saved = prefs.getString('addon_versions');
      if (saved != null) {
        (jsonDecode(saved) as Map<String, dynamic>).forEach((k, v) {
          if (v is String) _selectedVersions[k] = v;
        });
      }
    } catch (_) {}

    try {
      final savedBuilds = prefs.getString('installed_build_exes');
      if (savedBuilds != null) {
        (jsonDecode(savedBuilds) as Map<String, dynamic>).forEach((k, v) {
          if (v is String) _installedBuildExes[k] = v;
        });
      }
    } catch (_) {}

    _favoriteAddons.addAll(prefs.getStringList('addon_favorites') ?? const []);
    AddonPaths.versionFolders = prefs.getBool('addon_version_folders') ?? true;
    _showOtherDownloads = prefs.getBool('addons_show_other_downloads') ?? true;
    _showFolderAddons = prefs.getBool('addons_show_folder_addons') ?? true;
    _repositoryUpdates = RepositoryUpdates.values
        .firstWhere((m) => m.name == prefs.getString('repository_updates'), orElse: () => RepositoryUpdates.ask);
    _repoUpdateButtons = prefs.getBool('repository_update_buttons') ?? false;
    prefs.remove('addons_collapsed_groups'); // раньше сохранялось — теперь только в памяти
    _tagDisplay = (
      showGroup: prefs.getBool('addon_tags_show_group') ?? true,
      order: TagOrder.values.firstWhere((o) => o.name == prefs.getString('addon_tags_order'),
          orElse: () => TagOrder.groups),
      showAll: prefs.getBool('addon_tags_show_all') ?? true,
    );
    _iconAnimation = AddonIconAnimation.values
        .firstWhere((a) => a.name == prefs.getString('addon_icon_animation'), orElse: () => AddonIconAnimation.all);
    _playerEnabled = prefs.getBool('player_enabled') ?? false;
    _progressEnabled = prefs.getBool('progress_enabled') ?? false;
    _replaysEnabled = prefs.getBool('replays_enabled') ?? false;
    _progressHidden.addAll(prefs.getStringList('progress_hidden') ?? const []);
    for (final g in Games.all) {
      try {
        final list = jsonDecode(prefs.getString(g.key('progress_packs')) ?? '[]') as List;
        _progressPacks[g.id] = [
          for (final e in list.cast<Map<String, dynamic>>())
            // inQueue: заданный вручную пак важнее того же пака из репозитория.
            (title: e['title'] as String, files: (e['files'] as List).cast<String>(), inQueue: true),
        ];
      } catch (_) {}
    }
    _player.loadSettings();
    _hideNotDownloaded = prefs.getBool('addons_hide_not_downloaded') ?? false;
    _collapsedTagGroups.addAll(prefs.getStringList('tag_groups_collapsed') ?? const []);

    _autoHideTags = prefs.getBool('auto_hide_recommended_tags') ?? true;
    prefs.remove('hide_tags_offered'); // раньше теги добавлялись один раз
    final savedBlacklist = prefs.getString('blacklisted_tags');
    if (savedBlacklist != null) {
      blacklistedTagsString = savedBlacklist;
    }

    final savedMd5 = prefs.getString('md5_cache');
    if (savedMd5 != null) {
      try {
        (jsonDecode(savedMd5) as Map<String, dynamic>).forEach((path, v) {
          final e = _Md5Entry.fromJson(v);
          if (e != null) _md5Cache[path] = e;
        });
      } catch (_) {}
    }

    _loadGameState(prefs);
    SaveGuard.enabled = prefs.getBool(SaveGuard.prefsKey) ?? false;
    _startSaveBackupTimer();

    try {
      final pointers = jsonDecode(prefs.getString('repository_pointers') ?? '{}');
      if (pointers is Map) pointers.forEach((k, v) => _repoPointers['$k'] = '$v');
    } catch (_) {}
    _pointerManualOnly.addAll(prefs.getStringList('repository_pointers_manual') ?? const []);

    final imageHashes = <String>{};
    final savedManifestsRaw = prefs.getString('saved_repositories');
    if (savedManifestsRaw != null) {
      try {
        final Map<String, dynamic> decoded = jsonDecode(savedManifestsRaw);
        Map<String, List<ModItem>> restoredGroups = {};

        decoded.forEach((title, jsonValue) {
          final mods = ManifestService.parseMainIndex(jsonValue.toString(), sourceName: title);
          restoredGroups[title] = mods;
          rawManifests[title] = jsonValue.toString();

          for (var mod in mods) {
            if (mod.imageHash.isNotEmpty) imageHashes.add(mod.imageHash);
          }
        });

        setState(() => manifestGroups = restoredGroups);
        _refreshDownloaded();
      } catch (e) {
        print('Error restoring repositories: $e');
      }
    }

    // Пока демон запускается, показываем картинки из кэша на диске.
    for (final hash in imageHashes) {
      _loadModImage(hash);
    }

    // pointer.txt — сразу, не дожидаясь antd: «Подключить» в окне сам его ждёт.
    unawaited(_firstRun(prefs));
    final daemonOk = await daemonFuture;
    if (!mounted) return;
    setState(() => daemonReady = daemonOk);
    if (!daemonOk) {
      showSnack(context, 
        SnackBar(
          content: Text(tr('Could not start Autonomi (antd). See the console for details.')),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    // Остальные картинки скачиваются через демон.
    for (final hash in imageHashes) {
      _loadModImage(hash);
    }
    _syncPointerRepositories(prefs);
  }

  /// Обновлять ли репозитории по pointer при запуске (Settings → Addons).
  RepositoryUpdates _repositoryUpdates = RepositoryUpdates.ask;

  /// Кнопка ⟳ у каждого репозитория (Settings → Addons; по умолчанию нет).
  bool _repoUpdateButtons = false;

  /// Идёт проверка репозиториев (кнопка «Обновить репозитории»).
  bool _checkingRepositories = false;

  /// При запуске: подключает репозиторий по умолчанию (первый запуск), затем
  /// по настройке проверяет репозитории по pointer — обновляет сразу,
  /// спрашивает или не проверяет. Тихо: без сети всё остаётся как было.
  Future<void> _syncPointerRepositories(SharedPreferences prefs) async {
    if (_repositoryUpdates == RepositoryUpdates.off || !mounted) return;
    final (updates, _) = await _checkPointerRepositories();
    if (!mounted || updates.isEmpty) return;
    if (_repositoryUpdates == RepositoryUpdates.ask) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(tr('Repository updates')),
          content: Text(tr('New versions of these repositories are available:\n{names}\n\nUpdate now?',
              {'names': updates.map((u) => '• ${u.name}').join('\n')})),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Later'))),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Update'))),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    for (final u in updates) {
      await _applyRepositoryUpdate(u);
    }
  }

  /// Первый запуск — мастер (репозиторий, игры, экспериментальное), один раз;
  /// потом — только новый pointer.txt.
  Future<void> _firstRun(SharedPreferences prefs) async {
    const doneKey = 'setup_done';
    if (prefs.getBool(doneKey) == true) {
      // Исправленные описания своих игр из новой сборки.
      if (await CustomGames.refreshFromBundled(prefs) > 0 && mounted) _gamesChanged();
      await _offerPointerFile(prefs);
      // Новая версия лаунчера — окно с изменениями (не сразу: пусть загрузится).
      await Future<void>.delayed(const Duration(seconds: 3));
      if (mounted) await checkLauncherUpdateOnStart(context);
      return;
    }
    const offeredKey = 'pointer_file_offered';
    var pointer = AppPaths.pointerFromFile();
    if (pointer != null &&
        (prefs.getString(offeredKey) == pointer ||
            prefs.getBool('default_repository_added') == true ||
            _repoPointers.containsValue(pointer))) {
      pointer = null; // уже предлагался или подключён
    }
    final bundledPath = CustomGames.bundledPath();
    final bundled = await bundledGameDefinitions();
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final choice = await FirstRunWizard.show(
      context,
      FirstRunWizard(
        pointer: pointer,
        bundledGames: bundled,
        themeKey: widget.currentThemeKey,
        onThemeChanged: widget.onThemeChanged,
        folderOf: _folderOf,
        executableOf: (g) async {
          // Только путь: команда по умолчанию (srb2win.exe) — ещё не выбор.
          final program = (await _launchOf(g)).defaultExecutable?.program;
          return program != null && (program.contains('/') || program.contains(r'\')) ? program : null;
        },
        player: _playerEnabled,
        progress: _progressEnabled,
        replays: _replaysEnabled,
        saveProtection: SaveGuard.enabled,
      ),
    );
    if (choice == null || !mounted) return;
    await prefs.setBool(doneKey, true);
    // Язык, показанный в мастере (системный или выбранный), — теперь выбран.
    await prefs.setString('app_language', I18n.instance.code);
    final filePointer = AppPaths.pointerFromFile();
    if (filePointer != null) await prefs.setString(offeredKey, filePointer);

    for (final g in Games.builtIn) {
      await CustomGames.setEnabled(prefs, g.id, !choice.disabledGames.contains(g.id));
    }
    for (final d in choice.addGames) {
      try {
        await CustomGames.add(prefs, d, baseDir: bundledPath == null ? null : p.dirname(bundledPath));
      } catch (e) {
        AppLog.console('[games] could not add ${d['id']}: $e');
      }
    }
    for (final id in choice.declinedGames) {
      if (Games.custom.any((g) => g.id == id)) await CustomGames.remove(prefs, id);
    }
    for (final MapEntry(key: id, value: path) in choice.paths.entries) {
      final g = Games.find(id);
      if (g == null) continue;
      if (path.folder.isNotEmpty) await _setGameFolderOf(g, path.folder);
      if (path.executable.isNotEmpty) await _setDefaultExecutable(g, path.executable);
    }
    if (choice.player != _playerEnabled) await _setPlayerEnabled(choice.player);
    if (choice.progress != _progressEnabled) await _setProgressEnabled(choice.progress);
    if (choice.replays != _replaysEnabled) await _setReplaysEnabled(choice.replays);
    if (choice.saveProtection != SaveGuard.enabled) await _setSaveProtection(choice.saveProtection);
    if (!mounted) return;
    _gamesChanged();
    if (choice.connectRepository && pointer != null) unawaited(_connectPointerRepository(pointer));
  }

  /// Сборка [path] игры [g] — по умолчанию (из мастера первого запуска).
  /// Единственная сборка — команда без пути (srb2win.exe) — заменяется.
  Future<void> _setDefaultExecutable(GameDef g, String path) async {
    final launch = await _launchOf(g);
    final same = launch.executables.where((e) => PlatformUtils.samePath(e.program, path)).firstOrNull;
    if (same != null) return launch.setDefault(same.id);
    final command = PlatformUtils.quoteIfNeeded(path);
    final only = launch.executables.length == 1 ? launch.executables.single : null;
    if (only != null && !only.program.contains('/') && !only.program.contains(r'\')) {
      launch.updateExecutable(only.copyWith(name: launch.uniqueName(path), command: command));
      return;
    }
    final e = LaunchExecutable(id: LaunchExecutable.newId(), name: launch.uniqueName(path), command: command);
    launch.addExecutable(e);
    launch.setDefault(e.id);
  }

  /// Скачивает и подключает репозиторий по [pointer] (выбран в мастере);
  /// не вышло — окно «Добавить репозиторий» с ним, чтобы повторить.
  Future<void> _connectPointerRepository(String pointer) async {
    showSnack(context, SnackBar(content: Text(tr('Downloading the repository...'))));
    try {
      if (!await AntdDaemon.ensureRunning()) throw Exception(tr('Autonomi daemon is not running'));
      final (text, viaPointer) = await AutonomiService.downloadRepository(pointer);
      if (text == null) throw Exception(tr('Failed to download index by Autonomi hash'));
      final decoded = jsonDecode(text);
      final name = (decoded is Map ? decoded['repository_name'] : null) ?? tr('Unnamed Repository');
      if (!mounted) return;
      await _addRepository('$name', text, pointer: viaPointer);
    } catch (e) {
      AppLog.console('Repository pointer $pointer: $e');
      if (!mounted) return;
      await _openAddManifestDialog(
        pointer: pointer,
        intro: tr('Could not download the repository: {error}', {'error': e}),
      );
    }
  }

  /// Новый `pointer.txt` рядом с лаунчером (после мастера) — предложить подключить
  /// репозиторий по нему (окно «Подключить репозиторий» с этим pointer).
  /// Предлагается один раз на pointer; если он уже подключён — не предлагается.
  Future<void> _offerPointerFile(SharedPreferences prefs) async {
    const offeredKey = 'pointer_file_offered';
    final pointer = AppPaths.pointerFromFile();
    if (pointer == null || prefs.getString(offeredKey) == pointer) return;
    // Раньше репозиторий по умолчанию подключался сам — второй раз не нужно.
    if (prefs.getBool('default_repository_added') == true || _repoPointers.containsValue(pointer)) {
      await prefs.setString(offeredKey, pointer);
      return;
    }
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    await prefs.setString(offeredKey, pointer);
    await _openAddManifestDialog(
      pointer: pointer,
      intro: tr('pointer.txt next to the launcher names an addon repository. Download and connect it?'),
    );
  }

  /// Репозитории по pointer, файл которых изменился: (обновления, сколько не
  /// загрузилось). Ничего не меняет — см. [_applyRepositoryUpdate].
  /// [all] — и обновлённые из файла (кнопка «Обновить репозитории»); без
  /// него — только те, что обновляются сами (при запуске).
  /// [only] — проверить один репозиторий (кнопка у репозитория).
  Future<(List<_RepoUpdate>, int)> _checkPointerRepositories({bool all = false, String? only}) async {
    final updates = <_RepoUpdate>[];
    var failed = 0;
    for (final MapEntry(key: title, value: pointer) in Map.of(_repoPointers).entries) {
      if (only != null && title != only) continue;
      if (!all && _pointerManualOnly.contains(title)) continue;
      final (text, viaPointer) = await AutonomiService.downloadRepository(pointer);
      if (!mounted) break;
      if (text == null || viaPointer == null) {
        AppLog.console('Repository pointer $pointer: not loaded');
        failed++;
        continue;
      }
      if (rawManifests[title] == text) continue; // не изменился
      try {
        final name = (jsonDecode(text) as Map)['repository_name']?.toString() ?? tr('Unnamed Repository');
        updates.add((title: title, name: name, text: text, pointer: viaPointer));
      } catch (e) {
        AppLog.console('Repository pointer $pointer: $e');
        failed++;
      }
    }
    return (updates, failed);
  }

  Future<void> _applyRepositoryUpdate(_RepoUpdate u) async {
    // Название в новом файле могло смениться — старое убираем (а что нового —
    // сообщаем, сравнив со старым списком).
    List<ModItem>? renamedFrom;
    if (u.title != u.name) {
      renamedFrom = manifestGroups.remove(u.title);
      rawManifests.remove(u.title);
      _repoPointers.remove(u.title);
      _pointerManualOnly.remove(u.title);
    }
    await _addRepository(u.name, u.text, pointer: u.pointer, quiet: true);
    if (renamedFrom != null) _noticeRepositoryUpdate(u.name, renamedFrom, manifestGroups[u.name] ?? const []);
  }

  /// Репозиторий, который сейчас проверяется кнопкой у него.
  String? _checkingRepository;

  /// Кнопка «Обновить репозитории» (или у одного репозитория — [only]):
  /// проверить по pointer и обновить сейчас (при любой настройке), итог — в
  /// сообщении. Клиенту не нужно заново вводить pointer.
  Future<void> _updateRepositoriesNow({String? only}) async {
    if (_checkingRepositories || _checkingRepository != null) return;
    setState(() => only == null ? _checkingRepositories = true : _checkingRepository = only);
    try {
      final (updates, failed) = await _checkPointerRepositories(all: true, only: only);
      for (final u in updates) {
        if (!mounted) return;
        await _applyRepositoryUpdate(u);
      }
      if (!mounted) return;
      final parts = [
        updates.isEmpty
            ? tr('Repositories are up to date.')
            : tr('Updated: {names}', {'names': updates.map((u) => u.name).join(', ')}),
        if (failed > 0) tr('Could not load {n} repositories (is Autonomi running?).', {'n': failed}),
      ];
      showSnack(context, SnackBar(content: Text(parts.join(' '))));
    } finally {
      if (mounted) {
        setState(() {
          _checkingRepositories = false;
          _checkingRepository = null;
        });
      }
    }
  }

  Future<void> _saveRepositories() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_repositories', jsonEncode(rawManifests));
    _repoPointers.removeWhere((title, _) => !rawManifests.containsKey(title));
    _pointerManualOnly.removeWhere((title) => !_repoPointers.containsKey(title));
    await prefs.setString('repository_pointers', jsonEncode(_repoPointers));
    await prefs.setStringList('repository_pointers_manual', _pointerManualOnly.toList());
  }

  // --- Отмена и повтор изменений очереди (Ctrl+Z / Ctrl+Y) ---

  final _queueHistory = StateHistory<_QueueState>();

  /// Очередь при последнем сохранении: с ней сравнивается новая.
  _QueueState? _queueLast;
  bool _restoringQueue = false;

  _QueueState _queueState() {
    final o = _launch.options;
    return (
      queue: List.of(selectedFilesQueue),
      off: {for (final e in _disabledQueue) if (selectedFilesQueue.contains(e)) e},
      gametype: o.gametype,
      skin: o.cvar('skin'),
      color: o.cvar('color'),
      warp: o.warpMap,
    );
  }

  /// Перед сохранением изменённой очереди: прежняя очередь с текущим (ещё не
  /// сброшенным) выбором — в историю отмены. Персонаж, карта и т.п. из
  /// убранного аддона сбрасываются потом ([_dropOrphanSelections]) — отмена
  /// возвращает их, повтор снова убирает.
  void _recordQueueChange() {
    final now = _queueState();
    final last = _queueLast;
    _queueLast = now;
    if (_restoringQueue || last == null) return;
    if (_sameList(last.queue, now.queue) && last.off.length == now.off.length && last.off.containsAll(now.off)) return;
    _queueHistory.record((
      queue: last.queue,
      off: last.off,
      gametype: now.gametype,
      skin: now.skin,
      color: now.color,
      warp: now.warp,
    ));
  }

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// История — своя у каждой игры: при смене игры начинается заново.
  void _resetQueueHistory() {
    _queueHistory.clear();
    _queueLast = _queueState();
  }

  void _undoQueue() {
    if (_queueHistory.undo(_queueState()) case final s?) _restoreQueue(s);
  }

  void _redoQueue() {
    if (_queueHistory.redo(_queueState()) case final s?) _restoreQueue(s);
  }

  void _restoreQueue(_QueueState s) {
    setState(() {
      selectedFilesQueue = List.of(s.queue);
      _disabledQueue
        ..clear()
        ..addAll(s.off);
    });
    _launch.updateOptions((o) {
      o.gametype = s.gametype;
      o.setCvar('skin', s.skin);
      o.setCvar('color', s.color);
      o.warpMap = s.warp;
    });
    _restoringQueue = true;
    try {
      _saveLaunchQueue();
    } finally {
      _restoringQueue = false;
    }
  }

  /// Ctrl+Z / Ctrl+Y / Ctrl+Shift+Z на вкладке Launch, если фокус не в поле
  /// ввода (там своя отмена) и поверх нет окна.
  bool _onQueueUndoKey(KeyEvent e) {
    if (e is! KeyDownEvent || _currentTab != 1 || !mounted) return false;
    final keys = HardwareKeyboard.instance;
    if (!(keys.isControlPressed || keys.isMetaPressed) || keys.isAltPressed) return false;
    final focus = FocusManager.instance.primaryFocus?.context;
    if (focus != null && (focus.widget is EditableText || focus.findAncestorWidgetOfExactType<EditableText>() != null)) {
      return false;
    }
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    if (e.logicalKey == LogicalKeyboardKey.keyZ) {
      keys.isShiftPressed ? _redoQueue() : _undoQueue();
      return true;
    }
    if (e.logicalKey == LogicalKeyboardKey.keyY) {
      _redoQueue();
      return true;
    }
    return false;
  }

  Future<void> _saveLaunchQueue() async {
    _recordQueueChange();
    _dropOrphanSelections();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kQueue, selectedFilesQueue);
    _disabledQueue.retainAll(selectedFilesQueue);
    await prefs.setStringList(_kQueueOff, _disabledQueue.toList());
  }

  /// Папка и очередь текущей игры.
  void _loadGameState(SharedPreferences prefs) {
    final savedPath = PlatformUtils.cleanUserPath(prefs.getString(_kFolder) ?? '');
    setState(() {
      srb2FolderPath = savedPath.isEmpty ? null : savedPath;
      selectedFilesQueue = List.of(prefs.getStringList(_kQueue) ?? const []);
      _disabledQueue
        ..clear()
        ..addAll((prefs.getStringList(_kQueueOff) ?? const []).where(selectedFilesQueue.contains));
    });
    _resetQueueHistory();
  }

  /// Переключает игру: своя папка, очередь, сборки и серверы; список
  /// аддонов показывает только аддоны для неё.
  Future<void> _switchGame(GameDef game) async {
    if (game == _game) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_game', game.id);
    if (!mounted) return;
    // Выбранный аддон — заново из полного списка: у показанного остались
    // только файлы прошлой игры.
    final previous = selectedMod;
    ModItem? original;
    for (final m in manifestGroups[previous?.repositorySource] ?? const <ModItem>[]) {
      if (m.key == previous!.key) original = m;
    }
    setState(() {
      _game = game;
      AppThemes.currentGame.value = game.id;
      _selectedLocalFile = null; // файл из «Других загрузок» — прошлой игры
      fileStatuses = {};
      localMd5Cache = {};
      _localPaths = {};
      _conflictPaths = {};
      selectedMod = original?.forGame(game.id, orBase: game.addonBase);
    });
    _launch;
    _servers;
    _loadGameState(prefs);
    if (selectedMod != null && srb2FolderPath != null) _checkModFilesStatus(selectedMod!);
    _refreshDownloaded();
  }

  /// Набор игр изменился (Settings → Games): выключенная/убранная текущая
  /// игра — к SRB2, своя игра с новым описанием — заново.
  void _gamesChanged() {
    // Серверы и сборки, собранные по старому описанию своей игры.
    _serversByGame.removeWhere((id, s) => !identical(Games.find(id), s.game));
    _launchByGame.removeWhere((id, l) => !identical(Games.find(id), l.game));
    final now = Games.find(_game.id);
    if (now == null || !Games.isEnabled(now)) {
      _switchGame(Games.srb2);
    } else if (!identical(now, _game)) {
      _switchGame(now);
    } else {
      setState(() {});
    }
  }

  /// Переключатель игры на месте заголовка окна и кнопка «Открыть папку игры».
  Widget _buildGameSwitcher() {
    final folder = srb2FolderPath;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: _buildGameMenu()),
        IconButton(
          icon: const Icon(Icons.folder_open_outlined, size: 20),
          tooltip: folder == null
              ? tr('Open the game folder (set it in Settings first)')
              : tr('Open the game folder: {path}', {'path': folder}),
          onPressed: folder == null || !Directory(folder).existsSync() ? null : () => openFolder(context, folder),
        ),
      ],
    );
  }

  Widget _buildGameMenu() {
    return PopupMenuButton<GameDef>(
      tooltip: tr('Switch game'),
      initialValue: _game,
      onSelected: _switchGame,
      position: PopupMenuPosition.under,
      itemBuilder: (context) => [
        // Только включённые игры (Settings → Games).
        for (final g in Games.enabled)
          PopupMenuItem(
            value: g,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: GameIcon(g, size: 28),
              trailing: g == _game ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
              title: Text(g.fullName),
              subtitle: g.name == g.fullName ? null : Text(g.name),
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            GameIcon(_game, size: 26),
            const SizedBox(width: 10),
            Flexible(
              child: Text(_game.fullName, overflow: TextOverflow.ellipsis),
            ),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }

  /// Папка для аддонов внутри папки игры (SRB2 — DOWNLOAD,
  /// Ring Racers — addons/DOWNLOAD), с родными для ОС разделителями.
  String? get _downloadDir =>
      srb2FolderPath == null ? null : p.joinAll([srb2FolderPath!, ..._game.downloadPath]);

  bool _isPathEntry(String entry) => entry.contains('/') || entry.contains('\\');
  String _entryName(String entry) => entry.split(RegExp(r'[/\\]')).last;
  String _entryFolder(String entry) {
    final i = entry.lastIndexOf(RegExp(r'[/\\]'));
    return i <= 0 ? '' : entry.substring(0, i);
  }

  /// Записи очереди: пути внутри DOWNLOAD — относительно неё
  /// ("KNOCKOUT/V1.4b/CL_Knockout.pk3" или просто имя файла), остальные — полные.
  String _entryPath(String entry) =>
      p.isAbsolute(entry) ? entry : p.join(_downloadDir!, entry);

  /// Запись очереди для файла: относительно DOWNLOAD, если он внутри неё.
  /// На Windows сравнение без учёта регистра и вида слэшей.
  String _queueEntryFor(String path) {
    final downloads = _downloadDir;
    if (downloads != null && p.isWithin(downloads, path)) {
      return p.relative(path, from: downloads);
    }
    return path;
  }

  String _normalizeDroppedPath(String path) => _queueEntryFor(path);

  /// Добавляет аддоны (из drag & drop или диалога выбора файлов) в очередь.
  void _addPathsToQueue(Iterable<String> paths) {
    final newEntries = <String>[];
    var invalid = 0;
    for (final path in paths) {
      if (!PlatformUtils.isAddonFile(path)) {
        invalid++;
        continue;
      }
      final entry = _normalizeDroppedPath(path);
      if (!selectedFilesQueue.contains(entry) && !newEntries.contains(entry)) {
        newEntries.add(entry);
      }
    }

    if (newEntries.isNotEmpty) {
      setState(() => selectedFilesQueue.addAll(newEntries));
      _saveLaunchQueue();
      showSnack(context, 
        SnackBar(content: Text(tr('Added {n} file(s) to launch queue!', {'n': newEntries.length})), backgroundColor: Colors.green),
      );
    } else if (invalid > 0) {
      showSnack(context, 
        SnackBar(content: Text(tr('No valid addon files (.wad, .pk3, .lua, .soc) were dropped!')), backgroundColor: Colors.orange),
      );
    } else {
      showSnack(context, 
        SnackBar(content: Text(tr('These files are already in the launch queue.'))),
      );
    }
  }

  static final _addonTypeGroup = XTypeGroup(
    label: tr('Game addons'),
    // GTK-фильтры чувствительны к регистру, поэтому добавляем и .PK3 и т.п.
    extensions: [
      for (final e in PlatformUtils.addonExtensions) ...[e, e.toUpperCase()],
    ],
  );

  Future<void> _pickFilesForQueue() async {
    final downloads = _downloadDir;
    final initialDir =
        downloads != null && await Directory(downloads).exists() ? downloads : null;
    AppLog.action('open the openFiles dialog (main.dart)');
    final files = await openFiles(
      acceptedTypeGroups: [_addonTypeGroup],
      initialDirectory: initialDir,
      confirmButtonText: tr('Add'),
    );
    if (!mounted || files.isEmpty) return;
    _addPathsToQueue(files.map((f) => f.path));
  }

  void _addFileToQueue(String entry) {
    if (!selectedFilesQueue.contains(entry)) {
      setState(() => selectedFilesQueue.add(entry));
      _saveLaunchQueue();
      showSnack(context, 
        SnackBar(content: Text(tr('Added "{name}" to launch queue', {'name': _entryName(entry)}))),
      );
    }
  }

  /// Убирает из очереди выключенные аддоны ([disabledOnly]) или все; в
  /// сообщении — «Отменить».
  void _clearQueue({required bool disabledOnly}) {
    final removed = disabledOnly ? _disabledQueue.length : selectedFilesQueue.length;
    if (removed == 0) return;
    setState(() {
      if (disabledOnly) {
        selectedFilesQueue.removeWhere(_disabledQueue.contains);
      } else {
        selectedFilesQueue.clear();
      }
      _disabledQueue.clear();
    });
    _saveLaunchQueue();
    showSnack(
      context,
      SnackBar(
        content: Text(disabledOnly
            ? tr('Removed {n} disabled addon(s) from the queue', {'n': removed})
            : tr('Removed {n} addon(s) from the queue', {'n': removed})),
        // Та же отмена, что Ctrl+Z: вернёт и персонажа, карту и т.п.
        action: SnackBarAction(
          label: tr('Undo'),
          onPressed: () {
            if (mounted) _undoQueue();
          },
        ),
      ),
    );
  }

  void _removeFileFromQueue(int index) {
    setState(() => _disabledQueue.remove(selectedFilesQueue.removeAt(index)));
    _saveLaunchQueue();
  }

  /// Перетаскивание в списке очереди.
  void _reorderQueue(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex--;
    if (oldIndex == newIndex) return;
    setState(() => selectedFilesQueue.insert(newIndex, selectedFilesQueue.removeAt(oldIndex)));
    _saveLaunchQueue();
  }

  void _setQueueEntryEnabled(String entry, bool enabled) {
    setState(() => enabled ? _disabledQueue.remove(entry) : _disabledQueue.add(entry));
    _saveLaunchQueue();
  }

  void _moveQueueItem(int index, int direction) {
    final targetIndex = index + direction;
    if (targetIndex < 0 || targetIndex >= selectedFilesQueue.length) return;
    setState(() {
      final item = selectedFilesQueue.removeAt(index);
      selectedFilesQueue.insert(targetIndex, item);
    });
    _saveLaunchQueue();
  }

  Map<String, String>? _cleanChildEnvironment() => cleanChildEnvironment();


  /// Окно настроек (разделы: General, Game folder, Addons, Launch, Servers).
  Future<void> _openSettings([SettingsSection section = SettingsSection.general]) {
    return SettingsDialog.show(
      context,
      SettingsDialog(
        initialSection: section,
        game: _game,
        gameFolderOf: _folderOf,
        launchOf: _launchOf,
        serversOf: (g) => _serversByGame.putIfAbsent(g.id, () => ServersStore(g)..load()),
        onGameFolderChanged: _setGameFolderOf,
        onGamesChanged: _gamesChanged,
        onHiddenFoldersChanged: (g) {
          if (g.id == _game.id) _refreshServerAddons();
        },
        hiddenTags: blacklistedTagsString,
        playerEnabled: _playerEnabled,
        onPlayerEnabledChanged: _setPlayerEnabled,
        progressEnabled: _progressEnabled,
        onProgressEnabledChanged: _setProgressEnabled,
        replaysEnabled: _replaysEnabled,
        onReplaysEnabledChanged: _setReplaysEnabled,
        onSaveProtectionChanged: _setSaveProtection,
        progressHidden: _progressHidden.toList()..sort(),
        onProgressUnhide: (id) => _setProgressHidden(id, false),
        versionFolders: AddonPaths.versionFolders,
        onRestartAutonomi: _restartAutonomi,
        iconAnimation: _iconAnimation,
        onIconAnimationChanged: _setIconAnimation,
        tagDisplay: _tagDisplay,
        onTagDisplayChanged: (v) async {
          setState(() => _tagDisplay = v);
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool('addon_tags_show_group', v.showGroup);
          await prefs.setBool('addon_tags_show_all', v.showAll);
          await prefs.setString('addon_tags_order', v.order.name);
        },
        showOtherDownloads: _showOtherDownloads,
        onShowOtherDownloadsChanged: (v) async {
          setState(() {
            _showOtherDownloads = v;
            if (!v && _serverAddonFiles.contains(_selectedLocalFile)) _selectedLocalFile = null;
          });
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool('addons_show_other_downloads', v);
        },
        repositoryUpdates: _repositoryUpdates,
        onRepositoryUpdatesChanged: (v) async {
          setState(() => _repositoryUpdates = v);
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('repository_updates', v.name);
        },
        repositoryUpdateButtons: _repoUpdateButtons,
        onRepositoryUpdateButtonsChanged: (v) async {
          setState(() => _repoUpdateButtons = v);
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool('repository_update_buttons', v);
        },
        showFolderAddons: _showFolderAddons,
        onShowFolderAddonsChanged: (v) async {
          setState(() {
            _showFolderAddons = v;
            if (!v && _folderAddonFiles.contains(_selectedLocalFile)) _selectedLocalFile = null;
          });
          if (v) _refreshServerAddons();
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool('addons_show_folder_addons', v);
        },
        onVersionFoldersChanged: (v) async {
          setState(() => AddonPaths.versionFolders = v);
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool('addon_version_folders', v);
          if (selectedMod != null) _checkModFilesStatus(selectedMod!);
        },
        onHiddenTagsChanged: (value) async {
          setState(() => blacklistedTagsString = value);
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('blacklisted_tags', value);
        },
        autoHideTags: _autoHideTags,
        onAutoHideTagsChanged: _setAutoHideTags,
        themeKey: widget.currentThemeKey,
        onThemeChanged: widget.onThemeChanged,
      ),
    );
  }

  /// Папка игры [g] из настроек: у текущей — со всем, что от неё зависит,
  /// у другой — только запомнить. Текст ошибки или null.
  Future<String?> _setGameFolderOf(GameDef g, String raw) async {
    if (g == _game) return _setGameFolder(raw);
    final folder = PlatformUtils.cleanUserPath(raw);
    if (folder.isNotEmpty && !await Directory(folder).exists()) return tr('Folder does not exist');
    final prefs = await SharedPreferences.getInstance();
    if (folder.isEmpty) {
      await prefs.remove(_folderKey(g));
    } else {
      await prefs.setString(_folderKey(g), folder);
    }
    return null;
  }

  /// Новая папка игры; возвращает текст ошибки или null.
  Future<String?> _setGameFolder(String raw) async {
    final folder = PlatformUtils.cleanUserPath(raw);
    if (folder.isNotEmpty && !await Directory(folder).exists()) return tr('Folder does not exist');
    setState(() {
      srb2FolderPath = folder.isEmpty ? null : folder;
      fileStatuses = {};
      localMd5Cache = {};
      _localPaths = {};
    });
    final prefs = await SharedPreferences.getInstance();
    if (folder.isEmpty) {
      await prefs.remove(_kFolder);
    } else {
      await prefs.setString(_kFolder, folder);
    }
    if (selectedMod != null && srb2FolderPath != null) _checkModFilesStatus(selectedMod!);
    _refreshDownloaded();
    return null;
  }

  /// Защита сохранений перед запуском: только файлы, что использует запуск
  /// ([files] — их GameData, иначе файлы самой игры). Повреждённые —
  /// восстановить из копии (в уведомления), про уменьшившийся прогресс —
  /// спросить.
  Future<void> _guardSaves(String folder, List<String> files) async {
    if (!SaveGuard.enabled) return;
    try {
      final targets = SaveGuard.targetsFor(_game.id, await SaveGuard.gameDataOf(files));
      _activeSaves = (gameId: _game.id, folder: folder, targets: targets);
      final events = await SaveGuard.check(_game.id, folder, repair: true, only: targets);
      if (events.isEmpty) return;
      noticeSaveEvents(events);
      var replaced = events.any((e) => e.type == SaveEventType.restored);
      if (mounted && events.any((e) => e.type == SaveEventType.decreased)) {
        replaced = await askDecreasedSaves(context, events) || replaced;
      }
      if (replaced) _savesReplaced();
    } catch (e) {
      AppLog.console('[saves] check before launch failed: $e');
    }
  }

  /// Что проверять фоном: файлы последнего запуска.
  ({String gameId, String folder, SaveTargets targets})? _activeSaves;

  /// Окно «Копии сохранений» (вкладка Progress).
  Future<bool> _openSaveBackups() async {
    final folder = srb2FolderPath;
    if (folder == null) return false;
    final replaced = await showSaveBackupsDialog(context, gameId: _game.id, folder: folder);
    if (replaced) ProgressTab.invalidate();
    return replaced;
  }

  /// Файлы сохранений заменены: вкладка Progress перечитывает их.
  void _savesReplaced() {
    ProgressTab.invalidate();
    if (mounted) setState(() => _savesVersion++);
  }

  /// Меняется, когда файлы сохранений заменены копиями (ключ вкладки Progress).
  int _savesVersion = 0;

  /// Фоновая проверка сохранений: свежая копия, пока игра идёт и после неё.
  Timer? _saveBackupTimer;

  void _startSaveBackupTimer() {
    _saveBackupTimer ??= Timer.periodic(const Duration(seconds: 20), (_) {
      final a = _activeSaves;
      if (SaveGuard.enabled && a != null) SaveGuard.check(a.gameId, a.folder, repair: false, only: a.targets);
    });
  }

  /// Пока запуск готовится, второй не начинается (кнопки пишут «Checking…»).
  Future<void> _preparingLaunch(Future<void> Function() body) async {
    if (launchPreparing.value) return;
    launchPreparing.value = true;
    try {
      await body();
    } finally {
      launchPreparing.value = false;
    }
  }

  /// Находит исполняемый файл игры. Имена и относительные пути сначала ищутся
  /// в папке игры (`srb2win.exe`, `./lsdl2srb2`), иначе остаются как есть и
  /// ищутся ОС в PATH (`srb2`, `flatpak`). Если команда стандартная, пробуем
  /// и другие известные имена бинарника SRB2.
  Future<String> _resolveExecutable(String executable, {required bool isDefault}) async {
    if (p.isAbsolute(executable)) return executable;

    final candidates = <String>[executable];
    if (Platform.isWindows && p.extension(executable).isEmpty) {
      candidates.add('$executable.exe');
    }
    if (isDefault) {
      candidates.addAll(PlatformUtils.knownExecutables(game: _game).where((e) => e != executable));
    }

    for (final name in candidates) {
      final local = p.normalize(p.join(srb2FolderPath!, name));
      if (await FileSystemEntity.type(local) == FileSystemEntityType.file) {
        return local;
      }
    }
    return executable;
  }

  /// Вкладки: Addons, Launch (с размером очереди), Servers.
  List<String> get _tabLabels => [
        tr('Addons'),
        // Считаем только включённые: выключенные в игру не попадут.
        _activeQueue.isEmpty ? tr('Launch') : tr('Launch ({n})', {'n': _activeQueue.length}),
        tr('Servers'),
        // Ключ 'Music': 'Player' уже занят («Игрок» в параметрах запуска).
        if (_playerEnabled) tr('Music'),
        if (_progressEnabled) tr('Progress'),
        if (_replaysEnabled) tr('Replays'),
      ];

  /// Где плеер ищет музыку: файлы игры, затем скачанные аддоны.
  /// Где искать музыку: у каждой игры — её файлы, скачанные аддоны и
  /// другие загрузки (в этом порядке — так же идут разделы плеера).
  Future<List<MusicSource>> _musicSources() async {
    final out = <MusicSource>[];
    final missing = <String, List<String>>{};
    for (final g in Games.enabled) {
      try {
        final folder = await _folderOf(g);
        final launch = await _launchOf(g);
        final found = await GameFiles.resolveAsync(g, folder, launch, g.musicFiles);
        for (final f in found) {
          out.add(MusicSource(f, g.id, MusicCategory.game));
        }
        // Для подсказки в плеере: что из файлов игры не нашлось.
        missing[g.id] = [
          for (final rel in g.musicFiles)
            if (!found.any((f) => p.basename(f).toLowerCase() == p.basename(rel).toLowerCase())) rel,
        ];
        if (folder == null) continue;
        // Название аддона — чтобы плеер показывал, из какого он аддона.
        final names = {
          for (final group in manifestGroups.values)
            for (final m in group) m.key: m.name,
        };
        for (final MapEntry(key: modKey, value: files) in (await _downloadedModFiles(g, folder)).entries) {
          for (final f in files) {
            out.add(MusicSource(f, g.id, MusicCategory.addons, names[modKey] ?? ''));
          }
        }
        for (final f in await _otherDownloads(p.joinAll([folder, ...g.downloadPath]))) {
          out.add(MusicSource(f, g.id, MusicCategory.downloads));
        }
        for (final f in await _folderAddons(g, folder)) {
          out.add(MusicSource(f, g.id, MusicCategory.folder));
        }
      } catch (e) {
        // Папка игры недоступна — без её музыки.
        AppLog.console('[music] ${g.id}: $e');
      }
    }
    _player.missingGameFiles = missing;
    return out;
  }

  /// Медиаклавиши клавиатуры управляют плеером на любой вкладке.
  bool _onMediaKey(KeyEvent e) => _playerEnabled && handlePlayerMediaKey(_player, e);

  /// Мини-плеер внизу окна на вкладках, кроме самого плеера.
  Widget _withMiniPlayer(Widget body) {
    if (!_playerEnabled || _currentTab == _playerTab) return body;
    return Column(
      children: [
        Expanded(child: body),
        MiniPlayer(
          player: _player,
          onOpen: () {
            if (_playerTab case final tab?) setState(() => _currentTab = tab);
          },
        ),
      ],
    );
  }

  /// Щелчок по уровню в плеере: та игра, -warp на уровень; аддон с треком —
  /// в очередь запуска.
  Future<void> _warpFromPlayer(String gameId, String map, String? addonFile, {bool encore = false}) async {
    final game = Games.all.where((g) => g.id == gameId).firstOrNull;
    if (game == null) return;
    if (game != _game) await _switchGame(game);
    if (!mounted) return;
    // Трек играет в Encore — включаем режим, обычная музыка уровня — выключаем.
    if (game.encoreCvar case final cvar?) _launch.updateOptions((o) => o.setCvar(cvar, encore ? 'On' : ''));
    if (addonFile != null) {
      _warpTo(map, addonFile);
      return;
    }
    _launch.updateOptions((o) => o.warpMap = map);
    setState(() {});
    showSnack(
      context,
      SnackBar(
        content: Text(encore
            ? tr('-warp {map} and Encore mode are set.', {'map': map})
            : tr('-warp {map} is set.', {'map': map})),
        action: SnackBarAction(label: tr('Launch'), onPressed: () => _launchGame()),
      ),
    );
  }

  /// Новые загрузки — в плеер (из кэша поиска это быстро). Не чаще раза в
  /// несколько секунд.
  Timer? _playerRescan;
  void _schedulePlayerRescan() {
    if (!_playerEnabled || _player.tracks.isEmpty) return;
    _playerRescan?.cancel();
    _playerRescan = Timer(const Duration(seconds: 3), () async {
      if (!mounted || !_playerEnabled || _player.scanning) return;
      _player.scan(await _musicSources());
    });
  }

  Future<void> _setPlayerEnabled(bool v) async {
    setState(() {
      // Вкладки Progress и Replays сдвигаются вместе с Music.
      final onProgress = _currentTab == _progressTab;
      final onReplays = _currentTab == _replaysTab;
      if (!v && _currentTab == _playerTab) _currentTab = 0;
      _playerEnabled = v;
      if (onProgress) _currentTab = _progressTab!;
      if (onReplays) _currentTab = _replaysTab!;
    });
    if (!v) _player.shutdown();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('player_enabled', v);
  }

  Future<void> _setProgressEnabled(bool v) async {
    setState(() {
      // Вкладка Replays сдвигается вместе с Progress.
      final onReplays = _currentTab == _replaysTab;
      if (!v && _currentTab == _progressTab) _currentTab = 0;
      _progressEnabled = v;
      if (onReplays) _currentTab = _replaysTab!;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('progress_enabled', v);
  }

  Future<void> _setReplaysEnabled(bool v) async {
    setState(() {
      if (!v && _currentTab == _replaysTab) _currentTab = 0;
      _replaysEnabled = v;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('replays_enabled', v);
  }

  Future<void> _setSaveProtection(bool v) async {
    setState(() => SaveGuard.enabled = v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(SaveGuard.prefsKey, v);
  }

  Future<void> _setProgressHidden(String id, bool hidden) async {
    setState(() => hidden ? _progressHidden.add(id) : _progressHidden.remove(id));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('progress_hidden', _progressHidden.toList());
  }

  /// Аддоны, у которых может быть свой прогресс: пока только аддоны
  /// репозиториев (версия из очереди запуска, иначе новейшая скачанная).
  Future<List<ProgressCandidate>> _progressCandidates() async {
    final root = srb2FolderPath;
    final downloads = _downloadDir;
    if (root == null || downloads == null) return const [];
    final index = await LocalFileIndex.shared(root);
    final queue = {for (final e in selectedFilesQueue) p.normalize(_entryPath(e))};
    final out = <ProgressCandidate>[];
    for (final group in manifestGroups.values) {
      for (final m in group) {
        final mod = m.forGame(_game.id, orBase: _game.addonBase);
        if (mod == null) continue;
        List<String>? chosen;
        var inQueue = false;
        for (final v in mod.versions) {
          final files = [
            for (final f in v.files)
              AddonPaths.candidates(downloads, mod, f).where((c) => File(c).existsSync()).firstOrNull ??
                  index.firstByName(f.name),
          ];
          if (files.isEmpty || files.contains(null)) continue;
          final local = files.cast<String>();
          if (local.any((f) => queue.contains(p.normalize(f)))) {
            chosen = local;
            inQueue = true;
            break;
          }
          chosen ??= local; // версии от новой к старой
        }
        if (chosen != null) out.add((title: mod.name, files: chosen, inQueue: inQueue));
      }
    }
    // Добавленные и исправленные вручную — первыми (важнее паков из
    // репозитория с тем же GameData), если их файлы на месте.
    return [
      for (final c in _progressPacks[_game.id] ?? const <ProgressCandidate>[])
        if (c.files.every((f) => File(f).existsSync())) c,
      ...out,
    ];
  }

  Future<void> _saveProgressPacks(GameDef game) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(game.key('progress_packs'), jsonEncode([
      for (final c in _progressPacks[game.id] ?? const <ProgressCandidate>[]) {'title': c.title, 'files': c.files},
    ]));
  }

  /// «Add Map Pack»: файлы левелпака из диалога. Возвращает id пака (имя
  /// файла прогресса) или null.
  Future<String?> _addProgressPack() async {
    AppLog.action('open the openFiles dialog (Add Map Pack)');
    final picked = await openFiles(acceptedTypeGroups: [_addonTypeGroup], confirmButtonText: tr('Add'));
    if (!mounted || picked.isEmpty) return null;
    final files = [for (final f in picked) p.normalize(f.path)];
    return _storeProgressPack(p.basenameWithoutExtension(files.first), files);
  }

  /// Сохраняет левелпак [files] (в порядке загрузки) в списке Progress этой
  /// игры — только если у него свой прогресс (MainCfg → GameData), иначе
  /// сообщение. [replacing] — прежние файлы этого пака (правка). Пак,
  /// заданный вручную, важнее того же пака из репозитория.
  Future<String?> _storeProgressPack(String title, List<String> files, {List<String>? replacing}) async {
    final root = srb2FolderPath;
    if (root == null || files.isEmpty) return null;
    ProgressPack? pack;
    try {
      final base = [...await _gameFiles(_game.paletteFiles), ...await _gameFiles(_game.baseMapFiles)];
      final packs = await ProgressPack.discover(root, base, [(title: title, files: files, inQueue: false)],
          orphans: false, gameTitle: _game.fullName, kart: _game.id == 'srb2kart');
      pack = packs.where((x) => !x.vanilla).firstOrNull;
    } catch (e) {
      AppLog.write('Map pack $title: $e');
    }
    if (!mounted) return null;
    if (pack == null) {
      showSnack(context, SnackBar(
        content: Text(tr('{name} has no progress of its own: its SOC does not set GameData in MainCfg, '
            'or it has no emblems and no Record Attack levels.', {'name': p.basename(files.first)})),
      ));
      return null;
    }
    final list = _progressPacks.putIfAbsent(_game.id, () => []);
    list.removeWhere((c) => listEqualsPaths(c.files, files) || (replacing != null && listEqualsPaths(c.files, replacing)));
    list.add((title: title, files: files, inQueue: true));
    _progressHidden.remove(pack.id);
    await _saveProgressPacks(_game);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('progress_hidden', _progressHidden.toList());
    return pack.id;
  }

  bool _isManualProgressPack(List<String> files) =>
      (_progressPacks[_game.id] ?? const <ProgressCandidate>[]).any((c) => listEqualsPaths(c.files, files));

  Future<void> _removeProgressPack(List<String> files) async {
    _progressPacks[_game.id]?.removeWhere((c) => listEqualsPaths(c.files, files));
    await _saveProgressPacks(_game);
  }

  /// Строка «Прогресс» в карточке аддона со своим GameData: эмблемы и кнопка
  /// «Открыть в Progress».
  Widget _buildPackProgress(String title, List<String> files) {
    final root = srb2FolderPath;
    if (!_progressEnabled || !_game.hasProgress || root == null || files.isEmpty) return const SizedBox.shrink();
    final key = '$root|${[for (final f in files) '$f|${_mapPreviewKey(f)}'].join('|')}';
    final future = _packProgress.putIfAbsent(key, () async {
      try {
        final base = [...await _gameFiles(_game.paletteFiles), ...await _gameFiles(_game.baseMapFiles)];
        final packs = await ProgressPack.discover(root, base, [(title: title, files: files, inQueue: false)],
            orphans: false, kart: _game.id == 'srb2kart');
        return packs.where((p) => !p.vanilla).firstOrNull;
      } catch (_) {
        return null;
      }
    });
    return FutureBuilder<ProgressPack?>(
      future: future,
      builder: (context, snap) {
        final pack = snap.data;
        if (pack == null) return const SizedBox.shrink();
        return Card(
          margin: const EdgeInsets.only(top: 12),
          child: ListTile(
            leading: Icon(Icons.emoji_events_outlined, color: Theme.of(context).colorScheme.primary),
            title: Text(tr('Progress ({file})', {'file': pack.id})),
            subtitle: Text(!pack.started
                ? tr('Not started yet')
                : pack.emblems > 0
                    ? tr('Emblems: {got}/{all}', {'got': pack.emblemsCollected, 'all': pack.emblems})
                    : tr('Started')),
            trailing: TextButton(
              onPressed: () {
                _setProgressHidden(pack.id, false);
                ProgressTab.selectRequest.value = pack.id;
                setState(() => _currentTab = _progressTab!);
              },
              child: Text(tr('Open in Progress')),
            ),
          ),
        );
      },
    );
  }

  /// Файлы всех подключённых репозиториев по MD5 — вкладка Servers
  /// предлагает скачать из них аддоны сервера, которых у вас нет.
  Map<String, RepoFileRef> _repoFilesByMd5() => {
        for (final mods in _visibleGroups.values)
          for (final mod in mods)
            for (final file in mod.files)
              if (file.md5.isNotEmpty && file.hash.isNotEmpty) file.md5.toLowerCase(): (mod, file),
      };

  /// Окно с предупреждением/ошибкой. true — если нажата кнопка [actionLabel].
  Future<bool> _showProblem({
    required String title,
    required String message,
    String? actionLabel,
    bool error = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(
          error ? Icons.error_outline : Icons.warning_amber_rounded,
          color: error ? Colors.redAccent : Colors.orangeAccent,
          size: 36,
        ),
        title: Text(title),
        content: SizedBox(width: 460, child: SelectableText(message)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(actionLabel == null ? 'OK' : 'Close'),
          ),
          if (actionLabel != null)
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(actionLabel),
            ),
        ],
      ),
    );
    return result == true;
  }

  /// Папка игры задана и существует? Иначе — окно с кнопкой настроек.
  Future<bool> _ensureGameFolder() async {
    if (srb2FolderPath == null) {
      final open = await _showProblem(
        title: tr('Game folder is not set'),
        message: tr('Choose the folder with {file} in Settings first.', {'file': _game.mainFile}),
        actionLabel: tr('Open Settings'),
      );
      if (open && mounted) await _openSettings(SettingsSection.game);
      if (srb2FolderPath == null) return false;
    }
    if (!await Directory(srb2FolderPath!).exists()) {
      if (!mounted) return false;
      final open = await _showProblem(
        title: tr('Game folder not found'),
        message: tr('This folder does not exist:\n{path}\n\nCheck the path in Settings.', {'path': srb2FolderPath}),
        actionLabel: tr('Open Settings'),
      );
      if (open && mounted) await _openSettings(SettingsSection.game);
      return false;
    }
    return true;
  }

  /// Что делать с файлами очереди, которых нет на диске.
  Future<_MissingChoice> _askMissingFiles(List<String> missing) async {
    final choice = await showDialog<_MissingChoice>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent, size: 36),
        title: Text(missing.length == 1 ? 'File not found' : '${missing.length} files not found'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr('These files from the launch queue are missing:')),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final entry in missing)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.insert_drive_file_outlined, size: 20),
                        title: Text(_entryName(entry)),
                        subtitle: SelectableText(_entryPath(entry), style: const TextStyle(fontSize: 11)),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _MissingChoice.cancel),
            child: Text(tr('Cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, _MissingChoice.remove),
            child: Text(tr('Remove from queue')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, _MissingChoice.launch),
            child: Text(tr('Launch without them')),
          ),
        ],
      ),
    );
    return choice ?? _MissingChoice.cancel;
  }

  /// Путь для -file: относительно папки игры, если файл внутри неё. SRB2
  /// (D_IsPathAllowed) сравнивает начало абсолютного пути со своим путём
  /// с учётом регистра, а относительный путь без ".." принимает всегда.
  String _gameRelative(String folder, String path) =>
      p.isWithin(folder, path) ? p.relative(path, from: folder) : path;

  /// Запуск игры. [connectTo] — адрес сервера (вкладка Servers): очередь не
  /// передаётся; [serverFiles] — аддоны сервера в его порядке, они грузятся
  /// через -file до подключения (+connect), и игра сразу принимает их как
  /// уже загруженные.
  Future<void> _launchGame({String? connectTo, List<String>? serverFiles, String? executableId}) =>
      _preparingLaunch(() => _launchGameNow(connectTo: connectTo, serverFiles: serverFiles, executableId: executableId));

  Future<void> _launchGameNow({String? connectTo, List<String>? serverFiles, String? executableId}) async {
    if (!await _ensureGameFolder()) return;
    final folder = srb2FolderPath!;

    final fileArgs = <String>[];
    final launchedFiles = <String>[];
    if (connectTo == null && _activeQueue.isNotEmpty) {
      final present = <String>[];
      final missing = <String>[];
      for (final entry in _activeQueue) {
        final fullPath = _entryPath(entry);
        if (await File(fullPath).exists()) {
          present.add(fullPath);
        } else {
          missing.add(entry);
        }
      }
      if (missing.isNotEmpty) {
        if (!mounted) return;
        final choice = await _askMissingFiles(missing);
        if (choice == _MissingChoice.cancel) return;
        if (choice == _MissingChoice.remove) {
          setState(() => selectedFilesQueue.removeWhere(missing.contains));
          _saveLaunchQueue();
          return;
        }
      }
      launchedFiles.addAll(present);
      // -file — последним: SRB2 считает файлами всё после него до следующего "-".
      if (present.isNotEmpty) fileArgs..add('-file')..addAll(present.map((x) => _gameRelative(folder, x)));
    }
    if (connectTo != null && serverFiles != null && serverFiles.isNotEmpty) {
      fileArgs..add('-file')..addAll(serverFiles.map((x) => _gameRelative(folder, x)));
    }

    // Выбранный экзешник + галочки + доп. параметры (с учётом кавычек).
    final cmdParts = _launch.commandLine(
        connectTo: connectTo, executableId: executableId, skinColor: await _defaultSkinColor());
    final isDefault = (_launch.byId(executableId)?.command ?? _launch.command).trim() ==
        PlatformUtils.defaultLaunchCommand(game: _game);

    final executable = await _resolveExecutable(cmdParts.first, isDefault: isDefault);
    final finalArgs = [...cmdParts.skip(1), ...fileArgs];

    await _startGame(executable, finalArgs, folder,
        connectTo == null ? launchedFiles : (serverFiles ?? const <String>[]));
  }

  /// Играть в левелпак (вкладка Progress): сборка по умолчанию или
  /// выбранная из меню и только файлы пака — без параметров Launch,
  /// очереди, сетевой игры и -warp, чтобы игра сохраняла прогресс как обычно.
  Future<void> _playPack(List<String> files, {String? executableId}) =>
      _preparingLaunch(() => _playDirectNow(files, executableId: executableId));

  Future<void> _playReplay(String playdemoArg, List<String> files, {String? executableId}) =>
      _preparingLaunch(() => _playDirectNow(files, executableId: executableId, playdemoArg: playdemoArg));

  Future<void> _playDirectNow(List<String> files, {String? executableId, String? playdemoArg}) async {
    if (!await _ensureGameFolder()) return;
    final folder = srb2FolderPath!;
    final rawCmd = _launch.byId(executableId)?.command ?? _launch.command;
    var parts = PlatformUtils.splitCommandLine(rawCmd);
    if (parts.isEmpty) parts = [PlatformUtils.defaultLaunchCommand(game: _game)];
    final isDefault = rawCmd.trim() == PlatformUtils.defaultLaunchCommand(game: _game);
    final executable = await _resolveExecutable(parts.first, isDefault: isDefault);
    final args = [
      ...parts.skip(1),
      if (files.isNotEmpty) ...['-file', ...files.map((x) => _gameRelative(folder, x))],
      if (playdemoArg != null) ...['-playdemo', playdemoArg],
    ];
    await _startGame(executable, args, folder, files);
  }

  /// Поиск локальных аддонов для реплея по имени и MD5 в папке игры.
  Future<Map<String, String>> _resolveReplayAddons(List<ReplayAddon> addons) async {
    final folder = srb2FolderPath;
    if (folder == null || addons.isEmpty) return const {};
    final index = await LocalFileIndex.shared(folder);
    final result = <String, String>{};
    for (final addon in addons) {
      if (addon.md5.isEmpty) continue;
      final found = await index.findByName(addon.name, addon.md5);
      if (found != null) result[addon.md5] = found;
    }
    return result;
  }

  /// Поиск отсутствующего аддона реплея в подключённых репозиториях по MD5.
  (ModItem, ModFile)? _findRepoReplayAddon(ReplayAddon addon) {
    if (addon.md5.isEmpty) return null;
    return _repoFilesByMd5()[addon.md5.toLowerCase()];
  }

  /// Запускает игру и показывает ошибку запуска.
  /// [files] — запускаемые аддоны (по ним — какие сохранения проверить).
  Future<void> _startGame(String executable, List<String> finalArgs, String folder, List<String> files) async {
    // Повреждённое сохранение игра не загрузит (и предложит его удалить) —
    // сначала проверка и восстановление.
    await _guardSaves(folder, files);
    if (!mounted) return;
    try {
      showSnack(context, 
        SnackBar(
          content: Text(tr('Launching: {command}',
              {'command': [executable, ...finalArgs].map(PlatformUtils.quoteIfNeeded).join(' ')})),
        ),
      );
      final childEnv = _cleanChildEnvironment();

      // Команда, которой нет ни в папке игры, ни в PATH, но которую знает
      // оболочка (alias srb2legacy=... в ~/.bashrc): запуск через оболочку.
      var exe = executable;
      var args = finalArgs;
      if (!Platform.isWindows && !executable.contains('/') && !PlatformUtils.onPath(executable, childEnv)) {
        final viaShell = await PlatformUtils.shellCommand(executable, childEnv);
        if (viaShell != null) {
          AppLog.console('[launch] "$executable" is not on PATH; starting it through ${viaShell.$1} (alias or function)');
          exe = viaShell.$1;
          args = [...viaShell.$2, ...finalArgs];
        }
      }

      await Process.start(
        exe,
        args,
        mode: ProcessStartMode.detached,
        workingDirectory: folder,
        environment: childEnv,
        includeParentEnvironment: childEnv == null,
      );
    } on ProcessException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      // EACCES на Linux: файл есть, но без флага исполнения; 2 — файл не найден.
      final String hint;
      if (!Platform.isWindows && e.errorCode == 13) {
        hint = tr('The file is not executable. Run:\nchmod +x "{path}"', {'path': executable});
      } else if (e.errorCode == 2) {
        hint = tr('The file was not found. Check the path of the executable.') +
            (Platform.isWindows
                ? ''
                : '\n${tr('A shell alias works only if your shell ({shell}) knows it in a new terminal; otherwise give the full path.', {'shell': Platform.environment['SHELL'] ?? 'sh'})}');
      } else {
        hint = tr('Check the executable on the Launch tab.');
      }
      final selected = _launch.selected;
      final edit = await _showProblem(
        title: tr('Could not start the game'),
        message: '$executable\n\n${e.message.trim()}\n\n$hint',
        actionLabel: selected == null ? null : 'Edit executable',
        error: true,
      );
      if (edit && selected != null && mounted) {
        final updated = await showExecutableDialog(context, initial: selected, initialDirectory: folder);
        if (updated != null) _launch.updateExecutable(updated);
      }
    } catch (e) {
      if (!mounted) return;
      await _showProblem(title: tr('Launch error'), message: '$e', error: true);
    }
  }

  Future<void> _removeRepository(String title) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Remove Repository?')),
        content: Text(tr('Are you sure you want to remove "{name}" from the list?', {'name': title})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('Remove')),
          ),
        ],
      ),
    );

    if (confirm == true) {
      setState(() {
        manifestGroups.remove(title);
        rawManifests.remove(title);
        if (selectedMod != null && selectedMod!.repositorySource == title) {
          selectedMod = null;
        }
      });
      await _saveRepositories();
    }
  }

  StreamSubscription<void>? _antdRestarted;

  /// Картинки аддонов, которых ещё нет, — заново (после перезапуска демона).
  void _retryModImages() {
    for (final mods in manifestGroups.values) {
      for (final mod in mods) {
        if (mod.imageHash.isNotEmpty && !cachedImages.containsKey(mod.imageHash)) _loadModImage(mod.imageHash);
      }
    }
  }

  /// Кнопка в настройках: перезапустить демон Autonomi.
  Future<bool> _restartAutonomi() async {
    final ok = await AntdDaemon.restart(force: true);
    if (mounted) setState(() => daemonReady = ok);
    if (ok) _retryModImages();
    return ok;
  }

  Future<void> _loadModImage(String imageHash) async {
    if (imageHash.isEmpty || cachedImages.containsKey(imageHash)) return;

    // Пока демон не запущен, берём картинку только из кэша на диске.
    final localPath = daemonReady
        ? await AutonomiService.downloadAndGetCachedImage(imageHash)
        : await AutonomiService.cachedImage(imageHash);
    if (localPath != null && mounted) {
      setState(() => cachedImages[imageHash] = localPath);
    }
  }

  Future<void> _saveMd5Cache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'md5_cache',
      jsonEncode(_md5Cache.map((k, v) => MapEntry(k, v.toJson()))),
    );
  }

  Future<void> _rememberMd5(String path, String md5) async {
    try {
      final st = await File(path).stat();
      if (st.type == FileSystemEntityType.notFound) return;
      _md5Cache[path] = _Md5Entry(st.size, st.modified.millisecondsSinceEpoch, md5);
      await _saveMd5Cache();
    } catch (_) {}
  }

  // --- Скачанные аддоны: фильтр, папка, удаление ---

  Future<void>? _refreshing;
  bool _refreshAgain = false;

  /// Пересчитывает, какие аддоны скачаны (быстро: по имени файла, без MD5).
  /// Вызовы во время пересчёта склеиваются: после него — ещё один, не больше.
  Future<void> _refreshDownloaded() {
    final running = _refreshing;
    if (running != null) {
      _refreshAgain = true;
      return running;
    }
    return _refreshing = () async {
      try {
        do {
          _refreshAgain = false;
          await _refreshDownloadedNow();
        } while (_refreshAgain && mounted);
      } finally {
        _refreshing = null;
      }
    }();
  }

  Future<void> _refreshDownloadedNow() async {
    _packProgress.clear(); // строка «Прогресс» в карточках — заново
    final serverAddons = _refreshServerAddons();
    final root = srb2FolderPath;
    final present = <String, Set<String>>{};
    final modFiles =
        root == null ? <String, List<String>>{} : await _downloadedModFiles(_game, root, present: present);
    final keys = modFiles.keys.toSet();
    unawaited(_noticeAddonUpdates(present));
    if (!mounted) return;
    setState(() => _downloadedKeys
      ..clear()
      ..addAll(keys));
    // Что внутри скачанных файлов — для поиска по картам, режимам, персонажам, цветам.
    final contents = await _analyzePaths([for (final l in modFiles.values) ...l]);
    if (!mounted) return;
    setState(() {
      _modContents
        ..clear()
        ..addAll({
          for (final e in modFiles.entries)
            e.key: AddonContents.merge([for (final f in e.value) if (contents[f] case final c?) c]),
        });
    });
    await serverAddons;
  }

  /// Скачанные файлы аддонов репозиториев игры [g] с папкой [root]
  /// (ключ аддона → пути): в папке загрузок или где угодно в папке игры.
  /// Размер файла [path] равен [size] (0 — размер в манифесте не указан).
  static bool _sameSize(String path, int size) {
    if (size <= 0) return true;
    try {
      return File(path).lengthSync() == size;
    } catch (_) {
      return false;
    }
  }

  /// [present] — сюда же: какие файлы каждого аддона найдены ([ModFile.key]),
  /// чтобы понять, какая версия скачана.
  Future<Map<String, List<String>>> _downloadedModFiles(GameDef g, String root,
      {Map<String, Set<String>>? present}) async {
    final downloads = p.joinAll([root, ...g.downloadPath]);
    final index = await LocalFileIndex.shared(root);
    final out = <String, List<String>>{};
    for (final group in manifestGroups.values) {
      for (final m in group) {
        final mod = m.forGame(g.id, orBase: g.addonBase);
        if (mod == null) continue;
        // Скачан, если есть хоть один его файл — с тем же именем и размером:
        // в папке версии или где-то в папке игры. Файл с тем же именем, но
        // другого размера (другой аддон, другая версия, недокачанный файл) —
        // не считается.
        final paths = <String>{};
        for (final f in mod.files) {
          if (f.type != ModFileType.addon) continue;
          var local = AddonPaths.candidates(downloads, mod, f)
              .where((c) => File(c).existsSync() && _sameSize(c, f.size))
              .firstOrNull;
          if (local == null) {
            for (final c in index.byName(f.name)) {
              if (!_sameSize(c, f.size)) continue;
              // Размер в манифесте не указан — сверяем MD5 (он кэшируется).
              if (f.size <= 0 && f.md5.isNotEmpty && await _md5For(c) != f.md5) continue;
              local = c;
              break;
            }
          }
          if (local != null) {
            paths.add(local);
            present?.putIfAbsent(mod.key, () => {}).add(f.key);
          }
        }
        if (paths.isNotEmpty) out[mod.key] = paths.toList();
      }
    }
    return out;
  }

  /// Содержимое файлов (карты, режимы, персонажи, цвета) по путь|размер|время.
  /// Хранится и на диске: при следующем запуске неизменённые аддоны не
  /// открываются заново.
  final Map<String, AddonContents> _pathContents = {};
  final _contentsCache = JsonFileCache('addon_contents_cache.json');
  Future<void>? _contentsCacheLoaded;
  static const _contentsCacheVersion = 3; // 2: у режимов есть TypeOfLevel; 3: карты «папкой» в PK3

  Future<void> _loadContentsCache() => _contentsCacheLoaded ??= () async {
        final j = await _contentsCache.read();
        if (j == null || j['v'] != _contentsCacheVersion) return;
        try {
          for (final e in (j['files'] as Map).entries) {
            _pathContents.putIfAbsent(
                e.key as String, () => AddonContents.fromJson((e.value as Map).cast<String, Object?>()));
          }
        } catch (_) {}
      }();

  void _saveContentsCache() => _contentsCache.write({
        'v': _contentsCacheVersion,
        'files': {for (final e in _pathContents.entries) e.key: e.value.toJson()},
      });

  /// Разбирает [paths], которых ещё нет в кэше; возвращает путь → содержимое.
  Future<Map<String, AddonContents>> _analyzePaths(List<String> paths) async {
    await _loadContentsCache();
    final keyOf = {for (final f in paths) f: '$f|${_mapPreviewKey(f)}'};
    final unknown = [for (final f in paths) if (!_pathContents.containsKey(keyOf[f])) f];
    // Понемногу: между пачками — пауза, если окно свёрнуто.
    for (var i = 0; i < unknown.length; i += 16) {
      await AppActivity.whenVisible();
      final chunk = unknown.sublist(i, math.min(i + 16, unknown.length));
      try {
        final found = await AddonAnalyzer.analyzeAllInBackground(chunk);
        found.forEach((f, c) {
          // Старые версии того же файла из кэша убираем.
          _pathContents.removeWhere((k, _) => k.startsWith('$f|'));
          _pathContents[keyOf[f]!] = c;
        });
      } catch (_) {}
    }
    if (unknown.isNotEmpty) _saveContentsCache();
    return {for (final f in paths) if (_pathContents[keyOf[f]] case final c?) f: c};
  }

  /// Ищет файлы аддонов, которых нет в репозиториях (файл из репозитория —
  /// тот, чей MD5 совпадает с файлом репозитория): в папке загрузок и в
  /// остальной папке игры (если этот раздел показывается). [rescan] — папку
  /// игры обойти заново, даже если её обходили меньше минуты назад.
  Future<void> _refreshServerAddons({bool rescan = false}) async {
    final game = _game;
    final root = srb2FolderPath;
    final downloads = _downloadDir;
    // Скрытые папки (Settings → Game folder): их аддоны не из репозиториев не показываются.
    final hidden = await HiddenAddonFolders.resolved(game, root);
    final found = [
      for (final f in downloads == null ? <String>[] : await _otherDownloads(downloads, fresh: true))
        if (!HiddenAddonFolders.hides(hidden, f)) f,
    ];
    final inFolder = [
      for (final f in root == null || !_showFolderAddons
          ? <String>[]
          : await _folderAddons(game, root, fresh: true, rescan: rescan))
        if (!HiddenAddonFolders.hides(hidden, f)) f,
    ];
    final info = await _analyzePaths([...found, ...inFolder]);
    if (!mounted || game != _game) return;
    setState(() {
      _serverAddonFiles = found;
      _folderAddonFiles = inFolder;
      _serverAddonInfo = info;
      final selected = _selectedLocalFile;
      if (selected != null && !found.contains(selected) && !inFolder.contains(selected)) _selectedLocalFile = null;
    });
    _schedulePlayerRescan();
  }

  /// Недавние результаты [_otherDownloads] по папке — плеер берёт их, а не
  /// обходит папку заново сразу после пересчёта.
  final Map<String, (DateTime, Future<List<String>>)> _otherDownloadsMemo = {};

  /// Файлы аддонов в папке загрузок [downloads], которых нет в репозиториях
  /// (по MD5), по алфавиту. [fresh] — не брать результат минутной давности.
  Future<List<String>> _otherDownloads(String downloads, {bool fresh = false}) {
    final memo = _otherDownloadsMemo[downloads];
    if (!fresh && memo != null && DateTime.now().difference(memo.$1) < const Duration(minutes: 1)) return memo.$2;
    final result = _findOtherDownloads(downloads);
    _otherDownloadsMemo[downloads] = (DateTime.now(), result);
    return result;
  }

  Future<List<String>> _findOtherDownloads(String downloads) async {
    if (!await Directory(downloads).exists()) return [];
    final files = <String>[];
    try {
      await for (final e in Directory(downloads).list(recursive: true, followLinks: false)) {
        if (e is File && PlatformUtils.isAddonFile(e.path)) files.add(e.path);
      }
    } catch (_) {}
    return _notFromRepositories(files);
  }

  /// То же, что [_otherDownloadsMemo], для папок игр.
  final Map<String, (DateTime, Future<List<String>>)> _folderAddonsMemo = {};

  /// Файлы аддонов в папке игры [g] ([root]) вне папки загрузок, которых нет
  /// в репозиториях, по алфавиту. Без файлов самих игр (srb2.pk3, bios.pk3...).
  /// Папка обходится, как это делает игра: на 10 уровней вглубь, без
  /// screenshots, replay и т.п.
  Future<List<String>> _folderAddons(GameDef g, String root, {bool fresh = false, bool rescan = false}) {
    final key = '${g.id}|$root';
    final memo = _folderAddonsMemo[key];
    if (!fresh && memo != null && DateTime.now().difference(memo.$1) < const Duration(minutes: 1)) return memo.$2;
    final result = _findFolderAddons(g, root, rescan: rescan);
    _folderAddonsMemo[key] = (DateTime.now(), result);
    return result;
  }

  Future<List<String>> _findFolderAddons(GameDef g, String root, {bool rescan = false}) async {
    if (!await Directory(root).exists()) return [];
    // Кнопка «Обновить»: список файлов папки — заново, а не минутной давности.
    if (rescan) await LocalFileIndex.shared(root, force: true);
    final downloads = p.joinAll([root, ...g.downloadPath]);
    final own = {for (final game in Games.all) ...game.ownAddonFiles};
    // Файлы аддонов репозиториев, найденные по имени где угодно в папке игры.
    final fromRepos = {for (final l in (await _downloadedModFiles(g, root)).values) ...l};
    final index = await LocalFileIndex.shared(root);
    return _notFromRepositories([
      for (final f in index.paths)
        if (PlatformUtils.isAddonFile(f) &&
            !p.isWithin(downloads, f) &&
            !fromRepos.contains(f) &&
            !own.contains(p.basename(f).toLowerCase()))
          f,
    ]);
  }

  /// Из [files] — те, что не файлы репозиториев, по алфавиту. MD5 считаем
  /// только у совпавших с файлом репозитория по имени или размеру.
  Future<List<String>> _notFromRepositories(List<String> files) async {
    final repoMd5 = <String>{};
    final repoNames = <String>{};
    final repoSizes = <int>{};
    for (final mods in manifestGroups.values) {
      for (final mod in mods) {
        for (final f in mod.files) {
          if (f.md5.isNotEmpty) repoMd5.add(f.md5);
          repoNames.add(f.name.toLowerCase());
          if (f.size > 0) repoSizes.add(f.size);
        }
      }
    }
    final found = <String>[];
    for (final path in files) {
      try {
        final sameName = repoNames.contains(p.basename(path).toLowerCase());
        final sameSize = repoSizes.contains(await File(path).length());
        if (sameName || sameSize) {
          await AppActivity.whenVisible(); // MD5 большого файла — когда окно открыто
          if (repoMd5.contains(await _md5For(path))) continue;
        }
        found.add(path);
      } catch (_) {
        // файл пропал или нет доступа — пропускаем
      }
    }
    if (_md5CacheDirty) {
      _md5CacheDirty = false;
      await _saveMd5Cache();
    }
    found.sort((a, b) => p.basename(a).toLowerCase().compareTo(p.basename(b).toLowerCase()));
    return found;
  }

  Future<AddonContents> _contentsOf(String path) {
    final key = '$path|${_mapPreviewKey(path)}';
    // Уже разобран вместе с другими файлами (список аддонов, поиск).
    final known = _pathContents[key];
    if (known != null) return Future.value(known);
    return _fileContents.putIfAbsent(
      key,
      () => AddonAnalyzer.analyzeAllInBackground([path]).then((m) {
        final c = m[path] ?? const AddonContents();
        _pathContents[key] = c;
        return c;
      }).catchError((_) {
        _fileContents.remove(key); // ошибка — попробуем ещё раз в следующий раз
        return const AddonContents();
      }),
    );
  }

  /// Пустой список репозиториев: подсказка и кнопка добавления.
  Widget _buildNoRepositories() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
        child: Column(
          children: [
            Text(tr('No repositories connected.'), textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              icon: const Icon(Icons.add_link),
              label: Text(tr('Add Repository')),
              onPressed: _openAddManifestDialog,
            ),
          ],
        ),
      );

  static const _categoryOrder = [
    (AddonCategory.characters, 'Characters', Icons.person_outline),
    (AddonCategory.gametypes, 'Custom Gametypes', Icons.sports_esports_outlined),
    (AddonCategory.maps, 'Maps', Icons.map_outlined),
    (AddonCategory.skincolors, 'Custom skincolors', Icons.palette_outlined),
    (AddonCategory.misc, 'Miscellaneous', Icons.category_outlined),
  ];

  /// Разделы аддонов не из репозиториев: «Другие загрузки» (папка загрузок —
  /// с серверов) и «В папке игры» (остальная папка игры).
  List<Widget> _buildServerAddons() => [
        if (_showOtherDownloads)
          _buildLocalAddons('other', tr('Other downloads'), Icons.dns_outlined, _serverAddonFiles),
        if (_showFolderAddons)
          _buildLocalAddons('folder', tr('In the game folder'), Icons.folder_special_outlined, _folderAddonFiles,
              hint: tr('Addon files elsewhere in the game folder (outside {dir}) that are not in your repositories.',
                  {'dir': _game.downloadPath.join('/')})),
      ];

  /// Раздел [group] со списком [all]: файлы по категориям (каждый — в одной,
  /// первой подходящей: персонажи, режимы, карты, цвета, прочее).
  Widget _buildLocalAddons(String group, String title, IconData icon, List<String> all, {String? hint}) {
    final query = _query;
    // У файлов не из репозиториев тегов нет: с тегом в поиске их не видно.
    final files = query.tags.isNotEmpty
        ? const <String>[]
        : [
            for (final f in all)
              if (query.matchesWords(
                  (w) => p.basename(f).toLowerCase().contains(w) || (_serverAddonInfo[f]?.matches(w) ?? false)))
                f,
          ];
    if (files.isEmpty || _favoritesOnly) return const SizedBox.shrink();
    final accent = Theme.of(context).colorScheme.primary;
    return ExpansionTile(
      key: ValueKey('group:$group:$_groupKeySuffix'),
      // Вложенные категории не пересоздаются, пока группа свёрнута.
      maintainState: true,
      initiallyExpanded: _groupExpanded(group),
      onExpansionChanged: (v) => _groupToggled(group, v),
      leading: Icon(icon, color: accent),
      trailing: _groupTrailing(
        group,
        IconButton(
          icon: _refreshingLocal
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.refresh, color: Colors.grey, size: 20),
          tooltip: tr('Refresh: find new and removed files'),
          onPressed: _refreshingLocal ? null : _refreshLocalAddons,
        ),
      ),
      title: hint == null
          ? Text(title, style: const TextStyle(fontWeight: FontWeight.bold))
          : Tooltip(
              message: hint,
              waitDuration: const Duration(milliseconds: 500),
              child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
      subtitle: Text(tr('{n} addon(s)', {'n': files.length})),
      children: [
        for (final (category, label, icon) in _categoryOrder)
          if (files.where((f) => (_serverAddonInfo[f]?.category ?? AddonCategory.misc) == category).toList()
              case final inCategory when inCategory.isNotEmpty)
            ExpansionTile(
              key: ValueKey('group:$group:${category.name}:$_groupKeySuffix'),
              initiallyExpanded: _groupExpanded('$group:${category.name}'),
              onExpansionChanged: (v) => _setGroupExpanded('$group:${category.name}', v),
              leading: Icon(icon, size: 20),
              title: Text('${tr(label)} (${inCategory.length})',
                  style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.secondary)),
              children: [
                for (final f in inCategory)
                  ListTile(
                    dense: true,
                    selected: _selectedLocalFile == f,
                    leading: const Icon(Icons.insert_drive_file_outlined, size: 20),
                    title: Text(p.basename(f), overflow: TextOverflow.ellipsis),
                    subtitle: Text(p.relative(p.dirname(f), from: srb2FolderPath ?? p.dirname(f)),
                        style: const TextStyle(fontSize: 11), overflow: TextOverflow.ellipsis),
                    onTap: () => setState(() {
                      _selectedLocalFile = f;
                      selectedMod = null;
                    }),
                  ),
              ],
            ),
      ],
    );
  }

  /// Карточка файла, скачанного с сервера.
  Widget _buildLocalAddonCard(String path) {
    final entry = _queueEntryFor(path);
    final inQueue = selectedFilesQueue.contains(entry);
    final info = _serverAddonInfo[path];
    int size = 0;
    try {
      size = File(path).lengthSync();
    } catch (_) {}
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: StaticScrollList(
        controller: _cardScroll('local:$path'),
        children: [
          Row(
            children: [
              const Icon(Icons.dns_outlined, size: 48, color: Colors.grey),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.basename(path), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text(tr('Not from your repositories'), style: const TextStyle(color: Colors.grey)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SelectableText(path, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          Text(tr('Size: {size}', {'size': _formatSize(size)}), style: const TextStyle(fontSize: 12, color: Colors.grey)),
          if (info != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(spacing: 6, runSpacing: 6, children: [
                if (info.characters > 0) Chip(label: Text(tr('Characters: {n}', {'n': info.characters}))),
                if (info.gametypes.isNotEmpty) Chip(label: Text(tr('Gametypes: {n}', {'n': info.gametypes.length}))),
                if (info.maps > 0) Chip(label: Text(tr('Maps: {n}', {'n': info.maps}))),
                if (info.skincolors > 0) Chip(label: Text(tr('Skin colors: {n}', {'n': info.skincolors}))),
              ]),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              ElevatedButton.icon(
                icon: Icon(inQueue ? Icons.remove : Icons.add),
                label: Text(inQueue ? tr('In Queue') : tr('Add to Queue')),
                onPressed: () {
                  if (inQueue) {
                    setState(() => selectedFilesQueue.remove(entry));
                    _saveLaunchQueue();
                  } else {
                    _addFileToQueue(entry);
                  }
                },
              ),
              const SizedBox(width: 8),
              fileActionsMenu(
                onSelected: (a) => a == FileAction.showInFolder
                    ? _showInFolder(path)
                    : _deleteFiles([path], title: tr('Delete "{name}"?', {'name': p.basename(path)})),
              ),
            ],
          ),
          _buildFileGametypes(path),
          _buildFileLevels(path),
          _buildFileCharacters(path),
          _buildFileColors(path),
        ],
      ),
    );
  }

  /// Свои цвета персонажей в файле — на спрайте-образце.
  Widget _buildFileColors(String path) {
    return FutureBuilder<AddonContents>(
      future: _contentsOf(path),
      builder: (context, snap) {
        final colors = snap.data?.colors ?? const <SkinColor>[];
        if (colors.isEmpty) return const SizedBox.shrink();
        final current = _launch.options.cvar('color').trim().toLowerCase();
        final accent = Theme.of(context).colorScheme.primary;
        return _contentSection('colors|$path', tr('Skin colors in {file} ({n})', {'file': p.basename(path), 'n': colors.length}), () => [
              Text(
                tr('Click a color to use it (+color). It works only in multiplayer or with +devmode.'),
                style: const TextStyle(fontSize: 12, color: Colors.orangeAccent),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final c in colors)
                    Tooltip(
                      message: tr('Use this color: +color {name}', {'name': c.$1}),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => _chooseColor(c.$1, path),
                        child: Container(
                        width: 96,
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.black26,
                          borderRadius: BorderRadius.circular(8),
                          // Выбранный цвет — рамка цвета темы.
                          border: current == c.$1.toLowerCase()
                              ? Border.all(color: accent, width: 2)
                              : Border.all(color: Colors.grey[800]!),
                        ),
                        child: Column(
                          children: [
                            ColorPreview(c.$2, height: 72),
                            const SizedBox(height: 6),
                            Text(c.$1,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                          ],
                        ),
                      ),
                      ),
                    ),
                ],
              ),
            ]);
      },
    );
  }

  /// Свёрнутые разделы содержимого файлов (режимы, уровни, персонажи,
  /// цвета) — только в памяти, до выхода; сначала все раскрыты.
  final Set<String> _closedContent = {};

  /// Раздел содержимого файла: заголовок со стрелкой (щелчок сворачивает и
  /// разворачивает) и, если раскрыт, [body].
  Widget _contentSection(String id, String title, List<Widget> Function() body) {
    final open = !_closedContent.contains(id);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => setState(() => open ? _closedContent.add(id) : _closedContent.remove(id)),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Icon(open ? Icons.expand_more : Icons.chevron_right, size: 22),
                  const SizedBox(width: 6),
                  Expanded(child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
                ],
              ),
            ),
          ),
          if (open) ...[const SizedBox(height: 8), ...body()],
        ],
      ),
    );
  }

  /// Свои режимы игры в файле (SOC GameType / Lua G_AddGametype).
  Widget _buildFileGametypes(String path) {
    return FutureBuilder<AddonContents>(
      future: _contentsOf(path),
      builder: (context, snap) {
        final types = snap.data?.gametypes ?? const <GametypeInfo>[];
        if (types.isEmpty) return const SizedBox.shrink();
        final current = _launch.options.gametype.trim().toLowerCase();
        return _contentSection('gametypes|$path', tr('Gametypes in {file} ({n})', {'file': p.basename(path), 'n': types.length}), () => [
              for (final g in types)
                Card(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: current == g.name.toLowerCase()
                        ? BorderSide(color: Theme.of(context).colorScheme.primary, width: 2)
                        : BorderSide.none,
                  ),
                  child: ListTile(
                    leading: const Icon(Icons.sports_esports_outlined),
                    title: Text(g.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text([
                      '-gametype ${g.name.contains(' ') ? '"${g.name}"' : g.name}'
                          '${g.identifier.isNotEmpty ? ' · GT_${g.identifier.toUpperCase()}' : ''}',
                      if (g.description.isNotEmpty) g.description,
                    ].join('\n')),
                    onTap: () => _chooseGametype(g.name, path),
                  ),
                ),
            ]);
      },
    );
  }

  /// Аддон убрали из очереди или выключили: свой режим (-gametype),
  /// персонаж (+skin) и карта (-warp), которых больше нет ни в игре, ни во
  /// включённых аддонах очереди, сбрасываются.
  Future<void> _dropOrphanSelections() async {
    final o = _launch.options;
    final gametype = o.gametype.trim();
    final skin = o.cvar('skin').trim().toLowerCase();
    final warp = o.warpMap.trim().toUpperCase();
    final color = o.cvar('color').trim().toLowerCase();
    var dropGametype = false;
    var dropSkin = false;
    var dropWarp = false;
    var dropColor = false;

    if (gametype.isNotEmpty && !_game.gametypes.any((g) => g.toLowerCase() == gametype.toLowerCase())) {
      final custom = await _queueGametypes();
      dropGametype = !custom.any((g) => g.name.toLowerCase() == gametype.toLowerCase());
    }
    if (skin.isNotEmpty) {
      final chars = await _characters();
      // Персонажи игры не нашлись (нет файлов игры) — проверить нельзя.
      dropSkin = chars.isNotEmpty && !chars.any((c) => c.name == skin);
    }
    if (warp.isNotEmpty) {
      final maps = await _warpMaps();
      final name = MapScanner.socLevelMap(warp) ?? warp;
      // Карт игры не нашлось (нет файлов игры) — проверить нельзя.
      dropWarp = maps.isNotEmpty && !maps.any((m) => m.map == name || m.map == warp);
    }
    if (color.isNotEmpty && int.tryParse(color) == null) {
      final colors = await _launchColors();
      dropColor = !colors.any((c) => c.name.toLowerCase() == color);
    }
    if (!mounted || (!dropGametype && !dropSkin && !dropWarp && !dropColor)) return;
    // Пока проверяли, выбор могли поменять — сбрасываем только то же значение.
    final now = _launch.options;
    final resetGametype = dropGametype && now.gametype.trim() == gametype;
    final resetSkin = dropSkin && now.cvar('skin').trim().toLowerCase() == skin;
    final resetWarp = dropWarp && now.warpMap.trim().toUpperCase() == warp;
    final resetColor = dropColor && now.cvar('color').trim().toLowerCase() == color;
    if (!resetGametype && !resetSkin && !resetWarp && !resetColor) return;
    _launch.updateOptions((o) {
      if (resetGametype) o.gametype = '';
      if (resetSkin) o.setCvar('skin', '');
      if (resetColor) o.setCvar('color', '');
      if (resetWarp) o.warpMap = '';
    });
    setState(() {});
    showSnack(
      context,
      SnackBar(
        content: Text([
          if (resetGametype) tr('Gametype {name} is no longer available: -gametype is removed.', {'name': gametype}),
          if (resetSkin) tr('Character {name} is no longer available: +skin is removed.', {'name': skin}),
          if (resetWarp) tr('Map {map} is no longer available: -warp is removed.', {'map': warp}),
          if (resetColor) tr('Color {name} is no longer available: +color is removed.', {'name': color}),
        ].join('\n')),
      ),
    );
  }

  /// Цвет из аддона: файл — в очередь, +color — в параметры. Игра принимает
  /// +color только в сетевой игре или с devmode — об этом и говорим.
  void _chooseColor(String name, String path) {
    _enableInQueue(path);
    // Цвет выбран явно — «Всегда родной цвет» выключается.
    _launch.updateOptions((o) {
      o.setCvar('color', name);
      o.defaultColor = false;
    });
    setState(() {});
    showSnack(
      context,
      SnackBar(
        content: Text(tr('{file} is in the launch queue, +color {color} is set. It works only in multiplayer or with +devmode.',
            {'file': p.basename(path), 'color': name})),
        action: SnackBarAction(label: tr('Launch'), onPressed: () => _launchGame()),
      ),
    );
  }

  /// Цвета для выбора +color на вкладке Launch: игры (кроме служебных и
  /// супер-цветов) и аддонов включённой очереди.
  Future<List<SkinColorChoice>> _launchColors() async {
    final files = [for (final e in _activeQueue) _entryPath(e)].where((f) => File(f).existsSync()).toList();
    final contents = await Future.wait(files.map(_contentsOf));
    return [
      for (final (name, ramp) in _game.launchSkinColors) SkinColorChoice(name, ramp),
      for (final c in contents)
        for (final (name, ramp) in c.colors) SkinColorChoice(name, ramp, custom: true),
    ];
  }

  /// Режим из аддона: файл — в очередь, -gametype — в параметры.
  void _chooseGametype(String name, String path) {
    _enableInQueue(path);
    // Игра применяет -gametype только с -warp или в сетевой игре — иначе
    // стартует обычный Co-op. Поэтому включаем Host (если не Join/Dedicated).
    _launch.updateOptions((o) {
      o.gametype = name;
      if (o.net == NetMode.off) o.net = NetMode.host;
    });
    setState(() {});
    showSnack(
      context,
      SnackBar(
        content: Text(tr('{file} is in the launch queue, -gametype {gametype} is set.',
            {'file': p.basename(path), 'gametype': name})),
        action: SnackBarAction(label: tr('Launch'), onPressed: () => _launchGame()),
      ),
    );
  }

  /// Свои режимы из включённых аддонов очереди (для списка на вкладке Launch).
  Future<List<GametypeInfo>> _queueGametypes() async {
    final files = [for (final e in _activeQueue) _entryPath(e)].where((f) => File(f).existsSync()).toList();
    if (files.isEmpty) return const [];
    final map = await _analyzePaths(files);
    return [for (final f in files) ...?(map[f]?.gametypes)];
  }

  Future<void> _setHideNotDownloaded(bool v) async {
    setState(() => _hideNotDownloaded = v);
    if (v) _refreshDownloaded();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('addons_hide_not_downloaded', v);
  }

  Future<void> _showInFolder(String path) => showFileInFolder(context, path);

  /// Скачанные файлы аддона (все версии): на своих местах и с верным MD5,
  /// чтобы не задеть чужой файл с тем же именем.
  Future<List<String>> _addonLocalFiles(ModItem mod) async {
    final downloads = _downloadDir;
    if (downloads == null) return const [];
    final out = <String>{};
    for (final f in mod.files) {
      final local = _localPaths[f.key];
      if (local != null && fileStatuses[f.key] == 'ok') out.add(local);
      for (final c in AddonPaths.candidates(downloads, mod, f)) {
        if (out.contains(c) || !File(c).existsSync()) continue;
        final md5 = await _md5For(c);
        if (f.md5.isEmpty || md5 == f.md5) out.add(c);
      }
    }
    return out.toList()..sort();
  }

  /// Удаляет файлы (с подтверждением), убирает их из очереди и пустые папки.
  Future<void> _deleteFiles(List<String> paths, {required String title}) async {
    if (paths.isEmpty) return;
    final ok = await confirmDeleteFiles(context, paths, title);
    if (ok != true || !mounted) return;
    final failed = <String>[];
    final downloads = _downloadDir;
    for (final path in paths) {
      try {
        await File(path).delete();
        // Пустые папки версии/аддона внутри DOWNLOAD — тоже.
        var dir = Directory(p.dirname(path));
        while (downloads != null && p.isWithin(downloads, dir.path) && await dir.list().isEmpty) {
          await dir.delete();
          dir = dir.parent;
        }
      } catch (_) {
        if (await File(path).exists()) failed.add(path);
      }
    }
    final removed = {for (final path in paths) if (!failed.contains(path)) _queueEntryFor(path)};
    setState(() {
      selectedFilesQueue.removeWhere(removed.contains);
      _disabledQueue.removeAll(removed);
    });
    _saveLaunchQueue();
    if (srb2FolderPath != null) await LocalFileIndex.shared(srb2FolderPath!, force: true);
    if (selectedMod != null) _checkModFilesStatus(selectedMod!);
    _refreshDownloaded();
    if (!mounted) return;
    showSnack(context, SnackBar(
      content: Text(failed.isEmpty
          ? tr('Deleted {n} file(s)', {'n': paths.length})
          : tr('Could not delete:\n{files}', {'files': failed.join('\n')})),
      backgroundColor: failed.isEmpty ? null : Colors.red,
    ));
  }

  Future<void> _deleteAddon(ModItem mod) async {
    final files = await _addonLocalFiles(mod);
    if (!mounted) return;
    if (files.isEmpty) {
      showSnack(context, SnackBar(content: Text(tr('No downloaded files of this addon.'))));
      return;
    }
    await _deleteFiles(files, title: tr('Delete addon "{name}"?', {'name': mod.name}));
  }

  // --- Избранные аддоны ---

  void _toggleFavorite(ModItem mod) {
    setState(() {
      if (!_favoriteAddons.remove(mod.key)) _favoriteAddons.add(mod.key);
    });
    SharedPreferences.getInstance()
        .then((prefs) => prefs.setStringList('addon_favorites', _favoriteAddons.toList()));
  }

  Widget _favoriteButton(ModItem mod, {double size = 20}) {
    final fav = _favoriteAddons.contains(mod.key);
    return IconButton(
      icon: Icon(fav ? Icons.star : Icons.star_border, size: size, color: fav ? Colors.amber : Colors.grey),
      tooltip: fav ? tr('Remove from favorites') : tr('Add to favorites'),
      visualDensity: VisualDensity.compact,
      onPressed: () => _toggleFavorite(mod),
    );
  }

  // --- Версии аддонов ---

  /// Выбранная версия; если не выбирали — скачанная (самая новая из скачанных),
  /// иначе последняя.
  AddonVersion? _selectedVersion(ModItem mod) =>
      mod.versionNamed(_selectedVersions[mod.key]) ?? _installedVersion(mod) ?? mod.latest;

  /// Все файлы версии уже лежат в DOWNLOAD (быстрая проверка без MD5).
  bool _isVersionDownloaded(ModItem mod, AddonVersion v) {
    final downloads = _downloadDir;
    if (downloads == null || v.files.isEmpty) return false;
    return v.files.every((f) => File(AddonPaths.target(downloads, mod, f)).existsSync());
  }

  AddonVersion? _installedVersion(ModItem mod) {
    if (!mod.hasSeveralVersions) return null;
    for (final v in mod.versions) {
      if (_isVersionDownloaded(mod, v)) return v;
    }
    return null;
  }

  Future<void> _saveSelectedVersions() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('addon_versions', jsonEncode(_selectedVersions));
  }

  Future<void> _changeVersion(ModItem mod, String versionName) async {
    setState(() {
      _selectedVersions[mod.key] = versionName;
      fileStatuses = {};
      localMd5Cache = {};
      _localPaths = {};
    });
    _saveSelectedVersions();
    await _checkModFilesStatus(mod);
    if (mounted) _syncQueueToVersion(mod);
  }

  /// Очередь следует за выбранной версией: файлы других версий этого аддона
  /// заменяются файлами выбранной — если все они уже скачаны.
  void _syncQueueToVersion(ModItem mod) {
    final version = _selectedVersion(mod);
    final downloads = _downloadDir;
    if (version == null || downloads == null) return;

    final addonFiles = <String>{
      for (final f in mod.files)
        if (f.type == ModFileType.addon)
          for (final c in AddonPaths.candidates(downloads, mod, f)) p.canonicalize(c),
    };
    final positions = [
      for (var i = 0; i < selectedFilesQueue.length; i++)
        if (addonFiles.contains(p.canonicalize(_entryPath(selectedFilesQueue[i])))) i,
    ];
    if (positions.isEmpty) return;

    final addonFilesOfVersion = version.files.where((f) => f.type == ModFileType.addon).toList();
    final wanted = [
      for (final f in addonFilesOfVersion)
        if (fileStatuses[f.key] == 'ok' && _localPaths[f.key] != null) _queueEntryFor(_localPaths[f.key]!),
    ];
    if (wanted.length != addonFilesOfVersion.length) return; // версия скачана не полностью

    final current = [for (final i in positions) selectedFilesQueue[i]];
    if (current.length == wanted.length &&
        Iterable.generate(current.length).every((i) => current[i] == wanted[i])) {
      return;
    }

    setState(() {
      for (final i in positions.reversed) {
        selectedFilesQueue.removeAt(i);
      }
      final at = positions.first < selectedFilesQueue.length ? positions.first : selectedFilesQueue.length;
      selectedFilesQueue.insertAll(at, wanted.where((e) => !selectedFilesQueue.contains(e)));
    });
    _saveLaunchQueue();
    showSnack(context, 
      SnackBar(content: Text(tr('Launch queue now uses {name} {version}', {'name': mod.name, 'version': tr(version.label)}))),
    );
  }

  /// MD5 файла с кэшем по размеру и времени изменения; null — файла нет.
  Future<String?> _md5For(String path, {bool force = false}) async {
    final st = await File(path).stat();
    if (st.type != FileSystemEntityType.file) return null;
    final mtime = st.modified.millisecondsSinceEpoch;
    final cached = _md5Cache[path];
    if (!force && cached != null && cached.size == st.size && cached.mtime == mtime) {
      return cached.md5.toLowerCase();
    }
    final md5 = (await AutonomiService.calculateFileMd5(path))?.toLowerCase();
    if (md5 == null) return null;
    _md5Cache[path] = _Md5Entry(st.size, mtime, md5);
    _md5CacheDirty = true;
    return md5;
  }

  /// Проверяет файлы выбранной версии: в папке версии и в корне DOWNLOAD.
  /// Статусы: ok, outdated (в папке версии лежит другой файл), other
  /// (в корне DOWNLOAD файл с тем же именем, но другой версии), missing.
  Future<String> _modelsDownloadDir() async =>
      p.join((await AppPaths.modelsDir()).path, _game.id);

  /// Импортирует скачанный архив [path] в библиотеку наборов моделей игры; null — успех,
  /// иначе текст ошибки.
  Future<String?> _importModelsFromFile(ModItem mod, ModFile file, String path) async {
    if (_game.models == null) {
      return tr('{game}: 3D models are not supported', {'game': _game.name});
    }
    try {
      final lib = await ModelLibrary.load(_game);
      final name = '${mod.name} ${file.version}'.trim();
      if (!lib.packs.any((p) => p.sourceKey == file.key || p.name == name)) {
        await lib.add(path, name: name, sourceKey: file.key);
      }
      return null;
    } catch (e) {
      AppLog.console('Failed to import models from $path: $e');
      return '$e';
    }
  }

  Future<void> _checkModFilesStatus(ModItem mod, {bool force = false}) async {
    final version = _selectedVersion(mod);
    if (version == null) return;

    final token = ++_checkToken;
    final downloadDir = _downloadDir;
    final hasModels = version.files.any((f) => f.type == ModFileType.models);
    final modelsDir = hasModels ? await _modelsDownloadDir() : null;
    ModelLibrary? modelsLib;
    if (hasModels && _game.models != null) {
      try {
        modelsLib = await ModelLibrary.load(_game);
      } catch (_) {}
    }
    if (!mounted || token != _checkToken) return;

    final statuses = {for (final f in version.files) f.key: 'checking'};
    final md5s = <String, String>{};
    final paths = <String, String>{};
    final conflicts = <String, String>{};

    void publish() {
      setState(() {
        fileStatuses = Map.of(statuses);
        localMd5Cache = Map.of(md5s);
        _localPaths = Map.of(paths);
        _conflictPaths = Map.of(conflicts);
      });
    }

    publish();

    for (final file in version.files) {
      if (file.type.isBuild) {
        var status = 'missing';
        final savedExe = _installedBuildExes[file.key];
        if (savedExe != null && File(savedExe).existsSync()) {
          status = 'installed';
          paths[file.key] = savedExe;
        } else {
          final buildsDir = await AppPaths.buildsDir();
          final folderName = '${PlatformUtils.safeFileName(mod.name) ?? mod.id}_${PlatformUtils.safeFileName(file.version) ?? 'build'}';
          final buildDir = Directory(p.join(buildsDir.path, folderName));
          String? foundExe;
          if (await buildDir.exists()) {
            final found = await LaunchSettings.findExecutables(buildDir.path, hints: [_game.id, 'srb2', 'ringracers']);
            foundExe = found.where((e) => e.likelySrb2).firstOrNull?.path ?? found.firstOrNull?.path;
          }
          if (foundExe != null && File(foundExe).existsSync()) {
            _installedBuildExes[file.key] = foundExe;
            status = 'installed';
            paths[file.key] = foundExe;
          }
        }
        statuses[file.key] = status;
        publish();
        continue;
      }

      if (file.type == ModFileType.models) {
        final candidates = AddonPaths.candidates(modelsDir!, mod, file);
        var status = 'missing';
        final packName = '${mod.name} ${file.version}'.trim();
        final imported = modelsLib == null ||
            modelsLib.packs.any((p) => p.sourceKey == file.key || p.name == packName);
        for (final c in candidates) {
          final md5 = await _md5For(c, force: force);
          if (!mounted || token != _checkToken) return;
          if (md5 == null) continue;
          if (file.md5.isEmpty || md5 == file.md5) {
            md5s[file.key] = md5;
            paths[file.key] = c;
            if (imported) status = 'ok';
            break;
          }
        }
        statuses[file.key] = status;
        publish();
        continue;
      }

      if (downloadDir == null) {
        statuses[file.key] = 'missing';
        publish();
        continue;
      }

      final candidates = AddonPaths.candidates(downloadDir, mod, file);
      var status = 'missing';
      for (var i = 0; i < candidates.length; i++) {
        final md5 = await _md5For(candidates[i], force: force);
        if (!mounted || token != _checkToken) return;
        if (md5 == null) continue;
        if (file.md5.isEmpty || md5 == file.md5) {
          status = 'ok';
          md5s[file.key] = md5;
          paths[file.key] = candidates[i];
          break;
        }
        if (i == 0) {
          status = 'outdated';
          md5s[file.key] = md5;
          conflicts[file.key] = candidates[i];
        } else if (status == 'missing') {
          status = 'other';
          md5s[file.key] = md5;
          conflicts[file.key] = candidates[i];
        }
      }
      // Нет на своём месте — ищем по всей папке игры (addons/ и любые
      // подпапки, кроме screenshots, replay и т.п.): игра тоже находит файл
      // по имени и MD5 где угодно в папке.
      if (status != 'ok' && file.md5.isNotEmpty) {
        final index = await LocalFileIndex.shared(srb2FolderPath!, force: force);
        if (!mounted || token != _checkToken) return;
        final found = await index.findByName(file.name, file.md5);
        if (!mounted || token != _checkToken) return;
        if (found != null) {
          status = 'ok';
          md5s[file.key] = file.md5;
          paths[file.key] = found;
          conflicts.remove(file.key);
        }
      }
      statuses[file.key] = status;
      publish();
    }
    if (_md5CacheDirty) {
      _md5CacheDirty = false;
      await _saveMd5Cache();
    }
  }

  /// На месте скачиваемого файла лежит другой: заменить, сохранить оба или отменить.
  Future<_ReplaceChoice> _askReplace(String path, ModFile file, String? existingMd5) async {
    final choice = await showDialog<_ReplaceChoice>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent, size: 36),
        title: Text(tr('A different file is already there')),
        content: SizedBox(
          width: 500,
          child: SelectableText(
            '$path\n\n${tr('Its MD5 ({found}) does not match {what} ({expected}). It may be damaged or changed by hand.', {
              'found': existingMd5 ?? '?',
              'what': file.version.isEmpty ? tr('this file') : tr('version {version}', {'version': file.version}),
              'expected': file.md5,
            })}\n\n'
            '${tr('Replace — overwrite it with the downloaded file.')}\n'
            '${tr('Keep both — keep it and save the new file next to it in a subfolder (the game finds the right one by MD5).')}\n'
            '${tr('Rename old / Move old — keep the old file under another name or in another folder.')}',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, _ReplaceChoice.cancel), child: Text(tr('Cancel'))),
          TextButton(onPressed: () => Navigator.pop(context, _ReplaceChoice.rename), child: Text(tr('Rename old...'))),
          TextButton(onPressed: () => Navigator.pop(context, _ReplaceChoice.move), child: Text(tr('Move old...'))),
          TextButton(onPressed: () => Navigator.pop(context, _ReplaceChoice.keepBoth), child: Text(tr('Keep both'))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(context, _ReplaceChoice.replace),
            child: Text(tr('Replace')),
          ),
        ],
      ),
    );
    return choice ?? _ReplaceChoice.cancel;
  }

  /// Переименовывает файл (в той же папке). Возвращает новый путь или null.
  Future<String?> _renameFile(String path) async {
    final ext = p.extension(path);
    final controller = TextEditingController(text: '${p.basenameWithoutExtension(path)} (old)$ext');
    String? error;
    final name = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          void submit() {
            final safe = PlatformUtils.safeFileName(controller.text);
            if (safe == null || safe == p.basename(path)) {
              setDialogState(() => error = tr('Enter a different file name'));
              return;
            }
            if (File(p.join(p.dirname(path), safe)).existsSync()) {
              setDialogState(() => error = tr('A file with this name already exists'));
              return;
            }
            Navigator.pop(context, safe);
          }

          return AlertDialog(
            title: Text(tr('Rename old file')),
            content: SizedBox(
              width: 440,
              child: TextField(
                controller: controller,
                autofocus: true,
                onSubmitted: (_) => submit(),
                decoration: InputDecoration(
                  labelText: tr('New name'),
                  helperText: tr('In {folder}', {'folder': p.dirname(path)}),
                  errorText: error,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
              ElevatedButton(onPressed: submit, child: Text(tr('Rename'))),
            ],
          );
        },
      ),
    );
    if (name == null) return null;
    final target = p.join(p.dirname(path), name);
    try {
      await File(path).rename(target);
      _md5Cache.remove(path);
      return target;
    } on FileSystemException catch (e) {
      if (mounted) await _showProblem(title: tr('Cannot rename'), message: '${e.osError?.message ?? e.message}', error: true);
      return null;
    }
  }

  /// Перемещает файл в выбранную папку (между дисками — копированием).
  /// Возвращает новый путь или null.
  Future<String?> _moveFile(String path) async {
    AppLog.action('open the getDirectoryPath dialog (main.dart)');
    final dir = await getDirectoryPath(
      initialDirectory: srb2FolderPath,
      confirmButtonText: tr('Move here'),
    );
    if (dir == null) return null;
    var target = p.join(dir, p.basename(path));
    for (var i = 2; await File(target).exists(); i++) {
      target = p.join(dir, '${p.basenameWithoutExtension(path)} ($i)${p.extension(path)}');
    }
    try {
      try {
        await File(path).rename(target);
      } on FileSystemException {
        await File(path).copy(target); // другой диск
        await File(path).delete();
      }
      _md5Cache.remove(path);
      return target;
    } on FileSystemException catch (e) {
      if (mounted) await _showProblem(title: tr('Cannot move'), message: '${e.osError?.message ?? e.message}', error: true);
      return null;
    }
  }

  /// Файл не совпал по MD5: заменить, удалить, переименовать или переместить старый.
  Future<void> _resolveConflict(ModItem mod, ModFile file, _ConflictAction action) async {
    final path = _conflictPaths[file.key];
    if (path == null) return;
    switch (action) {
      case _ConflictAction.replace:
        // Старый файл не в папке версии (другая версия в корне DOWNLOAD) — убираем его.
        if (!PlatformUtils.samePath(path, AddonPaths.target(_downloadDir!, mod, file))) {
          try {
            await File(path).delete();
            _md5Cache.remove(path);
          } on FileSystemException catch (_) {}
        }
        await _downloadModFile(mod, file, overwrite: true);
        return;
      case _ConflictAction.delete:
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(tr('Delete old file?')),
            content: Text(path),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
                onPressed: () => Navigator.pop(context, true),
                child: Text(tr('Delete')),
              ),
            ],
          ),
        );
        if (ok != true) return;
        try {
          await File(path).delete();
          _md5Cache.remove(path);
        } on FileSystemException catch (e) {
          if (mounted) await _showProblem(title: tr('Cannot delete'), message: '${e.osError?.message ?? e.message}', error: true);
        }
      case _ConflictAction.rename:
        await _renameFile(path);
      case _ConflictAction.move:
        await _moveFile(path);
    }
    if (mounted && selectedMod != null) await _checkModFilesStatus(selectedMod!);
  }

  /// [pointer]/[intro] — из pointer.txt при первом запуске.
  Future<void> _openAddManifestDialog({String? pointer, String? intro}) async {
    final Map<String, dynamic>? result = await showDialog(
      context: context,
      builder: (context) => AddManifestDialog(
        autoHideTags: _autoHideTags,
        onAutoHideTagsChanged: _setAutoHideTags,
        initialPointer: pointer,
        intro: intro,
      ),
    );

    if (result == null) return;
    try {
      await _addRepository(result['title']!, result['value']!, pointer: result['pointer'] as String?);
    } catch (e) {
      if (mounted) {
        showSnack(context,
          SnackBar(content: Text(tr('JSON parsing error: {error}', {'error': e})), backgroundColor: Colors.red),
        );
      }
    }
  }

  /// Подключает (или обновляет) репозиторий [title] из JSON [jsonContent];
  /// [pointer] — если он взят по pointer. [quiet] — без сообщения (фоновое
  /// обновление). Ошибка разбора JSON — исключение.
  /// Теги, которые репозиторий советует скрыть (`hide_tags`): если включено
  /// «Автоматически добавлять…», те, которых нет в скрытых, добавляются —
  /// при подключении и обновлении репозитория и при включении настройки.
  Future<void> _offerHideTags(String repository, String json) async {
    if (!_autoHideTags) return;
    List<String> recommended;
    try {
      final list = (jsonDecode(json) as Map)['hide_tags'];
      recommended = list is List ? [for (final t in list) if (t is String) normalizeTag(t)] : const [];
    } catch (_) {
      return;
    }
    final hidden = blacklistedTags.toSet();
    final fresh = [
      for (final t in recommended.toSet())
        if (t.isNotEmpty && !hidden.contains(t)) t,
    ];
    if (fresh.isEmpty || !mounted) return;
    await _addHiddenTags(fresh);
    if (mounted) {
      showSnack(context, SnackBar(content: Text(tr('Hidden tags added from "{name}": {tags}',
          {'name': repository, 'tags': fresh.join(', ')}))));
    }
  }

  /// Одна настройка для Settings → Addons и окна «Подключить репозиторий».
  Future<void> _setAutoHideTags(bool v) async {
    setState(() => _autoHideTags = v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_hide_recommended_tags', v);
    // Включили — сразу добавить то, что советуют подключённые репозитории.
    if (v) {
      for (final e in Map.of(rawManifests).entries) {
        await _offerHideTags(e.key, e.value);
      }
    }
  }

  Future<void> _addHiddenTags(List<String> tags) async {
    final current = blacklistedTagsString.trim();
    setState(() => blacklistedTagsString = [if (current.isNotEmpty) current, ...tags].join(', '));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('blacklisted_tags', blacklistedTagsString);
  }

  /// Уведомления «у скачанного аддона вышла новая версия» — по одному разу
  /// на версию (что уже сообщено — в настройках). [present] — найденные файлы
  /// аддонов текущей игры ([_downloadedModFiles]).
  Future<void> _noticeAddonUpdates(Map<String, Set<String>> present) async {
    if (present.isEmpty) return;
    const key = 'addon_updates_noticed';
    final prefs = await SharedPreferences.getInstance();
    final seen = List.of(prefs.getStringList(key) ?? const <String>[]);
    final known = seen.toSet();
    final fresh = <String>[];
    for (final group in manifestGroups.values) {
      for (final m in group) {
        final mod = m.forGame(_game.id, orBase: _game.addonBase);
        final files = mod == null ? null : present[mod.key];
        if (mod == null || files == null) continue;
        final u = AddonUpdates.update(mod, files);
        if (u == null) continue;
        final id = '${mod.key}\u0000${u.$2.name}';
        if (!known.add(id)) continue;
        fresh.add(id);
        Notices.instance.add(Notice(
          NoticeKind.info,
          tr('Addon update'),
          tr('{addon} ({repository}): version {latest} is out, you have {installed}.', {
            'addon': mod.name,
            'repository': mod.repositorySource,
            'latest': u.$2.label,
            'installed': u.$1.label,
          }),
        ));
      }
    }
    if (fresh.isEmpty) return;
    seen.addAll(fresh);
    if (seen.length > 2000) seen.removeRange(0, seen.length - 2000);
    await prefs.setStringList(key, seen);
  }

  /// Уведомление «репозиторий обновился»: что в нём нового.
  void _noticeRepositoryUpdate(String title, List<ModItem> before, List<ModItem> after) {
    final d = AddonUpdates.diff(before, after);
    String names(List<ModItem> list) =>
        list.length <= 5 ? list.map((m) => m.name).join(', ') : '${list.take(5).map((m) => m.name).join(', ')}…';
    final parts = [
      if (d.added.isNotEmpty) tr('new addons ({n}): {names}', {'n': d.added.length, 'names': names(d.added)}),
      if (d.updated.isNotEmpty) tr('new versions ({n}): {names}', {'n': d.updated.length, 'names': names(d.updated)}),
    ];
    Notices.instance.add(Notice(
      NoticeKind.success,
      tr('Repository updated'),
      parts.isEmpty
          ? tr('{name}: the addon list has changed.', {'name': title})
          : '$title: ${parts.join('; ')}.',
    ));
  }

  Future<void> _addRepository(String title, String jsonContent, {String? pointer, bool quiet = false}) async {
    final parsedMods = ManifestService.parseMainIndex(jsonContent, sourceName: title);
    // Тот же репозиторий с другим содержимым — обновление: сообщить, что нового.
    final before = manifestGroups[title];
    if (before != null && rawManifests[title] != jsonContent) _noticeRepositoryUpdate(title, before, parsedMods);
    setState(() {
      manifestGroups[title] = parsedMods;
      rawManifests[title] = jsonContent;
      if (pointer != null) {
        _repoPointers[title] = pointer;
        _pointerManualOnly.remove(title);
      } else if (_repoPointers.containsKey(title)) {
        // Тот же репозиторий обновили из файла: pointer не теряем (на нём
        // выйдут свежие версии), но сам он больше не применяется.
        _pointerManualOnly.add(title);
      }
      _refreshDownloaded();
    });
    await _saveRepositories();
    unawaited(_offerHideTags(title, jsonContent));
    for (final mod in parsedMods) {
      if (mod.imageHash.isNotEmpty) _loadModImage(mod.imageHash);
    }
    if (mounted && !quiet) {
      showSnack(context,
        SnackBar(
          content: Text(tr('Repository "{name}" connected successfully ({n} addons)!', {'name': title, 'n': parsedMods.length})),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  String _formatProgress(int done, int total) {
    const units = ['B', 'KiB', 'MiB', 'GiB'];
    var t = total.toDouble();
    var d = done.toDouble();
    var i = 0;
    while (t >= 1024 && i < units.length - 1) {
      t /= 1024;
      d /= 1024;
      i++;
    }
    final f = i == 0 ? 0 : 1;
    return '${d.toStringAsFixed(f)} / ${t.toStringAsFixed(f)} ${units[i]}';
  }

  String _formatSize(int bytes) {
    if (bytes <= 0) return '—';
    const units = ['B', 'KiB', 'MiB', 'GiB'];
    double v = bytes.toDouble();
    int i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
  }

  Future<bool> _promptAndInstallBuild(ModItem mod, ModFile file) async {
    final pending = _repoQueue.where((d) => d.file.key == file.key).firstOrNull ??
        (_repoCurrent?.file.key == file.key ? _repoCurrent : null);
    if (pending != null) return pending.done.future;

    final buildsDir = await AppPaths.buildsDir();
    if (!mounted) return false;
    final folderName = '${PlatformUtils.safeFileName(mod.name) ?? mod.id}_${PlatformUtils.safeFileName(file.version) ?? 'build'}';
    final defaultTarget = p.join(buildsDir.path, folderName);

    final pathCtrl = TextEditingController(text: defaultTarget);
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          title: Text(tr('Install custom build')),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr('Custom game build: {name} ({version})', {
                  'name': mod.name,
                  'version': file.version.isEmpty ? file.name : file.version,
                })),
                const SizedBox(height: 16),
                TextField(
                  controller: pathCtrl,
                  decoration: InputDecoration(
                    labelText: tr('Installation folder'),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.folder_open),
                      tooltip: tr('Select folder'),
                      onPressed: () async {
                        final chosen = await getDirectoryPath(initialDirectory: pathCtrl.text);
                        if (chosen != null) {
                          setDlgState(() => pathCtrl.text = chosen);
                        }
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(tr('Cancel')),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(tr('Install')),
            ),
          ],
        ),
      ),
    );

    if (proceed != true || !mounted) return false;
    final targetFolder = pathCtrl.text.trim();
    if (targetFolder.isEmpty) return false;

    final targetDir = Directory(targetFolder);
    try {
      await targetDir.create(recursive: true);
    } catch (e) {
      if (mounted) {
        await _showProblem(
          title: tr('Cannot write to folder'),
          message: '$e',
          error: true,
        );
      }
      return false;
    }

    final fullOutputPath = p.join(targetFolder, file.name);

    late final _RepoDownload job;
    final item = DownloadCenter.instance.start(file.name, '${mod.repositorySource} — ${mod.name}',
        queued: true, cancel: () => _cancelQueued(job))
      ..source = tr('your repository');
    job = _RepoDownload(mod, file, fullOutputPath, item);
    if (mounted) setState(() => _repoQueue.add(job));
    unawaited(_pumpRepoQueue());
    return job.done.future;
  }

  /// Скачивает файл версии аддона из Autonomi в `DOWNLOAD/<аддон>/<версия>/`.
  /// Если там уже лежит другой файл — спрашивает, что делать (сразу, при
  /// нажатии). Файлы качаются по одному: пока идёт другое скачивание, этот
  /// встаёт в очередь (видно в «Скачиваниях», можно убрать); не скачался —
  /// очередь идёт дальше. true — файл скачан (или уже был) и MD5 совпал.
  Future<bool> _downloadModFile(ModItem mod, ModFile file, {bool overwrite = false}) async {
    if (file.type.isBuild) {
      return _promptAndInstallBuild(mod, file);
    }
    // Уже качается или ждёт — тот же результат, второй раз не ставим.
    final pending = _repoQueue.where((d) => d.file.key == file.key).firstOrNull ??
        (_repoCurrent?.file.key == file.key ? _repoCurrent : null);
    if (pending != null) return pending.done.future;

    final isModels = file.type == ModFileType.models;
    if (!isModels && (!mounted || !await _ensureGameFolder())) return false;
    final targetRoot = isModels ? await _modelsDownloadDir() : _downloadDir!;

    var fullOutputPath = AddonPaths.target(targetRoot, mod, file);
    if (!overwrite && await File(fullOutputPath).exists()) {
      final existing = await _md5For(fullOutputPath);
      if (existing != null && (file.md5.isEmpty || existing == file.md5)) {
        if (isModels) {
          final importError = await _importModelsFromFile(mod, file, fullOutputPath);
          await _checkModFilesStatus(mod);
          if (mounted) {
            showSnack(
              context,
              SnackBar(
                content: Text(importError == null
                    ? tr('Models for "{name}" imported!', {'name': mod.name})
                    : tr('Failed to import models: {error}', {'error': importError})),
                backgroundColor: importError == null ? Colors.green : Colors.red,
              ),
            );
          }
          return importError == null;
        }
        await _checkModFilesStatus(mod);
        return true; // уже скачан
      }
      if (!mounted) return false;
      final choice = await _askReplace(fullOutputPath, file, existing);
      switch (choice) {
        case _ReplaceChoice.cancel:
          return false;
        case _ReplaceChoice.keepBoth:
          final sub = file.md5.length >= 8 ? file.md5.substring(0, 8) : 'new';
          fullOutputPath = p.join(p.dirname(fullOutputPath), sub, file.name);
        case _ReplaceChoice.rename:
          if (await _renameFile(fullOutputPath) == null) return false;
        case _ReplaceChoice.move:
          if (await _moveFile(fullOutputPath) == null) return false;
        case _ReplaceChoice.replace:
          break;
      }
    }

    final downloadDir = Directory(p.dirname(fullOutputPath));
    try {
      await downloadDir.create(recursive: true);
    } on FileSystemException catch (e) {
      // Например, папка недоступна для записи.
      if (mounted) {
        await _showProblem(
          title: isModels ? tr('Cannot write to folder') : tr('Cannot write to the game folder'),
          message: tr('Could not create\n{path}\n\n{error}\n\nChoose a game folder you have write access to.', {'path': downloadDir.path, 'error': e.osError?.message ?? e.message}),
          error: true,
        );
      }
      return false;
    }

    // В общий список скачиваний (кнопка в заголовке окна) — пока в очереди.
    late final _RepoDownload job;
    final item = DownloadCenter.instance.start(file.name, '${mod.repositorySource} — ${mod.name}',
        queued: true, cancel: () => _cancelQueued(job))
      ..source = tr('your repository');
    job = _RepoDownload(mod, file, fullOutputPath, item);
    if (mounted) setState(() => _repoQueue.add(job));
    unawaited(_pumpRepoQueue());
    return job.done.future;
  }

  /// Скачивания аддонов репозиториев, ждущие очереди (по порядку нажатия).
  final List<_RepoDownload> _repoQueue = [];

  /// Скачивание, которое идёт сейчас (null — ничего).
  _RepoDownload? _repoCurrent;

  bool _isRepoQueued(ModFile file) => _repoQueue.any((d) => d.file.key == file.key);

  /// Убирает ждущее скачивание из очереди.
  void _cancelQueued(_RepoDownload job) {
    if (!_repoQueue.remove(job)) return;
    DownloadCenter.instance.finish(job.item, DownloadState.cancelled);
    if (!job.done.isCompleted) job.done.complete(false);
    if (mounted) setState(() {});
  }

  /// Качает очередь по одному файлу; ошибка одного не останавливает остальные.
  Future<void> _pumpRepoQueue() async {
    if (_repoCurrent != null) return;
    while (_repoQueue.isNotEmpty) {
      final job = _repoQueue.removeAt(0);
      _repoCurrent = job;
      var success = false;
      try {
        if (!await AntdDaemon.ensureRunning()) {
          // Без antd не скачается ни один файл очереди — сообщаем один раз.
          final rest = [job, ..._repoQueue];
          _repoQueue.clear();
          for (final j in rest) {
            DownloadCenter.instance.finish(j.item, DownloadState.failed, error: tr('Autonomi is not running'));
            if (!j.done.isCompleted) j.done.complete(false);
          }
          _repoCurrent = null;
          if (mounted) {
            setState(() {});
            await _showProblem(
              title: tr('Autonomi is not running'),
              message: tr('The antd daemon could not be started, so files cannot be downloaded. '
                  'See the console for details.'),
              error: true,
            );
          }
          return;
        }
        success = await _runRepoDownload(job);
      } catch (e, st) {
        AppLog.write('Download ${job.file.name} failed: $e\n$st');
        DownloadCenter.instance.finish(job.item, DownloadState.failed,
            error: tr('Error downloading {name}.', {'name': job.file.name}));
      } finally {
        _repoCurrent = null;
        if (!job.done.isCompleted) job.done.complete(success);
        // После исключения файл не должен остаться «качающимся».
        if (mounted && downloadingFileKey == job.file.key) setState(() => downloadingFileKey = null);
      }
    }
  }

  Future<bool> _runRepoDownload(_RepoDownload job) async {
    final mod = job.mod;
    final file = job.file;
    final fileName = file.name;
    final fullOutputPath = job.path;
    final item = job.item;
    DownloadCenter.instance.begin(item);
    if (mounted) {
      setState(() {
        downloadingFileKey = file.key;
        downloadProgress = 0.0;
        downloadedBytes = 0;
        downloadStage = 'downloading';
        chunksDone = 0;
        chunksTotal = 0;
      });
    }

    final success = await AutonomiService.downloadFile(
      hash: file.hash,
      outputFilePath: fullOutputPath,
      expectedMd5: file.md5,
      expectedSize: file.size,
      onStage: (stage) {
        DownloadCenter.instance.update(item, stage: stage);
        if (mounted) setState(() => downloadStage = stage);
      },
      onChunks: (done, total) {
        DownloadCenter.instance.update(item, chunksDone: done, chunksTotal: total);
        if (mounted) {
          setState(() {
            chunksDone = done;
            chunksTotal = total;
          });
        }
      },
      onProgress: (progress, downloaded, total) {
        DownloadCenter.instance.update(item, progress: progress);
        if (mounted) {
          setState(() {
            downloadProgress = progress;
            downloadedBytes = downloaded;
          });
        }
      },
    );
    DownloadCenter.instance.finish(item, success ? DownloadState.done : DownloadState.failed,
        error: success ? null : tr('Error downloading {name}.', {'name': fileName}));

    if (!mounted) return success;
    setState(() {
      downloadingFileKey = null;
      downloadProgress = 0.0;
      downloadedBytes = 0;
      chunksDone = 0;
      chunksTotal = 0;
    });

    if (success && file.md5.isNotEmpty) {
      await _rememberMd5(fullOutputPath, file.md5);
    }

    var overallSuccess = success;
    String? importError;
    if (overallSuccess && file.type == ModFileType.models) {
      importError = await _importModelsFromFile(mod, file, fullOutputPath);
      if (importError != null) overallSuccess = false;
    } else if (overallSuccess && file.type.isBuild) {
      try {
        final installDir = Directory(p.dirname(fullOutputPath));
        String? exePath;
        if (file.name.toLowerCase().endsWith('.zip')) {
          final archive = AddonArchive.open(fullOutputPath);
          if (archive != null) {
            await archive.extractTo(installDir.path);
            archive.close();
            try {
              await File(fullOutputPath).delete();
            } catch (_) {}
          }
          final found = await LaunchSettings.findExecutables(installDir.path, hints: [_game.id, 'srb2', 'ringracers']);
          exePath = found.where((e) => e.likelySrb2).firstOrNull?.path ?? found.firstOrNull?.path;
        } else {
          exePath = fullOutputPath;
        }
        if (exePath != null) {
          if (!Platform.isWindows) {
            await Process.run('chmod', ['755', exePath]);
          }
          final name = '${mod.name} ${file.version}'.trim();
          final launchExe = LaunchExecutable(id: LaunchExecutable.newId(), name: name, command: exePath);
          _launch.addExecutable(launchExe, select: true);
          _installedBuildExes[file.key] = exePath;
          await _saveInstalledBuilds();
        }
      } catch (e) {
        AppLog.console('Failed to install build from $fullOutputPath: $e');
      }
    }

    if (overallSuccess && selectedMod != null) {
      await _checkModFilesStatus(selectedMod!);
      // Очередь переходит на скачанную выбранную версию.
      if (mounted && identical(selectedMod, mod)) _syncQueueToVersion(mod);
    }

    if (mounted) {
      final successMsg = file.type.isBuild
          ? tr('Build "{name}" installed and selected for launch!', {'name': '${mod.name} ${file.version}'.trim()})
          : (file.type == ModFileType.models
              ? tr('Models for "{name}" imported!', {'name': mod.name})
              : tr('File {name} successfully downloaded!', {'name': fileName}));
      final errorMsg = importError != null
          ? tr('Failed to import models: {error}', {'error': importError})
          : tr('Error downloading {name}.', {'name': fileName});
      showSnack(context, 
        SnackBar(
          content: Text(overallSuccess ? successMsg : errorMsg),
          backgroundColor: overallSuccess ? Colors.green : Colors.red,
        ),
      );
    }
    if (overallSuccess && file.type == ModFileType.addon) _refreshDownloaded();
    return overallSuccess;
  }

  Widget _tabButton(BuildContext context, int index, String label) {
    final active = _currentTab == index;
    return SizedBox(
      height: 32,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: active
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          foregroundColor: active
              ? Theme.of(context).colorScheme.onPrimary
              : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.75),
          elevation: 0,
          minimumSize: const Size(64, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Theme.of(context).extension<LauncherExtras>()?.radius ?? 6)),
        ),
        onPressed: () {
          setState(() => _currentTab = index);
          // С вкладки Servers могли скачать аддоны.
          if (index == 0) _refreshServerAddons();
        },
        child: Text(label),
      ),
    );
  }

  Widget _animatedTabSlot({required bool visible, required Widget child}) {
    return ClipRect(
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(end: visible ? 1.0 : 0.0),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        builder: (context, t, body) => Align(
          alignment: Alignment.centerLeft,
          widthFactor: t,
          child: Opacity(opacity: t.clamp(0.0, 1.0), child: body),
        ),
        child: IgnorePointer(
          ignoring: !visible,
          child: ExcludeFocus(excluding: !visible, child: child),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // Вместо заголовка — переключатель игры.
        title: _buildGameSwitcher(),
        actions: [
          Builder(
            builder: (context) {
              final labels = _tabLabels;
              final hasExtra = labels.length > 3;
              bool isTabVisible(int i) {
                if (_extraTabsExpanded || i < 2) return true;
                if (_currentTab >= 3) return i == _currentTab;
                return i == 2;
              }

              return TapRegion(
                enabled: _extraTabsExpanded,
                onTapOutside: (_) {
                  if (_extraTabsExpanded && mounted) {
                    setState(() => _extraTabsExpanded = false);
                  }
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < labels.length; i++)
                      if (i == 0)
                        _tabButton(context, 0, labels[0])
                      else if (i == 1) ...[
                        const SizedBox(width: 6),
                        _tabButton(context, 1, labels[1]),
                      ] else
                        _animatedTabSlot(
                          visible: isTabVisible(i),
                          child: Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: _tabButton(context, i, labels[i]),
                          ),
                        ),
                    if (hasExtra)
                      _animatedTabSlot(
                        visible: !_extraTabsExpanded,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: Tooltip(
                            message: tr('Show extra tabs'),
                            child: SizedBox(
                              height: 32,
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                                  foregroundColor: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.75),
                                  elevation: 0,
                                  minimumSize: const Size(34, 32),
                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  padding: const EdgeInsets.symmetric(horizontal: 10),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(
                                          Theme.of(context).extension<LauncherExtras>()?.radius ?? 6)),
                                ),
                                onPressed: () => setState(() => _extraTabsExpanded = true),
                                child: const Icon(Icons.add, size: 18),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(width: 16),
          // Уведомления, все скачивания (с серверов и из репозиториев),
          // настройки; «Добавить репозиторий» — на вкладке Addons над поиском.
          const NotificationsButton(),
          const DownloadsButton(),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: tr('Settings & Theme'),
            onPressed: () => _openSettings(),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _withMiniPlayer(
          _currentTab == _replaysTab
          ? ReplaysTab(
              key: ValueKey('replays:${_game.id}:$srb2FolderPath'),
              game: _game,
              gameFolder: srb2FolderPath,
              launch: _launch,
              gameFiles: _gameFiles,
              resolveLocalAddons: _resolveReplayAddons,
              findRepoAddon: _findRepoReplayAddon,
              onDownloadAddon: (mod, file) async {
                final ok = await _downloadModFile(mod, file);
                if (ok && srb2FolderPath != null) {
                  await LocalFileIndex.shared(srb2FolderPath!, force: true);
                }
                return ok;
              },
              onPlay: _playReplay,
            )
          : _currentTab == _progressTab && _game.id == 'drrr'
          ? RingProgressTab(
              key: ValueKey('progress:drrr:$_savesVersion'),
              game: _game,
              gameFolder: srb2FolderPath,
              gameFiles: _gameFiles,
              characters: _characters,
              launch: _launch,
              onPlay: _playPack,
              onBackups: SaveGuard.enabled ? _openSaveBackups : null,
            )
          : _currentTab == _progressTab
          ? ProgressTab(
              key: ValueKey('progress:${_game.id}:$_savesVersion'),
              game: _game,
              gameFolder: srb2FolderPath,
              gameFiles: _gameFiles,
              candidates: _progressCandidates,
              hidden: _progressHidden,
              onHide: (id) => _setProgressHidden(id, true),
              launch: _launch,
              onPlay: _playPack,
              onAddPack: _addProgressPack,
              onEditPack: (pack, files) => _storeProgressPack(pack.title, files, replacing: pack.files),
              isManual: _isManualProgressPack,
              onRemovePack: _removeProgressPack,
              onBackups: SaveGuard.enabled ? _openSaveBackups : null,
            )
          : _currentTab == _playerTab
          ? PlayerTab(
              key: const ValueKey('player'),
              player: _player,
              sourceFiles: _musicSources,
              onWarp: _warpFromPlayer,
            )
          : _currentTab == 1
          ? _buildLaunchQueueView()
          : _currentTab == 2
          ? ServersTab(
              key: ValueKey(_game.id),
              store: _servers,
              gameFolder: srb2FolderPath,
              repoFiles: _repoFilesByMd5(),
              launch: _launch,
              onJoin: (address, files, executableId) =>
                  _launchGame(connectTo: address, serverFiles: files, executableId: executableId),
              onOpenSettings: () => _openSettings(SettingsSection.servers),
            )
          : Row(
              children: [
                SizedBox(
                  width: 320,
                  child: Column(
                    children: [
                      // «Добавить репозиторий» — над поиском, на всю ширину панели;
                      // справа — проверить репозитории по pointer сейчас.
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                        child: Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                icon: const Icon(Icons.add_link, size: 18),
                                label: Text(tr('Add Repository')),
                                onPressed: _openAddManifestDialog,
                              ),
                            ),
                            const SizedBox(width: 4),
                            IconButton.outlined(
                              tooltip: _repoPointers.isEmpty
                                  ? tr('No repositories connected by pointer to update')
                                  : tr('Update repositories: check their pointers for new files now'),
                              icon: _checkingRepositories
                                  ? const SizedBox(
                                      width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                  : const Icon(Icons.sync, size: 20),
                              onPressed:
                                  _repoPointers.isEmpty || _checkingRepositories ? null : _updateRepositoriesNow,
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                        child: Row(
                          children: [
                            Expanded(child: _buildSearchField()),
                          ],
                        ),
                      ),
                      // Фильтры и свернуть/развернуть — отдельной строкой: поиску — вся ширина.
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 2, 4, 2),
                        child: Row(
                          children: [
                            IconButton(
                              icon: Icon(_favoritesOnly ? Icons.star : Icons.star_border,
                                  color: _favoritesOnly ? Colors.amber : null),
                              tooltip: _favoritesOnly ? tr('Show all addons') : tr('Show only favorites'),
                              isSelected: _favoritesOnly,
                              visualDensity: VisualDensity.compact,
                              onPressed: () => setState(() => _favoritesOnly = !_favoritesOnly),
                            ),
                            IconButton(
                              icon: Icon(_hideNotDownloaded ? Icons.download_done : Icons.cloud_download_outlined,
                                  color: _hideNotDownloaded ? Colors.green : null),
                              tooltip: _hideNotDownloaded ? tr('Show all addons') : tr('Hide addons that are not downloaded'),
                              isSelected: _hideNotDownloaded,
                              visualDensity: VisualDensity.compact,
                              onPressed: () => _setHideNotDownloaded(!_hideNotDownloaded),
                            ),
                            IconButton(
                              icon: Icon(Icons.sell_outlined,
                                  color: _query.tags.isNotEmpty || _query.excludedTags.isNotEmpty
                                      ? Theme.of(context).colorScheme.primary
                                      : null),
                              tooltip: _showTagPanel ? tr('Hide the tag list') : tr('All tags'),
                              isSelected: _showTagPanel,
                              visualDensity: VisualDensity.compact,
                              onPressed: () => setState(() => _showTagPanel = !_showTagPanel),
                            ),
                            const Spacer(),
                            IconButton(
                              icon: const Icon(Icons.unfold_more),
                              tooltip: tr('Expand all'),
                              visualDensity: VisualDensity.compact,
                              onPressed: () => _setAllGroupsExpanded(true),
                            ),
                            IconButton(
                              icon: const Icon(Icons.unfold_less),
                              tooltip: tr('Collapse all'),
                              visualDensity: VisualDensity.compact,
                              onPressed: () => _setAllGroupsExpanded(false),
                            ),
                          ],
                        ),
                      ),
                      if (_showTagPanel) _buildTagPanel(),
                      Expanded(
                        // Весь список строится сразу (не лениво, как ListView): его
                        // высота известна заранее — полоса прокрутки не прыгает, а
                        // группы не пересоздаются при прокрутке.
                        child: SingleChildScrollView(
                                // Положение прокрутки сохраняется при смене вкладок.
                                controller: _addonsListScroll,
                                child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (manifestGroups.isEmpty) _buildNoRepositories(),
                                  ..._visibleGroups.entries.map((entry) {
                                  final query = _query;
                                  final sourceName = entry.key;
                                  final modsInGroup = entry.value;

                                  // Умная фильтрация с учетом тегов, поиска и черного списка
                                  final filteredMods = modsInGroup.where((mod) {
                                    if (_favoritesOnly && !_favoriteAddons.contains(mod.key)) return false;
                                    if (_hideNotDownloaded && !_downloadedKeys.contains(mod.key)) return false;

                                    // 1. Проверка глобального черного списка тегов (тег
                                    // как в файле или с группой: hidden / main:hidden).
                                    if (mod.tags.any((tag) =>
                                        blacklistedTags.contains(normalizeTag(tag)) ||
                                        blacklistedTags.contains(_tagGrouping.qualified(tag)))) {
                                      return false;
                                    }

                                    if (query.isEmpty) return true;
                                    // группа:тег / -группа:тег — только по тегам (точно); слова и
                                    // -слова — по названию, категории, автору и содержимому.
                                    if (!query.matchesTags(mod.tags.map(_tagGrouping.qualified))) return false;
                                    bool inAddon(String w) =>
                                        mod.name.toLowerCase().contains(w) ||
                                        mod.uploader.toLowerCase().contains(w) ||
                                        // Карты, режимы, персонажи и цвета скачанных файлов.
                                        (_modContents[mod.key]?.matches(w) ?? false);
                                    // Категория — только для «слово»: «-maps» не прячет
                                    // категорию Maps целиком.
                                    return query.matchesWords(
                                        (w) => inAddon(w) || mod.category.toLowerCase().contains(w),
                                        excluded: inAddon);
                                  }).toList();

                                  if (filteredMods.isEmpty && (_searchQuery.isNotEmpty || _favoritesOnly)) {
                                    return const SizedBox.shrink();
                                  }

                                  // Аддоны уже отсортированы при разборе манифеста,
                                  // здесь сортируем категории (Other — в конце).
                                  final Map<String, List<ModItem>> categorized = {};
                                  for (var mod in filteredMods) {
                                    categorized.putIfAbsent(mod.category, () => []).add(mod);
                                  }
                                  final categoryNames = categorized.keys.toList()
                                    ..sort(ModItem.compareCategories);

                                  return ExpansionTile(
                                    key: ValueKey('group:repo:$sourceName:$_groupKeySuffix'),
      // Вложенные категории не пересоздаются, пока группа свёрнута.
      maintainState: true,
                                    initiallyExpanded: _groupExpanded('repo:$sourceName'),
                                    onExpansionChanged: (v) => _groupToggled('repo:$sourceName', v),
                                    leading: Icon(Icons.source, color: Theme.of(context).colorScheme.primary),
                                    title: Text(sourceName, style: const TextStyle(fontWeight: FontWeight.bold)),
                                    subtitle: Text.rich(TextSpan(children: [
                                      TextSpan(
                                          text: modsInGroup.isEmpty && (manifestGroups[sourceName]?.isNotEmpty ?? false)
                                              ? tr('No addons for {game}', {'game': _game.name})
                                              : tr('{n} addon(s)', {'n': filteredMods.length})),
                                      // Обновлён из файла: pointer — только кнопкой.
                                      if (_pointerManualOnly.contains(sourceName))
                                        WidgetSpan(
                                          alignment: PlaceholderAlignment.middle,
                                          child: Tooltip(
                                            message: tr('Updated from a file: its pointer is not applied on start, so '
                                                'the file is kept. The update button next to Add Repository updates it '
                                                'from the pointer.'),
                                            child: Padding(
                                              padding: const EdgeInsets.only(left: 6),
                                              child: Icon(Icons.sync_disabled, size: 14, color: Colors.orange.shade300),
                                            ),
                                          ),
                                        ),
                                    ])),
                                    trailing: _groupTrailing(
                                      'repo:$sourceName',
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          // Обновить этот репозиторий по его pointer: по
                                          // настройке и только если таких репозиториев
                                          // несколько (иначе это та же кнопка, что сверху).
                                          if (_repoUpdateButtons &&
                                              _repoPointers.length > 1 &&
                                              _repoPointers.containsKey(sourceName))
                                            IconButton(
                                              icon: _checkingRepository == sourceName
                                                  ? const SizedBox(
                                                      width: 16,
                                                      height: 16,
                                                      child: CircularProgressIndicator(strokeWidth: 2))
                                                  : const Icon(Icons.sync, color: Colors.grey, size: 20),
                                              tooltip: tr('Update this repository from its pointer'),
                                              onPressed: _checkingRepositories || _checkingRepository != null
                                                  ? null
                                                  : () => _updateRepositoriesNow(only: sourceName),
                                            ),
                                          IconButton(
                                            icon: const Icon(Icons.delete_outline, color: Colors.grey, size: 20),
                                            tooltip: tr('Remove Repository'),
                                            onPressed: () => _removeRepository(sourceName),
                                          ),
                                        ],
                                      ),
                                    ),
                                    children: categoryNames.map((categoryName) {
                                      final modsList = categorized[categoryName]!;

                                      return ExpansionTile(
                                        key: ValueKey('group:repo:$sourceName:$categoryName:$_groupKeySuffix'),
                                        initiallyExpanded: _groupExpanded('repo:$sourceName:$categoryName'),
                                        onExpansionChanged: (v) =>
                                            _setGroupExpanded('repo:$sourceName:$categoryName', v),
                                        leading: const Icon(Icons.folder_outlined, size: 20),
                                        title: Text('$categoryName (${modsList.length})',
                                            style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.secondary)),
                                        children: modsList.map((mod) {
                                          final isSelected = selectedMod?.id == mod.id;

                                          Widget leadingWidget;
                                          if (mod.imageHash.isNotEmpty && cachedImages.containsKey(mod.imageHash)) {
                                            leadingWidget = AddonIcon(
                                              cachedImages[mod.imageHash]!,
                                              size: 48,
                                              animate: _iconAnimation == AddonIconAnimation.all ||
                                                  (_iconAnimation == AddonIconAnimation.selected && isSelected),
                                            );
                                          } else {
                                            leadingWidget = const SizedBox(
                                              width: 48,
                                              height: 48,
                                              child: Icon(Icons.extension_outlined, size: 28),
                                            );
                                          }

                                          return ListTile(
                                            contentPadding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
                                            selected: isSelected,
                                            leading: leadingWidget,
                                            title: Text(mod.name, style: const TextStyle(fontWeight: FontWeight.w500)),
                                            subtitle: mod.uploader.isEmpty
                                                ? null
                                                : Text(tr('Uploader: {name}', {'name': mod.uploader})),
                                            trailing: _favoriteAddons.contains(mod.key)
                                                ? const Icon(Icons.star, size: 18, color: Colors.amber)
                                                : null,
                                            onTap: () {
                                              setState(() {
                                                selectedMod = mod;
                                                _selectedLocalFile = null;
                                                _tagsExpanded = false;
                                                fileStatuses = {};
                                                localMd5Cache = {};
                                                _localPaths = {};
                                              });
                                              _checkModFilesStatus(mod);
                                              if (mod.imageHash.isNotEmpty) {
                                                _loadModImage(mod.imageHash);
                                              }
                                            },
                                          );
                                        }).toList(),
                                      );
                                    }).toList(),
                                  );
                                }),
                                  ..._buildServerAddons(),
                                ],
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: _selectedLocalFile != null
                      ? _buildLocalAddonCard(_selectedLocalFile!)
                      : selectedMod == null
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.extension, size: 64, color: Colors.grey),
                              SizedBox(height: 16),
                              Text(tr('Select an addon from the list on the left')),
                            ],
                          ),
                        )
                      : Padding(
                          padding: const EdgeInsets.all(24.0),
                          child: StaticScrollList(
                            // Своё положение прокрутки у каждого аддона.
                            controller: _cardScroll('mod:${selectedMod!.key}'),
                            children: [
                              Row(
                                children: [
                                  if (selectedMod!.imageHash.isNotEmpty && cachedImages.containsKey(selectedMod!.imageHash))
                                    Padding(
                                      padding: const EdgeInsets.only(right: 20.0),
                                      child: AddonIcon(
                                        cachedImages[selectedMod!.imageHash]!,
                                        size: 80,
                                        radius: 10,
                                        animate: _iconAnimation != AddonIconAnimation.none,
                                      ),
                                    ),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Chip(
                                              avatar: const Icon(Icons.source, size: 16),
                                              label: Text(selectedMod!.repositorySource),
                                            ),
                                            const SizedBox(width: 8),
                                            Chip(
                                              backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                                              label: Text(tr('Category: {name}', {'name': selectedMod!.category})),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        Row(
                                          children: [
                                            Flexible(
                                              child: Text(
                                                selectedMod!.name,
                                                style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                                              ),
                                            ),
                                            _favoriteButton(selectedMod!, size: 26),
                                            IconButton(
                                              icon: const Icon(Icons.delete_sweep_outlined, size: 24),
                                              tooltip: tr('Delete downloaded files of this addon'),
                                              visualDensity: VisualDensity.compact,
                                              onPressed: () => _deleteAddon(selectedMod!),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              // Кто загрузил, теги и описание — выбранной версии (в
                              // репозитории они могут быть свои у каждой версии).
                              Text(
                                tr('Uploader: {name}',
                                    {'name': selectedMod!.uploaderFor(_selectedVersion(selectedMod!)?.name)}),
                                style: const TextStyle(color: Colors.grey),
                              ),
                              const SizedBox(height: 8),
                              _buildVersionSelector(selectedMod!),
                              // Теги аддона (длинный список сворачивается)
                              if (selectedMod!.tagsFor(_selectedVersion(selectedMod!)?.name).isNotEmpty) ...[
                                const SizedBox(height: 12),
                                _buildTagChips(selectedMod!.tagsFor(_selectedVersion(selectedMod!)?.name)),
                              ],
                              const SizedBox(height: 16),
                              Text(
                                selectedMod!.descriptionFor(_selectedVersion(selectedMod!)?.name),
                                style: const TextStyle(fontSize: 16),
                              ),
                              _buildChangelog(selectedMod!),
                              const SizedBox(height: 24),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    tr('Addon files & MD5 check in {dir}:', {'dir': _game.downloadPath.join('/')}),
                                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                                  ),
                                  if (srb2FolderPath != null)
                                    TextButton.icon(
                                      icon: const Icon(Icons.refresh, size: 16),
                                      label: Text(tr('Recheck files')),
                                      onPressed: () => _checkModFilesStatus(selectedMod!, force: true),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              if (srb2FolderPath == null)
                                Card(
                                  color: Colors.amber[700],
                                  child: Padding(
                                    padding: const EdgeInsets.all(12.0),
                                    child: Row(
                                      children: [
                                        const Icon(Icons.warning, color: Colors.black),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            tr('{game} folder is not set. Please configure it in Settings.', {'game': _game.name}),
                                            style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
                                          ),
                                        ),
                                        TextButton(
                                          onPressed: () => _openSettings(SettingsSection.game),
                                          child: Text(tr('Open Settings'), style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ...(_selectedVersion(selectedMod!)?.files ?? const <ModFile>[]).map((file) {
                                final status = fileStatuses[file.key] ??
                                    (srb2FolderPath == null ? 'missing' : 'checking');
                                final localMd5 = localMd5Cache[file.key];
                                final isThisFileDownloading = downloadingFileKey == file.key;
                                final localPath = _localPaths[file.key];
                                final queueEntry = status == 'ok' && localPath != null ? _queueEntryFor(localPath) : null;
                                final isInQueue = queueEntry != null && selectedFilesQueue.contains(queueEntry);

                                Color statusColor;
                                String statusText;
                                IconData statusIcon;

                                if (file.type.isBuild) {
                                  if (status == 'installed') {
                                    statusColor = Colors.green;
                                    statusText = tr('Custom build installed and ready to launch');
                                    statusIcon = Icons.sports_esports;
                                  } else {
                                    statusColor = Colors.grey;
                                    statusText = tr('Custom game build: not installed yet');
                                    statusIcon = Icons.download_for_offline_outlined;
                                  }
                                } else if (file.type == ModFileType.models) {
                                  if (status == 'ok') {
                                    statusColor = Colors.green;
                                    statusText = tr('3D model pack imported');
                                    statusIcon = Icons.view_in_ar;
                                  } else {
                                    statusColor = Colors.grey;
                                    statusText = tr('3D model pack: not downloaded yet');
                                    statusIcon = Icons.view_in_ar_outlined;
                                  }
                                } else if (status == 'ok') {
                                  statusColor = Colors.green;
                                  statusText = tr('File is up to date (MD5 matches)');
                                  statusIcon = Icons.check_circle;
                                } else if (status == 'checking') {
                                  statusColor = Colors.orangeAccent;
                                  statusText = tr('Checking MD5...');
                                  statusIcon = Icons.hourglass_empty;
                                } else if (status == 'outdated') {
                                  statusColor = Colors.redAccent;
                                  statusText = tr('MD5 mismatch: the file in the version folder is damaged or changed.');
                                  statusIcon = Icons.warning_amber_rounded;
                                } else if (status == 'other') {
                                  statusColor = Colors.orangeAccent;
                                  statusText = tr('Not downloaded. {dir} has a file with this name, but a different version.', {'dir': _game.downloadPath.join('/')});
                                  statusIcon = Icons.difference_outlined;
                                } else {
                                  statusColor = Colors.grey;
                                  statusText = tr('Not in the game folder: no file with this name and MD5 in {dir} or other folders', {'dir': _game.downloadPath.join('/')});
                                  statusIcon = Icons.help_outline;
                                }

                                Widget trailingWidget;
                                if (isThisFileDownloading) {
                                  final isVerifying = downloadStage == 'verifying';
                                  final total = file.size;

                                  String infoText;
                                  if (isVerifying) {
                                    infoText = _formatSize(total > 0 ? total : downloadedBytes);
                                  } else if (chunksTotal > 0) {
                                    infoText = '$chunksDone/$chunksTotal chunks';
                                  } else if (downloadedBytes > 0) {
                                    infoText = total > 0
                                        ? _formatProgress(downloadedBytes, total)
                                        : _formatSize(downloadedBytes);
                                  } else {
                                    infoText = total > 0 ? _formatSize(total) : '';
                                  }

                                  double? barValue;
                                  if (!isVerifying) {
                                    if (chunksTotal > 0) {
                                      barValue = (chunksDone / chunksTotal).clamp(0.0, 0.99).toDouble();
                                    } else if (downloadProgress > 0) {
                                      barValue = downloadProgress;
                                    }
                                  }

                                  trailingWidget = SizedBox(
                                    width: 260,
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            Text(
                                              isVerifying ? tr('Verifying MD5...') : tr('Downloading...'),
                                              style: const TextStyle(fontSize: 12, color: Colors.orangeAccent, fontWeight: FontWeight.bold),
                                            ),
                                            if (infoText.isNotEmpty)
                                              Flexible(
                                                child: Padding(
                                                  padding: const EdgeInsets.only(left: 8),
                                                  child: Text(
                                                    infoText,
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                    textAlign: TextAlign.end,
                                                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                        const SizedBox(height: 6),
                                        LinearProgressIndicator(
                                          value: barValue,
                                          minHeight: 6,
                                          borderRadius: BorderRadius.circular(3),
                                        ),
                                      ],
                                    ),
                                  );
                                } else if (status == 'checking') {
                                  trailingWidget = const SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: CircularProgressIndicator(strokeWidth: 2.5),
                                  );
                                } else if (file.type.isBuild) {
                                  if (status == 'installed' && localPath != null) {
                                    final isSelected = _launch.selected?.command != null && p.equals(_launch.selected!.command, localPath);
                                    trailingWidget = Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Chip(
                                          avatar: const Icon(Icons.check, color: Colors.green, size: 16),
                                          label: Text(tr('Installed'), style: const TextStyle(color: Colors.green)),
                                          backgroundColor: Colors.transparent,
                                        ),
                                        const SizedBox(width: 8),
                                        ElevatedButton.icon(
                                          icon: Icon(isSelected ? Icons.check : Icons.play_arrow),
                                          label: Text(isSelected ? tr('Selected') : tr('Select for launch')),
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: isSelected ? Colors.green.withValues(alpha: 0.2) : Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                                            foregroundColor: isSelected ? Colors.green : Theme.of(context).colorScheme.primary,
                                            elevation: 0,
                                            side: BorderSide(color: isSelected ? Colors.green : Theme.of(context).colorScheme.primary, width: 1),
                                          ),
                                          onPressed: () {
                                            final exe = _launch.executables.where((e) => p.equals(e.command, localPath)).firstOrNull;
                                            if (exe != null) {
                                              _launch.select(exe.id);
                                              setState(() {});
                                            }
                                          },
                                        ),
                                        fileActionsMenu(
                                          onSelected: (a) async {
                                            if (a == FileAction.showInFolder) {
                                              _showInFolder(localPath);
                                            } else if (a == FileAction.delete) {
                                              final exe = _launch.executables.where((e) => p.equals(e.command, localPath)).firstOrNull;
                                              if (exe != null) _launch.removeExecutable(exe.id);
                                              _installedBuildExes.remove(file.key);
                                              await _saveInstalledBuilds();
                                              if (mounted) setState(() {});
                                            }
                                          },
                                        ),
                                      ],
                                    );
                                  } else {
                                    trailingWidget = ElevatedButton.icon(
                                      icon: const Icon(Icons.download),
                                      label: Text(tr('Install build')),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                                        foregroundColor: Theme.of(context).colorScheme.primary,
                                        elevation: 0,
                                        side: BorderSide(color: Theme.of(context).colorScheme.primary, width: 1),
                                      ),
                                      onPressed: () => _promptAndInstallBuild(selectedMod!, file),
                                    );
                                  }
                                } else if (file.type == ModFileType.models) {
                                  if (status == 'ok') {
                                    trailingWidget = Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Chip(
                                          avatar: const Icon(Icons.check, color: Colors.green, size: 16),
                                          label: Text(tr('Models imported'), style: const TextStyle(color: Colors.green)),
                                          backgroundColor: Colors.transparent,
                                        ),
                                        const SizedBox(width: 8),
                                        ElevatedButton.icon(
                                          icon: const Icon(Icons.view_in_ar),
                                          label: Text(tr('Open Models')),
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                                            foregroundColor: Theme.of(context).colorScheme.primary,
                                            elevation: 0,
                                            side: BorderSide(color: Theme.of(context).colorScheme.primary, width: 1),
                                          ),
                                          onPressed: () => _openSettings(SettingsSection.models),
                                        ),
                                        if (localPath != null)
                                          fileActionsMenu(
                                            onSelected: (a) => a == FileAction.showInFolder
                                                ? _showInFolder(localPath)
                                                : _deleteFiles([localPath], title: tr('Delete "{name}"?', {'name': file.name})),
                                          ),
                                      ],
                                    );
                                  } else {
                                    trailingWidget = ElevatedButton.icon(
                                      icon: const Icon(Icons.download),
                                      label: Text(tr('Download models')),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                                        foregroundColor: Theme.of(context).colorScheme.primary,
                                        elevation: 0,
                                        side: BorderSide(color: Theme.of(context).colorScheme.primary, width: 1),
                                      ),
                                      onPressed: () => _downloadModFile(selectedMod!, file),
                                    );
                                  }
                                } else if (status == 'ok') {
                                  trailingWidget = Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Chip(
                                        avatar: Icon(Icons.check, color: Colors.green, size: 16),
                                        label: Text(tr('Downloaded'), style: TextStyle(color: Colors.green)),
                                        backgroundColor: Colors.transparent,
                                      ),
                                      const SizedBox(width: 8),
                                      ElevatedButton.icon(
                                        icon: Icon(isInQueue ? Icons.remove : Icons.add),
                                        label: Text(isInQueue ? tr('In Queue') : tr('Add to Queue')),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: isInQueue ? Colors.grey[800] : Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                                          foregroundColor: Theme.of(context).colorScheme.primary,
                                          elevation: 0,
                                          side: BorderSide(color: Theme.of(context).colorScheme.primary, width: 1),
                                        ),
                                        onPressed: () {
                                          if (queueEntry == null) return;
                                          if (isInQueue) {
                                            setState(() => selectedFilesQueue.remove(queueEntry));
                                            _saveLaunchQueue();
                                          } else {
                                            _addFileToQueue(queueEntry);
                                          }
                                        },
                                      ),
                                      if (localPath != null)
                                        fileActionsMenu(
                                          onSelected: (a) => a == FileAction.showInFolder
                                              ? _showInFolder(localPath)
                                              : _deleteFiles([localPath], title: tr('Delete "{name}"?', {'name': file.name})),
                                        ),
                                    ],
                                  );
                                } else {
                                  final isOutdated = status == 'outdated';
                                  trailingWidget = ElevatedButton.icon(
                                    icon: Icon(isOutdated ? Icons.update : Icons.download),
                                    label: Text(isOutdated ? tr('Re-download') : tr('Download')),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                                      foregroundColor: Theme.of(context).colorScheme.primary,
                                      elevation: 0,
                                      side: BorderSide(color: Theme.of(context).colorScheme.primary, width: 1),
                                    ),
                                    onPressed: () => _downloadModFile(selectedMod!, file),
                                  );
                                  // Ждёт своей очереди: «В очереди» и убрать из неё.
                                  final queued = _repoQueue.where((d) => d.file.key == file.key).firstOrNull;
                                  if (queued != null) {
                                    trailingWidget = Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.schedule, size: 18, color: Colors.grey.shade500),
                                        const SizedBox(width: 6),
                                        Text(tr('In queue'), style: TextStyle(color: Colors.grey.shade500, fontWeight: FontWeight.bold)),
                                        IconButton(
                                          icon: const Icon(Icons.close, size: 18),
                                          tooltip: tr('Remove from the download queue'),
                                          onPressed: () => _cancelQueued(queued),
                                        ),
                                      ],
                                    );
                                  }
                                  final conflict = _conflictPaths[file.key];
                                  if (conflict != null) {
                                    final mod = selectedMod!;
                                    trailingWidget = Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        trailingWidget,
                                        PopupMenuButton<_ConflictAction>(
                                          tooltip: tr('What to do with the old file'),
                                          icon: const Icon(Icons.more_vert),
                                          enabled: !_isRepoQueued(file),
                                          onSelected: (a) => _resolveConflict(mod, file, a),
                                          itemBuilder: (context) => [
                                            PopupMenuItem(
                                              value: _ConflictAction.replace,
                                              child: ListTile(dense: true, leading: Icon(Icons.swap_horiz), title: Text(tr('Replace with this version'))),
                                            ),
                                            PopupMenuItem(
                                              value: _ConflictAction.delete,
                                              child: ListTile(dense: true, leading: Icon(Icons.delete_outline), title: Text(tr('Delete old file'))),
                                            ),
                                            PopupMenuItem(
                                              value: _ConflictAction.rename,
                                              child: ListTile(dense: true, leading: Icon(Icons.drive_file_rename_outline), title: Text(tr('Rename old file...'))),
                                            ),
                                            PopupMenuItem(
                                              value: _ConflictAction.move,
                                              child: ListTile(dense: true, leading: Icon(Icons.drive_file_move_outline), title: Text(tr('Move old file to folder...'))),
                                            ),
                                          ],
                                        ),
                                      ],
                                    );
                                  }
                                }

                                return Card(
                                  child: Padding(
                                    padding: const EdgeInsets.all(12.0),
                                    child: ListTile(
                                      contentPadding: EdgeInsets.zero,
                                      leading: Icon(statusIcon, color: statusColor, size: 32),
                                      title: Text(file.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                                      subtitle: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          const SizedBox(height: 4),
                                          SelectableText(tr('Expected MD5: {md5}', {'md5': file.md5.isEmpty ? tr('Not set') : file.md5})),
                                          if (file.size > 0)
                                            Text(tr('Size: {size}', {'size': _formatSize(file.size)})),
                                          if (localMd5 != null)
                                            SelectableText(tr('Local MD5: {md5}', {'md5': localMd5}), style: TextStyle(color: statusColor)),
                                          const SizedBox(height: 4),
                                          Text(statusText, style: TextStyle(color: statusColor, fontWeight: FontWeight.bold)),
                                        ],
                                      ),
                                      trailing: trailingWidget,
                                    ),
                                  ),
                                );
                              }),
                              // Что внутри скачанных файлов — после загрузки.
                              _buildLevels(selectedMod!),
                            ],
                          ),
                        ),
                ),
              ],
            ),
      ),
    );
  }

  /// Версия аддона: выпадающий список, если версий несколько.
  Widget _buildVersionSelector(ModItem mod) {
    final selected = _selectedVersion(mod);
    if (selected == null) return const SizedBox.shrink();
    if (!mod.hasSeveralVersions) {
      return selected.name.isEmpty
          ? const SizedBox.shrink()
          : Text(tr('Version: {version}', {'version': selected.name}), style: const TextStyle(color: Colors.grey));
    }
    final accent = Theme.of(context).colorScheme.primary;
    return Row(
      children: [
        Text(tr('Version:'), style: TextStyle(color: Colors.grey)),
        const SizedBox(width: 12),
        DropdownButton<String>(
          value: selected.name,
          isDense: true,
          items: [
            for (final v in mod.versions)
              DropdownMenuItem(
                value: v.name,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(tr(v.label), style: const TextStyle(fontWeight: FontWeight.bold)),
                    if (identical(v, mod.latest)) ...[
                      const SizedBox(width: 8),
                      _versionBadge(tr('latest'), accent),
                    ],
                    if (_isVersionDownloaded(mod, v)) ...[
                      const SizedBox(width: 8),
                      _versionBadge(tr('downloaded'), Colors.green),
                    ],
                  ],
                ),
              ),
          ],
          onChanged: (name) {
            if (name != null && name != selected.name) _changeVersion(mod, name);
          },
        ),
        if (!identical(selected, mod.latest)) ...[
          const SizedBox(width: 12),
          TextButton.icon(
            icon: const Icon(Icons.upgrade, size: 18),
            label: Text(tr('Latest: {version}', {'version': tr(mod.latest!.label)})),
            onPressed: () => _changeVersion(mod, mod.latest!.name),
          ),
        ],
      ],
    );
  }

  Widget _versionBadge(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          border: Border.all(color: color.withValues(alpha: 0.7)),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(text, style: TextStyle(fontSize: 11, color: color)),
      );

  /// Changelog выбранной версии.
  /// Уровни скачанных файлов выбранной версии: картинка (MAPxxP / PICTURE
  /// или заглушка), имя и кнопка запуска на этой карте.
  Widget _buildLevels(ModItem mod) {
    final files = [
      for (final f in _selectedVersion(mod)?.files ?? const <ModFile>[])
        if (fileStatuses[f.key] == 'ok' && _localPaths[f.key] != null) _localPaths[f.key]!,
    ];
    if (files.isEmpty || srb2FolderPath == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPackProgress(mod.name, files),
        for (final path in files) ...[
          _buildFileGametypes(path),
          _buildFileLevels(path),
          _buildFileCharacters(path),
          _buildFileColors(path),
        ],
      ],
    );
  }

  Future<List<MapPreview>> _levelsOf(String path) {
    String key;
    try {
      final st = File(path).statSync();
      key = '$path|${st.size}|${st.modified.millisecondsSinceEpoch}';
    } catch (_) {
      key = path;
    }
    return _mapPreviews.putIfAbsent(
      key,
      () => _gameFiles(_game.paletteFiles)
          .then((palettes) => MapScanner.scanInBackground(path, palettes))
          .catchError((_) => const <MapPreview>[]),
    );
  }

  /// Карты для выбора -warp на вкладке Launch: файлы игры, затем очередь
  /// (в порядке загрузки — поздние заменяют карты, как в игре).
  final Map<String, Future<List<MapPreview>>> _warpMapCache = {};

  Future<List<MapPreview>> _warpMaps() async {
    final root = srb2FolderPath;
    if (root == null) return const <MapPreview>[];
    final files = <String>[
      ...await _gameFiles(_game.baseMapFiles),
      for (final entry in _activeQueue) _entryPath(entry),
    ].where((f) => File(f).existsSync()).toList();
    final stamps = [
      for (final f in files)
        () {
          try {
            final st = File(f).statSync();
            return '$f|${st.size}|${st.modified.millisecondsSinceEpoch}';
          } catch (_) {
            return f;
          }
        }(),
    ];
    final palettes = await _gameFiles(_game.paletteFiles);
    return _warpMapCache.putIfAbsent(
      '${_game.id}\u0000${stamps.join('\u0000')}',
      () => MapScanner.scanAllInBackground(files, palettes, pictureInsideMaps: _game.pictureInsideMaps)
          .catchError((_) => const <MapPreview>[]),
    );
  }

  /// Персонажи для +skin: файлы игры, затем включённые аддоны очереди.
  final Map<String, Future<List<CharacterInfo>>> _characterCache = {};

  Future<List<CharacterInfo>> _characters() async {
    if (srb2FolderPath == null) return const <CharacterInfo>[];
    final base = await _gameFiles(_game.baseSkinFiles);
    final files = <String>[
      ...base,
      for (final entry in _activeQueue) _entryPath(entry),
    ].where((f) => File(f).existsSync()).toList();
    final stamps = [
      for (final f in files)
        () {
          try {
            final st = File(f).statSync();
            return '$f|${st.size}|${st.modified.millisecondsSinceEpoch}';
          } catch (_) {
            return f;
          }
        }(),
    ];
    final palettes = await _gameFiles(_game.paletteFiles);
    final key = '${_game.id}\u0000${stamps.join('\u0000')}';
    if (!_characterCache.containsKey(key)) {
      // В журнал: какие файлы игры нашлись — по нему видно, почему у
      // персонажей нет иконок (не нашёлся файл со спрайтами или палитра).
      final game = _game;
      unawaited(_characterCache.putIfAbsent(key, () => _scanCharacters(files, palettes)).then((chars) {
        final noIcon = [for (final c in chars) if (c.icon == null) c.name];
        AppLog.write('Characters (${game.id}): game files ${game.baseSkinFiles.map((f) {
          final hit = base.where((b) => p.basename(b).toLowerCase() == f.toLowerCase()).firstOrNull;
          return '$f=${hit ?? 'not found'}';
        }).join(', ')}; palette ${palettes.isEmpty ? 'not found' : palettes.join(', ')}; '
            '${chars.length} characters, without icon: ${noIcon.isEmpty ? 'none' : noIcon.join(', ')}');
      }));
    }
    return _characterCache[key]!;
  }

  Future<List<CharacterInfo>> _scanCharacters(List<String> files, List<String> palettes) {
    return CharacterScanner.scanAllInBackground(files, palettes,
              colors: _game.skinColors,
              startColor: _game.skinStartColor,
              iconFrames: _game.skinIconFrames,
              portraits: _game.skinPortraits,
              builtInSonic: _game.builtInSonic,
              baseDescriptions: _game.vanillaSkinDescriptions ? CharacterScanner.vanillaDescriptions : const {})
        .catchError((_) => const <CharacterInfo>[]);
  }

  /// Персонажи скачанного файла (в предпочитаемом цвете).
  final Map<String, Future<List<CharacterInfo>>> _fileCharacters = {};

  Widget _buildFileCharacters(String path) {
    final future = _fileCharacters.putIfAbsent(
      '${_game.id}|$path|${_mapPreviewKey(path)}',
      () => _gameFiles(_game.paletteFiles)
          .then((palettes) => CharacterScanner.scanAllInBackground([path], palettes,
              colors: _game.skinColors,
              startColor: _game.skinStartColor,
              iconFrames: _game.skinIconFrames,
              portraits: _game.skinPortraits))
          .catchError((_) => const <CharacterInfo>[]),
    );
    return FutureBuilder<List<CharacterInfo>>(
      future: future,
      builder: (context, snap) {
        final chars = snap.data;
        if (chars == null || chars.isEmpty) return const SizedBox.shrink();
        return _contentSection('characters|$path', tr('Characters in {file} ({n})', {'file': p.basename(path), 'n': chars.length}), () => [
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final c in chars)
                    characterTooltip(
                      c,
                      kartStats: _game.kartStats,
                      extra: [
                        tr('Play as {name}: adds the file to the launch queue and sets +skin {skin}',
                            {'name': c.realname, 'skin': c.name}),
                        if (c.prefColor.isNotEmpty) tr('Preferred color: {color}', {'color': c.prefColor}),
                      ],
                      InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => _chooseCharacter(c.name, path),
                        child: Container(
                        width: 120,
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.black26,
                          borderRadius: BorderRadius.circular(8),
                          // Выбранный персонаж (+skin) — рамка цвета темы.
                          border: _launch.options.cvar('skin').toLowerCase() == c.name
                              ? Border.all(color: Theme.of(context).colorScheme.primary, width: 2)
                              : Border.all(color: Colors.grey[800]!),
                        ),
                        child: Column(
                          children: [
                            CharacterIcon(c, size: 64, portrait: true),
                            const SizedBox(height: 6),
                            Text(c.realname,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                            Text(c.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 11, color: Colors.grey)),
                            if (_game.kartStats) KartStatsLine(c),
                          ],
                        ),
                      ),
                      ),
                    ),
                ],
              ),
            ]);
      },
    );
  }

  String _mapPreviewKey(String path) {
    try {
      final st = File(path).statSync();
      return '${st.size}|${st.modified.millisecondsSinceEpoch}';
    } catch (_) {
      return '';
    }
  }

  Widget _buildFileLevels(String path) {
    return FutureBuilder<List<MapPreview>>(
      future: _levelsOf(path),
      builder: (context, snap) {
        final maps = snap.data;
        if (maps == null) {
          return snap.connectionState == ConnectionState.done
              ? const SizedBox.shrink()
              : const Padding(
                  padding: EdgeInsets.only(top: 20),
                  child: LinearProgressIndicator(minHeight: 2),
                );
        }
        // Титульная карта — фон меню, а не уровень.
        final levels = [for (final m in maps) if (!m.isTitleMap) m];
        if (levels.isEmpty) return const SizedBox.shrink();
        return _contentSection('levels|$path', tr('Levels in {file} ({n})', {'file': p.basename(path), 'n': levels.length}), () => [
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [for (final m in levels) _buildLevelCard(m, path)],
              ),
            ]);
      },
    );
  }

  Widget _buildLevelCard(MapPreview m, String path) {
    final image = m.image;
    // Картинки уровней — пиксельные 160×100: без сглаживания при увеличении.
    final picture = image == null
        ? Image.asset('assets/map_unknown.png', width: 192, height: 120, fit: BoxFit.cover, filterQuality: FilterQuality.none)
        : Image.memory(
            image,
            width: 192,
            height: 120,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.none,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => Image.asset('assets/map_unknown.png',
                width: 192, height: 120, fit: BoxFit.cover, filterQuality: FilterQuality.none),
          );
    // Выбранная карта (-warp) — рамка цвета темы.
    final o = _launch.options;
    final selected = o.warpMap.trim().toUpperCase() == m.map;
    return SizedBox(
      width: 192,
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: selected ? BorderSide(color: Theme.of(context).colorScheme.primary, width: 2) : BorderSide.none,
        ),
        child: InkWell(
          // Щелчок — только -warp; режим — в меню «⋮».
          onTap: () => _warpTo(m.map, path),
          child: Tooltip(
            message: tr('Play on {map}: adds the file to the launch queue and sets -warp', {'map': m.map}),
            waitDuration: const Duration(milliseconds: 500),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                picture,
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(m.map,
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                overflow: TextOverflow.ellipsis),
                          ),
                          Builder(
                            builder: (button) => IconButton(
                              icon: const Icon(Icons.more_vert, size: 18),
                              tooltip: tr('Gametypes of this map'),
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                              onPressed: () => _levelGametypeMenu(button, m, path),
                            ),
                          ),
                        ],
                      ),
                      if (m.title.isNotEmpty)
                        srb2Title(m.title, style: const TextStyle(fontSize: 12, color: Colors.grey), maxLines: 2),
                      if (m.types.isNotEmpty) MapTypes(m.types),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Выбор персонажа на вкладке Addons: файл — в очередь, +skin — в
  /// параметры (+color не трогаем).
  void _chooseCharacter(String skin, String path) {
    _enableInQueue(path);
    _launch.updateOptions((o) => o.setCvar('skin', skin));
    setState(() {});
    showSnack(context, 
      SnackBar(
        content: Text(tr('{file} is in the launch queue, +skin {skin} is set.', {'file': p.basename(path), 'skin': skin})),
        action: SnackBarAction(label: tr('Launch'), onPressed: () => _launchGame()),
      ),
    );
  }

  /// Добавляет файл в очередь (или включает, если он там выключен).
  void _enableInQueue(String path) {
    final entry = _queueEntryFor(path);
    if (selectedFilesQueue.contains(entry) && !_disabledQueue.contains(entry)) return;
    setState(() {
      if (!selectedFilesQueue.contains(entry)) selectedFilesQueue.add(entry);
      _disabledQueue.remove(entry);
    });
    _saveLaunchQueue();
  }

  /// Меню «⋮» карточки уровня: режимы, которые карта берёт (встроенные и
  /// свои режимы этого файла и очереди). Выбор — -warp на карту и -gametype.
  Future<void> _levelGametypeMenu(BuildContext anchor, MapPreview m, String path) async {
    final own = await _contentsOf(path);
    final queued = await _queueGametypes();
    if (!mounted || !anchor.mounted) return;
    final (builtIn, custom) = gametypesForMap(_game, m, [...own.gametypes, ...queued]);
    final now = _launch.options;
    final choice = await showGametypeMenu(anchor, builtIn, custom,
        current: currentGametypeChoice(now.gametype, netOff: now.net == NetMode.off),
        singleplayer: mapHasSingleplayer(m));
    if (choice == null || !mounted) return;
    _warpTo(m.map, path);
    _launch.updateOptions((o) {
      if (choice == singleplayerGametype) {
        // Одиночная игра: без режима и без своего сервера.
        o.gametype = '';
        o.net = NetMode.off;
      } else {
        o.gametype = choice;
      }
    });
    setState(() {});
  }

  /// Готовит запуск на карте [map]: файл — в очередь, -warp — в параметры.
  void _warpTo(String map, String path) {
    final entry = _queueEntryFor(path);
    if (!selectedFilesQueue.contains(entry) || _disabledQueue.contains(entry)) {
      setState(() {
        if (!selectedFilesQueue.contains(entry)) selectedFilesQueue.add(entry);
        _disabledQueue.remove(entry);
      });
      _saveLaunchQueue();
    }
    _launch.updateOptions((o) => o.warpMap = map);
    setState(() {});
    showSnack(context, 
      SnackBar(
        content: Text(tr('{file} is in the launch queue, -warp {map} is set.', {'file': p.basename(path), 'map': map})),
        action: SnackBarAction(label: tr('Launch'), onPressed: () => _launchGame()),
      ),
    );
  }

  Widget _buildChangelog(ModItem mod) {
    final version = _selectedVersion(mod);
    if (version == null || version.changelog.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.black26,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.grey[800]!),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              version.name.isEmpty ? tr('Changelog') : tr('Changelog — {version}', {'version': version.name}),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            SelectableText(version.changelog),
          ],
        ),
      ),
    );
  }

  /// Строка поиска с подсказками тегов: от двух набранных букв — подходящие
  /// теги (`группа:тег`, цветом группы) с числом аддонов; выбор (мышью или
  /// стрелками и Enter) подставляет тег с группой.
  Widget _buildSearchField() {
    final scheme = Theme.of(context).colorScheme;
    return RawAutocomplete<(String, int)>(
      textEditingController: _searchController,
      focusNode: _searchFocus,
      optionsBuilder: (value) => _tagSuggestions(value.text),
      // Строка после выбора: набираемое слово заменяется тегом.
      displayStringForOption: (o) => completeSearchTag(_searchController.text, o.$1),
      onSelected: (_) => _searchFocus.requestFocus(),
      fieldViewBuilder: (context, controller, focusNode, onSubmitted) => TextField(
        controller: controller,
        focusNode: focusNode,
        onSubmitted: (_) => onSubmitted(),
        decoration: InputDecoration(
          hintText: tr('Name, uploader, map, character, tag... -word excludes'),
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(icon: const Icon(Icons.clear, size: 18), onPressed: () => _searchController.clear())
              : null,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          isDense: true,
        ),
      ),
      optionsViewBuilder: (context, onSelected, options) {
        final exclude = currentSearchToken(_searchController.text).$2.startsWith('-');
        final list = options.toList();
        final grouping = _tagGrouping;
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 304, maxHeight: 280),
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 4),
                shrinkWrap: true,
                itemCount: list.length,
                itemBuilder: (context, i) {
                  final (tag, count) = list[i];
                  final colon = tag.indexOf(':');
                  final color = Color(grouping.groupOfQualified(tag).color);
                  // Строка, выбранная стрелками: подсвечена и прокручена в вид.
                  final highlighted = AutocompleteHighlightedOption.of(context) == i;
                  if (highlighted) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (context.mounted) Scrollable.ensureVisible(context, alignment: 0.5);
                    });
                  }
                  return Material(
                    color: highlighted ? scheme.primary.withValues(alpha: 0.18) : Colors.transparent,
                    child: InkWell(
                      onTap: () => onSelected(list[i]),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                        child: Row(
                          children: [
                            Icon(exclude ? Icons.remove_circle_outline : Icons.sell_outlined,
                                size: 16, color: exclude ? Colors.redAccent : color),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text.rich(
                                TextSpan(children: [
                                  if (exclude) const TextSpan(text: '-', style: TextStyle(color: Colors.redAccent)),
                                  TextSpan(
                                      text: tag.substring(0, colon + 1),
                                      style: TextStyle(color: color.withValues(alpha: 0.75))),
                                  TextSpan(
                                      text: tag.substring(colon + 1),
                                      style: TextStyle(color: color, fontWeight: FontWeight.w600)),
                                ]),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text('$count', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  /// Свёрнутые группы в панели тегов (id группы, сохраняется).
  final Set<String> _collapsedTagGroups = {};

  Future<void> _toggleTagGroup(String id) async {
    setState(() => _collapsedTagGroups.contains(id) ? _collapsedTagGroups.remove(id) : _collapsedTagGroups.add(id));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('tag_groups_collapsed', _collapsedTagGroups.toList());
  }

  /// Группы тегов: из `tag_groups` подключённых репозиториев, иначе встроенные.
  /// Пересчитываются, только когда меняются файлы репозиториев.
  TagGrouping get _tagGrouping {
    final key = Object.hashAll([for (final e in rawManifests.entries) Object.hash(e.key, e.value)]);
    final cached = _tagGroupingCache;
    if (cached != null && cached.$1 == key) return cached.$2;
    final g = TagGrouping.fromManifests(rawManifests.values);
    _tagGroupingCache = (key, g);
    return g;
  }

  (int, TagGrouping)? _tagGroupingCache;


  /// Все теги аддонов игры по группам (группу можно свернуть): щелчок —
  /// «только с тегом» (группа:тег), ещё щелчок — «без тега» (-группа:тег),
  /// третий — снять. Строка поиска меняется вместе с ним. В панели тег — без
  /// группы (она в заголовке) и в её цвете.
  Widget _buildTagPanel() {
    final tags = _gameTags;
    final scheme = Theme.of(context).colorScheme;
    final text = _searchController.text;
    void apply(String value) => _searchController.value =
        TextEditingValue(text: value, selection: TextSelection.collapsed(offset: value.length));

    Widget chip(String rawTag, int count, Color groupColor) {
      // В поиске тег пишется с группой: source:workshop.
      final tag = _tagGrouping.qualified(rawTag);
      final sign = searchTagSign(text, tag);
      final color = sign == 1 ? scheme.primary : sign == -1 ? Colors.redAccent : null;
      return Tooltip(
        message: '$tag\n${switch (sign) {
          1 => tr('Only addons with {tag}. Click: hide addons with it', {'tag': tag}),
          -1 => tr('Addons with {tag} are hidden. Click: remove the filter', {'tag': tag}),
          _ => tr('Click: only addons with {tag}', {'tag': tag}),
        }}',
        waitDuration: const Duration(milliseconds: 500),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => apply(cycleSearchTag(_searchController.text, tag)),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: (color ?? groupColor).withValues(alpha: color == null ? 0.08 : 0.18),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: color ?? groupColor.withValues(alpha: 0.6)),
            ),
            child: Text.rich(
              TextSpan(children: [
                TextSpan(
                  text: '${sign == -1 ? '-' : ''}${_tagGrouping.label(rawTag)}',
                  style: TextStyle(
                    color: color ?? groupColor,
                    decoration: sign == -1 ? TextDecoration.lineThrough : null,
                  ),
                ),
                TextSpan(text: ' $count', style: const TextStyle(color: Colors.grey)),
              ]),
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ),
      );
    }

    final groups = _tagGrouping.group(tags, (t) => t.$1);
    // Отступы — внутри прокрутки: полоса прокрутки панели стоит у самого края,
    // на одной вертикали с полосой списка аддонов под ней.
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 280),
        child: tags.isEmpty
            ? Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(tr('The addons of this game have no tags.'),
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
              )
            : SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (group, list) in groups) ...[
                      () {
                        final groupColor = Color(group.color);
                        final collapsed = _collapsedTagGroups.contains(group.id);
                        // Выбранные теги свёрнутой группы — в заголовке, чтобы фильтр был виден.
                        final active = [
                          for (final (t, _) in list)
                            if (searchTagSign(text, _tagGrouping.qualified(t)) != 0) t,
                        ];
                        return InkWell(
                          borderRadius: BorderRadius.circular(6),
                          onTap: () => _toggleTagGroup(group.id),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Row(
                              children: [
                                Icon(collapsed ? Icons.chevron_right : Icons.expand_more, size: 18, color: Colors.grey),
                                Container(
                                  width: 8,
                                  height: 8,
                                  margin: const EdgeInsets.only(right: 6),
                                  decoration: BoxDecoration(color: groupColor, shape: BoxShape.circle),
                                ),
                                Text(group.title, // name из репозитория, иначе id
                                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: groupColor)),
                                Text('  ${list.length}', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                                if (collapsed && active.isNotEmpty)
                                  Flexible(
                                    child: Text(
                                      '  ${active.map((t) => '${searchTagSign(text, _tagGrouping.qualified(t)) == -1 ? '-' : ''}${_tagGrouping.label(t)}').join(' ')}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(fontSize: 11, color: scheme.primary),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        );
                      }(),
                      if (!_collapsedTagGroups.contains(group.id))
                        Padding(
                          padding: const EdgeInsets.only(left: 4, bottom: 6),
                          child: Wrap(
                            spacing: 4,
                            runSpacing: 4,
                            children: [for (final (tag, count) in list) chip(tag, count, Color(group.color))],
                          ),
                        ),
                    ],
                  ],
                ),
              ),
      ),
    );
  }

  /// Теги аддона: первые [_collapsedTagCount] видны сразу, остальные
  /// прячутся за чипом "+N more" и раскрываются по клику.
  /// Тег аддона с кнопками ＋ (искать с ним) и － (скрыть аддоны с ним).
  /// Не Chip: он переводит любой щелчок по подписи в её центр, и кнопки
  /// внутри него не различаются.
  Widget _tagChip(String rawTag) {
    final scheme = Theme.of(context).colorScheme;
    // У аддона тег — без группы, в её цвете; в поиск он идёт с группой
    // (source:workshop).
    final tag = _tagGrouping.qualified(rawTag);
    final label = _tagGrouping.label(rawTag);
    final color = Color(_tagGrouping.of(rawTag).color);
    final sign = searchTagSign(_searchController.text, tag);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 3, 3, 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Группа — по настройке (Settings → Addons): source:workshop.
          Text.rich(
            TextSpan(children: [
              if (_tagDisplay.showGroup)
                TextSpan(
                    text: tag.substring(0, tag.indexOf(':') + 1), style: TextStyle(color: color.withValues(alpha: 0.7))),
              TextSpan(text: label, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
            ]),
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(width: 8),
          _tagButton(
            Icons.add,
            sign == 1 ? tr('Remove {tag} from the search', {'tag': tag}) : tr('Search with the tag {tag}', {'tag': tag}),
            active: sign == 1,
            onTap: () => _searchTag(tag),
          ),
          const SizedBox(width: 3),
          _tagButton(
            Icons.remove,
            sign == -1 ? tr('Remove {tag} from the search', {'tag': tag}) : tr('Hide addons with the tag {tag}', {'tag': tag}),
            active: sign == -1,
            onTap: () => _searchTag(tag, exclude: true),
          ),
        ],
      ),
    );
  }

  /// Квадратная кнопка у тега; [active] — тег уже в поиске с этим знаком.
  Widget _tagButton(IconData icon, String tooltip, {required bool active, required VoidCallback onTap}) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: Material(
        color: active ? scheme.primary : scheme.surface,
        borderRadius: BorderRadius.circular(5),
        child: InkWell(
          borderRadius: BorderRadius.circular(5),
          onTap: onTap,
          child: SizedBox(
            width: 24,
            height: 24,
            child: Icon(icon, size: 16, color: active ? scheme.onPrimary : scheme.primary),
          ),
        ),
      ),
    );
  }

  /// Тег — в строку поиска (к тому, что там уже есть); тот же тег с тем же
  /// знаком — убрать из поиска.
  void _searchTag(String tag, {bool exclude = false}) {
    final current = _searchController.text;
    final text = searchTagSign(current, tag) == (exclude ? -1 : 1)
        ? removeSearchTag(current, tag)
        : addSearchTag(current, tag, exclude: exclude);
    _searchController.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
  }

  Widget _buildTagChips(List<String> unsorted) {
    // Порядок — по настройке: по алфавиту имени тега или по группам (порядок
    // групп — как в tag_groups, внутри — по алфавиту).
    final grouping = _tagGrouping;
    int byName(String a, String b) => grouping.label(a).toLowerCase().compareTo(grouping.label(b).toLowerCase());
    final tags = [...unsorted]..sort(switch (_tagDisplay.order) {
        TagOrder.alphabetical => byName,
        TagOrder.groups => (a, b) {
            final ga = grouping.groups.indexOf(grouping.of(a)), gb = grouping.groups.indexOf(grouping.of(b));
            return ga != gb ? ga - gb : byName(a, b);
          },
      });
    final collapsible = !_tagDisplay.showAll && tags.length > _collapsedTagCount;
    final Iterable<String> visible =
        collapsible && !_tagsExpanded ? tags.take(_collapsedTagCount) : tags;
    final accent = Theme.of(context).colorScheme.primary;

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final tag in visible) _tagChip(tag),
        if (collapsible)
          ActionChip(
            avatar: Icon(_tagsExpanded ? Icons.expand_less : Icons.expand_more, size: 16, color: accent),
            label: Text(
              _tagsExpanded ? tr('Show less') : tr('+{n} more', {'n': tags.length - _collapsedTagCount}),
              style: TextStyle(fontSize: 11, color: accent, fontWeight: FontWeight.bold),
            ),
            tooltip: _tagsExpanded
                ? null
                : tags.skip(_collapsedTagCount).map(_tagDisplay.showGroup ? grouping.qualified : grouping.label).join(', '),
            side: BorderSide(color: accent.withValues(alpha: 0.6)),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onPressed: () => setState(() => _tagsExpanded = !_tagsExpanded),
          ),
      ],
    );
  }

  // --- ЭКРАН УПРАВЛЕНИЯ ОЧЕРЕДЬЮ С DRAG & DROP ---

  Widget _buildLaunchQueueView() {
    return DropTarget(
      onDragDone: (details) => _addPathsToQueue(details.files.map((f) => f.path)),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    tr('Addon load order (-file):'),
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                ),
                // Отмена и повтор изменений очереди (Ctrl+Z / Ctrl+Y).
                IconButton(
                  icon: const Icon(Icons.undo),
                  tooltip: tr('Undo the last queue change (Ctrl+Z)'),
                  onPressed: _queueHistory.canUndo ? _undoQueue : null,
                ),
                IconButton(
                  icon: const Icon(Icons.redo),
                  tooltip: tr('Redo (Ctrl+Y)'),
                  onPressed: _queueHistory.canRedo ? _redoQueue : null,
                ),
                const SizedBox(width: 8),
                // Есть выключенные — убрать их; нет — убрать все аддоны.
                if (_disabledQueue.isNotEmpty)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.playlist_remove),
                    label: Text(tr('Remove disabled ({n})', {'n': _disabledQueue.length})),
                    onPressed: () => _clearQueue(disabledOnly: true),
                  )
                else
                  OutlinedButton.icon(
                    icon: const Icon(Icons.playlist_remove),
                    label: Text(tr('Remove addons')),
                    onPressed: selectedFilesQueue.isEmpty ? null : () => _clearQueue(disabledOnly: false),
                  ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.add),
                  label: Text(tr('Add files...')),
                  onPressed: _pickFilesForQueue,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              tr('Drag & Drop .wad, .pk3, .lua, .soc files here, click "Add files..." or use "Add to Queue" on the Addons tab.'),
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _buildQueueList()),
                  const SizedBox(width: 16),
                  // Галочки параметров SRB2 и доп. параметры (общие для всех экзешников).
                  SizedBox(
                    width: 390,
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey[700]!),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      // Поля панели заполняются из настроек, поэтому ждём их загрузки.
                      child: ListenableBuilder(
                        listenable: _launch,
                        builder: (context, _) => _launch.loaded
                            ? LaunchOptionsPanel(
                                settings: _launch,
                                queueHasFiles: selectedFilesQueue.isNotEmpty,
                                // Профиль запуска сохраняет и очередь аддонов.
                                getQueue: () => [
                                  for (final e in selectedFilesQueue) _disabledQueue.contains(e) ? '$_offMark$e' : e,
                                ],
                                loadMaps: _warpMaps,
                                loadCharacters: _characters,
                                loadGametypes: _queueGametypes,
                                loadColors: _launchColors,
                                masters: [for (final m in _servers.masters) (_servers.masterName(m), m)],
                                loadRooms: (master) => _servers.fetchRooms(master.isEmpty ? null : master),
                                scrollController: _launchOptionsScroll,
                                setQueue: (queue) {
                                  setState(() {
                                    selectedFilesQueue = [
                                      for (final e in queue) e.startsWith(_offMark) ? e.substring(_offMark.length) : e,
                                    ];
                                    _disabledQueue
                                      ..clear()
                                      ..addAll([
                                        for (final e in queue)
                                          if (e.startsWith(_offMark)) e.substring(_offMark.length),
                                      ]);
                                  });
                                  _saveLaunchQueue();
                                },
                              )
                            : const Center(child: CircularProgressIndicator()),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            ListenableBuilder(
              listenable: _launch,
              builder: (context, _) => _buildCommandPreview(),
            ),
            const SizedBox(height: 8),
            // Выбор сборки — слева, «Launch Game» — всегда у правого края.
            Row(
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: ExecutableSelector(settings: _launch, initialDirectory: srb2FolderPath),
                  ),
                ),
                const SizedBox(width: 16),
                ValueListenableBuilder<bool>(
                  valueListenable: launchPreparing,
                  builder: (context, busy, _) => ElevatedButton.icon(
                  // Насыщенный зелёный с белым текстом: в любой теме видно, что
                  // кнопка активна (цвет текста темы на зелёном выглядел как
                  // выключенная кнопка). Пока запуск готовится — бледнее.
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2E9E46),
                    foregroundColor: Colors.white,
                    iconColor: Colors.white,
                    disabledBackgroundColor: const Color(0xFF2E9E46).withValues(alpha: 0.55),
                    disabledForegroundColor: Colors.white70,
                    disabledIconColor: Colors.white70,
                    elevation: 3,
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                  ).copyWith(
                    overlayColor: WidgetStatePropertyAll(Colors.white.withValues(alpha: 0.12)),
                  ),
                  icon: busy
                      ? const SizedBox(
                          width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                      : const Icon(Icons.play_arrow, size: 28),
                  label: Text(busy ? tr('Checking...') : tr('Launch Game'),
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  onPressed: busy ? null : () => _launchGame(),
                ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Родной цвет (prefcolor) персонажа +skin — для «Всегда родной цвет»;
  /// '' — не нужен (выключено, Ring Racers) или не знаем (+skin не задан).
  Future<String> _defaultSkinColor() async {
    final o = _launch.options;
    final skin = o.cvar('skin').trim().toLowerCase();
    if (!o.defaultColor || skin.isEmpty || _game.engine == 'drrr') return '';
    try {
      final chars = await _characters();
      return chars.where((c) => c.name == skin).firstOrNull?.prefColor ?? '';
    } catch (_) {
      return '';
    }
  }

  /// То же для строки команды: уже известный цвет, иначе — узнаём и перерисуем.
  final Map<String, String> _skinColorShown = {};
  String _defaultSkinColorNow() {
    final o = _launch.options;
    final skin = o.cvar('skin').trim().toLowerCase();
    if (!o.defaultColor || skin.isEmpty || _game.engine == 'drrr') return '';
    // Персонаж может появиться с аддоном очереди — ключ меняется с очередью.
    final key = '${_game.id}|$skin|${Object.hashAll(_activeQueue)}';
    final known = _skinColorShown[key];
    if (known != null) return known;
    _skinColorShown[key] = '';
    _defaultSkinColor().then((color) {
      _skinColorShown[key] = color;
      if (mounted && color.isNotEmpty) setState(() {});
    });
    return '';
  }

  /// Итоговая командная строка (как её увидит SRB2) с кнопкой копирования.
  Widget _buildCommandPreview() {
    final parts = [
      ..._launch.commandLine(skinColor: _defaultSkinColorNow()),
      if (_activeQueue.isNotEmpty) ...[
        '-file',
        for (final entry in _activeQueue) srb2FolderPath == null ? entry : _entryPath(entry),
      ],
    ];
    final text = parts.map(PlatformUtils.quoteIfNeeded).join(' ');
    return Row(
      children: [
        const Icon(Icons.terminal, size: 16, color: Colors.grey),
        const SizedBox(width: 8),
        Expanded(
          child: SelectableText(
            text,
            maxLines: 2,
            style: const TextStyle(
              fontSize: 12,
              color: Colors.grey,
              fontFamily: 'monospace',
              fontFamilyFallback: ['Consolas', 'DejaVu Sans Mono'],
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.copy, size: 18),
          tooltip: tr('Copy command line'),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: text));
            showSnack(context, 
              SnackBar(content: Text(tr('Command line copied'))),
            );
          },
        ),
      ],
    );
  }

  /// Очередь файлов -file (порядок загрузки аддонов).
  Widget _buildQueueList() {
    var activePos = 0;
    final activePositions = <String, int>{
      for (final e in selectedFilesQueue)
        if (!_disabledQueue.contains(e)) e: ++activePos,
    };
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey[700]!),
        borderRadius: BorderRadius.circular(8),
        color: Colors.black26,
      ),
      // DragBoundary: перетаскиваемый файл не выходит за рамку списка.
      child: DragBoundary(
        child: selectedFilesQueue.isEmpty
          ? Center(
              child: Text(
                tr('Queue is empty.\nDrag & Drop .wad, .pk3, .lua, .soc files here\nor add them from the Addons tab.'),
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
            )
          // Порядок меняется перетаскиванием за ручку слева (или стрелками).
          : ReorderableListView.builder(
              buildDefaultDragHandles: false,
              dragBoundaryProvider: DragBoundary.forRectOf,
              itemCount: selectedFilesQueue.length,
              onReorder: _reorderQueue,
              itemBuilder: (context, index) {
                final entry = selectedFilesQueue[index];
                final enabled = !_disabledQueue.contains(entry);
                // Номер — позиция в -file среди включённых.
                final position = activePositions[entry] ?? 0;
                final dim = enabled ? null : Colors.grey;
                return ListTile(
                  key: ValueKey(entry),
                  leading: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ReorderableDragStartListener(
                        index: index,
                        child: MouseRegion(
                          cursor: SystemMouseCursors.grab,
                          child: Tooltip(
                            message: tr('Drag to change the load order'),
                            child: const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                              child: Icon(Icons.drag_indicator, color: Colors.grey),
                            ),
                          ),
                        ),
                      ),
                      Tooltip(
                        message: enabled
                            ? tr('On: loaded into the game')
                            : tr('Off: stays in the list but is not loaded'),
                        child: Switch(
                          value: enabled,
                          onChanged: (v) => _setQueueEntryEnabled(entry, v),
                        ),
                      ),
                      const SizedBox(width: 4),
                      CircleAvatar(
                        backgroundColor: enabled
                            ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.2)
                            : Colors.grey.withValues(alpha: 0.15),
                        child: Text(enabled ? '$position' : '–', style: TextStyle(color: dim)),
                      ),
                    ],
                  ),
                  title: Text(
                    _entryName(entry),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: dim,
                      decoration: enabled ? null : TextDecoration.lineThrough,
                    ),
                  ),
                  subtitle: _isPathEntry(entry)
                      ? Text(_entryFolder(entry), style: const TextStyle(fontSize: 12, color: Colors.grey))
                      : null,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_upward),
                        tooltip: tr('Move Up'),
                        onPressed: index > 0 ? () => _moveQueueItem(index, -1) : null,
                      ),
                      IconButton(
                        icon: const Icon(Icons.arrow_downward),
                        tooltip: tr('Move Down'),
                        onPressed: index < selectedFilesQueue.length - 1 ? () => _moveQueueItem(index, 1) : null,
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                        tooltip: tr('Remove from Queue'),
                        onPressed: () => _removeFileFromQueue(index),
                      ),
                    ],
                  ),
                );
              },
            ),
      ),
    );
  }
}
