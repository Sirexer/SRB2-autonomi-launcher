import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../i18n.dart';
import '../models/game.dart';
import '../services/gamepad_service.dart';
import '../services/srb2_config_schema.dart';

/// Открывает окно живого тестера геймпада и калибровки осей.
Future<void> showGamepadTesterDialog(
  BuildContext context, {
  required GameDef game,
  required int player,
  required List<(CvarSpec, String)> axisSpecs,
  required Map<String, String> currentValues,
  String? deadzoneCvar,
  double initialDeadzone = 0.125,
  String? deviceIndexCvar,
  void Function(String cvar, String value)? onCvarChanged,
  List<(ControlActionSpec, String)> controlDetectSpecs = const [],
  void Function(String command, String bind)? onControlBindChanged,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => GamepadTesterDialog(
      game: game,
      player: player,
      axisSpecs: axisSpecs,
      currentValues: currentValues,
      deadzoneCvar: deadzoneCvar,
      initialDeadzone: initialDeadzone,
      deviceIndexCvar: deviceIndexCvar,
      onCvarChanged: onCvarChanged,
      controlDetectSpecs: controlDetectSpecs,
      onControlBindChanged: onControlBindChanged,
    ),
  );
}

/// Быстрый диалог автоопределения одной оси (`joyaxis_*`). Возвращает выбранное имя оси.
Future<String?> showDetectAxisDialog(
  BuildContext context, {
  required GameDef game,
  required String actionLabel,
  String currentAxis = 'None',
}) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => _DetectAxisDialog(
      game: game,
      actionLabel: actionLabel,
      currentAxis: currentAxis,
    ),
  );
}

/// Диалог автоопределения стика, триггера, крестовины или кнопки для `setcontrol` (DRRR / BlanKart).
Future<String?> showDetectGamepadControlDialog(
  BuildContext context, {
  required GameDef game,
  required int player,
  required String actionLabel,
  String currentBind = '',
  GamepadService? gamepadService,
}) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => _DetectControlDialog(
      game: game,
      player: player,
      actionLabel: actionLabel,
      currentBind: currentBind,
      gamepadService: gamepadService,
    ),
  );
}

class GamepadTesterDialog extends StatefulWidget {
  final GameDef game;
  final int player;
  final List<(CvarSpec, String)> axisSpecs;
  final Map<String, String> currentValues;
  final String? deadzoneCvar;
  final double initialDeadzone;
  final String? deviceIndexCvar;
  final void Function(String cvar, String value)? onCvarChanged;
  final List<(ControlActionSpec, String)> controlDetectSpecs;
  final void Function(String command, String bind)? onControlBindChanged;

  /// Опциональный сервис для тестов (без реального железа).
  final GamepadService? service;

  const GamepadTesterDialog({
    super.key,
    required this.game,
    required this.player,
    required this.axisSpecs,
    required this.currentValues,
    this.deadzoneCvar,
    this.initialDeadzone = 0.125,
    this.deviceIndexCvar,
    this.onCvarChanged,
    this.controlDetectSpecs = const [],
    this.onControlBindChanged,
    this.service,
  });

  @override
  State<GamepadTesterDialog> createState() => _GamepadTesterDialogState();
}

class _GamepadTesterDialogState extends State<GamepadTesterDialog> {
  late final GamepadService _service = widget.service ?? GamepadService();
  late final bool _ownsService = widget.service == null;
  StreamSubscription<List<GamepadSnapshot>>? _sub;

  List<GamepadSnapshot> _devices = const [];
  int _selectedDeviceIdx = 1;
  GamepadLayout _layout = GamepadLayout.xbox;
  bool _layoutManuallyChosen = false;
  late double _deadzone = widget.initialDeadzone.clamp(0.0, 0.9);
  late final Map<String, String> _axes = Map<String, String>.from(widget.currentValues);
  late final Map<String, String> _ctrlBinds = {
    for (final (spec, cur) in widget.controlDetectSpecs) spec.command: cur,
  };

  GamepadLayout _resolveLayout(GamepadSnapshot d) {
    if (d.detectedLayout != GamepadLayout.generic) return d.detectedLayout;
    return d.isXInput ? GamepadLayout.xbox : GamepadLayout.generic;
  }

  @override
  void initState() {
    super.initState();
    _devices = _service.pollOnce();
    if (_devices.isNotEmpty) {
      _selectedDeviceIdx = _devices.first.deviceIndex;
      _layout = _resolveLayout(_devices.first);
    }
    _sub = _service.stream.listen((list) {
      if (!mounted || GamepadService.snapshotsEqual(_devices, list)) return;
      setState(() {
        _devices = list;
        if (_devices.isNotEmpty && !_devices.any((d) => d.deviceIndex == _selectedDeviceIdx)) {
          _selectedDeviceIdx = _devices.first.deviceIndex;
          if (!_layoutManuallyChosen) _layout = _resolveLayout(_devices.first);
        }
      });
    });
    if (_ownsService) {
      _service.startPolling();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    if (_ownsService) _service.dispose();
    super.dispose();
  }

  GamepadSnapshot? get _activeDevice {
    for (final d in _devices) {
      if (d.deviceIndex == _selectedDeviceIdx) return d;
    }
    return _devices.isEmpty ? null : _devices.first;
  }

  @override
  Widget build(BuildContext context) {
    final dev = _activeDevice;
    final cs = Theme.of(context).colorScheme;

    return Dialog(
      insetPadding: const EdgeInsets.all(28),
      child: SizedBox(
        width: 880,
        height: 660,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 18, 0, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  children: [
                    const Icon(Icons.sports_esports_outlined, size: 24),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        tr('Gamepad Tester & Calibration'),
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                      ),
                    ),
                    SegmentedButton<GamepadLayout>(
                      segments: const [
                        ButtonSegment(value: GamepadLayout.xbox, label: Text('Xbox')),
                        ButtonSegment(value: GamepadLayout.playstation, label: Text('PS')),
                        ButtonSegment(value: GamepadLayout.nintendo, label: Text('Nintendo')),
                        ButtonSegment(value: GamepadLayout.generic, label: Text('Raw')),
                      ],
                      selected: {_layout},
                      onSelectionChanged: (s) => setState(() {
                        _layout = s.first;
                        _layoutManuallyChosen = true;
                      }),
                    ),
                    const SizedBox(width: 8),
                    IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              // Панель выбора устройства.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  children: [
                    Expanded(
                      child: _devices.isEmpty
                          ? Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              decoration: BoxDecoration(
                                color: cs.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                tr('No gamepad detected. Connect a controller via USB or Bluetooth and press any button.'),
                                style: const TextStyle(color: Colors.grey),
                              ),
                            )
                          : DropdownButtonFormField<int>(
                              initialValue: dev?.deviceIndex,
                              isExpanded: true,
                              isDense: true,
                              decoration: InputDecoration(
                                labelText: tr('Connected controller'),
                                border: const OutlineInputBorder(),
                              ),
                              items: [
                                for (final d in _devices)
                                  DropdownMenuItem(value: d.deviceIndex, child: Text(d.name, overflow: TextOverflow.ellipsis)),
                              ],
                              onChanged: (v) {
                                if (v == null) return;
                                setState(() {
                                  _selectedDeviceIdx = v;
                                  if (!_layoutManuallyChosen) {
                                    final picked = _devices.where((d) => d.deviceIndex == v).firstOrNull;
                                    if (picked != null) _layout = _resolveLayout(picked);
                                  }
                                });
                              },
                            ),
                    ),
                    if (dev != null) ...[
                      const SizedBox(width: 8),
                      Chip(
                        avatar: const Icon(Icons.usb, size: 16),
                        label: Text(
                          dev.vidPidLabel == null
                              ? dev.detectedLayout.name
                              : '${dev.detectedLayout.name} · ${dev.vidPidLabel}',
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                        ),
                      ),
                    ],
                    const SizedBox(width: 8),
                    IconButton.outlined(
                      icon: const Icon(Icons.refresh),
                      tooltip: tr('Refresh controllers'),
                      onPressed: () => setState(() => _devices = _service.pollOnce()),
                    ),
                    if (dev != null && widget.deviceIndexCvar != null && widget.onCvarChanged != null) ...[
                      const SizedBox(width: 8),
                      FilledButton.tonal(
                        onPressed: () {
                          widget.onCvarChanged!(widget.deviceIndexCvar!, '${dev.deviceIndex}');
                        },
                        child: Text(tr('Use #{n} for P{p}', {'n': dev.deviceIndex, 'p': widget.player})),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(24, 0, 18, 0),
                    children: [
                    if (dev != null) ...[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _StickPad(
                            title: tr('Left Stick'),
                            x: dev.axisValue('lx'),
                            y: dev.axisValue('ly'),
                            deadzone: _deadzone,
                            axisNames: '${dev.axes.isNotEmpty ? dev.axes[0].axisNameFor(widget.game, negative: false) : "X"} / ${dev.axes.length > 1 ? dev.axes[1].axisNameFor(widget.game, negative: false) : "Y"}',
                          ),
                          const SizedBox(width: 16),
                          _StickPad(
                            title: tr('Right Stick'),
                            x: dev.axisValue('rx'),
                            y: dev.axisValue('ry'),
                            deadzone: _deadzone,
                            axisNames: '${dev.axes.length > 2 ? dev.axes[2].axisNameFor(widget.game, negative: false) : "RX"} / ${dev.axes.length > 3 ? dev.axes[3].axisNameFor(widget.game, negative: false) : "RY"}',
                          ),
                          const SizedBox(width: 16),
                          Expanded(child: _buildAxesBars(dev)),
                        ],
                      ),
                      const SizedBox(height: 14),
                      _buildButtonsPreview(dev),
                      const SizedBox(height: 14),
                    ],
                    if (widget.deadzoneCvar != null && widget.onCvarChanged != null) ...[
                      Row(
                        children: [
                          Text(tr('Stick deadzone preview ({name}):', {'name': widget.deadzoneCvar!}),
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                          Expanded(
                            child: Slider(
                              value: _deadzone,
                              min: 0,
                              max: 0.75,
                              divisions: 30,
                              label: _deadzone.toStringAsFixed(2),
                              onChanged: (v) {
                                final rounded = double.parse(v.toStringAsFixed(3));
                                setState(() => _deadzone = rounded);
                                widget.onCvarChanged!(widget.deadzoneCvar!, rounded.toString());
                              },
                            ),
                          ),
                          SizedBox(
                            width: 48,
                            child: Text(_deadzone.toStringAsFixed(2),
                                textAlign: TextAlign.end, style: const TextStyle(fontFamily: 'monospace')),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                    ],
                    if (widget.axisSpecs.isNotEmpty && widget.onCvarChanged != null) ...[
                      Text(
                        tr('Game axes ({game}, Player {p})', {'game': widget.game.name, 'p': widget.player}),
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 6),
                      for (final (spec, cvarName) in widget.axisSpecs) _buildAxisRow(spec, cvarName, dev),
                    ],
                    if (widget.controlDetectSpecs.isNotEmpty && widget.onControlBindChanged != null) ...[
                      if (widget.axisSpecs.isNotEmpty) const SizedBox(height: 12),
                      Text(
                        tr('Gamepad controls ({game}, Player {p})', {'game': widget.game.name, 'p': widget.player}),
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 6),
                      for (final (spec, _) in widget.controlDetectSpecs) _buildControlDetectRow(spec, dev),
                    ],
                  ],
                ),
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    FilledButton(onPressed: () => Navigator.pop(context), child: Text(tr('Done'))),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAxesBars(GamepadSnapshot dev) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Theme.of(context).dividerColor.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr('All axes (live)'), style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          for (final a in dev.axes)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  SizedBox(
                    width: 115,
                    child: Text(a.label, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis),
                  ),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        minHeight: 8,
                        value: a.isTrigger ? a.value.clamp(0.0, 1.0) : ((a.value + 1.0) / 2.0).clamp(0.0, 1.0),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 48,
                    child: Text(
                      a.value.toStringAsFixed(2),
                      textAlign: TextAlign.end,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 72,
                    child: Text(
                      a.axisNameFor(widget.game, negative: false),
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.grey),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildButtonsPreview(GamepadSnapshot dev) {
    final cs = Theme.of(context).colorScheme;
    final hats = const ['hatup', 'hatdown', 'hatleft', 'hatright'];
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Theme.of(context).dividerColor.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr('Buttons & D-Pad (live)'), style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var b = 1; b <= 12; b++) _btnPill(
                active: dev.pressedButtons.contains(b),
                friendly: GamepadNames.friendlyButton(b, _layout),
                bind: GamepadNames.srb2ButtonBind(b, widget.game, widget.player),
              ),
              for (final h in hats) _btnPill(
                active: dev.hat == h,
                friendly: GamepadNames.friendlyHat(h),
                bind: GamepadNames.srb2HatBind(h, widget.game, widget.player),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _btnPill({required bool active, required String friendly, required String bind}) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: active ? cs.primary : cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        '$friendly · $bind',
        style: TextStyle(
          fontSize: 12,
          fontWeight: active ? FontWeight.bold : FontWeight.normal,
          color: active ? cs.onPrimary : cs.onSurface,
        ),
      ),
    );
  }

  Widget _buildAxisRow(CvarSpec spec, String cvarName, GamepadSnapshot? dev) {
    final cur = _axes[cvarName] ?? spec.defaultValue;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr(spec.label), style: const TextStyle(fontWeight: FontWeight.w500)),
                Text(cvarName, style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.grey)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 230,
            child: DropdownButtonFormField<String>(
              initialValue: spec.options.contains(cur) ? cur : spec.options.firstOrNull,
              isExpanded: true,
              isDense: true,
              decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
              items: [
                for (final o in {...spec.options, cur})
                  DropdownMenuItem(
                    value: o,
                    child: Text(
                      GamepadNames.axisHint(o) == null ? o : '$o (${GamepadNames.axisHint(o)})',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() => _axes[cvarName] = v);
                widget.onCvarChanged!(cvarName, v);
              },
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.sensors, size: 16),
            label: Text(tr('Detect')),
            onPressed: dev == null
                ? null
                : () async {
                    final detected = await showDetectAxisDialog(
                      context,
                      game: widget.game,
                      actionLabel: tr(spec.label),
                      currentAxis: cur,
                    );
                    if (detected == null || !mounted) return;
                    setState(() => _axes[cvarName] = detected);
                    widget.onCvarChanged!(cvarName, detected);
                  },
          ),
        ],
      ),
    );
  }

  Widget _buildControlDetectRow(ControlActionSpec spec, GamepadSnapshot? dev) {
    final cur = _ctrlBinds[spec.command] ?? 'KEY0';
    final display = cur.isEmpty ? 'KEY0' : cur.toUpperCase();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr(spec.label), style: const TextStyle(fontWeight: FontWeight.w500)),
                Text(spec.command, style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.grey)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            width: 170,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              display,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: display == 'KEY0' ? Colors.grey : null,
              ),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.sensors, size: 16),
            label: Text(tr('Detect')),
            onPressed: dev == null
                ? null
                : () async {
                    final detected = await showDetectGamepadControlDialog(
                      context,
                      game: widget.game,
                      player: widget.player,
                      actionLabel: tr(spec.label),
                      currentBind: cur,
                    );
                    if (detected == null || !mounted) return;
                    setState(() => _ctrlBinds[spec.command] = detected);
                    widget.onControlBindChanged!(spec.command, detected);
                  },
          ),
        ],
      ),
    );
  }
}

class _StickPad extends StatelessWidget {
  final String title;
  final double x;
  final double y;
  final double deadzone;
  final String axisNames;

  const _StickPad({
    required this.title,
    required this.x,
    required this.y,
    required this.deadzone,
    required this.axisNames,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final mag = math.sqrt(x * x + y * y);
    final active = mag > deadzone;
    return Container(
      width: 160,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Theme.of(context).dividerColor.withValues(alpha: 0.5)),
      ),
      child: Column(
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          const SizedBox(height: 6),
          SizedBox(
            width: 110,
            height: 110,
            child: CustomPaint(
              painter: _StickPainter(
                x: x,
                y: y,
                deadzone: deadzone,
                dotColor: active ? cs.primary : Colors.grey,
                ringColor: cs.outlineVariant,
                deadzoneColor: cs.tertiary.withValues(alpha: 0.5),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'X:${x.toStringAsFixed(2)} Y:${y.toStringAsFixed(2)}',
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
          Text(
            axisNames,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 10, color: Colors.grey),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _StickPainter extends CustomPainter {
  final double x;
  final double y;
  final double deadzone;
  final Color dotColor;
  final Color ringColor;
  final Color deadzoneColor;

  const _StickPainter({
    required this.x,
    required this.y,
    required this.deadzone,
    required this.dotColor,
    required this.ringColor,
    required this.deadzoneColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide / 2 - 4;
    final borderPaint = Paint()
      ..color = ringColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawCircle(center, radius, borderPaint);
    canvas.drawLine(Offset(center.dx - radius, center.dy), Offset(center.dx + radius, center.dy), borderPaint);
    canvas.drawLine(Offset(center.dx, center.dy - radius), Offset(center.dx, center.dy + radius), borderPaint);

    if (deadzone > 0) {
      canvas.drawCircle(
        center,
        radius * deadzone.clamp(0.0, 1.0),
        Paint()
          ..color = deadzoneColor
          ..style = PaintingStyle.fill,
      );
    }

    final dx = (center.dx + x.clamp(-1.0, 1.0) * radius);
    final dy = (center.dy + y.clamp(-1.0, 1.0) * radius);
    canvas.drawCircle(Offset(dx, dy), 6, Paint()..color = dotColor);
  }

  @override
  bool shouldRepaint(_StickPainter old) =>
      old.x != x || old.y != y || old.deadzone != deadzone || old.dotColor != dotColor;
}

class _DetectAxisDialog extends StatefulWidget {
  final GameDef game;
  final String actionLabel;
  final String currentAxis;

  const _DetectAxisDialog({
    required this.game,
    required this.actionLabel,
    required this.currentAxis,
  });

  @override
  State<_DetectAxisDialog> createState() => _DetectAxisDialogState();
}

class _DetectAxisDialogState extends State<_DetectAxisDialog> {
  final _service = GamepadService();
  StreamSubscription<List<GamepadSnapshot>>? _sub;
  Map<int, Map<String, double>> _baselines = {};
  (GamepadAxisInfo, bool)? _detected;
  bool _hasController = false;

  @override
  void initState() {
    super.initState();
    final init = _service.pollOnce();
    _hasController = init.isNotEmpty;
    _baselines = {
      for (final d in init) d.deviceIndex: {for (final a in d.axes) a.id: a.value},
    };
    _sub = _service.stream.listen((list) {
      if (!mounted) return;
      final had = _hasController;
      _hasController = list.isNotEmpty;
      for (final d in list) {
        final base = _baselines.putIfAbsent(d.deviceIndex, () => {for (final a in d.axes) a.id: a.value});
        final hit = GamepadNames.detectMovedAxis(d, base);
        if (hit != null) {
          setState(() => _detected = hit);
          return;
        }
      }
      if (had != _hasController && mounted) setState(() {});
    });
    _service.startPolling();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final det = _detected;
    final axisName = det?.$1.axisNameFor(widget.game, negative: det.$2);
    final invertedName = det?.$1.axisNameFor(widget.game, negative: !det.$2);
    final cs = Theme.of(context).colorScheme;

    return AlertDialog(
      title: Text(tr('Detect axis: {action}', {'action': widget.actionLabel})),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: cs.primaryContainer.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: cs.primary),
              ),
              child: Column(
                children: [
                  const Icon(Icons.sensors, size: 30),
                  const SizedBox(height: 8),
                  Text(
                    det == null
                        ? (_hasController
                            ? tr('Move the desired stick or press a trigger all the way...')
                            : tr('No controller detected. Connect a gamepad and try again.'))
                        : '${det.$1.label} → $axisName',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (det != null && invertedName != null && invertedName != axisName) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      children: [
                        FilledButton(
                          onPressed: () => Navigator.pop(context, axisName),
                          child: Text(tr('Use {axis}', {'axis': axisName!})),
                        ),
                        OutlinedButton(
                          onPressed: () => Navigator.pop(context, invertedName),
                          child: Text(tr('Inverted ({axis})', {'axis': invertedName})),
                        ),
                      ],
                    ),
                  ] else if (det != null) ...[
                    const SizedBox(height: 10),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, axisName),
                      child: Text(tr('Use {axis}', {'axis': axisName!})),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (det != null)
          TextButton(
            onPressed: () {
              final cur = _service.pollOnce();
              setState(() {
                _detected = null;
                _baselines = {
                  for (final d in cur) d.deviceIndex: {for (final a in d.axes) a.id: a.value},
                };
              });
            },
            child: Text(tr('Detect again')),
          ),
        TextButton(onPressed: () => Navigator.pop(context, 'None'), child: Text(tr('Clear (None)'))),
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
      ],
    );
  }
}

class _DetectControlDialog extends StatefulWidget {
  final GameDef game;
  final int player;
  final String actionLabel;
  final String currentBind;
  final GamepadService? gamepadService;

  const _DetectControlDialog({
    required this.game,
    required this.player,
    required this.actionLabel,
    required this.currentBind,
    this.gamepadService,
  });

  @override
  State<_DetectControlDialog> createState() => _DetectControlDialogState();
}

class _DetectControlDialogState extends State<_DetectControlDialog> {
  late final GamepadService _service = widget.gamepadService ?? GamepadService();
  late final bool _ownsService = widget.gamepadService == null;
  StreamSubscription<List<GamepadSnapshot>>? _sub;
  final Map<int, Set<int>> _heldAtOpen = {};
  final Map<int, String?> _hatAtOpen = {};
  final Map<int, Map<String, double>> _axisBaselines = {};
  String? _connectedName;
  bool _done = false;

  void _finish([String? value]) {
    if (_done || !mounted) return;
    _done = true;
    _sub?.cancel();
    _sub = null;
    if (_ownsService) _service.stopPolling();
    Navigator.of(context).pop(value);
  }

  @override
  void initState() {
    super.initState();
    final init = _service.pollOnce();
    _connectedName = init.isNotEmpty ? init.first.name : null;
    for (final d in init) {
      _heldAtOpen[d.deviceIndex] = Set.of(d.pressedButtons);
      _hatAtOpen[d.deviceIndex] = d.hat;
      _axisBaselines[d.deviceIndex] = {for (final a in d.axes) a.id: a.value};
    }
    _sub = _service.stream.listen((list) {
      if (_done || !mounted) return;
      final nextName = list.isNotEmpty ? list.first.name : null;
      if (_connectedName != nextName) setState(() => _connectedName = nextName);
      for (final d in list) {
        final held = _heldAtOpen[d.deviceIndex];
        held?.removeWhere((b) => !d.pressedButtons.contains(b));
        for (final b in d.pressedButtons) {
          if (held == null || !held.contains(b)) {
            _finish(GamepadNames.srb2ButtonBind(b, widget.game, widget.player));
            return;
          }
        }
        final openHat = _hatAtOpen[d.deviceIndex];
        if (d.hat == null) {
          _hatAtOpen[d.deviceIndex] = null;
        } else if (d.hat != openHat) {
          _finish(GamepadNames.srb2HatBind(d.hat!, widget.game, widget.player));
          return;
        }
        if (GamepadNames.usesSdlControllerNames(widget.game)) {
          final base = _axisBaselines.putIfAbsent(d.deviceIndex, () => {for (final a in d.axes) a.id: a.value});
          final stick = GamepadNames.detectStickBind(d, base);
          if (stick != null) {
            _finish(stick);
            return;
          }
        }
      }
    });
    if (_ownsService) _service.startPolling();
  }

  @override
  void dispose() {
    _done = true;
    _sub?.cancel();
    if (_ownsService) _service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(tr('Detect control: {action}', {'action': widget.actionLabel})),
      content: SizedBox(
        width: 420,
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: cs.primaryContainer.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: cs.primary),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.sports_esports_outlined, size: 30),
              const SizedBox(height: 8),
              Text(
                tr('Tilt a stick, press a trigger, D-Pad or gamepad button...'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (_connectedName != null) ...[
                const SizedBox(height: 6),
                Text(
                  tr('Detected controller: {name}', {'name': _connectedName!}),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: cs.primary),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => _finish('KEY0'), child: Text(tr('Clear (KEY0)'))),
        TextButton(onPressed: () => _finish(), child: Text(tr('Cancel'))),
      ],
    );
  }
}
