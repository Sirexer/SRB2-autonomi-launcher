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
}
