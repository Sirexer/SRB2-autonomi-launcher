/// История отмены и повтора: [record] — состояние до изменения; [undo] /
/// [redo] получают текущее состояние и возвращают то, к которому перейти
/// (null — некуда).
class StateHistory<T> {
  StateHistory({this.limit = 100});

  /// Сколько шагов отмены хранится.
  final int limit;

  final List<T> _undo = [];
  final List<T> _redo = [];

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// Новое изменение: [before] — состояние до него. Повторять больше нечего.
  void record(T before) {
    _undo.add(before);
    if (_undo.length > limit) _undo.removeAt(0);
    _redo.clear();
  }

  T? undo(T current) {
    if (_undo.isEmpty) return null;
    _redo.add(current);
    return _undo.removeLast();
  }

  T? redo(T current) {
    if (_redo.isEmpty) return null;
    _undo.add(current);
    return _redo.removeLast();
  }

  void clear() {
    _undo.clear();
    _redo.clear();
  }
}
