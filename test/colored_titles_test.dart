import 'package:flutter_test/flutter_test.dart';
import 'package:srb2_autonomi_launcher/models/srb2_server.dart';
import 'package:srb2_autonomi_launcher/services/characters.dart';
import 'package:srb2_autonomi_launcher/ui/srb2_text.dart';

void main() {
  test('SOC text colors: ^N codes, \XX bytes, raw codes', () {
    final caret = srb2TitleSpans('^4My level');
    expect([for (final s in caret) (s.text, s.color)], [('My level', 4)]);
    final mixed = srb2TitleSpans('^2Golden^0 Coast ^^ \\82x\\80');
    expect([for (final s in mixed) (s.text, s.color)], [('Golden', 2), (' Coast ^ ', 0), ('x', 2)]);
    final raw = srb2TitleSpans('\x85Red\x80 Zone');
    expect([for (final s in raw) (s.text, s.color)], [('Red', 5), (' Zone', 0)]);
    expect(srb2TitleSpans('^Bpear'), [isA<Srb2TextSpan>().having((s) => s.color, 'color', 11)]);
    expect(srb2PlainTitle('^4My level'), 'My level');
    // Текст лаунчера (кириллица) с названием из SOC — буквы не теряются.
    expect(srb2PlainTitle('Кубок ^2Ring'), 'Кубок Ring');
    // «^» без цифры — конец цвета, пробел после него остаётся.
    final hint = srb2TitleSpans('the ^2yellow^ room');
    expect([for (final s in hint) (s.text, s.color)], [('the ', 0), ('yellow', 2), (' room', 0)]);
    expect([for (final s in srb2TitleSpans(' Plain Zone ')) (s.text, s.color)], [('Plain Zone', 0)]);
    expect(srb2TitleSpans(''), isEmpty);
  });

  test('server map title with colors, ZONE and act', () {
    const info = ServerInfo(
      packetVersion: 0,
      application: 'SRB2',
      version: 202,
      subversion: 15,
      players: 0,
      maxPlayers: 8,
      refuseReason: 0,
      gametype: 'Co-op',
      modified: false,
      cheats: false,
      flags: 0,
      levelTimeTics: 0,
      nameSpans: [],
      name: 'x',
      mapName: 'MAP01',
      mapTitle: 'Greenflower',
      mapTitleSpans: [Srb2TextSpan('Green', 3), Srb2TextSpan('flower', 0)],
      actNum: 1,
      isZone: true,
      httpSource: '',
      files: [],
    );
    expect(info.fullMapTitle, 'Greenflower ZONE 1');
    expect([for (final s in info.fullMapTitleSpans) (s.text, s.color)],
        [('Green', 3), ('flower', 0), (' ZONE 1', 0)]);
    expect(info.withFiles(const []).mapTitleSpans.length, 2);
  });

  test('character descriptions from SOC_PLAY (PlayerText up to #)', () {
    const soc = '''
# comment
Character 0
PicName = SONCCHAR
Status = 32
SkinName = Sonic
PlayerText = Fast and ^2agile^0.
Spin dash away!#

Character 1
SkinName = tails
PlayerText = Flies.#
DisplayName = Tails

Level 1
LevelName = Not a character
''';
    final d = CharacterScanner.parseSocDescriptions(soc);
    expect(d['sonic'], 'Fast and ^2agile^0.\nSpin dash away!');
    expect(Srb2Text.plain(srb2TitleSpans(d['sonic']!.split('\n').first)), 'Fast and agile.');
    expect(d['tails'], 'Flies.');
    expect(d.length, 2);
  });
}
