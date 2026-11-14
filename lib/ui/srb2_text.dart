import 'package:flutter/material.dart';

import '../models/srb2_server.dart';

export '../models/srb2_server.dart' show Srb2Text, Srb2TextSpan;

/// Цвета SRB2 (\x81–\x8F) для тёмной темы; null — обычный цвет текста.
Color? srb2Color(int code) => const <int, Color>{
      1: Color(0xFFE865E8), // magenta
      2: Color(0xFFF5E25B), // yellow
      3: Color(0xFF62D85A), // green
      4: Color(0xFF6B8CFF), // blue
      5: Color(0xFFF2554F), // red
      6: Color(0xFFA8A8A8), // gray
      7: Color(0xFFFFA347), // orange
      8: Color(0xFF5FD3FF), // sky
      9: Color(0xFFB283FF), // purple
      10: Color(0xFF56E8D4), // aqua
      11: Color(0xFFC6E15A), // peridot
      12: Color(0xFF79A9FF), // azure
      13: Color(0xFFC08A5A), // brown
      14: Color(0xFFFF9AC1), // rosy
    }[code]; // 15 (invert) на тёмном фоне не показать — обычный цвет

/// Имя SRB2 с цветами.
Widget srb2Name(List<Srb2TextSpan> spans, {TextStyle? style, bool dim = false}) =>
    srb2Text(spans, style: style, dim: dim);

/// Название уровня (или другой текст из SOC) с цветами SRB2: коды `^4`,
/// `\82` и сами байты \x80–\x8F (см. [Srb2Text.decodeSoc]).
List<Srb2TextSpan> srb2TitleSpans(String title) => Srb2Text.parse(Srb2Text.decodeSoc(title));

/// Название уровня без цветовых кодов (поиск, подсказки, сортировка).
String srb2PlainTitle(String title) => Srb2Text.plain(srb2TitleSpans(title));

/// Название уровня с цветами SRB2.
Widget srb2Title(String title,
        {TextStyle? style, int? maxLines = 1, TextOverflow? overflow = TextOverflow.ellipsis, TextAlign? textAlign}) =>
    srb2Text(srb2TitleSpans(title), style: style, maxLines: maxLines, overflow: overflow, textAlign: textAlign);

/// Текст SRB2 из кусков с цветами.
Widget srb2Text(List<Srb2TextSpan> spans,
        {TextStyle? style,
        bool dim = false,
        int? maxLines = 1,
        TextOverflow? overflow = TextOverflow.ellipsis,
        TextAlign? textAlign}) =>
    Text.rich(
      TextSpan(children: [
        for (final s in spans)
          TextSpan(text: s.text, style: TextStyle(color: dim ? null : srb2Color(s.color))),
      ]),
      style: style,
      maxLines: maxLines,
      overflow: overflow,
      textAlign: textAlign,
    );

/// Многострочный текст SRB2 (описания) с цветами — для [Tooltip.richMessage]
/// и [Text.rich]: строки по `\n`, коды цветов как в [srb2TitleSpans].
TextSpan srb2RichText(String text, {TextStyle? style}) {
  final lines = text.split('\n');
  return TextSpan(style: style, children: [
    for (var i = 0; i < lines.length; i++) ...[
      if (i > 0) const TextSpan(text: '\n'),
      for (final s in srb2TitleSpans(lines[i])) TextSpan(text: s.text, style: TextStyle(color: srb2Color(s.color))),
    ],
  ]);
}

/// Подсказка на тёмно-синем фоне, как в меню игры: цвета SRB2 (жёлтый и
/// т.п.) на светлой подсказке почти не видны. [message] — куски текста:
/// из SOC — через [srb2RichText], переводы лаунчера — обычным TextSpan
/// (разбор SOC оставляет только латиницу, кириллица стала бы «???»).
Widget srb2Tooltip(InlineSpan message, Widget child) => Tooltip(
      waitDuration: const Duration(milliseconds: 350),
      constraints: const BoxConstraints(maxWidth: 420),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xF2000A50),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white24),
      ),
      textStyle: const TextStyle(color: Colors.white, fontSize: 12.5, height: 1.3),
      richMessage: message,
      child: child,
    );
