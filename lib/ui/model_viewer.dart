import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../services/model_mesh.dart';
import '../services/model_raster.dart';

/// 3D-модель в кадре [frame]: крутится мышью (перетаскивание),
/// приближается колесом. Рисуется с проверкой глубины по пикселям
/// ([rasterizeModel]), как в игре. Анимацией управляет тот, кто показывает.
class ModelViewer extends StatefulWidget {
  final ModelMesh mesh;

  /// Текстура (RGBA); null — серая модель.
  final RasterTexture? texture;

  /// Номер кадра модели.
  final int frame;

  /// Следующий кадр и доля перехода (0..1) для плавной интерполяции вершин.
  final int? nextFrame;
  final double interp;

  /// Поворот вокруг вертикали при открытии (радианы от «лицом к нам»).
  final double initialYaw;

  const ModelViewer({
    super.key,
    required this.mesh,
    this.texture,
    this.frame = 0,
    this.nextFrame,
    this.interp = 0,
    this.initialYaw = 0,
  });

  @override
  State<ModelViewer> createState() => _ModelViewerState();
}

class _ModelViewerState extends State<ModelViewer> {
  // Модель смотрит на нас лицом: в SRB2 «вперёд» — ось X.
  static const _frontYaw = -math.pi / 2 - 0.5;
  late double _yaw = _frontYaw + widget.initialYaw;
  double _pitch = 0.25, _zoom = 1;
  Offset _pan = Offset.zero;
  bool _panning = false;

  /// Размер и центр — по всем кадрам: модель не прыгает при анимации.
  late List<double> _bounds = widget.mesh.bounds();

  @override
  void didUpdateWidget(ModelViewer old) {
    super.didUpdateWidget(old);
    if (!identical(old.mesh, widget.mesh)) _bounds = widget.mesh.bounds();
  }

  /// Готовая картинка и что в ней нарисовано.
  ui.Image? _image;
  Object? _drawn;
  bool _rendering = false;
  Size _size = Size.zero;
  double _ratio = 1;

  /// Что нужно нарисовать сейчас (сравнивается с [_drawn]).
  Object get _wanted => (
        widget.mesh,
        widget.texture,
        _frame,
        _nextFrame,
        _interp,
        _yaw,
        _pitch,
        _zoom,
        _pan,
        _size,
        _ratio,
      );

  /// Рисует, если картинка устарела; пока рисуется — новый запрос
  /// подождёт и возьмёт последнее положение.
  Future<void> _render() async {
    if (_rendering || !mounted) return;
    final want = _wanted;
    if (want == _drawn || _size.isEmpty) return;
    _rendering = true;
    try {
      final w = (_size.width * _ratio).round(), h = (_size.height * _ratio).round();
      final pixels = rasterizeModel(
        widget.mesh,
        _frame,
        widget.texture,
        w,
        h,
        nextFrame: _nextFrame,
        interp: _interp,
        panX: _pan.dx * _ratio,
        panY: _pan.dy * _ratio,
        yaw: _yaw,
        pitch: _pitch,
        zoom: _zoom,
        bounds: _bounds,
      );
      final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
      final descriptor = ui.ImageDescriptor.raw(buffer, width: w, height: h, pixelFormat: ui.PixelFormat.rgba8888);
      final codec = await descriptor.instantiateCodec();
      final frame = await codec.getNextFrame();
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      final old = _image;
      setState(() {
        _image = frame.image;
        _drawn = want;
      });
      old?.dispose();
    } finally {
      _rendering = false;
    }
    if (mounted && _wanted != _drawn) _render();
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  int get _frame => widget.frame.clamp(0, math.max(0, widget.mesh.frames - 1));
  int? get _nextFrame => widget.nextFrame?.clamp(0, math.max(0, widget.mesh.frames - 1));
  double get _interp => (_nextFrame == null || _nextFrame == _frame) ? 0.0 : widget.interp.clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (e) {
        if ((e.buttons & kSecondaryMouseButton) != 0 && !_panning) {
          setState(() => _panning = true);
        }
      },
      onPointerMove: (e) {
        if ((e.buttons & kSecondaryMouseButton) != 0) {
          setState(() {
            _panning = true;
            _pan = Offset(
              (_pan.dx + e.delta.dx).clamp(-_size.width, _size.width),
              (_pan.dy + e.delta.dy).clamp(-_size.height, _size.height),
            );
          });
        }
      },
      onPointerUp: (_) {
        if (_panning) setState(() => _panning = false);
      },
      onPointerCancel: (_) {
        if (_panning) setState(() => _panning = false);
      },
      onPointerSignal: (e) {
        if (e is PointerScrollEvent) {
          setState(() => _zoom = (_zoom * math.pow(0.999, e.scrollDelta.dy)).clamp(0.3, 6.0));
        }
      },
      child: GestureDetector(
        onPanUpdate: (d) => setState(() {
          _yaw -= d.delta.dx * 0.01;
          _pitch = (_pitch + d.delta.dy * 0.01).clamp(-1.5, 1.5);
        }),
        onDoubleTap: () => setState(() {
          _yaw = _frontYaw + widget.initialYaw;
          _pitch = 0.25;
          _zoom = 1;
          _pan = Offset.zero;
        }),
        child: MouseRegion(
          cursor: _panning ? SystemMouseCursors.move : SystemMouseCursors.grab,
          child: LayoutBuilder(
            builder: (context, box) {
              _size = box.biggest;
              // Чётче на HiDPI, но не дороже полутора пикселей на точку.
              _ratio = math.min(MediaQuery.devicePixelRatioOf(context), 1.5);
              if (_wanted != _drawn) WidgetsBinding.instance.addPostFrameCallback((_) => _render());
              return SizedBox.expand(
                child: _image == null
                    ? null
                    : RawImage(image: _image, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
              );
            },
          ),
        ),
      ),
    );
  }
}
