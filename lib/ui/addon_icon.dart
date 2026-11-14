import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../services/app_activity.dart';

/// Какие обложки аддонов анимировать (GIF/WebP бывают анимированными, а
/// каждая анимация — это перерисовка десятки раз в секунду).
enum AddonIconAnimation { all, selected, none }

/// Обложка аддона: анимированная или только первый кадр. Декодируется под
/// размер на экране, перерисовывается отдельно от остального списка.
class AddonIcon extends StatelessWidget {
  final String path;
  final double size;
  final bool animate;
  final double radius;

  const AddonIcon(this.path, {super.key, required this.size, required this.animate, this.radius = 6});

  @override
  Widget build(BuildContext context) {
    final px = (size * MediaQuery.devicePixelRatioOf(context)).round();
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: animate ? _AnimatedFrames(path, size, px) : _StaticFrame(path, size, px),
      ),
    );
  }

}

Widget _placeholder(double size) => SizedBox(width: size, height: size, child: const Icon(Icons.extension_outlined, size: 28));

/// Анимация обложки — своими силами, а не Image.file:
/// - кадры декодируются по одному и в размере на экране (не весь GIF в памяти);
/// - скорость — как в файле (по часам, без накопления задержек), а «нулевая»
///   задержка GIF — 100 мс, как в браузерах;
/// - перерисовка не чаще 30 раз в секунду: если кадры короче, лишние
///   пропускаются (скорость от этого не меняется);
/// - пока окно неактивно или свёрнуто, анимация стоит.
class _AnimatedFrames extends StatefulWidget {
  final String path;
  final double size;
  final int px;
  const _AnimatedFrames(this.path, this.size, this.px);

  @override
  State<_AnimatedFrames> createState() => _AnimatedFramesState();
}

class _AnimatedFramesState extends State<_AnimatedFrames> {
  static const _minRedraw = Duration(milliseconds: 33);

  ui.Codec? _codec;
  ui.Image? _image;
  Timer? _timer;
  bool _waiting = false; // кадр пора показать, но окно неактивно

  /// Часы анимации (стоят, пока окно неактивно) и когда кончается показанный кадр.
  final _clock = Stopwatch();
  Duration _frameEnd = Duration.zero;

  @override
  void initState() {
    super.initState();
    AppActivity.focused.addListener(_onFocus);
    _open();
  }

  @override
  void didUpdateWidget(covariant _AnimatedFrames old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path || old.px != widget.px) {
      _close();
      _open();
    }
  }

  Future<void> _open() async {
    try {
      final bytes = await File(widget.path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes, targetHeight: widget.px);
      if (!mounted) {
        codec.dispose();
        return;
      }
      _codec = codec;
      _clock
        ..reset()
        ..start();
      _frameEnd = Duration.zero;
      _tick();
    } catch (_) {}
  }

  static Duration _delay(Duration d) => d <= const Duration(milliseconds: 10) ? const Duration(milliseconds: 100) : d;

  Future<void> _tick() async {
    final codec = _codec;
    if (codec == null) return;
    try {
      final now = _clock.elapsed;
      ui.FrameInfo? frame;
      // Кадры, чьё время уже прошло, декодируем, но не рисуем.
      var skipped = 0;
      do {
        final next = await codec.getNextFrame();
        if (!mounted || codec != _codec) {
          next.image.dispose();
          frame?.image.dispose();
          return;
        }
        frame?.image.dispose();
        frame = next;
        _frameEnd += _delay(next.duration);
      } while (codec.frameCount > 1 && _frameEnd <= now && ++skipped < codec.frameCount);
      final old = _image;
      setState(() => _image = frame!.image);
      old?.dispose();
      if (codec.frameCount <= 1) return; // не анимация
      var wait = _frameEnd - _clock.elapsed;
      if (wait < _minRedraw) wait = _minRedraw;
      _timer = Timer(wait, () {
        if (AppActivity.focused.value && AppActivity.visible.value) {
          _tick();
        } else {
          _waiting = true;
          _clock.stop();
        }
      });
    } catch (_) {}
  }

  void _onFocus() {
    if (_waiting && AppActivity.focused.value) {
      _waiting = false;
      _clock.start();
      _tick();
    }
  }

  void _close() {
    _timer?.cancel();
    _timer = null;
    _waiting = false;
    _clock.stop();
    _codec?.dispose();
    _codec = null;
  }

  @override
  void dispose() {
    AppActivity.focused.removeListener(_onFocus);
    _close();
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) return _placeholder(widget.size);
    return RawImage(
        image: image, width: widget.size, height: widget.size, fit: BoxFit.cover, filterQuality: FilterQuality.medium);
  }
}

/// Первый кадр картинки — без анимации и без таймеров.
class _StaticFrame extends StatelessWidget {
  final String path;
  final double size;
  final int px;
  const _StaticFrame(this.path, this.size, this.px);

  static final Map<String, Future<ui.Image?>> _loading = {};
  static final Map<String, ui.Image?> _ready = {};

  static Future<ui.Image?> _firstFrame(String key, String path, int px) async {
    ui.Image? image;
    try {
      final bytes = await File(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes, targetHeight: px);
      image = (await codec.getNextFrame()).image;
      codec.dispose();
    } catch (_) {
      image = null;
    }
    _ready[key] = image;
    return image;
  }

  @override
  Widget build(BuildContext context) {
    final key = '$path|$px';
    return FutureBuilder<ui.Image?>(
      future: _loading.putIfAbsent(key, () => _firstFrame(key, path, px)),
      // Уже готовый кадр — сразу, без мигания пустым местом.
      initialData: _ready[key],
      builder: (context, snap) {
        final image = snap.data;
        if (image == null) return _placeholder(size);
        return RawImage(image: image, width: size, height: size, fit: BoxFit.cover, filterQuality: FilterQuality.medium);
      },
    );
  }
}
