import 'package:flutter/foundation.dart';

/// queued — ждёт в очереди (аддоны репозиториев качаются по одному).
enum DownloadState { queued, running, done, failed, cancelled }

/// Одно скачивание в общем списке (кнопка «Скачивания» в заголовке окна).
class DownloadItem {
  /// Имя файла.
  final String name;

  /// Откуда и для чего: «Сервер: …», название аддона или репозитория.
  final String group;

  /// Источник сейчас («the server», «your repository»…); '' — не важно.
  String source = '';

  /// Доля готового 0..1; null — неизвестно.
  double? progress;
  DownloadState state = DownloadState.running;
  String? error;

  /// Сколько чанков загружено и сколько всего (для Autonomi).
  int chunksDone = 0;
  int chunksTotal = 0;

  /// Текущий этап ('downloading', 'verifying' и т.п.)
  String stage = '';

  /// Отмена (null — отменить нельзя: начатые загрузки Autonomi не прерываются,
  /// но ждущие в очереди убираются).
  VoidCallback? cancel;

  final DateTime started = DateTime.now();

  DownloadItem(this.name, this.group, {this.cancel});

  /// Ещё не закончено: качается или ждёт в очереди.
  bool get active => state == DownloadState.running || state == DownloadState.queued;
}

/// Все скачивания лаунчера: аддоны с серверов и из репозиториев. Живёт всё
/// время работы лаунчера, поэтому смена вкладки ничего не прерывает и не
/// прячет.
class DownloadCenter extends ChangeNotifier {
  DownloadCenter._();
  static final DownloadCenter instance = DownloadCenter._();

  /// Новые — в начале.
  final List<DownloadItem> items = [];

  int get activeCount => items.where((i) => i.active).length;
  int get failedCount => items.where((i) => i.state == DownloadState.failed).length;

  /// Общий прогресс идущих скачиваний (null — нечего показывать).
  double? get activeProgress {
    final active = [for (final i in items) if (i.state == DownloadState.running) i];
    if (active.isEmpty) return null;
    return active.fold<double>(0, (sum, i) => sum + (i.progress ?? 0)) / active.length;
  }

  /// Новое скачивание; [queued] — пока ждёт очереди ([begin] его запустит).
  DownloadItem start(String name, String group, {VoidCallback? cancel, bool queued = false}) {
    final item = DownloadItem(name, group, cancel: cancel);
    if (queued) item.state = DownloadState.queued;
    items.insert(0, item);
    // Старые завершённые не копим.
    while (items.length > 60) {
      final last = items.lastIndexWhere((i) => !i.active);
      if (last < 0) break;
      items.removeAt(last);
    }
    notifyListeners();
    return item;
  }

  /// Ждавшее в очереди начало качаться; [cancel] — отмена уже идущего (null — нельзя).
  void begin(DownloadItem item, {VoidCallback? cancel}) {
    item.state = DownloadState.running;
    item.cancel = cancel;
    notifyListeners();
  }

  void update(
    DownloadItem item, {
    double? progress,
    String? source,
    int? chunksDone,
    int? chunksTotal,
    String? stage,
  }) {
    if (source != null) item.source = source;
    if (chunksDone != null) item.chunksDone = chunksDone;
    if (chunksTotal != null) item.chunksTotal = chunksTotal;
    if (stage != null) item.stage = stage;
    if (progress == 1.0) {
      item.progress = 1.0;
      if (item.chunksTotal > 0) item.chunksDone = item.chunksTotal;
    } else if (item.chunksTotal > 0) {
      item.progress = (item.chunksDone / item.chunksTotal).clamp(0.0, 0.99).toDouble();
    } else if (progress != null) {
      item.progress = progress;
    }
    notifyListeners();
  }

  void finish(DownloadItem item, DownloadState state, {String? error}) {
    item.state = state;
    item.error = error;
    if (state == DownloadState.done) {
      item.progress = 1;
      if (item.chunksTotal > 0) item.chunksDone = item.chunksTotal;
    }
    notifyListeners();
  }

  /// Убирает из списка всё, что уже не качается.
  void clearFinished() {
    items.removeWhere((i) => !i.active);
    notifyListeners();
  }
}
