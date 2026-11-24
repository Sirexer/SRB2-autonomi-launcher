import 'package:flutter/material.dart';

import '../i18n.dart';
import '../services/characters.dart';
import 'srb2_text.dart';

/// Скорость и вес персонажа (как в игре: не указаны — 5).
(int, int) kartStatsOf(CharacterInfo c) => (c.kartSpeed ?? 5, c.kartWeight ?? 5);

/// «Скорость 5 · Вес 3».
String kartStatsText(CharacterInfo c) {
  final (speed, weight) = kartStatsOf(c);
  return tr('Speed {speed} · Weight {weight}', {'speed': '$speed', 'weight': '$weight'});
}

/// Сетка статов 9×9, как в меню выбора персонажа в игре: скорость — слева
/// направо, вес — сверху вниз; точка — персонаж.
class KartStatsGrid extends StatelessWidget {
  final int speed, weight;
  final double size;
  const KartStatsGrid(this.speed, this.weight, {super.key, this.size = 36});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return CustomPaint(size: Size.square(size), painter: _StatsGridPainter(speed, weight, accent));
  }
}

class _StatsGridPainter extends CustomPainter {
  final int speed, weight;
  final Color accent;
  _StatsGridPainter(this.speed, this.weight, this.accent);

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / 9;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(3)),
      Paint()..color = Colors.black45,
    );
    final dot = Paint()..color = Colors.white24;
    for (var x = 0; x < 9; x++) {
      for (var y = 0; y < 9; y++) {
        canvas.drawCircle(Offset((x + 0.5) * cell, (y + 0.5) * cell), cell * 0.16, dot);
      }
    }
    final at = Offset((speed.clamp(1, 9) - 0.5) * cell, (weight.clamp(1, 9) - 0.5) * cell);
    // Строка и столбец персонажа — подсветкой, точка — заметно крупнее сетки.
    final band = Paint()..color = accent.withValues(alpha: 0.18);
    canvas.drawRect(Rect.fromLTWH(0, at.dy - cell / 2, size.width, cell), band);
    canvas.drawRect(Rect.fromLTWH(at.dx - cell / 2, 0, cell, size.height), band);
    canvas.drawCircle(at, cell * 1.0, Paint()..color = Colors.white);
    canvas.drawCircle(at, cell * 0.75, Paint()..color = accent);
  }

  @override
  bool shouldRepaint(_StatsGridPainter old) => old.speed != speed || old.weight != weight || old.accent != accent;
}

/// Подсказка персонажа: имя, строки [extra] и описание из меню выбора
/// персонажа (PlayerText из SOC, с цветами SRB2). [kartStats] — строка со
/// скоростью и весом (игры-карты).
Widget characterTooltip(CharacterInfo? character, Widget child,
    {List<String> extra = const [], String? fallback, bool description = true, bool kartStats = false}) {
  if (character == null) {
    return fallback == null || fallback.isEmpty ? child : Tooltip(message: fallback, child: child);
  }
  final text = description ? character.description.trim() : '';
  // Тёмно-синий фон, как в меню выбора персонажа в игре: цвета SRB2
  // (жёлтый и т.п.) на светлой подсказке почти не видны.
  return Tooltip(
    waitDuration: const Duration(milliseconds: 350),
    constraints: const BoxConstraints(maxWidth: 420),
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: const Color(0xF2000A50),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: Colors.white24),
    ),
    textStyle: const TextStyle(color: Colors.white, fontSize: 12.5, height: 1.3),
    richMessage: TextSpan(children: [
      TextSpan(
        text: '${character.realname} (${character.name})',
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      if (kartStats) TextSpan(text: '\n${kartStatsText(character)}'),
      for (final line in extra) TextSpan(text: '\n$line'),
      if (text.isNotEmpty) ...[
        const TextSpan(text: '\n\n'),
        srb2RichText(text),
      ],
    ]),
    child: child,
  );
}

/// Иконка персонажа (пиксельная) или заглушка «?».
class CharacterIcon extends StatelessWidget {
  final CharacterInfo? character;
  final double size;

  /// Другой цвет (например, команды); null — предпочитаемый цвет персонажа.
  final List<int>? ramp;

  /// Портрет XTRAB0 вместо иконки XTRAC0 (если есть).
  final bool portrait;
  const CharacterIcon(this.character, {super.key, this.size = 32, this.ramp, this.portrait = false});

  @override
  Widget build(BuildContext context) {
    Widget placeholder() =>
        Image.asset('assets/char_unknown.png', width: size, height: size, filterQuality: FilterQuality.none);
    final icon = portrait && character?.portrait != null
        ? character!.portrait
        : ramp == null
            ? character?.icon
            : character?.iconWithRamp(ramp);
    if (icon == null) return placeholder();
    return Image.memory(icon,
        width: size,
        height: size,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.none,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => placeholder());
  }
}

/// Выбор персонажа для `+skin`: персонажи игры и аддонов из очереди.
/// Возвращает имя скина.
/// [portraits] — показывать портреты (charsel), а не иконки.
/// [kartStats] — скорость и вес на плитках (игры-карты).
Future<String?> showCharacterPicker(BuildContext context, Future<List<CharacterInfo>> characters,
        {String? current, bool portraits = false, bool kartStats = false}) =>
    showDialog<String>(
        context: context, builder: (_) => _CharacterPickerDialog(characters, current, portraits, kartStats));

class _CharacterPickerDialog extends StatefulWidget {
  final Future<List<CharacterInfo>> characters;
  final String? current;
  final bool portraits, kartStats;
  const _CharacterPickerDialog(this.characters, this.current, this.portraits, this.kartStats);

  @override
  State<_CharacterPickerDialog> createState() => _CharacterPickerDialogState();
}

class _CharacterPickerDialogState extends State<_CharacterPickerDialog> {
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
          child: FutureBuilder<List<CharacterInfo>>(
            future: widget.characters,
            builder: (context, snap) {
              final all = snap.data;
              final q = _search.text.trim().toLowerCase();
              // Один скин — один раз (игра переименовывает повторы, выбрать их по имени всё равно нельзя).
              final seen = <String>{};
              final shown = [
                for (final c in all ?? const <CharacterInfo>[])
                  if (seen.add(c.name) &&
                      (q.isEmpty || c.name.contains(q) || c.realname.toLowerCase().contains(q)))
                    c,
              ];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Text(tr('Choose a character'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
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
                        ? (snap.connectionState == ConnectionState.done
                            ? Center(child: Text(tr('Could not read the characters.')))
                            : const Center(child: CircularProgressIndicator()))
                        : shown.isEmpty
                            ? Center(
                                child: Text(
                                  all.isEmpty
                                      ? tr('No characters found. Set the game folder and add character addons to the launch queue.')
                                      : tr('Nothing found.'),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(color: Colors.grey),
                                ),
                              )
                            : GridView.builder(
                                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent: 130,
                                  mainAxisExtent: widget.kartStats ? 150 : 130,
                                  crossAxisSpacing: 8,
                                  mainAxisSpacing: 8,
                                ),
                                itemCount: shown.length,
                                itemBuilder: (context, i) {
                                  final c = shown[i];
                                  final selected = widget.current?.trim().toLowerCase() == c.name;
                                  return characterTooltip(c, kartStats: widget.kartStats, Card(
                                    margin: EdgeInsets.zero,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      side: selected ? BorderSide(color: accent, width: 2) : BorderSide.none,
                                    ),
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(8),
                                      onTap: () => Navigator.pop(context, c.name),
                                      child: Padding(
                                        padding: const EdgeInsets.all(8),
                                        child: Column(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            CharacterIcon(c, size: 56, portrait: widget.portraits),
                                            const SizedBox(height: 6),
                                            Text(c.realname,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                                            Text(c.name,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(fontSize: 11, color: Colors.grey)),
                                            if (widget.kartStats) KartStatsLine(c),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ));
                                },
                              ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    tr('Characters of the game and of the addons in the launch queue.'),
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

/// Строка под именем: значки скорости и веса с числами и мини-сетка.
class KartStatsLine extends StatelessWidget {
  final CharacterInfo character;
  const KartStatsLine(this.character, {super.key});

  @override
  Widget build(BuildContext context) {
    final (speed, weight) = kartStatsOf(character);
    const style = TextStyle(fontSize: 11, fontWeight: FontWeight.w600);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: tr('Speed'),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.speed, size: 13),
              const SizedBox(width: 2),
              Text('$speed', style: style),
            ]),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: tr('Weight'),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.fitness_center, size: 13),
              const SizedBox(width: 2),
              Text('$weight', style: style),
            ]),
          ),
          const SizedBox(width: 8),
          KartStatsGrid(speed, weight, size: 27),
        ],
      ),
    );
  }
}
