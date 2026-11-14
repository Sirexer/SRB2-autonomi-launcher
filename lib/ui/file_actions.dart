import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../i18n.dart';
import 'snack.dart';

/// Действия со скачанным файлом (меню «⋮»).
enum FileAction { showInFolder, delete }

/// Меню «⋮»: показать в папке, удалить.
Widget fileActionsMenu({required ValueChanged<FileAction> onSelected, bool enabled = true}) =>
    PopupMenuButton<FileAction>(
      tooltip: tr('File actions'),
      icon: const Icon(Icons.more_vert),
      enabled: enabled,
      onSelected: onSelected,
      itemBuilder: (context) => [
        PopupMenuItem(
          value: FileAction.showInFolder,
          child: ListTile(dense: true, leading: const Icon(Icons.folder_open_outlined), title: Text(tr('Show in folder'))),
        ),
        PopupMenuItem(
          value: FileAction.delete,
          child: ListTile(
            dense: true,
            leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
            title: Text(tr('Delete file')),
          ),
        ),
      ],
    );

/// Окружение для внешних программ без переменных AppImage (иначе xdg-open
/// подхватит библиотеки лаунчера); null — менять не нужно.
Map<String, String>? cleanChildEnvironment() {
  final env = Map<String, String>.from(Platform.environment);
  if (!env.containsKey('LAUNCHER_ORIG_LD_LIBRARY_PATH')) return null;
  final orig = env.remove('LAUNCHER_ORIG_LD_LIBRARY_PATH') ?? '';
  if (orig.isEmpty) {
    env.remove('LD_LIBRARY_PATH');
  } else {
    env['LD_LIBRARY_PATH'] = orig;
  }
  for (final k in ['APPDIR', 'APPIMAGE', 'ARGV0', 'OWD']) {
    env.remove(k);
  }
  return env;
}

/// Открывает папку файла (на Windows — с выделенным файлом).
Future<void> showFileInFolder(BuildContext context, String path) async {
  try {
    if (Platform.isWindows) {
      await Process.start('explorer.exe', ['/select,', path], mode: ProcessStartMode.detached);
    } else {
      final env = cleanChildEnvironment();
      await Process.start('xdg-open', [p.dirname(path)],
          mode: ProcessStartMode.detached, environment: env, includeParentEnvironment: env == null);
    }
  } catch (e) {
    if (!context.mounted) return;
    showSnack(context, SnackBar(content: Text(tr('Could not open the folder: {error}', {'error': e}))));
  }
}

/// Открывает папку [dir] в файловом менеджере.
Future<void> openFolder(BuildContext context, String dir) async {
  try {
    if (Platform.isWindows) {
      await Process.start('explorer.exe', [dir], mode: ProcessStartMode.detached);
    } else {
      final env = cleanChildEnvironment();
      await Process.start('xdg-open', [dir],
          mode: ProcessStartMode.detached, environment: env, includeParentEnvironment: env == null);
    }
  } catch (e) {
    if (!context.mounted) return;
    showSnack(context, SnackBar(content: Text(tr('Could not open the folder: {error}', {'error': e}))));
  }
}

/// Подтверждение удаления со списком файлов.
Future<bool> confirmDeleteFiles(BuildContext context, List<String> paths, String title) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 36),
      title: Text(title),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('These files will be deleted from disk:')),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: SingleChildScrollView(child: SelectableText(paths.join('\n'), style: const TextStyle(fontSize: 12))),
            ),
          ],
        ),
      ),
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
  return ok == true;
}
