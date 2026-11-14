import 'package:flutter_test/flutter_test.dart';
import 'package:srb2_autonomi_launcher/services/search_query.dart';

bool groups(String g) => const {'source', 'content', 'main', 'other'}.contains(g);

void main() {
  test('words: spaces split, quotes join, signs stay', () {
    expect(searchTokens('sonic  -nsfw'), ['sonic', '-nsfw']);
    expect(searchTokens('"sonic adventure" -"big pack" x'), ['sonic adventure', '-big pack', 'x']);
    expect(searchTokens('"content:original music" -main:port'), ['content:original music', '-main:port']);
    expect(searchTokens('  '), isEmpty);
    expect(searchTokens('"unclosed tag'), ['unclosed tag']);
  });

  test('query: words search everywhere but tags, group:tag is an exact tag filter', () {
    final q = AddonQuery.parse('Sonic -hide Source:Workshop -main:hidden "content:original music" re:zero - x:',
        isTagGroup: groups);
    expect(q.words, ['sonic', 're:zero', 'x:']); // re — не группа, x: — без тега
    expect(q.excludedWords, ['hide']);
    expect(q.tags, {'source:workshop', 'content:original music'});
    expect(q.excludedTags, {'main:hidden'});
    expect(AddonQuery.parse('').isEmpty, isTrue);
    // Без групп двоеточие — просто слово.
    expect(AddonQuery.parse('source:workshop').words, ['source:workshop']);

    // Тег — точное совпадение, не часть другого тега.
    final port = AddonQuery.parse('main:port', isTagGroup: groups);
    expect(port.matchesTags(['Main:Port', 'content:maps']), isTrue);
    expect(port.matchesTags(['main:portal']), isFalse);
    expect(AddonQuery.parse('-main:hidden', isTagGroup: groups).matchesTags(['main:hidden']), isFalse);
    expect(AddonQuery.parse('-main:hidden', isTagGroup: groups).matchesTags(['main:hide']), isTrue);

    // -слово не смотрит на теги.
    final noHide = AddonQuery.parse('-hidden', isTagGroup: groups);
    expect(noHide.matchesTags(['main:hidden']), isTrue);
    expect(noHide.matchesWords((w) => 'Hidden Palace'.toLowerCase().contains(w)), isFalse);
    expect(noHide.matchesWords((w) => 'Greenflower'.toLowerCase().contains(w)), isTrue);

    // -слово можно искать уже, чем слово: «-maps» не прячет аддоны только
    // из-за категории Maps, а «maps» её находит.
    bool name(String w) => 'Greenflower Remix'.toLowerCase().contains(w);
    bool nameOrCategory(String w) => name(w) || 'maps'.contains(w);
    expect(AddonQuery.parse('-maps').matchesWords(nameOrCategory, excluded: name), isTrue);
    expect(AddonQuery.parse('maps').matchesWords(nameOrCategory, excluded: name), isTrue);
    expect(AddonQuery.parse('-remix').matchesWords(nameOrCategory, excluded: name), isFalse);
  });

  test('tag buttons and the tag panel: add, flip, cycle, remove', () {
    expect(addSearchTag('', 'main:port'), 'main:port');
    expect(addSearchTag('sonic', 'Main:Port'), 'sonic main:port');
    expect(addSearchTag('sonic main:port', 'main:port', exclude: true), 'sonic -main:port'); // знак меняется
    expect(addSearchTag('main:port', 'main:port'), 'main:port'); // без повторов
    expect(addSearchTag('port', 'main:port'), 'port main:port'); // слово port — не тег
    expect(addSearchTag('x', 'content:original music', exclude: true), 'x -"content:original music"');
    expect(AddonQuery.parse(addSearchTag('x', 'content:original music', exclude: true), isTagGroup: groups).excludedTags,
        {'content:original music'});

    expect(searchTagSign('sonic main:port', 'Main:Port'), 1);
    expect(searchTagSign('sonic -main:port', 'main:port'), -1);
    expect(searchTagSign('sonic port', 'main:port'), 0);
    expect(removeSearchTag('sonic -main:port x', 'main:port'), 'sonic x');

    var q = '';
    q = cycleSearchTag(q, 'main:hidden');
    expect(q, 'main:hidden');
    q = cycleSearchTag(q, 'main:hidden');
    expect(q, '-main:hidden');
    q = cycleSearchTag(q, 'main:hidden');
    expect(q, '');
  });

  test('suggestions: the typed word is replaced by the whole group:tag', () {
    expect(currentSearchToken('sonic wor'), (6, 'wor'));
    expect(currentSearchToken('sonic '), (6, ''));
    expect(currentSearchToken('x "content:original mu'), (2, '"content:original mu'));
    expect(completeSearchTag('sonic wor', 'source:workshop'), 'sonic source:workshop ');
    expect(completeSearchTag('sonic -hid', 'main:hidden'), 'sonic -main:hidden ');
    expect(completeSearchTag('x "content:orig', 'content:original music'), 'x "content:original music" ');
    expect(completeSearchTag('main:port po', 'main:port'), 'main:port ');
  });
}
