/// Строка поиска аддонов.
///
/// - `слово` — ищется в названии, категории, авторе и содержимом файлов
///   (карты, режимы, персонажи, цвета), но не в тегах;
/// - `-слово` — убрать аддоны, где оно есть (там же, кроме тегов);
/// - `группа:тег` — только аддоны с этим тегом (точное совпадение; группа —
///   из `tag_groups` репозитория, см. TagGrouping.qualified);
/// - `-группа:тег` — убрать аддоны с этим тегом;
/// - `"два слова"`, `"content:original music"` — слово или тег с пробелом.
///
/// Слово с двоеточием — тег, только если до двоеточия известная группа
/// ([AddonQuery.parse], `isTagGroup`); иначе это обычное слово.
/// Все условия должны выполняться вместе.
class AddonQuery {
  final List<String> words;
  final List<String> excludedWords;

  /// Теги вида `группа:тег` (нижний регистр).
  final Set<String> tags;
  final Set<String> excludedTags;

  const AddonQuery._(this.words, this.excludedWords, this.tags, this.excludedTags);

  /// [isTagGroup] — есть ли группа тегов с таким id (`source`, `content`…).
  static AddonQuery parse(String query, {bool Function(String group)? isTagGroup}) {
    final words = <String>[];
    final excludedWords = <String>[];
    final tags = <String>{};
    final excludedTags = <String>{};
    for (final raw in searchTokens(query.toLowerCase())) {
      final exclude = raw.startsWith('-');
      final body = exclude ? raw.substring(1) : raw;
      if (body.isEmpty) continue;
      final colon = body.indexOf(':');
      if (colon > 0 && colon < body.length - 1 && (isTagGroup?.call(body.substring(0, colon)) ?? false)) {
        (exclude ? excludedTags : tags).add(normalizeTag(body));
      } else {
        (exclude ? excludedWords : words).add(body);
      }
    }
    return AddonQuery._(words, excludedWords, tags, excludedTags);
  }

  bool get isEmpty => words.isEmpty && excludedWords.isEmpty && tags.isEmpty && excludedTags.isEmpty;

  /// Подходят ли теги аддона ([addonTags] — вида `группа:тег`): все теги
  /// запроса есть, ни одного исключённого.
  bool matchesTags(Iterable<String> addonTags) {
    final own = {for (final t in addonTags) normalizeTag(t)};
    return own.containsAll(tags) && !excludedTags.any(own.contains);
  }

  /// Подходит ли аддон по словам: [matches] — есть ли слово в названии,
  /// авторе, содержимом и т.п. (теги туда не входят); [excluded] — где
  /// искать `-слово` (по умолчанию там же; например, без категории).
  bool matchesWords(bool Function(String word) matches, {bool Function(String word)? excluded}) =>
      words.every(matches) && !excludedWords.any(excluded ?? matches);
}

/// Тег в одном виде: нижний регистр, без пробелов по краям.
String normalizeTag(String tag) => tag.trim().toLowerCase();

/// Слова строки через пробел; `"два слова"` — одно слово с пробелом
/// (кавычки убираются, знак `-` перед ними остаётся).
List<String> searchTokens(String query) {
  final out = <String>[];
  final buf = StringBuffer();
  var quoted = false;
  void flush() {
    final token = buf.toString().trim();
    if (token.isNotEmpty) out.add(token);
    buf.clear();
  }

  for (final ch in query.split('')) {
    if (ch == '"') {
      quoted = !quoted;
      continue;
    }
    if (!quoted && ch.trim().isEmpty) {
      flush();
      continue;
    }
    buf.write(ch);
  }
  flush();
  return out;
}

/// Есть ли в запросе [query] тег [tag] (`группа:тег`): 1 — есть, -1 — с
/// минусом, 0 — нет.
int searchTagSign(String query, String tag) {
  final t = normalizeTag(tag);
  var sign = 0;
  for (final token in searchTokens(query.toLowerCase())) {
    if (token == t) sign = 1;
    if (token == '-$t') sign = -1;
  }
  return sign;
}

/// Добавляет к запросу [query] тег [tag]: `группа:тег` или, с [exclude],
/// `-группа:тег`. Тот же тег с другим знаком убирается, повторно не
/// добавляется.
String addSearchTag(String query, String tag, {bool exclude = false}) {
  final t = normalizeTag(tag);
  if (t.isEmpty) return query;
  return _joinTokens([..._withoutTag(query, t), exclude ? '-$t' : t]);
}

/// Убирает из запроса [query] тег [tag] (и с минусом, и без).
String removeSearchTag(String query, String tag) {
  final t = normalizeTag(tag);
  if (t.isEmpty) return query;
  return _joinTokens(_withoutTag(query, t));
}

/// Следующее состояние тега в панели тегов: нет → тег → -тег → нет.
String cycleSearchTag(String query, String tag) => switch (searchTagSign(query, tag)) {
      0 => addSearchTag(query, tag),
      1 => addSearchTag(query, tag, exclude: true),
      _ => removeSearchTag(query, tag),
    };

List<String> _withoutTag(String query, String t) => [
      for (final x in searchTokens(query))
        if (normalizeTag(x) != t && normalizeTag(x) != '-$t') x,
    ];

/// Слово, которое сейчас набирается (последнее, если строка не кончается
/// пробелом): для подсказок тегов. (начало слова в строке, само слово).
(int, String) currentSearchToken(String query) {
  if (query.isEmpty || query.endsWith(' ')) return (query.length, '');
  // Незакрытая кавычка — слово с пробелом ещё набирается.
  var start = query.length;
  var quotes = '"'.allMatches(query).length;
  while (start > 0) {
    final ch = query[start - 1];
    if (ch == '"') quotes--;
    if (ch == ' ' && quotes.isEven) break;
    start--;
  }
  return (start, query.substring(start));
}

/// Заменяет набираемое слово тегом [tag] (`группа:тег`; знак `-`
/// сохраняется) и ставит пробел — можно печатать дальше.
String completeSearchTag(String query, String tag) {
  final (start, token) = currentSearchToken(query);
  final exclude = token.startsWith('-');
  final t = normalizeTag(tag);
  final rest = query.substring(0, start);
  final others = removeSearchTag(rest, t);
  return '${others.isEmpty ? '' : '$others '}${_quote(exclude ? '-$t' : t)} ';
}

/// Слово с пробелом — в кавычках (минус — снаружи).
String _quote(String x) {
  final exclude = x.length > 1 && x.startsWith('-');
  final body = exclude ? x.substring(1) : x;
  return body.contains(RegExp(r'\s')) ? '${exclude ? '-' : ''}"$body"' : x;
}

/// Слова — обратно в строку; слова с пробелом — в кавычках.
String _joinTokens(List<String> tokens) => tokens.map(_quote).join(' ');
