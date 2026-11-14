import 'package:flutter_test/flutter_test.dart';
import 'package:srb2_autonomi_launcher/services/state_history.dart';

void main() {
  test('undo returns the state before a change, redo the state after, a new change drops redo', () {
    final h = StateHistory<String>(limit: 3);
    var state = 'a';
    void change(String to) {
      h.record(state);
      state = to;
    }

    expect((h.canUndo, h.canRedo), (false, false));
    change('b'); // a → b (b: аддон убран, персонаж сброшен)
    change('c');
    state = h.undo(state)!;
    expect(state, 'b');
    state = h.undo(state)!;
    expect(state, 'a');
    expect(h.undo(state), isNull);
    state = h.redo(state)!;
    expect(state, 'b');
    change('x'); // новое изменение — повторять больше нечего
    expect(h.canRedo, isFalse);
    expect(h.undo(state), 'b');

    // Не больше limit шагов.
    final l = StateHistory<int>(limit: 3);
    for (var i = 0; i < 5; i++) {
      l.record(i);
    }
    final got = <int>[];
    int? cur = 99;
    while ((cur = l.undo(cur!)) != null) {
      got.add(cur!);
    }
    expect(got, [4, 3, 2]);
  });
}
