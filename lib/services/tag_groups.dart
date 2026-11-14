import 'dart:convert';

/// Группа тегов в панели тегов: id (`source`), цвет (ARGB) и её теги.
class TagGroup {
  final String id;
  final int color;

  /// Теги группы (нижний регистр). Встроенные группы берут ещё теги с
  /// приставкой `id:` — см. [TagGrouping.builtIn].
  final Set<String> tags;

  /// Название из репозитория (`name`); null — по [id].
  final String? name;

  const TagGroup(this.id, this.color, [this.tags = const {}, this.name]);

  /// Название в панели — только из репозитория: `name`, иначе сам `id`
  /// (лаунчер своих названий групп не задаёт).
  String get title {
    final n = name?.trim() ?? '';
    return n.isNotEmpty ? n : id;
  }
}

/// Как теги разложены по группам: из `tag_groups` репозиториев или, если ни
/// один репозиторий их не задаёт, встроенные группы.
///
/// `tag_groups` в файле репозитория (порядок групп — как в списке):
/// ```json
/// "tag_groups": [
///   {"id": "source", "color": "#4FC3F7", "tags": ["source:ws", "source:mb"]},
///   {"id": "section", "name": "WS Section", "color": "#7986CB", "tags": ["section:blue_sphere"]}
/// ]
/// ```
/// `name` — название группы в панели (не обязательно; без него — `id`).
/// Тег попадает в группу, где он перечислен; неперечисленные — в «Другие».
/// Тег с приставкой своей группы (`source:ws`) показывается без неё.
class TagGrouping {
  final List<TagGroup> groups;

  /// Группы заданы репозиториями (а не встроенные).
  final bool fromRepositories;

  /// Встроенные: теги без приставки — по этому списку.
  final Map<String, String> _plain;

  TagGrouping._(this.groups, this.fromRepositories, [this._plain = const {}]);

  static const other = TagGroup('other', 0xFF9E9E9E);

  /// Встроенные группы: тег `группа:имя` — по приставке, без приставки —
  /// по списку.
  static final builtIn = TagGrouping._(const [
    TagGroup('main', 0xFFFFC857),
    TagGroup('source', 0xFF4FC3F7),
    TagGroup('section', 0xFF7986CB),
    TagGroup('content', 0xFF81C784),
    TagGroup('mapstyle', 0xFFBA68C8),
    TagGroup('gametype', 0xFFFF8A65),
    TagGroup('maps', 0xFF4DB6AC),
    TagGroup('port', 0xFFF06292),
    other,
  ], false, const {
    // main
    'featured': 'main', 'open_assets': 'main', 'w.i.p.': 'main', 'demo': 'main', 'beta': 'main',
    'for_modders': 'main', 'mod_dev': 'main', 'serv_management': 'main', 'hidden': 'main', 'hide': 'main',
    'port': 'main',
    // content
    'maps': 'content', 'characters': 'content', 'assets': 'content', 'lua': 'content', 'sprites': 'content',
    'textures': 'content', 'music': 'content', 'original_music': 'content', 'original music': 'content',
    'badniks': 'content', 'bosses': 'content', 'gimmicks': 'content',
    // maps
    'single_map': 'maps', 'map_pack': 'maps', 'large_map_pack': 'maps', 'small_map_pack': 'maps',
    'medium_map_pack': 'maps', 'hangout': 'maps', 'emerald_hunt': 'maps', 'linear_maps': 'maps',
    'nonlinear_maps': 'maps', 'slope_abuse': 'maps', 'no_slopes': 'maps', 'minimum_slopes': 'maps', 'mixels': 'maps',
    // port
    'clear_port': 'port', 'almost_clear_port': 'port', 'edited_port': 'port', 'extended_port': 'port',
  });

  /// Группы из `tag_groups` файлов репозиториев [manifests] (в порядке
  /// репозиториев). Группа с тем же id в другом репозитории добавляет свои
  /// теги, цвет — от первого. Ни одного `tag_groups` — [builtIn].
  static TagGrouping fromManifests(Iterable<String> manifests) {
    final order = <String>[];
    final colors = <String, int>{};
    final names = <String, String>{};
    final tags = <String, Set<String>>{};
    final taken = <String>{}; // тег — только в первой группе, где он есть
    for (final raw in manifests) {
      Object? json;
      try {
        json = jsonDecode(raw);
      } catch (_) {
        continue;
      }
      final list = json is Map ? json['tag_groups'] : null;
      if (list is! List) continue;
      for (final g in list) {
        if (g is! Map) continue;
        final id = (g['id'] as Object?)?.toString().trim().toLowerCase() ?? '';
        if (id.isEmpty || id == other.id) continue;
        if (!order.contains(id)) order.add(id);
        colors.putIfAbsent(id, () => parseColor(g['color']) ?? other.color);
        if (g['name'] case final String n when n.trim().isNotEmpty) names.putIfAbsent(id, () => n.trim());
        final own = tags.putIfAbsent(id, () => {});
        if (g['tags'] case final List t) {
          for (final x in t) {
            final tag = x is String ? x : (x is Map ? x['tag'] : null);
            if (tag is! String) continue;
            final n = tag.trim().toLowerCase();
            if (n.isNotEmpty && taken.add(n)) own.add(n);
          }
        }
      }
    }
    if (order.isEmpty) return builtIn;
    return TagGrouping._([for (final id in order) TagGroup(id, colors[id]!, tags[id]!, names[id]), other], true);
  }

  /// `#RRGGBB` / `#AARRGGBB` (с # или без) → ARGB; null — не цвет.
  static int? parseColor(Object? v) {
    if (v is! String) return null;
    var h = v.trim();
    if (h.startsWith('#')) h = h.substring(1);
    if (h.length != 6 && h.length != 8) return null;
    final n = int.tryParse(h, radix: 16);
    if (n == null) return null;
    return h.length == 6 ? 0xFF000000 | n : n;
  }

  TagGroup? byId(String id) => groups.where((g) => g.id == id).firstOrNull;

  /// Группа тега.
  TagGroup of(String tag) {
    final t = tag.toLowerCase();
    if (fromRepositories) {
      return groups.where((g) => g.tags.contains(t)).firstOrNull ?? other;
    }
    final colon = t.indexOf(':');
    if (colon > 0) {
      final g = byId(t.substring(0, colon));
      if (g != null && g != other) return g;
    }
    return byId(_plain[t] ?? '') ?? other;
  }

  /// Имя тега без приставки его группы: `source:ws` → `ws`, `lua` → `lua`.
  String label(String tag) {
    final g = of(tag);
    final prefix = '${g.id}:';
    return g != other && tag.toLowerCase().startsWith(prefix) && tag.length > prefix.length
        ? tag.substring(prefix.length)
        : tag;
  }

  /// Тег с группой — так он пишется в поиске и показывается у аддона:
  /// `workshop` (в группе source) → `source:workshop`, встроенный `source:ws`
  /// → `source:ws`, тег без группы → `other:xyz`.
  String qualified(String tag) => '${of(tag).id}:${label(tag)}'.toLowerCase();

  /// Группа по началу тега с группой (`source:workshop` → source).
  TagGroup groupOfQualified(String qualified) {
    final colon = qualified.indexOf(':');
    return colon > 0 ? byId(qualified.substring(0, colon)) ?? other : other;
  }

  /// Теги по группам в порядке [groups]; внутри группы порядок [tags]
  /// сохраняется. Пустые группы пропускаются.
  List<(TagGroup, List<T>)> group<T>(List<T> tags, String Function(T) name) {
    final by = <String, List<T>>{};
    for (final t in tags) {
      by.putIfAbsent(of(name(t)).id, () => []).add(t);
    }
    return [
      for (final g in groups)
        if (by[g.id] case final list?) (g, list),
    ];
  }
}
