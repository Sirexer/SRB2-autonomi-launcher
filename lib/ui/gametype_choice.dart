import 'package:flutter/material.dart';

import '../i18n.dart';
import '../models/game.dart';
import '../services/addon_contents.dart';
import '../services/map_preview.dart';

/// Режимы, которые берёт карта [map]: встроенные режимы игры [game] и свои
/// режимы аддонов [custom] (без повторов). Если TypeOfLevel карты неизвестен —
/// пусто (предлагать нечего).
(List<String>, List<GametypeInfo>) gametypesForMap(GameDef game, MapPreview map, List<GametypeInfo> custom) {
  if (map.types.isEmpty) return (const [], const []);
  final seen = <String>{};
  return (
    [for (final g in game.gametypes) if (GameDef.levelFits(map.types, game.gametypeLevels(g) ?? const [])) g],
    [
      for (final g in custom)
        if (g.levels.isNotEmpty && GameDef.levelFits(map.types, g.levels) && seen.add(g.name.toLowerCase())) g,
    ],
  );
}

/// Выбор «Singleplayer» в меню режимов: одиночная игра — без -gametype и
/// без своего сервера (Netgame: Off).
const singleplayerGametype = '\u0000singleplayer';

/// Карта годится для одиночной игры (TypeOfLevel: Singleplayer / SP / Solo).
bool mapHasSingleplayer(MapPreview map) => map.types.any((t) => GameDef.normalizeLevelType(t) == 'SOLO');

/// [current] для меню: одиночная игра сейчас — если нет ни режима, ни сервера.
String currentGametypeChoice(String gametype, {required bool netOff}) =>
    gametype.trim().isEmpty && netOff ? singleplayerGametype : gametype;

/// Меню «⋮» с режимами карты у кнопки [anchor]: встроенные [builtIn] и свои
/// режимы аддонов [custom]. Текущий режим [current] отмечен галочкой справа,
/// длинные названия — с многоточием (целиком — в подсказке). [singleplayer] —
/// первым пунктом предложить одиночную игру ([singleplayerGametype]).
/// Возвращает выбранное название или null.
Future<String?> showGametypeMenu(
  BuildContext anchor,
  List<String> builtIn,
  List<GametypeInfo> custom, {
  String current = '',
  bool singleplayer = false,
}) async {
  if (!anchor.mounted) return null;
  final box = anchor.findRenderObject() as RenderBox?;
  final overlay = Overlay.of(anchor).context.findRenderObject() as RenderBox?;
  if (box == null || overlay == null) return null;
  final position = RelativeRect.fromRect(
    Rect.fromPoints(
      box.localToGlobal(Offset.zero, ancestor: overlay),
      box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
    ),
    Offset.zero & overlay.size,
  );
  final selected = current.trim().toLowerCase();
  final accent = Theme.of(anchor).colorScheme.primary;

  PopupMenuItem<String> item(String name, {String description = '', bool addon = false}) => PopupMenuItem(
        value: name,
        child: Tooltip(
          message: description.isEmpty ? name : '$name\n$description',
          waitDuration: const Duration(milliseconds: 500),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260),
            child: Row(
              children: [
                if (addon) ...[
                  const Icon(Icons.extension_outlined, size: 16),
                  const SizedBox(width: 8),
                ],
                Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                const SizedBox(width: 12),
                // Место под галочку есть у всех строк: галочки стоят ровно.
                SizedBox(
                  width: 18,
                  child: name.toLowerCase() == selected ? Icon(Icons.check, size: 18, color: accent) : null,
                ),
              ],
            ),
          ),
        ),
      );

  return showMenu<String>(
    context: anchor,
    position: position,
    items: [
      if (singleplayer) ...[
        PopupMenuItem(
          value: singleplayerGametype,
          child: Tooltip(
            message: tr('Single player: no -gametype and no server of your own (Netgame: Off)'),
            waitDuration: const Duration(milliseconds: 500),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: Row(
                children: [
                  const Icon(Icons.person_outline, size: 16),
                  const SizedBox(width: 8),
                  Expanded(child: Text(tr('Singleplayer'), maxLines: 1, overflow: TextOverflow.ellipsis)),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 18,
                    child: current == singleplayerGametype ? Icon(Icons.check, size: 18, color: accent) : null,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (builtIn.isNotEmpty || custom.isNotEmpty) const PopupMenuDivider(),
      ],
      if (builtIn.isEmpty && custom.isEmpty && !singleplayer)
        PopupMenuItem(enabled: false, child: Text(tr('Gametypes of this map are unknown'))),
      for (final g in builtIn) item(g),
      if (builtIn.isNotEmpty && custom.isNotEmpty) const PopupMenuDivider(),
      for (final g in custom) item(g.name, description: g.description, addon: true),
    ],
  );
}
