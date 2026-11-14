import 'package:flutter/foundation.dart';

/// Запуск игры готовится (проверка сохранений, поиск файлов): кнопки
/// запуска выключены и пишут «Checking…», второй щелчок ничего не делает.
final launchPreparing = ValueNotifier<bool>(false);
