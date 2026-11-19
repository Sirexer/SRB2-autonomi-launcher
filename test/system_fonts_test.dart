import 'package:flutter_test/flutter_test.dart';
import 'package:srb2_autonomi_launcher/services/system_fonts.dart';

void main() {
  test('family names without style words (Windows registry names)', () {
    expect(SystemFonts.familyOf('Segoe UI Bold Italic'), 'Segoe UI');
    expect(SystemFonts.familyOf('Arial'), 'Arial');
    expect(SystemFonts.familyOf('Bahnschrift SemiLight Condensed'), 'Bahnschrift');
    expect(SystemFonts.familyOf('Bold'), 'Bold');
  });

  test('the system has fonts (fontconfig here)', () async {
    final fonts = await SystemFonts.list();
    expect(fonts, isNotEmpty);
    expect(fonts.toSet().length, fonts.length);
  });
}
