import 'package:flutter/material.dart';

import '../i18n.dart';
import '../services/addon_contents.dart';
import '../services/map_preview.dart';
import 'gametype_choice.dart';
import 'srb2_text.dart';

/// Картинка уровня 160×100 (пиксельная) или заглушка «?».
class MapPicture extends StatelessWidget {
  final MapPreview map;
  final double width;
  final double height;

  const MapPicture(this.map, {super.key, this.width = 192, this.height = 120});

  @override
  Widget build(BuildContext context) {
    Widget placeholder() => Image.asset('assets/map_unknown.png',
        width: width, height: height, fit: BoxFit.cover, filterQuality: FilterQuality.none);
    final image = map.image;
    if (image == null) return placeholder();
    return Image.memory(
      image,
      width: width,
      height: height,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.none,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => placeholder(),
    );
  }
}

/// Режимы уровня (TypeOfLevel) одной строкой.
class MapTypes extends StatelessWidget {
  final List<String> types;
  const MapTypes(this.types, {super.key});

  @override
  Widget build(BuildContext context) {
    // Строчными: co-op, race — не CO-OP, RACE.
    final names = [for (final t in types) t.toLowerCase()];
    return Tooltip(
        message: names.join(', '),
        child: Text(
          names.join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.85)),
        ),
      );
  }
}

/// Выбор в окне карт: карта и (из меню «⋮») режим; null — режим не выбирали.
typedef MapChoice = ({String map, String? gametype});

/// Режимы, которые берёт карта: встроенные и свои режимы аддонов.
typedef MapGametypes = (List<String>, List<GametypeInfo>) Function(MapPreview map);

/// Окно выбора карты для -warp: карты игры и аддонов из очереди, превью,
/// поиск по имени и названию. Титульная карта не показывается, скрытые
/// уровни (Hidden в SOC) — по переключателю. У карточек с [gametypes] есть
/// меню «⋮» с режимами карты ([gametype] — текущий, с галочкой).
Future<MapChoice?> showMapPicker(BuildContext context, Future<List<MapPreview>> maps,
        {String? current, MapGametypes? gametypes, String gametype = ''}) =>
    showDialog<MapChoice>(context: context, builder: (_) => _MapPickerDialog(maps, current, gametypes, gametype));

class _MapPickerDialog extends StatefulWidget {
  final Future<List<MapPreview>> maps;
  final String? current;
  final MapGametypes? gametypes;
  final String gametype;
  const _MapPickerDialog(this.maps, this.current, this.gametypes, this.gametype);

  @override
  State<_MapPickerDialog> createState() => _MapPickerDialogState();
}

class _MapPickerDialogState extends State<_MapPickerDialog> {
  final _search = TextEditingController();
  bool _showHidden = false;

  /// Режимы фильтра (строчными); пусто — показываются все карты.
  final Set<String> _types = {};

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<MapPreview> _filter(List<MapPreview> all) {
    final q = _search.text.trim().toLowerCase();
    return [
      for (final m in all)
        if (!m.isTitleMap &&
            (_showHidden || !m.hidden) &&
            (_types.isEmpty || m.types.any((t) => _types.contains(t.toLowerCase()))) &&
            (q.isEmpty ||
                m.map.toLowerCase().contains(q) ||
                srb2PlainTitle(m.title).toLowerCase().contains(q) ||
                m.types.any((t) => t.toLowerCase().contains(q))))
          m,
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(32),
      child: SizedBox(
        width: 960,
        height: 680,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FutureBuilder<List<MapPreview>>(
            future: widget.maps,
            builder: (context, snap) {
              final all = snap.data;
              final hiddenCount = all?.where((m) => m.hidden && !m.isTitleMap).length ?? 0;
              final shown = all == null ? const <MapPreview>[] : _filter(all);
              // Режимы карт для фильтра: чаще встречающиеся — первыми.
              final typeCounts = <String, int>{};
              for (final m in all ?? const <MapPreview>[]) {
                if (m.isTitleMap || (!_showHidden && m.hidden)) continue;
                for (final t in {for (final t in m.types) t.toLowerCase()}) {
                  typeCounts[t] = (typeCounts[t] ?? 0) + 1;
                }
              }
              final typeList = typeCounts.keys.toList()..sort((a, b) => typeCounts[b]!.compareTo(typeCounts[a]!));
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Text(tr('Choose a map'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                      const SizedBox(width: 16),
                      Expanded(
                        child: TextField(
                          controller: _search,
                          autofocus: true,
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            hintText: tr('Search by map or level name...'),
                            prefixIcon: const Icon(Icons.search, size: 20),
                            isDense: true,
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                      ),
                      IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
                    ],
                  ),
                  if (hiddenCount > 0)
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: _showHidden,
                      onChanged: (v) => setState(() => _showHidden = v ?? false),
                      title: Text(tr('Show hidden levels ({n})', {'n': hiddenCount})),
                    ),
                  if (typeList.length > 1)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(tr('Gametype:'), style: const TextStyle(fontSize: 13, color: Colors.grey)),
                          for (final t in typeList)
                            FilterChip(
                              visualDensity: VisualDensity.compact,
                              label: Text('$t (${typeCounts[t]})'),
                              selected: _types.contains(t),
                              onSelected: (v) => setState(() => v ? _types.add(t) : _types.remove(t)),
                            ),
                          if (_types.isNotEmpty)
                            TextButton(
                              onPressed: () => setState(_types.clear),
                              child: Text(tr('All gametypes')),
                            ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: all == null
                        ? (snap.connectionState == ConnectionState.done
                            ? Center(child: Text(tr('Could not read the maps.')))
                            : const Center(child: CircularProgressIndicator()))
                        : shown.isEmpty
                            ? Center(
                                child: Text(
                                  all.isEmpty
                                      ? tr('No maps found. Set the game folder and add map addons to the launch queue.')
                                      : tr('Nothing found.'),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(color: Colors.grey),
                                ),
                              )
                            : GridView.builder(
                                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent: 210,
                                  mainAxisExtent: 204,
                                  crossAxisSpacing: 10,
                                  mainAxisSpacing: 10,
                                ),
                                itemCount: shown.length,
                                itemBuilder: (context, i) => _tile(shown[i]),
                              ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    tr('Maps of the game and of the addons in the launch queue. The title screen map is not shown.'),
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _tile(MapPreview m) {
    final selected = widget.current?.trim().toUpperCase() == m.map;
    final accent = Theme.of(context).colorScheme.primary;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: selected ? BorderSide(color: accent, width: 2) : BorderSide.none,
      ),
      child: InkWell(
        onTap: () => Navigator.pop<MapChoice>(context, (map: m.map, gametype: null)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MapPicture(m, width: double.infinity, height: 120),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(m.map,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                            overflow: TextOverflow.ellipsis),
                      ),
                      if (m.hidden) const Icon(Icons.visibility_off_outlined, size: 14, color: Colors.grey),
                      if (widget.gametypes != null)
                        Builder(
                          builder: (button) => IconButton(
                            icon: const Icon(Icons.more_vert, size: 18),
                            tooltip: tr('Gametypes of this map'),
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                            onPressed: () => _gametypeMenu(button, m),
                          ),
                        ),
                    ],
                  ),
                  srb2Title(m.title.isEmpty ? '—' : m.title, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  if (m.types.isNotEmpty) MapTypes(m.types),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Меню «⋮»: режим карты — выбрать и карту, и режим сразу.
  Future<void> _gametypeMenu(BuildContext anchor, MapPreview m) async {
    final (builtIn, custom) = widget.gametypes!(m);
    final choice = await showGametypeMenu(anchor, builtIn, custom,
        current: widget.gametype, singleplayer: mapHasSingleplayer(m));
    if (choice == null || !mounted) return;
    Navigator.pop<MapChoice>(context, (map: m.map, gametype: choice));
  }
}
