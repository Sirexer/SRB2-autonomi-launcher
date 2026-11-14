import 'package:flutter/material.dart';

/// ScrollController, который помнит позицию, пока список скрыт (другая
/// вкладка), и восстанавливает её, когда список снова появляется.
///
/// Не использует PageStorage: с PageStorageKey на списке раскрывающиеся
/// группы (ExpansionTile) внутри читали сохранённую позицию прокрутки как
/// своё состояние «развёрнута» — и список ломался (серое поле).
class KeptScrollController extends ScrollController {
  double _saved = 0;

  KeptScrollController() : super(keepScrollOffset: false) {
    addListener(() {
      if (positions.length == 1) _saved = offset;
    });
  }

  @override
  double get initialScrollOffset => _saved;
}

/// Прокручиваемый список, который строит всё содержимое сразу (в отличие
/// от ListView): высота известна заранее, полоса прокрутки не дёргается, а
/// блоки с загрузкой (уровни, персонажи) не пересоздаются при прокрутке.
class StaticScrollList extends StatelessWidget {
  final ScrollController? controller;
  final List<Widget> children;
  const StaticScrollList({super.key, this.controller, required this.children});

  // SizedBox.expand: занять всё место (как ListView). Иначе в Row короткое
  // содержимое центрируется по вертикали.
  @override
  Widget build(BuildContext context) => SizedBox.expand(
        child: SingleChildScrollView(
          controller: controller,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
        ),
      );
}
