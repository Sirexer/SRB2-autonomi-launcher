import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:srb2_autonomi_launcher/models/mod_item.dart';
import 'package:srb2_autonomi_launcher/models/srb2_server.dart';
import 'package:srb2_autonomi_launcher/services/addon_paths.dart';
import 'package:srb2_autonomi_launcher/services/manifest_service.dart';

void main() {
  group('manifest versions', () {
    test('games: one for all versions or per version; a file\'s own games win', () {
      Map<String, dynamic> file(String v, [List<String>? games]) =>
          {'name': 'F_$v.pk3', 'version': v, 'hash': v, 'md5': v, 'games': ?games};
      final mod = ModItem.fromJson({
        'id': '1',
        'name': 'FUREN Project',
        'games': {
          '2.0.2': ['srb2'],
          '2.0.3': ['SRB2', 'RingRacers'],
        },
        'files': [file('2.0.1'), file('2.0.2'), file('2.0.3'), file('2.0.4'), file('2.0.5', ['srb2kart'])],
      }, source: 'Hub');
      List<String> gamesOf(String v) => mod.files.firstWhere((f) => f.version == v).games;
      expect(gamesOf('2.0.1'), ['srb2']); // старее всех записей — ближайшая новая
      expect(gamesOf('2.0.2'), ['srb2']);
      expect(gamesOf('2.0.3'), ['srb2', 'drrr']);
      expect(gamesOf('2.0.4'), ['srb2', 'drrr']); // своей записи нет — от 2.0.3
      expect(gamesOf('2.0.5'), ['srb2kart']); // у файла свои
      expect([for (final v in mod.forGame('drrr')!.versions) v.name], ['2.0.4', '2.0.3']);
      expect([for (final v in mod.forGame('srb2')!.versions) v.name], ['2.0.4', '2.0.3', '2.0.2', '2.0.1']);

      // Как раньше: список для всех версий, без games — SRB2.
      final plain = ModItem.fromJson({
        'id': '2',
        'name': 'X',
        'games': ['drrr'],
        'files': [file('1.0'), file('2.0')],
      }, source: 'Hub');
      expect(plain.games, {'drrr'});
      expect(ModItem.fromJson({'id': '3', 'name': 'Y', 'files': [file('1.0')]}, source: 'Hub').games, {'srb2'});
    });

    test('tags, uploader and description: one for all versions or per version', () {
      Map<String, dynamic> file(String v) => {'name': 'F_$v.pk3', 'version': v, 'hash': v, 'md5': v};
      final mod = ModItem.fromJson({
        'id': '1',
        'name': 'FUREN Project',
        'uploader': ['Mikhael Blur'],
        'description': 'Same text',
        'tags': {
          '2.0.2': ['Workshop', 'maps'],
          '2.0.3': ['workshop', 'maps', 'lol'],
        },
        'files': [file('2.0.1'), file('2.0.2'), file('2.0.3'), file('2.0.10')],
      }, source: 'Hub');
      // Последняя версия (2.0.10) своих тегов не имеет — от ближайшей старой (2.0.3).
      expect(mod.version, '2.0.10');
      expect(mod.tags, ['workshop', 'maps', 'lol']);
      expect(mod.tagsFor('2.0.2'), ['workshop', 'maps']);
      expect(mod.tagsFor('2.0.1'), ['workshop', 'maps']); // старее всех записей — ближайшая новая
      expect((mod.uploader, mod.uploaderFor('2.0.2')), ('Mikhael Blur', 'Mikhael Blur'));
      expect(mod.descriptionFor('2.0.1'), 'Same text');
      // forGame сохраняет записи по версиям.
      expect(mod.forGame('srb2')!.tagsFor('2.0.2'), ['workshop', 'maps']);

      final perVersion = ModItem.fromJson({
        'id': '2',
        'name': 'X',
        'uploader': {'1.0': 'Old Person', '2.0': ['A', 'B']},
        'description': {'1.0': 'old', '2.0': 'new'},
        'tags': ['plain'],
        'files': [file('1.0'), file('2.0')],
      }, source: 'Hub');
      expect((perVersion.uploader, perVersion.uploaderFor('1.0')), ('A, B', 'Old Person'));
      expect((perVersion.description, perVersion.descriptionFor('1.0')), ('new', 'old'));
      expect(perVersion.tagsFor('1.0'), ['plain']);
    });

    test('new format: version and changelog per file, newest first', () {
      final mod = ModItem.fromJson({
        'id': 'knockout',
        'name': 'KNOCKOUT',
        'files': [
          {'name': 'CL_Knockout-V1.4a(Demo).pk3', 'version': 'V1.4a(Demo)', 'hash': 'a', 'md5': 'AA', 'changelog': 'first'},
          {'name': 'CL_Knockout-V1.4b(Demo).pk3', 'version': 'V1.4b(Demo)', 'hash': 'b', 'md5': 'bb', 'changelog': 'fixes'},
        ],
      }, source: 'Hub');
      expect(mod.versions.map((v) => v.name), ['V1.4b(Demo)', 'V1.4a(Demo)']);
      expect(mod.version, 'V1.4b(Demo)');
      expect(mod.changelog, 'fixes');
      expect(mod.hasSeveralVersions, isTrue);
      expect(mod.versionNamed('V1.4a(Demo)')!.files.single.md5, 'aa'); // md5 в нижнем регистре
      expect(mod.files, hasLength(2));
    });

    test('several files with the same version form one version', () {
      final mod = ModItem.fromJson({
        'id': 'pack',
        'name': 'Resource Pack',
        'files': [
          {'name': 'SL_WS_Resource_Pack_v3.pk3', 'version': '3.0', 'hash': 'x', 'md5': '1'},
          {'name': 'Ex_TestMap.wad', 'version': '3.0', 'hash': 'y', 'md5': '2', 'changelog': 'test map'},
          {'name': 'SL_WS_Resource_Pack_v2.pk3', 'version': '2.10', 'hash': 'z', 'md5': '3'},
          {'name': 'SL_WS_Resource_Pack_v2_9.pk3', 'version': '2.9', 'hash': 'w', 'md5': '4'},
        ],
      }, source: 'Hub');
      expect(mod.versions.map((v) => v.name), ['3.0', '2.10', '2.9']); // 2.10 > 2.9
      expect(mod.latest!.files.map((f) => f.name), ['SL_WS_Resource_Pack_v3.pk3', 'Ex_TestMap.wad']);
      expect(mod.latest!.changelog, 'test map'); // первый непустой
    });

    test('old format: version and changelog of the addon apply to its files', () {
      final mod = ModItem.fromJson({
        'id': 'furen',
        'name': 'FUREN Project',
        'version': '2.0.2',
        'changelog': 'idk',
        'files': [
          {'name': 'SL_FurenProject_v2.0.2.pk3', 'hash': 'h', 'md5': 'm', 'size': 17258409},
        ],
      }, source: 'Hub');
      expect(mod.versions.single.name, '2.0.2');
      expect(mod.versions.single.changelog, 'idk');
      expect(mod.files.single.version, '2.0.2');
      expect(mod.hasSeveralVersions, isFalse);
    });

    test('no version at all', () {
      final mod = ModItem.fromJson({
        'id': 'x',
        'name': 'X',
        'files': [
          {'name': 'x.pk3', 'hash': 'h', 'md5': 'm'},
        ],
      }, source: 'Hub');
      expect(mod.version, '');
      expect(mod.latest!.label, 'Unversioned');
    });

    test('whole manifest in the new format parses', () {
      const json = '''
      {"index_version": 2, "repository_name": "Hub", "mods": [
        {"id": "k", "name": "KNOCKOUT", "files": [
          {"name": "a.pk3", "version": "1.0", "hash": "h1", "md5": "m1", "size": 1, "changelog": "c1"},
          {"name": "b.pk3", "version": "1.1", "hash": "h2", "md5": "m2", "size": 2, "changelog": "c2"}
        ]}
      ]}''';
      final mods = ManifestService.parseMainIndex(json, sourceName: 'Hub');
      expect(mods.single.versions.map((v) => v.changelog), ['c2', 'c1']);
    });
  });

  test('version folders: DOWNLOAD/<addon>/<version>/<file>', () {
    final mod = ModItem.fromJson({
      'id': 'k',
      'name': 'KNOCKOUT',
      'files': [
        {'name': 'CL_Knockout.pk3', 'version': 'V1.4b(Demo)', 'hash': 'h', 'md5': 'm'},
        {'name': 'loose.pk3', 'hash': 'h', 'md5': 'm2'},
      ],
    }, source: 'Hub');
    final dl = p.join('games', 'srb2', 'DOWNLOAD');
    final versioned = mod.versionNamed('V1.4b(Demo)')!.files.single;
    expect(AddonPaths.target(dl, mod, versioned), p.join(dl, 'KNOCKOUT', 'V1.4b(Demo)', 'CL_Knockout.pk3'));
    expect(
      AddonPaths.target(dl, mod, versioned, fileName: 'server_name.pk3'),
      p.join(dl, 'KNOCKOUT', 'V1.4b(Demo)', 'server_name.pk3'),
    );
    expect(AddonPaths.candidates(dl, mod, versioned).last, p.join(dl, 'CL_Knockout.pk3'));
    final loose = mod.versionNamed('')!.files.single;
    expect(AddonPaths.target(dl, mod, loose), p.join(dl, 'KNOCKOUT', 'loose.pk3'));

    final odd = ModItem.fromJson({
      'id': 'odd',
      'name': 'What?: Mod.',
      'files': [
        {'name': 'f.pk3', 'version': '../1.0', 'hash': 'h', 'md5': 'm'},
      ],
    }, source: 'Hub');
    // Имя и версия из манифеста не могут выйти за пределы DOWNLOAD.
    expect(AddonPaths.target(dl, odd, odd.files.single), p.join(dl, 'What__ Mod', '1.0', 'f.pk3'));

    // Настройка "без папок": прямо в DOWNLOAD, старое место — вторым кандидатом.
    AddonPaths.versionFolders = false;
    addTearDown(() => AddonPaths.versionFolders = true);
    expect(AddonPaths.target(dl, mod, versioned), p.join(dl, 'CL_Knockout.pk3'));
    expect(AddonPaths.candidates(dl, mod, versioned),
        [p.join(dl, 'CL_Knockout.pk3'), p.join(dl, 'KNOCKOUT', 'V1.4b(Demo)', 'CL_Knockout.pk3')]);
  });

  group('SRB2 text', () {
    List<(String, int)> spans(List<int> bytes) => [for (final s in Srb2Text.parse(bytes)) (s.text, s.color)];

    test('colour codes split the name into coloured parts', () {
      // "\x85Red \x84Blue\x80 plain"
      final bytes = [0x85, ...'Red '.codeUnits, 0x84, ...'Blue'.codeUnits, 0x80, ...' plain'.codeUnits];
      expect(spans(bytes), [('Red ', 5), ('Blue', 4), (' plain', 0)]);
    });

    test('bytes outside the SRB2 font are dropped, like in the game', () {
      expect(Srb2Text.plain(Srb2Text.parse([...'A'.codeUnits, 0xA9, 0xFF, 0x01, ...'B'.codeUnits])), 'AB');
      // Имена с экрана пользователя: "ÈVega's ÄParadise" = C3 88 ... C3 84 ...
      final vega = [0xC3, 0x88, ..."Vega's ".codeUnits, 0xC3, 0x84, ...'Paradise'.codeUnits];
      expect(spans(vega), [("Vega's ", 8), ('Paradise', 4)]);
      // "„Spleenik€.‡com" = E2 80 9E ... E2 82 AC . E2 80 A1 com
      final spleenik = [0xE2, 0x80, 0x9E, ...'Spleenik'.codeUnits, 0xE2, 0x82, 0xAC, ...'.'.codeUnits,
        0xE2, 0x80, 0xA1, ...'com'.codeUnits];
      expect(Srb2Text.plain(Srb2Text.parse(spleenik)), 'Spleenik.com');
    });

    test('whitespace around the name and empty parts are removed', () {
      expect(spans([0x20, 0x82, 0x20, ...'Hi'.codeUnits, 0x20, 0x83, 0x80]), [('Hi', 2)]);
      expect(Srb2Text.parse([0x82, 0x80]), isEmpty);
    });

    test('master server titles: percent-encoded bytes with colour codes', () {
      final list = MasterServerParser.parseServers('0\n1.2.3.4 5029 %82Gold%20Rush%80! 2.2.15\n');
      expect([for (final s in list.single.titleSpans) (s.text, s.color)], [('Gold Rush', 2), ('!', 0)]);
      expect(list.single.plainTitle, 'Gold Rush!');
    });
  });
}
