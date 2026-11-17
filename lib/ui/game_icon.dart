import 'dart:io';

import 'package:flutter/material.dart';

import '../models/game.dart';

/// Иконка игры: своя (файл PNG у своей игры) или встроенная (иконка основы).
class GameIcon extends StatelessWidget {
  final GameDef game;
  final double size;
  const GameIcon(this.game, {super.key, this.size = 24});

  @override
  Widget build(BuildContext context) {
    Widget asset() => Image.asset(game.iconAsset,
        width: size, height: size, filterQuality: FilterQuality.medium, errorBuilder: (_, _, _) => SizedBox(width: size));
    final file = game.iconFile;
    if (file == null) return asset();
    return Image.file(File(file),
        width: size,
        height: size,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, _, _) => asset());
  }
}
