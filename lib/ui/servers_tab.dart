import '../i18n.dart';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../models/game.dart';
import '../models/srb2_server.dart';
import '../services/launch_settings.dart';
import '../services/app_log.dart';
import '../services/characters.dart';
import '../services/game_files.dart';
import '../services/geoip.dart';
import '../services/map_preview.dart';
import 'character_picker.dart';
import 'file_actions.dart';
import '../services/file_hash.dart';
import '../services/server_blacklist.dart';
import '../services/server_downloads.dart';
export '../services/server_downloads.dart' show RepoFileRef;
import '../services/server_files.dart';
import '../services/servers_store.dart';
import '../utils/natural_compare.dart';
import 'build_split_button.dart';
import 'snack.dart';
import 'srb2_text.dart';

export 'srb2_text.dart';

/// Откуда скачивается аддон сервера.
typedef _Source = ServerFileSource;

/// Столбец сортировки списка серверов; auto — "умный" порядок по умолчанию.
enum _SortColumn { auto, name, players, ping, gametype, map }

/// Вкладка Servers: список серверов (мастер-серверы + свой список),
/// информация о сервере, игроки, аддоны и подключение.
class ServersTab extends StatefulWidget {
  final ServersStore store;

  /// Папка игры (где srb2.pk3 и DOWNLOAD) или null.
  final String? gameFolder;

  /// MD5 → файл в репозиториях аддонов.
  final Map<String, RepoFileRef> repoFiles;

  /// Запуск игры с подключением к серверу (`+connect адрес`). [files] —
  /// локальные пути аддонов сервера в его порядке (грузятся до подключения)
  /// или null, если загрузить их заранее нельзя.
  /// [executableId] — сборка из стрелки у кнопки Join (null — по умолчанию).
  final void Function(String address, List<String>? files, String? executableId) onJoin;

  /// Сборки для выбора при подключении.
  final LaunchSettings launch;

  /// Открывает настройки на разделе Servers.
  final VoidCallback onOpenSettings;

  const ServersTab({
    super.key,
    required this.store,
    required this.gameFolder,
    required this.repoFiles,
    required this.onJoin,
    required this.launch,
    required this.onOpenSettings,
  });

  @override
  State<ServersTab> createState() => _ServersTabState();
}

class _ServersTabState extends State<ServersTab> {
  /// Автообновление — один раз за запуск лаунчера для каждой игры,
  /// а не при каждом входе во вкладку.
  static final Set<String> _autoRefreshed = {};

  ServersStore get store => widget.store;
  GameDef get game => store.game;

  // Статические — чтобы выбор и сортировка сохранялись при переключении вкладок.
  static final Map<String, String?> _selectedByGame = {};
  String? get _selectedKey => _selectedByGame[game.id];
  set _selectedKey(String? v) => _selectedByGame[game.id] = v;
  static _SortColumn _sortColumn = _SortColumn.auto;
  static bool _sortAscending = true;
  final _search = TextEditingController();

  // Аддоны выбранного сервера: где лежат у вас ('' — нет), прогресс, ошибки.
  // Статические, чтобы после возврата на вкладку не проверять всё заново.
  // Само скачивание живёт в [ServerDownloads], а не во вкладке: при
  // переключении вкладок оно продолжается.
  final ServerDownloads _dl = ServerDownloads.instance;
  LocalFileIndex? get _index => _dl.index;
  set _index(LocalFileIndex? v) => _dl.index = v;
  Map<String, String> get _local => _dl.local;
  Map<String, double?> get _downloading => _dl.downloading;
  Map<String, String> get _errors => _dl.errors;
  Map<String, _Source> get _sourceOf => _dl.sourceOf;
  int _checkToken = 0;

  // Пакетное скачивание (кнопки Download missing / Join).
  bool get _busy => _dl.busy;
  bool get _cancel => _dl.cancelled;
  String? _joiningKey;
  int get _batchIndex => _dl.batchIndex;
  int get _batchTotal => _dl.batchTotal;

  void _onDownloads() {
    if (mounted) setState(() {});
  }

  // Страна хоста: база из сборки; имена хостов разрешаются один раз.
  static GeoIp? _geo;
  static final Map<String, String?> _hostCountry = {};
  static final Set<String> _resolving = {};

  /// Сервер на этом же компьютере.
  static bool _isLocalhost(String host) {
    final h = host.toLowerCase();
    return h == 'localhost' || h == '::1' || h == '0.0.0.0' || h.startsWith('127.');
  }

  /// Код страны сервера [host] (null — неизвестно или ещё разрешается).
  String? _country(String host) {
    final geo = _geo;
    if (geo == null || host.isEmpty || _isLocalhost(host)) return null;
    if (host.contains(':') || RegExp(r'^[0-9.]+$').hasMatch(host)) return geo.country(host);
    if (_hostCountry.containsKey(host)) return _hostCountry[host];
    if (_resolving.add(host)) {
      InternetAddress.lookup(host, type: InternetAddressType.IPv4)
          .then<String?>((a) => a.isEmpty ? null : geo.country(a.first.address), onError: (_) => null)
          .then((code) {
        _hostCountry[host] = code;
        _resolving.remove(host);
        if (mounted) setState(() {});
      });
    }
    return null;
  }

  /// Флаг страны (assets/flags, flag-icons); нет картинки — код буквами.
  static Widget _flag(String code, {double width = 20}) => ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: Image.asset('assets/flags/${code.toLowerCase()}.png',
            width: width,
            height: width * 3 / 4,
            fit: BoxFit.fill,
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, _, _) => _countryCode(code)),
      );

  static Widget _countryCode(String code) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.withValues(alpha: 0.6)),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(code, style: const TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.bold)),
      );

  /// Флаг страны хоста: «lh» — этот компьютер, «?» — страна неизвестна.
  Widget _countryBadge(String host) {
    if (_isLocalhost(host)) {
      return Tooltip(
        message: tr('Localhost: this computer'),
        child: SizedBox(
          width: 20,
          child: Text('(lh)',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.bold)),
        ),
      );
    }
    final code = _country(host);
    if (code == null) {
      return Tooltip(
        message: tr('Unknown country'),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: Image.asset('assets/flags/unknown.png', width: 20, height: 15, fit: BoxFit.fill),
        ),
      );
    }
    return Tooltip(message: '${GeoIp.name(code)} ($code)', child: _flag(code));
  }

  /// Значок причины, по которой не войти: бан, полный сервер, входы закрыты.
  static (IconData, Color) _refuseIcon(int reason) => switch (reason) {
        3 => (Icons.cancel, Colors.redAccent),
        2 => (Icons.group_off, Colors.orangeAccent),
        _ => (Icons.lock_outline, Colors.orangeAccent),
      };

  /// Значки слева от имени сервера: страна, выделенный / обычный, ванильный /
  /// с аддонами, читы, почему не войти, из локального списка. У каждого своё
  /// место, пустое — тоже: имена серверов стоят ровно.
  static const _statusWidth = 24.0 + 5 * 18.0;

  Widget _rowStatus(ServerRow row, ServerInfo? info) {
    Widget slot(IconData? icon, String tip, [Color color = Colors.grey]) => SizedBox(
          width: 18,
          child: icon == null ? null : Tooltip(message: tip, child: Icon(icon, size: 14, color: color)),
        );
    final refuse = info != null && info.refuseReason > 0 ? _refuseIcon(info.refuseReason) : null;
    return Row(
      children: [
        SizedBox(width: 24, child: Align(alignment: Alignment.centerLeft, child: _countryBadge(row.host))),
        info == null
            ? slot(null, '')
            : info.isDedicated
                ? slot(Icons.dns, tr('Dedicated server'))
                : slot(Icons.person_outline, tr('Listen server: the host is playing too')),
        info == null
            ? slot(null, '')
            : info.modified
                ? slot(Icons.extension, tr('Modified: the server has addons'))
                : slot(Icons.verified_outlined, tr('Vanilla: no addons')),
        info != null && info.cheats ? slot(Icons.warning_amber, tr('Cheats on'), Colors.orangeAccent) : slot(null, ''),
        refuse == null ? slot(null, '') : slot(refuse.$1, tr(info!.refuseText), refuse.$2),
        row.fromLocal
            ? slot(
                Icons.history,
                row.lastSeen == null
                    ? tr('From your local list')
                    : tr('From your local list — last online {time}', {'time': _formatTime(row.lastSeen!)}))
            : slot(null, ''),
      ],
    );
  }

  @override
  void initState() {
    super.initState();
    _dl.addListener(_onDownloads);
    ServerBlacklist.instance.load();
    if (_geo == null) {
      GeoIp.load().then((geo) {
        if (geo == null || _geo != null) return;
        _geo = geo;
        if (mounted) setState(() {});
      });
    }
    _search.addListener(() => setState(() {}));
    if (_autoRefreshed.add(game.id)) {
      // После первого кадра: refresh() сразу уведомляет слушателей.
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!store.loaded) await store.load();
        store.refresh();
      });
    }
    // Вернулись на вкладку с выбранным сервером — досчитываем статусы его аддонов.
    final key = _selectedKey;
    if (key != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final info = store.rowByKey(key)?.result?.info;
        if (mounted && info != null) _checkLocalFiles(info);
      });
    }
  }

  @override
  void dispose() {
    // Скачивание не прерываем: оно продолжается в ServerDownloads.
    _dl.removeListener(_onDownloads);
    _search.dispose();
    super.dispose();
  }

  // --- Список ---

  List<ServerRow> _visibleRows() {
    final query = _search.text.trim().toLowerCase();
    final rows = store.rows.where((r) {
      final info = r.result?.info;
      final offline = r.result != null && info == null;
      if (store.favoritesOnly && r.favorite == null) return false;
      if (store.hideEmpty && (info == null || info.players == 0)) return false;
      if (store.hideOffline && offline && r.favorite == null) return false;
      if (store.hideLocal && r.fromLocal && r.favorite == null) return false;
      if (store.hideUnsupported && (r.result?.isUnsupported ?? false) && r.favorite == null) return false;
      if (store.hideIPv6 && r.isIPv6 && r.favorite == null) return false;
      if (r.favorite == null && ServerBlacklist.instance.blocks(r.host, r.port, r.name)) return false;
      if (store.modifiedOnly && !(info?.modified ?? false)) return false;
      if (store.hideModified && (info?.modified ?? false)) return false;
      if (store.shownGametypes.isNotEmpty &&
          (info == null || !store.shownGametypes.contains(info.gametype.toLowerCase()))) {
        return false;
      }
      if (query.isEmpty) return true;
      return r.name.toLowerCase().contains(query) ||
          r.address.toLowerCase().contains(query) ||
          (info?.gametype.toLowerCase().contains(query) ?? false) ||
          (info?.fullMapTitle.toLowerCase().contains(query) ?? false);
    }).toList();

    // Не ответившие серверы — всегда внизу (кроме сортировки по имени).
    int rank(ServerRow r) {
      final info = r.result?.info;
      if (info == null) return r.result == null ? 2 : 3;
      return 0;
    }

    int byName(ServerRow a, ServerRow b) => naturalCompare(a.name, b.name);
    int byPlayers(ServerRow a, ServerRow b) =>
        (a.result?.info?.players ?? -1).compareTo(b.result?.info?.players ?? -1);
    int byPing(ServerRow a, ServerRow b) =>
        (a.result?.pingMs ?? 99999).compareTo(b.result?.pingMs ?? 99999);

    final dir = _sortAscending ? 1 : -1;
    rows.sort((a, b) {
      // Мои серверы — всегда сверху.
      final byFavorite = (a.favorite == null ? 1 : 0).compareTo(b.favorite == null ? 1 : 0);
      if (byFavorite != 0) return byFavorite;
      if (_sortColumn != _SortColumn.name) {
        final byRank = rank(a).compareTo(rank(b));
        if (byRank != 0) return byRank;
      }
      final int primary = switch (_sortColumn) {
        // По умолчанию: больше игроков, меньше пинг.
        _SortColumn.auto => -byPlayers(a, b) != 0 ? -byPlayers(a, b) : byPing(a, b),
        _SortColumn.name => dir * byName(a, b),
        _SortColumn.players => dir * byPlayers(a, b),
        _SortColumn.ping => dir * byPing(a, b),
        _SortColumn.gametype =>
          dir * naturalCompare(a.result?.info?.gametype ?? '', b.result?.info?.gametype ?? ''),
        _SortColumn.map =>
          dir * naturalCompare(a.result?.info?.fullMapTitle ?? '', b.result?.info?.fullMapTitle ?? ''),
      };
      return primary != 0 ? primary : byName(a, b);
    });
    return rows;
  }

  /// Клик по заголовку столбца, как в проводнике: тот же столбец — обратный
  /// порядок, другой — его порядок по умолчанию (игроки — сначала больше).
  void _sortBy(_SortColumn column) {
    setState(() {
      if (_sortColumn == column) {
        _sortAscending = !_sortAscending;
      } else {
        _sortColumn = column;
        _sortAscending = column != _SortColumn.players;
      }
    });
  }

  Widget _header(String label, _SortColumn column) {
    final active = _sortColumn == column;
    return InkWell(
      onTap: () => _sortBy(column),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
          if (active)
            Icon(_sortAscending ? Icons.arrow_upward : Icons.arrow_downward, size: 14),
        ],
      ),
    );
  }

  void _select(ServerRow row) {
    if (_busy) return; // идёт скачивание для выбранного сервера
    setState(() {
      _selectedKey = row.key;
      _local.clear();
      _errors.clear();
    });
    _refreshSelected(row);
  }

  Future<void> _refreshSelected(ServerRow row) async {
    final result = await store.queryServer(row.host, row.port);
    final info = result?.info;
    if (info != null && mounted && _selectedKey == row.key) {
      await _checkLocalFiles(info);
    }
  }

  Future<void> _checkLocalFiles(ServerInfo info) async {
    final root = widget.gameFolder;
    if (root == null) return;
    final token = ++_checkToken;

    final index = _index;
    if (index == null ||
        index.root != root ||
        DateTime.now().difference(index.built) > const Duration(minutes: 1)) {
      if (index != null && index.root != root) _local.clear(); // другая папка (другая игра)
      _index = await LocalFileIndex.shared(root, force: true);
    }

    for (final f in info.files) {
      if (f.isFolder) continue;
      final found = await _index!.find(f);
      if (!mounted || token != _checkToken) return;
      setState(() => _local[f.md5] = found ?? '');
    }
  }

  // --- Диалоги ---

  Future<void> _addServerDialog() async {
    final address = TextEditingController();
    final name = TextEditingController();
    String? error;

    final result = await showDialog<FavoriteServer>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          void submit() {
            final parsed = parseServerAddress(address.text);
            if (parsed == null) {
              setDialogState(() => error = tr('Enter an address like 192.168.1.5 or play.example.com:5029'));
              return;
            }
            Navigator.pop(context, FavoriteServer(host: parsed.$1, port: parsed.$2, name: name.text.trim()));
          }

          return AlertDialog(
            title: Text(tr('Add server')),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: address,
                    autofocus: true,
                    onSubmitted: (_) => submit(),
                    decoration: InputDecoration(
                      labelText: tr('Address'),
                      hintText: tr('host or host:port (default port {port})', {'port': Srb2Protocol.defaultPort}),
                      errorText: error,
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: name,
                    onSubmitted: (_) => submit(),
                    decoration: InputDecoration(
                      labelText: tr('Name (optional)'),
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    tr('Servers in your list are queried directly, even when the master server is down.'),
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
              ElevatedButton(onPressed: submit, child: Text(tr('Add'))),
            ],
          );
        },
      ),
    );
    if (result == null) return;
    store.addFavorite(result);
    setState(() => _selectedKey = result.key);
    final row = store.rowByKey(result.key);
    if (row != null) _select(row);
  }

  // --- Скачивание аддонов сервера ---

  List<_Source> _sourcesFor(ServerFile f, ServerInfo info) =>
      ServerDownloads.sourcesFor(f, info, widget.repoFiles);

  bool _canDownload(ServerFile f, ServerInfo info) => _sourcesFor(f, info).isNotEmpty;

  List<ServerFile> _missing(ServerInfo info) => [
        for (final f in info.files)
          if (!f.isFolder && _local[f.md5] == '') f,
      ];

  List<ServerFile> _missingDownloadable(ServerInfo info) => [
        for (final f in _missing(info))
          if (!_downloading.containsKey(f.md5) && _canDownload(f, info)) f,
      ];

  /// Скачивает [files] в DOWNLOAD. true — все скачаны и не было отмены.
  Future<bool> _download(List<ServerFile> files, ServerInfo info, ServerRow row) => _dl.download(
        files: files,
        info: info,
        key: row.key,
        host: row.host,
        port: row.port,
        serverName: info.name.isEmpty ? row.address : info.name,
        game: game,
        gameFolder: widget.gameFolder,
        repoFiles: widget.repoFiles,
      );

  /// Join: сначала докачивает недостающие аддоны, потом запускает игру.
  /// SRB2 найдёт их в DOWNLOAD по MD5 и не будет качать при подключении.
  Future<void> _join(ServerRow row, {String? executableId}) async {
    if (_busy) return;
    // Кнопка Join — сборкой по умолчанию; стрелка рядом — выбранной.
    executableId ??= widget.launch.defaultExecutable?.id;
    if (widget.gameFolder == null) {
      widget.onJoin(row.address, null, executableId);
      return;
    }

    setState(() => _joiningKey = row.key);
    try {
      // Свежая информация с полным списком аддонов.
      final info = (await store.queryServer(row.host, row.port))?.info ?? row.result?.info;
      if (info == null || !mounted) {
        if (mounted) widget.onJoin(row.address, null, executableId);
        return;
      }
      if (info.files.any((f) => !f.isFolder && !_local.containsKey(f.md5))) {
        await _checkLocalFiles(info);
      }
      if (!mounted) return;

      final missing = _missing(info);
      if (missing.isNotEmpty) {
        final downloadable = [for (final f in missing) if (_canDownload(f, info)) f];
        await _download(downloadable, info, row);
        if (!mounted || _cancel) return;

        final still = _missing(info);
        if (still.isNotEmpty) {
          final go = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              icon: const Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent, size: 36),
              title: Text('${still.length} addon(s) could not be downloaded'),
              content: SizedBox(
                width: 460,
                child: Text(
                  '${still.map((f) => f.name).join('\n')}\n\n'
                  '${tr('The game will try to get them itself when joining, if the server sends them.')}',
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
                ElevatedButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Join anyway'))),
              ],
            ),
          );
          if (go != true) return;
        }
      }
      if (!mounted) return;
      // Все аддоны сервера есть — грузим их заранее, в порядке сервера:
      // SRB2 требует точного совпадения списка загруженных файлов.
      final paths = [for (final f in info.files) if (!f.isFolder) _local[f.md5]];
      final canPreload = info.files.isNotEmpty &&
          info.files.every((f) => !f.isFolder) &&
          paths.every((x) => x != null && x.isNotEmpty);
      widget.onJoin(
        row.address,
        canPreload && store.preloadAddons && store.game.protocol.preloadFiles ? [for (final x in paths) x!] : null,
        executableId,
      );
    } finally {
      if (mounted) setState(() => _joiningKey = null);
    }
  }

  // --- Построение UI ---

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([store, ServerBlacklist.instance]),
      builder: (context, _) {
        final rows = _visibleRows();
        final selected = _selectedKey == null ? null : store.rowByKey(_selectedKey!);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(flex: 3, child: _buildList(rows)),
            const VerticalDivider(width: 1),
            Expanded(
              flex: 2,
              child: selected == null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.dns_outlined, size: 64, color: Colors.grey),
                          SizedBox(height: 16),
                          Text(tr('Select a server to see its players and addons')),
                        ],
                      ),
                    )
                  : _buildDetails(selected),
            ),
          ],
        );
      },
    );
  }

  Widget _buildList(List<ServerRow> rows) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _search,
                  decoration: InputDecoration(
                    hintText: tr('Search by name, map, gametype, address...'),
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(icon: const Icon(Icons.clear, size: 18), onPressed: _search.clear),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: store.refreshing
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh),
                tooltip: tr('Refresh list'),
                onPressed: store.refreshing ? null : store.refresh,
              ),
              IconButton(icon: const Icon(Icons.add), tooltip: tr('Add server to my list'), onPressed: _addServerDialog),
              IconButton(icon: const Icon(Icons.settings_outlined), tooltip: tr('Server settings (master servers, local list)'), onPressed: widget.onOpenSettings),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _filter(tr('My servers'), store.favoritesOnly, (v) => store.favoritesOnly = v,
                        icon: const Icon(Icons.star, size: 16, color: Colors.amber)),
                    _filter(tr('Hide empty'), store.hideEmpty, (v) => store.hideEmpty = v),
                    _filter(tr('Hide offline'), store.hideOffline, (v) => store.hideOffline = v,
                        tooltip: tr('Hide servers that did not answer (your servers are always shown)')),
                    _filter(tr('Hide modified'), store.hideModified, (v) {
                      store.hideModified = v;
                      if (v) store.modifiedOnly = false;
                    }, tooltip: tr('Hide servers with addons loaded')),
                    _filter(tr('Modified'), store.modifiedOnly, (v) {
                      store.modifiedOnly = v;
                      if (v) store.hideModified = false;
                    },
                        tooltip: tr('Only servers with addons loaded')),
                    _filter(tr('Hide local list'), store.hideLocal, (v) => store.hideLocal = v,
                        tooltip: tr('Hide servers that are only in your local list (not on the master server now)')),
                    _gametypeFilter(),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _buildUpdateBanner(),
          _buildMasterStatus(),
          const SizedBox(height: 8),
          _ServerRowLayout(
            header: true,
            star: Tooltip(
              message: tr('Default order'),
              child: InkWell(
                onTap: () => setState(() => _sortColumn = _SortColumn.auto),
                child: Icon(Icons.sort, size: 16,
                    color: _sortColumn == _SortColumn.auto ? Theme.of(context).colorScheme.primary : null),
              ),
            ),
            status: const SizedBox.shrink(),
            name: _header(tr('Name'), _SortColumn.name),
            players: _header(tr('Players'), _SortColumn.players),
            ping: _header(tr('Ping'), _SortColumn.ping),
            gametype: _header(tr('Gametype'), _SortColumn.gametype),
            map: _header('Map', _SortColumn.map),
          ),
          const Divider(height: 8),
          Expanded(
            child: rows.isEmpty
                ? Center(
                    child: Text(
                      store.refreshing ? tr('Loading servers...') : tr('No servers. Refresh the list or add a server.'),
                      style: const TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (context, i) => _buildRow(rows[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _filter(String label, bool value, void Function(bool v) set, {Widget? icon, String? tooltip}) {
    final chip = FilterChip(
      label: Text(label),
      avatar: icon,
      selected: value,
      visualDensity: VisualDensity.compact,
      onSelected: (v) => store.updateOptions((_) => set(v)),
    );
    return tooltip == null ? chip : Tooltip(message: tooltip, child: chip);
  }

  /// Фильтр режимов игры: галочки — показывать только отмеченные режимы;
  /// без галочек показываются все серверы.
  Widget _gametypeFilter() {
    final types = {...store.knownGametypes};
    // Отмеченные показываем в меню, даже если сейчас таких серверов нет.
    final all = [...types, ...store.shownGametypes.where((h) => !types.any((t) => t.toLowerCase() == h))];
    final shown = store.shownGametypes.length;
    return PopupMenuButton<String>(
      tooltip: tr('Show only the checked gametypes'),
      enabled: all.isNotEmpty,
      itemBuilder: (context) => [
        // Неактивный пункт меню не закрывает меню по клику, а галочка внутри
        // переключается — можно отметить несколько режимов подряд.
        for (final g in all)
          PopupMenuItem<String>(
            enabled: false,
            padding: EdgeInsets.zero,
            child: StatefulBuilder(
              builder: (context, setMenuState) => CheckboxListTile(
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                value: store.shownGametypes.contains(g.toLowerCase()),
                title: Text(g, style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
                onChanged: (v) {
                  store.updateOptions((s) {
                    if (v == true) {
                      s.shownGametypes.add(g.toLowerCase());
                    } else {
                      s.shownGametypes.remove(g.toLowerCase());
                    }
                  });
                  setMenuState(() {});
                },
              ),
            ),
          ),
        if (shown > 0) const PopupMenuDivider(),
        if (shown > 0) PopupMenuItem<String>(value: '\u0000clear', child: Text(tr('Clear checkmarks'))),
      ],
      onSelected: (g) {
        if (g == '\u0000clear') store.updateOptions((s) => s.shownGametypes.clear());
      },
      child: Chip(
        visualDensity: VisualDensity.compact,
        avatar: const Icon(Icons.sports_esports, size: 16),
        label: Text(shown == 0 ? tr('Gametype: all') : tr('Gametype: {n} selected', {'n': shown})),
        side: shown == 0 ? null : BorderSide(color: Theme.of(context).colorScheme.primary),
      ),
    );
  }

  /// Вышла новая версия игры (по мастер-серверу или по ответам серверов).
  Widget _buildUpdateBanner() {
    final String? text;
    if (store.gameUpdated) {
      text = tr('{game} {new} is out. The launcher supports {game} {version}: servers of the new version '
          'are marked as incompatible until the launcher is updated. Joining still works if your game is updated.', {
        'game': game.name,
        'new': store.latestRelease!.name,
        'version': game.version,
      });
    } else if (store.newerServers.length >= 3) {
      text = tr('{n} servers run {game} {new}, newer than {version} supported by the launcher. '
          'The game may have been updated.', {
        'n': store.newerServers.length,
        'game': game.name,
        'new': store.newestServerVersion,
        'version': game.version,
      });
    } else {
      text = null;
    }
    if (text == null) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.amber.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.system_update_alt, size: 18, color: Colors.amber),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 12))),
        ],
      ),
    );
  }

  Widget _buildMasterStatus() {
    final time = store.listTime == null ? '' : _formatTime(store.listTime!);
    if (store.usingCache) {
      final errors = store.masterStatus.where((s) => s.error != null).map((s) => '${store.masterName(s.url)}: ${s.error}');
      return Tooltip(
        message: errors.isEmpty ? tr('Saved list') : errors.join('\n'),
        child: Text(
          tr('Master server unavailable — saved list from {time}', {'time': time}),
          style: const TextStyle(fontSize: 12, color: Colors.orangeAccent),
          overflow: TextOverflow.ellipsis,
        ),
      );
    }
    if (store.masterStatus.isNotEmpty && store.masterStatus.every((s) => s.error != null)) {
      return Tooltip(
        message: store.masterStatus.map((s) => '${store.masterName(s.url)}: ${s.error}').join('\n'),
        child: Text(
          tr('Master server unavailable — only your servers are shown'),
          style: TextStyle(fontSize: 12, color: Colors.orangeAccent),
          overflow: TextOverflow.ellipsis,
        ),
      );
    }
    if (store.listTime == null) return const SizedBox.shrink();
    return Text(
      tr('{n} servers · updated {time}', {'n': store.masterList.length, 'time': time}),
      style: const TextStyle(fontSize: 12, color: Colors.grey),
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _buildRow(ServerRow row) {
    final info = row.result?.info;
    final ping = row.result?.pingMs;
    final offline = row.result != null && info == null;
    final dim = offline;
    final style = TextStyle(color: dim ? Colors.grey : null, fontSize: 13);

    return Material(
      color: row.key == _selectedKey
          ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.18)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => _select(row),
        onDoubleTap: info == null || _busy ? null : () => _join(row),
        child: _ServerRowLayout(
          star: row.favorite == null
              ? const SizedBox.shrink()
              : const Icon(Icons.star, size: 16, color: Colors.amber),
          status: _rowStatus(row, info),
          name: srb2Name(row.nameSpans, style: style.copyWith(fontWeight: FontWeight.w600), dim: dim),
          players: _withTooltip(
            (row.result?.botCount ?? 0) > 0 ? tr('{n} bot(s)', {'n': row.result!.botCount}) : null,
            Text(
              info == null
                  ? '—'
                  : '${info.players}/${info.maxPlayers}${(row.result?.botCount ?? 0) > 0 ? ' +${row.result!.botCount}' : ''}',
              style: style,
            ),
          ),
          ping: row.querying && row.result == null
              // Align — иначе ячейка шириной 56 растягивает индикатор в овал.
              ? const Align(
                  alignment: Alignment.centerLeft,
                  child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                )
              : Text(
                  offline ? 'offline' : (ping == null ? '—' : '$ping'),
                  style: style.copyWith(color: offline ? Colors.grey : _pingColor(ping)),
                ),
          gametype: Text(info?.gametype ?? '', style: style, overflow: TextOverflow.ellipsis),
          map: srb2Text(info?.fullMapTitleSpans ?? const [], style: style, dim: dim),
        ),
      ),
    );
  }

  /// Сведения сервера, для которых уже запущена проверка «есть ли у вас».
  ServerInfo? _localCheckedFor;

  Widget _buildDetails(ServerRow row) {
    final result = row.result;
    final info = result?.info;
    // Сведения пришли, а файлы ещё не проверены (например, сервер только что
    // добавлен через «+»: его второй опрос вернулся без сведений, пока шёл
    // первый, и проверка не запустилась — «Проверка…» висела) — проверяем.
    if (info != null &&
        widget.gameFolder != null &&
        !identical(info, _localCheckedFor) &&
        info.files.any((f) => !f.isFolder && !_local.containsKey(f.md5))) {
      _localCheckedFor = info;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _selectedKey == row.key) _checkLocalFiles(info);
      });
    }
    final players = result?.players ?? const <ServerPlayer>[];
    final pingMs = result?.pingMs;
    final isFav = store.isFavorite(row.host, row.port);
    final accent = Theme.of(context).colorScheme.primary;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            Expanded(
              child: srb2Name(row.nameSpans, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            ),
            IconButton(
              icon: Icon(isFav ? Icons.star : Icons.star_border, color: isFav ? Colors.amber : null),
              tooltip: isFav ? tr('Remove from my servers') : tr('Add to my servers'),
              onPressed: () => isFav
                  ? store.removeFavorite(row.host, row.port)
                  : store.addFavorite(FavoriteServer(host: row.host, port: row.port, name: row.name)),
            ),
            if (!isFav)
              IconButton(
                icon: const Icon(Icons.block),
                tooltip: tr('Add to the blacklist'),
                onPressed: () => _blacklistDialog(row),
              ),
            IconButton(
              icon: row.querying
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh),
              tooltip: tr('Refresh server info'),
              onPressed: row.querying ? null : () => _refreshSelected(row),
            ),
          ],
        ),
        Row(
          children: [
            SelectableText(row.address, style: const TextStyle(color: Colors.grey)),
            IconButton(
              icon: const Icon(Icons.copy, size: 16),
              tooltip: tr('Copy address'),
              visualDensity: VisualDensity.compact,
              onPressed: () {
                Clipboard.setData(ClipboardData(text: row.address));
                showSnack(context, SnackBar(content: Text(tr('Address copied'))));
              },
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (info == null && result != null)
          Card(
            color: Colors.orange.withValues(alpha: 0.15),
            child: ListTile(
              leading: const Icon(Icons.cloud_off, color: Colors.orangeAccent),
              title: Text(tr('No answer from the server')),
              subtitle: Text(result.error == 'No response'
                  ? tr('The server is offline, the address is wrong or the port is blocked.')
                  : tr(result.error ?? '')),
            ),
          ),
        if (info == null && result == null)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
        if (info != null) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildMapPicture(row, info),
              const SizedBox(width: 12),
              Expanded(
                child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _chip(Icons.sports_esports, info.gametype),
              _chip(Icons.map_outlined, info.fullMapTitle, spans: [
                if (info.mapName.isNotEmpty) Srb2TextSpan('${info.mapName} · ', 0),
                ...info.fullMapTitleSpans,
              ]),
              _chip(Icons.people_outline, '${info.players}/${info.maxPlayers} players'),
              if ((result?.botCount ?? 0) > 0) _chip(Icons.smart_toy_outlined, tr('{n} bot(s)', {'n': result!.botCount})),
              if (pingMs != null) _chip(Icons.network_ping, '$pingMs ms', color: _pingColor(pingMs)),
              // Просто версия сервера: какая версия игры стоит у вас, лаунчер не знает.
              _chip(Icons.info_outline, 'v${info.versionString}'),
              if (info.avgPowerLevel != null) _chip(Icons.bolt, tr('Power level {n}', {'n': info.avgPowerLevel})),
              if (info.refuseReason == 0) _chip(Icons.lock_open, tr(info.refuseText), color: Colors.green),
              if (info.refuseReason > 0)
                _chip(_refuseIcon(info.refuseReason).$1, tr(info.refuseText), color: _refuseIcon(info.refuseReason).$2),
              info.isDedicated
                  ? _chip(Icons.dns, tr('Dedicated'))
                  : _chip(Icons.person_outline, tr('Listen server'),
                      tooltip: tr('Listen server: the host is playing too')),
              info.modified ? _chip(Icons.extension, tr('Modified')) : _chip(Icons.verified_outlined, tr('Vanilla')),
              info.cheats
                  ? _chip(Icons.warning_amber, tr('Cheats on'), color: Colors.orangeAccent)
                  : _chip(Icons.shield_outlined, tr('Cheats off')),
              if (_isLocalhost(row.host))
                _chip(Icons.computer, tr('Localhost: this computer'))
              else if (_country(row.host) case final code?)
                _chip(Icons.public, '${GeoIp.name(code)} ($code)', avatar: _flag(code, width: 18))
              else
                _chip(Icons.public, tr('Unknown country'),
                    avatar: Image.asset('assets/flags/unknown.png', width: 18, height: 13.5, fit: BoxFit.fill)),
              _chip(Icons.timer_outlined, tr('Map time {time}', {'time': _formatDuration(info.levelTimeTics ~/ 35)})),
            ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              // Составная кнопка: «Подключиться» — сборкой по умолчанию,
              // стрелка — выбрать другую сборку.
              BuildSplitButton(
                launch: widget.launch,
                label: tr('Join'),
                buttonTooltip: _missingDownloadable(info).isEmpty
                    ? tr('Start the game and connect')
                    : tr('Download {n} missing addon(s), then connect', {'n': _missingDownloadable(info).length}),
                menuTooltip: tr('Join with another build'),
                enabled: !_busy && _joiningKey == null,
                busy: _joiningKey == row.key,
                onPressed: (id) => _join(row, executableId: id),
              ),
              const SizedBox(width: 12),
              if (!_busy && _missingDownloadable(info).isNotEmpty)
                OutlinedButton.icon(
                  icon: const Icon(Icons.download),
                  label: Text(tr('Download missing ({n})', {'n': _missingDownloadable(info).length})),
                  onPressed: () => _download(_missingDownloadable(info), info, row),
                ),
            ],
          ),
          const SizedBox(height: 4),
          // BlanKart грузит аддоны сервера только сам (compatmode) — галочки нет.
          if (store.game.protocol.preloadFiles)
          Tooltip(
            message: tr('On: the launcher starts the game with the server\'s addons (-file, in the server\'s order) '
                'and then connects, so the game does not load them while joining.\n'
                'Off: the game connects first and loads the addons itself (the "Loading addons" screen).\n'
                'Missing addons are downloaded before joining in both cases.'),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Checkbox(
                  value: store.preloadAddons,
                  visualDensity: VisualDensity.compact,
                  onChanged: (v) => store.updateOptions((s) => s.preloadAddons = v ?? true),
                ),
                Text(tr('Load addons into the game before connecting')),
              ],
            ),
          ),
          // Ход скачивания — у того сервера, для которого оно идёт.
          if (_busy && _dl.serverKey == row.key) ...[
            const SizedBox(height: 12),
            _buildBatchBanner(info),
          ],
          const SizedBox(height: 20),
          _sectionTitle(tr('Players ({n})', {'n': players.length}), accent),
          if (players.isEmpty)
            Text(tr('Nobody is playing right now.'), style: TextStyle(color: Colors.grey))
          else
          if ((result?.botCount ?? 0) > 0 && !(result?.allBots ?? false))
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                tr('{bots} of them are bots. The server does not say which ones.', {'bots': result!.botCount}),
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
          FutureBuilder<(List<CharacterInfo>, int)?>(
            future: _serverCharacters(info),
            builder: (context, snap) => Column(
              children: [
                for (final pl in players)
                  _buildPlayer(pl, info,
                      bot: result?.allBots ?? false, characters: snap.data?.$1, certain: snap.data?.$2 ?? 0),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _sectionTitle(tr('Addons ({n})', {'n': info.files.length}), accent),
          if (widget.gameFolder == null)
            Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(tr('Set the game folder in Settings to see which addons you already have.'),
                  style: TextStyle(color: Colors.orangeAccent, fontSize: 12)),
            ),
          if (info.files.isEmpty)
            Text(tr('The server runs without addons.'), style: TextStyle(color: Colors.grey))
          else
            for (final f in info.files) _buildFile(f, info, row),
          const SizedBox(height: 12),
          Text(
            !game.hasHttpSource
                ? tr('Join downloads missing addons first: from your repositories by MD5 or from the server itself '
                    '(like the game does). Files go to {dir}, where the game finds them by MD5 and does not download '
                    'them again.', {'dir': game.downloadPath.join('/')})
                : tr('Join downloads missing addons first: from your repositories by MD5, from the server\'s HTTP mirror{mirror} '
                'or from the server itself (like the game does). Files go to {dir}, where the game finds them '
                'by MD5 and does not download them again.', {
              'mirror': ServerFileDownloader.isUsableMirror(info.httpSource) ? ' (${info.httpSource})' : '',
              'dir': game.downloadPath.join('/'),
            }),
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ],
    );
  }

  static Widget _withTooltip(String? message, Widget child) =>
      message == null ? child : Tooltip(message: message, child: child);

  /// Картинки карт серверов: ключ — карта + файлы, где искали.
  static final Map<String, Future<Uint8List?>> _mapPictures = {};

  /// Картинка текущей карты сервера: из его аддонов, которые у вас есть
  /// (по MD5), затем из файлов игры. Иначе — заглушка «?».
  Widget _buildMapPicture(ServerRow row, ServerInfo info) {
    Widget placeholder() => Image.asset('assets/map_unknown.png',
        width: 160, height: 100, fit: BoxFit.cover, filterQuality: FilterQuality.none);
    final root = widget.gameFolder;
    Widget frame(Widget child) => ClipRRect(borderRadius: BorderRadius.circular(6), child: child);
    if (root == null || (info.mapName.isEmpty && info.mapTitle.isEmpty)) return frame(placeholder());

    // Аддоны сервера в его порядке: последний загруженный заменяет карты.
    final addons = [
      for (final f in info.files)
        if ((_local[f.md5] ?? '').isNotEmpty) _local[f.md5]!,
    ];
    final key = '${game.id}|$root|${info.mapName}|${info.mapTitle}|${addons.join('|')}';
    final future = _mapPictures.putIfAbsent(key, () async {
      try {
        final base = await GameFiles.resolveAsync(game, root, widget.launch, game.baseMapFiles);
        final palettes = await GameFiles.resolveAsync(game, root, widget.launch, game.paletteFiles);
        return await MapScanner.findPictureInBackground(
          files: [...base, ...addons],
          map: info.mapName,
          title: info.mapTitle,
          paletteFiles: palettes,
        );
      } catch (_) {
        return null;
      }
    });
    return frame(FutureBuilder<Uint8List?>(
      future: future,
      builder: (context, snap) {
        final image = snap.data;
        if (image == null) {
          return snap.connectionState == ConnectionState.done
              ? placeholder()
              : const SizedBox(width: 160, height: 100, child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
        }
        return Image.memory(image,
            width: 160,
            height: 100,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.none,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => placeholder());
      },
    ));
  }

  /// Персонажи сервера: [base] — сколько из них из файлов игры.
  static final Map<String, Future<(List<CharacterInfo>, Set<String>)>> _characters = {};

  /// Список скинов сервера в его порядке: файлы игры, затем его аддоны.
  /// Номер скина в списке игроков — индекс в этом списке. Если каких-то
  /// аддонов сервера у вас нет, верны только номера скинов игры.
  static final Map<String, Future<(List<CharacterInfo>, int)?>> _characterViews = {};

  /// Тот же Future для тех же данных — иначе FutureBuilder мигает при перерисовке.
  /// Персонажи сервера: игры и скачанных у вас аддонов сервера, по порядку
  /// (номер в списке — номер скина), и сколько первых из них — наверняка.
  /// Аддоны, которых у вас нет, считаются файлами без персонажей: обычно это
  /// скрипты и карты. Если в них всё же были персонажи, номера после них
  /// сдвинуты — у таких игроков подсказка говорит, что персонаж угадан.
  Future<(List<CharacterInfo>, int)?> _serverCharacters(ServerInfo info) {
    final root = widget.gameFolder;
    if (root == null) return Future.value(null);
    final addons = [
      for (final f in info.files)
        if ((_local[f.md5] ?? '').isNotEmpty) _local[f.md5]!,
    ];
    // Пока у вас проверяются файлы сервера, список меняется с каждым файлом:
    // сканируем один раз, когда проверка закончилась, а до того — прошлый
    // результат этого сервера.
    final server = _selectedKey ?? '';
    final ready = info.files.every((f) => f.isFolder || _local.containsKey(f.md5));
    if (!ready) return _charactersByServer[server] ?? Future.value(null);
    return _charactersByServer[server] = _characterViews.putIfAbsent(
        '${game.id}|$root|${_knownPrefix(info).join('|')}|${addons.join('|')}', () => _loadServerCharacters(info));
  }

  static final Map<String, Future<(List<CharacterInfo>, int)?>> _charactersByServer = {};

  /// Аддоны сервера, что есть у вас, — по порядку до первого, которого нет.
  /// Номера скинов игроков верны для персонажей игры и этих файлов: в
  /// следующих могут быть персонажи, которых мы не видим, и номера сдвинутся.
  List<String> _knownPrefix(ServerInfo info) {
    final out = <String>[];
    for (final f in info.files) {
      if (f.isFolder) continue;
      final local = _local[f.md5] ?? '';
      if (local.isEmpty) break;
      out.add(local);
    }
    return out;
  }

  Future<(List<CharacterInfo>, int)?> _loadServerCharacters(ServerInfo info) async {
    final root = widget.gameFolder;
    if (root == null) return null;
    final addons = [
      for (final f in info.files)
        if ((_local[f.md5] ?? '').isNotEmpty) _local[f.md5]!,
    ];
    final known = _knownPrefix(info).toSet();
    final key = '${game.id}|$root|${addons.join('|')}';
    try {
      final (list, base) = await _characters.putIfAbsent(key, () async {
        final baseFiles = await GameFiles.resolveAsync(game, root, widget.launch, game.baseSkinFiles);
        final palettes = await GameFiles.resolveAsync(game, root, widget.launch, game.paletteFiles);
        // Файл игры в списке сервера (legacy.pk3 и т.п.) уже загружен — второй
        // раз его персонажи не считаются, иначе номера скинов сдвинутся.
        final base = {for (final f in baseFiles) p.canonicalize(f)};
        final extra = [for (final a in addons) if (!base.contains(p.canonicalize(a))) a];
        final list = await CharacterScanner.scanAllInBackground([...baseFiles, ...extra], palettes,
            colors: game.skinColors,
            startColor: game.skinStartColor,
            iconFrames: game.skinIconFrames,
            portraits: game.skinPortraits,
            builtInSonic: game.builtInSonic,
            baseDescriptions: game.vanillaSkinDescriptions ? CharacterScanner.vanillaDescriptions : const {});
        // Номера скинов — в консоль лаунчера: по ним видно, если что-то не сошлось.
        AppLog.console('Server skins (${game.name}): '
            '${[for (var i = 0; i < list.length; i++) '#$i ${list[i].name} (${p.basename(list[i].file)})'].join(', ')}');
        return (list, baseFiles.toSet());
      });
      // Наверняка — персонажи игры и аддонов до первого недостающего файла.
      return (list, list.takeWhile((c) => base.contains(c.file) || known.contains(c.file)).length);
    } catch (_) {
      return null;
    }
  }

  Widget _buildPlayer(ServerPlayer pl, ServerInfo info,
      {bool bot = false, List<CharacterInfo>? characters, int certain = 0}) {
    final bySkin = pl.skin != 255;
    final character = characters == null
        ? null
        : bySkin
            ? (pl.skin < characters.length ? characters[pl.skin] : null)
            : CharacterScanner.findByName(characters, pl.name);
    final guessNote = character == null
        ? null
        : !bySkin
            ? tr('Found by the player\'s name: the server does not report characters')
            : pl.skin >= certain
                ? tr('Probably: you do not have some of the server\'s addons, so the skin number may point '
                    'to another character')
                : null;
    final String team;
    if (bot) {
      team = tr('Bot');
    } else if (pl.isSpectator) {
      team = tr('Spectator');
    } else if (pl.team == 1) {
      team = tr('Red team');
    } else if (pl.team == 2) {
      team = tr('Blue team');
    } else {
      team = tr('Playing');
    }
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: character == null && (bot || !bySkin)
          ? Icon(bot ? Icons.smart_toy_outlined : (pl.isSpectator ? Icons.visibility_outlined : Icons.person),
              color: pl.team == 1 ? Colors.redAccent : (pl.team == 2 ? Colors.lightBlueAccent : null))
          : characterTooltip(
              character,
              fallback: pl.skinName,
              extra: [?guessNote],
              // Описание мешает в списке игроков — только имя (в Аддонах и Запуске — полностью).
              description: false,
              kartStats: game.kartStats,
              Opacity(
                opacity: pl.isSpectator ? 0.5 : 1,
                // Цвет игрока сервер не присылает: в командах — цвет команды,
                // иначе — предпочитаемый цвет персонажа (prefcolor).
                child: CharacterIcon(character,
                    size: 32,
                    ramp: pl.team == 1
                        ? CharacterScanner.findColor(game.skinColors, 'Red')
                        : pl.team == 2
                            ? CharacterScanner.findColor(game.skinColors, 'Blue')
                            : null),
              ),
            ),
      title: Text(pl.name),
      subtitle: Text(() {
        final skin = character?.realname ?? pl.skinName;
        return skin.isEmpty ? team : '$team · $skin';
      }()),
      trailing: Text(
        tr('Score {score}\n{time}', {'score': pl.score, 'time': _formatDuration(pl.secondsInServer)}),
        textAlign: TextAlign.end,
        style: const TextStyle(fontSize: 12, color: Colors.grey),
      ),
    );
  }

  /// Полоса пакетного скачивания (Download missing / Join) с кнопкой отмены.
  Widget _buildBatchBanner(ServerInfo info) {
    double? current;
    String name = '';
    for (final f in info.files) {
      if (_downloading.containsKey(f.md5)) {
        current = _downloading[f.md5];
        name = f.name;
      }
    }
    final overall = _batchTotal == 0 ? null : ((_batchIndex - 1) + (current ?? 0)) / _batchTotal;
    return Card(
      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _joiningKey != null
                        ? tr('Downloading addons before joining ({i}/{n}) {name}', {'i': _batchIndex, 'n': _batchTotal, 'name': name})
                        : tr('Downloading addons ({i}/{n}) {name}', {'i': _batchIndex, 'n': _batchTotal, 'name': name}),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: _cancel ? null : _dl.cancel,
                  child: Text(tr('Cancel')),
                ),
              ],
            ),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: overall?.clamp(0.0, 1.0).toDouble(), minHeight: 6, borderRadius: BorderRadius.circular(3)),
          ],
        ),
      ),
    );
  }

  Widget _buildFile(ServerFile f, ServerInfo info, ServerRow row) {
    final local = _local[f.md5];
    final repo = widget.repoFiles[f.md5];
    final progress = _downloading[f.md5];
    final isDownloading = _downloading.containsKey(f.md5);
    final error = _errors[f.md5];

    Widget leading;
    String status;
    Color? color;
    Widget? trailing;

    if (f.isFolder) {
      leading = const Icon(Icons.folder_outlined, color: Colors.grey);
      status = tr('Folder addon — cannot be downloaded');
      color = Colors.grey;
    } else if (local != null && local.isNotEmpty) {
      leading = const Icon(Icons.check_circle, color: Colors.green);
      status = tr('You have it');
      color = Colors.green;
      trailing = fileActionsMenu(
        enabled: !_busy,
        onSelected: (a) => a == FileAction.showInFolder ? showFileInFolder(context, local) : _deleteLocal(f, local),
      );
    } else if (isDownloading) {
      leading = SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(value: progress, strokeWidth: 2.5),
      );
      final from = switch (_sourceOf[f.md5]) {
        _Source.mirror => tr('the HTTP mirror'),
        _Source.server => tr('the server'),
        _Source.repository => tr('your repository'),
        null => '',
      };
      final percent = progress == null ? '' : ' ${(progress * 100).toStringAsFixed(0)}%';
      status = from.isEmpty ? tr('Downloading...{percent}', {'percent': percent}) : tr('Downloading from {source}...{percent}', {'source': from, 'percent': percent});
    } else if (local == null && widget.gameFolder != null) {
      leading = const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2));
      status = tr('Checking...');
      color = Colors.grey;
    } else {
      // Нет у вас.
      final sources = _sourcesFor(f, info);
      if (sources.isNotEmpty) {
        leading = const Icon(Icons.cloud_download_outlined, color: Colors.lightBlueAccent);
        status = switch (sources.first) {
          _Source.mirror => tr('Missing · available on the server\'s HTTP mirror'),
          _Source.server => tr('Missing · can be downloaded from the server'),
          _Source.repository => tr('Missing · available in repository "{name}"', {'name': repo!.$1.repositorySource}),
        };
        trailing = IconButton(
          icon: const Icon(Icons.download),
          tooltip: tr('Download now'),
          onPressed: _busy ? null : () => _download([f], info, row),
        );
      } else if (f.willSend == ServerFileSend.tooLarge) {
        leading = const Icon(Icons.block, color: Colors.redAccent);
        status = tr('Too large for the server to send — get it elsewhere');
        color = Colors.redAccent;
      } else {
        leading = const Icon(Icons.block, color: Colors.redAccent);
        status = tr('The server does not send it — get it elsewhere');
        color = Colors.redAccent;
      }
    }

    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: leading,
      title: Text(f.name, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${_formatSize(f.size)} · ${FileHash.isMd5(f.md5) ? 'MD5' : 'XXH3'} ${f.md5}',
              style: const TextStyle(fontSize: 11)),
          Tooltip(
            message: local != null && local.isNotEmpty ? local : '',
            child: Text(status, style: TextStyle(fontSize: 12, color: color)),
          ),
          if (error != null)
            Text(tr('Download failed: {error}', {'error': tr(error)}), style: const TextStyle(fontSize: 12, color: Colors.redAccent)),
        ],
      ),
      trailing: trailing,
    );
  }

  /// Удаляет ваш файл аддона сервера (с подтверждением).
  Future<void> _deleteLocal(ServerFile f, String path) async {
    if (!await confirmDeleteFiles(context, [path], tr('Delete "{name}"?', {'name': f.name}))) return;
    try {
      await File(path).delete();
    } catch (e) {
      if (!mounted) return;
      showSnack(context, SnackBar(content: Text(tr('Could not delete:\n{files}', {'files': path})), backgroundColor: Colors.red));
      return;
    }
    final root = widget.gameFolder;
    if (root != null) _index = await LocalFileIndex.shared(root, force: true);
    if (!mounted) return;
    setState(() => _local[f.md5] = '');
  }

  // --- Мелочи ---

  Widget _sectionTitle(String text, Color color) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color)),
      );

  /// В чёрный список: этот сервер, все на его адресе или по слову в имени.
  Future<void> _blacklistDialog(ServerRow row) async {
    final word = TextEditingController();
    var mode = 'server';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) {
          Widget option(String value, String title, [String? subtitle]) => RadioListTile<String>(
                contentPadding: EdgeInsets.zero,
                value: value,
                title: Text(title),
                subtitle: subtitle == null ? null : Text(subtitle),
              );
          final canAdd = mode != 'word' || word.text.trim().isNotEmpty;
          return AlertDialog(
            icon: const Icon(Icons.block, size: 36, color: Colors.redAccent),
            title: Text(tr('Add to the blacklist')),
            content: SizedBox(
              width: 480,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tr('Blacklisted servers are not shown in the list. The blacklist is in Settings → Servers.'),
                      style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 8),
                  RadioGroup<String>(
                    groupValue: mode,
                    onChanged: (v) => setLocal(() => mode = v!),
                    child: Column(
                      children: [
                        option('server', tr('This server'), row.address),
                        option('host', tr('All servers at this IP address'), row.host),
                        option('word', tr('Servers with a word in the name')),
                      ],
                    ),
                  ),
                  if (mode == 'word')
                    Padding(
                      padding: const EdgeInsets.only(left: 16),
                      child: TextField(
                        controller: word,
                        autofocus: true,
                        onChanged: (_) => setLocal(() {}),
                        decoration: InputDecoration(
                          hintText: tr('A word or part of it'),
                          helperText: tr('Case and colors do not matter.'),
                          isDense: true,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
              FilledButton(onPressed: canAdd ? () => Navigator.pop(context, true) : null, child: Text(tr('Add'))),
            ],
          );
        },
      ),
    );
    final text = word.text;
    word.dispose();
    if (ok != true) return;
    final list = ServerBlacklist.instance;
    switch (mode) {
      case 'server':
        await list.addAddress(row.host, row.port);
      case 'host':
        await list.addAddress(row.host);
      default:
        await list.addWord(text);
    }
    if (!mounted) return;
    // Скрытый сервер — снять выбор.
    if (list.blocks(row.host, row.port, row.name)) setState(() => _selectedKey = null);
    showSnack(context, SnackBar(content: Text(tr('Added to the blacklist'))));
  }

  Widget _chip(IconData icon, String label,
      {Color? color, String? tooltip, List<Srb2TextSpan>? spans, Widget? avatar}) {
    final chip = Chip(
      avatar: avatar ?? Icon(icon, size: 16, color: color),
      label: spans == null
          ? Text(label, style: TextStyle(fontSize: 12, color: color))
          : srb2Text(spans, style: TextStyle(fontSize: 12, color: color), maxLines: null, overflow: null),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    return tooltip == null ? chip : Tooltip(message: tooltip, child: chip);
  }

  static Color? _pingColor(int? ping) {
    if (ping == null) return null;
    if (ping < 80) return Colors.green;
    if (ping < 160) return Colors.orangeAccent;
    return Colors.redAccent;
  }

  static String _formatTime(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    final now = DateTime.now();
    final time = '${two(t.hour)}:${two(t.minute)}';
    if (t.year == now.year && t.month == now.month && t.day == now.day) return time;
    return '${two(t.day)}.${two(t.month)}.${t.year} $time';
  }

  static String _formatDuration(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
  }

  static String _formatSize(int bytes) {
    const units = ['B', 'KiB', 'MiB', 'GiB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
  }
}

/// Колонки строки списка серверов (и заголовка).
class _ServerRowLayout extends StatelessWidget {
  final bool header;
  final Widget star;

  /// Значки состояния сервера перед именем (у заголовка — пусто).
  final Widget status;
  final Widget name;
  final Widget players;
  final Widget ping;
  final Widget gametype;
  final Widget map;

  const _ServerRowLayout({
    this.header = false,
    required this.star,
    required this.status,
    required this.name,
    required this.players,
    required this.ping,
    required this.gametype,
    required this.map,
  });

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      child: Row(
        children: [
          SizedBox(width: 22, child: star),
          SizedBox(width: _ServersTabState._statusWidth, child: status),
          Expanded(flex: 5, child: name),
          SizedBox(width: 64, child: players),
          SizedBox(width: 56, child: ping),
          Expanded(flex: 2, child: gametype),
          const SizedBox(width: 8),
          Expanded(flex: 3, child: map),
        ],
      ),
    );
    if (!header) return row;
    return DefaultTextStyle.merge(
      style: const TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold),
      child: row,
    );
  }
}
