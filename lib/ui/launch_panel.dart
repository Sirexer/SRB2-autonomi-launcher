import 'dart:convert';
import 'dart:io';

import '../services/app_log.dart';
import '../i18n.dart';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/game.dart';
import '../models/launch_config.dart';
import '../services/launch_settings.dart';
import '../services/addon_contents.dart';
import '../services/characters.dart';
import '../services/map_preview.dart';
import '../services/platform_utils.dart';
import 'character_picker.dart';
import 'color_picker.dart';
import 'gametype_choice.dart';
import 'kept_scroll.dart';
import 'map_picker.dart';
import 'sound.dart';
import 'snack.dart';
import 'srb2_text.dart';

const _argStyle = TextStyle(
  fontSize: 11,
  color: Colors.grey,
  fontFamily: 'monospace',
  fontFamilyFallback: ['Consolas', 'DejaVu Sans Mono'],
);

/// Команда или переменная консоли SRB2 из справочника (assets/console_reference.json,
/// собран из вики SRB2: Console Commands / Console Variables).
class ConsoleRef {
  final String name;
  final bool isVariable;
  final String args;
  final String section;
  final String description;
  const ConsoleRef(this.name, this.isVariable, this.args, this.section, this.description);

  static Future<List<ConsoleRef>>? _cache;

  static Future<List<ConsoleRef>> load() => _cache ??= () async {
        try {
          final raw = jsonDecode(await rootBundle.loadString('assets/console_reference.json')) as List;
          return [
            for (final j in raw)
              if (j is Map && j['name'] is String)
                ConsoleRef(
                  j['name'] as String,
                  j['kind'] == 'var',
                  '${j['args'] ?? ''}',
                  '${j['section'] ?? ''}',
                  '${j['desc'] ?? ''}',
                ),
          ]..sort((a, b) => a.name.compareTo(b.name));
        } catch (_) {
          return <ConsoleRef>[];
        }
      }();
}

/// Панель параметров запуска (вкладка Launch и Settings → Launch).
class LaunchOptionsPanel extends StatefulWidget {
  final LaunchSettings settings;

  /// Есть ли файлы в очереди (для предупреждения про режим Join).
  final bool queueHasFiles;

  /// Очередь аддонов для профилей; null — профили не показываются.
  final List<String> Function()? getQueue;
  final ValueChanged<List<String>>? setQueue;

  /// Карты для выбора -warp (игра + очередь); null — без кнопки выбора.
  final Future<List<MapPreview>> Function()? loadMaps;

  /// Персонажи для выбора +skin (игра + очередь); null — без кнопки.
  final Future<List<CharacterInfo>> Function()? loadCharacters;

  /// Свои режимы игры из аддонов очереди (для списка -gametype).
  final Future<List<GametypeInfo>> Function()? loadGametypes;

  /// Цвета для выбора +color (игра + очередь); null — без кнопки.
  final Future<List<SkinColorChoice>> Function()? loadColors;

  /// Мастер-серверы игры из настроек Servers: (название, адрес) — для
  /// выбора, где объявить свой сервер.
  final List<(String, String)> masters;

  /// Комнаты мастер-сервера (адрес; '' — все включённые): id → название —
  /// для выбора Room ID. null — без кнопки выбора.
  final Future<Map<int, String>> Function(String master)? loadRooms;

  /// Прокрутка панели (своя у вкладки — сохраняется при смене вкладок).
  final ScrollController? scrollController;

  const LaunchOptionsPanel({
    super.key,
    required this.settings,
    required this.queueHasFiles,
    this.getQueue,
    this.setQueue,
    this.loadMaps,
    this.loadCharacters,
    this.loadGametypes,
    this.loadColors,
    this.masters = const [],
    this.loadRooms,
    this.scrollController,
  });

  @override
  State<LaunchOptionsPanel> createState() => _LaunchOptionsPanelState();
}

class _LaunchOptionsPanelState extends State<LaunchOptionsPanel> {
  LaunchSettings get s => widget.settings;
  LaunchOptions get o => s.options;

  late final _width = TextEditingController(text: o.width);
  late final _height = TextEditingController(text: o.height);
  late final _warp = TextEditingController(text: o.warpMap);
  late final _address = TextEditingController(text: o.joinAddress);
  late final _room = TextEditingController(text: o.room);
  late final _password = TextEditingController(text: o.adminPassword);
  late final _gametype = TextEditingController(text: o.gametype);
  late final _extra = TextEditingController(text: s.extraParams);
  final _consoleInput = TextEditingController();
  final _consoleFocus = FocusNode();
  List<ConsoleRef> _refs = const [];

  /// Свои режимы игры из аддонов очереди.
  List<GametypeInfo> _customGametypes = const [];

  Future<void> _loadGametypes() async {
    final load = widget.loadGametypes;
    if (load == null) return;
    try {
      final list = await load();
      final seen = <String>{};
      if (mounted) setState(() => _customGametypes = [for (final g in list) if (seen.add(g.name.toLowerCase())) g]);
    } catch (_) {}
  }

  /// Поля -warp, -gametype, +skin и +color следуют за настройками, когда их
  /// меняют не здесь (выбор на вкладке Addons, сброс после удаления аддона).
  late String _lastSkin = _cvar('skin');
  late String _lastColor = _cvar('color');

  final _ownScroll = KeptScrollController();

  /// Карта -warp (её TypeOfLevel — какие режимы она берёт); null — не выбрана
  /// или не нашлась.
  MapPreview? _warpMap;
  String _warpMapFor = '\u0000';

  /// Ищет выбранную карту среди карт игры и очереди.
  Future<void> _refreshWarpMap() async {
    final want = o.warpMap.trim().toUpperCase();
    if (want == _warpMapFor) return;
    _warpMapFor = want;
    MapPreview? found;
    final load = widget.loadMaps;
    if (want.isNotEmpty && load != null) {
      try {
        final name = MapScanner.socLevelMap(want) ?? want;
        for (final m in await load()) {
          if (m.map == name || m.map == want) found = m;
        }
      } catch (_) {}
    }
    if (mounted && want == _warpMapFor) setState(() => _warpMap = found);
  }

  void _onSettingsChanged() {
    if (!mounted) return;
    if (_warp.text != o.warpMap) _warp.text = o.warpMap;
    if (_gametype.text != o.gametype) _gametype.text = o.gametype;
    final skin = _cvar('skin'), color = _cvar('color');
    if (skin != _lastSkin || color != _lastColor) {
      _lastSkin = skin;
      _lastColor = color;
      setState(() => _quickRev++); // поля +skin/+color пересоздаются с новым значением
    }
    _refreshWarpMap();
  }

  @override
  void didUpdateWidget(covariant LaunchOptionsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.settings, widget.settings)) {
      // Другая игра — свои настройки: поля берут её значения.
      oldWidget.settings.removeListener(_onSettingsChanged);
      widget.settings.addListener(_onSettingsChanged);
      _syncControllers();
      _lastSkin = _cvar('skin');
      _lastColor = _cvar('color');
      _quickRev++;
      _customGametypes = const [];
      _loadGametypes();
      _warpMapFor = '\u0000';
      _warpMap = null;
      _refreshWarpMap();
    }
  }

  @override
  void initState() {
    super.initState();
    s.addListener(_onSettingsChanged);
    _loadGametypes();
    _refreshWarpMap();
    ConsoleRef.load().then((refs) {
      if (mounted) setState(() => _refs = refs);
    });
  }

  @override
  void dispose() {
    s.removeListener(_onSettingsChanged);
    for (final c in [_width, _height, _warp, _address, _room, _password, _gametype, _extra, _consoleInput]) {
      c.dispose();
    }
    _consoleFocus.dispose();
    _ownScroll.dispose();
    super.dispose();
  }

  /// После выбора профиля поля ввода берут новые значения.
  void _syncControllers() {
    _width.text = o.width;
    _height.text = o.height;
    _warp.text = o.warpMap;
    _address.text = o.joinAddress;
    _room.text = o.room;
    _password.text = o.adminPassword;
    _gametype.text = o.gametype;
    _extra.text = s.extraParams;
  }

  @override
  Widget build(BuildContext context) {
    // Не ListView: ленивый список меряет только видимое, и ползунок прыгает
    // (как было на вкладке Addons). Поля строятся все сразу — их немного.
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => SingleChildScrollView(
        controller: widget.scrollController ?? _ownScroll,
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.setQueue != null) ..._buildProfiles(),

          ..._group('video', tr('Video'), () => [
            _choices<RendererMode>(
              value: o.renderer,
              options: [
                (RendererMode.auto, tr('Auto'), tr('Renderer from the game config')),
                (RendererMode.opengl, 'OpenGL', '-opengl'),
                (RendererMode.software, tr('Software'), '-software'),
              ],
              onChanged: (v) => s.updateOptions((o) => o.renderer = v),
            ),
            _flag(LaunchFlags.windowed),
            _flag(LaunchFlags.borderless),
            _check(
              label: tr('Custom resolution'),
              arg: '-width -height',
              hint: tr('Force the window/screen size.'),
              value: o.customResolution,
              onChanged: (v) => s.updateOptions((o) => o.customResolution = v),
            ),
            if (o.customResolution)
              _fieldRow([
                _field(_width, tr('Width'), hint: '1280', digits: true, onChanged: (o, v) => o.width = v),
                const Text('×'),
                _field(_height, tr('Height'), hint: '720', digits: true, onChanged: (o, v) => o.height = v),
              ]),
          ]),

          ..._group('audio', tr('Audio'), () => [
            _flag(LaunchFlags.noSound),
            _flag(LaunchFlags.noMusic),
          ]),

          ..._group('game', tr('Game'), () => [
            _flag(LaunchFlags.skipIntro),
            // -warp — без отдельной галочки: карта указана — передаётся, пусто — нет.
            // Кнопки (очистить, выбрать карту) — внутри поля, на одной линии с ним;
            // под полем — название выбранного уровня.
            _fieldRow([
                Tooltip(
                  message: tr('Start the game right on this map (e.g. MAP01 or 1). Empty — the game starts as usual.'),
                  waitDuration: const Duration(milliseconds: 600),
                  child: SizedBox(
                    width: 340,
                    child: TextField(
                      controller: _warp,
                      onChanged: (v) => s.updateOptions((o) => o.warpMap = v),
                      decoration: InputDecoration(
                        labelText: tr('Warp to map'),
                        hintText: 'MAP01',
                        // Название уровня — с цветами SRB2.
                        helper: srb2Text(
                          [
                            const Srb2TextSpan('-warp', 0),
                            if (_warpMap != null && _warpMap!.title.isNotEmpty) ...[
                              const Srb2TextSpan(' · ', 0),
                              ...srb2TitleSpans(_warpMap!.title),
                            ],
                          ],
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey),
                        ),
                        isDense: true,
                        border: const OutlineInputBorder(),
                        suffixIcon: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (o.warpMap.trim().isNotEmpty)
                              IconButton(
                                icon: const Icon(Icons.clear, size: 18),
                                tooltip: tr('Without -warp'),
                                visualDensity: VisualDensity.compact,
                                onPressed: () {
                                  _warp.clear();
                                  s.updateOptions((o) => o.warpMap = '');
                                },
                              ),
                            if (widget.loadMaps != null)
                              IconButton(
                                icon: const Icon(Icons.map_outlined, size: 20),
                                tooltip: tr('Choose map...'),
                                visualDensity: VisualDensity.compact,
                                onPressed: _chooseWarpMap,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ]),
            // -gametype работает и в одиночной игре (вместе с -warp), не только на сервере.
            _fieldRow([
                SizedBox(
                  width: 240,
                  child: TextField(
                    controller: _gametype,
                    onChanged: (v) => s.updateOptions((o) => o.gametype = v),
                    decoration: InputDecoration(
                      labelText: tr('Gametype'),
                      hintText: tr('From the map / game'),
                      helperText: '-gametype',
                      isDense: true,
                      border: const OutlineInputBorder(),
                      suffixIcon: PopupMenuButton<String>(
                        icon: const Icon(Icons.arrow_drop_down),
                        tooltip: tr('Gametypes'),
                        // Свои режимы аддонов очереди — к следующему открытию.
                        onOpened: _loadGametypes,
                        onSelected: (g) {
                          _gametype.text = g;
                          s.updateOptions((o) => o.gametype = g);
                        },
                        itemBuilder: (context) => [
                          PopupMenuItem(value: '', child: Text(tr('Not set'))),
                          // С выбранной картой — только режимы, которые она берёт.
                          for (final g in s.game.gametypes)
                            if (_fits(s.game.gametypeLevels(g) ?? const [])) PopupMenuItem(value: g, child: Text(g)),
                          if (_customGametypes.any((g) => _fits(g.levels))) const PopupMenuDivider(),
                          for (final g in _customGametypes)
                            if (_fits(g.levels))
                            PopupMenuItem(
                              value: g.name,
                              child: Tooltip(
                                message: g.description,
                                child: Row(
                                  children: [
                                    const Icon(Icons.extension_outlined, size: 16),
                                    const SizedBox(width: 8),
                                    Text(g.name),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
            ]),
            if (_gametypeWarning() case final warning?)
              Padding(
                padding: const EdgeInsets.only(left: 8, bottom: 6),
                child: Text(warning, style: const TextStyle(fontSize: 12, color: Colors.orangeAccent)),
              ),
            if (_warpMap != null && _warpMap!.types.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 8, bottom: 6),
                child: Text(
                  tr('Gametypes of {map}: {types}', {
                    'map': _warpMap!.map,
                    'types': [for (final t in _warpMap!.types) t.toLowerCase()].join(', '),
                  }),
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
            if (s.game.encoreCvar case final encore?)
              _check(
                label: tr('Encore mode'),
                arg: '+$encore On',
                hint: tr('Mirrored level with the Encore palette. Race only; works with -warp too.'),
                value: _encoreOn(encore),
                onChanged: (v) => _setCvar(encore, v ? 'On' : ''),
              ),
            if (s.game.gearCvar != null || s.game.botsCvar != null) _gearAndBots(),
            if (s.game.engine == 'srb2') _flag(LaunchFlags.ultimate, danger: true),
            _flag(LaunchFlags.noData),
            _flag(LaunchFlags.resetData, danger: true),
          ]),

          ..._group('player', tr('Player'), () => [
            _quickFields(_quickPlayer, trailing: [_defaultColorToggle()]),
            // +color в одиночной игре игра не принимает (кроме devmode).
            if (_cvar('color').isNotEmpty && !o.defaultColor && o.net == NetMode.off && !_devmode)
              Padding(
                padding: const EdgeInsets.only(left: 8, bottom: 6),
                child: Text(
                  tr('+color works only in multiplayer (Host/Join) or with +devmode.'),
                  style: const TextStyle(fontSize: 12, color: Colors.orangeAccent),
                ),
              ),
          ]),

          ..._group('netgame', tr('Netgame'), () => [
            _choices<NetMode>(
              value: o.net,
              options: [
                (NetMode.off, tr('Off'), ''),
                (NetMode.host, tr('Host'), tr('-server: host a netgame')),
                (NetMode.dedicated, tr('Dedicated'), tr('-dedicated: server without a player')),
                (NetMode.join, tr('Join'), tr('+connect: join a server')),
              ],
              onChanged: (v) => s.updateOptions((o) => o.net = v),
            ),
            if (o.net == NetMode.join) ...[
              _fieldRow([
                _field(_address, tr('Server address'), hint: tr('IP or host:port, empty = LAN'), width: 300,
                    onChanged: (o, v) => o.joinAddress = v),
              ]),
              if (widget.queueHasFiles)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    tr('Queued addons are loaded before connecting. The server accepts you only if they '
                        'match its addons exactly (same files, same order) — Join on the Servers tab does this for you.'),
                    style: const TextStyle(fontSize: 12, color: Colors.orangeAccent),
                  ),
                ),
            ],
            if (o.net == NetMode.host || o.net == NetMode.dedicated)
              _fieldRow([
                if (s.game.hasRooms)
                  _field(_room, tr('Room ID'), hint: tr('Master server'), digits: true, width: 170,
                      suffix: widget.loadRooms == null ? null : Builder(builder: _roomButton),
                      onChanged: (o, v) => o.room = v),
                _field(_password, tr('Admin password'), width: 190, obscure: true,
                    onChanged: (o, v) => o.adminPassword = v),
              ]),
            if (o.net == NetMode.host || o.net == NetMode.dedicated) _hostMaster(),
            _flag(LaunchFlags.noDownload),
            _flag(LaunchFlags.noUpload),
          ]),

          ..._group('server', tr('Server (when hosting)'), () => [
            _quickFields([
              for (final q in _quickServer)
                if (q.$1 != 'http_source' || s.game.hasHttpSource) q,
            ]),
            _quickToggles(),
          ]),

          ..._group('input', tr('Input'), () => [
            _flag(LaunchFlags.noMouse),
            _flag(LaunchFlags.noMouseGrab),
            _flag(LaunchFlags.noJoy),
          ]),

          ..._group('console', tr('Console commands and variables'), () => [
            ..._buildConsole(),
          ]),

          ..._group('debug', tr('Debug'), () => [
            // -console открывает отдельное окно консоли только на Windows.
            if (Platform.isWindows) _flag(LaunchFlags.console),
            _flag(LaunchFlags.debug),
          ]),

          ..._group('extra', tr('Extra parameters'), () => [
            TextField(
              controller: _extra,
              onChanged: s.setExtraParams,
              decoration: InputDecoration(
                labelText: tr('Extra parameters'),
                hintText: tr('Any other {game} parameters', {'game': s.game.name}),
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
          ]),
        ],
      ),
      ),
    );
  }

  /// Берёт ли выбранная карта режим с TypeOfLevel [levels] (карта не
  /// выбрана или её режимы неизвестны — да).
  bool _fits(List<String> levels) {
    final map = _warpMap;
    return map == null || GameDef.levelFits(map.types, levels);
  }

  /// TypeOfLevel режима [name]: встроенного или из аддона; null — не знаем.
  List<String>? _levelsOf(String name) {
    final builtIn = s.game.gametypeLevels(name);
    if (builtIn != null) return builtIn;
    for (final g in _customGametypes) {
      if (g.name.toLowerCase() == name.trim().toLowerCase()) return g.levels;
    }
    return null;
  }

  /// Предупреждение: выбранный режим не подходит карте -warp.
  String? _gametypeWarning() {
    final name = o.gametype.trim();
    final map = _warpMap;
    if (name.isEmpty || map == null || map.types.isEmpty) return null;
    final levels = _levelsOf(name);
    if (levels == null || _fits(levels)) return null;
    return tr('{map} does not support {gametype}: the game may refuse it or start another gametype.',
        {'map': map.map, 'gametype': name});
  }

  /// +devmode в консольных командах (с ним +color работает и в одиночной игре).
  bool get _devmode => o.console.any((c) => c.enabled && c.name.toLowerCase() == 'devmode');

  /// Раскрытые разделы — только в памяти (до выхода из лаунчера); сначала
  /// все свёрнуты. Profile не сворачивается.
  static final Set<String> _openSections = {};

  /// Раздел [id]: заголовок со стрелкой и, если раскрыт, его поля [build].
  /// У свёрнутого в заголовке видно, что в нём задано (-warp MAP01...).
  List<Widget> _group(String id, String title, List<Widget> Function() build) {
    final open = _openSections.contains(id);
    final accent = Theme.of(context).colorScheme.primary;
    final summary = open ? '' : _summary(id).join(' ');
    return [
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => setState(() => open ? _openSections.remove(id) : _openSections.add(id)),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Icon(open ? Icons.expand_more : Icons.chevron_right, size: 18, color: accent),
                const SizedBox(width: 4),
                Text(
                  title.toUpperCase(),
                  style: TextStyle(fontSize: 11, letterSpacing: 1.1, fontWeight: FontWeight.bold, color: accent),
                ),
                if (summary.isNotEmpty) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: Tooltip(
                      message: summary,
                      waitDuration: const Duration(milliseconds: 500),
                      child: Text(summary, maxLines: 1, overflow: TextOverflow.ellipsis, style: _argStyle),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      if (open) ...build(),
    ];
  }

  /// Что задано в разделе [id] — для заголовка свёрнутого раздела.
  List<String> _summary(String id) {
    List<String> flags(List<LaunchFlag> list) => [for (final f in list) if (o.has(f)) f.arg];
    String cvar(String name) => _cvar(name).trim().isEmpty ? '' : '+$name ${_cvar(name).trim()}';
    final encore = s.game.encoreCvar;
    final w = o.width.trim(), h = o.height.trim();
    return [
      ...switch (id) {
        'video' => [
            if (o.renderer == RendererMode.opengl) '-opengl',
            if (o.renderer == RendererMode.software) '-software',
            ...flags([LaunchFlags.windowed, LaunchFlags.borderless]),
            if (o.customResolution && w.isNotEmpty && h.isNotEmpty) '-width $w -height $h',
          ],
        'audio' => flags([LaunchFlags.noSound, LaunchFlags.noMusic]),
        'game' => [
            ...flags([LaunchFlags.skipIntro]),
            if (o.warpMap.trim().isNotEmpty) '-warp ${o.warpMap.trim()}',
            if (o.gametype.trim().isNotEmpty) '-gametype ${o.gametype.trim()}',
            if (encore != null && _encoreOn(encore)) '+$encore On',
            if (s.game.gearCvar case (final gear, _)) cvar(gear),
            if (s.game.botsCvar case final bots?) cvar(bots),
            if (s.game.engine == 'srb2') ...flags([LaunchFlags.ultimate]),
            ...flags([LaunchFlags.noData, LaunchFlags.resetData]),
          ],
        'player' => [
            cvar('name'),
            cvar('skin'),
            o.defaultColor ? tr('Always default color') : cvar('color'),
          ],
        'netgame' => [
            switch (o.net) {
              NetMode.off => '',
              NetMode.host => '-server',
              NetMode.dedicated => '-dedicated',
              NetMode.join => '+connect ${o.joinAddress.trim().isEmpty ? s.game.lanConnect : o.joinAddress.trim()}',
            },
            if (o.net == NetMode.host || o.net == NetMode.dedicated) cvar('masterserver'),
            ...flags([LaunchFlags.noDownload, LaunchFlags.noUpload]),
          ],
        'server' => [
            for (final q in _quickServer) cvar(q.$1),
            for (final q in _quickToggleVars) cvar(q.$1),
          ],
        'input' => flags([LaunchFlags.noMouse, LaunchFlags.noMouseGrab, LaunchFlags.noJoy]),
        'console' => [
            for (final c in o.console)
              if (c.enabled && !_quickNames.contains(c.name.toLowerCase())) '+${c.name}',
          ],
        'debug' => flags([if (Platform.isWindows) LaunchFlags.console, LaunchFlags.debug]),
        'extra' => [s.extraParams.trim()],
        _ => const <String>[],
      },
    ].where((x) => x.isNotEmpty).toList();
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 6),
        child: Text(
          title.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            letterSpacing: 1.1,
            fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );

  /// Переключатель из чипов: переносится на новую строку, а не сжимает текст.
  Widget _choices<T>({
    required T value,
    required List<(T, String, String)> options,
    required ValueChanged<T> onChanged,
  }) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final (v, label, hint) in options)
          Tooltip(
            message: hint,
            child: ChoiceChip(
              label: Text(label),
              selected: v == value,
              showCheckmark: false,
              onSelected: (_) => onChanged(v),
            ),
          ),
      ],
    );
  }

  Widget _check({
    required String label,
    required String arg,
    required String hint,
    required bool value,
    required ValueChanged<bool> onChanged,
    bool danger = false,
  }) {
    return Tooltip(
      message: hint,
      waitDuration: const Duration(milliseconds: 600),
      child: CheckboxListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: value,
        onChanged: (v) => onChanged(v ?? false),
        title: Text(label, style: danger ? const TextStyle(color: Colors.redAccent) : null),
        secondary: Text(arg, style: _argStyle),
      ),
    );
  }

  Widget _flag(LaunchFlag f, {bool danger = false}) => _check(
        label: tr(f.label),
        arg: f.arg,
        hint: tr(f.hint),
        value: o.has(f),
        danger: danger,
        onChanged: (v) => _toggleFlag(f, v),
      );

  Future<void> _toggleFlag(LaunchFlag f, bool on) async {
    // Ultimate: тот самый звук из игры.
    if (on && identical(f, LaunchFlags.ultimate)) UiSound.play('assets/ultimate.wav');
    if (on && identical(f, LaunchFlags.resetData)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(tr('Reset progress?')),
          content: Text(
            tr('With -resetdata the game starts with empty game data and saves it, '
                'erasing your records, emblems and unlocks.\n\n'
                'To test addons without touching your progress use '
                '"Don\'t load or save progress" (-nodata) instead.'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr('Enable')),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }

    s.updateOptions((o) {
      if (on) {
        o.flags.add(f.arg);
      } else {
        o.flags.remove(f.arg);
      }
      // -nodata и -resetdata противоречат друг другу.
      if (on && identical(f, LaunchFlags.noData)) o.flags.remove(LaunchFlags.resetData.arg);
      if (on && identical(f, LaunchFlags.resetData)) o.flags.remove(LaunchFlags.noData.arg);
    });
  }

  Widget _fieldRow(List<Widget> children) => Padding(
        padding: const EdgeInsets.only(left: 8, top: 10, bottom: 10),
        child: Wrap(
          spacing: 12,
          runSpacing: 14,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: children,
        ),
      );

  Widget _field(
    TextEditingController c,
    String label, {
    String? hint,
    double width = 110,
    bool digits = false,
    bool obscure = false,
    Widget? suffix,
    required void Function(LaunchOptions o, String value) onChanged,
  }) {
    return SizedBox(
      width: width,
      child: TextField(
        controller: c,
        obscureText: obscure,
        keyboardType: digits ? TextInputType.number : null,
        inputFormatters: digits ? [FilteringTextInputFormatter.digitsOnly] : null,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          isDense: true,
          border: const OutlineInputBorder(),
          suffixIcon: suffix,
        ),
        onChanged: (v) => s.updateOptions((o) => onChanged(o, v)),
      ),
    );
  }

  // --- Профили ---

  List<Widget> _buildProfiles() {
    final current = s.currentProfile != null && s.profileIndexOf(s.currentProfile!) >= 0 ? s.currentProfile : null;
    return [
      _section(tr('Profile')),
      Row(
        children: [
          Expanded(
            child: DropdownButton<String>(
              isExpanded: true,
              value: current,
              hint: Text(tr('No profile selected')),
              items: [
                for (final p in s.profiles) DropdownMenuItem(value: p.name, child: Text(p.name)),
              ],
              onChanged: (name) {
                if (name == null) return;
                final queue = s.applyProfile(s.profiles[s.profileIndexOf(name)]);
                if (queue != null) widget.setQueue?.call(queue);
                setState(_syncControllers);
              },
            ),
          ),
          IconButton(
            icon: const Icon(Icons.bookmark_add_outlined),
            tooltip: tr('Save profile'),
            onPressed: _saveProfile,
          ),
          IconButton(
            icon: const Icon(Icons.bookmark_remove_outlined),
            tooltip: tr('Delete profile'),
            onPressed: current == null ? null : () => s.removeProfile(s.profileIndexOf(current)),
          ),
          IconButton(
            icon: const Icon(Icons.restart_alt),
            tooltip: tr('Reset the parameters and the addon queue'),
            onPressed: _reset,
          ),
        ],
      ),
      if (current != null && _profileChanged(s.profiles[s.profileIndexOf(current)]))
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            children: [
              const Icon(Icons.warning_amber_rounded, size: 16, color: Colors.orangeAccent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  tr('Changes are not saved to the profile "{name}"', {'name': current}),
                  style: const TextStyle(fontSize: 12, color: Colors.orangeAccent),
                ),
              ),
            ],
          ),
        )
      else if (current == null)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            tr('The current configuration is not saved to a profile.'),
            style: const TextStyle(fontSize: 12, color: Colors.orangeAccent),
          ),
        ),
      Text(
        tr('A profile saves the checkboxes, console commands, extra parameters and the addon queue.'),
        style: const TextStyle(fontSize: 11, color: Colors.grey),
      ),
    ];
  }

  /// «Сбросить»: все параметры запуска — по умолчанию, очередь аддонов —
  /// пустая (после подтверждения). Сборки и профили остаются.
  Future<void> _reset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Reset?')),
        content: Text(tr('All checkboxes, console commands and extra parameters return to their defaults, '
            'and the addon queue is cleared. Builds and profiles are kept.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Reset'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    s.resetOptions();
    widget.setQueue?.call(const []);
    setState(() {
      _syncControllers();
      _lastSkin = _cvar('skin');
      _lastColor = _cvar('color');
      _quickRev++; // быстрые поля (+name, +skin...) пересоздаются пустыми
    });
  }

  /// Отличается ли текущая конфигурация от сохранённой в профиле.
  bool _profileChanged(LaunchProfile p) {
    if (p.options != null && jsonEncode(p.options) != jsonEncode(o.toJson())) return true;
    if (p.params != s.extraParams.trim()) return true;
    final queue = widget.getQueue?.call();
    if (p.queue != null && queue != null) {
      if (p.queue!.length != queue.length) return true;
      for (var i = 0; i < queue.length; i++) {
        if (p.queue![i] != queue[i]) return true;
      }
    }
    return false;
  }

  Future<void> _saveProfile() async {
    final nameController = TextEditingController(text: s.currentProfile ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Save profile')),
        content: SizedBox(
          width: 380,
          child: TextField(
            controller: nameController,
            autofocus: true,
            decoration: InputDecoration(
              labelText: tr('Profile name'),
              hintText: tr('e.g. Map testing'),
              helperText: tr('A profile with the same name is replaced.'),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, nameController.text),
            child: Text(tr('Save')),
          ),
        ],
      ),
    );
    // Контроллер не освобождаем вручную: диалог ещё анимирует закрытие.
    if (name == null || name.trim().isEmpty) return;
    s.saveProfile(name, widget.getQueue?.call());
    if (mounted) {
      showSnack(context, 
        SnackBar(content: Text(tr('Profile "{name}" saved', {'name': name.trim()}))),
      );
    }
  }

  // --- Частые консольные переменные (быстрые поля) ---

  /// (переменная, подпись, подсказка, ширина)
  static const _quickPlayer = [
    ('name', 'Player name', '', 200.0),
    ('skin', 'Skin', 'sonic', 140.0),
    ('color', 'Color', 'blue', 140.0),
  ];
  static const _quickServer = [
    ('servername', 'Server name', '', 260.0),
    ('maxplayers', 'Max players', '8', 120.0),
    ('maxsend', 'Max download size, KB', '4096', 180.0),
    ('downloadspeed', 'Download speed', '16', 150.0),
    ('http_source', 'HTTP mirror', 'https://...', 260.0),
    ('pointlimit', 'Point limit', '', 120.0),
    ('timelimit', 'Time limit, min', '', 130.0),
  ];
  static const _quickToggleVars = [
    ('allowjoin', 'Allow joining'),
    ('downloading', 'Allow downloads'),
  ];
  static final _quickNames = {
    for (final q in _quickPlayer) q.$1,
    for (final q in _quickServer) q.$1,
    for (final q in _quickToggleVars) q.$1,
    'kartencore', 'encore', // галочка Encore
    'masterserver', // выбор мастер-сервера для своего сервера
    'kartspeed', 'gamespeed', 'bots', // Gear и боты
  };

  /// Режим Encore включён (+kartencore / +encore On).
  bool _encoreOn(String cvar) => const {'on', '1', 'yes', 'true'}.contains(_cvar(cvar).toLowerCase());

  String _cvar(String name) => o.cvar(name);

  /// Пустое значение — переменная не передаётся.
  void _setCvar(String name, String value) {
    // Своё изменение +skin — поле не пересоздаём (иначе теряется фокус при наборе).
    if (name == 'skin') _lastSkin = value.trim();
    if (name == 'color') _lastColor = value.trim();
    s.updateOptions((o) => o.setCvar(name, value));
  }

  /// Меняется после выбора персонажа — чтобы поле +skin показало новое значение.
  int _quickRev = 0;

  Widget _quickFields(List<(String, String, String, double)> fields, {List<Widget> trailing = const []}) {
    final key = '${identityHashCode(o)}/$_quickRev';
    return _fieldRow([
      for (final (name, label, hint, width) in fields)
        Tooltip(
          message: name == 'color' && o.defaultColor
              ? tr('"Always default color" is on: this color is not used.')
              : '+$name — ${_ref(name)?.description ?? ''}',
          waitDuration: const Duration(milliseconds: 600),
          child: SizedBox(
            width: width,
            child: TextFormField(
              key: ValueKey('$key/quick/$name'),
              initialValue: _cvar(name),
              // С «Всегда родной цвет» свой цвет не передаётся — поле серое.
              enabled: !(name == 'color' && o.defaultColor),
              onChanged: (v) => _setCvar(name, v),
              decoration: InputDecoration(
                labelText: tr(label),
                hintText: hint,
                helperText: '+$name',
                isDense: true,
                border: const OutlineInputBorder(),
                suffixIcon: name == 'skin' && widget.loadCharacters != null
                    ? IconButton(
                        icon: const Icon(Icons.person_search, size: 20),
                        tooltip: tr('Choose a character'),
                        onPressed: () async {
                          final skin = await showCharacterPicker(context, widget.loadCharacters!(),
                              current: _cvar('skin'), portraits: s.game.pickerPortraits);
                          if (skin == null || !mounted) return;
                          _setCvar('skin', skin);
                          setState(() => _quickRev++);
                        },
                      )
                    : name == 'color' && widget.loadColors != null
                        ? IconButton(
                            icon: const Icon(Icons.palette_outlined, size: 20),
                            tooltip: tr('Choose a color'),
                            onPressed: o.defaultColor
                                ? null
                                : () async {
                              final color = await showSkinColorPicker(context, widget.loadColors!(),
                                  current: _cvar('color'));
                              if (color == null || !mounted) return;
                              _setCvar('color', color);
                              setState(() => _quickRev++);
                            },
                          )
                        : null,
              ),
            ),
          ),
        ),
      ...trailing,
    ]);
  }

  /// «Всегда родной цвет»: вместо +color — цвет персонажа из его S_SKIN.
  Widget _defaultColorToggle() {
    void toggle(bool v) => s.updateOptions((o) => o.defaultColor = v);
    return Tooltip(
      message: s.game.engine == 'drrr'
          ? tr('Always the own color of the character: +color Default instead of the color on the left.')
          : tr('Always the own color of the character (prefcolor of its S_SKIN) instead of the color on the left: '
              'the launcher passes it as +color. Needs +skin; works in multiplayer.'),
      waitDuration: const Duration(milliseconds: 500),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => toggle(!o.defaultColor),
        child: Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Checkbox(value: o.defaultColor, onChanged: (v) => toggle(v ?? false)),
              Text(tr('Always default color')),
            ],
          ),
        ),
      ),
    );
  }

  /// Окно выбора карты для -warp (и режима — меню «⋮» на карточках).
  Future<void> _chooseWarpMap() async {
    // Свои режимы аддонов очереди — для меню «⋮» на карточках.
    _loadGametypes();
    final choice = await showMapPicker(
      context,
      widget.loadMaps!(),
      current: _warp.text,
      gametypes: (m) => gametypesForMap(s.game, m, _customGametypes),
      gametype: currentGametypeChoice(o.gametype, netOff: o.net == NetMode.off),
    );
    if (choice == null || !mounted) return;
    final single = choice.gametype == singleplayerGametype;
    final gametype = single ? '' : choice.gametype;
    _warp.text = choice.map;
    if (gametype != null) _gametype.text = gametype;
    s.updateOptions((o) {
      o.warpMap = choice.map;
      if (gametype != null) o.gametype = gametype;
      // Singleplayer: одиночная игра — без своего сервера.
      if (single) o.net = NetMode.off;
    });
    // Без «⋮» режим — в меню поля Gametype: там только режимы этой карты.
    await _refreshWarpMap();
  }

  /// Gear (скорость игры) и боты: выпадающие списки; «по умолчанию» —
  /// параметр не передаётся.
  Widget _gearAndBots() {
    Widget choice(String label, String cvar, List<(String, String)> values, String hint) {
      final current = _cvar(cvar).trim();
      final known = values.any((v) => v.$1 == current);
      return Tooltip(
        message: hint,
        waitDuration: const Duration(milliseconds: 600),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label),
            const SizedBox(width: 8),
            DropdownButton<String>(
              value: current,
              isDense: true,
              items: [
                DropdownMenuItem(value: '', child: Text(tr('Default'))),
                for (final (value, name) in values) DropdownMenuItem(value: value, child: Text(name)),
                // Значение, заданное вручную, которого нет в списке.
                if (current.isNotEmpty && !known) DropdownMenuItem(value: current, child: Text(current)),
              ],
              onChanged: (v) => _setCvar(cvar, v ?? ''),
            ),
          ],
        ),
      );
    }

    final gear = s.game.gearCvar;
    final bots = s.game.botsCvar;
    return _fieldRow([
      if (gear != null)
        choice(tr('Gear'), gear.$1, gear.$2,
            tr('Game speed: +{cvar} <value>. Default — the game decides (its config or Auto Gear).', {'cvar': gear.$1})),
      if (bots != null)
        choice(
          tr('Bots'),
          bots,
          [
            ('0', tr('Off')),
            for (var i = 1; i <= 12; i++) ('$i', 'Lv.$i'),
            ('13', 'Lv.MAX'),
          ],
          tr('Bots fill the race: +{cvar} <level>. Default — as in the game.', {'cvar': bots}),
        ),
    ]);
  }

  /// На каком мастер-сервере объявить свой сервер: +masterserver <адрес>.
  /// Кнопка выбора комнаты: комнаты с мастер-сервера, где будет объявлен
  /// сервер (+masterserver), или со всех включённых.
  bool _loadingRooms = false;

  Widget _roomButton(BuildContext button) => IconButton(
        icon: _loadingRooms
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.meeting_room_outlined, size: 20),
        tooltip: tr('Choose a room of the master server'),
        visualDensity: VisualDensity.compact,
        onPressed: _loadingRooms ? null : () => _chooseRoom(button),
      );

  Future<void> _chooseRoom(BuildContext button) async {
    setState(() => _loadingRooms = true);
    Map<int, String> rooms;
    String? error;
    try {
      rooms = await widget.loadRooms!(_cvar('masterserver'));
    } catch (e) {
      rooms = const {};
      error = '$e';
    }
    if (!mounted) return;
    setState(() => _loadingRooms = false);
    if (!button.mounted) return;
    final box = button.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(button).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final ids = rooms.keys.toList()..sort();
    final current = int.tryParse(_room.text.trim());
    final picked = await showMenu<int>(
      context: button,
      position: RelativeRect.fromRect(
        Rect.fromPoints(
          box.localToGlobal(Offset.zero, ancestor: overlay),
          box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
        ),
        Offset.zero & overlay.size,
      ),
      items: ids.isEmpty
          ? [
              PopupMenuItem(
                enabled: false,
                child: Text(error == null
                    ? tr('The master server has no rooms')
                    : tr('Could not load the rooms: {error}', {'error': error})),
              ),
            ]
          : [
              for (final id in ids)
                PopupMenuItem(
                  value: id,
                  child: Row(
                    children: [
                      SizedBox(width: 44, child: Text('$id', style: const TextStyle(fontWeight: FontWeight.bold))),
                      Expanded(child: Text(rooms[id]!, overflow: TextOverflow.ellipsis)),
                      SizedBox(
                        width: 22,
                        child: id == current
                            ? Icon(Icons.check, size: 18, color: Theme.of(context).colorScheme.primary)
                            : null,
                      ),
                    ],
                  ),
                ),
            ],
    );
    if (picked == null || !mounted) return;
    _room.text = '$picked';
    s.updateOptions((o) => o.room = '$picked');
  }

  Widget _hostMaster() {
    final current = _cvar('masterserver').trim();
    final known = widget.masters.any((m) => m.$2 == current);
    return Tooltip(
      message: tr('Where your server is listed: +masterserver <address>. The game saves it to its config, '
          'so it stays until you choose another one. "From the game config" passes nothing.'),
      waitDuration: const Duration(milliseconds: 600),
      child: Padding(
        padding: const EdgeInsets.only(left: 8, bottom: 6),
        child: Row(
          children: [
            Text(tr('Master server')),
            const SizedBox(width: 12),
            Flexible(
              child: DropdownButton<String>(
                value: current,
                isDense: true,
                isExpanded: true,
                items: [
                  DropdownMenuItem(value: '', child: Text(tr('From the game config'))),
                  for (final (name, url) in widget.masters)
                    DropdownMenuItem(
                      value: url,
                      child: Text(name == url ? url : '$name — $url', overflow: TextOverflow.ellipsis),
                    ),
                  // Адрес, заданный вручную (в консольных командах), которого нет в списке.
                  if (current.isNotEmpty && !known)
                    DropdownMenuItem(value: current, child: Text(current, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) => _setCvar('masterserver', v ?? ''),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// allowjoin / downloading: по умолчанию (из конфига), вкл или выкл.
  Widget _quickToggles() {
    return _fieldRow([
      for (final (name, label) in _quickToggleVars)
        Tooltip(
          message: '+$name — ${_ref(name)?.description ?? ''}',
          waitDuration: const Duration(milliseconds: 600),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(tr(label)),
              const SizedBox(width: 8),
              DropdownButton<String>(
                value: switch (_cvar(name).toLowerCase()) {
                  'on' || '1' || 'yes' => 'On',
                  'off' || '0' || 'no' => 'Off',
                  _ => '',
                },
                isDense: true,
                items: [
                  DropdownMenuItem(value: '', child: Text(tr('Default'))),
                  DropdownMenuItem(value: 'On', child: Text(tr('On'))),
                  DropdownMenuItem(value: 'Off', child: Text(tr('Off'))),
                ],
                onChanged: (v) => _setCvar(name, v ?? ''),
              ),
            ],
          ),
        ),
    ]);
  }

  // --- Консольные команды и переменные (+имя значение) ---

  ConsoleRef? _ref(String name) {
    for (final r in _refs) {
      if (r.name.toLowerCase() == name.toLowerCase()) return r;
    }
    return null;
  }

  void _addConsole(String name, [String value = '']) {
    final n = name.trim().replaceFirst(RegExp(r'^\+'), '');
    if (n.isEmpty) return;
    s.updateOptions((o) => o.console = [...o.console, ConsoleEntry(n, value)]);
    _consoleInput.clear();
  }

  List<Widget> _buildConsole() {
    final key = identityHashCode(o); // новые поля после выбора профиля
    return [
      Text(
        tr('Run after the game loads, like typing in the console: +maxsend 200000, +servername "My server".'),
        style: const TextStyle(fontSize: 11, color: Colors.grey),
      ),
      const SizedBox(height: 6),
      for (var i = 0; i < o.console.length; i++)
        if (!_quickNames.contains(o.console[i].name.toLowerCase()))
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            children: [
              Checkbox(
                value: o.console[i].enabled,
                visualDensity: VisualDensity.compact,
                onChanged: (v) => s.updateOptions((o) {
                  final e = o.console[i];
                  o.console = [...o.console]..[i] = ConsoleEntry(e.name, e.value, enabled: v ?? true);
                }),
              ),
              Tooltip(
                message: _ref(o.console[i].name)?.description ?? '',
                child: SizedBox(
                  width: 130,
                  child: Text('+${o.console[i].name}', style: _argStyle.copyWith(fontSize: 13), overflow: TextOverflow.ellipsis),
                ),
              ),
              Expanded(
                child: TextFormField(
                  key: ValueKey('$key/$i/${o.console[i].name}'),
                  initialValue: o.console[i].value,
                  decoration: InputDecoration(
                    hintText: _ref(o.console[i].name)?.args ?? '',
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (v) => s.updateOptions((o) {
                    final e = o.console[i];
                    o.console = [...o.console]..[i] = ConsoleEntry(e.name, v, enabled: e.enabled);
                  }),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                tooltip: tr('Remove'),
                onPressed: () => s.updateOptions((o) => o.console = [...o.console]..removeAt(i)),
              ),
            ],
          ),
        ),
      RawAutocomplete<ConsoleRef>(
        textEditingController: _consoleInput,
        focusNode: _consoleFocus,
        optionsBuilder: (value) {
          final q = value.text.trim().replaceFirst(RegExp(r'^\+'), '').toLowerCase();
          if (q.isEmpty) return const Iterable<ConsoleRef>.empty();
          // В SRB2 Legacy (2.1) нет http_source — не предлагаем.
          final refs = s.game.hasHttpSource ? _refs : _refs.where((r) => r.name != 'http_source');
          final starts = refs.where((r) => r.name.toLowerCase().startsWith(q));
          final contains = refs.where((r) => !r.name.toLowerCase().startsWith(q) && r.name.toLowerCase().contains(q));
          return [...starts, ...contains].take(40);
        },
        displayStringForOption: (r) => r.name,
        onSelected: (r) => _addConsole(r.name),
        fieldViewBuilder: (context, controller, focusNode, onSubmitted) => TextField(
          controller: controller,
          focusNode: focusNode,
          decoration: InputDecoration(
            labelText: tr('Add a command or variable'),
            hintText: s.game.hasHttpSource ? tr('e.g. maxsend, servername, http_source') : tr('e.g. maxsend, servername'),
            prefixIcon: const Icon(Icons.add, size: 18),
            isDense: true,
            border: const OutlineInputBorder(),
          ),
          // Enter без выбора из списка: "maxsend 200000" → +maxsend 200000.
          onSubmitted: (text) {
            final t = text.trim().replaceFirst(RegExp(r'^\+'), '');
            if (t.isEmpty) return;
            final space = t.indexOf(' ');
            if (space < 0) {
              _addConsole(t);
            } else {
              _addConsole(t.substring(0, space), t.substring(space + 1).trim());
            }
          },
        ),
        optionsViewBuilder: (context, onSelected, options) => Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380, maxHeight: 300),
              child: ListView(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                children: [
                  for (final r in options)
                    ListTile(
                      dense: true,
                      title: Text('+${r.name} ${r.args}', style: _argStyle.copyWith(fontSize: 13)),
                      subtitle: Text(
                        '${r.isVariable ? tr('Variable') : tr('Command')} · ${r.section}\n${r.description}',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11),
                      ),
                      onTap: () => onSelected(r),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    ];
  }
}

enum _ExeAction { add, scan, edit, remove }

/// Выбор экзешника перед запуском + управление списком.
class ExecutableSelector extends StatelessWidget {
  final LaunchSettings settings;

  /// Папка игры — стартовая для диалогов выбора файла.
  final String? initialDirectory;

  const ExecutableSelector({super.key, required this.settings, this.initialDirectory});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final selected = settings.selected;
        final isDefault = selected != null && settings.isDefault(selected);

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(tr('Executable:'), style: TextStyle(color: Colors.grey)),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 180, maxWidth: 300),
              child: Tooltip(
                message: selected?.command ?? '${PlatformUtils.defaultLaunchCommand(game: settings.game)} (default)',
                waitDuration: const Duration(milliseconds: 600),
                child: DropdownButton<String>(
                  value: selected?.id,
                  isExpanded: true,
                  hint: Text('${PlatformUtils.defaultLaunchCommand(game: settings.game)} (default)'),
                  items: [
                    for (final e in settings.executables)
                      DropdownMenuItem(
                        value: e.id,
                        child: Row(
                          children: [
                            Icon(
                              settings.isDefault(e) ? Icons.star : Icons.terminal,
                              size: 16,
                              color: settings.isDefault(e) ? Colors.amber : Colors.grey,
                            ),
                            const SizedBox(width: 8),
                            Flexible(child: Text(e.name, overflow: TextOverflow.ellipsis)),
                          ],
                        ),
                      ),
                  ],
                  onChanged: settings.select,
                ),
              ),
            ),
            IconButton(
              icon: Icon(isDefault ? Icons.star : Icons.star_border,
                  color: isDefault ? Colors.amber : null),
              tooltip: isDefault ? tr('Default executable') : tr('Set as default'),
              onPressed: selected == null || isDefault ? null : () => settings.setDefault(selected.id),
            ),
            PopupMenuButton<_ExeAction>(
              icon: const Icon(Icons.more_vert),
              tooltip: tr('Manage executables'),
              onSelected: (action) => _onAction(context, action),
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: _ExeAction.add,
                  child: ListTile(leading: Icon(Icons.add), title: Text(tr('Add executable...')), dense: true),
                ),
                PopupMenuItem(
                  value: _ExeAction.scan,
                  child: ListTile(leading: Icon(Icons.manage_search), title: Text(tr('Find builds in folder...')), dense: true),
                ),
                PopupMenuItem(
                  value: _ExeAction.edit,
                  enabled: selected != null,
                  child: ListTile(leading: Icon(Icons.edit_outlined), title: Text(tr('Edit selected...')), dense: true),
                ),
                PopupMenuItem(
                  value: _ExeAction.remove,
                  enabled: selected != null,
                  child: ListTile(leading: Icon(Icons.delete_outline), title: Text(tr('Remove selected')), dense: true),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Future<void> _onAction(BuildContext context, _ExeAction action) async {
    final selected = settings.selected;
    switch (action) {
      case _ExeAction.add:
        final added = await showExecutableDialog(
          context,
          initialDirectory: initialDirectory,
          suggestName: settings.uniqueName,
        );
        if (added != null) settings.addExecutable(added);
      case _ExeAction.edit:
        if (selected == null) return;
        final edited = await showExecutableDialog(context, initial: selected, initialDirectory: initialDirectory);
        if (edited != null) settings.updateExecutable(edited);
      case _ExeAction.remove:
        if (selected == null) return;
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(tr('Remove executable?')),
            content: Text(tr('Remove "{name}" from the list? The file itself is not deleted.', {'name': selected.name})),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
              ElevatedButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Remove'))),
            ],
          ),
        );
        if (ok == true) settings.removeExecutable(selected.id);
      case _ExeAction.scan:
        await _scanFolder(context);
    }
  }

  /// Поиск сборок в папке (используется и в окне настроек).
  Future<void> scanFolder(BuildContext context) => _scanFolder(context);

  Future<void> _scanFolder(BuildContext context) async {
    AppLog.action('open the getDirectoryPath dialog (launch_panel.dart)');
    final dir = await getDirectoryPath(
      initialDirectory: initialDirectory,
      confirmButtonText: tr('Scan'),
    );
    if (dir == null) return;
    final found = await LaunchSettings.findExecutables(dir, hints: settings.game.executableHints);
    if (!context.mounted) return;

    if (found.isEmpty) {
      showSnack(context, 
        SnackBar(content: Text(tr('No executables found in {folder}', {'folder': dir}))),
      );
      return;
    }

    // Сразу отмечены новые файлы, похожие на сборку игры (в имени есть "srb2", "ringracers").
    final checked = <int>{
      for (var i = 0; i < found.length; i++)
        if (found[i].likelySrb2 && !settings.hasProgram(found[i].path)) i,
    };

    final chosen = await showDialog<List<FoundExecutable>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(tr('Add builds')),
          content: SizedBox(
            width: 520,
            height: 360,
            child: ListView(
              children: [
                for (var i = 0; i < found.length; i++)
                  CheckboxListTile(
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: settings.hasProgram(found[i].path) || checked.contains(i),
                    onChanged: settings.hasProgram(found[i].path)
                        ? null
                        : (v) => setDialogState(() => v == true ? checked.add(i) : checked.remove(i)),
                    title: Text(found[i].name + (settings.hasProgram(found[i].path) ? '  (already added)' : '')),
                    subtitle: Text(found[i].path, style: _argStyle),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, [for (final i in checked) found[i]]),
              child: Text(tr('Add selected')),
            ),
          ],
        ),
      ),
    );
    if (chosen == null || chosen.isEmpty) return;

    for (final f in chosen) {
      settings.addExecutable(
        LaunchExecutable(
          id: LaunchExecutable.newId(),
          name: settings.uniqueName(f.path, preferred: f.name),
          command: PlatformUtils.quoteIfNeeded(f.path),
        ),
        select: false,
      );
    }
    if (context.mounted) {
      showSnack(context, 
        SnackBar(content: Text(tr('Added {n} executable(s)', {'n': chosen.length})), backgroundColor: Colors.green),
      );
    }
  }
}

/// Диалог добавления/изменения экзешника: имя + путь (или команда).
/// [suggestName] — имя по умолчанию для выбранного файла (без повторов).
Future<LaunchExecutable?> showExecutableDialog(
  BuildContext context, {
  LaunchExecutable? initial,
  String? initialDirectory,
  String Function(String command)? suggestName,
}) {
  final nameFor = suggestName ?? LaunchExecutable.suggestName;
  final nameController = TextEditingController(text: initial?.name ?? '');
  final commandController = TextEditingController(text: initial?.command ?? '');
  final isWin = Platform.isWindows;

  return showDialog<LaunchExecutable>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) {
        Future<void> browse() async {
          AppLog.action('open the openFile dialog (launch_panel.dart)');
          final file = await openFile(
            acceptedTypeGroups: isWin
                ? [XTypeGroup(label: tr('Programs'), extensions: ['exe'])]
                : const [],
            initialDirectory: initialDirectory,
            confirmButtonText: tr('Select'),
          );
          if (file == null || !context.mounted) return;
          setDialogState(() {
            commandController.text = PlatformUtils.quoteIfNeeded(file.path);
            if (nameController.text.trim().isEmpty) {
              nameController.text = nameFor(file.path);
            }
          });
        }

        final command = commandController.text.trim();
        return AlertDialog(
          title: Text(initial == null ? 'Add executable' : 'Edit executable'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: commandController,
                        onChanged: (_) => setDialogState(() {}),
                        decoration: InputDecoration(
                          labelText: tr('Executable or command'),
                          hintText: isWin ? r'C:\Games\SRB2\srb2win.exe' : 'srb2 or flatpak run org.srb2.SRB2',
                          helperText: tr('Put paths with spaces in "quotes".'),
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.outlined(
                      icon: const Icon(Icons.file_open_outlined),
                      tooltip: tr('Browse...'),
                      onPressed: browse,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: nameController,
                  decoration: InputDecoration(
                    labelText: tr('Name'),
                    hintText: command.isEmpty ? 'e.g. srb2win' : nameFor(command),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
            ElevatedButton(
              onPressed: command.isEmpty
                  ? null
                  : () {
                      final name = nameController.text.trim().isEmpty
                          ? nameFor(command)
                          : nameController.text.trim();
                      Navigator.pop(
                        context,
                        initial == null
                            ? LaunchExecutable(id: LaunchExecutable.newId(), name: name, command: command)
                            : initial.copyWith(name: name, command: command),
                      );
                    },
              child: Text(initial == null ? 'Add' : 'Save'),
            ),
          ],
        );
      },
    ),
  );
  // Контроллеры не освобождаем вручную: диалог ещё анимирует закрытие.
}
