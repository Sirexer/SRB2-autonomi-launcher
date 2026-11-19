import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:srb2_autonomi_launcher/ui/music_visualizer.dart';

/// Полосы с двумя цветами — градиент цветами вершин (без шейдера).
void main() {
  Future<ByteData> render(VisualizerBars bars, Size size) async {
    final recorder = ui.PictureRecorder();
    bars.paint(Canvas(recorder), size);
    final image = await recorder.endRecording().toImage(size.width.toInt(), size.height.toInt());
    return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  }

  Color pixel(ByteData d, int w, int x, int y) {
    final o = (y * w + x) * 4;
    return Color.fromARGB(d.getUint8(o + 3), d.getUint8(o), d.getUint8(o + 1), d.getUint8(o + 2));
  }

  testWidgets('two colors: bottom of a full bar is the base color, its top is the top color', (tester) async {
    await tester.runAsync(() async {
      const size = Size(100, 100);
      final d = await render(
        VisualizerBars([1.0], const Color(0xFFFF0000), const Color(0xFF0000FF), const Color(0x590000FF)),
        size,
      );
      // Одна полоса во всю высоту верхней части (60 px): x ≈ 50.
      final topPx = pixel(d, 100, 50, 1);
      final bottomPx = pixel(d, 100, 50, 57);
      expect(topPx.r, greaterThan(0.85));
      expect(topPx.b, lessThan(0.15));
      expect(bottomPx.b, greaterThan(0.85));
      expect(bottomPx.r, lessThan(0.15));
    });
  });
}
