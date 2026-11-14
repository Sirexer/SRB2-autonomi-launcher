import 'package:flutter_test/flutter_test.dart';
import 'package:srb2_autonomi_launcher/models/mod_item.dart';
import 'package:srb2_autonomi_launcher/services/manifest_service.dart';
import 'package:srb2_autonomi_launcher/utils/natural_compare.dart';

void main() {
  List<String> sorted(List<String> items) => [...items]..sort(naturalCompare);

  test('naturalCompare: case-insensitive, numbers as numbers', () {
    expect(
      sorted(['mod 10', 'Mod 2', 'banana', 'Apple', 'mod 1']),
      ['Apple', 'banana', 'mod 1', 'Mod 2', 'mod 10'],
    );
    expect(sorted(['v1.10', 'v1.9', 'v1.2']), ['v1.2', 'v1.9', 'v1.10']);
    expect(sorted(['Map007', 'Map7b', 'Map06']), ['Map06', 'Map007', 'Map7b']);
    expect(sorted(['abc', 'ab']), ['ab', 'abc']);
    expect(naturalCompare('Sonic', 'sonic'), isNot(0)); // stable, but adjacent
  });

  test('categories: alphabetical, default category last', () {
    final cats = ['Other', 'zones', 'Characters', 'Levels 2', 'Levels 10']
      ..sort(ModItem.compareCategories);
    expect(cats, ['Characters', 'Levels 2', 'Levels 10', 'zones', 'Other']);
  });

  test('manifest: addons sorted by name, missing/empty category -> Other', () {
    const json = '''
    {"mods": [
      {"id": "c", "name": "zeta Mod", "category": "Characters"},
      {"id": "a", "name": "Alpha 10"},
      {"id": "b", "name": "alpha 9", "category": "  "}
    ]}''';
    final mods = ManifestService.parseMainIndex(json, sourceName: 'test');
    expect(mods.map((m) => m.name), ['alpha 9', 'Alpha 10', 'zeta Mod']);
    expect(mods.map((m) => m.category), ['Other', 'Other', 'Characters']);
  });
}
