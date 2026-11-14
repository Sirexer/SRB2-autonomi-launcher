import 'dart:async';

import 'package:flutter/material.dart';

int _snackToken = 0;

/// Показывает уведомление: предыдущее сразу убирается (не копятся в очереди),
/// новое исчезает через 3 секунды — даже с кнопкой действия (такие
/// SnackBar сами не закрываются).
void showSnack(BuildContext context, SnackBar snack) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.removeCurrentSnackBar();
  final token = ++_snackToken;
  messenger.showSnackBar(snack);
  Timer(const Duration(seconds: 3), () {
    if (token == _snackToken) messenger.hideCurrentSnackBar();
  });
}
