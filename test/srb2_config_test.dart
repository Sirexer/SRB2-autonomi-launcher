import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:srb2_autonomi_launcher/models/game.dart';
import 'package:srb2_autonomi_launcher/services/custom_games.dart';
import 'package:srb2_autonomi_launcher/services/launch_settings.dart';
import 'package:srb2_autonomi_launcher/services/servers_store.dart';
import 'package:srb2_autonomi_launcher/services/srb2_config.dart';
import 'package:srb2_autonomi_launcher/services/srb2_config_schema.dart';
import 'package:srb2_autonomi_launcher/ui/addon_icon.dart';
import 'package:srb2_autonomi_launcher/ui/config_settings.dart';
import 'package:srb2_autonomi_launcher/ui/settings_dialog.dart';

const _sampleConfig = '''// SRB2 configuration file.
execversion "56"
renderer "OpenGL"
fullscreen "Yes"
1upsound "Sound"
name "{RU}Player ("
gr_models "Off"
custom_mod_var "hello world"
setcontrol "forward" "w"
setcontrol "jump" "space" "mouse2"
setcontrol2 "tossflag" "sec_joy1"
''';

void main() {
  group('Srb2ConfigDocument', () {
    test('parses cvars, comments, controls and preserves clean state', () {
      final doc = Srb2ConfigDocument.parse(_sampleConfig);
      expect(doc.isDirty, isFalse);
      expect(doc.changedCount, 0);
      expect(doc.cvar('renderer'), 'OpenGL');
      expect(doc.cvar('1upsound'), 'Sound');
      expect(doc.cvar('name'), '{RU}Player (');
      expect(doc.cvar('custom_mod_var'), 'hello world');

      final jump = doc.control(1, 'jump')!;
      expect(jump.primary, 'space');
      expect(jump.secondary, 'mouse2');

      final p2Flag = doc.control(2, 'tossflag')!;
      expect(p2Flag.primary, 'sec_joy1');
      expect(p2Flag.secondary, '');
    });

    test('tracks dirty state accurately, supports reset and round-trip save with backup', () async {
      final dir = await Directory.systemTemp.createTemp('srb2_cfg_test_');
      addTearDown(() => dir.delete(recursive: true));
      final cfgPath = p.join(dir.path, 'config.cfg');
      await File(cfgPath).writeAsString(_sampleConfig);

      final doc = await Srb2ConfigDocument.loadFile(cfgPath);
      expect(doc.isDirty, isFalse);

      doc.setCvar('gr_models', 'On');
      expect(doc.isDirty, isTrue);
      expect(doc.changedCount, 1);

      // Возврат исходного значения снимает флаг несохранённых изменений.
      doc.setCvar('gr_models', 'Off');
      expect(doc.isDirty, isFalse);

      doc.setCvar('gr_models', 'On');
      doc.setCvar('new_extra_cvar', '123');
      doc.setControl(1, 'forward', primary: 'up arrow');
      expect(doc.changedCount, 3);

      doc.reset();
      expect(doc.isDirty, isFalse);
      expect(doc.cvar('gr_models'), 'Off');
      expect(doc.hasCvar('new_extra_cvar'), isFalse);
      expect(doc.control(1, 'forward')!.primary, 'w');

      // Реальные изменения + сохранение + проверка бэкапа и комментариев.
      doc.setCvar('gr_models', 'On');
      doc.setCvar('new_extra_cvar', '456');
      doc.setControl(1, 'jump', secondary: 'KEY0');
      final saved = await doc.save();

      expect(saved.isDirty, isFalse);
      final bak = File('$cfgPath.bak');
      expect(await bak.exists(), isTrue);
      expect(await bak.readAsString(), _sampleConfig);

      final disk = await File(cfgPath).readAsString();
      expect(disk, contains('// SRB2 configuration file.'));
      expect(disk, contains('gr_models "On"'));
      expect(disk, contains('custom_mod_var "hello world"'));
      expect(disk, contains('new_extra_cvar "456"'));
      expect(disk, contains('setcontrol "jump" "space"'));
    });

    test('resolves expected config file names per game', () {
      expect(Srb2ConfigDocument.configFileNameFor(Games.srb2), 'config.cfg');
      expect(Srb2ConfigDocument.configFileNameFor(Games.srb2legacy), 'config.cfg');
      expect(Srb2ConfigDocument.configFileNameFor(Games.srb2kart), 'kartconfig.cfg');
      expect(Srb2ConfigDocument.configFileNameFor(Games.drrr), 'ringconfig.cfg');
      final blankart = Games.fromDefinition({
        'id': 'srb2blankart',
        'name': 'BlanKart',
        'base': 'srb2kart',
        'config_file': 'blanconfig.cfg',
      });
      expect(Srb2ConfigDocument.configFileNameFor(blankart), 'blanconfig.cfg');
    });

    test('preserves setcontrol3, setcontrol4 and 3-key Ring Racers binds on round-trip', () {
      const drrrCfg = '''
setcontrol3 "up" "UP ARROW" "D-PAD UP" "L-STICK UP"
setcontrol4 "a" "A" "A BUTTON"
''';
      final doc = Srb2ConfigDocument.parse(drrrCfg);
      final p3Up = doc.control(3, 'up')!;
      expect(p3Up.primary, 'UP ARROW');
      expect(p3Up.secondary, 'D-PAD UP');
      expect(p3Up.extraKeys, ['L-STICK UP']);

      doc.setControl(3, 'up', primary: 'w');
      final saved = doc.serialize();
      expect(saved, contains('setcontrol3 "up" "w" "D-PAD UP" "L-STICK UP"'));
      expect(saved, contains('setcontrol4 "a" "A" "A BUTTON"'));
    });
  });

  group('Srb2ConfigSchema', () {
    test('maps common Flutter keys to SRB2 key names', () {
      expect(Srb2ConfigSchema.logicalKeyToSrb2(LogicalKeyboardKey.space), 'space');
      expect(Srb2ConfigSchema.logicalKeyToSrb2(LogicalKeyboardKey.keyW), 'w');
      expect(Srb2ConfigSchema.logicalKeyToSrb2(LogicalKeyboardKey.shiftLeft), 'lshift');
      expect(Srb2ConfigSchema.logicalKeyToSrb2(LogicalKeyboardKey.arrowUp), 'up arrow');
      expect(Srb2ConfigSchema.logicalKeyToSrb2(LogicalKeyboardKey.backquote), 'TILDE');
      expect(Srb2ConfigSchema.logicalKeyToSrb2(LogicalKeyboardKey.f12), 'f12');
    });

    test('inherits SRB2Kart schema and applies another_games overrides for BlanKart', () {
      final ag = File('packaging/another_games.json').readAsStringSync();
      final def = CustomGames.parse(ag).first;
      final blankart = Games.fromDefinition(def);
      final schema = Srb2ConfigSchema.forGame(blankart);

      expect(blankart.configFileName, 'blanconfig.cfg');
      expect(schema.maxPlayers, 4);
      // Унаследовано от SRB2Kart:
      expect(schema.controlActions.any((c) => c.command == 'drift'), isTrue);
      // Добавлено в another_games.json:
      expect(schema.controlActions.any((c) => c.command == 'horncode'), isTrue);
      // Убрано и заменено в another_games.json:
      expect(schema.isCuratedCvar('gr_mdls'), isFalse);
      expect(schema.isCuratedCvar('gr_models'), isTrue);
      // Per-player на 4 игроков:
      expect(schema.isCuratedCvar('driftmode4'), isTrue);
      expect(schema.isCuratedCvar('cam4_dist'), isTrue);
    });
  });

  group('SettingsDialog Config protection', () {
    Widget buildHarness(Directory folder) {
      return MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => SettingsDialog.show(
                context,
                SettingsDialog(
                  initialSection: SettingsSection.config,
                  game: Games.srb2,
                  gameFolderOf: (_) async => folder.path,
                  launchOf: (_) async => LaunchSettings(Games.srb2),
                  serversOf: (g) => ServersStore(g),
                  onGameFolderChanged: (_, _) async => null,
                  hiddenTags: '',
                  onHiddenTagsChanged: (_) {},
                  autoHideTags: false,
                  onAutoHideTagsChanged: (_) {},
                  versionFolders: false,
                  onVersionFoldersChanged: (_) {},
                  playerEnabled: false,
                  onPlayerEnabledChanged: (_) {},
                  progressEnabled: false,
                  onProgressEnabledChanged: (_) {},
                  replaysEnabled: false,
                  onReplaysEnabledChanged: (_) {},
                  onSaveProtectionChanged: (_) {},
                  progressHidden: const [],
                  onProgressUnhide: (_) {},
                  showOtherDownloads: false,
                  onShowOtherDownloadsChanged: (_) {},
                  showFolderAddons: false,
                  onShowFolderAddonsChanged: (_) {},
                  onRestartAutonomi: () async => true,
                  iconAnimation: AddonIconAnimation.values.first,
                  onIconAnimationChanged: (_) {},
                  repositoryUpdates: RepositoryUpdates.auto,
                  onRepositoryUpdatesChanged: (_) {},
                  repositoryUpdateButtons: false,
                  onRepositoryUpdateButtonsChanged: (_) {},
                  tagDisplay: (showGroup: false, order: TagOrder.alphabetical, showAll: false),
                  onTagDisplayChanged: (_) {},
                  onGamesChanged: () {},
                  onHiddenFoldersChanged: (_) {},
                  themeKey: 'dark',
                  onThemeChanged: (_) {},
                ),
              ),
              child: const Text('open_settings'),
            ),
          ),
        ),
      );
    }

    testWidgets('ConfigSettings standalone renders and saves', (tester) async {
      tester.view.physicalSize = const Size(760, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final dir = Directory.systemTemp.createTempSync('srb2_cfg_only_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final cfgPath = p.join(dir.path, 'config.cfg');
      File(cfgPath).writeAsStringSync(_sampleConfig);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ConfigSettings(
            game: Games.srb2,
            gameFolder: dir.path,
            launch: LaunchSettings(Games.srb2),
            onConfigureFolder: () {},
            onDirtyChanged: (_) {},
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Video'), findsOneWidget);
      expect(find.text('All changes saved'), findsOneWidget);

      // Проверяем горизонтальную прокрутку полосы сабвкладок колёсиком мыши.
      final tabsScrollable = find.descendant(
        of: find.byWidgetPredicate((w) => w is SingleChildScrollView && w.scrollDirection == Axis.horizontal),
        matching: find.byType(Scrollable),
      );
      final tabsPos = tester.state<ScrollableState>(tabsScrollable.first).position;
      expect(tabsPos.maxScrollExtent, greaterThan(0));
      final center = tester.getCenter(find.text('Video'));
      await tester.sendEventToBinding(PointerScrollEvent(
        position: center,
        scrollDelta: const Offset(0, 120),
      ));
      await tester.pump();
      expect(tabsPos.pixels, greaterThan(0));
    });

    testWidgets('blocks closing and section switch on unsaved changes until saved or discarded', (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final dir = Directory.systemTemp.createTempSync('srb2_ui_cfg_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final cfgPath = p.join(dir.path, 'config.cfg');
      File(cfgPath).writeAsStringSync(_sampleConfig);

      await tester.pumpWidget(buildHarness(dir));
      await tester.tap(find.text('open_settings'));
      await tester.pumpAndSettle();

      // Сабвкладки на месте.
      expect(find.text('Video'), findsOneWidget);
      expect(find.text('Audio'), findsOneWidget);
      expect(find.text('Controls'), findsOneWidget);
      expect(find.text('All variables'), findsOneWidget);
      expect(find.text('All changes saved'), findsOneWidget);

      // Переключаемся на Audio, затем возвращаемся на Video и проверяем Reset/Save + защиту выхода.
      await tester.tap(find.text('Audio'));
      await tester.pumpAndSettle();
      expect(find.text('Sound effects'), findsOneWidget);

      await tester.tap(find.text('Video'));
      await tester.pumpAndSettle();

      final row = find.ancestor(of: find.text('Fullscreen'), matching: find.byType(Container)).first;
      final sw = find.descendant(of: row, matching: find.byType(Switch));
      await tester.tap(sw);
      await tester.pumpAndSettle();
      expect(find.text('Unsaved changes: 1'), findsOneWidget);

      // Кнопка Reset возвращает исходное состояние.
      await tester.tap(find.widgetWithText(OutlinedButton, 'Reset'));
      await tester.pumpAndSettle();
      expect(find.text('All changes saved'), findsOneWidget);

      // Снова меняем настройку и пытаемся уйти без сохранения.
      await tester.tap(sw);
      await tester.pumpAndSettle();
      expect(find.text('Unsaved changes: 1'), findsOneWidget);

      // Попытка перейти в раздел General — лаунчер не пускает и спрашивает.
      await tester.tap(find.text('General'));
      await tester.pumpAndSettle();
      expect(find.text('Unsaved changes in config'), findsOneWidget);

      // Нажимаем Cancel — остаёмся в Config с несохранённой правкой.
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      expect(find.text('Video'), findsOneWidget);
      expect(find.text('Unsaved changes: 1'), findsOneWidget);

      // Попытка закрыть крестиком — снова защита, выбираем Save и проверяем файл на диске.
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.text('Unsaved changes in config'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
      await tester.pumpAndSettle();

      expect(find.text('Unsaved changes in config'), findsNothing);
      expect(File(cfgPath).readAsStringSync(), contains('fullscreen "No"'));
      expect(File('$cfgPath.bak').readAsStringSync(), contains('fullscreen "Yes"'));

      // Дожидаемся таймера showSnack (3 сек), чтобы в teardown не осталось активных таймеров.
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });
  });
}
