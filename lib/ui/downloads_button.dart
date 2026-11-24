import 'package:flutter/material.dart';

import '../i18n.dart';
import '../services/downloads.dart';
import 'notifications_button.dart' show eventFrame;

/// Кнопка «Скачивания» в заголовке окна: число идущих скачиваний, кольцо
/// общего прогресса; щелчок открывает список (ход, отмена, ошибки).
class DownloadsButton extends StatelessWidget {
  const DownloadsButton({super.key});

  @override
  Widget build(BuildContext context) {
    final center = DownloadCenter.instance;
    return ListenableBuilder(
      listenable: center,
      builder: (context, _) {
        final active = center.activeCount;
        final failed = center.failedCount;
        final scheme = Theme.of(context).colorScheme;
        return IconButton(
          tooltip: active > 0
              ? tr('Downloads: {n} in progress', {'n': active})
              : failed > 0
                  ? tr('Downloads: {n} failed', {'n': failed})
                  : tr('Downloads'),
          onPressed: () => showDialog<void>(context: context, builder: (_) => const _DownloadsDialog()),
          icon: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              if (active > 0)
                SizedBox(
                  width: 30,
                  height: 30,
                  child: CircularProgressIndicator(value: center.activeProgress, strokeWidth: 2),
                ),
              Icon(active > 0 ? Icons.downloading : Icons.download_outlined, color: active > 0 ? scheme.primary : null),
              if (active > 0 || failed > 0)
                Positioned(
                  right: -6,
                  top: -6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: active > 0 ? scheme.primary : Colors.redAccent,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${active > 0 ? active : failed}',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: active > 0 ? scheme.onPrimary : Colors.white,
                      ),
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

class _DownloadsDialog extends StatelessWidget {
  const _DownloadsDialog();

  @override
  Widget build(BuildContext context) {
    final center = DownloadCenter.instance;
    return ListenableBuilder(
      listenable: center,
      builder: (context, _) {
        final items = center.items;
        return AlertDialog(
          title: Text(tr('Downloads')),
          content: SizedBox(
            width: 560,
            height: 420,
            child: items.isEmpty
                ? Center(
                    child: Text(
                      tr('Nothing is being downloaded. Downloads from servers and repositories appear here '
                          'and continue when you switch tabs.'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.separated(
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) => eventFrame(context, _row(context, items[i])),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: items.any((i) => !i.active) ? center.clearFinished : null,
              child: Text(tr('Clear finished')),
            ),
            TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Close'))),
          ],
        );
      },
    );
  }

  Widget _row(BuildContext context, DownloadItem item) {
    final (icon, color, status) = switch (item.state) {
      DownloadState.queued => (Icons.schedule, Colors.grey, tr('In queue')),
      DownloadState.running => (
          Icons.downloading,
          Theme.of(context).colorScheme.primary,
          [
            if (item.stage == 'verifying')
              tr('Verifying MD5...')
            else ...[
              item.source.isEmpty ? tr('Downloading...') : tr('Downloading from {source}...', {'source': item.source}),
              if (item.chunksTotal > 0)
                '${item.chunksDone}/${item.chunksTotal} chunks'
              else if (item.progress != null && item.progress! > 0)
                '${(item.progress! * 100).toStringAsFixed(0)}%',
            ],
          ].join(' '),
        ),
      DownloadState.done => (Icons.check_circle_outline, Colors.green, tr('Downloaded')),
      DownloadState.failed => (Icons.error_outline, Colors.redAccent, item.error ?? tr('Failed')),
      DownloadState.cancelled => (Icons.cancel_outlined, Colors.grey, tr('Cancelled')),
    };
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: color),
      title: Text(item.name, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(item.group, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          Text(status, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: color)),
          if (item.state == DownloadState.running)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: LinearProgressIndicator(
                value: item.stage == 'verifying' ? null : item.progress,
                minHeight: 3,
              ),
            ),
        ],
      ),
      trailing: item.active && item.cancel != null
          ? IconButton(icon: const Icon(Icons.close, size: 18), tooltip: tr('Cancel'), onPressed: item.cancel)
          : null,
    );
  }
}
