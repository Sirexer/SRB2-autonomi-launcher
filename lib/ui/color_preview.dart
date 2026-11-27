import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_activity.dart';
import '../services/characters.dart';

/// Спрайт-образец (assets/color_preview.bin), перекрашенный в цвет: индексы
/// палитры 96–111 (ramp «Green», startcolor по умолчанию) заменяются на ramp.
/// Формат файла: ширина, высота (uint16 LE), индексы, маска, PLAYPAL (768 байт).
///
/// Если передано несколько кадров [ramps] и [animate] включена — плавно
/// переливается по очереди (как супер-цвета в SRB2), останавливаясь, пока окно
/// неактивно.
class ColorPreview extends StatelessWidget {
  final List<int> ramp;
  final List<List<int>>? ramps;
  final bool animate;
  final double height;
  const ColorPreview(this.ramp, {super.key, this.height = 96, this.ramps, this.animate = true});

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

  static Uint8List _renderRamp((int, int, Uint8List, Uint8List, Uint8List) t, List<int> r) =>
      _cache.putIfAbsent(r.join(','), () => CharacterScanner.render(t.$1, t.$2, t.$3, t.$4, t.$5, 96, r));

  @override
  Widget build(BuildContext context) {
    final frames = ramps;
    if (frames != null && frames.length > 1 && animate) {
      return _AnimatedColorPreview(ramps: frames, height: height);
    }
    final active = frames != null && frames.length > 1 ? CharacterScanner.stillRamp(frames) : ramp;
    return FutureBuilder(
      future: _load(),
      builder: (context, snap) {
        final t = snap.data;
        if (t == null) return SizedBox(width: height * 34 / 64, height: height);
        return Image.memory(_renderRamp(t, active), height: height, filterQuality: FilterQuality.none, gaplessPlayback: true);
      },
    );
  }
}

class _AnimatedColorPreview extends StatefulWidget {
  final List<List<int>> ramps;
  final double height;
  const _AnimatedColorPreview({required this.ramps, required this.height});

  @override
  State<_AnimatedColorPreview> createState() => _AnimatedColorPreviewState();
}

class _AnimatedColorPreviewState extends State<_AnimatedColorPreview> {
  static const _stepDuration = Duration(milliseconds: 120);

  Timer? _timer;
  int _step = 0;
  (int, int, Uint8List, Uint8List, Uint8List)? _template;
  late List<int> _order = CharacterScanner.pulseIndices(widget.ramps.length);

  @override
  void initState() {
    super.initState();
    AppActivity.focused.addListener(_onActivity);
    AppActivity.visible.addListener(_onActivity);
    ColorPreview._load().then((t) {
      if (!mounted) return;
      setState(() => _template = t);
      _syncTimer();
    });
  }

  @override
  void didUpdateWidget(covariant _AnimatedColorPreview old) {
    super.didUpdateWidget(old);
    if (old.ramps != widget.ramps) {
      _order = CharacterScanner.pulseIndices(widget.ramps.length);
      _step = 0;
    }
  }

  void _onActivity() => _syncTimer();

  void _syncTimer() {
    final active = _template != null && AppActivity.focused.value && AppActivity.visible.value && _order.length > 1;
    if (!active) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer ??= Timer.periodic(_stepDuration, (_) {
      if (!mounted) return;
      setState(() => _step = (_step + 1) % _order.length);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    AppActivity.focused.removeListener(_onActivity);
    AppActivity.visible.removeListener(_onActivity);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = _template;
    if (t == null) return SizedBox(width: widget.height * 34 / 64, height: widget.height);
    final png = ColorPreview._renderRamp(t, widget.ramps[_order[_step % _order.length]]);
    return Image.memory(png, height: widget.height, filterQuality: FilterQuality.none, gaplessPlayback: true);
  }
}
