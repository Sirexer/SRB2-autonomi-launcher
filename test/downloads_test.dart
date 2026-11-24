import 'package:flutter_test/flutter_test.dart';
import 'package:srb2_autonomi_launcher/services/downloads.dart';

void main() {
  test('queued downloads are active but do not count in the progress ring', () {
    final center = DownloadCenter.instance;
    center.items.clear();
    final running = center.start('a.pk3', 'Repo — A');
    center.update(running, progress: 0.5);
    final queued = center.start('b.pk3', 'Repo — B', queued: true);

    expect(queued.state, DownloadState.queued);
    expect(queued.active, isTrue);
    expect(center.activeCount, 2);
    expect(center.activeProgress, 0.5);

    center.finish(running, DownloadState.failed);
    expect(center.activeProgress, isNull);
    center.begin(queued);
    expect(queued.state, DownloadState.running);
    expect(center.activeProgress, 0.0);

    center.finish(queued, DownloadState.done);
    expect(center.activeCount, 0);
    center.items.clear();
  });

  test('chunk progress calculates progress and updates item chunks', () {
    final center = DownloadCenter.instance;
    center.items.clear();
    final item = center.start('mod.pk3', 'Repo — Mod');
    center.update(item, progress: 0.0);
    expect(item.progress, 0.0);

    center.update(item, chunksDone: 3, chunksTotal: 10);
    expect(item.chunksDone, 3);
    expect(item.chunksTotal, 10);
    expect(item.progress, closeTo(0.3, 0.001));
    expect(center.activeProgress, closeTo(0.3, 0.001));

    // Subsequent byte progress call does not overwrite chunk progress
    center.update(item, progress: 0.0);
    expect(item.progress, closeTo(0.3, 0.001));

    // Stage update
    center.update(item, stage: 'verifying');
    expect(item.stage, 'verifying');

    // Finish sets progress to 1 and chunksDone to chunksTotal
    center.finish(item, DownloadState.done);
    expect(item.progress, 1.0);
    expect(item.chunksDone, 10);
    expect(item.state, DownloadState.done);
    center.items.clear();
  });
}
