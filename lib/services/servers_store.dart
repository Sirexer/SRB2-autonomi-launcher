import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/game.dart';
import '../models/srb2_server.dart';
import 'legacy_master.dart';
import 'srb2_query.dart';

/// Сервер из локального списка (избранное) — работает без мастер-сервера.
class FavoriteServer {
  final String host;
  final int port;
  final String name;
  const FavoriteServer({required this.host, required this.port, this.name = ''});

  String get key => serverKey(host, port);

  Map<String, dynamic> toJson() => {'host': host, 'port': port, 'name': name};

  static FavoriteServer? fromJson(dynamic j) {
    if (j is! Map || j['host'] is! String || j['port'] is! int) return null;
    return FavoriteServer(
      host: j['host'] as String,
      port: j['port'] as int,
      name: j['name'] is String ? j['name'] as String : '',
    );
  }
}

String serverKey(String host, int port) => '${host.toLowerCase()}:$port';

/// Адрес для -connect: IPv6 в квадратных скобках.
String connectAddress(String host, int port) =>
    host.contains(':') ? '[$host]:$port' : '$host:$port';

/// Состояние мастер-сервера после последнего обновления.
class MasterStatus {
  final String url;
  final int? count;
  final String? error;
  const MasterStatus(this.url, {this.count, this.error});
}

/// Строка списка серверов: адрес + что о нём известно.
class ServerRow {
  final String host;
  final int port;
  final MasterServerEntry? master;
  final FavoriteServer? favorite;
  final ServerQueryResult? result;
  final bool querying;

  /// Сервера нет в текущем списке мастер-сервера — он из локального списка.
  final bool fromLocal;

  /// Когда сервер последний раз был в списке мастер-сервера.
  final DateTime? lastSeen;

  const ServerRow({
    required this.host,
    required this.port,
    this.master,
    this.favorite,
    this.result,
    this.querying = false,
    this.fromLocal = false,
    this.lastSeen,
  });

  String get key => serverKey(host, port);
  String get address => connectAddress(host, port);

  /// Адрес IPv6 (в адресе есть «:»).
  bool get isIPv6 => host.contains(':');

  /// Имя с цветами SRB2: из ответа сервера, своё имя из избранного,
  /// имя из списка мастер-сервера или адрес.
  List<Srb2TextSpan> get nameSpans {
    final live = result?.info?.nameSpans;
    if (live != null && live.isNotEmpty) return live;
    if (favorite != null && favorite!.name.isNotEmpty) return [Srb2TextSpan(favorite!.name, 0)];
    final fromMaster = master?.titleSpans;
    if (fromMaster != null && fromMaster.isNotEmpty) return fromMaster;
    return [Srb2TextSpan(address, 0)];
  }

  String get name => Srb2Text.plain(nameSpans);
}

/// Сколько хранить в локальном списке серверы, пропавшие с мастер-сервера.
enum LocalListRetention {
  forever('Never remove', null),
  month('1 month', Duration(days: 30)),
  week('1 week', Duration(days: 7)),
  day('1 day', Duration(days: 1)),
  off("Don't keep", Duration.zero);

  final String label;
  final Duration? keep;
  const LocalListRetention(this.label, this.keep);
}

/// Сервер в локальном списке: что прислал мастер-сервер и когда.
class KnownServer {
  final MasterServerEntry entry;
  final DateTime lastSeen;
  const KnownServer(this.entry, this.lastSeen);

  Map<String, dynamic> toJson() => {...entry.toJson(), 'seen': lastSeen.toIso8601String()};

  static KnownServer? fromJson(dynamic j) {
    final e = MasterServerEntry.fromJson(j);
    final seen = j is Map ? DateTime.tryParse('${j['seen']}') : null;
    return e == null || seen == null ? null : KnownServer(e, seen);
  }
}

/// Данные вкладки Servers: мастер-серверы, избранное, локальный список,
/// фильтры и результаты опроса. У каждой игры — свой экземпляр и свои настройки.
class ServersStore extends ChangeNotifier {
  final GameDef game;

  ServersStore([this.game = Games.srb2])
      : _client = Srb2QueryClient(protocol: game.protocol),
        masters = List.of(game.defaultMasters);

  /// Мастер-сервер SRB2 по умолчанию.
  static const defaultMaster = 'https://ds.ms.srb2.org/MS/0';
  String get _kMasters => game.key('servers_masters');
  String get _kFavorites => game.key('servers_favorites');
  static const _kCache = 'servers_cache'; // старый кэш SRB2, переносится в локальный список
  String get _kKnown => game.key('servers_known');
  String get _kRetention => game.key('servers_retention');
  String get _kOptions => game.key('servers_options');

  final Srb2QueryClient _client;

  /// Адреса мастер-серверов: ссылка http(s) или `хост:порт` (старый
  /// протокол SRB2 2.1, порт 28900).
  List<String> masters;

  /// Выключенные мастер-серверы: остаются в списке, но список серверов с
  /// них не берётся.
  final Set<String> disabledMasters = {};
  String get _kMastersOff => game.key('servers_masters_disabled');

  /// Включённые мастер-серверы — с них берётся список.
  List<String> get activeMasters => [for (final m in masters) if (!disabledMasters.contains(m)) m];

  Future<void> setMasterEnabled(String url, bool enabled) async {
    if (enabled ? !disabledMasters.remove(url) : !disabledMasters.add(url)) return;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kMastersOff, disabledMasters.toList());
  }

  /// Свои названия мастер-серверов: адрес → название.
  final Map<String, String> masterNames = {};
  String get _kMasterNames => game.key('servers_master_names');

  /// Название мастер-сервера: своё, известное (стандартные) или его хост.
  String masterName(String url) {
    final custom = masterNames[url]?.trim() ?? '';
    if (custom.isNotEmpty) return custom;
    final known = Games.masterNames[url];
    if (known != null) return known;
    if (LegacyMaster.isLegacyAddress(url)) return LegacyMaster.parseAddress(url).$1;
    final host = Uri.tryParse(url)?.host ?? '';
    return host.isEmpty ? url : host;
  }

  /// Строки `Название | адрес` (для списка в настройках).
  List<String> get masterLines => [for (final m in masters) '${masterName(m)} | $m'];

  /// Последний известный статус мастер-сервера [url] (null — не проверяли).
  MasterStatus? statusOf(String url) {
    for (final st in masterStatus) {
      if (st.url == url) return st;
    }
    return null;
  }

  /// Проверяемые сейчас мастер-серверы (кнопка «Проверить» в настройках).
  final Set<String> checkingMasters = {};

  /// Проверяет один мастер-сервер: отвечает ли и сколько серверов отдаёт.
  Future<void> checkMaster(String url) async {
    if (!checkingMasters.add(url)) return;
    notifyListeners();
    MasterStatus status;
    try {
      final count = LegacyMaster.isLegacyAddress(url)
          ? (await LegacyMaster.fetchServers(url)).length
          : game.parseServers(await _get(game.serversUrl(url))).length;
      status = MasterStatus(url, count: count);
    } catch (e) {
      status = MasterStatus(url, error: _describe(e));
    }
    masterStatus = [for (final st in masterStatus) if (st.url != url) st, status];
    checkingMasters.remove(url);
    notifyListeners();
  }

  /// Название мастер-сервера [url] (пустое — стандартное или по хосту).
  Future<void> setMasterName(String url, String name) async {
    final n = name.trim();
    if (n.isEmpty || n == Games.masterNames[url]) {
      masterNames.remove(url);
    } else {
      masterNames[url] = n;
    }
    await setMasters(masterLines);
  }

  /// `Название | адрес` или просто адрес → (название, адрес).
  static (String, String) parseMasterLine(String line) {
    final bar = line.indexOf('|');
    if (bar < 0) return ('', line.trim());
    return (line.substring(0, bar).trim(), line.substring(bar + 1).trim());
  }
  final List<FavoriteServer> favorites = [];
  /// Список мастер-сервера, полученный в этом запуске.
  List<MasterServerEntry> masterList = [];
  Map<int, String> rooms = {};
  List<MasterStatus> masterStatus = [];

  /// Локальный список: все серверы, которые были на мастер-сервере.
  final Map<String, KnownServer> known = {};
  LocalListRetention retention = LocalListRetention.month;

  /// Последняя версия игры по данным мастер-сервера (null — не узнали).
  GameRelease? latestRelease;

  /// Вышла версия игры новее той, что поддерживает лаунчер.
  bool get gameUpdated => latestRelease != null && latestRelease!.number > game.modVersion;

  /// Отвечающие серверы той же игры, но версии новее поддерживаемой.
  List<ServerInfo> get newerServers {
    final p = game.protocol;
    return [
      for (final r in results.values)
        if (r.info case final info?)
          if (info.application.toLowerCase() == p.application.toLowerCase() &&
              (info.version > p.version || (info.version == p.version && info.subversion > p.subversion)))
            info,
    ];
  }

  /// Самая новая версия среди [newerServers] ("2.2.16") или null.
  String? get newestServerVersion {
    ServerInfo? best;
    for (final i in newerServers) {
      if (best == null ||
          i.version > best.version ||
          (i.version == best.version && i.subversion > best.subversion)) {
        best = i;
      }
    }
    return best?.versionString;
  }

  /// Время, когда список был получен с мастер-сервера.
  DateTime? listTime;

  /// Мастер-серверы не ответили — показан локальный список.
  bool usingCache = false;

  // Настройки и фильтры вкладки (сохраняются).
  /// Загружать аддоны сервера в игру до подключения (-file + +connect).
  bool preloadAddons = true;
  bool favoritesOnly = false;
  bool hideEmpty = false;
  bool hideOffline = true;
  bool modifiedOnly = false;
  bool hideModified = false;
  bool hideLocal = false;

  /// Скрывать серверы с ошибкой «Unsupported server (different game
  /// version)» — другой версии игры, их не опросить и к ним не подключиться.
  bool hideUnsupported = true;

  /// Скрывать серверы с адресом IPv6: на деле к ним не подключиться, а
  /// опрос только ждёт ответа. Мои серверы показываются всегда.
  bool hideIPv6 = true;

  /// Показывать только эти режимы игры (в нижнем регистре); пусто — все.
  final Set<String> shownGametypes = {};
  bool refreshing = false;
  bool loaded = false;

  final Map<String, ServerQueryResult> results = {};
  final Set<String> _querying = {};

  bool isFavorite(String host, int port) => favorites.any((f) => f.key == serverKey(host, port));
  bool isQuerying(String key) => _querying.contains(key);

  /// Избранное + список мастер-сервера + локальный список, без повторов.
  List<ServerRow> get rows {
    final favs = {for (final f in favorites) f.key: f};
    final current = {for (final m in masterList) serverKey(m.host, m.port): m};
    final keys = <String>{...favs.keys, ...current.keys, ...known.keys};
    return [
      for (final key in keys)
        () {
          final m = current[key] ?? known[key]?.entry;
          final f = favs[key];
          return ServerRow(
            host: m?.host ?? f!.host,
            port: m?.port ?? f!.port,
            master: m,
            favorite: f,
            result: results[key],
            querying: _querying.contains(key),
            fromLocal: !current.containsKey(key) && known.containsKey(key),
            lastSeen: known[key]?.lastSeen,
          );
        }(),
    ];
  }

  /// Режимы игры отвечающих серверов (для фильтра).
  List<String> get knownGametypes {
    final set = <String, String>{};
    for (final r in results.values) {
      final g = r.info?.gametype ?? '';
      if (g.isNotEmpty) set.putIfAbsent(g.toLowerCase(), () => g);
    }
    return set.values.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  ServerRow? rowByKey(String key) {
    for (final r in rows) {
      if (r.key == key) return r;
    }
    return null;
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final savedMasters = prefs.getStringList(_kMasters);
    if (savedMasters != null && savedMasters.isNotEmpty) masters = savedMasters;
    disabledMasters
      ..clear()
      ..addAll(prefs.getStringList(_kMastersOff) ?? const []);
    masterNames.clear();
    try {
      final names = jsonDecode(prefs.getString(_kMasterNames) ?? '{}');
      if (names is Map) names.forEach((k, v) => masterNames['$k'] = '$v');
    } catch (_) {}

    favorites.clear();
    try {
      final raw = prefs.getString(_kFavorites);
      if (raw != null) {
        for (final j in jsonDecode(raw) as List) {
          final f = FavoriteServer.fromJson(j);
          if (f != null) favorites.add(f);
        }
      }
    } catch (_) {}

    retention = LocalListRetention.values.asNameMap()[prefs.getString(_kRetention)] ?? LocalListRetention.month;

    known.clear();
    try {
      final raw = prefs.getString(_kKnown);
      if (raw != null) {
        final j = jsonDecode(raw) as Map;
        for (final e in (j['servers'] as List? ?? const [])) {
          final k = KnownServer.fromJson(e);
          if (k != null) known[serverKey(k.entry.host, k.entry.port)] = k;
        }
        rooms = {
          for (final e in ((j['rooms'] as Map?) ?? const {}).entries)
            if (int.tryParse('${e.key}') case final id?) id: '${e.value}',
        };
        listTime = DateTime.tryParse('${j['time']}');
      } else if (game == Games.srb2) {
        // Перенос старого кэша последнего списка.
        final old = prefs.getString(_kCache);
        if (old != null) {
          final j = jsonDecode(old) as Map;
          final time = DateTime.tryParse('${j['time']}') ?? DateTime.now();
          for (final e in (j['servers'] as List? ?? const [])) {
            final entry = MasterServerEntry.fromJson(e);
            if (entry != null) known[serverKey(entry.host, entry.port)] = KnownServer(entry, time);
          }
          listTime = time;
        }
      }
    } catch (_) {}
    _pruneKnown();
    usingCache = known.isNotEmpty;

    try {
      final raw = prefs.getString(_kOptions);
      if (raw != null) {
        final j = jsonDecode(raw) as Map;
        bool flag(String k, bool def) => j[k] is bool ? j[k] as bool : def;
        preloadAddons = flag('preloadAddons', true);
        favoritesOnly = flag('favoritesOnly', false);
        hideEmpty = flag('hideEmpty', false);
        hideOffline = flag('hideOffline', true);
        modifiedOnly = flag('modifiedOnly', false);
        hideModified = flag('hideModified', false);
        hideLocal = flag('hideLocal', false);
        hideUnsupported = flag('hideUnsupported', true);
        hideIPv6 = flag('hideIPv6', true);
        shownGametypes
          ..clear()
          ..addAll((j['shownGametypes'] as List? ?? const []).map((e) => '$e'));
      }
    } catch (_) {}

    loaded = true;
    notifyListeners();
  }

  /// Убирает из локального списка серверы старше срока хранения.
  void _pruneKnown() {
    final keep = retention.keep;
    if (keep == null) return;
    final limit = DateTime.now().subtract(keep);
    known.removeWhere((_, k) => keep == Duration.zero || k.lastSeen.isBefore(limit));
  }

  Future<void> _saveKnown() async {
    final prefs = await SharedPreferences.getInstance();
    if (retention == LocalListRetention.off) {
      await prefs.remove(_kKnown);
      return;
    }
    await prefs.setString(
      _kKnown,
      jsonEncode({
        'time': listTime?.toIso8601String(),
        'servers': known.values.map((k) => k.toJson()).toList(),
        'rooms': rooms.map((k, v) => MapEntry('$k', v)),
      }),
    );
    await prefs.remove(_kCache);
  }

  Future<void> setRetention(LocalListRetention value) async {
    retention = value;
    _pruneKnown();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kRetention, value.name);
    await _saveKnown();
  }

  /// Меняет настройку/фильтр и сохраняет все настройки вкладки.
  Future<void> updateOptions(void Function(ServersStore s) change) async {
    change(this);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kOptions,
      jsonEncode({
        'preloadAddons': preloadAddons,
        'favoritesOnly': favoritesOnly,
        'hideEmpty': hideEmpty,
        'hideOffline': hideOffline,
        'modifiedOnly': modifiedOnly,
        'hideModified': hideModified,
        'hideLocal': hideLocal,
        'hideUnsupported': hideUnsupported,
        'hideIPv6': hideIPv6,
        'shownGametypes': shownGametypes.toList(),
      }),
    );
  }

  /// [lines] — `Название | адрес` или просто адрес, по одному на строку.
  Future<void> setMasters(List<String> lines) async {
    final urls = <String>[];
    masterNames.clear();
    for (final line in lines) {
      final (name, url) = parseMasterLine(line);
      if (url.isEmpty || urls.contains(url)) continue;
      urls.add(url);
      // Стандартное название не храним: оно и так известно.
      if (name.isNotEmpty && name != Games.masterNames[url]) masterNames[url] = name;
    }
    masters = urls.isEmpty ? List.of(game.defaultMasters) : urls;
    disabledMasters.retainAll(masters);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kMasters, masters);
    await prefs.setStringList(_kMastersOff, disabledMasters.toList());
    await prefs.setString(_kMasterNames, jsonEncode(masterNames));
  }

  Future<void> _saveFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kFavorites, jsonEncode(favorites.map((f) => f.toJson()).toList()));
  }

  void addFavorite(FavoriteServer f) {
    favorites.removeWhere((x) => x.key == f.key);
    favorites.add(f);
    notifyListeners();
    _saveFavorites();
    queryServer(f.host, f.port);
  }

  void removeFavorite(String host, int port) {
    favorites.removeWhere((f) => f.key == serverKey(host, port));
    notifyListeners();
    _saveFavorites();
  }

  /// Обновляет список с мастер-серверов и опрашивает все серверы.
  Future<void> refresh() async {
    if (refreshing) return;
    refreshing = true;
    notifyListeners();

    await _checkVersion();
    // У Kart Krew список свой для каждой версии: если игра обновилась,
    // берём и список новой версии — серверы не пропадут до обновления лаунчера.
    final modVersions = {
      game.modVersion,
      if (game.masterApi == MasterApi.kart && gameUpdated) latestRelease!.number,
    };

    final statuses = <MasterStatus>[];
    final merged = <String, MasterServerEntry>{};
    final mergedRooms = <int, String>{};
    await Future.wait([
      for (final url in activeMasters)
        () async {
          try {
            var count = 0;
            if (LegacyMaster.isLegacyAddress(url)) {
              // Старый мастер-сервер 2.1 (TCP): список и комнаты одним протоколом.
              final list = await LegacyMaster.fetchServers(url);
              for (final e in list) {
                merged.putIfAbsent(serverKey(e.host, e.port), () => e);
              }
              statuses.add(MasterStatus(url, count: list.length));
              try {
                mergedRooms.addAll(await LegacyMaster.fetchRooms(url));
              } catch (_) {} // названия комнат — не обязательно
              return;
            }
            for (final mv in modVersions) {
              final List<MasterServerEntry> list;
              try {
                list = game.parseServers(await _get(game.serversUrl(url, modVersion: mv)));
              } catch (_) {
                if (mv == game.modVersion) rethrow;
                continue; // список новой версии — не обязателен
              }
              for (final e in list) {
                merged.putIfAbsent(serverKey(e.host, e.port), () => e);
              }
              count += list.length;
            }
            statuses.add(MasterStatus(url, count: count));
            if (game.hasRooms) {
              try {
                mergedRooms.addAll(MasterServerParser.parseRooms(await _get('$url/rooms')));
              } catch (_) {} // названия комнат — не обязательно
            }
          } catch (e) {
            statuses.add(MasterStatus(url, error: _describe(e)));
          }
        }(),
    ]);

    masterStatus = statuses;
    if (statuses.any((s) => s.error == null)) {
      final now = DateTime.now();
      masterList = merged.values.toList();
      rooms = mergedRooms;
      listTime = now;
      usingCache = false;
      for (final e in masterList) {
        final key = serverKey(e.host, e.port);
        // Мастер-сервер Ring Racers не присылает имён — оставляем запомненное.
        final oldTitle = known[key]?.entry.title ?? '';
        // Время в списке — когда сервер последний раз был в сети (ответил на
        // запрос), а не когда был на мастер-сервере: там бывают и мёртвые.
        // Новый сервер — с текущим временем (его сразу опросим).
        known[key] = KnownServer(
            e.title.isEmpty && oldTitle.isNotEmpty ? e.withTitle(oldTitle) : e, known[key]?.lastSeen ?? now);
      }
      _pruneKnown();
      _saveKnown();
    } else {
      usingCache = known.isNotEmpty;
    }
    notifyListeners();

    await queryAll();
    if (_knownChanged) {
      _knownChanged = false;
      _saveKnown();
    }
    refreshing = false;
    notifyListeners();
  }

  /// Комнаты мастер-сервера [master] (id → название) — для выбора Room ID
  /// своего сервера; без [master] — всех включённых. Ошибки — исключение.
  Future<Map<int, String>> fetchRooms([String? master]) async {
    final urls = master == null || master.trim().isEmpty ? activeMasters : [master.trim()];
    final out = <int, String>{};
    Object? lastError;
    for (final url in urls) {
      try {
        out.addAll(LegacyMaster.isLegacyAddress(url)
            ? await LegacyMaster.fetchRooms(url)
            : MasterServerParser.parseRooms(await _get('$url/rooms')));
      } catch (e) {
        lastError = e;
      }
    }
    if (out.isEmpty && lastError != null) throw lastError;
    if (master == null) rooms = {...rooms, ...out};
    return out;
  }

  /// Узнаёт у мастер-серверов последнюю версию игры (как игра при запуске).
  Future<void> _checkVersion() async {
    for (final url in activeMasters) {
      if (LegacyMaster.isLegacyAddress(url)) continue; // версию сообщают только HTTP-серверы
      try {
        final release = GameDef.parseVersion(await _get(game.versionUrl(url)));
        if (release != null) {
          latestRelease = release;
          return;
        }
      } catch (_) {
        // Не ответил — пробуем следующий; без версии всё работает как раньше.
      }
    }
  }

  static String _describe(Object e) {
    if (e is TimeoutException) return 'timed out';
    if (e is SocketException) return e.osError?.message ?? e.message;
    if (e is HttpException) return e.message;
    if (e is FormatException) return e.message;
    return '$e';
  }

  Future<String> _get(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..userAgent = 'SRB2AutonomiLauncher (${game.name} ${game.version} compatible)';
    try {
      final request = await client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 10));
      final response = await request.close().timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
      }
      return await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 15));
    } finally {
      client.close(force: true);
    }
  }

  /// Опрашивает все серверы списка (не больше 16 одновременно).
  Future<void> queryAll() async {
    _bulk = true;
    // Скрытые IPv6-серверы не опрашиваем (кроме своих).
    final queue = [for (final r in rows) if (!hideIPv6 || !r.isIPv6 || r.favorite != null) (r.host, r.port)];
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final (host, port) = queue.removeLast();
        await queryServer(host, port, fullFileList: false);
      }
    }

    try {
      await Future.wait([for (var i = 0; i < 16; i++) worker()]);
    } finally {
      _bulk = false;
    }
  }

  /// Идёт опрос всех серверов: локальный список сохраняется один раз в конце.
  bool _bulk = false;

  /// Сервер ответил — он в сети: обновляем время в локальном списке.
  void _markOnline(String key) {
    final k = known[key];
    if (k == null) return;
    known[key] = KnownServer(k.entry, DateTime.now());
    _knownChanged = true;
  }

  /// Опрашивает один сервер. Для карточки сервера — с полным списком аддонов.
  Future<ServerQueryResult?> queryServer(String host, int port, {bool fullFileList = true}) async {
    final key = serverKey(host, port);
    if (!_querying.add(key)) return results[key];
    notifyListeners();
    try {
      final result = await _client.query(host, port, fullFileList: fullFileList);
      // Не затираем полный список аддонов коротким при общем обновлении.
      final old = results[key];
      final keepFullFiles = !fullFileList &&
          result.info != null &&
          result.info!.hasMoreFiles &&
          old?.info != null &&
          old!.info!.files.length > result.info!.files.length;
      results[key] = keepFullFiles
          ? ServerQueryResult(
              info: result.info!.withFiles(old.info!.files),
              players: result.players,
              pingMs: result.pingMs,
            )
          : result;
      _rememberName(key, result.info);
      if (result.info != null) _markOnline(key);
      return results[key];
    } finally {
      _querying.remove(key);
      if (!_bulk && _knownChanged) {
        _knownChanged = false;
        _saveKnown();
      }
      notifyListeners();
    }
  }

  /// Локальный список изменился (имя или время в сети) — сохранить.
  bool _knownChanged = false;

  /// Мастер-сервер без имён (Ring Racers): запоминаем имя из ответа сервера,
  /// чтобы локальный список показывал его и когда сервер не отвечает.
  void _rememberName(String key, ServerInfo? info) {
    final k = known[key];
    if (k == null || info == null || info.name.isEmpty || game.masterApi != MasterApi.kart) return;
    if (k.entry.title == info.name) return;
    known[key] = KnownServer(k.entry.withTitle(info.name), k.lastSeen);
    final m = masterList.indexWhere((e) => serverKey(e.host, e.port) == key);
    if (m >= 0) masterList[m] = masterList[m].withTitle(info.name);
    _knownChanged = true;
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }
}
