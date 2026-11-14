import 'package:flutter/foundation.dart';

/// Вид уведомления (значок и цвет).
enum NoticeKind { info, success, warning, error }

/// Уведомление в шапке (кнопка с колокольчиком).
class Notice {
  final DateTime time;
  final NoticeKind kind;
  final String title;
  final String message;

  /// Файл, который можно показать в папке (например, повреждённое сохранение).
  final String? path;

  Notice(this.kind, this.title, this.message, {this.path}) : time = DateTime.now();
}

/// Уведомления лаунчера: новые сверху; непрочитанные — число на кнопке.
/// Живут до закрытия лаунчера.
class Notices extends ChangeNotifier {
  Notices._();
  static final instance = Notices._();

  static const _max = 100;

  final List<Notice> _items = [];
  int _unread = 0;

  List<Notice> get items => List.unmodifiable(_items);
  int get unread => _unread;

  void add(Notice n) {
    _items.insert(0, n);
    if (_items.length > _max) _items.removeRange(_max, _items.length);
    _unread = (_unread + 1).clamp(0, _items.length);
    notifyListeners();
  }

  void markRead() {
    if (_unread == 0) return;
    _unread = 0;
    notifyListeners();
  }

  void remove(Notice n) {
    _items.remove(n);
    _unread = _unread.clamp(0, _items.length);
    notifyListeners();
  }

  void clear() {
    _items.clear();
    _unread = 0;
    notifyListeners();
  }
}
