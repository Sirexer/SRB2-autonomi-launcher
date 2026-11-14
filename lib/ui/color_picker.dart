import 'package:flutter/material.dart';

import '../i18n.dart';
import 'color_preview.dart';

/// Цвет для выбора: имя (для +color), ramp и из аддона ли он.
class SkinColorChoice {
  final String name;
  final List<int> ramp;
  final bool custom;
  const SkinColorChoice(this.name, this.ramp, {this.custom = false});
}

/// Окно выбора цвета персонажа (+color): цвета игры и аддонов очереди,
/// поиск по имени. Возвращает имя цвета.
Future<String?> showSkinColorPicker(BuildContext context, Future<List<SkinColorChoice>> colors, {String? current}) =>
    showDialog<String>(context: context, builder: (_) => _ColorPickerDialog(colors, current));

class _ColorPickerDialog extends StatefulWidget {
  final Future<List<SkinColorChoice>> colors;
  final String? current;
  const _ColorPickerDialog(this.colors, this.current);

  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Dialog(
      insetPadding: const EdgeInsets.all(32),
      child: SizedBox(
        width: 820,
        height: 600,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FutureBuilder<List<SkinColorChoice>>(
            future: widget.colors,
            builder: (context, snap) {
              final all = snap.data;
              final q = _search.text.trim().toLowerCase();
              final seen = <String>{};
              final shown = [
                for (final c in all ?? const <SkinColorChoice>[])
                  if (seen.add(c.name.toLowerCase()) && (q.isEmpty || c.name.toLowerCase().contains(q))) c,
              ];
              final current = widget.current?.trim().toLowerCase() ?? '';
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Text(tr('Choose a color'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                      const SizedBox(width: 16),
                      Expanded(
                        child: TextField(
                          controller: _search,
                          autofocus: true,
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            hintText: tr('Search by name...'),
                            prefixIcon: const Icon(Icons.search, size: 20),
                            isDense: true,
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                      ),
                      IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: all == null
                        ? const Center(child: CircularProgressIndicator())
                        : shown.isEmpty
                            ? Center(child: Text(tr('Nothing found.'), style: const TextStyle(color: Colors.grey)))
                            : GridView.builder(
                                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent: 110,
                                  mainAxisExtent: 120,
                                  crossAxisSpacing: 8,
                                  mainAxisSpacing: 8,
                                ),
                                itemCount: shown.length,
                                itemBuilder: (context, i) {
                                  final c = shown[i];
                                  final selected = current == c.name.toLowerCase();
                                  return Card(
                                    margin: EdgeInsets.zero,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      side: selected ? BorderSide(color: accent, width: 2) : BorderSide.none,
                                    ),
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(8),
                                      onTap: () => Navigator.pop(context, c.name),
                                      child: Padding(
                                        padding: const EdgeInsets.all(6),
                                        child: Column(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            ColorPreview(c.ramp, height: 72),
                                            const SizedBox(height: 4),
                                            Row(
                                              mainAxisAlignment: MainAxisAlignment.center,
                                              children: [
                                                if (c.custom) ...[
                                                  Tooltip(
                                                    message: tr('From an addon in the launch queue'),
                                                    child: Icon(Icons.extension_outlined, size: 12, color: accent),
                                                  ),
                                                  const SizedBox(width: 3),
                                                ],
                                                Flexible(
                                                  child: Text(c.name,
                                                      maxLines: 1,
                                                      overflow: TextOverflow.ellipsis,
                                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    tr('Colors of the game and of the addons in the launch queue. +color works only in multiplayer or with +devmode.'),
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
}
