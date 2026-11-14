import 'dart:async';
import 'dart:isolate';

/// Рендер прерван: пользователь выбрал другой трек.
class RenderCancelled implements Exception {
  const RenderCancelled();
  @override
  String toString() => 'Render cancelled';
}

/// Задача в изоляте: входные данные, прогресс и результат.
class IsolateJob {
  final SendPort _port;
  final Object? input;
  int _percent = -1;
  IsolateJob._(this._port, this.input);

  /// Доля готового (0..1); отправляется не чаще раза на процент.
  void progress(double p) {
    final percent = (p * 100).floor();
    if (percent == _percent) return;
    _percent = percent;
    _port.send(p);
  }

  void done(Object? result) => _port.send(_Result(result));
}

class _Result {
  final Object? value;
  const _Result(this.value);
}

void _entry((void Function(IsolateJob), Object?, SendPort) m) => m.$1(IsolateJob._(m.$3, m.$2));

/// Запускает [entry] в отдельном изоляте с [input]. Возвращает то, что
/// передано в [IsolateJob.done]. Если [cancelled] вернёт true (проверяется
/// при каждом сообщении изолята), изолят убивается и бросается
/// [RenderCancelled]. Ошибка в изоляте — FormatException с её текстом.
Future<Object?> runKillable(
  void Function(IsolateJob job) entry,
  Object? input, {
  void Function(double progress)? onProgress,
  bool Function()? cancelled,
}) async {
  final port = ReceivePort();
  final result = Completer<Object?>();
  port.listen((msg) {
    if (result.isCompleted) return;
    if (cancelled?.call() ?? false) {
      result.completeError(const RenderCancelled());
    } else if (msg is double) {
      onProgress?.call(msg);
    } else if (msg is _Result) {
      result.complete(msg.value);
    } else if (msg is List) {
      // Необработанная ошибка в изоляте: [текст, стек].
      result.completeError(FormatException(msg.isEmpty ? 'Render failed' : '${msg.first}'));
    } else if (msg == null) {
      result.completeError(StateError('Render stopped'));
    }
  });
  Isolate? isolate;
  try {
    isolate = await Isolate.spawn(_entry, (entry, input, port.sendPort), onError: port.sendPort, onExit: port.sendPort);
    return await result.future;
  } finally {
    isolate?.kill(priority: Isolate.immediate);
    port.close();
  }
}
