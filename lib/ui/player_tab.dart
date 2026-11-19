import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show FontFeature;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../services/midi_out.dart';
import '../services/app_log.dart';
import '../i18n.dart';
import '../models/game.dart';
import '../services/music.dart';
import '../services/music_player.dart';
import 'file_actions.dart';
import 'game_icon.dart';
import 'music_visualizer.dart';
import 'snack.dart';
import 'srb2_text.dart';

/// Вкладка «Плеер» (экспериментальная): музыка всех игр — из файлов игры,
/// скачанных аддонов, других загрузок — и открытых вручную файлов.
class PlayerTab extends StatefulWidget {
  final MusicPlayer player;

  /// Файлы, где искать музыку (игры, их аддоны и загрузки).
  final Future<List<MusicSource>> Function() sourceFiles;

  /// Щелчок по уровню, где играет трек: выбрать его для -warp в Launch.
  /// [addonFile] — файл аддона, который надо загрузить вместе с уровнем;
  /// [encore] — трек играет в режиме Encore (включить и его).
  final void Function(String game, String map, String? addonFile, {bool encore})? onWarp;

  const PlayerTab({super.key, required this.player, required this.sourceFiles, this.onWarp});

  @override
  State<PlayerTab> createState() => _PlayerTabState();
}

/// Заголовок в списке: игра (0), категория (1) или файл (2).
class _Header {
  final int level;

  /// Ключ для сворачивания (у файла — путь).
  final String id;
  final MusicTrack first;
  final int count;
  const _Header(this.level, this.id, this.first, this.count);
}

GameDef? _gameOf(String id) => Games.all.where((g) => g.id == id).firstOrNull;

String _time(Duration d) {
  final s = d.inSeconds;
  return s >= 3600
      ? '${s ~/ 3600}:${(s ~/ 60 % 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}'
      : '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// Роль служебных треков игры (_TITLE, _1UP...) — понятным словом.
String? specialMusicName(String lump) => switch (lump.toUpperCase()) {
      '_TITLE' => tr('Title screen'),
      '_INTRO' => tr('Intro'),
      '_CHSEL' => tr('Character select'),
      '_CLEAR' => tr('Act clear'),
      '_INTER' => tr('Intermission'),
      '_1UP' => tr('Extra life'),
      '_SHOES' => tr('Speed shoes'),
      '_INV' => tr('Invincibility'),
      '_MINV' => tr('Invincibility (Mario mode)'),
      '_SUPER' => tr('Super form'),
      '_DROWN' => tr('Drowning'),
      '_GOVER' => tr('Game over'),
      '_CONTI' => tr('Continue screen'),
      '_CREDS' => tr('Credits'),
      '_ENDB' || '_END' || '_ENDG' => tr('Ending'),
      '_RECAT' => tr('Record Attack menu'),
      '_NITAT' => tr('NiGHTS Attack menu'),
      '_NTIME' => tr('NiGHTS: time is running out'),
      _ => null,
    };

/// Файлы, которые можно перетащить в плеер.
bool _droppable(String path) {
  final ext = p.extension(path).toLowerCase().replaceFirst('.', '');
  return ext == 'wad' || ext == 'pk3' || ext == 'sf2' || MusicScanner.audioExtensions.contains(ext);
}

class _PlayerTabState extends State<PlayerTab> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _searchKey = GlobalKey();
  final _focus = FocusNode(debugLabel: 'player');
  bool _dragging = false;
  static const _rowHeight = 52.0;

  /// Режим отметки треков (для экспорта) и отмеченные треки (ключи).
  bool _selecting = false;
  final Set<String> _checked = {};

  static final _gameNames = {for (final g in Games.all) g.id: g.name};

  static String _gameKey(String game) => 'game:$game';
  static String _sectionKey(MusicTrack t) => 'section:${t.section}';

  MusicPlayer get player => widget.player;

  // Список пересчитывается, только когда меняются треки, поиск или фильтры, —
  // не на каждом тике позиции воспроизведения.
  List<MusicTrack> _arranged = const [];
  Object? _arrangedKey;

  /// При поиске всё развёрнуто (иначе находки прятались бы в свёрнутых
  /// категориях); свернуть можно и тут — до конца поиска.
  final Set<String> _searchCollapsed = {};
  bool get _searching => _search.text.trim().isNotEmpty;

  bool _isCollapsed(String key) => _searching ? _searchCollapsed.contains(key) : player.isCollapsed(key);

  void _setCollapsed(Iterable<String> keys, bool collapsed) {
    if (!_searching) return player.setCollapsed(keys, collapsed);
    setState(() {
      if (collapsed) {
        _searchCollapsed.addAll(keys);
      } else {
        _searchCollapsed.removeAll(keys);
      }
    });
  }

  /// Сколько дубликатов во всём списке (без учёта поиска и форматов).
  int _duplicateCount() {
    final key = (identityHashCode(player.tracks), player.tracks.length, Object.hashAllUnordered(player.favorites));
    if (key != _duplicatesFor) {
      _duplicatesFor = key;
      _duplicates = duplicateTrackKeys(player.tracks, keep: player.favorites).length;
    }
    return _duplicates;
  }

  Object? _duplicatesFor;
  int _duplicates = 0;

  List<MusicTrack> _visible() {
    final key = (
      identityHashCode(player.tracks),
      player.tracks.length,
      _search.text,
      player.sort,
      [for (final f in player.hiddenFormats) f.name].join(','),
      // Избранное влияет и на дубликаты: избранная копия не скрывается.
      player.favoritesOnly || player.hideDuplicates ? Object.hashAllUnordered(player.favorites) : 0,
      player.favoritesOnly,
      player.hideDuplicates,
    );
    if (key != _arrangedKey) {
      _arrangedKey = key;
      final arranged = arrangeTracks(
        player.tracks,
        query: _search.text,
        hidden: player.hiddenFormats,
        sort: player.sort,
        gameNames: _gameNames,
        hideDuplicates: player.hideDuplicates,
        keep: player.favorites,
      );
      _arranged = player.favoritesOnly ? [for (final t in arranged) if (player.isFavorite(t)) t] : arranged;
    }
    return _arranged;
  }

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {
          if (!_searching) _searchCollapsed.clear();
        }));
    // Первый вход — ищем треки.
    if (player.tracks.isEmpty && !player.scanning) _rescan();
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _rescan() async => player.scan(await widget.sourceFiles());

  Future<void> _openFiles() async {
    AppLog.action('open the openFiles dialog (player_tab.dart)');
    final files = await openFiles(
      acceptedTypeGroups: [
        XTypeGroup(label: tr('Music and addons'), extensions: [
          for (final e in ['wad', 'pk3', ...MusicScanner.audioExtensions]) ...[e, e.toUpperCase()],
        ]),
      ],
      confirmButtonText: tr('Open'),
    );
    if (files.isEmpty) return;
    player.addFiles(files.map((f) => f.path));
    await _rescan();
  }

  /// Перетащенные файлы: музыка и аддоны — в плеер, .sf2 — в список SoundFont.
  Future<void> _dropped(Iterable<String> paths) async {
    final files = [for (final f in paths) if (_droppable(f)) f];
    final fonts = [for (final f in files) if (f.toLowerCase().endsWith('.sf2')) f];
    final music = [for (final f in files) if (!f.toLowerCase().endsWith('.sf2')) f];
    for (final f in fonts) {
      player.setSf2(f);
    }
    if (music.isEmpty) return;
    player.addFiles(music);
    await _rescan();
  }

  Future<void> _addSf2() async {
    AppLog.action('open the openFile dialog (player_tab.dart)');
    final file = await openFile(
      acceptedTypeGroups: [XTypeGroup(label: 'SoundFont', extensions: ['sf2', 'SF2'])],
      confirmButtonText: tr('Select'),
    );
    if (file != null) player.setSf2(file.path);
  }

  /// Горячие клавиши (когда фокус не в поле поиска): пробел — пауза, ←/→ —
  /// перемотка на 5 с, Ctrl+←/→ — предыдущий/следующий трек, ↑/↓ —
  /// громкость, Ctrl+F — поиск.
  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = e.logicalKey;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final first = e is KeyDownEvent;
    if (key == LogicalKeyboardKey.space && first) {
      player.togglePause();
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      if (!ctrl) {
        player.seekBy(const Duration(seconds: -5));
      } else if (first) {
        player.previous();
      }
    } else if (key == LogicalKeyboardKey.arrowRight) {
      if (!ctrl) {
        player.seekBy(const Duration(seconds: 5));
      } else if (first) {
        player.next();
      }
    } else if (key == LogicalKeyboardKey.arrowUp) {
      player.setVolume(player.volume + 0.05);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      player.setVolume(player.volume - 0.05);
    } else if (key == LogicalKeyboardKey.keyF && ctrl && first) {
      _searchFocus.requestFocus();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  /// Видимые строки: игра → категория → файл → треки; свёрнутые разделы
  /// без содержимого. У открытых вручную файлов нет категории.
  List<Object> _rows(List<MusicTrack> visible) {
    final counts = <String, int>{};
    for (final t in visible) {
      for (final k in [_gameKey(t.game), _sectionKey(t), t.file]) {
        counts[k] = (counts[k] ?? 0) + 1;
      }
    }
    final rows = <Object>[];
    String? game, section, file;
    for (final t in visible) {
      final gk = _gameKey(t.game), sk = _sectionKey(t);
      if (gk != game) {
        game = gk;
        section = file = null;
        rows.add(_Header(0, gk, t, counts[gk]!));
      }
      if (_isCollapsed(gk)) continue;
      if (t.category != MusicCategory.opened && sk != section) {
        section = sk;
        file = null;
        rows.add(_Header(1, sk, t, counts[sk]!));
      }
      if (t.category != MusicCategory.opened && _isCollapsed(sk)) continue;
      if (t.file != file) {
        file = t.file;
        rows.add(_Header(2, t.file, t, counts[t.file]!));
      }
      if (_isCollapsed(t.file)) continue;
      rows.add(t);
    }
    return rows;
  }

  static double _extent(Object row) => switch (row) {
        _Header(level: 0) => 46.0,
        _Header(level: 1) => 36.0,
        _Header() => 40.0,
        _ => _rowHeight,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      // Щелчок по вкладке возвращает фокус плееру (клавиши работают);
      // поле поиска забирает его себе само.
      child: Listener(
        onPointerDown: (e) {
          final box = _searchKey.currentContext?.findRenderObject() as RenderBox?;
          final inSearch = box != null && (box.localToGlobal(Offset.zero) & box.size).contains(e.position);
          if (!inSearch) _focus.requestFocus();
        },
        child: DropTarget(
          onDragEntered: (_) => setState(() => _dragging = true),
          onDragExited: (_) => setState(() => _dragging = false),
          onDragDone: (d) {
            setState(() => _dragging = false);
            _dropped(d.files.map((f) => f.path));
          },
          child: ListenableBuilder(
            listenable: player,
            builder: (context, _) {
              final visible = _visible();
              player.playlist = visible;
              final rows = _rows(visible);
              return Container(
                foregroundDecoration: _dragging
                    ? BoxDecoration(
                        color: scheme.primary.withValues(alpha: 0.08),
                        border: Border.all(color: scheme.primary, width: 2),
                      )
                    : null,
                // Широкое окно — плеер справа (с эквалайзером), узкое — внизу.
                child: LayoutBuilder(
                  builder: (context, box) {
                    final side = box.maxWidth >= 1100;
                    final list = Column(
                      children: [
                        _toolbar(),
                        _filters(visible),
                        const Divider(height: 1),
                        Expanded(
                          child: player.scanning && player.tracks.isEmpty
                              ? const Center(child: CircularProgressIndicator())
                              : rows.isEmpty
                                  ? Center(
                                      child: Text(
                                        player.tracks.isEmpty
                                            ? tr('No music found. Set the game folder, download addons or open a file.')
                                            : tr('Nothing found.'),
                                        style: const TextStyle(color: Colors.grey),
                                      ),
                                    )
                                  // Высота строк известна заранее — полоса прокрутки не прыгает.
                                  : ListView.builder(
                                      itemExtentBuilder: (i, _) => i < rows.length ? _extent(rows[i]) : null,
                                      itemCount: rows.length,
                                      itemBuilder: (context, i) {
                                        final r = rows[i];
                                        return r is MusicTrack ? _trackRow(r) : _header(r as _Header);
                                      },
                                    ),
                        ),
                        if (!side) ...[
                          const Divider(height: 1),
                          _nowPlaying(),
                        ],
                      ],
                    );
                    if (!side) return list;
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: list),
                        const VerticalDivider(width: 1),
                        SizedBox(width: 500, child: _nowPlaying(side: true)),
                      ],
                    );
                  },
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _toolbar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: _searchKey,
              controller: _search,
              focusNode: _searchFocus,
              decoration: InputDecoration(
                hintText: tr('Search by title, music name, author, file...'),
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: player.scanning
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
            tooltip: tr('Search for music again'),
            onPressed: player.scanning ? null : _rescan,
          ),
          Tooltip(
            message: tr('You can also drag files here'),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.folder_open, size: 18),
              label: Text(tr('Open file...')),
              onPressed: _openFiles,
            ),
          ),
          const SizedBox(width: 8),
          _soundFontMenu(),
        ],
      ),
    );
  }

  /// Список SoundFont для быстрого переключения: встроенный синтезатор,
  /// добавленные файлы (с кнопкой «убрать») и «Добавить…».
  /// MIDI-устройства системы (обновляются при открытии меню).
  List<MidiDevice> _midiDevices = const [];

  Widget _soundFontMenu() {
    final sf2 = player.sf2Path;
    final device = player.midiDevice;
    final accent = Theme.of(context).colorScheme.primary;
    Widget check(bool on) => Icon(on ? Icons.check : null, size: 18, color: accent);
    Widget header(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Text(text, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        );
    final deviceName = device == null
        ? null
        : device == 'win:*'
            ? tr('Windows default (MIDI Mapper)')
            : (_midiDevices.where((d) => d.id == device).firstOrNull?.name ?? device.substring(device.indexOf(':') + 1));
    return MenuAnchor(
      menuChildren: [
        // Куда идёт MIDI: свой синтезатор (SoundFont ниже) или устройство системы.
        header(tr('MIDI output')),
        MenuItemButton(
          leadingIcon: check(device == null),
          onPressed: () => player.setMidiDevice(null),
          child: Text(tr('Launcher synthesizer (SoundFont)')),
        ),
        for (final d in _midiDevices)
          MenuItemButton(
            leadingIcon: check(device == d.id),
            onPressed: () => player.setMidiDevice(d.id),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Text(d.id == 'win:*' ? tr('Windows default (MIDI Mapper)') : d.name,
                  overflow: TextOverflow.ellipsis),
            ),
          ),
        if (_midiDevices.isEmpty)
          MenuItemButton(
            leadingIcon: check(false),
            child: Text(tr('No MIDI devices found'), style: const TextStyle(color: Colors.grey)),
          ),
        const Divider(height: 1),
        header('SoundFont'),
        MenuItemButton(
          leadingIcon: check(sf2 == null),
          onPressed: () => player.setSf2(null),
          child: Text(tr('Built-in synthesizer')),
        ),
        for (final path in player.soundFonts)
          MenuItemButton(
            leadingIcon: check(sf2 == path),
            trailingIcon: IconButton(
              icon: const Icon(Icons.close, size: 16),
              tooltip: tr('Remove from the list'),
              visualDensity: VisualDensity.compact,
              onPressed: () => player.removeSoundFont(path),
            ),
            onPressed: () => player.setSf2(path),
            child: Tooltip(
              message: path,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: Text(
                  File(path).existsSync() ? p.basename(path) : '${p.basename(path)} (${tr('File not found')})',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
        const Divider(height: 1),
        MenuItemButton(
          leadingIcon: const Icon(Icons.add, size: 18),
          onPressed: _addSf2,
          child: Text(tr('Add SoundFont...')),
        ),
      ],
      builder: (context, controller, _) => Tooltip(
        message: deviceName != null
            ? tr('MIDI is played by the MIDI device of the system: {device}.', {'device': deviceName})
            : sf2 ??
                tr('MIDI is played by a simple built-in synthesizer. Choose a SoundFont (.sf2) for real instruments.'),
        child: OutlinedButton.icon(
          icon: const Icon(Icons.piano, size: 18),
          label: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(
                  deviceName != null
                      ? 'MIDI: $deviceName'
                      : sf2 == null
                          ? tr('SoundFont: built-in')
                          : 'SoundFont: ${p.basename(sf2)}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Icon(Icons.arrow_drop_down, size: 18),
            ],
          ),
          onPressed: () {
            if (controller.isOpen) {
              controller.close();
              return;
            }
            // Устройства — заново при каждом открытии (синтезатор могли запустить).
            setState(() => _midiDevices = MidiOut.devices());
            controller.open();
          },
        ),
      ),
    );
  }

  /// Вторая строка: форматы, сортировка, избранное, свернуть/развернуть все
  /// категории и файлы, число треков.
  Widget _filters(List<MusicTrack> visible) {
    final top = {for (final t in visible) t.category == MusicCategory.opened ? t.file : _sectionKey(t)};
    final groups = {...top, for (final t in visible) t.file};
    final allCollapsed = top.isNotEmpty && top.every(_isCollapsed);
    final checked = [for (final t in player.tracks) if (_checked.contains(t.key)) t];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          // Кнопки — слева; узкое окно — переносятся на новую строку.
          Expanded(
            child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _formatFilter(),
          _sortMenu(),
          FilterChip(
            visualDensity: VisualDensity.compact,
            avatar: Icon(player.favoritesOnly ? Icons.star : Icons.star_border, size: 16),
            label: Text(tr('Favorites')),
            selected: player.favoritesOnly,
            showCheckmark: false,
            tooltip: tr('Show only favorite tracks'),
            onSelected: player.setFavoritesOnly,
          ),
          FilterChip(
            visualDensity: VisualDensity.compact,
            avatar: const Icon(Icons.filter_none, size: 16),
            label: Text(tr('Hide duplicates')),
            selected: player.hideDuplicates,
            showCheckmark: false,
            tooltip: tr('The same music in several files (e.g. versions of one addon) is shown once'),
            onSelected: player.setHideDuplicates,
          ),
          TextButton.icon(
            icon: Icon(allCollapsed ? Icons.unfold_more : Icons.unfold_less, size: 18),
            label: Text(allCollapsed ? tr('Expand all') : tr('Collapse all')),
            onPressed: groups.isEmpty ? null : () => _setCollapsed(groups, !allCollapsed),
          ),
          // Отметить треки — экспортировать их разом.
          TextButton.icon(
            icon: Icon(_selecting ? Icons.check_box_outlined : Icons.checklist, size: 18),
            label: Text(_selecting ? tr('Done') : tr('Select')),
            onPressed: () => setState(() {
              _selecting = !_selecting;
              if (!_selecting) _checked.clear();
            }),
          ),
          if (_selecting) ...[
            const SizedBox(width: 4),
            FilledButton.tonalIcon(
              icon: const Icon(Icons.save_alt, size: 18),
              label: Text(tr('Export checked ({n})', {'n': checked.length})),
              onPressed: checked.isEmpty || player.exporting ? null : () => _export(checked),
            ),
            TextButton(
              onPressed: () => setState(() {
                if (_checked.length == visible.length) {
                  _checked.clear();
                } else {
                  _checked.addAll(visible.map((t) => t.key));
                }
              }),
              child: Text(_checked.length == visible.length && visible.isNotEmpty ? tr('Uncheck all') : tr('Check all shown')),
            ),
          ],
        ],
            ),
          ),
          const SizedBox(width: 12),
          // Число треков и что скрыто — у правого края (своя ширина, не
          // половина ряда: иначе строка съезжает в середину).
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
          if (player.exporting) ...[
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, value: player.exportProgress),
            ),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: Text(
                tr('Exporting {done}/{total}: {name}',
                    {'done': player.exportDone + 1, 'total': player.exportTotal, 'name': player.exportName}),
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 16),
              tooltip: tr('Cancel the export'),
              visualDensity: VisualDensity.compact,
              onPressed: player.cancelExport,
            ),
            const SizedBox(width: 8),
          ],
          if (player.readingDetails) ...[
            const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
            const SizedBox(width: 6),
            Text(tr('Reading durations...'), style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(width: 12),
          ],
          Text(
            tr('{n} tracks', {'n': visible.length}),
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
          // Треки, спрятанные фильтром форматов, — чтобы не терялись молча.
          if (player.hiddenFormats.isNotEmpty)
            if (player.tracks.where((t) => player.hiddenFormats.contains(t.format)).length case final n when n > 0)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  tr('· {n} hidden by formats', {'n': n}),
                  style: const TextStyle(fontSize: 12, color: Colors.orangeAccent),
                ),
              ),
          if (player.hideDuplicates)
            if (_duplicateCount() case final n when n > 0)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  tr('· {n} duplicates hidden', {'n': n}),
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Форматы: снятая галочка скрывает формат. Меню не закрывается по клику —
  /// можно снять несколько галочек подряд (как фильтр режимов в Servers).
  Widget _formatFilter() {
    final counts = <MusicFormat, int>{};
    for (final t in player.tracks) {
      counts[t.format] = (counts[t.format] ?? 0) + 1;
    }
    // Скрытые показываем в меню, даже если сейчас таких треков нет.
    final formats = [
      for (final f in MusicFormat.values)
        if (f != MusicFormat.unknown && (counts.containsKey(f) || player.hiddenFormats.contains(f))) f,
    ];
    final hidden = player.hiddenFormats.length;
    return PopupMenuButton<String>(
      tooltip: tr('Uncheck formats to hide them'),
      enabled: formats.isNotEmpty,
      itemBuilder: (context) => [
        for (final f in formats)
          PopupMenuItem<String>(
            enabled: false,
            padding: EdgeInsets.zero,
            child: StatefulBuilder(
              builder: (context, setMenuState) => CheckboxListTile(
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                value: !player.hiddenFormats.contains(f),
                title: Text(
                  '${f.label} (${counts[f] ?? 0})',
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
                ),
                onChanged: (v) {
                  player.setFormatHidden(f, v != true);
                  setMenuState(() {});
                },
              ),
            ),
          ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(value: 'show', enabled: hidden > 0, child: Text(tr('Show all formats'))),
        PopupMenuItem<String>(
          value: 'hide',
          enabled: formats.any((f) => !player.hiddenFormats.contains(f)),
          child: Text(tr('Hide all formats')),
        ),
      ],
      onSelected: (v) {
        if (v == 'show') player.showAllFormats();
        if (v == 'hide') player.setFormatsHidden(formats, true);
      },
      child: Chip(
        visualDensity: VisualDensity.compact,
        avatar: const Icon(Icons.audio_file_outlined, size: 16),
        label: Text(hidden == 0
            ? tr('Formats: all')
            : hidden <= 3
                // Какие именно скрыты — видно сразу.
                ? tr('Hidden: {formats}', {'formats': [for (final f in player.hiddenFormats) f.label].join(', ')})
                : tr('Formats: {n} hidden', {'n': hidden})),
        side: hidden == 0 ? null : BorderSide(color: Theme.of(context).colorScheme.primary),
      ),
    );
  }

  static String _sortLabel(MusicSort s) => switch (s) {
        MusicSort.file => tr('As in the file'),
        MusicSort.title => tr('By title (A–Z)'),
        MusicSort.lump => tr('By music name (A–Z)'),
      };

  Widget _sortMenu() {
    final sorted = player.sort != MusicSort.file;
    return PopupMenuButton<MusicSort>(
      tooltip: tr('Sort'),
      initialValue: player.sort,
      itemBuilder: (context) => [
        for (final s in MusicSort.values)
          CheckedPopupMenuItem<MusicSort>(value: s, checked: player.sort == s, child: Text(_sortLabel(s))),
      ],
      onSelected: player.setSort,
      child: Chip(
        visualDensity: VisualDensity.compact,
        avatar: const Icon(Icons.sort_by_alpha, size: 16),
        label: Text(_sortLabel(player.sort)),
        side: sorted ? BorderSide(color: Theme.of(context).colorScheme.primary) : null,
      ),
    );
  }

  static String _categoryLabel(MusicCategory c) => switch (c) {
        MusicCategory.game => tr('Game files'),
        MusicCategory.addons => tr('Addons'),
        MusicCategory.downloads => tr('Other downloads'),
        MusicCategory.folder => tr('In the game folder'),
        MusicCategory.opened => tr('Opened files'),
      };

  static IconData _categoryIcon(MusicCategory c) => switch (c) {
        MusicCategory.game => Icons.sports_esports_outlined,
        MusicCategory.addons => Icons.extension_outlined,
        MusicCategory.downloads => Icons.download_outlined,
        MusicCategory.folder => Icons.folder_special_outlined,
        MusicCategory.opened => Icons.folder_open,
      };

  Widget _header(_Header h) {
    final collapsed = _isCollapsed(h.id);
    final scheme = Theme.of(context).colorScheme;
    final t = h.first;
    final Widget icon;
    final String label;
    String? tooltip;
    TextStyle style = const TextStyle(fontWeight: FontWeight.bold);
    Color? background;
    switch (h.level) {
      case 0:
        final game = _gameOf(t.game);
        icon = game == null
            ? Icon(_categoryIcon(MusicCategory.opened), size: 24, color: scheme.primary)
            : GameIcon(game, size: 24);
        label = game?.name ?? tr('Opened files');
        style = const TextStyle(fontWeight: FontWeight.bold, fontSize: 15);
        background = scheme.primary.withValues(alpha: 0.16);
      case 1:
        icon = Icon(_categoryIcon(t.category), size: 18, color: scheme.primary);
        label = _categoryLabel(t.category);
        style = TextStyle(fontWeight: FontWeight.w600, color: scheme.primary);
        background = scheme.primary.withValues(alpha: 0.06);
      default:
        icon = Icon(
          t.category == MusicCategory.opened && t.entry.isEmpty ? Icons.audio_file_outlined : Icons.inventory_2_outlined,
          size: 18,
          color: Colors.grey,
        );
        // Название аддона из репозитория — рядом с именем файла.
        final addon = player.labelOf(t.file);
        label = addon.isEmpty ? p.basename(t.file) : '$addon — ${p.basename(t.file)}';
        tooltip = t.file;
        background = Colors.black26;
    }
    // Отступ по уровню; у открытых вручную файлов нет категории.
    final indent = switch (h.level) {
      0 => 0,
      1 => 1,
      _ => t.category == MusicCategory.opened ? 1 : 2,
    };
    final manual = h.level == 2 && t.category == MusicCategory.opened;
    final text = Text(label, overflow: TextOverflow.ellipsis, style: style);
    return Material(
      color: background,
      child: InkWell(
        onTap: () => _setCollapsed([h.id], !collapsed),
        child: Padding(
          padding: EdgeInsets.only(left: 8.0 + indent * 16, right: 8),
          child: Row(
            children: [
              Icon(collapsed ? Icons.chevron_right : Icons.expand_more, size: 20, color: Colors.grey),
              const SizedBox(width: 4),
              icon,
              const SizedBox(width: 8),
              Expanded(
                child: Row(
                  children: [
                    Flexible(child: tooltip == null ? text : Tooltip(message: tooltip, child: text)),
                    const SizedBox(width: 8),
                    Text('${h.count}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  ],
                ),
              ),
              if (h.level == 0 && t.game.isNotEmpty) _gameFilesHint(t.game),
              if (h.level == 2) ...[
                IconButton(
                  icon: const Icon(Icons.folder_open, size: 16),
                  tooltip: tr('Show the file in its folder'),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => showFileInFolder(context, t.file),
                ),
                IconButton(
                  icon: const Icon(Icons.save_alt, size: 16),
                  tooltip: tr('Export the music of this file...'),
                  visualDensity: VisualDensity.compact,
                  onPressed: player.exporting
                      ? null
                      : () => _export([for (final x in player.tracks) if (x.file == t.file) x]),
                ),
              ],
              if (manual)
                IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  tooltip: tr('Remove from the player'),
                  onPressed: () => player.removeManualFile(t.file),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Какие файлы игры с музыкой нашлись и сколько в них треков (значок у
  /// названия игры; оранжевый — в файлах игры музыки нет).
  Widget _gameFilesHint(String game) {
    final files = player.gameFilesOf(game);
    final missing = player.missingGameFiles[game] ?? const <String>[];
    final total = files.fold<int>(0, (n, f) => n + f.$2);
    String formats(String path) =>
        [for (final e in player.formatsOf(path).entries) '${e.key.label} ${e.value}'].join(', ');
    // Сколько треков файлов игры спрятал фильтр форматов.
    var hiddenByFilter = 0;
    for (final (path, _) in files) {
      for (final e in player.formatsOf(path).entries) {
        if (player.hiddenFormats.contains(e.key)) hiddenByFilter += e.value;
      }
    }
    final lines = [
      tr('Game files with music:'),
      for (final (path, n) in files)
        '  ${p.basename(path)} — ${tr('{n} tracks', {'n': n})}${n > 0 ? ' (${formats(path)})' : ''}',
      if (files.isEmpty) '  —',
      if (missing.isNotEmpty) tr('Not found: {files}', {'files': missing.join(', ')}),
      if (total == 0) tr('No music in the game files: check the game folder in Settings.'),
      if (hiddenByFilter > 0) tr('{n} of them are hidden by the format filter.', {'n': hiddenByFilter}),
    ];
    final warn = total == 0 || hiddenByFilter > 0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Tooltip(
        message: lines.join('\n'),
        child: Icon(
          warn ? Icons.warning_amber_rounded : Icons.info_outline,
          size: 18,
          color: warn ? Colors.orangeAccent : Colors.grey,
        ),
      ),
    );
  }

  /// Уровни трека для подписи: «Greenflower Zone 1 +2».
  String _levelsNote(List<LevelRef> levels) {
    if (levels.isEmpty) return '';
    final l = levels.first;
    final first = '${l.title.isEmpty ? l.map : srb2PlainTitle(l.title)}${l.encore ? ' (Encore)' : ''}';
    return levels.length == 1 ? first : '$first +${levels.length - 1}';
  }

  Widget _trackRow(MusicTrack t) {
    final isCurrent = player.current?.key == t.key;
    final unsupported = !t.format.playable;
    final scheme = Theme.of(context).colorScheme;
    final levels = player.levelsOf(t);
    final original = player.originalOf(t);
    final special = specialMusicName(t.lump);
    final subtitle = [
      ?special,
      t.lump,
      if (t.displayAuthors.isNotEmpty) t.displayAuthors,
      if (t.details?.game.isNotEmpty ?? false) t.details!.game,
      t.format.label,
    ].join(' · ');
    final duration = t.duration;
    final favorite = player.isFavorite(t);
    final tile = ListTile(
      dense: true,
      selected: isCurrent,
      enabled: !unsupported,
      contentPadding: EdgeInsets.only(left: t.category == MusicCategory.opened ? 52.0 : 68.0, right: 8),
      leading: _selecting
          ? Checkbox(
              value: _checked.contains(t.key),
              onChanged: (v) => setState(() => v == true ? _checked.add(t.key) : _checked.remove(t.key)),
            )
          : Icon(
              isCurrent
                  ? (player.loading ? Icons.hourglass_top : (player.playing ? Icons.volume_up : Icons.pause))
                  : Icons.music_note,
              color: isCurrent ? scheme.primary : null,
            ),
      title: Text(
        t.altTitle.isEmpty ? t.displayTitle : '${t.displayTitle} — ${t.altTitle}',
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Row(
        children: [
          Flexible(child: Text(subtitle, overflow: TextOverflow.ellipsis)),
          if (original != null) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: tr('Replaces the game track {name}', {'name': original.displayTitle}),
              child: Icon(Icons.swap_horiz, size: 14, color: scheme.tertiary),
            ),
          ],
          // Та же музыка есть и в других файлах (копии скрыты).
          if (player.hideDuplicates)
            if (player.copiesOf(t) case final copies when copies.isNotEmpty) ...[
              const SizedBox(width: 6),
              Tooltip(
                message: tr('Also in:\n{files}', {
                  'files': {for (final c in copies) p.basename(c.file)}.join('\n'),
                }),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.filter_none, size: 12, color: Colors.grey),
                    const SizedBox(width: 2),
                    Text('${copies.length}', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                  ],
                ),
              ),
            ],
          if (levels.isNotEmpty) ...[
            const SizedBox(width: 6),
            Icon(Icons.map_outlined, size: 13, color: scheme.primary),
            const SizedBox(width: 2),
            Flexible(
              child: Tooltip(
                message: [for (final l in levels) l.title.isEmpty ? l.map : '${srb2PlainTitle(l.title)} (${l.map})'].join('\n'),
                child: Text(_levelsNote(levels), overflow: TextOverflow.ellipsis, style: TextStyle(color: scheme.primary)),
              ),
            ),
          ],
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (duration != null)
            Text(_time(duration), style: const TextStyle(fontSize: 12, color: Colors.grey, fontFeatures: [FontFeature.tabularFigures()])),
          IconButton(
            icon: Icon(favorite ? Icons.star : Icons.star_border, size: 18, color: favorite ? Colors.amber : Colors.grey),
            tooltip: favorite ? tr('Remove from favorites') : tr('Add to favorites'),
            visualDensity: VisualDensity.compact,
            onPressed: () => player.toggleFavorite(t),
          ),
        ],
      ),
      onTap: _selecting
          ? () => setState(() => _checked.contains(t.key) ? _checked.remove(t.key) : _checked.add(t.key))
          : unsupported
              ? null
              : () => player.play(t),
    );
    return unsupported ? Tooltip(message: tr('This format cannot be played in the launcher'), child: tile) : tile;
  }

  String _status(MusicTrack? t, String loopNote) {
    if (player.error != null) return tr(player.error!);
    if (player.warning != null && !player.loading) return player.warning!;
    if (player.loading) {
      final progress = player.renderProgress;
      final format = player.currentFormat ?? t?.format;
      final synth = format?.isSynth ?? false;
      if (progress != null) {
        final n = (progress * 100).floor();
        return synth || format == null
            ? tr('Rendering MIDI... {n}%', {'n': n})
            : tr('Rendering {format}... {n}%', {'format': format.label, 'n': n});
      }
      return synth ? tr('Rendering MIDI...') : tr('Loading...');
    }
    final special = t == null ? null : specialMusicName(t.lump);
    return [
      if (_gameOf(t?.game ?? '') case final game?) game.name,
      ?special,
      if (t != null) t.lump,
      if (t != null && t.displayAuthors.isNotEmpty) t.displayAuthors,
      if (t?.details?.game.isNotEmpty ?? false) t!.details!.game,
      if (player.currentFormat != null && t != null) player.currentFormat!.label,
      if (loopNote.isNotEmpty) loopNote,
    ].join(' · ');
  }

  /// Экспорт треков [list] оригиналами: выбор папки, затем — в фоне.
  Future<void> _export(List<MusicTrack> list) async {
    if (list.isEmpty || player.exporting) return;
    AppLog.action('open the getDirectoryPath dialog (player_tab.dart)');
    final dir = await getDirectoryPath(initialDirectory: player.lastExportDir, confirmButtonText: tr('Export here'));
    if (dir == null || !mounted) return;
    final (saved, errors) = await player.export(list, dir);
    if (!mounted) return;
    showSnack(
      context,
      SnackBar(
        content: Text(errors.isEmpty
            ? tr('Exported: {n}', {'n': saved})
            : '${tr('Exported: {n}', {'n': saved})}\n${tr('Not exported: {n}', {'n': errors.length})} — ${errors.first}'),
        action: SnackBarAction(label: tr('Open folder'), onPressed: () => showFileInFolder(context, dir)),
      ),
    );
  }

  /// Откуда трек: «Аддон (файл.pk3)» или имя файла.
  String _sourceOf(MusicTrack t) {
    final label = player.labelOf(t.file);
    final file = p.basename(t.file);
    return label.isEmpty ? file : '$label ($file)';
  }

  /// Когда трек доиграл: по нажатию — по кругу: весь список → до конца
  /// списка → трек с начала → трек с циклом (с точки петли).
  Widget _repeatButton() => _repeatIconButton(context, player);

  /// Сравнение: трек аддона ↔ трек игры, который он заменяет, — с того же
  /// места.
  Widget? _compareButton(MusicTrack t) {
    final original = player.originalOf(t);
    final others = original != null ? [original] : player.replacementsOf(t);
    if (others.isEmpty) return null;
    String label(MusicTrack x) => x.category == MusicCategory.game
        ? tr('Original: {name}', {'name': x.displayTitle})
        : tr('Replacement from {file}', {'file': p.basename(x.file)});
    void open(MusicTrack x) => player.play(x, from: player.position);
    if (others.length == 1) {
      return IconButton(
        icon: const Icon(Icons.compare_arrows),
        tooltip: tr('{what} — from the same moment', {'what': label(others.first)}),
        onPressed: () => open(others.first),
      );
    }
    return PopupMenuButton<MusicTrack>(
      icon: const Icon(Icons.compare_arrows),
      tooltip: tr('Compare with a replacement from an addon'),
      itemBuilder: (context) => [for (final x in others) PopupMenuItem(value: x, child: Text(label(x)))],
      onSelected: open,
    );
  }

  /// Дорожки многодорожечного файла (NSF, GBS...).
  Widget? _subtrackMenu(MusicTrack t) {
    final count = t.details?.subtracks ?? 1;
    if (count <= 1) return null;
    return PopupMenuButton<int>(
      tooltip: tr('Track of the file'),
      initialValue: player.subtrack,
      itemBuilder: (context) => [
        for (var i = 0; i < count; i++)
          CheckedPopupMenuItem(value: i, checked: player.subtrack == i, child: Text(tr('Track {n}', {'n': i + 1}))),
      ],
      onSelected: player.setSubtrack,
      child: Chip(
        visualDensity: VisualDensity.compact,
        avatar: const Icon(Icons.queue_music, size: 16),
        label: Text('${player.subtrack + 1}/$count'),
      ),
    );
  }

  /// «Играет на»: уровни трека с картинками; щелчок выбирает уровень в Launch.
  Widget _levelsRow(MusicTrack t) {
    final levels = player.levelsOf(t);
    if (levels.isEmpty || t.game.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: SizedBox(
        height: 40,
        child: Row(
          children: [
            Text(tr('Plays on:'), style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(width: 8),
            Expanded(
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: levels.length,
                separatorBuilder: (_, _) => const SizedBox(width: 6),
                itemBuilder: (context, i) {
                  final l = levels[i];
                  final addon = l.fromTrackFile || t.category != MusicCategory.game ? t.file : null;
                  return _LevelChip(
                    level: l,
                    picture: player.levelPicture(t.game, l.map, file: t.category == MusicCategory.game ? null : t.file),
                    onTap: widget.onWarp == null ? null : () => widget.onWarp!(t.game, l.map, addon, encore: l.encore),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Что играет и кнопки управления. [side] — панель справа (широкое окно):
  /// спектр, всё в столбик; иначе — полоса внизу.
  Widget _nowPlaying({bool side = false}) {
    final t = player.current;
    final maxMs = player.length.inMilliseconds.toDouble();
    final loop = player.loopStart != null && !(player.currentFormat?.isSynth ?? false) ? player.loopStart! : null;
    final loopNote = loop != null ? tr('Loop from {time}', {'time': _time(loop)}) : '';
    // Отметка начала петли на ползунке.
    final loopMark = loop != null && maxMs > 0 && loop > Duration.zero && loop.inMilliseconds < maxMs
        ? loop.inMilliseconds / maxMs
        : null;
    final scheme = Theme.of(context).colorScheme;
    final favorite = t != null && player.isFavorite(t);
    final compare = t == null ? null : _compareButton(t);
    final subtracks = t == null ? null : _subtrackMenu(t);
    final Widget info = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (_gameOf(t?.game ?? '') case final game?) ...[
                          Tooltip(
                            message: game.name,
                            child: GameIcon(game, size: 18),
                          ),
                          const SizedBox(width: 6),
                        ],
                        Flexible(
                          child: Text(
                            t == null ? tr('Nothing is playing') : t.displayTitle,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                          ),
                        ),
                        if (t != null)
                          IconButton(
                            icon: Icon(favorite ? Icons.star : Icons.star_border,
                                size: 18, color: favorite ? Colors.amber : Colors.grey),
                            tooltip: favorite ? tr('Remove from favorites') : tr('Add to favorites'),
                            visualDensity: VisualDensity.compact,
                            onPressed: () => player.toggleFavorite(t),
                          ),
                      ],
                    ),
                    Text(
                      _status(t, loopNote),
                      maxLines: player.error != null || player.warning != null ? 2 : 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12,
                          color: player.error != null
                              ? Colors.redAccent
                              : (player.warning != null && !player.loading ? Colors.orangeAccent : Colors.grey)),
                    ),
                    // Откуда трек: аддон и файл — открыть папку, экспортировать.
                    if (t != null)
                      Row(
                        children: [
                          const Icon(Icons.inventory_2_outlined, size: 14, color: Colors.grey),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Tooltip(
                              message: t.file,
                              child: Text(
                                tr('From: {source}', {'source': _sourceOf(t)}),
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12, color: Colors.grey),
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.folder_open, size: 16),
                            tooltip: tr('Show the file in its folder'),
                            visualDensity: VisualDensity.compact,
                            onPressed: () => showFileInFolder(context, t.file),
                          ),
                          IconButton(
                            icon: const Icon(Icons.save_alt, size: 16),
                            tooltip: tr('Export this track...'),
                            visualDensity: VisualDensity.compact,
                            onPressed: player.exporting ? null : () => _export([t]),
                          ),
                        ],
                      ),
                  ],
                );
    final transport = <Widget>[
      _shuffleIconButton(context, player),
      IconButton(icon: const Icon(Icons.skip_previous), tooltip: tr('Previous (Ctrl+←)'), onPressed: player.previous),
      IconButton.filled(
        iconSize: 32,
        icon: Icon(player.playing ? Icons.pause : Icons.play_arrow),
        tooltip: player.playing ? tr('Pause (Space)') : tr('Play (Space)'),
        onPressed: t == null && player.playlist.isEmpty ? null : player.togglePause,
      ),
      IconButton(icon: const Icon(Icons.skip_next), tooltip: tr('Next (Ctrl+→)'), onPressed: player.next),
      IconButton(icon: const Icon(Icons.stop), tooltip: tr('Stop'), onPressed: player.stop),
    ];
    // Режимы: оригинал/замена, дорожка, повтор.
    final modes = <Widget>[
      ?compare,
      ?subtracks,
      _repeatButton(),
    ];
    final mute = _MuteButton(player);
    final volume = _VolumeSlider(player);
    final extras = <Widget>[
      if (t != null) _levelsRow(t),
      if (player.loading && player.renderProgress != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: LinearProgressIndicator(value: player.renderProgress),
        ),
    ];
    // Позиция меняется 4 раза в секунду — перерисовывается только эта строка.
    final positionRow = ValueListenableBuilder<Duration>(
            valueListenable: player.positionListenable,
            builder: (context, position, _) => Row(
              children: [
                SizedBox(width: 52, child: Text(_time(position), style: const TextStyle(fontSize: 12))),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackShape: loopMark == null ? null : _LoopMarkTrackShape(loopMark, scheme.tertiary),
                    ),
                    child: Slider(
                      value: position.inMilliseconds.toDouble().clamp(0.0, maxMs <= 0 ? 0.0 : maxMs),
                      max: maxMs <= 0 ? 1 : maxMs,
                      onChanged: maxMs <= 0 ? null : (v) => player.seek(Duration(milliseconds: v.round())),
                    ),
                  ),
                ),
                SizedBox(
                  width: 52,
                  child: Text(_time(player.length), textAlign: TextAlign.end, style: const TextStyle(fontSize: 12)),
                ),
              ],
            ),
          );

    if (side) {
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Полосы спектра над названием — пока играет и окно активно.
            const SizedBox(height: 12),
            SizedBox(height: 280, child: MusicVisualizer(player: player)),
            const SizedBox(height: 16),
            info,
            ...extras,
            const SizedBox(height: 8),
            positionRow,
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: transport,
            ),
            Row(
              children: [
                ...modes,
                const SizedBox(width: 8),
                mute,
                Expanded(child: volume),
              ],
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: info),
              ...transport,
              const SizedBox(width: 8),
              ...modes,
              const SizedBox(width: 8),
              mute,
              SizedBox(width: 120, child: volume),
            ],
          ),
          ...extras,
          positionRow,
        ],
      ),
    );
  }
}

/// Кнопка звука: перерисовывается только при смене громкости.
class _MuteButton extends StatelessWidget {
  final MusicPlayer player;
  const _MuteButton(this.player);

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<double>(
        valueListenable: player.volumeListenable,
        builder: (context, volume, _) => IconButton(
          icon: Icon(volume == 0 ? Icons.volume_off : Icons.volume_down, size: 20),
          tooltip: volume == 0 ? tr('Turn the sound on') : tr('Turn the sound off'),
          onPressed: player.toggleMute,
        ),
      );
}

/// Ползунок громкости: двигается — перерисовывается только он сам.
class _VolumeSlider extends StatelessWidget {
  final MusicPlayer player;
  const _VolumeSlider(this.player);

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<double>(
        valueListenable: player.volumeListenable,
        builder: (context, volume, _) => Slider(value: volume, onChanged: player.setVolume),
      );
}

/// Кнопка повтора: щелчок переключает режим по кругу.
Widget _repeatIconButton(BuildContext context, MusicPlayer player, {double? size}) {
  final scheme = Theme.of(context).colorScheme;
  final (icon, tip) = switch (player.repeat) {
    PlayerRepeat.list => (Icons.repeat, tr('Repeat the whole list')),
    PlayerRepeat.once => (Icons.playlist_play, tr('Play to the end of the list')),
    PlayerRepeat.track => (Icons.repeat_one, tr('Repeat the track from the start')),
    PlayerRepeat.loop => (Icons.all_inclusive, tr('Repeat the track with its loop (from the LOOPMS point)')),
  };
  return IconButton(
    icon: Icon(icon, size: size),
    color: player.repeat == PlayerRepeat.once ? null : scheme.primary,
    tooltip: tip,
    onPressed: player.cycleRepeat,
  );
}

/// Кнопка перемешивания.
Widget _shuffleIconButton(BuildContext context, MusicPlayer player, {double? size}) => IconButton(
      icon: Icon(Icons.shuffle, size: size),
      color: player.shuffle ? Theme.of(context).colorScheme.primary : Colors.grey,
      tooltip: player.shuffle ? tr('Shuffle is on') : tr('Shuffle is off'),
      onPressed: () => player.setShuffle(!player.shuffle),
    );

/// Уровень с картинкой (MAPxxP / PICTURE) — «играет на».
class _LevelChip extends StatelessWidget {
  final LevelRef level;
  final Future<Uint8List?> picture;
  final VoidCallback? onTap;
  const _LevelChip({required this.level, required this.picture, this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = level.title.isEmpty ? level.map : srb2PlainTitle(level.title);
    final encoreNote = !level.encore
        ? ''
        : '\n${level.byName ? tr('Encore version by its name: the game itself does not play it, only a Lua script of an addon can.') : tr('Plays in Encore mode.')}';
    return Tooltip(
      message: (onTap == null
              ? '$title (${level.map})'
              : level.encore
                  ? tr('{title} ({map}): click to choose it for -warp with Encore mode in Launch',
                      {'title': title, 'map': level.map})
                  : tr('{title} ({map}): click to choose it for -warp in Launch', {'title': title, 'map': level.map})) +
          encoreNote,
      child: Material(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FutureBuilder<Uint8List?>(
                future: picture,
                builder: (context, snap) {
                  final image = snap.data;
                  return image == null
                      ? Image.asset('assets/map_unknown.png',
                          width: 64, height: 40, fit: BoxFit.cover, filterQuality: FilterQuality.none)
                      : Image.memory(image,
                          width: 64, height: 40, fit: BoxFit.cover, filterQuality: FilterQuality.none, gaplessPlayback: true);
                },
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 180),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      level.title.isEmpty
                          ? Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12))
                          : srb2Title(level.title, style: const TextStyle(fontSize: 12)),
                      if (level.encore)
                        Text(level.byName ? 'Encore (Lua)' : 'Encore',
                            style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: scheme.primary)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Мини-плеер внизу окна на других вкладках: что играет и основные кнопки.
/// Щелчок по названию открывает вкладку плеера.
class MiniPlayer extends StatelessWidget {
  final MusicPlayer player;
  final VoidCallback onOpen;
  const MiniPlayer({super.key, required this.player, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final t = player.current;
        if (t == null) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        final total = player.length.inMilliseconds;
        final game = _gameOf(t.game);
        return Material(
          color: scheme.surfaceContainerHigh,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ValueListenableBuilder<Duration>(
                valueListenable: player.positionListenable,
                builder: (context, position, _) => LinearProgressIndicator(
                  minHeight: 2,
                  value: player.loading
                      ? player.renderProgress
                      : (total <= 0 ? 0 : (position.inMilliseconds / total).clamp(0.0, 1.0)),
                ),
              ),
              SizedBox(
                height: 44,
                child: Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: onOpen,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Row(
                            children: [
                              if (game != null) ...[
                                GameIcon(game, size: 18),
                                const SizedBox(width: 8),
                              ] else ...[
                                const Icon(Icons.music_note, size: 18),
                                const SizedBox(width: 8),
                              ],
                              Flexible(
                                child: Text(
                                  t.displayTitle,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontWeight: FontWeight.bold),
                                ),
                              ),
                              const SizedBox(width: 12),
                              ValueListenableBuilder<Duration>(
                                valueListenable: player.positionListenable,
                                builder: (context, position, _) => Text(
                                  player.loading ? tr('Loading...') : '${_time(position)} / ${_time(player.length)}',
                                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    _shuffleIconButton(context, player, size: 20),
                    IconButton(
                      icon: const Icon(Icons.skip_previous, size: 20),
                      tooltip: tr('Previous'),
                      onPressed: player.previous,
                    ),
                    IconButton(
                      icon: Icon(player.playing ? Icons.pause : Icons.play_arrow, size: 22),
                      tooltip: player.playing ? tr('Pause') : tr('Play'),
                      onPressed: player.togglePause,
                    ),
                    IconButton(
                      icon: const Icon(Icons.skip_next, size: 20),
                      tooltip: tr('Next'),
                      onPressed: player.next,
                    ),
                    IconButton(
                      icon: const Icon(Icons.stop, size: 20),
                      tooltip: tr('Stop'),
                      onPressed: player.stop,
                    ),
                    _repeatIconButton(context, player, size: 20),
                    _MuteButton(player),
                    SizedBox(
                      width: 100,
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 2,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                          overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                        ),
                        child: _VolumeSlider(player),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.open_in_full, size: 18),
                      tooltip: tr('Open the player'),
                      onPressed: onOpen,
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      tooltip: tr('Close the player (stops the music)'),
                      onPressed: player.close,
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Медиаклавиши клавиатуры (Play/Pause, Next, Previous, Stop) — когда окно
/// лаунчера активно. true — клавиша обработана.
bool handlePlayerMediaKey(MusicPlayer player, KeyEvent e) {
  if (e is! KeyDownEvent) return false;
  final key = e.logicalKey;
  if (key == LogicalKeyboardKey.mediaPlayPause) {
    player.togglePause();
  } else if (key == LogicalKeyboardKey.mediaPlay) {
    if (!player.playing) player.togglePause();
  } else if (key == LogicalKeyboardKey.mediaPause) {
    if (player.playing) player.togglePause();
  } else if (key == LogicalKeyboardKey.mediaTrackNext) {
    player.next();
  } else if (key == LogicalKeyboardKey.mediaTrackPrevious) {
    player.previous();
  } else if (key == LogicalKeyboardKey.mediaStop) {
    player.stop();
  } else {
    return false;
  }
  return true;
}

/// Дорожка ползунка с отметкой начала петли (доля [mark] от длины трека).
class _LoopMarkTrackShape extends RoundedRectSliderTrackShape {
  final double mark;
  final Color color;
  const _LoopMarkTrackShape(this.mark, this.color);

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    super.paint(
      context,
      offset,
      parentBox: parentBox,
      sliderTheme: sliderTheme,
      enableAnimation: enableAnimation,
      textDirection: textDirection,
      thumbCenter: thumbCenter,
      secondaryOffset: secondaryOffset,
      isDiscrete: isDiscrete,
      isEnabled: isEnabled,
      additionalActiveTrackHeight: additionalActiveTrackHeight,
    );
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final x = textDirection == TextDirection.rtl ? rect.right - rect.width * mark : rect.left + rect.width * mark;
    final marker = Rect.fromCenter(center: Offset(x, rect.center.dy), width: 3, height: rect.height + 12);
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(marker, const Radius.circular(1.5)),
      Paint()..color = color,
    );
  }
}
