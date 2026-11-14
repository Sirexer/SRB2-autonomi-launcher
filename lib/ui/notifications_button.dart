import 'package:flutter/material.dart';

import '../i18n.dart';
import '../services/notices.dart';
import 'file_actions.dart';

/// Кнопка уведомлений в шапке (слева от загрузок): число непрочитанных и
/// окно со списком.
class NotificationsButton extends StatelessWidget {
  const NotificationsButton({super.key});

  @override
  Widget build(BuildContext context) {
    final notices = Notices.instance;
    return ListenableBuilder(
      listenable: notices,
      builder: (context, _) {
        final unread = notices.unread;
        final scheme = Theme.of(context).colorScheme;
        return IconButton(
          tooltip: unread > 0 ? tr('Notifications: {n} new', {'n': unread}) : tr('Notifications'),
          onPressed: () async {
            await showDialog<void>(context: context, builder: (_) => const _NotificationsDialog());
            notices.markRead();
          },
          icon: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              Icon(unread > 0 ? Icons.notifications_active : Icons.notifications_none,
                  color: unread > 0 ? scheme.primary : null),
              if (unread > 0)
                Positioned(
                  right: -6,
                  top: -6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(8)),
                    child: Text(
                      '$unread',
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: scheme.onPrimary),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Событие в списке (загрузки, уведомления) — в рамке; [highlight] — новое.
Widget eventFrame(BuildContext context, Widget child, {bool highlight = false}) {
  final scheme = Theme.of(context).colorScheme;
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
    decoration: BoxDecoration(
      color: highlight ? scheme.primary.withValues(alpha: 0.06) : null,
      border: Border.all(color: highlight ? scheme.primary.withValues(alpha: 0.6) : scheme.outlineVariant),
      borderRadius: BorderRadius.circular(10),
    ),
    child: child,
  );
}

class _NotificationsDialog extends StatelessWidget {
  const _NotificationsDialog();

  @override
  Widget build(BuildContext context) {
    final notices = Notices.instance;
    return ListenableBuilder(
      listenable: notices,
      builder: (context, _) {
        final items = notices.items;
        final unread = notices.unread;
        return AlertDialog(
          title: Text(tr('Notifications')),
          content: SizedBox(
            width: 560,
            height: 420,
            child: items.isEmpty
                ? Center(
                    child: Text(tr('No notifications.'), style: const TextStyle(color: Colors.grey)),
                  )
                : ListView.separated(
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) =>
                        eventFrame(context, _row(context, items[i], isNew: i < unread), highlight: i < unread),
                  ),
          ),
          actions: [
            TextButton(onPressed: items.isEmpty ? null : notices.clear, child: Text(tr('Clear all'))),
            TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Close'))),
          ],
        );
      },
    );
  }

  Widget _row(BuildContext context, Notice n, {required bool isNew}) {
    final (icon, color) = switch (n.kind) {
      NoticeKind.info => (Icons.info_outline, Colors.lightBlueAccent),
      NoticeKind.success => (Icons.check_circle_outline, Colors.lightGreen),
      NoticeKind.warning => (Icons.warning_amber_rounded, Colors.orangeAccent),
      NoticeKind.error => (Icons.error_outline, Colors.redAccent),
    };
    String two(int v) => v.toString().padLeft(2, '0');
    final t = n.time;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: color),
      title: Row(
        children: [
          Expanded(
            child: Text(n.title, style: TextStyle(fontWeight: isNew ? FontWeight.bold : FontWeight.normal)),
          ),
          Text('${two(t.day)}.${two(t.month)} ${two(t.hour)}:${two(t.minute)}',
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(n.message, style: const TextStyle(fontSize: 12)),
          if (n.path != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                icon: const Icon(Icons.folder_open, size: 16),
                label: Text(tr('Show in folder')),
                onPressed: () => showFileInFolder(context, n.path!),
              ),
            ),
        ],
      ),
      trailing: IconButton(
        icon: const Icon(Icons.close, size: 18),
        tooltip: tr('Remove'),
        onPressed: () => Notices.instance.remove(n),
      ),
    );
  }
}
