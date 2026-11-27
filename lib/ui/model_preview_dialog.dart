import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:path/path.dart' as p;

import '../i18n.dart';
import '../models/game.dart';
import '../services/characters.dart';
import '../services/model_mesh.dart';
import '../services/model_packs.dart';
import '../services/model_raster.dart';
import 'model_viewer.dart';

/// В фоне: только явные аргументы (замыкание метода State может утащить
/// с собой то, что в другой изолят не передаётся).
List<Uint8List> _blendBatchJob((Uint8List, Uint8List, List<List<int>>, Uint8List) a) => [
      for (final ramp in a.$3) blendSkinColor(a.$1, a.$2, ramp, a.$4),
    ];

/// Модель, текстура и маска перекраски, прочитанные с диска.
class LoadedModel {
  final ModelMesh mesh;

  /// Текстура (RGBA); null — своей текстуры нет.
  final RasterTexture? texture;

  /// Маска перекраски того же размера; null — нет.
  final Uint8List? blend;
  const LoadedModel(this.mesh, this.texture, this.blend);
}

Future<ui.Image?> _decode(String path) async {
  try {
    final f = File(path);
    if (!await f.exists()) return null;
    final codec = await ui.instantiateImageCodec(await f.readAsBytes());
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  } catch (_) {
    return null;
  }
}

Future<Uint8List?> _rgba(ui.Image? image) async {
  final data = await image?.toByteData(format: ui.ImageByteFormat.rawRgba);
  // Своя копия с начала буфера: растеризатор читает её по 4 байта.
  return data == null ? null : Uint8List.fromList(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
}

/// Читает модель [m] набора [pack]: сетка — в фоне.
Future<LoadedModel> loadPackModel(ModelPack pack, PackModel m) async {
  final path = pack.file(m.line.path);
  final bytes = await File(path).readAsBytes();
  final mesh = await compute(ModelMesh.parse, bytes);
  final stem = p.withoutExtension(path);
  final image = await _decode('$stem.png');
  final blendImage = await _decode('${stem}_blend.png');
  final rgba = await _rgba(image);
  final blend = await _rgba(blendImage);
  final sameSize =
      image != null && blendImage != null && image.width == blendImage.width && image.height == blendImage.height;
  final texture = image == null || rgba == null ? null : RasterTexture(image.width, image.height, rgba);
  image?.dispose();
  blendImage?.dispose();
  return LoadedModel(mesh, texture, sameSize ? blend : null);
}

/// Что выбрали в окне модели.
sealed class ModelPick {
  const ModelPick();
}

/// По порядку наборов.
class ModelPickAuto extends ModelPick {
  const ModelPickAuto();
}

/// Выключить модель.
class ModelPickOff extends ModelPick {
  const ModelPickOff();
}

class ModelPickPack extends ModelPick {
  final String packId;
  final String? modelPath;
  const ModelPickPack(this.packId, [this.modelPath]);
}

/// Окно модели: 3D-вид, анимации, цвет игрока; справа — версии из наборов.
/// [palette] — PLAYPAL игры (для перекраски), может прийти позже.
Future<ModelPick?> showModelPreview(
  BuildContext context,
  GameDef game,
  ModelChoice choice,
  Future<Uint8List?> palette,
) => showDialog<ModelPick>(
  context: context,
  builder: (_) => _ModelPreview(game: game, choice: choice, palette: palette),
);

class _ModelPreview extends StatefulWidget {
  final GameDef game;
  final ModelChoice choice;
  final Future<Uint8List?> palette;
  const _ModelPreview({required this.game, required this.choice, required this.palette});

  @override
  State<_ModelPreview> createState() => _ModelPreviewState();
}

class _ModelPreviewState extends State<_ModelPreview> with SingleTickerProviderStateMixin {
  /// Какая версия на экране (номер в candidates).
  late int _shown = () {
    final chosen = widget.choice.chosen;
    final i = chosen == null
        ? 0
        : widget.choice.candidates.indexWhere(
            (c) => c.$1.id == chosen.$1.id && c.$2.line.path.toLowerCase() == chosen.$2.line.path.toLowerCase(),
          );
    return i < 0 ? 0 : i;
  }();

  LoadedModel? _model;
  RasterTexture? _colored;
  String? _error;
  bool _loading = true;
  List<(String, List<int>)> _animations = const [];
  int _animation = 0;
  bool _playing = true;
  bool _interpolate = true;

  /// Дробный шаг анимации (целая часть — кадр, дробная — доля интерполяции)
  /// и скорость воспроизведения (кадров в секунду).
  double _phase = 0;
  double _fps = 8;
  late final Ticker _ticker = createTicker(_onTick);
  Duration _lastTick = Duration.zero;
  static const _speeds = [1.0, 2.0, 4.0, 8.0, 12.0, 20.0, 35.0];

  List<int> get _frames => _animations.isEmpty ? const [0] : _animations[_animation].$2;
  int get _step => _phase.floor() % _frames.length;
  int get _frame => _frames[_step];
  int? get _nextFrame =>
      (_playing && _interpolate && _frames.length > 1) ? _frames[(_step + 1) % _frames.length] : null;
  double get _interp => _nextFrame != null ? _phase - _phase.floor() : 0.0;

  void _onTick(Duration elapsed) {
    final dt = _lastTick == Duration.zero
        ? 0.0
        : ((elapsed - _lastTick).inMicroseconds / 1e6).clamp(0.0, 0.1);
    _lastTick = elapsed;
    if (dt <= 0) return;
    var changed = false;
    if (_playing && _frames.length >= 2) {
      final prevStep = _step;
      final nextPhase = (_phase + dt * _fps) % _frames.length;
      if (!_interpolate && nextPhase.floor() % _frames.length == prevStep) {
        _phase = nextPhase;
      } else {
        _phase = nextPhase;
        changed = true;
      }
    }
    if (_coloredFrames.length > 1) {
      final order = CharacterScanner.pulseIndices(_coloredFrames.length);
      final nextColorStep = (elapsed.inMilliseconds ~/ 120) % order.length;
      if (nextColorStep != _colorStep) {
        _colorStep = nextColorStep;
        _colored = _coloredFrames[order[nextColorStep]];
        changed = true;
      }
    }
    if (changed) setState(() {});
  }

  /// Анимация идёт, пока есть движение модели или переливание супер-цвета.
  void _restartTimer() {
    if ((!_playing || _frames.length < 2) && _coloredFrames.length < 2) {
      _ticker.stop();
      _lastTick = Duration.zero;
      return;
    }
    if (!_ticker.isActive) {
      _lastTick = Duration.zero;
      _ticker.start();
    }
  }

  /// Шаг на кадр вперёд или назад; анимация встаёт на паузу.
  void _stepBy(int d) {
    setState(() {
      _playing = false;
      var s = (_step + d) % _frames.length;
      if (s < 0) s += _frames.length;
      _phase = s.toDouble();
    });
    _restartTimer();
  }
  Uint8List? _palette;

  /// Цвета игры (супер-цвета объединены в переливающиеся группы).
  late final List<({String name, List<List<int>> ramps, bool selectable})> _colors =
      CharacterScanner.groupColors(widget.game.skinColors, isHidden: GameDef.isSuperColorName)
          .where((g) => g.name != 'None')
          .toList();

  /// Цвет игрока (номер в [_colors]); null — без перекраски.
  int? _color;
  List<RasterTexture> _coloredFrames = const [];
  int _colorStep = 0;

  @override
  void initState() {
    super.initState();
    widget.palette.then((p) {
      if (!mounted) return;
      setState(() => _palette = p);
      _recolor();
    });
    final blue = _colors.indexWhere((c) => c.name == 'Blue');
    _color = blue >= 0 ? blue : (_colors.isNotEmpty ? 0 : null);
    _load();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final (pack, m) = widget.choice.candidates[_shown];
    final shown = _shown;
    setState(() {
      _loading = true;
      _error = null;
    });
    if (!m.hasModel) {
      setState(() {
        _model = null;
        _animations = const [];
        _error = tr('The pack has no file {file}: this model is left out of the pack.', {'file': m.line.path});
        _loading = false;
      });
      _restartTimer();
      return;
    }
    try {
      final model = await loadPackModel(pack, m);
      if (!mounted || shown != _shown) return;
      final anims = model.mesh.animations();
      // Стоит/ждёт — первыми, если есть.
      final stand = anims.indexWhere((a) => a.$1 == 'STND' || a.$1 == 'WAIT');
      setState(() {
        _model = model;
        _colored = null;
        _coloredFrames = const [];
        _colorStep = 0;
        _animations = anims;
        _animation = stand >= 0 ? stand : 0;
        _phase = 0;
        _loading = false;
      });
      _restartTimer();
      _recolor();
    } catch (e) {
      if (mounted && shown == _shown) {
        setState(() {
          _error = e is FormatException ? e.message : '$e';
          _loading = false;
        });
      }
    }
  }

  /// Перекраска текстуры в выбранный цвет (если у модели есть _blend).
  Future<void> _recolor() async {
    final model = _model, palette = _palette, color = _color;
    final texture = model?.texture;
    if (model == null || texture == null || model.blend == null || palette == null || color == null) {
      if (_colored != null || _coloredFrames.isNotEmpty) {
        setState(() {
          _colored = null;
          _coloredFrames = const [];
          _colorStep = 0;
        });
        _restartTimer();
      }
      return;
    }
    final ramps = _colors[color].ramps;
    final list = await compute(_blendBatchJob, (texture.rgba, model.blend!, ramps, palette));
    if (!mounted || model != _model || color != _color) return;
    final textures = [for (final pixels in list) RasterTexture(texture.width, texture.height, pixels)];
    setState(() {
      _coloredFrames = textures;
      _colorStep = 0;
      _colored = textures.first;
    });
    _restartTimer();
  }

  @override
  Widget build(BuildContext context) {
    final choice = widget.choice;
    final (pack, m) = choice.candidates[_shown];
    final model = _model;
    final muted = TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant);
    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 980,
        height: (MediaQuery.sizeOf(context).height - 48).clamp(360, 680).toDouble(),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                    child: Text(m.line.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 2, 20, 0),
                    child: Text(
                      [
                        pack.name,
                        m.line.path,
                        if (model != null) tr('{n} triangles', {'n': '${model.mesh.triangles}'}),
                        if (model != null) tr('{n} frames', {'n': '${model.mesh.frames}'}),
                        if (model != null && model.texture == null) tr('no texture: the game uses the sprite'),
                      ].join(' · '),
                      style: muted,
                    ),
                  ),
                  Expanded(
                    child: Container(
                      margin: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: _loading
                          ? const Center(child: CircularProgressIndicator())
                          : _error != null || model == null
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Text(
                                  !m.hasModel
                                      ? _error ?? ''
                                      : tr('Could not read the model: {error}', {'error': _error ?? ''}),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            )
                          : ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: ModelViewer(
                                mesh: model.mesh,
                                texture: _colored ?? model.texture,
                                frame: _frame,
                                nextFrame: _nextFrame,
                                interp: _interp,
                              ),
                            ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (_animations.length > 1)
                          DropdownButton<int>(
                            value: _animation,
                            isDense: true,
                            items: [
                              for (var i = 0; i < _animations.length; i++)
                                DropdownMenuItem(
                                  value: i,
                                  child: Text('${_animations[i].$1} (${_animations[i].$2.length})'),
                                ),
                            ],
                            onChanged: (v) {
                              setState(() {
                                _animation = v ?? 0;
                                _phase = 0;
                              });
                              _restartTimer();
                            },
                          ),
                        if (model != null && _frames.length > 1)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: tr('Previous frame'),
                                icon: const Icon(Icons.skip_previous),
                                onPressed: () => _stepBy(-1),
                              ),
                              IconButton(
                                tooltip: _playing ? tr('Pause') : tr('Play'),
                                icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                                onPressed: () {
                                  setState(() {
                                    _playing = !_playing;
                                    if (!_playing) _phase = _step.toDouble();
                                  });
                                  _restartTimer();
                                },
                              ),
                              IconButton(
                                tooltip: tr('Next frame'),
                                icon: const Icon(Icons.skip_next),
                                onPressed: () => _stepBy(1),
                              ),
                              const SizedBox(width: 4),
                              Tooltip(
                                message: tr('Animation speed'),
                                child: DropdownButton<double>(
                                  value: _fps,
                                  isDense: true,
                                  items: [
                                    for (final v in _speeds)
                                      DropdownMenuItem(value: v, child: Text(tr('{n} fps', {'n': v.toStringAsFixed(0)}))),
                                  ],
                                  onChanged: (v) {
                                    setState(() => _fps = v ?? 8);
                                    _restartTimer();
                                  },
                                ),
                              ),
                            ],
                          ),
                        if (model != null && _frames.length > 1)
                          FilterChip(
                            avatar: const Icon(Icons.animation, size: 16),
                            label: Text(tr('Model interpolation')),
                            selected: _interpolate,
                            visualDensity: VisualDensity.compact,
                            onSelected: (v) {
                              setState(() => _interpolate = v);
                              _restartTimer();
                            },
                          ),
                        if (model != null)
                          Text(
                            tr('Frame {i} of {n} · {name}', {
                              'i': '${_step + 1}',
                              'n': '${_frames.length}',
                              'name': model.mesh.frameNames[_frame.clamp(0, model.mesh.frames - 1)],
                            }),
                            style: muted,
                          ),
                        if (model?.blend != null && _palette != null)
                          DropdownButton<int>(
                            value: _color,
                            isDense: true,
                            hint: Text(tr('Color')),
                            items: [
                              for (var i = 0; i < _colors.length; i++)
                                DropdownMenuItem(value: i, child: Text(_colors[i].name)),
                            ],
                            onChanged: (v) {
                              setState(() => _color = v);
                              _recolor();
                            },
                          ),
                        Text(tr('Drag to rotate, right-drag to move, scroll to zoom, double-click to reset'), style: muted),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // Версии модели из наборов.
            Container(
              width: 300,
              color: Colors.black.withValues(alpha: 0.12),
              padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(tr('Versions'), style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(tr('Pick a version to look at it, then use it in the pack.'), style: muted),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView(
                      children: [
                        for (var i = 0; i < choice.candidates.length; i++)
                          () {
                            final (cp, cm) = choice.candidates[i];
                            final inUse = choice.chosen != null &&
                                choice.chosen!.$1.id == cp.id &&
                                choice.chosen!.$2.line.path.toLowerCase() == cm.line.path.toLowerCase();
                            return Card(
                              margin: const EdgeInsets.only(bottom: 6),
                              color: i == _shown ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.18) : null,
                              child: ListTile(
                                dense: true,
                                selected: i == _shown,
                                title: Text(cp.name, overflow: TextOverflow.ellipsis),
                                subtitle: Text(
                                  [
                                    cm.line.path,
                                    tr('scale {n}', {'n': cm.line.scale}),
                                    if (inUse) tr('in the pack'),
                                  ].join(' · '),
                                  style: const TextStyle(fontSize: 11),
                                ),
                                trailing: inUse ? const Icon(Icons.check_circle, size: 18) : null,
                                onTap: () {
                                  if (i == _shown) return;
                                  setState(() => _shown = i);
                                  _load();
                                },
                              ),
                            );
                          }(),
                      ],
                    ),
                  ),
                  FilledButton.icon(
                    icon: const Icon(Icons.check, size: 18),
                    label: Text(tr('Use this version')),
                    onPressed: () => Navigator.pop(context, ModelPickPack(pack.id, m.line.path)),
                  ),
                  const SizedBox(height: 6),
                  OutlinedButton(
                    onPressed: choice.manual ? () => Navigator.pop(context, const ModelPickAuto()) : null,
                    child: Text(tr('By pack order')),
                  ),
                  const SizedBox(height: 6),
                  OutlinedButton(
                    onPressed: choice.chosen == null ? null : () => Navigator.pop(context, const ModelPickOff()),
                    child: Text(tr('Turn off')),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
