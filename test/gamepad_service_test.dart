import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:srb2_autonomi_launcher/models/game.dart';
import 'package:srb2_autonomi_launcher/services/custom_games.dart';
import 'package:srb2_autonomi_launcher/services/gamepad_service.dart';
import 'package:srb2_autonomi_launcher/services/srb2_config.dart';
import 'package:srb2_autonomi_launcher/services/srb2_config_schema.dart';
import 'package:srb2_autonomi_launcher/ui/config_settings.dart';
import 'package:srb2_autonomi_launcher/ui/gamepad_tester_dialog.dart';

class _FakeGamepadService extends GamepadService {
  final _ctrl = StreamController<List<GamepadSnapshot>>.broadcast();
  List<GamepadSnapshot> _state;

  _FakeGamepadService(this._state);

  @override
  Stream<List<GamepadSnapshot>> get stream => _ctrl.stream;

  @override
  List<GamepadSnapshot> pollOnce() => _state;

  void push(List<GamepadSnapshot> next) {
    _state = next;
    _ctrl.add(next);
  }

  @override
  void startPolling({Duration interval = const Duration(milliseconds: 16)}) {}

  @override
  void stopPolling() {}

  @override
  void dispose() {
    _ctrl.close();
  }
}

void main() {
  group('GamepadNames & axis detection', () {
    test('maps button and hat names across games and players', () {
      expect(GamepadNames.friendlyButton(1, GamepadLayout.xbox), 'A');
      expect(GamepadNames.friendlyButton(1, GamepadLayout.playstation), 'Cross (×)');
      expect(GamepadNames.friendlyButton(1, GamepadLayout.nintendo), 'B');

      expect(GamepadNames.srb2ButtonBind(1, Games.srb2, 1), 'joy1');
      expect(GamepadNames.srb2ButtonBind(1, Games.srb2, 2), 'sec_joy1');
      expect(GamepadNames.srb2ButtonBind(1, Games.srb2kart, 3), 'TRD_JOY1');
      expect(GamepadNames.srb2ButtonBind(1, Games.srb2kart, 4), 'FOR_JOY1');
      expect(GamepadNames.srb2ButtonBind(1, Games.drrr, 1), 'A BUTTON');

      expect(GamepadNames.srb2HatBind('hatup', Games.srb2, 1), 'hatup');
      expect(GamepadNames.srb2HatBind('hatup', Games.srb2, 2), 'sec_hatup');
      expect(GamepadNames.srb2HatBind('hatup', Games.drrr, 1), 'D-PAD UP');

      final blankart = Games.fromDefinition({'id': 'srb2blankart', 'name': 'BlanKart', 'base': 'srb2kart'});
      expect(GamepadNames.srb2ButtonBind(6, blankart, 1), 'R BUMPER');
    });

    test('detects canonical SRB2 axis regardless of stick pull direction', () {
      const rest = {'lx': 0.02, 'ly': -0.01, 'rx': 0.0, 'ry': 0.0, 'lt': 0.0, 'rt': 0.0};

      // Левый стик вверх И вниз -> всегда Y-Axis (без минуса).
      for (final val in [-0.95, 0.95]) {
        final lySnap = GamepadSnapshot(
          deviceIndex: 1,
          name: 'Xbox',
          isXInput: true,
          pressedButtons: const {},
          axes: GamepadNames.standardSdlAxes(lx: 0.0, ly: val, rx: 0.0, ry: 0.0, lt: 0.0, rt: 0.0),
        );
        final hit = GamepadNames.detectMovedAxis(lySnap, rest)!;
        expect(hit.$1.axisNameFor(Games.srb2, negative: hit.$2), 'Y-Axis');
        expect(hit.$1.axisNameFor(Games.srb2, negative: !hit.$2), 'Y-Axis-');
      }

      // Левый стик влево И вправо -> всегда X-Axis (без минуса).
      for (final val in [-0.95, 0.95]) {
        final lxSnap = GamepadSnapshot(
          deviceIndex: 1,
          name: 'Xbox',
          isXInput: true,
          pressedButtons: const {},
          axes: GamepadNames.standardSdlAxes(lx: val, ly: 0.0, rx: 0.0, ry: 0.0, lt: 0.0, rt: 0.0),
        );
        final hit = GamepadNames.detectMovedAxis(lxSnap, rest)!;
        expect(hit.$1.axisNameFor(Games.srb2, negative: hit.$2), 'X-Axis');
      }

      // Правый стик вверх И вниз -> всегда X-Rudder- (с минусом).
      for (final val in [-0.92, 0.92]) {
        final rySnap = GamepadSnapshot(
          deviceIndex: 1,
          name: 'Xbox',
          isXInput: true,
          pressedButtons: const {},
          axes: GamepadNames.standardSdlAxes(lx: 0.0, ly: 0.0, rx: 0.0, ry: val, lt: 0.0, rt: 0.0),
        );
        final hit = GamepadNames.detectMovedAxis(rySnap, rest)!;
        expect(hit.$1.axisNameFor(Games.srb2, negative: hit.$2), 'X-Rudder-');
        expect(hit.$1.axisNameFor(Games.srb2, negative: !hit.$2), 'X-Rudder');
        expect(hit.$1.axisNameFor(Games.srb2kart, negative: hit.$2), 'Right Y');
      }

      // Правый стик влево И вправо -> всегда Z-Axis (без минуса).
      for (final val in [-0.92, 0.92]) {
        final rxSnap = GamepadSnapshot(
          deviceIndex: 1,
          name: 'Xbox',
          isXInput: true,
          pressedButtons: const {},
          axes: GamepadNames.standardSdlAxes(lx: 0.0, ly: 0.0, rx: val, ry: 0.0, lt: 0.0, rt: 0.0),
        );
        final hit = GamepadNames.detectMovedAxis(rxSnap, rest)!;
        expect(hit.$1.axisNameFor(Games.srb2, negative: hit.$2), 'Z-Axis');
      }

      // SDL-привязка стиков для DRRR / BlanKart сохраняет направление.
      final leftUp = GamepadSnapshot(
        deviceIndex: 1,
        name: 'Xbox',
        isXInput: true,
        pressedButtons: const {},
        axes: GamepadNames.standardSdlAxes(lx: 0.0, ly: -0.95, rx: 0.0, ry: 0.0, lt: 0.0, rt: 0.0),
      );
      final rightUp = GamepadSnapshot(
        deviceIndex: 1,
        name: 'Xbox',
        isXInput: true,
        pressedButtons: const {},
        axes: GamepadNames.standardSdlAxes(lx: 0.0, ly: 0.0, rx: 0.0, ry: -0.95, lt: 0.0, rt: 0.0),
      );
      expect(GamepadNames.detectStickBind(leftUp, rest), 'L-STICK UP');
      expect(GamepadNames.detectStickBind(rightUp, rest), 'R-STICK UP');

      expect(GamepadNames.axisHint('Z-Axis'), 'Right Stick X');
      expect(GamepadNames.axisHint('X-Rudder-'), 'Right Stick Y');
      expect(GamepadNames.axisHint('Y-Rudder'), 'Left Trigger (LT)');
      expect(GamepadNames.axisHint('Z-Rudder'), 'Right Trigger (RT)');
    });

    test('decodes Nintendo Switch 0x30 and 0x3F HID reports accurately', () {
      // 0x30 полный отчёт: B (0x04 в b3), ZL (0x80 в b5), D-Pad Up (0x02 в b5), правый стик вправо (rx ~ 3448).
      final full = Uint8List(49);
      full[0] = 0x30;
      full[3] = 0x04 | 0x40; // B + R
      full[4] = 0x02; // Plus
      full[5] = 0x02 | 0x80; // D-Pad Up + ZL
      // lx = 2048 (0x800), ly = 2048 (0x800) => bytes [0x00, 0x08, 0x80]
      full[6] = 0x00;
      full[7] = 0x08;
      full[8] = 0x80;
      // rx = 3448 (0xD78), ry = 2048 (0x800) => bytes [0x78, 0x0D, 0x80]
      full[9] = 0x78;
      full[10] = 0x0D;
      full[11] = 0x80;

      final p30 = GamepadNames.parseNintendoSwitchReport(full)!;
      expect(p30.buttons, containsAll([1, 6, 8, 11]));
      expect(p30.hat, 'hatup');
      expect(p30.axes.firstWhere((a) => a.id == 'rx').value, greaterThan(0.9));
      expect(p30.axes.firstWhere((a) => a.id == 'lt').value, 1.0);

      // 0x3F компактный отчёт Bluetooth: A (0x02), ZR (0x80), hat = 2 (Right).
      final compact = Uint8List(12);
      compact[0] = 0x3F;
      compact[1] = 0x02 | 0x80; // A + ZR
      compact[3] = 0x02; // Hat Right
      compact[5] = 0x80; // lx mid
      compact[7] = 0x80; // ly mid
      compact[9] = 0x80; // rx mid
      compact[11] = 0x80; // ry mid

      final p3f = GamepadNames.parseNintendoSwitchReport(compact)!;
      expect(p3f.buttons, containsAll([2, 12]));
      expect(p3f.hat, 'hatright');
      expect(p3f.axes.firstWhere((a) => a.id == 'rt').value, 1.0);
    });

    test('live pollOnce and background isolate start/stop run fast without blocking UI', () async {
      final svc = GamepadService();
      addTearDown(svc.dispose);
      final sw = Stopwatch()..start();
      expect(svc.pollOnce(), isA<List<GamepadSnapshot>>());
      sw.stop();
      // Без сканирования пустых WinMM-слотов pollOnce должен выполняться быстрее 50 мс.
      expect(sw.elapsedMilliseconds, lessThan(50));

      svc.startPolling(interval: const Duration(milliseconds: 16));
      final first = await svc.stream.first.timeout(const Duration(seconds: 3));
      expect(first, isA<List<GamepadSnapshot>>());
      svc.stopPolling();
    });

    test('snapshotsEqual suppresses noisy micro-jitter while detecting real changes', () {
      final base = [
        GamepadSnapshot(
          deviceIndex: 1,
          name: 'Pad',
          isXInput: true,
          axes: GamepadNames.standardSdlAxes(lx: 0.0, ly: 0.0, rx: 0.0, ry: 0.0, lt: 0.0, rt: 0.0),
          pressedButtons: const {},
        ),
      ];
      final jitter = [
        GamepadSnapshot(
          deviceIndex: 1,
          name: 'Pad',
          isXInput: true,
          axes: GamepadNames.standardSdlAxes(lx: 0.002, ly: 0.0, rx: 0.0, ry: 0.0, lt: 0.0, rt: 0.0),
          pressedButtons: const {},
        ),
      ];
      final pressed = [
        GamepadSnapshot(
          deviceIndex: 1,
          name: 'Pad',
          isXInput: true,
          axes: GamepadNames.standardSdlAxes(lx: 0.0, ly: 0.0, rx: 0.0, ry: 0.0, lt: 0.0, rt: 0.0),
          pressedButtons: const {1},
        ),
      ];
      expect(GamepadService.snapshotsEqual(base, jitter), isTrue);
      expect(GamepadService.snapshotsEqual(base, pressed), isFalse);
    });
  });

  group('GamepadTesterDialog widget', () {
    testWidgets('renders live sticks, switches Xbox/PS labels, and updates deadzone', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final fake = _FakeGamepadService(const [
        GamepadSnapshot(
          deviceIndex: 1,
          name: 'XInput Controller #1',
          isXInput: true,
          pressedButtons: {1},
          hat: 'hatup',
          axes: [
            GamepadAxisInfo(id: 'lx', label: 'Left Stick X', value: 0.5, srb2Positive: 'X-Axis', srb2Negative: 'X-Axis-', kartPositive: 'Left X', kartNegative: 'Left X-'),
            GamepadAxisInfo(id: 'ly', label: 'Left Stick Y', value: -0.25, srb2Positive: 'Y-Axis', srb2Negative: 'Y-Axis-', kartPositive: 'Left Y', kartNegative: 'Left Y-'),
          ],
        ),
      ]);
      addTearDown(fake.dispose);

      final updated = <String, String>{};
      final axisSpec = Srb2ConfigSchema.forGame(Games.srb2)
          .specs
          .firstWhere((s) => s.name == 'joyaxis_move');

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: GamepadTesterDialog(
            game: Games.srb2,
            player: 1,
            axisSpecs: [(axisSpec, 'joyaxis_move')],
            currentValues: const {'joyaxis_move': 'Y-Axis'},
            deadzoneCvar: 'joy_deadzone',
            initialDeadzone: 0.125,
            deviceIndexCvar: 'use_gamepad',
            onCvarChanged: (k, v) => updated[k] = v,
            service: fake,
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Gamepad Tester & Calibration'), findsOneWidget);
      expect(find.text('A · joy1'), findsOneWidget);
      expect(find.text('D-Pad Up · hatup'), findsOneWidget);

      // Переключение раскладки на PlayStation меняет подписи кнопок.
      await tester.tap(find.text('PS'));
      await tester.pumpAndSettle();
      expect(find.text('Cross (×) · joy1'), findsOneWidget);

      // Кнопка выбора устройства для P1 обновляет use_gamepad.
      await tester.tap(find.text('Use #1 for P1'));
      await tester.pumpAndSettle();
      expect(updated['use_gamepad'], '1');
    });

    testWidgets('auto-selects layout from detectedLayout and displays VID:PID chip', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final fake = _FakeGamepadService(const [
        GamepadSnapshot(
          deviceIndex: 1,
          name: 'Sony DualSense (PS5)',
          isXInput: false,
          detectedLayout: GamepadLayout.playstation,
          vendorId: 0x054C,
          productId: 0x0CE6,
          axes: [],
          pressedButtons: {1},
        ),
      ]);
      addTearDown(fake.dispose);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: GamepadTesterDialog(
            game: Games.srb2,
            player: 1,
            axisSpecs: const [],
            currentValues: const {},
            deadzoneCvar: 'joy_deadzone',
            initialDeadzone: 0.125,
            deviceIndexCvar: 'use_gamepad',
            onCvarChanged: (_, _) {},
            service: fake,
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // Раскладка PS выбрана автоматически без ручного нажатия кнопки PS.
      expect(find.text('Cross (×) · joy1'), findsOneWidget);
      expect(find.text('playstation · 054C:0CE6'), findsOneWidget);
    });
  });

  group('GamepadCatalog.identify', () {
    test('identifies Xbox, DualSense, Switch Pro by VID:PID and fallback heuristics', () {
      final xbox = GamepadCatalog.identify(vendorId: 0x045E, productId: 0x02E0);
      expect(xbox.layout, GamepadLayout.xbox);
      expect(xbox.modelName, contains('Xbox'));

      final ps5 = GamepadCatalog.identify(vendorId: 0x054C, productId: 0x0CE6);
      expect(ps5.layout, GamepadLayout.playstation);
      expect(ps5.modelName, contains('DualSense'));

      final nsw = GamepadCatalog.identify(vendorId: 0x057E, productId: 0x2009);
      expect(nsw.layout, GamepadLayout.nintendo);
      expect(nsw.modelName, contains('Switch'));

      final heuristic = GamepadCatalog.identify(rawName: 'Wireless DualShock 4');
      expect(heuristic.layout, GamepadLayout.playstation);
    });
  });

  group('showKeyCaptureDialog gamepad safety', () {
    testWidgets('pops once cleanly even if multiple 16ms gamepad press events fire', (tester) async {
      final fake = _FakeGamepadService(const [
        GamepadSnapshot(
          deviceIndex: 1,
          name: 'Xbox Wireless Controller',
          detectedLayout: GamepadLayout.xbox,
          vendorId: 0x045E,
          productId: 0x02E0,
          isXInput: true,
          axes: [],
          pressedButtons: {},
        ),
      ]);
      addTearDown(fake.dispose);

      String? captured;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                captured = await showKeyCaptureDialog(
                  context,
                  game: Games.srb2,
                  player: 1,
                  actionLabel: 'Jump',
                  currentKey: 'SPACE',
                  gamepadService: fake,
                );
              },
              child: const Text('Bind'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('Bind'));
      await tester.pumpAndSettle();

      expect(find.text('Detected controller: Xbox Wireless Controller'), findsOneWidget);

      // Эмулируем серию повторных кадров с нажатой кнопкой 1 до завершения анимации закрытия.
      const pressed = [
        GamepadSnapshot(
          deviceIndex: 1,
          name: 'Xbox Wireless Controller',
          detectedLayout: GamepadLayout.xbox,
          vendorId: 0x045E,
          productId: 0x02E0,
          isXInput: true,
          axes: [],
          pressedButtons: {1},
        ),
      ];
      fake.push(pressed);
      await tester.pump(const Duration(milliseconds: 16));
      fake.push(pressed);
      await tester.pump(const Duration(milliseconds: 16));
      fake.push(pressed);
      await tester.pumpAndSettle();

      expect(captured, 'joy1');
      // Главный экран всё ещё на месте (не произошёл лишний Navigator.pop).
      expect(find.text('Bind'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('ConfigSettings uppercase controls UI', () {
    testWidgets('displays bound controls in uppercase while saving lowercase to config', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final tmp = Directory.systemTemp.createTempSync('srb2_ctrl_ui_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final cfgFile = File('${tmp.path}/config.cfg');
      cfgFile.writeAsStringSync('setcontrol "jump" "space" "joy1"\n');

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ConfigSettings(
            game: Games.srb2,
            gameFolder: tmp.path,
            launch: null,
            onConfigureFolder: () {},
            onDirtyChanged: (_) {},
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Controls'));
      await tester.pumpAndSettle();

      expect(find.text('SPACE'), findsOneWidget);
      expect(find.text('JOY1'), findsOneWidget);

      // Значение в файле на диске остаётся в исходном регистре SRB2.
      final parsed = Srb2ConfigDocument.parse(cfgFile.readAsStringSync());
      expect(parsed.control(1, 'jump')?.primary, 'space');
      expect(parsed.control(1, 'jump')?.secondary, 'joy1');
    });
  });

  group('DRRR and BlanKart Detect controls', () {
    testWidgets('showDetectGamepadControlDialog captures stick tilt for BlanKart', (tester) async {
      final fake = _FakeGamepadService([
        GamepadSnapshot(
          deviceIndex: 1,
          name: 'Xbox Wireless Controller',
          detectedLayout: GamepadLayout.xbox,
          isXInput: true,
          axes: GamepadNames.standardSdlAxes(lx: 0, ly: 0, rx: 0, ry: 0, lt: 0, rt: 0),
          pressedButtons: const {},
        ),
      ]);
      addTearDown(fake.dispose);

      final ag = File('packaging/another_games.json').readAsStringSync();
      final def = CustomGames.parse(ag).first;
      final blankart = Games.fromDefinition(def);
      final schema = Srb2ConfigSchema.forGame(blankart);
      expect(schema.gamepadDetectControls, containsAll(['turnleft', 'accelerate', 'drift']));
      expect(Srb2ConfigSchema.forGame(Games.drrr).gamepadDetectControls, containsAll(['up', 'left', 'a', 'l']));

      String? captured;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                captured = await showDetectGamepadControlDialog(
                  context,
                  game: blankart,
                  player: 1,
                  actionLabel: 'turnleft',
                  gamepadService: fake,
                );
              },
              child: const Text('DetectCtrl'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('DetectCtrl'));
      await tester.pumpAndSettle();

      fake.push([
        GamepadSnapshot(
          deviceIndex: 1,
          name: 'Xbox Wireless Controller',
          detectedLayout: GamepadLayout.xbox,
          isXInput: true,
          axes: GamepadNames.standardSdlAxes(lx: -0.95, ly: 0, rx: 0, ry: 0, lt: 0, rt: 0),
          pressedButtons: const {},
        ),
      ]);
      await tester.pumpAndSettle();

      expect(captured, 'L-STICK LEFT');
    });

    testWidgets('ConfigSettings renders Detect button on DRRR control rows and preserves keyboard bind', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final tmp = Directory.systemTemp.createTempSync('drrr_detect_ui_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      File('${tmp.path}/ringconfig.cfg').writeAsStringSync('setcontrol "left" "LEFT ARROW" "D-PAD LEFT"\n');

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ConfigSettings(
            game: Games.drrr,
            gameFolder: tmp.path,
            launch: null,
            onConfigureFolder: () {},
            onDirtyChanged: (_) {},
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Controls'));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Detect with gamepad'), findsWidgets);
      expect(find.text('LEFT ARROW'), findsOneWidget);
      expect(find.text('D-PAD LEFT'), findsOneWidget);
    });
  });
}
