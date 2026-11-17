import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../i18n.dart';
import '../models/game.dart';
import '../services/app_log.dart';
import '../services/custom_games.dart';
import 'game_icon.dart';
import 'snack.dart';

/// Подпись игры: полное имя и основа (у своей игры).
String gameSubtitle(GameDef g) => [
      if (g.name != g.fullName) g.name,
      if (g.isCustom) tr('based on {game}', {'game': Games.byId(g.engine).name}),
    ].join(' · ');

/// Settings → Games: какие игры в переключателе, свои игры из JSON.
class GamesSettings extends StatefulWidget {
  /// Набор игр изменился (главному окну — обновить переключатель).
  final VoidCallback onChanged;
  const GamesSettings({super.key, required this.onChanged});

  @override
  State<GamesSettings> createState() => _GamesSettingsState();
}

class _GamesSettingsState extends State<GamesSettings> {
  Future<void> _toggle(GameDef g, bool on) async {
    final prefs = await SharedPreferences.getInstance();
    await CustomGames.setEnabled(prefs, g.id, on);
    if (!mounted) return;
    setState(() {});
    widget.onChanged();
  }

  Future<void> _remove(GameDef g) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Remove {game}?', {'game': g.fullName})),
        content: SizedBox(
          width: 440,
          child: Text(tr('The game disappears from the launcher; its files on disk stay. To get it back, add its JSON '
              'again (Add games from JSON).')),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Remove'))),
        ],
      ),
    );
    if (ok != true) return;
    final prefs = await SharedPreferences.getInstance();
    await CustomGames.remove(prefs, g.id);
    if (!mounted) return;
    setState(() {});
    widget.onChanged();
  }

  Future<void> _export(GameDef g) async {
    AppLog.action('open the getSaveLocation dialog (games_settings.dart)');
    final where = await getSaveLocation(
      suggestedName: '${g.id}.json',
      acceptedTypeGroups: [XTypeGroup(label: 'JSON', extensions: const ['json'])],
    );
    if (where == null) return;
    try {
      await File(where.path).writeAsString(await CustomGames.export(g));
      if (mounted) showSnack(context, SnackBar(content: Text(tr('Saved to {path}', {'path': where.path}))));
    } catch (e) {
      if (mounted) showSnack(context, SnackBar(content: Text('$e'), backgroundColor: Colors.red));
    }
  }

  Future<void> _import() async {
    AppLog.action('open the openFile dialog (games_settings.dart)');
    final file = await openFile(acceptedTypeGroups: [XTypeGroup(label: 'JSON', extensions: const ['json'])]);
    if (file == null || !mounted) return;
    final added = await addGamesFromFile(context, file.path);
    if (!mounted || added == 0) return;
    setState(() {});
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tr('Games in the game switcher. Sonic Robo Blast 2 is always there. Custom games (forks such as BlanKart) '
              'are described in JSON; a removed one comes back only from its JSON.'),
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const SizedBox(height: 8),
        for (final g in Games.all)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Opacity(opacity: Games.isEnabled(g) ? 1 : 0.4, child: GameIcon(g, size: 32)),
            title: Text(g.fullName),
            subtitle: Text(gameSubtitle(g)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (g.isCustom) ...[
                  IconButton(
                    icon: const Icon(Icons.file_upload_outlined),
                    tooltip: tr('Export JSON'),
                    onPressed: () => _export(g),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: tr('Remove from the launcher'),
                    onPressed: () => _remove(g),
                  ),
                ],
                Tooltip(
                  message: g == Games.srb2 ? tr('Sonic Robo Blast 2 is always on') : '',
                  child: Switch(
                    value: Games.isEnabled(g),
                    onChanged: g == Games.srb2 ? null : (v) => _toggle(g, v),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.add),
          label: Text(tr('Add games from JSON...')),
          onPressed: _import,
        ),
      ],
    );
  }
}

/// Добавить игры из файла [path]: одна или несколько — пользователь
/// выбирает, какие. Сколько добавлено.
Future<int> addGamesFromFile(BuildContext context, String path) async {
  final List<(Map<String, dynamic>, GameDef?, String?)> found;
  try {
    found = await CustomGames.readFile(path);
  } catch (e) {
    if (context.mounted) {
      showSnack(context, SnackBar(content: Text(tr('Not a games file: {error}', {'error': e})), backgroundColor: Colors.red));
    }
    return 0;
  }
  if (!context.mounted) return 0;
  final chosen = await showDialog<List<Map<String, dynamic>>>(
    context: context,
    builder: (_) => _ChooseGamesDialog(found: found),
  );
  if (chosen == null || chosen.isEmpty) return 0;
  final prefs = await SharedPreferences.getInstance();
  var added = 0;
  for (final d in chosen) {
    try {
      await CustomGames.add(prefs, d, baseDir: p.dirname(path));
      added++;
    } catch (e) {
      AppLog.console('[games] could not add ${d['id']}: $e');
    }
  }
  return added;
}

/// Какие игры из файла добавить (все отмечены; с ошибкой — нельзя).
class _ChooseGamesDialog extends StatefulWidget {
  final List<(Map<String, dynamic>, GameDef?, String?)> found;
  const _ChooseGamesDialog({required this.found});

  @override
  State<_ChooseGamesDialog> createState() => _ChooseGamesDialogState();
}

class _ChooseGamesDialogState extends State<_ChooseGamesDialog> {
  late final Set<int> _on = {
    for (var i = 0; i < widget.found.length; i++)
      if (widget.found[i].$2 != null) i,
  };

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('Add games')),
      content: SizedBox(
        width: 520,
        child: ListView(
          shrinkWrap: true,
          children: [
            for (var i = 0; i < widget.found.length; i++) _row(i),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
        FilledButton(
          onPressed: _on.isEmpty ? null : () => Navigator.pop(context, [for (final i in _on) widget.found[i].$1]),
          child: Text(tr('Add')),
        ),
      ],
    );
  }

  Widget _row(int i) {
    final (def, game, error) = widget.found[i];
    final exists = game != null && Games.custom.any((g) => g.id == game.id);
    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      value: _on.contains(i),
      onChanged: game == null ? null : (v) => setState(() => v == true ? _on.add(i) : _on.remove(i)),
      secondary: game == null ? const Icon(Icons.error_outline, color: Colors.redAccent) : GameIcon(game, size: 32),
      title: Text(game?.fullName ?? '${def['name'] ?? def['id'] ?? '?'}'),
      subtitle: Text(
        error ?? [gameSubtitle(game!), if (exists) tr('already added: will be replaced')].join(' · '),
        style: TextStyle(color: error != null ? Colors.redAccent : null),
      ),
    );
  }
}
