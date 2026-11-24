import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:srb2_autonomi_launcher/services/map_preview.dart';
import 'package:srb2_autonomi_launcher/ui/map_picker.dart';

void main() {
  testWidgets('map picker: gametype filter; nothing chosen — all maps', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final maps = Future.value(const [
      MapPreview('MAP01', 'Greenflower', null, types: ['Singleplayer', 'Co-op', 'Race']),
      MapPreview('MAP02', 'Arena', null, types: ['Match']),
      MapPreview('MAP03', 'Track', null, types: ['Race']),
    ]);
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(onPressed: () => showMapPicker(context, maps), child: const Text('open')),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('MAP01'), findsOneWidget);
    expect(find.text('MAP02'), findsOneWidget);
    expect(find.text('MAP03'), findsOneWidget);

    // Чаще всего — race (2): первой.
    expect(find.widgetWithText(FilterChip, 'race (2)'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilterChip, 'race (2)'));
    await tester.pumpAndSettle();
    expect(find.text('MAP02'), findsNothing);
    expect(find.text('MAP01'), findsOneWidget);
    expect(find.text('MAP03'), findsOneWidget);

    // Второй режим — карты любого из выбранных.
    await tester.tap(find.widgetWithText(FilterChip, 'match (1)'));
    await tester.pumpAndSettle();
    expect(find.text('MAP02'), findsOneWidget);

    await tester.tap(find.text('All gametypes'));
    await tester.pumpAndSettle();
    expect(find.text('MAP02'), findsOneWidget);
    expect(find.text('All gametypes'), findsNothing);
  });
}
