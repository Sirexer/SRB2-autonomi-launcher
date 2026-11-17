import 'package:flutter_test/flutter_test.dart';
import 'package:srb2_autonomi_launcher/models/game.dart';
import 'package:srb2_autonomi_launcher/models/mod_item.dart';
import 'package:srb2_autonomi_launcher/models/srb2_server.dart';
import 'package:srb2_autonomi_launcher/services/custom_games.dart';

void main() {
  final blankart = {
    'id': 'srb2blankart',
    'name': 'BlanKart',
    'full_name': 'SRB2 BlanKart',
    'base': 'srb2kart',
    'version': '2.0',
    'protocol': 'blankart',
    'masters': ['https://ms.blankart.cc/MS/1'],
    'mod_version': 12,
    'main_file': 'main.pk3',
    'executables': {'windows': ['blankart.exe'], 'linux': ['blankart']},
    'linux_data_folders': ['.srb2kart-v2'],
    'base_addons': true,
  };

  test('a custom game takes what it does not set from its base', () {
    final g = Games.fromDefinition(blankart);
    expect((g.id, g.name, g.fullName, g.engine, g.isCustom), ('srb2blankart', 'BlanKart', 'SRB2 BlanKart', 'srb2kart', true));
    expect(g.protocol, same(NetProtocol.blankart));
    expect(g.masterApi, MasterApi.kart); // от SRB2Kart
    expect(g.serversUrl('https://ms.blankart.cc/MS/1'), 'https://ms.blankart.cc/MS/1/games/SRB2Kart/12/servers?v=2.2');
    expect((g.mainFile, g.windowsCommand, g.linuxCommand), ('main.pk3', 'blankart.exe', 'blankart'));
    expect(g.downloadPath, ['DOWNLOAD']);
    expect(g.gametypes, Games.srb2kart.gametypes);
    expect(g.encoreCvar, 'kartencore'); // поведение — как у основы
    expect(g.skinColors, same(Games.srb2kart.skinColors));
    expect(g.hasProgress, isFalse);
    expect(g.key('folder_path'), 'game.srb2blankart.folder_path'); // свои настройки
    expect(g.addonBase, 'srb2kart');
    expect(g.iconAsset, 'assets/games/srb2kart.png');
  });

  test('bad definitions are explained', () {
    String? error(Map<String, dynamic> d) {
      try {
        Games.fromDefinition(d);
        return null;
      } on FormatException catch (e) {
        return e.message;
      }
    }

    expect(error({...blankart, 'id': 'srb2kart'}), contains('built-in'));
    expect(error({...blankart, 'id': 'Bad Id'}), contains('"id"'));
    expect(error({...blankart, 'base': 'doom'}), contains('"base"'));
    expect(error({...blankart, 'protocol': 'nope'}), contains('protocol'));
    expect(error({...blankart, 'name': ''}), contains('"name"'));
    expect(error(blankart), isNull);
  });

  test('a file holds one game, a list or {"games": [...]}', () {
    expect(CustomGames.parse('{"id": "a", "name": "A", "base": "srb2"}').single['id'], 'a');
    expect(CustomGames.parse('[{"id": "a"}, {"id": "b"}]').length, 2);
    expect(CustomGames.parse('{"games": [{"id": "a"}, {"id": "b"}, 5]}').length, 2);
    expect(() => CustomGames.parse('[]'), throwsFormatException);
  });

  test('registry: custom games are found by id; disabled ones are not offered', () {
    final g = Games.fromDefinition(blankart);
    Games.custom = [g];
    Games.disabled = {'drrr'};
    addTearDown(() {
      Games.custom = [];
      Games.disabled = {};
    });
    expect(Games.find('SRB2BlanKart'), same(g));
    expect(Games.enabled.map((x) => x.id), ['srb2', 'srb2legacy', 'srb2kart', 'srb2blankart']);
    Games.disabled.add('srb2');
    expect(Games.isEnabled(Games.srb2), isTrue); // SRB2 не выключается
  });

  test('base_addons: the addons of the base game are shown too', () {
    final mod = ModItem.fromJson({
      'id': '1',
      'name': 'Kart pack',
      'files': [
        {'name': 'k.pk3', 'version': '1', 'hash': 'h', 'md5': 'm', 'games': ['srb2kart']},
      ],
    }, source: 'Hub');
    expect(mod.forGame('srb2blankart'), isNull);
    expect(mod.forGame('srb2blankart', orBase: 'srb2kart'), isNotNull);
  });
}
