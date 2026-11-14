import 'dart:convert';
import '../models/mod_item.dart';

class ManifestService {
  // Парсинг JSON-индекса репозитория
  static List<ModItem> parseMainIndex(String jsonRaw, {String sourceName = 'Репозиторий'}) {
    try {
      final Map<String, dynamic> data = jsonDecode(jsonRaw);
      final List<dynamic> modsJson = data['mods'] ?? [];
      
      // Аддоны сразу по алфавиту, чтобы список не зависел от порядка в манифесте.
      return modsJson.map((item) => ModItem.fromJson(item, source: sourceName)).toList()
        ..sort(ModItem.compareByName);
    } catch (e) {
      print('Ошибка парсинга манифеста ($sourceName): $e');
      return [];
    }
  }

  // Шаблон репозитория (формат index_version 2: версии у файлов).
  // Описание формата: docs/manifest-format.md
  static String getEmptyRepositoryTemplate() {
    return '''
    {
      "index_version": 2,
      "repository_name": "My Repository",
      "mods": [
        {
          "id": "example-mod",
          "name": "Example Mod",
          "category": "Other",
          "uploader": "Your name",
          "description": "Mod description",
          "tags": ["example", "demo"],
          "files": [
            {
              "name": "Example_v1.0.pk3",
              "version": "1.0",
              "hash": "<autonomi address>",
              "md5": "<md5>",
              "size": 0,
              "changelog": "First release"
            }
          ]
        }
      ]
    }
    ''';
  }
}