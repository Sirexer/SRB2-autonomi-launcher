import 'dart:async';

import 'package:flutter/foundation.dart';

/// Видно ли окно лаунчера. Пока оно свёрнуто, фоновая работа (разбор
/// аддонов, чтение длительности треков, MD5) ждёт: окно откроют — доделаем.
class AppActivity {
  AppActivity._();

  static final ValueNotifier<bool> visible = ValueNotifier(true);

  /// Окно активно (в фокусе). Анимации обложек идут только в активном окне.
  static final ValueNotifier<bool> focused = ValueNotifier(true);

  /// Сразу, если окно видно; иначе — когда его откроют.
  static Future<void> whenVisible() {
    if (visible.value) return Future.value();
    final done = Completer<void>();
    void listener() {
      if (!visible.value || done.isCompleted) return;
      visible.removeListener(listener);
      done.complete();
    }

    visible.addListener(listener);
    return done.future;
  }
}
