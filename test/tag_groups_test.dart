import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:srb2_autonomi_launcher/services/tag_groups.dart';

void main() {
  test('built-in groups: by prefix or by the built-in list, shown without the prefix', () {
    final g = TagGrouping.builtIn;
    expect(g.of('source:ws').id, 'source');
    expect(g.of('section:blue_sphere').id, 'section');
    expect(g.of('mapstyle:oldschool').id, 'mapstyle');
    expect(g.of('gametype:ctf').id, 'gametype');
    expect(g.of('content:maps').id, 'content');
    expect(g.of('lua').id, 'content');
    expect(g.of('single_map').id, 'maps');
    expect(g.of('port').id, 'main');
    expect(g.of('clear_port').id, 'port');
    expect(g.of('featured').id, 'main');
    expect(g.of('something').id, 'other');
    expect(g.of('weird:prefix').id, 'other');

    expect(g.label('source:ws'), 'ws');
    expect(g.label('lua'), 'lua');
    expect(g.label('weird:prefix'), 'weird:prefix');
    expect((g.qualified('lua'), g.qualified('Source:WS'), g.qualified('xyz')),
        ('content:lua', 'source:ws', 'other:xyz'));

    final grouped = g.group(['lua', 'source:ws', 'xyz', 'maps', 'featured'], (t) => t);
    expect([for (final (gr, l) in grouped) '${gr.id}=${l.join(',')}'],
        ['main=featured', 'source=source:ws', 'content=lua,maps', 'other=xyz']);
  });

  test('tag_groups from repositories: listed tags only, merged by id, order of repositories', () {
    final a = jsonEncode({
      'tag_groups': [
        {'id': 'Source', 'color': '#4FC3F7', 'tags': ['source:ws', 'Source:MB']},
        {'id': 'my_group', 'name': ' My Mods ', 'color': 'nope', 'tags': ['lua', 'source:ws']},
      ],
      'mods': [],
    });
    final b = jsonEncode({
      'tag_groups': [
        {'id': 'source', 'color': '#000000', 'tags': ['source:gb']},
        {'id': 'content', 'color': '#80FF0000', 'tags': ['maps', 'lua']},
      ],
    });
    final g = TagGrouping.fromManifests([a, 'not json', b, jsonEncode({'mods': []})]);
    expect(g.fromRepositories, isTrue);
    expect([for (final x in g.groups) x.id], ['source', 'my_group', 'content', 'other']);
    expect(g.byId('source')!.color, 0xFF4FC3F7); // цвет — из первого репозитория
    expect(g.byId('my_group')!.color, TagGrouping.other.color); // не цвет — серый
    expect(g.byId('content')!.color, 0x80FF0000);
    expect(g.of('source:mb').id, 'source');
    expect(g.of('source:gb').id, 'source');
    expect(g.of('lua').id, 'my_group'); // тег — в первой группе, где он перечислен
    expect(g.of('source:sb').id, 'other'); // не перечислен — «Другие», по приставке не угадывается
    expect(g.label('source:ws'), 'ws');
    expect(g.label('lua'), 'lua');
    // С группой — для поиска и карточки аддона.
    expect((g.qualified('source:ws'), g.qualified('lua'), g.qualified('source:sb')),
        ('source:ws', 'my_group:lua', 'other:source:sb'));
    expect(g.groupOfQualified('my_group:lua').id, 'my_group');
    expect(g.groupOfQualified('nope:x').id, 'other');
    // Названия — только из репозитория: name, иначе id.
    expect([for (final x in g.groups) x.title], ['source', 'My Mods', 'content', 'other']);
    expect(const TagGroup('section', 0, {}, 'WS Section').title, 'WS Section');
    expect(const TagGroup('fan_games', 0).title, 'fan_games');

    // Ни одного tag_groups — встроенные группы.
    expect(identical(TagGrouping.fromManifests([jsonEncode({'mods': []})]), TagGrouping.builtIn), isTrue);
  });

  test('parseColor', () {
    expect(TagGrouping.parseColor('#4FC3F7'), 0xFF4FC3F7);
    expect(TagGrouping.parseColor('4fc3f7'), 0xFF4FC3F7);
    expect(TagGrouping.parseColor('#804FC3F7'), 0x804FC3F7);
    expect(TagGrouping.parseColor('#FFF'), isNull);
    expect(TagGrouping.parseColor(12), isNull);
  });
}
