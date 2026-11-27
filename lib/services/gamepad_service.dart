import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../models/game.dart';

/// Раскладка подписей кнопок геймпада (по мотивам `sc_gamepad` из Spectator Camera).
enum GamepadLayout { xbox, playstation, nintendo, generic }

/// Опознанная модель контроллера по USB/Bluetooth VID/PID или системному имени.
class GamepadIdentity {
  final String modelName;
  final GamepadLayout layout;
  final int? vendorId;
  final int? productId;

  const GamepadIdentity({
    required this.modelName,
    required this.layout,
    this.vendorId,
    this.productId,
  });

  String? get vidPidLabel {
    if (vendorId == null || productId == null) return null;
    final v = vendorId!.toRadixString(16).toUpperCase().padLeft(4, '0');
    final p = productId!.toRadixString(16).toUpperCase().padLeft(4, '0');
    return '$v:$p';
  }
}

/// База популярных контроллеров по VID/PID и имени.
class GamepadCatalog {
  GamepadCatalog._();

  static GamepadIdentity identify({
    int? vendorId,
    int? productId,
    String? rawName,
    bool isXInput = false,
  }) {
    if (vendorId == 0x045E) {
      final model = switch (productId) {
        0x028E || 0x028F || 0x0719 => 'Xbox 360 Controller',
        0x02D1 || 0x02DD => 'Xbox One Controller',
        0x02E0 || 0x02EA || 0x02FD || 0x02FF => 'Xbox One S / Wireless Controller',
        0x02E3 || 0x0B00 || 0x0B05 => 'Xbox Elite Wireless Controller',
        0x0B12 || 0x0B13 => 'Xbox Series X|S Controller',
        _ => 'Xbox Controller',
      };
      return GamepadIdentity(
        modelName: model,
        layout: GamepadLayout.xbox,
        vendorId: vendorId,
        productId: productId,
      );
    }
    if (vendorId == 0x054C) {
      final model = switch (productId) {
        0x0268 => 'PlayStation DualShock 3',
        0x05C4 || 0x09CC || 0x0BA0 => 'PlayStation DualShock 4',
        0x0CE6 => 'PlayStation DualSense',
        0x0DF2 => 'PlayStation DualSense Edge',
        _ => 'PlayStation Controller',
      };
      return GamepadIdentity(
        modelName: model,
        layout: GamepadLayout.playstation,
        vendorId: vendorId,
        productId: productId,
      );
    }
    if (vendorId == 0x057E) {
      final model = switch (productId) {
        0x2006 => 'Nintendo Joy-Con (L)',
        0x2007 => 'Nintendo Joy-Con (R)',
        0x2009 => 'Nintendo Switch Pro Controller',
        0x200E => 'Nintendo Joy-Con Grip',
        _ => 'Nintendo Controller',
      };
      return GamepadIdentity(
        modelName: model,
        layout: GamepadLayout.nintendo,
        vendorId: vendorId,
        productId: productId,
      );
    }
    if (vendorId == 0x2DC8) {
      return GamepadIdentity(
        modelName: '8BitDo Controller',
        layout: GamepadLayout.xbox,
        vendorId: vendorId,
        productId: productId,
      );
    }
    if (vendorId == 0x046D) {
      return GamepadIdentity(
        modelName: 'Logitech Gamepad',
        layout: GamepadLayout.xbox,
        vendorId: vendorId,
        productId: productId,
      );
    }
    if (vendorId == 0x28DE) {
      return GamepadIdentity(
        modelName: 'Steam Controller / Deck',
        layout: GamepadLayout.xbox,
        vendorId: vendorId,
        productId: productId,
      );
    }

    final lower = (rawName ?? '').toLowerCase();
    if (lower.contains('dualsense') ||
        lower.contains('dualshock') ||
        lower.contains('playstation') ||
        lower.contains('wireless controller') ||
        lower.contains('ps4') ||
        lower.contains('ps5')) {
      return GamepadIdentity(
        modelName: rawName?.trim().isNotEmpty == true ? rawName!.trim() : 'PlayStation Controller',
        layout: GamepadLayout.playstation,
        vendorId: vendorId,
        productId: productId,
      );
    }
    if (lower.contains('nintendo') || lower.contains('switch') || lower.contains('joy-con') || lower.contains('pro controller')) {
      return GamepadIdentity(
        modelName: rawName?.trim().isNotEmpty == true ? rawName!.trim() : 'Nintendo Controller',
        layout: GamepadLayout.nintendo,
        vendorId: vendorId,
        productId: productId,
      );
    }
    if (isXInput || lower.contains('xbox') || lower.contains('xinput') || lower.contains('360')) {
      return GamepadIdentity(
        modelName: rawName?.trim().isNotEmpty == true ? rawName!.trim() : 'Xbox / XInput Controller',
        layout: GamepadLayout.xbox,
        vendorId: vendorId,
        productId: productId,
      );
    }
    return GamepadIdentity(
      modelName: rawName?.trim().isNotEmpty == true ? rawName!.trim() : 'Generic Gamepad',
      layout: GamepadLayout.generic,
      vendorId: vendorId,
      productId: productId,
    );
  }
}

/// Состояние одной физической оси геймпада в реальном времени.
class GamepadAxisInfo {
  final String id;
  final String label;

  /// Нормализованное значение: `-1.0..1.0` для стиков или `0.0..1.0` для курков.
  final double value;

  /// Имя оси в SRB2 / Legacy при положительном и отрицательном отклонении.
  final String srb2Positive;
  final String srb2Negative;

  /// Имя оси в SRB2Kart при положительном и отрицательном отклонении.
  final String kartPositive;
  final String kartNegative;

  final bool isTrigger;

  const GamepadAxisInfo({
    required this.id,
    required this.label,
    required this.value,
    required this.srb2Positive,
    required this.srb2Negative,
    required this.kartPositive,
    required this.kartNegative,
    this.isTrigger = false,
  });

  String axisNameFor(GameDef game, {required bool negative}) {
    if (game.engine == 'srb2kart') {
      return negative ? kartNegative : kartPositive;
    }
    return negative ? srb2Negative : srb2Positive;
  }
}

/// Текущий снимок состояния одного подключённого геймпада.
class GamepadSnapshot {
  /// 1-based индекс устройства (совпадает с `use_gamepad` / `use_joystick`).
  final int deviceIndex;
  final String name;
  final bool isXInput;
  final GamepadLayout detectedLayout;
  final int? vendorId;
  final int? productId;
  final List<GamepadAxisInfo> axes;

  /// Нажатые кнопки (1-based номера: 1 = `joy1`, 2 = `joy2`, ...).
  final Set<int> pressedButtons;

  /// Направление крестовины (`hatup`, `hatdown`, `hatleft`, `hatright`) или null.
  final String? hat;

  const GamepadSnapshot({
    required this.deviceIndex,
    required this.name,
    required this.isXInput,
    this.detectedLayout = GamepadLayout.generic,
    this.vendorId,
    this.productId,
    required this.axes,
    required this.pressedButtons,
    this.hat,
  });

  String? get vidPidLabel {
    if (vendorId == null || productId == null) return null;
    final v = vendorId!.toRadixString(16).toUpperCase().padLeft(4, '0');
    final p = productId!.toRadixString(16).toUpperCase().padLeft(4, '0');
    return '$v:$p';
  }

  double axisValue(String id) {
    for (final a in axes) {
      if (a.id == id) return a.value;
    }
    return 0;
  }
}

/// Словарь понятных подписей и преобразование кнопок/осей в имена SRB2/Kart/RR/BlanKart.
class GamepadNames {
  GamepadNames._();

  static const _xboxLabels = <int, String>{
    1: 'A',
    2: 'B',
    3: 'X',
    4: 'Y',
    5: 'LB',
    6: 'RB',
    7: 'Back',
    8: 'Start',
    9: 'LS',
    10: 'RS',
    11: 'LT',
    12: 'RT',
  };

  static const _psLabels = <int, String>{
    1: 'Cross (×)',
    2: 'Circle (○)',
    3: 'Square (□)',
    4: 'Triangle (△)',
    5: 'L1',
    6: 'R1',
    7: 'Share / Create',
    8: 'Options',
    9: 'L3',
    10: 'R3',
    11: 'L2',
    12: 'R2',
  };

  static const _nintendoLabels = <int, String>{
    1: 'B',
    2: 'A',
    3: 'Y',
    4: 'X',
    5: 'L',
    6: 'R',
    7: 'Minus (-)',
    8: 'Plus (+)',
    9: 'LS',
    10: 'RS',
    11: 'ZL',
    12: 'ZR',
  };

  static const _sdlControllerButtons = <int, String>{
    1: 'A BUTTON',
    2: 'B BUTTON',
    3: 'X BUTTON',
    4: 'Y BUTTON',
    5: 'L BUMPER',
    6: 'R BUMPER',
    7: 'BACK BUTTON',
    8: 'START BUTTON',
    9: 'L-STICK CLICK',
    10: 'R-STICK CLICK',
    11: 'L TRIGGER',
    12: 'R TRIGGER',
  };

  static String friendlyButton(int btn, GamepadLayout layout) => switch (layout) {
        GamepadLayout.xbox => _xboxLabels[btn] ?? 'Button $btn',
        GamepadLayout.playstation => _psLabels[btn] ?? 'Button $btn',
        GamepadLayout.nintendo => _nintendoLabels[btn] ?? 'Button $btn',
        GamepadLayout.generic => 'Button $btn',
      };

  static String friendlyHat(String hat) => switch (hat) {
        'hatup' => 'D-Pad Up',
        'hatdown' => 'D-Pad Down',
        'hatleft' => 'D-Pad Left',
        'hatright' => 'D-Pad Right',
        _ => hat,
      };

  static bool usesSdlControllerNames(GameDef game) =>
      game.engine == 'drrr' || game.id == 'srb2blankart';

  /// Возвращает имя кнопки для `setcontrol` выбранной игры и игрока [player] (1..4).
  static String srb2ButtonBind(int btn, GameDef game, int player) {
    if (usesSdlControllerNames(game)) {
      return _sdlControllerButtons[btn] ?? 'joy$btn';
    }
    return switch (player) {
      2 => 'sec_joy$btn',
      3 => 'TRD_JOY$btn',
      4 => 'FOR_JOY$btn',
      _ => 'joy$btn',
    };
  }

  /// Возвращает имя крестовины для `setcontrol` выбранной игры и игрока [player] (1..4).
  static String srb2HatBind(String hat, GameDef game, int player) {
    if (usesSdlControllerNames(game)) {
      return switch (hat) {
        'hatup' => 'D-PAD UP',
        'hatdown' => 'D-PAD DOWN',
        'hatleft' => 'D-PAD LEFT',
        'hatright' => 'D-PAD RIGHT',
        _ => hat.toUpperCase(),
      };
    }
    return switch (player) {
      2 => 'sec_$hat',
      3 => 'TRD_${hat.toUpperCase()}',
      4 => 'FOR_${hat.toUpperCase()}',
      _ => hat,
    };
  }

  /// Стандартные 6 осей SDL2 / GameController (XInput, DualSense, Switch Pro) в именах SRB2 и Kart.
  static List<GamepadAxisInfo> standardSdlAxes({
    required double lx,
    required double ly,
    required double rx,
    required double ry,
    required double lt,
    required double rt,
  }) =>
      [
        GamepadAxisInfo(
          id: 'lx',
          label: 'Left Stick X',
          value: lx.clamp(-1.0, 1.0),
          srb2Positive: 'X-Axis',
          srb2Negative: 'X-Axis-',
          kartPositive: 'Left X',
          kartNegative: 'Left X-',
        ),
        GamepadAxisInfo(
          id: 'ly',
          label: 'Left Stick Y',
          value: ly.clamp(-1.0, 1.0),
          srb2Positive: 'Y-Axis',
          srb2Negative: 'Y-Axis-',
          kartPositive: 'Left Y',
          kartNegative: 'Left Y-',
        ),
        GamepadAxisInfo(
          id: 'rx',
          label: 'Right Stick X',
          value: rx.clamp(-1.0, 1.0),
          srb2Positive: 'Z-Axis',
          srb2Negative: 'Z-Axis-',
          kartPositive: 'Right X',
          kartNegative: 'Right X-',
        ),
        GamepadAxisInfo(
          id: 'ry',
          label: 'Right Stick Y',
          value: ry.clamp(-1.0, 1.0),
          srb2Positive: 'X-Rudder-',
          srb2Negative: 'X-Rudder',
          kartPositive: 'Right Y',
          kartNegative: 'Right Y-',
        ),
        GamepadAxisInfo(
          id: 'lt',
          label: 'Left Trigger (LT)',
          value: lt.clamp(0.0, 1.0),
          srb2Positive: 'Y-Rudder',
          srb2Negative: 'Y-Rudder',
          kartPositive: 'L Trigger',
          kartNegative: 'L Trigger',
          isTrigger: true,
        ),
        GamepadAxisInfo(
          id: 'rt',
          label: 'Right Trigger (RT)',
          value: rt.clamp(0.0, 1.0),
          srb2Positive: 'Z-Rudder',
          srb2Negative: 'Z-Rudder',
          kartPositive: 'R Trigger',
          kartNegative: 'R Trigger',
          isTrigger: true,
        ),
      ];

  /// Декодирует HID-репорт Nintendo Switch (`0x30` полный или `0x3F` компактный Bluetooth).
  /// [stickCenters] — опциональный список из 4 центров `[lx, ly, rx, ry]` (по умолчанию 2048).
  /// Возвращает `(buttons, hat, axes)` или `null`, если формат отчёта неизвестен.
  static ({Set<int> buttons, String? hat, List<GamepadAxisInfo> axes})? parseNintendoSwitchReport(
    Uint8List report, {
    List<int>? stickCenters,
  }) {
    if (report.length < 12) return null;
    final id = report[0];
    final btns = <int>{};
    String? hat;
    double lx = 0, ly = 0, rx = 0, ry = 0;

    if (id == 0x30) {
      final b3 = report[3];
      final b4 = report[4];
      final b5 = report[5];
      if ((b3 & 0x04) != 0) btns.add(1); // B (South)
      if ((b3 & 0x08) != 0) btns.add(2); // A (East)
      if ((b3 & 0x01) != 0) btns.add(3); // Y (West)
      if ((b3 & 0x02) != 0) btns.add(4); // X (North)
      if ((b5 & 0x40) != 0) btns.add(5); // L
      if ((b3 & 0x40) != 0) btns.add(6); // R
      if ((b4 & 0x01) != 0) btns.add(7); // Minus
      if ((b4 & 0x02) != 0) btns.add(8); // Plus
      if ((b4 & 0x08) != 0) btns.add(9); // LS
      if ((b4 & 0x04) != 0) btns.add(10); // RS
      if ((b5 & 0x80) != 0) btns.add(11); // ZL
      if ((b3 & 0x80) != 0) btns.add(12); // ZR
      if ((b4 & 0x10) != 0) btns.add(13); // Home
      if ((b4 & 0x20) != 0) btns.add(14); // Capture

      if ((b5 & 0x02) != 0) {
        hat = 'hatup';
      } else if ((b5 & 0x01) != 0) {
        hat = 'hatdown';
      } else if ((b5 & 0x08) != 0) {
        hat = 'hatleft';
      } else if ((b5 & 0x04) != 0) {
        hat = 'hatright';
      }

      final rawLx = report[6] | ((report[7] & 0x0F) << 8);
      final rawLy = (report[7] >> 4) | (report[8] << 4);
      final rawRx = report[9] | ((report[10] & 0x0F) << 8);
      final rawRy = (report[10] >> 4) | (report[11] << 4);

      if (stickCenters != null && stickCenters.length == 4) {
        if (stickCenters[0] == 0 && (rawLx - 2048).abs() < 350) stickCenters[0] = rawLx;
        if (stickCenters[1] == 0 && (rawLy - 2048).abs() < 350) stickCenters[1] = rawLy;
        if (stickCenters[2] == 0 && (rawRx - 2048).abs() < 350) stickCenters[2] = rawRx;
        if (stickCenters[3] == 0 && (rawRy - 2048).abs() < 350) stickCenters[3] = rawRy;
      }
      final cLx = (stickCenters != null && stickCenters[0] > 0) ? stickCenters[0] : 2048;
      final cLy = (stickCenters != null && stickCenters[1] > 0) ? stickCenters[1] : 2048;
      final cRx = (stickCenters != null && stickCenters[2] > 0) ? stickCenters[2] : 2048;
      final cRy = (stickCenters != null && stickCenters[3] > 0) ? stickCenters[3] : 2048;

      lx = ((rawLx - cLx) / 1400.0).clamp(-1.0, 1.0);
      ly = -((rawLy - cLy) / 1400.0).clamp(-1.0, 1.0);
      rx = ((rawRx - cRx) / 1400.0).clamp(-1.0, 1.0);
      ry = -((rawRy - cRy) / 1400.0).clamp(-1.0, 1.0);
    } else if (id == 0x3F) {
      final b1 = report[1];
      final b2 = report[2];
      if ((b1 & 0x01) != 0) btns.add(1); // B
      if ((b1 & 0x02) != 0) btns.add(2); // A
      if ((b1 & 0x04) != 0) btns.add(3); // Y
      if ((b1 & 0x08) != 0) btns.add(4); // X
      if ((b1 & 0x10) != 0) btns.add(5); // L
      if ((b1 & 0x20) != 0) btns.add(6); // R
      if ((b2 & 0x01) != 0) btns.add(7); // Minus
      if ((b2 & 0x02) != 0) btns.add(8); // Plus
      if ((b2 & 0x04) != 0) btns.add(9); // LS
      if ((b2 & 0x08) != 0) btns.add(10); // RS
      if ((b1 & 0x40) != 0) btns.add(11); // ZL
      if ((b1 & 0x80) != 0) btns.add(12); // ZR
      if ((b2 & 0x10) != 0) btns.add(13); // Home
      if ((b2 & 0x20) != 0) btns.add(14); // Capture

      hat = _hatFrom07(report[3]);
      double u16(int lo, int hi) => (((lo | (hi << 8)) - 32767.5) / 32767.5).clamp(-1.0, 1.0);
      lx = u16(report[4], report[5]);
      ly = u16(report[6], report[7]);
      rx = u16(report[8], report[9]);
      ry = u16(report[10], report[11]);
    } else {
      return null;
    }

    return (
      buttons: btns,
      hat: hat,
      axes: standardSdlAxes(
        lx: lx,
        ly: ly,
        rx: rx,
        ry: ry,
        lt: btns.contains(11) ? 1.0 : 0.0,
        rt: btns.contains(12) ? 1.0 : 0.0,
      ),
    );
  }

  static String? _hatFrom07(int dir) => switch (dir) {
        0 || 1 || 7 => 'hatup',
        2 || 3 => 'hatright',
        4 || 5 => 'hatdown',
        6 => 'hatleft',
        _ => null,
      };

  /// Возвращает понятную подсказку к названию оси SRB2/Kart для пользователя.
  static String? axisHint(String axisName) => switch (axisName) {
        'X-Axis' || 'X-Axis-' => 'Left Stick X',
        'Y-Axis' || 'Y-Axis-' => 'Left Stick Y',
        'Z-Axis' || 'Z-Axis-' => 'Right Stick X',
        'X-Rudder' || 'X-Rudder-' => 'Right Stick Y',
        'Y-Rudder' || 'Y-Rudder-' => 'Left Trigger (LT)',
        'Z-Rudder' || 'Z-Rudder-' => 'Right Trigger (RT)',
        _ => null,
      };

  /// Возвращает SDL-имя направления стика/триггера для `setcontrol` (DRRR / BlanKart).
  static String srb2StickBind(String axisId, double value) => switch (axisId) {
        'lx' => value < 0 ? 'L-STICK LEFT' : 'L-STICK RIGHT',
        'ly' => value < 0 ? 'L-STICK UP' : 'L-STICK DOWN',
        'rx' => value < 0 ? 'R-STICK LEFT' : 'R-STICK RIGHT',
        'ry' => value < 0 ? 'R-STICK UP' : 'R-STICK DOWN',
        'lt' => 'L TRIGGER',
        'rt' => 'R TRIGGER',
        _ => '',
      };

  /// Определяет отклонённое направление стика или нажатый триггер для `setcontrol`.
  static String? detectStickBind(
    GamepadSnapshot current,
    Map<String, double> baseline, {
    double threshold = 0.6,
  }) {
    GamepadAxisInfo? best;
    var bestDelta = 0.0;
    for (final a in current.axes) {
      final base = baseline[a.id] ?? 0.0;
      final diff = (a.value - base).abs();
      if (diff > bestDelta && diff >= threshold) {
        bestDelta = diff;
        best = a;
      }
    }
    if (best == null) return null;
    final bind = srb2StickBind(best.id, best.value);
    return bind.isEmpty ? null : bind;
  }

  /// Находит самую сильно отклонившуюся ось относительно [baseline].
  /// Всегда возвращает основное (не инвертированное от направления) имя оси:
  /// `Left X -> X-Axis`, `Left Y -> Y-Axis`, `Right X -> Z-Axis`, `Right Y -> X-Rudder-`.
  static (GamepadAxisInfo, bool)? detectMovedAxis(
    GamepadSnapshot current,
    Map<String, double> baseline, {
    double threshold = 0.45,
  }) {
    GamepadAxisInfo? best;
    var bestDelta = 0.0;
    for (final a in current.axes) {
      final base = baseline[a.id] ?? 0.0;
      final absDiff = (a.value - base).abs();
      if (absDiff > bestDelta && absDiff >= threshold) {
        bestDelta = absDiff;
        best = a;
      }
    }
    if (best == null) return null;
    return (best, false);
  }
}

/// Абстрактный источник живого опроса геймпадов.
abstract class GamepadBackend {
  List<GamepadSnapshot> poll();
  void dispose();
}

GamepadBackend? _createPlatformBackend() {
  if (Platform.isWindows) return _WindowsGamepadBackend();
  if (Platform.isLinux) return _LinuxGamepadBackend();
  return null;
}

void _gamepadPollIsolateEntry(List<Object?> args) {
  final replyPort = args[0] as SendPort;
  final intervalMs = args[1] as int;
  final cmdPort = ReceivePort();
  replyPort.send(cmdPort.sendPort);

  final backend = _createPlatformBackend();
  List<GamepadSnapshot>? lastSent;
  var stopped = false;

  void step() {
    if (stopped || backend == null) return;
    try {
      final next = backend.poll();
      if (lastSent == null || !GamepadService.snapshotsEqual(lastSent!, next)) {
        lastSent = next;
        replyPort.send(next);
      }
    } catch (_) {}
  }

  step();
  final timer = Timer.periodic(Duration(milliseconds: intervalMs), (_) => step());

  cmdPort.listen((msg) {
    if (msg == 'stop') {
      stopped = true;
      timer.cancel();
      backend?.dispose();
      cmdPort.close();
    }
  });
}

/// Сервис живого опроса геймпадов без внешних плагинов (XInput + Direct HID + WinMM на Windows,
/// `/dev/input/js*` на Linux). Периодический опрос выполняется в фоновом [Isolate], не тормозя UI.
class GamepadService {
  GamepadBackend? _backend;
  ReceivePort? _rxPort;
  SendPort? _workerCmd;
  Isolate? _workerIso;
  int _pollGen = 0;
  bool _pollingActive = false;
  final _controller = StreamController<List<GamepadSnapshot>>.broadcast();

  Stream<List<GamepadSnapshot>> get stream => _controller.stream;
  List<GamepadSnapshot> latest = const [];

  GamepadService();

  /// Сравнивает два снимка состояний с допуском [axisEpsilon] по осям,
  /// чтобы не перерисовывать UI на холостом ходу.
  static bool snapshotsEqual(
    List<GamepadSnapshot> a,
    List<GamepadSnapshot> b, {
    double axisEpsilon = 0.004,
  }) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final da = a[i];
      final db = b[i];
      if (da.deviceIndex != db.deviceIndex ||
          da.name != db.name ||
          da.isXInput != db.isXInput ||
          da.detectedLayout != db.detectedLayout ||
          da.vendorId != db.vendorId ||
          da.productId != db.productId ||
          da.hat != db.hat) {
        return false;
      }
      if (da.pressedButtons.length != db.pressedButtons.length ||
          !da.pressedButtons.containsAll(db.pressedButtons)) {
        return false;
      }
      if (da.axes.length != db.axes.length) return false;
      for (var j = 0; j < da.axes.length; j++) {
        if (da.axes[j].id != db.axes[j].id ||
            (da.axes[j].value - db.axes[j].value).abs() > axisEpsilon) {
          return false;
        }
      }
    }
    return true;
  }

  /// Единоразовый опрос подключённых контроллеров.
  List<GamepadSnapshot> pollOnce() {
    if (_pollingActive) return latest;
    final b = _backend ??= _createPlatformBackend();
    if (b == null) return const [];
    try {
      latest = b.poll();
    } catch (_) {
      latest = const [];
    }
    if (!_controller.isClosed) {
      _controller.add(latest);
    }
    return latest;
  }

  /// Запускает периодический опрос (~60 Гц) в отдельном [Isolate].
  void startPolling({Duration interval = const Duration(milliseconds: 16)}) {
    stopPolling();
    if (!Platform.isWindows && !Platform.isLinux) return;
    // Освобождаем main-thread backend, чтобы HID-дескрипторами владел только worker-изолят.
    _backend?.dispose();
    _backend = null;

    _pollingActive = true;
    final gen = ++_pollGen;
    final rx = ReceivePort();
    _rxPort = rx;

    rx.listen((msg) {
      if (msg is SendPort) {
        if (gen != _pollGen || _controller.isClosed) {
          msg.send('stop');
        } else {
          _workerCmd = msg;
        }
        return;
      }
      if (msg is List<GamepadSnapshot> && gen == _pollGen && !_controller.isClosed) {
        latest = msg;
        _controller.add(msg);
      }
    });

    Isolate.spawn(_gamepadPollIsolateEntry, [rx.sendPort, interval.inMilliseconds]).then<void>(
      (iso) {
        if (gen != _pollGen || _controller.isClosed) {
          _workerCmd?.send('stop');
          iso.kill(priority: Isolate.immediate);
        } else {
          _workerIso = iso;
        }
      },
      onError: (_) {},
    );
  }

  void stopPolling() {
    _pollingActive = false;
    _pollGen++;
    if (_workerCmd != null) {
      _workerCmd!.send('stop');
      _workerCmd = null;
    } else {
      _workerIso?.kill(priority: Isolate.immediate);
    }
    _workerIso = null;
    _rxPort?.close();
    _rxPort = null;
  }

  void dispose() {
    stopPolling();
    _backend?.dispose();
    _backend = null;
    _controller.close();
  }
}

// ==================== WINDOWS (XInput + WinMM) ====================

final class _XInputGamepad extends Struct {
  @Uint16()
  external int wButtons;
  @Uint8()
  external int bLeftTrigger;
  @Uint8()
  external int bRightTrigger;
  @Int16()
  external int sThumbLX;
  @Int16()
  external int sThumbLY;
  @Int16()
  external int sThumbRX;
  @Int16()
  external int sThumbRY;
}

final class _XInputState extends Struct {
  @Uint32()
  external int dwPacketNumber;
  external _XInputGamepad gamepad;
}

final class _JoyInfoEx extends Struct {
  @Uint32()
  external int dwSize;
  @Uint32()
  external int dwFlags;
  @Uint32()
  external int dwXpos;
  @Uint32()
  external int dwYpos;
  @Uint32()
  external int dwZpos;
  @Uint32()
  external int dwRpos;
  @Uint32()
  external int dwUpos;
  @Uint32()
  external int dwVpos;
  @Uint32()
  external int dwButtons;
  @Uint32()
  external int dwButtonNumber;
  @Uint32()
  external int dwPOV;
  @Uint32()
  external int dwReserved1;
  @Uint32()
  external int dwReserved2;
}

final class _RawInputDeviceList extends Struct {
  @IntPtr()
  external int hDevice;
  @Uint32()
  external int dwType;
}

final class _RidDeviceInfoHid extends Struct {
  @Uint32()
  external int dwVendorId;
  @Uint32()
  external int dwProductId;
  @Uint32()
  external int dwVersionNumber;
  @Uint16()
  external int usUsagePage;
  @Uint16()
  external int usUsage;
}

final class _RidDeviceInfo extends Struct {
  @Uint32()
  external int cbSize;
  @Uint32()
  external int dwType;
  external _RidDeviceInfoHid hid;
  @Array(8)
  external Array<Uint8> reserved;
}

final class _Overlapped extends Struct {
  @UintPtr()
  external int internal;
  @UintPtr()
  external int internalHigh;
  @Uint32()
  external int offset;
  @Uint32()
  external int offsetHigh;
  @IntPtr()
  external int hEvent;
}

typedef _XInputGetStateN = Uint32 Function(Uint32 dwUserIndex, Pointer<_XInputState> pState);
typedef _XInputGetStateD = int Function(int dwUserIndex, Pointer<_XInputState> pState);
typedef _JoyGetPosExN = Uint32 Function(Uint32 uJoyID, Pointer<_JoyInfoEx> pji);
typedef _JoyGetPosExD = int Function(int uJoyID, Pointer<_JoyInfoEx> pji);
typedef _JoyGetNumDevsN = Uint32 Function();
typedef _JoyGetNumDevsD = int Function();
typedef _JoyGetDevCapsWN = Uint32 Function(IntPtr uJoyID, Pointer<Uint8> pjc, Uint32 cbjc);
typedef _JoyGetDevCapsWD = int Function(int uJoyID, Pointer<Uint8> pjc, int cbjc);
typedef _GetRawInputDeviceListN = Uint32 Function(
    Pointer<_RawInputDeviceList> pRawInputDeviceList, Pointer<Uint32> puiNumDevices, Uint32 cbSize);
typedef _GetRawInputDeviceListD = int Function(
    Pointer<_RawInputDeviceList> pRawInputDeviceList, Pointer<Uint32> puiNumDevices, int cbSize);
typedef _GetRawInputDeviceInfoWN = Uint32 Function(
    IntPtr hDevice, Uint32 uiCommand, Pointer<Void> pData, Pointer<Uint32> pcbSize);
typedef _GetRawInputDeviceInfoWD = int Function(
    int hDevice, int uiCommand, Pointer<Void> pData, Pointer<Uint32> pcbSize);

typedef _CreateFileWN = IntPtr Function(Pointer<Utf16> lpFileName, Uint32 dwDesiredAccess, Uint32 dwShareMode,
    Pointer<Void> lpSecurityAttributes, Uint32 dwCreationDisposition, Uint32 dwFlagsAndAttributes, IntPtr hTemplateFile);
typedef _CreateFileWD = int Function(Pointer<Utf16> lpFileName, int dwDesiredAccess, int dwShareMode,
    Pointer<Void> lpSecurityAttributes, int dwCreationDisposition, int dwFlagsAndAttributes, int hTemplateFile);
typedef _ReadWriteFileN = Int32 Function(IntPtr hFile, Pointer<Uint8> lpBuffer, Uint32 nNumberOfBytes,
    Pointer<Uint32> lpNumberOfBytesTransferred, Pointer<_Overlapped> lpOverlapped);
typedef _ReadWriteFileD = int Function(int hFile, Pointer<Uint8> lpBuffer, int nNumberOfBytes,
    Pointer<Uint32> lpNumberOfBytesTransferred, Pointer<_Overlapped> lpOverlapped);
typedef _CreateEventWN = IntPtr Function(
    Pointer<Void> lpEventAttributes, Int32 bManualReset, Int32 bInitialState, Pointer<Utf16> lpName);
typedef _CreateEventWD = int Function(
    Pointer<Void> lpEventAttributes, int bManualReset, int bInitialState, Pointer<Utf16> lpName);
typedef _ResetEventN = Int32 Function(IntPtr hEvent);
typedef _ResetEventD = int Function(int hEvent);
typedef _GetOverlappedResultN = Int32 Function(
    IntPtr hFile, Pointer<_Overlapped> lpOverlapped, Pointer<Uint32> lpNumberOfBytesTransferred, Int32 bWait);
typedef _GetOverlappedResultD = int Function(
    int hFile, Pointer<_Overlapped> lpOverlapped, Pointer<Uint32> lpNumberOfBytesTransferred, int bWait);
typedef _WaitForSingleObjectN = Uint32 Function(IntPtr hHandle, Uint32 dwMilliseconds);
typedef _WaitForSingleObjectD = int Function(int hHandle, int dwMilliseconds);
typedef _CancelIoExN = Int32 Function(IntPtr hFile, Pointer<_Overlapped> lpOverlapped);
typedef _CancelIoExD = int Function(int hFile, Pointer<_Overlapped> lpOverlapped);
typedef _CloseHandleN = Int32 Function(IntPtr hObject);
typedef _CloseHandleD = int Function(int hObject);
typedef _GetLastErrorN = Uint32 Function();
typedef _GetLastErrorD = int Function();

typedef _HidDGetPreparsedDataN = Uint8 Function(IntPtr hidDeviceObject, Pointer<IntPtr> preparsedData);
typedef _HidDGetPreparsedDataD = int Function(int hidDeviceObject, Pointer<IntPtr> preparsedData);
typedef _HidDFreePreparsedDataN = Uint8 Function(IntPtr preparsedData);
typedef _HidDFreePreparsedDataD = int Function(int preparsedData);
typedef _HidPGetCapsN = Int32 Function(IntPtr preparsedData, Pointer<Uint16> capabilities);
typedef _HidPGetCapsD = int Function(int preparsedData, Pointer<Uint16> capabilities);
typedef _HidPGetValueCapsN = Int32 Function(
    Int32 reportType, Pointer<Uint8> valueCaps, Pointer<Uint16> valueCapsLength, IntPtr preparsedData);
typedef _HidPGetValueCapsD = int Function(
    int reportType, Pointer<Uint8> valueCaps, Pointer<Uint16> valueCapsLength, int preparsedData);
typedef _HidPMaxUsageListLengthN = Uint32 Function(Int32 reportType, Uint16 usagePage, IntPtr preparsedData);
typedef _HidPMaxUsageListLengthD = int Function(int reportType, int usagePage, int preparsedData);
typedef _HidPGetUsagesN = Int32 Function(Int32 reportType, Uint16 usagePage, Uint16 linkCollection,
    Pointer<Uint16> usageList, Pointer<Uint32> usageLength, IntPtr preparsedData, Pointer<Uint8> report, Uint32 reportLength);
typedef _HidPGetUsagesD = int Function(int reportType, int usagePage, int linkCollection, Pointer<Uint16> usageList,
    Pointer<Uint32> usageLength, int preparsedData, Pointer<Uint8> report, int reportLength);
typedef _HidPGetUsageValueN = Int32 Function(Int32 reportType, Uint16 usagePage, Uint16 linkCollection, Uint16 usage,
    Pointer<Uint32> usageValue, IntPtr preparsedData, Pointer<Uint8> report, Uint32 reportLength);
typedef _HidPGetUsageValueD = int Function(int reportType, int usagePage, int linkCollection, int usage,
    Pointer<Uint32> usageValue, int preparsedData, Pointer<Uint8> report, int reportLength);

class _HidDescriptor {
  final GamepadIdentity identity;
  final String devicePath;
  final bool isXInputMirror;

  const _HidDescriptor({
    required this.identity,
    required this.devicePath,
    required this.isXInputMirror,
  });
}

class _HidAxisCap {
  final int usage;
  final int bitSize;
  final int logicalMin;
  final int logicalMax;

  const _HidAxisCap({
    required this.usage,
    required this.bitSize,
    required this.logicalMin,
    required this.logicalMax,
  });

  double normalize(int rawUnsigned) {
    final maxVal = logicalMax > logicalMin ? logicalMax : ((1 << bitSize) - 1);
    if (maxVal <= logicalMin) return 0;
    final signed = logicalMin < 0 && rawUnsigned >= (1 << (bitSize - 1))
        ? rawUnsigned - (1 << bitSize)
        : rawUnsigned;
    return (((signed - logicalMin) / (maxVal - logicalMin)) * 2.0 - 1.0).clamp(-1.0, 1.0);
  }
}

class _WinHidApis {
  final _CreateFileWD createFile;
  final _ReadWriteFileD readFile;
  final _ReadWriteFileD writeFile;
  final _CreateEventWD createEvent;
  final _ResetEventD resetEvent;
  final _GetOverlappedResultD getOverlappedResult;
  final _WaitForSingleObjectD waitForSingleObject;
  final _CancelIoExD cancelIoEx;
  final _CloseHandleD closeHandle;
  final _GetLastErrorD getLastError;

  final _HidDGetPreparsedDataD getPreparsedData;
  final _HidDFreePreparsedDataD freePreparsedData;
  final _HidPGetCapsD getCaps;
  final _HidPGetValueCapsD getValueCaps;
  final _HidPMaxUsageListLengthD maxUsageListLength;
  final _HidPGetUsagesD getUsages;
  final _HidPGetUsageValueD getUsageValue;

  const _WinHidApis({
    required this.createFile,
    required this.readFile,
    required this.writeFile,
    required this.createEvent,
    required this.resetEvent,
    required this.getOverlappedResult,
    required this.waitForSingleObject,
    required this.cancelIoEx,
    required this.closeHandle,
    required this.getLastError,
    required this.getPreparsedData,
    required this.freePreparsedData,
    required this.getCaps,
    required this.getValueCaps,
    required this.maxUsageListLength,
    required this.getUsages,
    required this.getUsageValue,
  });

  static _WinHidApis? tryLoad() {
    try {
      final k32 = DynamicLibrary.open('kernel32.dll');
      final hid = DynamicLibrary.open('hid.dll');
      return _WinHidApis(
        createFile: k32.lookupFunction<_CreateFileWN, _CreateFileWD>('CreateFileW'),
        readFile: k32.lookupFunction<_ReadWriteFileN, _ReadWriteFileD>('ReadFile'),
        writeFile: k32.lookupFunction<_ReadWriteFileN, _ReadWriteFileD>('WriteFile'),
        createEvent: k32.lookupFunction<_CreateEventWN, _CreateEventWD>('CreateEventW'),
        resetEvent: k32.lookupFunction<_ResetEventN, _ResetEventD>('ResetEvent'),
        getOverlappedResult: k32.lookupFunction<_GetOverlappedResultN, _GetOverlappedResultD>('GetOverlappedResult'),
        waitForSingleObject: k32.lookupFunction<_WaitForSingleObjectN, _WaitForSingleObjectD>('WaitForSingleObject'),
        cancelIoEx: k32.lookupFunction<_CancelIoExN, _CancelIoExD>('CancelIoEx'),
        closeHandle: k32.lookupFunction<_CloseHandleN, _CloseHandleD>('CloseHandle'),
        getLastError: k32.lookupFunction<_GetLastErrorN, _GetLastErrorD>('GetLastError'),
        getPreparsedData: hid.lookupFunction<_HidDGetPreparsedDataN, _HidDGetPreparsedDataD>('HidD_GetPreparsedData'),
        freePreparsedData: hid.lookupFunction<_HidDFreePreparsedDataN, _HidDFreePreparsedDataD>('HidD_FreePreparsedData'),
        getCaps: hid.lookupFunction<_HidPGetCapsN, _HidPGetCapsD>('HidP_GetCaps'),
        getValueCaps: hid.lookupFunction<_HidPGetValueCapsN, _HidPGetValueCapsD>('HidP_GetValueCaps'),
        maxUsageListLength: hid.lookupFunction<_HidPMaxUsageListLengthN, _HidPMaxUsageListLengthD>('HidP_MaxUsageListLength'),
        getUsages: hid.lookupFunction<_HidPGetUsagesN, _HidPGetUsagesD>('HidP_GetUsages'),
        getUsageValue: hid.lookupFunction<_HidPGetUsageValueN, _HidPGetUsageValueD>('HidP_GetUsageValue'),
      );
    } catch (_) {
      return null;
    }
  }
}

class _HidGamepadDevice {
  static const _genericRead = 0x80000000;
  static const _genericWrite = 0x40000000;
  static const _fileShareRw = 0x00000003;
  static const _openExisting = 3;
  static const _fileFlagOverlapped = 0x40000000;
  static const _errorIoPending = 997;
  static const _errorIoIncomplete = 996;
  static const _hidpStatusSuccess = 0x00110000;

  final _WinHidApis api;
  final GamepadIdentity identity;
  final int _handle;
  final int _readEvent;
  final int _preparsedData;
  final int _inReportLen;
  final Pointer<Uint8> _readBuf;
  final Pointer<_Overlapped> _readOv;
  final Pointer<Uint32> _bytesPtr = calloc<Uint32>();
  final Pointer<Uint16> _usageBuf;
  final Pointer<Uint32> _usageLenPtr = calloc<Uint32>();
  final Pointer<Uint32> _valPtr = calloc<Uint32>();
  final int _maxUsages;
  final Map<int, _HidAxisCap> _axisCaps;
  final List<int> _nintendoCenters = [0, 0, 0, 0];

  bool _ioPending = false;
  bool hasPackets = false;
  Set<int> pressedButtons = const {};
  String? hat;
  List<GamepadAxisInfo> axes = GamepadNames.standardSdlAxes(lx: 0, ly: 0, rx: 0, ry: 0, lt: 0, rt: 0);

  _HidGamepadDevice._(
    this.api,
    this.identity,
    this._handle,
    this._readEvent,
    this._preparsedData,
    this._inReportLen,
    this._maxUsages,
    this._axisCaps,
  )   : _readBuf = calloc<Uint8>(_inReportLen),
        _readOv = calloc<_Overlapped>(),
        _usageBuf = calloc<Uint16>(_maxUsages);

  static _HidGamepadDevice? open(_WinHidApis api, _HidDescriptor desc) {
    final pathPtr = desc.devicePath.toNativeUtf16();
    int h = -1;
    try {
      h = api.createFile(pathPtr, _genericRead | _genericWrite, _fileShareRw, nullptr, _openExisting, _fileFlagOverlapped, 0);
      if (h == -1) {
        h = api.createFile(pathPtr, _genericRead, _fileShareRw, nullptr, _openExisting, _fileFlagOverlapped, 0);
      }
    } finally {
      calloc.free(pathPtr);
    }
    if (h == -1) return null;

    final ppPtr = calloc<IntPtr>();
    final capsBuf = calloc<Uint16>(32);
    int preparsed = 0;
    int readEv = 0;
    try {
      if (api.getPreparsedData(h, ppPtr) == 0 || ppPtr.value == 0) {
        api.closeHandle(h);
        return null;
      }
      preparsed = ppPtr.value;
      if (api.getCaps(preparsed, capsBuf) != _hidpStatusSuccess) {
        api.freePreparsedData(preparsed);
        api.closeHandle(h);
        return null;
      }
      final inLen = math.max(64, capsBuf[2]);
      final outLen = capsBuf[3];
      final valCount = capsBuf[24];

      final axisCaps = <int, _HidAxisCap>{};
      if (valCount > 0 && valCount <= 64) {
        final vcLenPtr = calloc<Uint16>()..value = valCount;
        final vcBuf = calloc<Uint8>(72 * valCount);
        try {
          if (api.getValueCaps(0, vcBuf, vcLenPtr, preparsed) == _hidpStatusSuccess) {
            final bd = ByteData.sublistView(vcBuf.asTypedList(72 * vcLenPtr.value));
            for (var i = 0; i < vcLenPtr.value; i++) {
              final o = i * 72;
              final page = bd.getUint16(o + 0, Endian.little);
              if (page != 0x01) continue;
              final bits = bd.getUint16(o + 18, Endian.little);
              final lmin = bd.getInt32(o + 40, Endian.little);
              final lmax = bd.getInt32(o + 44, Endian.little);
              final usage = bd.getUint16(o + 56, Endian.little);
              axisCaps[usage] = _HidAxisCap(usage: usage, bitSize: bits, logicalMin: lmin, logicalMax: lmax);
            }
          }
        } finally {
          calloc.free(vcLenPtr);
          calloc.free(vcBuf);
        }
      }

      final maxUsages = math.max(32, api.maxUsageListLength(0, 0x09, preparsed));
      readEv = api.createEvent(nullptr, 1, 0, nullptr);
      if (readEv == 0) {
        api.freePreparsedData(preparsed);
        api.closeHandle(h);
        return null;
      }

      final dev = _HidGamepadDevice._(
        api,
        desc.identity,
        h,
        readEv,
        preparsed,
        inLen,
        maxUsages,
        axisCaps,
      );

      if (desc.identity.vendorId == 0x057E) {
        dev._sendNintendoInit(outLen > 0 ? outLen : 49);
      }
      dev._queueRead();
      return dev;
    } catch (_) {
      if (readEv != 0) api.closeHandle(readEv);
      if (preparsed != 0) api.freePreparsedData(preparsed);
      api.closeHandle(h);
      return null;
    } finally {
      calloc.free(ppPtr);
      calloc.free(capsBuf);
    }
  }

  void _sendOverlapped(List<int> bytes) {
    final ev = api.createEvent(nullptr, 1, 0, nullptr);
    if (ev == 0) return;
    final ov = calloc<_Overlapped>();
    final outBuf = calloc<Uint8>(bytes.length);
    final written = calloc<Uint32>();
    try {
      for (var i = 0; i < bytes.length; i++) {
        outBuf[i] = bytes[i];
      }
      ov.ref.hEvent = ev;
      final ok = api.writeFile(_handle, outBuf, bytes.length, written, ov);
      if (ok == 0 && api.getLastError() == _errorIoPending) {
        final w = api.waitForSingleObject(ev, 20);
        if (w != 0) api.cancelIoEx(_handle, ov);
      }
    } finally {
      api.closeHandle(ev);
      calloc.free(ov);
      calloc.free(outBuf);
      calloc.free(written);
    }
  }

  void _sendNintendoInit(int outLen) {
    // 1. USB handshake & enable HID (безвредно отклоняется по Bluetooth).
    _sendOverlapped(const [0x80, 0x02]);
    _sendOverlapped(const [0x80, 0x04]);
    // 2. Subcommand 0x03 -> 0x30: включить стандартный 60 Гц полный отчёт.
    final len = math.max(49, outLen);
    final cmd = List<int>.filled(len, 0);
    cmd[0] = 0x01;
    cmd[3] = 0x01;
    cmd[4] = 0x40;
    cmd[5] = 0x40;
    cmd[7] = 0x01;
    cmd[8] = 0x40;
    cmd[9] = 0x40;
    cmd[10] = 0x03;
    cmd[11] = 0x30;
    _sendOverlapped(cmd);
  }

  void drain() {
    for (var step = 0; step < 16; step++) {
      if (_ioPending) {
        final ok = api.getOverlappedResult(_handle, _readOv, _bytesPtr, 0);
        if (ok == 0) {
          final err = api.getLastError();
          if (err == _errorIoIncomplete || err == _errorIoPending) return;
          _ioPending = false;
          return;
        }
        _ioPending = false;
        _parseReport(_bytesPtr.value);
      }
      if (!_queueRead()) return;
    }
  }

  bool _queueRead() {
    api.resetEvent(_readEvent);
    _readOv.ref
      ..internal = 0
      ..internalHigh = 0
      ..offset = 0
      ..offsetHigh = 0
      ..hEvent = _readEvent;
    _bytesPtr.value = 0;
    final ok = api.readFile(_handle, _readBuf, _inReportLen, _bytesPtr, _readOv);
    if (ok != 0) {
      _parseReport(_bytesPtr.value);
      return true;
    }
    if (api.getLastError() == _errorIoPending) {
      _ioPending = true;
    }
    return false;
  }

  void _parseReport(int len) {
    if (len <= 0) return;
    final bytes = Uint8List.fromList(_readBuf.asTypedList(math.min(len, _inReportLen)));

    if (identity.vendorId == 0x057E) {
      final parsed = GamepadNames.parseNintendoSwitchReport(bytes, stickCenters: _nintendoCenters);
      if (parsed != null) {
        hasPackets = true;
        pressedButtons = parsed.buttons;
        hat = parsed.hat;
        axes = parsed.axes;
        return;
      }
    }

    // Стандартный HID-разбор через HidP_GetUsages / HidP_GetUsageValue.
    _usageLenPtr.value = _maxUsages;
    final btns = <int>{};
    if (api.getUsages(0, 0x09, 0, _usageBuf, _usageLenPtr, _preparsedData, _readBuf, bytes.length) ==
        _hidpStatusSuccess) {
      hasPackets = true;
      for (var i = 0; i < _usageLenPtr.value; i++) {
        final u = _usageBuf[i];
        if (u > 0) btns.add(u);
      }
    }

    String? parsedHat;
    final hatCap = _axisCaps[0x39];
    if (hatCap != null &&
        api.getUsageValue(0, 0x01, 0, 0x39, _valPtr, _preparsedData, _readBuf, bytes.length) == _hidpStatusSuccess) {
      final rawHat = _valPtr.value;
      if (rawHat >= hatCap.logicalMin && rawHat <= hatCap.logicalMax) {
        parsedHat = GamepadNames._hatFrom07(rawHat - hatCap.logicalMin);
      }
    }

    double readAxis(int usage) {
      final cap = _axisCaps[usage];
      if (cap == null) return 0;
      if (api.getUsageValue(0, 0x01, 0, usage, _valPtr, _preparsedData, _readBuf, bytes.length) !=
          _hidpStatusSuccess) {
        return 0;
      }
      return cap.normalize(_valPtr.value);
    }

    pressedButtons = btns;
    hat = parsedHat;
    axes = GamepadNames.standardSdlAxes(
      lx: readAxis(0x30),
      ly: readAxis(0x31),
      rx: readAxis(0x32),
      ry: readAxis(0x35),
      lt: ((readAxis(0x33) + 1.0) / 2.0).clamp(0.0, 1.0),
      rt: ((readAxis(0x34) + 1.0) / 2.0).clamp(0.0, 1.0),
    );
  }

  void dispose() {
    if (_ioPending) api.cancelIoEx(_handle, _readOv);
    api.closeHandle(_readEvent);
    api.freePreparsedData(_preparsedData);
    api.closeHandle(_handle);
    calloc.free(_readBuf);
    calloc.free(_readOv);
    calloc.free(_bytesPtr);
    calloc.free(_usageBuf);
    calloc.free(_usageLenPtr);
    calloc.free(_valPtr);
  }
}

class _WindowsGamepadBackend implements GamepadBackend {
  static const _ridiDeviceName = 0x20000007;
  static const _ridiDeviceInfo = 0x2000000b;
  static const _rimTypeHid = 2;

  _XInputGetStateD? _xinputGetState;
  _JoyGetPosExD? _joyGetPosEx;
  _JoyGetNumDevsD? _joyGetNumDevs;
  _JoyGetDevCapsWD? _joyGetDevCaps;
  _GetRawInputDeviceListD? _getRawList;
  _GetRawInputDeviceInfoWD? _getRawInfo;
  _WinHidApis? _hidApis;

  final Pointer<_XInputState> _xState = calloc<_XInputState>();
  final Pointer<_JoyInfoEx> _joyInfo = calloc<_JoyInfoEx>();
  final Pointer<Uint8> _joyCapsBuf = calloc<Uint8>(728);
  bool _initialized = false;
  DateTime _lastHidScan = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastWinmmScan = DateTime.fromMillisecondsSinceEpoch(0);
  List<_HidDescriptor> _hidDescriptors = const [];
  List<({int id, int? mid, int? pid})> _winmmSlots = const [];
  final Map<String, _HidGamepadDevice> _hidDevices = {};

  void _init() {
    if (_initialized) return;
    _initialized = true;

    for (final dll in const ['xinput1_4.dll', 'xinput1_3.dll', 'xinput9_1_0.dll']) {
      try {
        final lib = DynamicLibrary.open(dll);
        _xinputGetState = lib.lookupFunction<_XInputGetStateN, _XInputGetStateD>('XInputGetState');
        break;
      } catch (_) {}
    }

    try {
      final winmm = DynamicLibrary.open('winmm.dll');
      _joyGetPosEx = winmm.lookupFunction<_JoyGetPosExN, _JoyGetPosExD>('joyGetPosEx');
      _joyGetNumDevs = winmm.lookupFunction<_JoyGetNumDevsN, _JoyGetNumDevsD>('joyGetNumDevs');
      _joyGetDevCaps = winmm.lookupFunction<_JoyGetDevCapsWN, _JoyGetDevCapsWD>('joyGetDevCapsW');
    } catch (_) {}

    try {
      final user32 = DynamicLibrary.open('user32.dll');
      _getRawList = user32.lookupFunction<_GetRawInputDeviceListN, _GetRawInputDeviceListD>('GetRawInputDeviceList');
      _getRawInfo = user32.lookupFunction<_GetRawInputDeviceInfoWN, _GetRawInputDeviceInfoWD>('GetRawInputDeviceInfoW');
    } catch (_) {}

    _hidApis = _WinHidApis.tryLoad();
  }

  List<_HidDescriptor> _scanHidDescriptors() {
    final now = DateTime.now();
    if (now.difference(_lastHidScan) < const Duration(seconds: 2)) {
      return _hidDescriptors;
    }
    _lastHidScan = now;
    final getList = _getRawList;
    final getInfo = _getRawInfo;
    if (getList == null || getInfo == null) return const [];

    final countPtr = calloc<Uint32>();
    final infoPtr = calloc<_RidDeviceInfo>();
    final sizePtr = calloc<Uint32>();
    Pointer<_RawInputDeviceList>? listPtr;
    try {
      final elemSize = sizeOf<_RawInputDeviceList>();
      getList(nullptr, countPtr, elemSize);
      final count = countPtr.value;
      if (count == 0 || count > 256) {
        _hidDescriptors = const [];
        return _hidDescriptors;
      }
      listPtr = calloc<_RawInputDeviceList>(count);
      final readCount = getList(listPtr, countPtr, elemSize);
      if (readCount <= 0 || readCount > count) {
        _hidDescriptors = const [];
        return _hidDescriptors;
      }
      final found = <_HidDescriptor>[];
      final infoSize = sizeOf<_RidDeviceInfo>();
      for (var i = 0; i < readCount; i++) {
        final entry = (listPtr + i).ref;
        if (entry.dwType != _rimTypeHid) continue;
        infoPtr.ref.cbSize = infoSize;
        sizePtr.value = infoSize;
        final res = getInfo(entry.hDevice, _ridiDeviceInfo, infoPtr.cast(), sizePtr);
        if (res == 0xFFFFFFFF) continue;
        final hid = infoPtr.ref.hid;
        if (hid.usUsagePage != 1 || (hid.usUsage != 4 && hid.usUsage != 5)) continue;

        sizePtr.value = 0;
        getInfo(entry.hDevice, _ridiDeviceName, nullptr, sizePtr);
        final chars = sizePtr.value;
        var path = '';
        if (chars > 0 && chars < 2048) {
          final nameBuf = calloc<Uint16>(chars + 1);
          try {
            if (getInfo(entry.hDevice, _ridiDeviceName, nameBuf.cast(), sizePtr) != 0xFFFFFFFF) {
              path = nameBuf.cast<Utf16>().toDartString();
            }
          } finally {
            calloc.free(nameBuf);
          }
        }
        if (path.isEmpty) continue;
        found.add(_HidDescriptor(
          identity: GamepadCatalog.identify(
            vendorId: hid.dwVendorId,
            productId: hid.dwProductId,
          ),
          devicePath: path,
          isXInputMirror: path.toUpperCase().contains('&IG_'),
        ));
      }
      _hidDescriptors = found;
      return found;
    } catch (_) {
      return _hidDescriptors;
    } finally {
      calloc.free(countPtr);
      calloc.free(infoPtr);
      calloc.free(sizePtr);
      if (listPtr != null) calloc.free(listPtr);
    }
  }

  void _syncDirectHidDevices(List<_HidDescriptor> nonXinputHids) {
    final apis = _hidApis;
    if (apis == null) return;
    final activeKeys = <String>{};
    for (final d in nonXinputHids) {
      final key = d.devicePath.toUpperCase();
      activeKeys.add(key);
      if (!_hidDevices.containsKey(key)) {
        final opened = _HidGamepadDevice.open(apis, d);
        if (opened != null) _hidDevices[key] = opened;
      }
    }
    final stale = [
      for (final k in _hidDevices.keys)
        if (!activeKeys.contains(k)) k,
    ];
    for (final k in stale) {
      _hidDevices.remove(k)?.dispose();
    }
    for (final dev in _hidDevices.values) {
      dev.drain();
    }
  }

  static double _normThumb(int v) => (v < 0 ? v / 32768.0 : v / 32767.0).clamp(-1.0, 1.0);
  static double _normU16(int v) => ((v - 32767.5) / 32767.5).clamp(-1.0, 1.0);

  @override
  List<GamepadSnapshot> poll() {
    _init();
    final out = <GamepadSnapshot>[];
    final descriptors = _scanHidDescriptors();
    final xinputHids = [for (final d in descriptors) if (d.isXInputMirror) d.identity];
    final nonXinputHids = [for (final d in descriptors) if (!d.isXInputMirror) d];
    _syncDirectHidDevices(nonXinputHids);

    final coveredVidPids = <(int, int)>{};

    // 1. XInput (Xbox и совместимые).
    final xGet = _xinputGetState;
    if (xGet != null) {
      var xIdx = 0;
      for (var i = 0; i < 4; i++) {
        if (xGet(i, _xState) == 0) {
          final matchedHid = xIdx < xinputHids.length
              ? xinputHids[xIdx]
              : (xinputHids.isNotEmpty
                  ? xinputHids.first
                  : const GamepadIdentity(modelName: 'Xbox / XInput Controller', layout: GamepadLayout.xbox));
          xIdx++;
          if (matchedHid.vendorId != null && matchedHid.productId != null) {
            coveredVidPids.add((matchedHid.vendorId!, matchedHid.productId!));
          }
          final gp = _xState.ref.gamepad;
          final mask = gp.wButtons;
          final btns = <int>{};
          if ((mask & 0x1000) != 0) btns.add(1); // A
          if ((mask & 0x2000) != 0) btns.add(2); // B
          if ((mask & 0x4000) != 0) btns.add(3); // X
          if ((mask & 0x8000) != 0) btns.add(4); // Y
          if ((mask & 0x0100) != 0) btns.add(5); // LB
          if ((mask & 0x0200) != 0) btns.add(6); // RB
          if ((mask & 0x0020) != 0) btns.add(7); // Back
          if ((mask & 0x0010) != 0) btns.add(8); // Start
          if ((mask & 0x0040) != 0) btns.add(9); // LS
          if ((mask & 0x0080) != 0) btns.add(10); // RS
          if (gp.bLeftTrigger > 128) btns.add(11);
          if (gp.bRightTrigger > 128) btns.add(12);

          String? hat;
          if ((mask & 0x0001) != 0) {
            hat = 'hatup';
          } else if ((mask & 0x0002) != 0) {
            hat = 'hatdown';
          } else if ((mask & 0x0004) != 0) {
            hat = 'hatleft';
          } else if ((mask & 0x0008) != 0) {
            hat = 'hatright';
          }

          out.add(GamepadSnapshot(
            deviceIndex: out.length + 1,
            name: '${matchedHid.modelName} (#${out.length + 1})',
            isXInput: true,
            detectedLayout: matchedHid.layout,
            vendorId: matchedHid.vendorId,
            productId: matchedHid.productId,
            pressedButtons: btns,
            hat: hat,
            axes: GamepadNames.standardSdlAxes(
              lx: _normThumb(gp.sThumbLX),
              ly: -_normThumb(gp.sThumbLY),
              rx: _normThumb(gp.sThumbRX),
              ry: -_normThumb(gp.sThumbRY),
              lt: (gp.bLeftTrigger / 255.0).clamp(0.0, 1.0),
              rt: (gp.bRightTrigger / 255.0).clamp(0.0, 1.0),
            ),
          ));
        }
      }
    }

    // 2. Прямое чтение Nintendo Switch (0x057E) через hid.dll (Windows joy.cpl не отображает их нажатия).
    for (final hDev in _hidDevices.values) {
      if (hDev.identity.vendorId != 0x057E) continue;
      if (hDev.identity.vendorId != null && hDev.identity.productId != null) {
        coveredVidPids.add((hDev.identity.vendorId!, hDev.identity.productId!));
      }
      final idx = out.length + 1;
      out.add(GamepadSnapshot(
        deviceIndex: idx,
        name: '${hDev.identity.modelName} (#$idx)',
        isXInput: false,
        detectedLayout: hDev.identity.layout,
        vendorId: hDev.identity.vendorId,
        productId: hDev.identity.productId,
        pressedButtons: Set.of(hDev.pressedButtons),
        hat: hDev.hat,
        axes: hDev.axes,
      ));
    }

    // 3. WinMM (DirectInput / PlayStation / USB), только если есть не-XInput/не-Nintendo устройства,
    // и только по кэшированным раз в 3 сек слотам (чтобы не тормозить опрос пустых портов).
    final needWinmm = nonXinputHids.any((d) => d.identity.vendorId != 0x057E);
    if (needWinmm && _joyGetPosEx != null && _joyGetNumDevs != null) {
      final now = DateTime.now();
      if (now.difference(_lastWinmmScan) >= const Duration(seconds: 3)) {
        _lastWinmmScan = now;
        final scanned = <({int id, int? mid, int? pid})>[];
        final count = math.min(16, _joyGetNumDevs!());
        for (var id = 0; id < count; id++) {
          int? wMid;
          int? wPid;
          if (_joyGetDevCaps != null && _joyGetDevCaps!(id, _joyCapsBuf, 728) == 0) {
            final bd = ByteData.sublistView(_joyCapsBuf.asTypedList(728));
            wMid = bd.getUint16(0, Endian.little);
            wPid = bd.getUint16(2, Endian.little);
            if (coveredVidPids.contains((wMid, wPid))) continue;
          }
          _joyInfo.ref
            ..dwSize = sizeOf<_JoyInfoEx>()
            ..dwFlags = 0xFF;
          if (_joyGetPosEx!(id, _joyInfo) == 0) {
            scanned.add((id: id, mid: wMid, pid: wPid));
          }
        }
        _winmmSlots = scanned;
      }

      var dIdx = 0;
      for (final slot in _winmmSlots) {
        final id = slot.id;
        final wMid = slot.mid;
        final wPid = slot.pid;
        if (wMid != null && wPid != null && coveredVidPids.contains((wMid, wPid))) continue;
        _joyInfo.ref
          ..dwSize = sizeOf<_JoyInfoEx>()
          ..dwFlags = 0xFF;
        if (_joyGetPosEx!(id, _joyInfo) == 0) {
          final matchingDirect = (wMid != null && wPid != null)
              ? _hidDevices.values
                  .where((d) => d.identity.vendorId == wMid && d.identity.productId == wPid)
                  .firstOrNull
              : null;
          final matchedHid = matchingDirect?.identity ??
              (dIdx < nonXinputHids.length
                  ? nonXinputHids[dIdx].identity
                  : const GamepadIdentity(modelName: 'DirectInput / USB Gamepad', layout: GamepadLayout.generic));
          dIdx++;
          if (matchedHid.vendorId != null && matchedHid.productId != null) {
            coveredVidPids.add((matchedHid.vendorId!, matchedHid.productId!));
          }
          final info = _joyInfo.ref;
          final btns = <int>{};
          for (var b = 0; b < 32; b++) {
            if ((info.dwButtons & (1 << b)) != 0) btns.add(b + 1);
          }
          String? hat;
          final pov = info.dwPOV;
          if (pov != 0xFFFF && pov <= 36000) {
            if (pov < 4500 || pov >= 31500) {
              hat = 'hatup';
            } else if (pov < 13500) {
              hat = 'hatright';
            } else if (pov < 22500) {
              hat = 'hatdown';
            } else {
              hat = 'hatleft';
            }
          }
          // Если у устройства есть активный HID-канал, объединяем кнопки (на случай проблемного драйвера Windows).
          if (matchingDirect != null && matchingDirect.hasPackets) {
            btns.addAll(matchingDirect.pressedButtons);
            hat ??= matchingDirect.hat;
          }
          final idx = out.length + 1;
          out.add(GamepadSnapshot(
            deviceIndex: idx,
            name: '${matchedHid.modelName} (#$idx)',
            isXInput: false,
            detectedLayout: matchedHid.layout,
            vendorId: matchedHid.vendorId,
            productId: matchedHid.productId,
            pressedButtons: btns,
            hat: hat,
            axes: GamepadNames.standardSdlAxes(
              lx: _normU16(info.dwXpos),
              ly: _normU16(info.dwYpos),
              rx: _normU16(info.dwZpos),
              ry: _normU16(info.dwRpos),
              lt: ((_normU16(info.dwUpos) + 1.0) / 2.0).clamp(0.0, 1.0),
              rt: ((_normU16(info.dwVpos) + 1.0) / 2.0).clamp(0.0, 1.0),
            ),
          ));
        }
      }
    }

    // 4. Остальные прямые HID-контроллеры, которые не появились ни в XInput, ни в WinMM (напр. 3rd-party Switch).
    for (final hDev in _hidDevices.values) {
      final vid = hDev.identity.vendorId;
      final pid = hDev.identity.productId;
      if (vid == 0x057E || (vid != null && pid != null && coveredVidPids.contains((vid, pid)))) continue;
      final idx = out.length + 1;
      out.add(GamepadSnapshot(
        deviceIndex: idx,
        name: '${hDev.identity.modelName} (#$idx)',
        isXInput: false,
        detectedLayout: hDev.identity.layout,
        vendorId: vid,
        productId: pid,
        pressedButtons: Set.of(hDev.pressedButtons),
        hat: hDev.hat,
        axes: hDev.axes,
      ));
    }

    return out;
  }

  @override
  void dispose() {
    for (final d in _hidDevices.values) {
      d.dispose();
    }
    _hidDevices.clear();
    calloc.free(_xState);
    calloc.free(_joyInfo);
    calloc.free(_joyCapsBuf);
  }
}

// ==================== LINUX (/dev/input/js*) ====================

typedef _OpenN = Int32 Function(Pointer<Utf8> path, Int32 flags);
typedef _OpenD = int Function(Pointer<Utf8> path, int flags);
typedef _ReadN = IntPtr Function(Int32 fd, Pointer<Uint8> buf, IntPtr count);
typedef _ReadD = int Function(int fd, Pointer<Uint8> buf, int count);
typedef _CloseN = Int32 Function(Int32 fd);
typedef _CloseD = int Function(int fd);

class _LinuxJsDevice {
  final int index;
  int fd;
  final Map<int, double> rawAxes = {};
  final Set<int> buttons = {};

  _LinuxJsDevice(this.index, this.fd);
}

class _LinuxGamepadBackend implements GamepadBackend {
  static const _oRdonlyNonBlock = 0x800; // O_RDONLY | O_NONBLOCK on x86_64/arm64 Linux
  _OpenD? _open;
  _ReadD? _read;
  _CloseD? _close;
  bool _inited = false;
  final Map<int, _LinuxJsDevice> _devices = {};
  final Pointer<Uint8> _buf = calloc<Uint8>(8);

  void _init() {
    if (_inited) return;
    _inited = true;
    try {
      final libc = DynamicLibrary.open('libc.so.6');
      _open = libc.lookupFunction<_OpenN, _OpenD>('open');
      _read = libc.lookupFunction<_ReadN, _ReadD>('read');
      _close = libc.lookupFunction<_CloseN, _CloseD>('close');
    } catch (_) {}
  }

  @override
  List<GamepadSnapshot> poll() {
    _init();
    if (_open == null || _read == null || _close == null) return const [];

    for (var i = 0; i < 8; i++) {
      final path = '/dev/input/js$i';
      if (!_devices.containsKey(i)) {
        if (!File(path).existsSync()) continue;
        final cPath = path.toNativeUtf8();
        final fd = _open!(cPath, _oRdonlyNonBlock);
        calloc.free(cPath);
        if (fd >= 0) _devices[i] = _LinuxJsDevice(i, fd);
      }
      final dev = _devices[i];
      if (dev == null) continue;
      if (!File(path).existsSync()) {
        _close!(dev.fd);
        _devices.remove(i);
        continue;
      }
      for (var step = 0; step < 64; step++) {
        final n = _read!(dev.fd, _buf, 8);
        if (n != 8) break;
        final bd = ByteData.sublistView(_buf.asTypedList(8));
        final val = bd.getInt16(4, Endian.little);
        final type = bd.getUint8(6) & 0x7F;
        final num = bd.getUint8(7);
        if (type == 1) {
          if (val != 0) {
            dev.buttons.add(num + 1);
          } else {
            dev.buttons.remove(num + 1);
          }
        } else if (type == 2) {
          dev.rawAxes[num] = (val / 32767.0).clamp(-1.0, 1.0);
        }
      }
    }

    final out = <GamepadSnapshot>[];
    for (final dev in _devices.values) {
      double ax(int n) => dev.rawAxes[n] ?? 0.0;
      String? hat;
      if (ax(6) < -0.5) {
        hat = 'hatleft';
      } else if (ax(6) > 0.5) {
        hat = 'hatright';
      } else if (ax(7) < -0.5) {
        hat = 'hatup';
      } else if (ax(7) > 0.5) {
        hat = 'hatdown';
      }
      final sysBase = '/sys/class/input/js${dev.index}/device';
      String? rawName;
      int? vid;
      int? pid;
      try {
        final nf = File('$sysBase/name');
        if (nf.existsSync()) rawName = nf.readAsStringSync().trim();
        final vf = File('$sysBase/id/vendor');
        if (vf.existsSync()) vid = int.tryParse(vf.readAsStringSync().trim(), radix: 16);
        final pf = File('$sysBase/id/product');
        if (pf.existsSync()) pid = int.tryParse(pf.readAsStringSync().trim(), radix: 16);
      } catch (_) {}
      final identity = GamepadCatalog.identify(vendorId: vid, productId: pid, rawName: rawName);
      out.add(GamepadSnapshot(
        deviceIndex: dev.index + 1,
        name: '${identity.modelName} (#${dev.index + 1})',
        isXInput: false,
        detectedLayout: identity.layout,
        vendorId: identity.vendorId,
        productId: identity.productId,
        pressedButtons: Set.of(dev.buttons),
        hat: hat,
        axes: GamepadNames.standardSdlAxes(
          lx: ax(0),
          ly: ax(1),
          rx: ax(3),
          ry: ax(4),
          lt: ((ax(2) + 1) / 2).clamp(0.0, 1.0),
          rt: ((ax(5) + 1) / 2).clamp(0.0, 1.0),
        ),
      ));
    }
    return out;
  }

  @override
  void dispose() {
    for (final dev in _devices.values) {
      _close?.call(dev.fd);
    }
    _devices.clear();
    calloc.free(_buf);
  }
}
