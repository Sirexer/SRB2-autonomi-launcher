import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../services/app_activity.dart';
import '../theme/app_themes.dart';
import '../services/music_player.dart';

/// Полосы спектра над названием трека: сверху — полосы, снизу — их
/// отражение потемнее. Обновляется не чаще 30 раз в секунду и только пока
/// музыка играет, а окно активно; иначе полосы плавно опускаются и всё
/// стоит (без перерисовок и без расчёта FFT в движке).
class MusicVisualizer extends StatefulWidget {
  final MusicPlayer player;
  const MusicVisualizer({super.key, required this.player});

  @override
  State<MusicVisualizer> createState() => _MusicVisualizerState();
}

class _MusicVisualizerState extends State<MusicVisualizer> with SingleTickerProviderStateMixin {
  static const _bars = 48;
  static const _frame = Duration(milliseconds: 33);

  late final Ticker _ticker = createTicker(_tick);
  final _levels = ValueNotifier<List<double>>(List.filled(_bars, 0.0));
  Duration _last = Duration.zero;

  @override
  void initState() {
    super.initState();
    widget.player.addListener(_update);
    AppActivity.visible.addListener(_update);
    _update();
  }

  @override
  void dispose() {
    widget.player.removeListener(_update);
    AppActivity.visible.removeListener(_update);
    _ticker.dispose();
    widget.player.stopSpectrum();
    _levels.dispose();
    super.dispose();
  }

  /// Идёт, пока окно видно — и в фоне, без фокуса (на втором мониторе,
  /// рядом с игрой); свёрнутое окно — стоит.
  bool get _wanted => widget.player.playing && AppActivity.visible.value;

  /// Играет и окно видно — тикаем; нет — ещё немного, пока полосы опускаются.
  void _update() {
    if (_wanted || _levels.value.any((v) => v > 0.01)) {
      if (!_ticker.isActive) {
        _last = Duration.zero;
        _ticker.start();
      }
    }
  }

  void _tick(Duration elapsed) {
    if (elapsed - _last < _frame) return;
    _last = elapsed;
    // MIDI на устройстве системы: спектра нет — полосы по звучащим нотам.
    final notes = _wanted ? widget.player.noteLevels() : null;
    final spectrum = _wanted && notes == null ? widget.player.spectrum() : null;
    final old = _levels.value;
    final next = List<double>.filled(_bars, 0.0);
    for (var i = 0; i < _bars; i++) {
      final target = notes != null
          ? (i < notes.length ? notes[i].toDouble() : 0.0)
          : (spectrum == null ? 0.0 : _band(spectrum, i));
      // Вверх — сразу, вниз — плавно.
      next[i] = target >= old[i] ? target : math.max(target, old[i] - 0.06);
    }
    _levels.value = next;
    if (spectrum == null && notes == null) {
      widget.player.stopSpectrum();
      if (next.every((v) => v <= 0.01)) {
        _levels.value = List.filled(_bars, 0.0);
        _ticker.stop();
      }
    }
  }

  /// Уровень полосы [i] (0..1): полосы делят спектр по логарифму частоты,
  /// чтобы низы и середина не сжимались в пару полос.
  static double _band(Float32List fft, int i) {
    const usable = 200; // выше — почти пусто
    final from = (math.pow(usable, i / _bars)).floor();
    final to = math.max(from + 1, (math.pow(usable, (i + 1) / _bars)).floor());
    var peak = 0.0;
    for (var k = from; k < to && k < fft.length; k++) {
      if (fft[k] > peak) peak = fft[k];
    }
    // Громкость ощущается по логарифму: сжимаем, чтобы полосы не упирались.
    return (math.log(1 + peak * 12) / math.log(13)).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final extras = Theme.of(context).extension<LauncherExtras>();
    final top = extras?.visualizerTop ?? scheme.primary;
    final base = extras?.visualizerBottom ?? top;
    return RepaintBoundary(
      child: ValueListenableBuilder<List<double>>(
        valueListenable: _levels,
        builder: (context, levels, _) => CustomPaint(
          size: Size.infinite,
          // Цвета темы (вверху полосы и у её основания), иначе акцент.
          painter: VisualizerBars(levels, top, base, base.withValues(alpha: 0.35)),
        ),
      ),
    );
  }
}

/// Полосы визуализации (открыт для тестов).
@visibleForTesting
class VisualizerBars extends CustomPainter {
  final List<double> levels;
  final Color top;
  final Color base;
  final Color bottom;
  VisualizerBars(this.levels, this.top, this.base, this.bottom);

  @override
  void paint(Canvas canvas, Size size) {
    final n = levels.length;
    final step = size.width / n;
    final bar = step * 0.62;
    // Верхняя часть — 60% высоты, отражение снизу — 40%, между ними щель.
    final mid = size.height * 0.6;
    const gap = 2.0;
    final gradient = top != base;
    final up = Paint()..color = top;
    final down = Paint()..color = bottom;
    // Два цвета — переход от основания полосы к её верху цветами вершин, одним
    // вызовом и без шейдера: градиент-шейдер на Windows (Impeller через
    // ANGLE) рисуется через временную текстуру на каждую полосу и кадр —
    // это сотни мегабайт.
    final positions = gradient ? Float32List(n * 12) : null;
    final colors = gradient ? Int32List(n * 6) : null;
    final baseArgb = base.toARGB32();
    for (var i = 0; i < n; i++) {
      // Даже в тишине — короткие полоски, чтобы было видно, что это.
      final v = math.max(levels[i], 0.04);
      final x = i * step + (step - bar) / 2;
      final y0 = mid - gap / 2 - v * (mid - gap);
      final y1 = mid - gap / 2;
      if (gradient) {
        // Цвет верха — по высоте полосы: у полной — [top], у низкой — ближе к [base].
        final topArgb = Color.lerp(base, top, v)!.toARGB32();
        positions!.setAll(i * 12, [x, y0, x + bar, y0, x, y1, x + bar, y0, x + bar, y1, x, y1]);
        colors!.setAll(i * 6, [topArgb, topArgb, baseArgb, topArgb, baseArgb, baseArgb]);
      } else {
        canvas.drawRect(Rect.fromLTRB(x, y0, x + bar, y1), up);
      }
      canvas.drawRect(
          Rect.fromLTRB(x, mid + gap / 2, x + bar, mid + gap / 2 + v * (size.height - mid - gap)), down);
    }
    if (gradient) {
      final vertices = ui.Vertices.raw(ui.VertexMode.triangles, positions!, colors: colors);
      // dst — только цвета вершин (без цвета кисти).
      canvas.drawVertices(vertices, BlendMode.dst, up);
      vertices.dispose();
    }
  }

  @override
  bool shouldRepaint(VisualizerBars old) =>
      old.levels != levels || old.top != top || old.base != base || old.bottom != bottom;
}
