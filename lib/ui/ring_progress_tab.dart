import 'dart:io';

import 'package:flutter/material.dart';

import '../i18n.dart';
import '../models/game.dart';
import '../services/characters.dart';
import '../services/game_progress.dart' show formatTics;
import '../services/launch_state.dart';
import '../services/ring_progress.dart';
import 'character_picker.dart';
import 'save_guard_dialogs.dart';
import 'srb2_text.dart';

/// Вкладка Progress для Dr. Robotnik's Ring Racers: ringdata.dat (время,
/// раунды, кольца, ключи Чао, кубки Гран-при, персонажи, рекорды карт) и
/// ringprofiles.prf (профили игроков).
class RingProgressTab extends StatefulWidget {
  final GameDef game;
  final String? gameFolder;
  final Future<List<String>> Function(List<String> relative) gameFiles;

  /// Персонажи игры (иконки лучших персонажей кубков и профилей).
  final Future<List<CharacterInfo>> Function() characters;

  /// Играть: игра без аддонов и параметров Launch.
  final void Function(List<String> files) onPlay;

  /// «Копии сохранений»: true — какой-то файл заменён копией.
  final Future<bool> Function()? onBackups;

  const RingProgressTab({
    super.key,
    required this.game,
    required this.gameFolder,
    required this.gameFiles,
    required this.characters,
    required this.onPlay,
    this.onBackups,
  });

  @override
  State<RingProgressTab> createState() => _RingProgressTabState();
}

class _RingProgressTabState extends State<RingProgressTab> {
  // Между открытиями вкладки: прочитанные файлы (по времени изменения).
  static (String, DateTime?, Future<RingProgress>)? _cache;

  Future<RingProgress>? _future;
  Map<String, CharacterInfo> _chars = const {};

  @override
  void initState() {
    super.initState();
    _future = _load();
    widget.characters().then((list) {
      if (!mounted) return;
      setState(() => _chars = {for (final c in list) c.name.toLowerCase(): c});
    }).catchError((Object _) {});
  }

  Future<RingProgress>? _load({bool force = false}) {
    final folder = widget.gameFolder;
    if (folder == null) return null;
    DateTime? modified;
    try {
      modified = File('$folder${Platform.pathSeparator}${RingProgress.dataFile}').lastModifiedSync();
    } catch (_) {}
    final c = _cache;
    if (!force && c != null && c.$1 == folder && c.$2 == modified) return c.$3;
    final future = () async {
      // SOC (кубки, медали, испытания, названия карт) — во всех файлах игры.
      final files = await widget.gameFiles(const [
        'bios.pk3', 'data/scripts.pk3', 'data/gfx.pk3', 'data/maps.pk3', 'data/unlocks.pk3', //
      ]);
      final palettes = await widget.gameFiles(widget.game.paletteFiles);
      return RingProgress.load(folder, files, palettes);
    }();
    _cache = (folder, modified, future);
    return future;
  }

  void _reload() => setState(() => _future = _load(force: true));

  @override
  Widget build(BuildContext context) {
    if (widget.gameFolder == null) {
      return _message(Icons.folder_off_outlined, tr('Set the game folder in Settings: ringdata.dat is there.'));
    }
    return FutureBuilder<RingProgress>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
        if (snap.hasError) {
          final path = '${widget.gameFolder}${Platform.pathSeparator}${RingProgress.dataFile}';
          if (snap.error is FormatException && File(path).existsSync()) {
            return DamagedSaveView(gameId: widget.game.id, path: path, error: snap.error!, onRestored: _reload);
          }
          return _message(Icons.error_outline,
              tr('Could not read {file}: {error}', {'file': RingProgress.dataFile, 'error': snap.error!}),
              retry: true);
        }
        final r = snap.data!;
        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
          children: [
            _summary(r),
            if (r.profiles.isNotEmpty) ...[
              _section(tr('Profiles ({n})', {'n': r.profiles.length})),
              Wrap(spacing: 12, runSpacing: 12, children: [for (final pr in r.profiles) _profile(pr)]),
            ],
            _section(tr('Grand Prix cups')),
            _cups(r),
            ..._characters(r),
            ..._maps(r),
          ],
        );
      },
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
              Text(text, textAlign: TextAlign.center),
              if (retry) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(icon: const Icon(Icons.refresh), label: Text(tr('Reload')), onPressed: _reload),
              ],
            ],
          ),
        ),
      );

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 10),
        child: Text(title,
            style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary)),
      );

  static String _hours(int tics) {
    final t = tics ~/ 35;
    return tr('{h} h {m} min {s} s', {'h': t ~/ 3600, 'm': t ~/ 60 % 60, 's': t % 60});
  }

  static String _modeName(String mode) => switch (mode) {
        'race' => tr('Race'),
        'battle' => tr('Battle'),
        'prisons' => tr('Prison Break'),
        'special' => tr('Special Stages'),
        'timeattack' => tr('Time Attack'),
        'spbattack' => tr('SPB Attack'),
        'tumble' => tr('Tumble'),
        'netgame' => tr('Online'),
        'custom' => tr('Custom'),
        'menus' => tr('Menus'),
        _ => mode,
      };

  // --- Сводка ---

  Widget _summary(RingProgress r) {
    final d = r.data;
    final definedChallenges = r.defs.challenges.values.where((u) => u.name.isNotEmpty).toList();
    final challengesGot = definedChallenges.isEmpty
        ? d.unlockedCount
        : definedChallenges.where((u) => u.number - 1 < d.unlocked.length && d.unlocked[u.number - 1]).length;
    Widget big(String label, String value, {String? sub}) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: const TextStyle(color: Colors.grey)),
            Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            if (sub != null) Text(sub, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        );
    final modes = [for (final m in ringModes) if ((d.playTime[m] ?? 0) > 0) m];
    final rounds = [for (final e in d.rounds.entries) if (e.value > 0) e];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Wrap(
                spacing: 40,
                runSpacing: 16,
                children: [
                  big(tr('Total play time'), _hours(d.playTimeTotal)),
                  big(tr('Rounds'), '${rounds.fold<int>(0, (s, e) => s + e.value)}',
                      sub: rounds.map((e) => '${_modeName(e.key)}: ${e.value}').join(' · ')),
                  big(tr('Rings collected'), '${d.totalRings}'),
                  big(tr('Chao Keys'), '${d.chaoKeys}'),
                  big(tr('Challenges'),
                      definedChallenges.isEmpty ? '$challengesGot' : '$challengesGot/${definedChallenges.length}'),
                  if (r.defs.medals.isNotEmpty || d.emblemsCollected > 0)
                    big(tr('Medals'),
                        r.defs.medals.isEmpty ? '${d.emblemsCollected}' : '${d.emblemsCollected}/${r.defs.medals.length}'),
                  if (modes.isNotEmpty)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 520),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final m in modes)
                            Chip(
                              visualDensity: VisualDensity.compact,
                              label: Text('${_modeName(m)}: ${_hours(d.playTime[m]!)}',
                                  style: const TextStyle(fontSize: 12)),
                            ),
                        ],
                      ),
                    ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 320),
                    child: Text(
                      r.modified == null
                          ? tr('{file} not found: the game creates it when you play.', {'file': RingProgress.dataFile})
                          : '${r.dataPath}\n${tr('Saved by the game: {time}', {'time': _date(r.modified!)})}',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Tooltip(
                  message: tr('Start the game without addons and without the Launch parameters, so it saves your progress.'),
                  child: ValueListenableBuilder<bool>(
                    valueListenable: launchPreparing,
                    builder: (context, busy, _) => FilledButton.icon(
                      icon: busy
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.play_arrow),
                      label: Text(busy ? tr('Checking...') : tr('Play game')),
                      onPressed: busy ? null : () => widget.onPlay(const []),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.onBackups != null)
                      IconButton(
                        icon: const Icon(Icons.history),
                        tooltip: tr('Save backups'),
                        onPressed: () async {
                          if (await widget.onBackups!() && mounted) _reload();
                        },
                      ),
                    IconButton(icon: const Icon(Icons.refresh), tooltip: tr('Reload'), onPressed: _reload),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _date(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.day)}.${two(t.month)}.${t.year} ${two(t.hour)}:${two(t.minute)}';
  }

  // --- Профили ---

  List<int>? _ramp(String color) =>
      color.isEmpty || color.toLowerCase() == 'default' ? null : CharacterScanner.findColor(widget.game.skinColors, color);

  Widget _profile(RingProfile pr) {
    final c = _chars[pr.skin];
    final rate = pr.rounds > 0 ? ' (${(pr.wins * 100 / pr.rounds).round()}%)' : '';
    return SizedBox(
      width: 300,
      child: Card(
        child: ListTile(
          leading: CharacterIcon(c, size: 40, ramp: _ramp(pr.color)),
          title: Text(pr.playerName.isEmpty ? pr.name : pr.playerName,
              style: const TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Text([
            c?.realname ?? pr.skin,
            if (pr.color.isNotEmpty && pr.color.toLowerCase() != 'default') pr.color,
            if (pr.follower.isNotEmpty && pr.follower.toLowerCase() != 'none') tr('follower: {name}', {'name': pr.follower}),
            tr('wins {wins} of {rounds}', {'wins': pr.wins, 'rounds': pr.rounds}) + rate,
          ].join('\n')),
          isThreeLine: true,
        ),
      ),
    );
  }

  // --- Кубки ---

  Widget _cups(RingProgress r) {
    final d = r.data;
    // Кубки по порядку SOC; кубки из ringdata.dat без описания (аддоны) — в конце.
    final ids = [
      for (final c in r.defs.cups) c.id,
      for (final id in d.cups.keys) if (!r.defs.cups.any((c) => c.id == id)) id,
    ];
    if (ids.isEmpty) {
      return Text(tr('No cups played yet.'), style: const TextStyle(color: Colors.grey));
    }
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        for (final id in ids) _cup(r, r.defs.cups.where((c) => c.id == id).firstOrNull ?? RingCup(id), d.cups[id]),
      ],
    );
  }

  static Color _gradeColor(int g) => switch (g) {
        0 => const Color(0xFF5A8CFF), // E — синий
        1 => const Color(0xFF7BC74D), // D — зелёный
        2 => const Color(0xFFFFA347), // C — оранжевый
        3 => const Color(0xFFF2554F), // B — красный
        4 => const Color(0xFFE865E8), // A — пурпурный
        _ => const Color(0xFFFFD54F), // S — золотой
      };

  static String _place(int p) => switch (p) {
        1 => tr('1st'),
        2 => tr('2nd'),
        3 => tr('3rd'),
        _ => tr('{n}th', {'n': p}),
      };

  Widget _cup(RingProgress r, RingCup cup, List<RingCupRecord?>? records) {
    final icon = r.cupIcons[cup.id];
    final played = records != null && records.any((x) => x != null);
    return SizedBox(
      width: 330,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Opacity(
            opacity: played ? 1 : 0.55,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (icon != null)
                      Image.memory(icon, width: 36, height: 36, filterQuality: FilterQuality.none, gaplessPlayback: true)
                    else
                      const Icon(Icons.emoji_events_outlined, size: 32),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text.rich(_cupTitle(cup),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                          if (cup.levels.isNotEmpty)
                            Tooltip(
                              message: [for (final l in cup.levels) srb2PlainTitle(r.defs.mapTitles[l] ?? l)].join('\n'),
                              child: Text(tr('{n} courses', {'n': cup.levels.length}),
                                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                const Divider(height: 16),
                for (var i = 0; i < ringGpDifficulties.length; i++) _cupRow(i, records != null && i < records.length ? records[i] : null),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// «Кубок Ring»: перевод — как есть, название из SOC — с цветами SRB2.
  /// Целиком через разбор SOC нельзя: он оставляет только латиницу, и
  /// кириллица перевода становилась «?????».
  static TextSpan _cupTitle(RingCup cup) {
    const mark = '{name}';
    final template = tr('{name} Cup');
    final at = template.indexOf(mark);
    if (at < 0) return TextSpan(children: [srb2RichText(cup.title)]);
    return TextSpan(children: [
      TextSpan(text: template.substring(0, at)),
      srb2RichText(cup.title),
      TextSpan(text: template.substring(at + mark.length)),
    ]);
  }

  Widget _cupRow(int difficulty, RingCupRecord? rec) {
    final label = switch (difficulty) {
      0 => tr('Relaxed'),
      1 => tr('Intense'),
      2 => tr('Vicious'),
      _ => tr('Master'),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(width: 72, child: Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey))),
          if (rec == null)
            const Text('—', style: TextStyle(color: Colors.grey))
          else ...[
            SizedBox(width: 44, child: Text(_place(rec.placement), style: const TextStyle(fontWeight: FontWeight.bold))),
            Tooltip(
              message: tr('Grade {grade}', {'grade': ringGrade(rec.grade)}),
              child: Container(
                width: 24,
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(vertical: 1),
                decoration: BoxDecoration(
                  color: _gradeColor(rec.grade).withValues(alpha: 0.2),
                  border: Border.all(color: _gradeColor(rec.grade)),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(ringGrade(rec.grade),
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _gradeColor(rec.grade))),
              ),
            ),
            const SizedBox(width: 8),
            if (rec.emerald)
              Tooltip(
                message: tr('Chaos Emerald collected'),
                child: const Icon(Icons.diamond, size: 18, color: Color(0xFF62D85A)),
              )
            else
              const SizedBox(width: 18),
            const Spacer(),
            if (rec.skin.isNotEmpty)
              Tooltip(
                message: tr('Best with {name}', {'name': _chars[rec.skin.toLowerCase()]?.realname ?? rec.skin}),
                child: CharacterIcon(_chars[rec.skin.toLowerCase()], size: 22),
              ),
          ],
        ],
      ),
    );
  }

  // --- Персонажи ---

  List<Widget> _characters(RingProgress r) {
    final played = [
      for (final e in r.data.skins.entries)
        if (e.value.rounds > 0) e,
    ]..sort((a, b) => b.value.rounds - a.value.rounds);
    if (played.isEmpty) return const [];
    return [
      _section(tr('Characters ({n})', {'n': played.length})),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final e in played)
            SizedBox(
              width: 250,
              child: Card(
                child: ListTile(
                  dense: true,
                  leading: CharacterIcon(_chars[e.key], size: 32),
                  title: Text(_chars[e.key]?.realname ?? e.key, style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(
                      '${tr('wins {wins} of {rounds}', {'wins': e.value.wins, 'rounds': e.value.rounds})}\n${_hours(e.value.time)}'),
                  isThreeLine: true,
                ),
              ),
            ),
        ],
      ),
    ];
  }

  // --- Карты ---

  List<Widget> _maps(RingProgress r) {
    final d = r.data;
    final visited = d.maps.values.where((m) => m.visited).length;
    final beaten = d.maps.values.where((m) => m.beaten).length;
    final withRecords = [
      for (final e in d.maps.entries)
        if (e.value.hasRecord || r.defs.medalsOf(e.key).any((m) => d.collected(m.number - 1))) e,
    ]..sort((a, b) => a.key.compareTo(b.key));
    return [
      _section(tr('Courses')),
      Text(tr('Visited: {visited} · beaten: {beaten}', {'visited': visited, 'beaten': beaten}),
          style: const TextStyle(color: Colors.grey)),
      if (withRecords.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(tr('No Time Attack records yet.'), style: const TextStyle(color: Colors.grey)),
        )
      else ...[
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [for (final e in withRecords) _mapCard(r, e.key, e.value)],
        ),
      ],
    ];
  }

  Widget _mapCard(RingProgress r, String map, RingMapRecord rec) {
    final medals = r.defs.medalsOf(map);
    String t(int tics) => tics > 0 ? formatTics(tics) : '—';
    return SizedBox(
      width: 300,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              srb2Title(r.defs.mapTitles[map] ?? map, style: const TextStyle(fontWeight: FontWeight.bold)),
              Text(map, style: const TextStyle(fontSize: 10, color: Colors.grey)),
              const SizedBox(height: 4),
              Text('${tr('Time Attack')}: ${t(rec.bestTime)} · ${tr('lap')} ${t(rec.bestLap)}',
                  style: const TextStyle(fontSize: 12)),
              if (rec.spbTime > 0)
                Text('${tr('SPB Attack')}: ${t(rec.spbTime)} · ${tr('lap')} ${t(rec.spbLap)}',
                    style: const TextStyle(fontSize: 12)),
              if (medals.isNotEmpty)
                Wrap(
                  spacing: 4,
                  children: [
                    for (final m in medals)
                      Tooltip(
                        message: m.type == 'TIME' && m.target > 0
                            ? tr('Time: beat {time}', {'time': formatTics(m.target)})
                            : tr('Medal'),
                        child: Icon(r.data.collected(m.number - 1) ? Icons.military_tech : Icons.military_tech_outlined,
                            size: 18, color: r.data.collected(m.number - 1) ? Colors.amber : Colors.grey),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
