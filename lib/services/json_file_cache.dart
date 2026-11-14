import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// JSON-файл кэша в папке данных лаунчера. Разбор и запись текста — в
/// отдельном изоляте (окно не подвисает на больших кэшах), записи идут по
/// очереди.
class JsonFileCache {
  final String name;
  Future<void>? _writing;

  JsonFileCache(this.name);

  Future<File> _file() async => File(p.join((await getApplicationSupportDirectory()).path, name));

  /// Содержимое; null — файла нет или он повреждён.
  Future<Map<String, Object?>?> read() async {
    try {
      final f = await _file();
      if (!await f.exists()) return null;
      final text = await f.readAsString();
      final json = await Isolate.run(() => jsonDecode(text));
      return json is Map<String, Object?> ? json : null;
    } catch (_) {
      return null;
    }
  }

  /// Сохраняет [json] (только простые Map/List/String/num/bool).
  void write(Map<String, Object?> json) {
    _writing = (_writing ?? Future<void>.value()).then((_) async {
      try {
        final text = await Isolate.run(() => jsonEncode(json));
        final f = await _file();
        await f.parent.create(recursive: true);
        await f.writeAsString(text, flush: true);
      } catch (_) {
        // кэш — не страшно, если не записался
      }
    });
  }
}
