import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../services/app_activity.dart';
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
    final spectrum = _wanted ? widget.player.spectrum() : null;
    final old = _levels.value;
    final next = List<double>.filled(_bars, 0.0);
    for (var i = 0; i < _bars; i++) {
      final target = spectrum == null ? 0.0 : _band(spectrum, i);
      // Вверх — сразу, вниз — плавно.
      next[i] = target >= old[i] ? target : math.max(target, old[i] - 0.06);
    }
    _levels.value = next;
    if (spectrum == null) {
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
    return RepaintBoundary(
      child: ValueListenableBuilder<List<double>>(
        valueListenable: _levels,
        builder: (context, levels, _) => CustomPaint(
          size: Size.infinite,
          painter: _BarsPainter(levels, scheme.primary, scheme.primary.withValues(alpha: 0.35)),
        ),
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  final List<double> levels;
  final Color top;
  final Color bottom;
  _BarsPainter(this.levels, this.top, this.bottom);

  @override
  void paint(Canvas canvas, Size size) {
    final n = levels.length;
    final step = size.width / n;
    final bar = step * 0.62;
    // Верхняя часть — 60% высоты, отражение снизу — 40%, между ними щель.
    final mid = size.height * 0.6;
    const gap = 2.0;
    final up = Paint()..color = top;
    final down = Paint()..color = bottom;
    for (var i = 0; i < n; i++) {
      // Даже в тишине — короткие полоски, чтобы было видно, что это.
      final v = math.max(levels[i], 0.04);
      final x = i * step + (step - bar) / 2;
      canvas.drawRect(Rect.fromLTRB(x, mid - gap / 2 - v * (mid - gap), x + bar, mid - gap / 2), up);
      canvas.drawRect(
          Rect.fromLTRB(x, mid + gap / 2, x + bar, mid + gap / 2 + v * (size.height - mid - gap)), down);
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) => old.levels != levels || old.top != top || old.bottom != bottom;
}
