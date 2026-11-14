import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:srb2_autonomi_launcher/models/game.dart';
import 'package:srb2_autonomi_launcher/models/launch_config.dart';
import 'package:srb2_autonomi_launcher/services/launch_settings.dart';
import 'package:srb2_autonomi_launcher/services/platform_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LaunchOptions.toArgs', () {
    test('defaults produce no arguments', () {
      expect(LaunchOptions().toArgs(), isEmpty);
    });

    test('renderer, flags in fixed order, resolution and warp', () {
      final o = LaunchOptions()
        ..renderer = RendererMode.opengl
        ..flags.addAll(['-nodata', '-win', '-skipintro'])
        ..customResolution = true
        ..width = '1280'
        ..height = '720'
        ..warpMap = ' MAP01 ';
      expect(o.toArgs(), [
        '-opengl', '-win', '-skipintro', '-nodata', //
        '-width', '1280', '-height', '720', '-warp', 'MAP01',
      ]);
    });

    test('joining a server drops -warp and -gametype', () {
      final o = LaunchOptions()
        ..warpMap = 'MAP04'
        ..gametype = 'Hangout'
        ..console = [const ConsoleEntry('skin', 'shadow')];
      expect(o.forJoining('1.2.3.4:5029').toArgs(), ['+connect', '1.2.3.4:5029', '+skin', 'shadow']);
      expect(o.toArgs(), ['-warp', 'MAP04', '-gametype', 'Hangout', '+skin', 'shadow']);
    });

    test('-ultimatemode only for SRB2', () {
      final o = LaunchOptions()..flags.add('-ultimatemode');
      expect(o.toArgs(), ['-ultimatemode']);
      expect(o.toArgs(game: Games.srb2kart), isEmpty);
    });

    test('incomplete resolution or empty warp are skipped', () {
      final o = LaunchOptions()
        ..customResolution = true
        ..width = '1280'
        ..warpMap = '  ';
      expect(o.toArgs(), isEmpty);
    });

    test('-warp without a checkbox: a saved unchecked warp has no map', () {
      final old = LaunchOptions.fromJson({'warpEnabled': false, 'warpMap': 'MAP05'});
      expect(old.warpMap, '');
      expect(old.toArgs(), isEmpty);
      final on = LaunchOptions.fromJson({'warpEnabled': true, 'warpMap': 'MAP05'});
      expect(on.toArgs(), ['-warp', 'MAP05']);
      expect(LaunchOptions.fromJson(on.toJson()).warpMap, 'MAP05');
    });

    test('always default color: the own color of the character instead of +color', () {
      final o = LaunchOptions()
        ..defaultColor = true
        ..console = [const ConsoleEntry('skin', 'shadow'), const ConsoleEntry('color', 'Red')];
      expect(o.toArgs(skinColor: 'Black'), ['+skin', 'shadow', '+color', 'Black']);
      expect(o.toArgs(), ['+skin', 'shadow']); // цвет персонажа неизвестен — игра решит сама
      expect(o.toArgs(game: Games.drrr), ['+skin', 'shadow', '+color', 'Default']);
      expect(LaunchOptions.fromJson(o.toJson()).defaultColor, isTrue);
      o.defaultColor = false;
      expect(o.toArgs(skinColor: 'Black'), ['+skin', 'shadow', '+color', 'Red']);
    });

    test('net modes', () {
      final o = LaunchOptions()..net = NetMode.join;
      // +connect: консольная команда после загрузки -file (с -connect SRB2 их пропускает).
      expect(o.toArgs(), ['+connect', 'any']); // пустой адрес — поиск в локальной сети
      o.joinAddress = '127.0.0.1:5029';
      expect(o.toArgs(), ['+connect', '127.0.0.1:5029']);

      o
        ..net = NetMode.host
        ..room = '33'
        ..adminPassword = 'secret';
      expect(o.toArgs(), ['-server', '-room', '33', '-password', 'secret']);

      o.net = NetMode.dedicated;
      expect(o.toArgs().first, '-dedicated');

      o.net = NetMode.off;
      expect(o.toArgs(), isEmpty); // room/password only for hosting
    });

    test('server example: -server -room 33 -gametype match -warp MAPMB +maxsend 200000', () {
      final o = LaunchOptions()
        ..net = NetMode.host
        ..room = '33'
        ..gametype = 'match'
        ..warpMap = 'MAPMB'
        ..console = [
          const ConsoleEntry('maxsend', '200000'),
          const ConsoleEntry('servername', 'My Server'),
          const ConsoleEntry('downloading', 'Off', enabled: false),
        ];
      expect(o.toArgs(), [
        '-warp', 'MAPMB', '-server', '-room', '33', '-gametype', 'match', //
        '+maxsend', '200000', '+servername', 'My Server',
      ]);
      final back = LaunchOptions.fromJson(jsonDecode(jsonEncode(o.toJson())));
      expect(back.toArgs(), o.toArgs());
      expect(back.console.last.enabled, isFalse);
    });

    test('JSON round trip ignores unknown flags', () {
      final o = LaunchOptions()
        ..renderer = RendererMode.software
        ..net = NetMode.join
        ..joinAddress = 'srb2.example'
        ..flags.addAll(['-nosound', '-borderless']);
      final back = LaunchOptions.fromJson({...o.toJson(), 'flags': ['-nosound', '-borderless', '-rm-rf']});
      expect(back.toArgs(), o.toArgs());
      expect(LaunchOptions.fromJson('garbage').toArgs(), isEmpty);
    });
  });

  group('LaunchExecutable', () {
    test('suggestName is the file name, folderName its folder', () {
      const win = r'"D:\Games\SRB2\bin\TSoURDt3rd_x64\srb2win.exe"';
      expect(LaunchExecutable.suggestName(win), 'srb2win');
      expect(LaunchExecutable.folderName(win), 'TSoURDt3rd_x64');
      expect(LaunchExecutable.suggestName('/opt/srb2/lsdl2srb2'), 'lsdl2srb2');
      expect(LaunchExecutable.suggestName('srb2'), 'srb2');
      expect(LaunchExecutable.folderName('srb2'), '');
      expect(LaunchExecutable.folderName(r'C:\srb2win.exe'), '');
      expect(LaunchExecutable.suggestName('flatpak run org.srb2.SRB2'), 'flatpak');
    });

    test('program is the first word of the command', () {
      const e = LaunchExecutable(id: '1', name: 'x', command: '"/home/u/My Games/srb2" -opengl');
      expect(e.program, '/home/u/My Games/srb2');
    });

    test('fromJson rejects broken entries', () {
      expect(LaunchExecutable.fromJson({'id': '1', 'command': '  '}), isNull);
      expect(LaunchExecutable.fromJson('x'), isNull);
      expect(LaunchExecutable.fromJson({'id': '1', 'command': 'srb2'})!.name, 'srb2');
    });
  });

  group('LaunchSettings', () {
    test('migrates the old single launch command', () async {
      SharedPreferences.setMockInitialValues({'srb2_launch_command': r'"C:\SRB2 2.2.15\srb2win.exe"'});
      final s = LaunchSettings();
      await s.load();
      expect(s.executables, hasLength(1));
      expect(s.executables.single.name, 'srb2win');
      expect(s.isDefault(s.executables.single), isTrue);
      expect(s.selected, same(s.executables.single));
    });

    test('fresh install gets the platform default', () async {
      SharedPreferences.setMockInitialValues({});
      final s = LaunchSettings();
      await s.load();
      expect(s.command, PlatformUtils.defaultLaunchCommand());
      expect(s.executables.single.name, 'SRB2');
    });

    test('command line = executable + its args + options + extra params', () async {
      SharedPreferences.setMockInitialValues({});
      final s = LaunchSettings();
      await s.load();
      s.addExecutable(const LaunchExecutable(id: 'b', name: 'Build', command: '"/bin dir/srb2" -nojoy'));
      s.updateOptions((o) => o.flags.add('-win'));
      s.setExtraParams('-gametype coop "+name Sonic Fan"');
      expect(s.commandLine(), ['/bin dir/srb2', '-nojoy', '-win', '-gametype', 'coop', '+name Sonic Fan']);
    });

    test('reset returns the options to defaults and keeps builds and profiles', () async {
      SharedPreferences.setMockInitialValues({});
      final s = LaunchSettings();
      await s.load();
      s.addExecutable(const LaunchExecutable(id: 'b', name: 'Build', command: 'srb2'));
      s.updateOptions((o) {
        o.flags.add('-win');
        o.warpMap = 'MAP01';
        o.defaultColor = true;
        o.setCvar('skin', 'knuckles');
      });
      s.setExtraParams('-nojoy');
      s.saveProfile('Mine', const ['a.pk3']);
      s.resetOptions();
      expect(s.options.toJson(), LaunchOptions().toJson());
      expect(s.extraParams, '');
      expect(s.currentProfile, isNull);
      expect(s.executables.map((e) => e.id), contains('b'));
      expect(s.profiles.single.name, 'Mine');
      expect(s.commandLine(executableId: 'b'), ['srb2']);
    });

    test('default and selection survive removal', () async {
      SharedPreferences.setMockInitialValues({});
      final s = LaunchSettings();
      await s.load();
      final first = s.executables.single;
      s.addExecutable(const LaunchExecutable(id: 'b', name: 'B', command: 'b'));
      s.setDefault('b');
      expect(s.selected!.id, 'b'); // newly added is selected
      s.removeExecutable('b');
      expect(s.isDefault(first), isTrue);
      expect(s.selected, same(first));
      s.removeExecutable(first.id);
      expect(s.selected, isNull);
      expect(s.command, PlatformUtils.defaultLaunchCommand());
    });

    test('uniqueName adds the folder, then a number', () async {
      SharedPreferences.setMockInitialValues({});
      final s = LaunchSettings();
      await s.load(); // "SRB2"
      const x32 = '/games/bin/x32/srb2win';
      const x64 = '/games/bin/x64/srb2win';
      expect(s.uniqueName(x32), 'srb2win');
      s.addExecutable(LaunchExecutable(id: 'a', name: s.uniqueName(x32), command: x32));
      expect(s.uniqueName(x64), 'srb2win (x64)');
      s.addExecutable(LaunchExecutable(id: 'b', name: s.uniqueName(x64), command: x64));
      expect(s.uniqueName(x64), 'srb2win (x64) 2');
      expect(s.uniqueName('/x/SRB2'), 'SRB2 (x)'); // case-insensitive clash with "SRB2"
    });

    test('profiles keep options, extra params and the queue', () async {
      SharedPreferences.setMockInitialValues({});
      final s = LaunchSettings();
      await s.load();
      s.updateOptions((o) {
        o.flags.add('-win');
        o.console = [const ConsoleEntry('maxsend', '200000')];
      });
      s.setExtraParams('-nojoy');
      s.saveProfile('Server', ['a.pk3', 'Addon/1.0/b.pk3']);

      s.updateOptions((o) {
        o.flags.clear();
        o.console = [];
      });
      s.setExtraParams('');
      final queue = s.applyProfile(s.profiles.single);
      expect(queue, ['a.pk3', 'Addon/1.0/b.pk3']);
      expect(s.options.has(LaunchFlags.windowed), isTrue);
      expect(s.extraParams, '-nojoy');
      expect(s.currentProfile, 'Server');

      s.saveProfile('Server', null); // то же имя — замена
      expect(s.profiles, hasLength(1));
      s.removeProfile(0);
      expect(s.profiles, isEmpty);
      expect(s.currentProfile, isNull);
    });

    test('old extra-parameter presets load as profiles', () async {
      SharedPreferences.setMockInitialValues({
        'launch_extra_presets': '[{"name": "Map test", "params": "-warp MAP01"}]',
      });
      final s = LaunchSettings();
      await s.load();
      expect(s.profiles.single.name, 'Map test');
      expect(s.profiles.single.options, isNull);
      expect(s.applyProfile(s.profiles.single), isNull); // очередь не трогаем
      expect(s.extraParams, '-warp MAP01');
    });
  });

  test('findExecutables names builds by folder', () async {
    final root = await Directory.systemTemp.createTemp('srb2_scan_');
    addTearDown(() => root.delete(recursive: true));

    Future<String> make(String rel) async {
      final f = File(p.join(root.path, rel));
      await f.parent.create(recursive: true);
      await f.writeAsString('x');
      if (!Platform.isWindows) await Process.run('chmod', ['+x', f.path]);
      return f.path;
    }

    final exe = Platform.isWindows ? '.exe' : '';
    await make('x32/srb2win$exe');
    await make('TSoURDt3rd_x64/srb2win$exe');
    await make('TSoURDt3rd_x64/updater$exe');
    await make('ReShade/ReShade_Setup$exe');
    await make('deep/er/srb2win$exe'); // too deep, skipped
    await File(p.join(root.path, 'x32', 'srb2.pk3')).writeAsString('data'); // not executable

    final found = await LaunchSettings.findExecutables(root.path);
    expect(
      {for (final f in found) f.name: f.likelySrb2},
      {
        'ReShade_Setup': false,
        'srb2win (TSoURDt3rd_x64)': true,
        'updater': false,
        'srb2win (x32)': true,
      },
    );
  });
}
