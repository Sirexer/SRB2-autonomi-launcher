import 'dart:ffi' show Abi;

import 'package:flutter_test/flutter_test.dart';
import 'package:srb2_autonomi_launcher/models/mod_item.dart';
import 'package:srb2_autonomi_launcher/services/platform_utils.dart';

void main() {
  group('splitCommandLine', () {
    test('plain command', () {
      expect(PlatformUtils.splitCommandLine('srb2', windows: false), ['srb2']);
      expect(
        PlatformUtils.splitCommandLine('  flatpak   run org.srb2.SRB2 ', windows: false),
        ['flatpak', 'run', 'org.srb2.SRB2'],
      );
      expect(PlatformUtils.splitCommandLine('   ', windows: false), isEmpty);
    });

    test('Windows path with spaces in quotes, backslashes kept', () {
      expect(
        PlatformUtils.splitCommandLine(r'"C:\Program Files\SRB2\srb2win.exe" -opengl', windows: true),
        [r'C:\Program Files\SRB2\srb2win.exe', '-opengl'],
      );
      expect(
        PlatformUtils.splitCommandLine(r'C:\SRB2\srb2win.exe', windows: true),
        [r'C:\SRB2\srb2win.exe'],
      );
    });

    test('single quote is a normal character on Windows', () {
      expect(
        PlatformUtils.splitCommandLine(r"C:\Sonic's\srb2win.exe", windows: true),
        [r"C:\Sonic's\srb2win.exe"],
      );
    });

    test('POSIX quotes and escapes', () {
      expect(
        PlatformUtils.splitCommandLine("'/home/u/My Games/lsdl2srb2' -nosound", windows: false),
        ['/home/u/My Games/lsdl2srb2', '-nosound'],
      );
      expect(
        PlatformUtils.splitCommandLine(r'/home/u/My\ Games/srb2', windows: false),
        ['/home/u/My Games/srb2'],
      );
      expect(
        PlatformUtils.splitCommandLine(r'"say \"hi\""', windows: false),
        ['say "hi"'],
      );
    });

    test('quoteIfNeeded round-trips through splitCommandLine', () {
      const path = r'C:\Program Files\SRB2\srb2win.exe';
      expect(
        PlatformUtils.splitCommandLine(PlatformUtils.quoteIfNeeded(path), windows: true),
        [path],
      );
      expect(PlatformUtils.quoteIfNeeded('/usr/bin/srb2'), '/usr/bin/srb2');
    });
  });

  group('cleanUserPath', () {
    test('Windows: quotes, slashes and trailing separators', () {
      expect(PlatformUtils.cleanUserPath(r' "C:\Games\SRB2\" ', windows: true), r'C:\Games\SRB2');
      expect(PlatformUtils.cleanUserPath('C:/Games/SRB2/', windows: true), r'C:\Games\SRB2');
      expect(PlatformUtils.cleanUserPath(r'C:\', windows: true), r'C:\');
    });

    test('Linux: home expansion and file URIs', () {
      expect(PlatformUtils.cleanUserPath('~/.srb2/', windows: false, home: '/home/u'), '/home/u/.srb2');
      expect(PlatformUtils.cleanUserPath('~', windows: false, home: '/home/u'), '/home/u');
      expect(
        PlatformUtils.cleanUserPath('file:///home/u/My%20Games', windows: false),
        '/home/u/My Games',
      );
      expect(PlatformUtils.cleanUserPath('/home/u//srb2/./', windows: false), '/home/u/srb2');
    });

    test('empty input', () {
      expect(PlatformUtils.cleanUserPath('  ', windows: false), '');
      expect(PlatformUtils.cleanUserPath('""', windows: true), '');
    });
  });

  test('samePath ignores case and slash style on Windows only', () {
    expect(PlatformUtils.samePath(r'C:\SRB2\DOWNLOAD', 'c:/srb2/download', windows: true), isTrue);
    expect(PlatformUtils.samePath('/home/u/DOWNLOAD', '/home/u/download', windows: false), isFalse);
    expect(PlatformUtils.samePath('/home/u//DOWNLOAD/', '/home/u/DOWNLOAD', windows: false), isTrue);
  });

  test('isAddonFile', () {
    expect(PlatformUtils.isAddonFile('/x/MyMod.PK3'), isTrue);
    expect(PlatformUtils.isAddonFile('level.wad'), isTrue);
    expect(PlatformUtils.isAddonFile('readme.txt'), isFalse);
    expect(PlatformUtils.isAddonFile('pk3'), isFalse);
  });

  group('safeFileName', () {
    test('keeps normal names', () {
      expect(PlatformUtils.safeFileName('CL_Mod-v1.2.pk3'), 'CL_Mod-v1.2.pk3');
    });

    test('cannot escape the folder', () {
      expect(PlatformUtils.safeFileName('../../.bashrc'), '.bashrc');
      expect(PlatformUtils.safeFileName(r'..\..\evil.dll'), 'evil.dll');
      expect(PlatformUtils.safeFileName('/etc/passwd'), 'passwd');
      expect(PlatformUtils.safeFileName('..'), isNull);
      expect(PlatformUtils.safeFileName('mods/'), isNull);
    });

    test('Windows-invalid names', () {
      expect(PlatformUtils.safeFileName('a.pk3:stream'), 'a.pk3_stream');
      expect(PlatformUtils.safeFileName('what?.wad'), 'what_.wad');
      expect(PlatformUtils.safeFileName('mod.pk3. '), 'mod.pk3');
      expect(PlatformUtils.safeFileName('NUL.pk3'), '_NUL.pk3');
      expect(PlatformUtils.safeFileName('com1'), '_com1');
    });

    test('is applied when parsing manifests', () {
      final mod = ModItem.fromJson({
        'id': 'x',
        'files': [
          {'name': '../../../.profile', 'hash': 'h', 'md5': 'm'},
          {'hash': 'h2'},
        ],
      }, source: 'test');
      expect(mod.files.map((f) => f.name), ['.profile', 'mod_file.pk3']);
    });
  });

  test('antdAssetName matches ant-sdk release assets', () {
    expect(PlatformUtils.antdAssetName(Abi.linuxX64), 'antd-linux-amd64');
    expect(PlatformUtils.antdAssetName(Abi.linuxArm64), 'antd-linux-arm64');
    expect(PlatformUtils.antdAssetName(Abi.windowsX64), 'antd-windows-amd64.exe');
    expect(PlatformUtils.antdAssetName(Abi.windowsArm64), 'antd-windows-amd64.exe');
    expect(PlatformUtils.antdAssetName(Abi.macosArm64), 'antd-darwin-arm64');
    expect(PlatformUtils.antdAssetName(Abi.linuxRiscv64), isNull);
  });

  test('defaults per platform', () {
    expect(PlatformUtils.defaultLaunchCommand(windows: true), 'srb2win.exe');
    expect(PlatformUtils.defaultLaunchCommand(windows: false), 'srb2');
    expect(PlatformUtils.knownExecutables(windows: true), contains('srb2win.exe'));
  });
}
