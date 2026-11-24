import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/characters.dart';

/// Спрайт-образец (assets/color_preview.bin), перекрашенный в цвет: индексы
/// палитры 96–111 (ramp «Green», startcolor по умолчанию) заменяются на ramp.
/// Формат файла: ширина, высота (uint16 LE), индексы, маска, PLAYPAL (768 байт).
class ColorPreview extends StatelessWidget {
  final List<int> ramp;
  final double height;
  const ColorPreview(this.ramp, {super.key, this.height = 96});

  static Future<(int, int, Uint8List, Uint8List, Uint8List)>? _template;
  static final Map<String, Uint8List> _cache = {};

  static Future<(int, int, Uint8List, Uint8List, Uint8List)> _load() =>
      _template ??= rootBundle.load('assets/color_preview.bin').then((data) {
        final b = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
        final w = b[0] | (b[1] << 8);
        final h = b[2] | (b[3] << 8);
        final n = w * h;
        return (
          w,
          h,
          Uint8List.sublistView(b, 4, 4 + n),
          Uint8List.sublistView(b, 4 + n, 4 + 2 * n),
          Uint8List.sublistView(b, 4 + 2 * n, 4 + 2 * n + 768),
        );
      });

  /// Палитра SRB2 из образца — запасная, если в файлах игры её нет.
  static Future<Uint8List> builtInPalette() async => (await _load()).$5;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _load(),
      builder: (context, snap) {
        final t = snap.data;
        if (t == null) return SizedBox(width: height * 34 / 64, height: height);
        final png = _cache.putIfAbsent(
            ramp.join(','), () => CharacterScanner.render(t.$1, t.$2, t.$3, t.$4, t.$5, 96, ramp));
        return Image.memory(png, height: height, filterQuality: FilterQuality.none, gaplessPlayback: true);
      },
    );
  }
}
