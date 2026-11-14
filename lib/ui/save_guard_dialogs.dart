import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../i18n.dart';
import '../services/notices.dart';
import '../services/save_guard.dart';
import 'file_actions.dart';
import 'snack.dart';

/// Время в игре (тики, 35 в секунду): «120 h 5 min».
String formatPlayTime(int tics) {
  final minutes = tics ~/ 35 ~/ 60;
  return tr('{h} h {m} min', {'h': minutes ~/ 60, 'm': minutes % 60});
}

String _date(DateTime? t) {
  if (t == null) return '?';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(t.day)}.${two(t.month)}.${t.year} ${two(t.hour)}:${two(t.minute)}';
}

Future<void> _openDamaged(BuildContext context) async {
  final dir = await SaveGuard.damagedFolder();
  await Directory(dir).create(recursive: true);
  if (context.mounted) await openFolder(context, dir);
}

/// Восстановленные и повреждённые без копии файлы — в уведомления.
void noticeSaveEvents(List<SaveEvent> events) {
  for (final e in events) {
    switch (e.type) {
      case SaveEventType.restored:
        final from = e.fromGameBackup
            ? tr('{file} was damaged. It was restored from the copy the game made itself ({date}).',
                {'file': e.file, 'date': _date(e.backupTime)})
            : tr('{file} was damaged. It was restored from the copy of {date}.',
                {'file': e.file, 'date': _date(e.backupTime)});
        final play =
            e.backupPlayTime == null ? '' : ' ${tr('Play time: {time}.', {'time': formatPlayTime(e.backupPlayTime!)})}';
        Notices.instance.add(Notice(
          NoticeKind.success,
          tr('Save restored'),
          '$from$play ${tr('The damaged file is kept in the folder “Damaged”.')}',
          path: e.brokenCopy,
        ));
      case SaveEventType.brokenNoBackup:
        Notices.instance.add(Notice(
          NoticeKind.error,
          tr('Damaged save'),
          tr('{file} is damaged, and there is no whole copy of it. The launcher left it as it is.', {'file': e.file}),
          path: p.join(e.folder, e.file),
        ));
      case SaveEventType.decreased:
        break;
    }
  }
}

/// Перед запуском: время в игре меньше, чем в копии — по окну на файл.
/// true — какой-то файл заменён копией.
Future<bool> askDecreasedSaves(BuildContext context, List<SaveEvent> events) async {
  var replaced = false;
  for (final e in events.where((e) => e.type == SaveEventType.decreased)) {
    if (!context.mounted) break;
    final restore = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.trending_down, color: Colors.orangeAccent, size: 36),
        title: Text(tr('Progress decreased')),
        content: SizedBox(
          width: 520,
          child: Text(tr(
              'The play time in {file} is {now}, but the copy of {date} has {then}. Did you reset the progress '
              'yourself?\n\nIf not, restore the copy; the current file is moved to the folder “Damaged”.',
              {
                'file': e.file,
                'now': formatPlayTime(e.currentPlayTime ?? 0),
                'then': formatPlayTime(e.backupPlayTime ?? 0),
                'date': _date(e.backupTime),
              })),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Ask later'))),
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Yes, it was me'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Restore the copy'))),
        ],
      ),
    );
    if (restore == true) {
      final moved = await SaveGuard.restore(e.gameId, e.folder, e.file);
      replaced = true;
      Notices.instance.add(Notice(
        NoticeKind.success,
        tr('Save restored'),
        tr('{file} restored from the copy.', {'file': e.file}),
        path: moved == null || moved.isEmpty ? null : moved,
      ));
    } else if (restore == false) {
      await SaveGuard.keepCurrent(e);
    }
  }
  return replaced;
}

/// Окно «Копии сохранений» (вкладка Progress): копии файлов игры, вернуть
/// копию, открыть папки. true — какой-то файл заменён копией.
Future<bool> showSaveBackupsDialog(BuildContext context, {required String gameId, required String folder}) async {
  final changed = await showDialog<bool>(
    context: context,
    builder: (context) => _BackupsDialog(gameId: gameId, folder: folder),
  );
  return changed == true;
}

class _BackupsDialog extends StatefulWidget {
  final String gameId, folder;
  const _BackupsDialog({required this.gameId, required this.folder});

  @override
  State<_BackupsDialog> createState() => _BackupsDialogState();
}

class _BackupsDialogState extends State<_BackupsDialog> {
  late Future<List<SaveBackup>> _list = SaveGuard.backups(widget.gameId, widget.folder);
  var _changed = false;

  Future<void> _restore(SaveBackup b) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Restore {file}?', {'file': b.file})),
        content: Text(tr('{file} is replaced with the copy of {date}. The current file is moved to the folder '
            '“Damaged”.', {'file': b.file, 'date': _date(b.time)})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Restore'))),
        ],
      ),
    );
    if (ok != true) return;
    await SaveGuard.restore(widget.gameId, widget.folder, b.file);
    _changed = true;
    if (!mounted) return;
    showSnack(context, SnackBar(content: Text(tr('{file} restored from the copy.', {'file': b.file}))));
    setState(() => _list = SaveGuard.backups(widget.gameId, widget.folder));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('Save backups')),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              tr('Before the game starts, the launcher checks the saves it will use and keeps the last whole copy of '
                  'each. A damaged file is restored from it.'),
              style: const TextStyle(color: Colors.grey, fontSize: 13),
            ),
            const SizedBox(height: 12),
            FutureBuilder<List<SaveBackup>>(
              future: _list,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
                }
                final list = snap.data ?? const <SaveBackup>[];
                if (list.isEmpty) return Text(tr('No copies yet: they appear when you start the game.'));
                return ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 360),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final b in list)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.save_outlined),
                          title: Text(b.file),
                          subtitle: Text([
                            tr('Copy: {date}', {'date': _date(b.time)}),
                            if (b.playTime != null) tr('Play time: {time}', {'time': formatPlayTime(b.playTime!)}),
                          ].join(' · ')),
                          trailing: TextButton.icon(
                            icon: const Icon(Icons.restore, size: 18),
                            label: Text(tr('Restore')),
                            onPressed: () => _restore(b),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          icon: const Icon(Icons.folder_open),
          label: Text(tr('Copies')),
          onPressed: () async {
            final dir = await SaveGuard.backupFolder(widget.gameId, widget.folder);
            await Directory(dir).create(recursive: true);
            if (context.mounted) await openFolder(context, dir);
          },
        ),
        TextButton.icon(
          icon: const Icon(Icons.folder_open),
          label: Text(tr('Damaged')),
          onPressed: () => _openDamaged(context),
        ),
        FilledButton(onPressed: () => Navigator.pop(context, _changed), child: Text(tr('Close'))),
      ],
    );
  }
}

/// Вкладка Progress, когда файл прогресса [path] не читается: что с ним и
/// чем его заменить (копия лаунчера или самой игры).
class DamagedSaveView extends StatefulWidget {
  final String gameId;
  final String path;

  /// Текст ошибки чтения (в подробностях).
  final Object error;

  /// Файл заменён — перечитать.
  final VoidCallback onRestored;

  const DamagedSaveView({
    super.key,
    required this.gameId,
    required this.path,
    required this.error,
    required this.onRestored,
  });

  @override
  State<DamagedSaveView> createState() => _DamagedSaveViewState();
}

class _DamagedSaveViewState extends State<DamagedSaveView> {
  late final Future<SaveSource?> _source =
      SaveGuard.sourceFor(widget.gameId, p.dirname(widget.path), p.basename(widget.path));
  var _busy = false;

  String get _file => p.basename(widget.path);

  Future<void> _repair() async {
    setState(() => _busy = true);
    final e = await SaveGuard.repair(widget.gameId, p.dirname(widget.path), _file);
    if (!mounted) return;
    setState(() => _busy = false);
    if (e != null) noticeSaveEvents([e]);
    widget.onRestored();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: FutureBuilder<SaveSource?>(
            future: _source,
            builder: (context, snap) {
              final source = snap.data;
              final done = snap.connectionState == ConnectionState.done;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.broken_image_outlined, size: 48, color: Colors.redAccent),
                  const SizedBox(height: 12),
                  Text(tr('{file} is damaged', {'file': _file}),
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text(
                    tr('The file is cut short or broken (it happens when the PC turns off while the game is '
                        'saving). The game will not load it either.'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 16),
                  if (!done)
                    const CircularProgressIndicator()
                  else if (source != null) ...[
                    Text(
                      [
                        source.fromGame
                            ? tr('There is a whole copy the game made itself ({date}).', {'date': _date(source.time)})
                            : tr('There is a whole copy of {date}.', {'date': _date(source.time)}),
                        if (source.check.playTime != null)
                          tr('Play time: {time}.', {'time': formatPlayTime(source.check.playTime!)}),
                      ].join(' '),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      icon: _busy
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.restore),
                      label: Text(tr('Restore from the copy')),
                      onPressed: _busy ? null : _repair,
                    ),
                    const SizedBox(height: 6),
                    Text(tr('The damaged file is kept in the folder “Damaged”.'),
                        style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  ] else
                    Text(
                      SaveGuard.enabled
                          ? tr('There is no whole copy of it.')
                          : tr('There is no whole copy of it. Turn on save protection (Settings → Experimental) so '
                              'that the launcher keeps one.'),
                      textAlign: TextAlign.center,
                    ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton.icon(
                        icon: const Icon(Icons.folder_open),
                        label: Text(tr('Show in folder')),
                        onPressed: () => showFileInFolder(context, widget.path),
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.refresh),
                        label: Text(tr('Reload')),
                        onPressed: widget.onRestored,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SelectableText('${widget.error}', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
