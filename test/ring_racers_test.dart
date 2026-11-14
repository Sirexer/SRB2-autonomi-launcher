import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:srb2_autonomi_launcher/models/game.dart';
import 'package:srb2_autonomi_launcher/models/launch_config.dart';
import 'package:srb2_autonomi_launcher/models/mod_item.dart';
import 'package:srb2_autonomi_launcher/models/srb2_server.dart';
import 'package:srb2_autonomi_launcher/services/launch_settings.dart';
import 'package:srb2_autonomi_launcher/services/platform_utils.dart';
import 'package:srb2_autonomi_launcher/services/servers_store.dart';
import 'package:srb2_autonomi_launcher/services/srb2_query.dart';

// --- Пакеты как у сервера Ring Racers 2.4 (src/d_clisrv.h, ATTRPACK) ---

const helloMd5 = '5d41402abc4b2a76b9719d911017c592';

List<int> _md5Bytes(String hex) =>
    [for (var i = 0; i < 32; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];

/// Запись PutFileNeeded в Ring Racers: status, size, name\0, md5 — без байта folder.
/// willsend: 1 — отдаст, 2 — скачивание выключено, 0 — слишком большой.
List<int> kartFileEntry(String name, int size, String md5, {int willSend = 1}) => [
      1 + (willSend << 4),
      size & 0xFF, (size >> 8) & 0xFF, (size >> 16) & 0xFF, (size >> 24) & 0xFF,
      ...latin1.encode(name), 0,
      ..._md5Bytes(md5),
    ];

void _put(Uint8List b, int offset, List<int> bytes) => b.setRange(offset, offset + bytes.length, bytes);

/// serverinfo_pak Ring Racers; смещения — offsetof упакованной структуры.
Uint8List fakeKartServerInfo({int kartvars = 0x41, int pwr = 5000, required List<List<int>> files}) {
  final fileBytes = [for (final f in files) ...f];
  final b = Uint8List(404 + fileBytes.length);
  b[0] = 255;
  b[1] = 0; // PACKETVERSION
  _put(b, 2, ascii.encode('RingRacers'));
  b[18] = 2; // VERSION
  b[19] = 4; // SUBVERSION
  _put(b, 20, [0xDE, 0xAD, 0xBE, 0xEF]); // commit
  b[24] = 5; // игроков
  b[25] = 16;
  b[26] = 0;
  _put(b, 27, ascii.encode('Race'));
  b[51] = 1; // modifiedgame
  b[52] = 0; // cheats
  b[53] = kartvars; // gamespeed 1 + dedicated
  b[54] = files.length;
  final bd = ByteData.sublistView(b);
  bd.setUint32(59, 35 * 90, Endian.little); // leveltime
  _put(b, 63, [0x85, ...ascii.encode('Kart '), 0x80, ...ascii.encode('Krew')]);
  _put(b, 95, ascii.encode('Robotnik Coaster'));
  b[144] = 0; // actnum
  b[145] = 0; // iszone
  _put(b, 146, ascii.encode('https://mirror.example/rr/'));
  bd.setInt16(402, pwr, Endian.little);
  b.setRange(404, b.length, fileBytes);
  return Srb2Codec.buildPacket(NetProtocol.ringRacers.ptServerInfo, b);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('protocol', () {
    test('askinfo uses the Ring Racers version byte', () {
      final pkt = Srb2Codec.askInfo(7, NetProtocol.ringRacers);
      expect(pkt[6], 12);
      expect(pkt[8], 2);
    });

    test('serverinfo layout, kart file entries and willsend codes', () {
      final info = Srb2Codec.parseServerInfo(
        fakeKartServerInfo(files: [
          kartFileEntry('KR_Track.pk3', 4096, helloMd5),
          kartFileEntry('private.pk3', 10, helloMd5, willSend: 2),
          kartFileEntry('huge.pk3', 1 << 30, helloMd5, willSend: 0),
        ]),
        NetProtocol.ringRacers,
      )!;
      expect(info.application, 'RingRacers');
      expect(info.versionString, '2.4');
      expect(info.isCompatible, isTrue);
      expect(info.name, 'Kart Krew');
      expect(info.players, 5);
      expect(info.maxPlayers, 16);
      expect(info.gametype, 'Race');
      expect(info.modified, isTrue);
      expect(info.isDedicated, isTrue);
      expect(info.kartSpeed, 1);
      expect(info.mapName, '');
      expect(info.fullMapTitle, 'Robotnik Coaster');
      expect(info.levelTimeTics ~/ 35, 90);
      expect(info.httpSource, 'https://mirror.example/rr/');
      expect(info.avgPowerLevel, 5000);
      expect(info.files.map((f) => f.name), ['KR_Track.pk3', 'private.pk3', 'huge.pk3']);
      expect(info.files.first.size, 4096);
      expect(info.files.first.md5, helloMd5);
      expect(info.files.map((f) => f.willSend), [ServerFileSend.yes, ServerFileSend.no, ServerFileSend.tooLarge]);
      expect(info.files.any((f) => f.isFolder), isFalse);
    });

    test('power level -1 means disabled; SRB2 packets are not Ring Racers', () {
      final info = Srb2Codec.parseServerInfo(fakeKartServerInfo(pwr: -1, files: []), NetProtocol.ringRacers)!;
      expect(info.avgPowerLevel, isNull);
      // Разбор как SRB2: другой PACKETVERSION — отказ.
      expect(Srb2Codec.parseServerInfo(fakeKartServerInfo(files: [])), isNull);
    });

    test('other version is not compatible', () {
      final pkt = fakeKartServerInfo(files: []);
      pkt[8 + 19] = 3; // SUBVERSION 3 → 2.3
      final info = Srb2Codec.parseServerInfo(Srb2Codec.buildPacket(13, pkt.sublist(8)), NetProtocol.ringRacers)!;
      expect(info.versionString, '2.3');
      expect(info.isCompatible, isFalse);
    });

    test('bots: player list minus human count', () {
      const info = ServerInfo(
        packetVersion: 0, application: 'RingRacers', version: 2, subversion: 4, players: 0, maxPlayers: 15,
        refuseReason: 0, gametype: 'Race', modified: false, cheats: false, flags: 0, levelTimeTics: 0,
        nameSpans: [], name: 'x', mapName: '', mapTitle: '', actNum: 0, isZone: false, httpSource: '', files: [],
      );
      ServerPlayer pl(int n) => ServerPlayer(num: n, name: 'P$n', team: 0, skin: 255, score: 0, secondsInServer: 0);
      final allBots = ServerQueryResult(info: info, players: [for (var i = 0; i < 6; i++) pl(i)]);
      expect(allBots.botCount, 6);
      expect(allBots.allBots, isTrue);
      final mixed = ServerQueryResult(
        info: ServerInfo(
          packetVersion: 0, application: 'RingRacers', version: 2, subversion: 4, players: 2, maxPlayers: 15,
          refuseReason: 0, gametype: 'Race', modified: false, cheats: false, flags: 0, levelTimeTics: 0,
          nameSpans: const [], name: 'x', mapName: '', mapTitle: '', actNum: 0, isZone: false, httpSource: '',
          files: const [],
        ),
        players: [pl(0), pl(1), pl(2)],
      );
      expect(mixed.botCount, 1);
      expect(mixed.allBots, isFalse);
    });

        test('ringracers:// addresses', () {
      expect(parseServerAddress('ringracers://1.2.3.4:5030'), ('1.2.3.4', 5030));
    });

    test('UDP query of a fake Ring Racers server', () async {
      final server = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((event) {
        if (event != RawSocketEvent.read) return;
        final d = server.receive();
        if (d == null) return;
        final pkt = Uint8List.fromList(d.data);
        if (Srb2Codec.packetType(pkt) == 12 && pkt[8] == 2) {
          server.send(fakeKartServerInfo(files: [kartFileEntry('a.pk3', 1, helloMd5)]), d.address, d.port);
        }
      });
      final client = Srb2QueryClient(protocol: NetProtocol.ringRacers);
      addTearDown(client.close);
      final result = await client.query('127.0.0.1', server.port);
      expect(result.error, isNull);
      expect(result.info!.name, 'Kart Krew');
      expect(result.info!.files.single.name, 'a.pk3');
    });
  });

  group('master server', () {
    test('Kart Krew list: address port contact', () {
      const body = '1.2.3.4 5029 discord: someone\n'
          '2001:db8::1 5030\n'
          '\n';
      final list = MasterServerParser.parseKartServers(body, version: '2.4');
      expect(list.map((e) => '${e.host}:${e.port}'), ['1.2.3.4:5029', '2001:db8::1:5030']);
      expect(list.first.contact, 'discord: someone');
      expect(list.first.title, '');
      expect(list.first.version, '2.4');
      expect(MasterServerParser.parseKartServers('<html>error</html>'), isEmpty);
    });

    test('server list URLs per game', () {
      expect(Games.drrr.serversUrl('https://ms.kartkrew.org/ms/api'),
          'https://ms.kartkrew.org/ms/api/games/RingRacers/13/servers?v=2.2');
      expect(Games.srb2.serversUrl('https://ds.ms.srb2.org/MS/0/'), 'https://ds.ms.srb2.org/MS/0/servers');
    });
  });

  group('game updates', () {
    test('version answer and URLs', () {
      final r = GameDef.parseVersion('57 2.2.16\n')!;
      expect(r.number, 57);
      expect(r.name, '2.2.16');
      expect(GameDef.parseVersion('<html>'), isNull);
      expect(Games.srb2.versionUrl('https://ds.ms.srb2.org/MS/0'), 'https://ds.ms.srb2.org/MS/0/versions/18');
      expect(Games.drrr.versionUrl('https://ms.kartkrew.org/ms/api/'),
          'https://ms.kartkrew.org/ms/api/games/RingRacers/version?v=2.2');
      expect(Games.drrr.serversUrl('https://ms.example', modVersion: 14),
          'https://ms.example/games/RingRacers/14/servers?v=2.2');
    });

    test('a newer release is detected and its server list is merged', () async {
      SharedPreferences.setMockInitialValues({});
      // TestWidgetsFlutterBinding подменяет HttpClient (всегда 400) — нужен настоящий.
      final overrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = overrides);
      final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => http.close(force: true));
      http.listen((req) {
        final body = switch (req.uri.path) {
          '/ms/games/RingRacers/version' => '14 2.5\n',
          '/ms/games/RingRacers/13/servers' => '127.0.0.1 1 old\n',
          '/ms/games/RingRacers/14/servers' => '127.0.0.1 2 new\n',
          _ => null,
        };
        req.response.statusCode = body == null ? 404 : 200;
        req.response.write(body ?? '');
        req.response.close();
      });

      final store = ServersStore(Games.drrr);
      addTearDown(store.dispose);
      await store.load();
      await store.setMasters(['http://127.0.0.1:${http.port}/ms']);
      await store.refresh();
      expect(store.gameUpdated, isTrue);
      expect(store.latestRelease!.name, '2.5');
      expect(store.masterList.map((e) => e.port).toSet(), {1, 2});
    });
  });

  group('manifest games', () {
    ModItem parse(Map<String, dynamic> j) => ModItem.fromJson(j, source: 'repo');

    test('default is srb2, addon-level list, per-file override, aliases', () {
      expect(parse({'name': 'Old', 'files': [{'name': 'a.pk3'}]}).files.single.games, ['srb2']);

      final mod = parse({
        'name': 'Both',
        'games': ['SRB2', 'RingRacers'],
        'files': [
          {'name': 'shared.pk3', 'version': '1'},
          {'name': 'kart_only.pk3', 'version': '1', 'games': 'drrr'},
          {'name': 'srb2_only.pk3', 'version': '2', 'games': ['srb2']},
        ],
      });
      // Версии идут от новой к старой — ищем файлы по имени.
      List<String> gamesOf(String name) => mod.files.firstWhere((f) => f.name == name).games;
      expect(gamesOf('shared.pk3'), ['srb2', 'drrr']);
      expect(gamesOf('kart_only.pk3'), ['drrr']);
      expect(gamesOf('srb2_only.pk3'), ['srb2']);
      expect(mod.games, {'srb2', 'drrr'});

      final kart = mod.forGame('drrr')!;
      expect(kart.files.map((f) => f.name), ['shared.pk3', 'kart_only.pk3']);
      expect(kart.versions.map((v) => v.name), ['1']);
      expect(kart.key, mod.key);
      // Порядок — по версиям (новые первыми), поэтому сравниваем без порядка.
      expect(mod.forGame('srb2')!.files.map((f) => f.name), unorderedEquals(['shared.pk3', 'srb2_only.pk3']));
      expect(parse({'name': 'S', 'files': [{'name': 'x.pk3'}]}).forGame('drrr'), isNull);
    });

    test('uploader, with the old authors list as a fallback', () {
      expect(parse({'name': 'A', 'uploader': 'Mikhael Blur', 'authors': ['x']}).uploader, 'Mikhael Blur');
      expect(parse({'name': 'B', 'authors': ['One', 'Two']}).uploader, 'One, Two');
      expect(parse({'name': 'C'}).uploader, '');
    });

    test('unchanged addon is returned as is', () {
      final mod = parse({'name': 'S', 'files': [{'name': 'x.pk3'}]});
      expect(identical(mod.forGame('srb2'), mod), isTrue);
    });
  });

  group('launch', () {
    test('no -room for Ring Racers, its gametypes and default executable', () {
      final o = LaunchOptions()
        ..net = NetMode.host
        ..room = '33'
        ..gametype = 'Battle';
      expect(o.toArgs(game: Games.drrr), ['-server', '-gametype', 'Battle']);
      expect(o.toArgs(), ['-server', '-room', '33', '-gametype', 'Battle']);
      expect(Games.drrr.gametypes, contains('Battle'));
      expect(PlatformUtils.defaultLaunchCommand(windows: true, game: Games.drrr), 'ringracers.exe');
      expect(PlatformUtils.defaultLaunchCommand(windows: false, game: Games.drrr), 'ringracers');
    });

    test('settings of each game are stored separately', () async {
      SharedPreferences.setMockInitialValues({'srb2_launch_command': '/games/srb2/srb2win'});
      final srb2 = LaunchSettings();
      final kart = LaunchSettings(Games.drrr);
      await srb2.load();
      await kart.load();
      expect(srb2.executables.single.name, 'srb2win');
      expect(kart.executables.single.name, 'Ring Racers'); // старая команда SRB2 не переносится
      expect(kart.command, PlatformUtils.defaultLaunchCommand(game: Games.drrr));

      kart.updateOptions((o) => o.flags.add('-win'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('drrr.launch_options'), contains('-win'));
      expect(prefs.getString('launch_options'), isNull);
    });

    test('servers store uses the game masters and keys', () async {
      SharedPreferences.setMockInitialValues({'servers_masters': ['https://srb2.example/MS/0']});
      final kart = ServersStore(Games.drrr);
      addTearDown(kart.dispose);
      await kart.load();
      expect(kart.masters, Games.drrr.defaultMasters);
      final srb2 = ServersStore();
      addTearDown(srb2.dispose);
      await srb2.load();
      expect(srb2.masters, ['https://srb2.example/MS/0']);
    });

    test('found executables are marked by game', () async {
      final root = await Directory.systemTemp.createTemp('rr_scan_');
      addTearDown(() => root.delete(recursive: true));
      final exe = Platform.isWindows ? '.exe' : '';
      for (final name in ['ringracers$exe', 'srb2win$exe']) {
        final f = File('${root.path}${Platform.pathSeparator}$name');
        await f.writeAsString('x');
        if (!Platform.isWindows) await Process.run('chmod', ['+x', f.path]);
      }
      final found = await LaunchSettings.findExecutables(root.path, hints: Games.drrr.executableHints);
      expect({for (final f in found) f.name: f.likelySrb2}, {'ringracers': true, 'srb2win': false});
    });
  });
}
