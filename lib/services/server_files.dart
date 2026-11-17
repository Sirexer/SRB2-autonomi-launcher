import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/srb2_server.dart';
import 'autonomi_service.dart';
import 'file_hash.dart';
import 'platform_utils.dart';

/// Индекс файлов папки игры по имени — чтобы понять, какие аддоны сервера
/// у вас уже есть. SRB2 ищет файл так же: по имени (без учёта регистра)
/// рекурсивно в папке игры и проверяет MD5.
class LocalFileIndex {
  final String root;
  final Map<String, List<String>> _byName;
  final DateTime built = DateTime.now();

  LocalFileIndex._(this.root, this._byName);

  static final Map<String, (int, int, String)> _md5Cache = {};

  /// Папки, где аддонов не бывает (скриншоты, записи, логи...): не обходим.
  static const skippedFolders = {'screenshots', 'replay', 'movies', 'models', 'luafiles', 'logs'};

  static LocalFileIndex? _shared;

  /// Общий индекс папки игры (перестраивается раз в минуту или по [force]).
  static Future<LocalFileIndex> shared(String root, {bool force = false}) async {
    final s = _shared;
    if (!force && s != null && s.root == root && DateTime.now().difference(s.built) < const Duration(minutes: 1)) {
      return s;
    }
    return _shared = await build(root);
  }

  /// SRB2 ищет на глубину до 10 папок; столько же обходим и мы.
  static Future<LocalFileIndex> build(String root, {int maxDepth = 10}) async {
    final byName = <String, List<String>>{};

    Future<void> walk(Directory dir, int depth) async {
      try {
        await for (final e in dir.list(followLinks: false)) {
          if (e is File) {
            byName.putIfAbsent(p.basename(e.path).toLowerCase(), () => []).add(e.path);
          } else if (e is Directory && depth > 0) {
            if (skippedFolders.contains(p.basename(e.path).toLowerCase())) continue;
            await walk(e, depth - 1);
          }
        }
      } catch (_) {
        // Нет доступа — пропускаем.
      }
    }

    await walk(Directory(root), maxDepth);
    return LocalFileIndex._(root, byName);
  }

  /// Путь к файлу с таким именем и контрольной суммой или null.
  Future<String?> find(ServerFile file) async {
    for (final path in _byName[file.name.toLowerCase()] ?? const <String>[]) {
      if (!FileHash.isMd5(file.md5)) {
        // XXH3 (BlanKart): сначала размер — не считать сумму зря.
        try {
          if (File(path).lengthSync() != file.size) continue;
        } catch (_) {
          continue;
        }
      }
      if (await hashOf(path, file.md5) == file.md5) return path;
    }
    return null;
  }

  /// Путь к файлу с именем [name] и MD5 [md5] (пустой MD5 — любой) или null.
  Future<String?> findByName(String name, String md5) async {
    for (final path in _byName[name.toLowerCase()] ?? const <String>[]) {
      if (md5.isEmpty || await md5Of(path) == md5.toLowerCase()) return path;
    }
    return null;
  }

  /// Первый найденный путь файла с таким именем (без проверки MD5).
  /// Все файлы с этим именем (без учёта регистра).
  List<String> byName(String name) => _byName[name.toLowerCase()] ?? const [];

  String? firstByName(String name) {
    final list = _byName[name.toLowerCase()];
    return list == null || list.isEmpty ? null : list.first;
  }

  /// Все найденные файлы.
  Iterable<String> get paths => _byName.values.expand((l) => l);

  /// Есть ли файл с таким именем (без проверки MD5).
  bool hasName(String name) => (_byName[name.toLowerCase()] ?? const []).isNotEmpty;

  /// Есть файл с таким именем, но другим MD5 (другая версия аддона).
  bool hasOtherVersion(ServerFile file) => (_byName[file.name.toLowerCase()] ?? const []).isNotEmpty;

  void add(String path) =>
      _byName.putIfAbsent(p.basename(path).toLowerCase(), () => []).add(path);

  /// MD5 с кэшем по размеру и времени изменения файла.
  static Future<String?> md5Of(String path) => _cached(_md5Cache, path, AutonomiService.calculateFileMd5);

  static final Map<String, (int, int, String)> _xxh3Cache = {};

  /// Сумма файла того же вида, что [like]: MD5 или XXH3-64 (BlanKart).
  static Future<String?> hashOf(String path, String like) =>
      FileHash.isMd5(like) ? md5Of(path) : _cached(_xxh3Cache, path, FileHash.xxh3OfFile);

  static Future<String?> _cached(
      Map<String, (int, int, String)> cache, String path, Future<String?> Function(String) compute) async {
    try {
      final st = await File(path).stat();
      final cached = cache[path];
      final mtime = st.modified.millisecondsSinceEpoch;
      if (cached != null && cached.$1 == st.size && cached.$2 == mtime) return cached.$3;
      final hash = (await compute(path))?.toLowerCase();
      if (hash != null) cache[path] = (st.size, mtime, hash);
      return hash;
    } catch (_) {
      return null;
    }
  }
}

/// Скачивание аддонов сервера до запуска игры.
class ServerFileDownloader {
  ServerFileDownloader._();

  /// Куда сохранить аддон сервера. Обычно `DOWNLOAD/<имя>`; если там уже лежит
  /// другая версия с тем же именем — `DOWNLOAD/<имя без расширения>/<md5>/<имя>`,
  /// чтобы не затереть её. SRB2 сам найдёт нужную по MD5.
  static Future<String?> targetPath(String downloadDir, ServerFile file) async {
    final safe = PlatformUtils.safeFileName(file.name);
    if (safe == null) return null;
    final direct = p.join(downloadDir, safe);
    if (!await File(direct).exists()) return direct;
    if (await LocalFileIndex.hashOf(direct, file.md5) == file.md5) return direct;
    return p.join(downloadDir, p.basenameWithoutExtension(safe), file.md5.substring(0, 8), safe);
  }

  /// HTTP-зеркало сервера (http_source): SRB2 качает `<источник>/<имя>?md5=<md5>`,
  /// BlanKart (без MD5) — просто `<источник>/<имя>`.
  static Uri mirrorUrl(String httpSource, ServerFile file) {
    var base = httpSource.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    final query = FileHash.isMd5(file.md5) ? '?md5=${file.md5}' : '';
    return Uri.parse('$base/${Uri.encodeComponent(file.name)}$query');
  }

  /// Совпадает ли сумма скачанного файла с той, что прислал сервер.
  static Future<bool> checksumMatches(String path, ServerFile file) async {
    final hash = FileHash.isMd5(file.md5) ? await AutonomiService.calculateFileMd5(path) : await FileHash.xxh3OfFile(path);
    return hash?.toLowerCase() == file.md5;
  }

  /// Можно ли качать с этого зеркала (только http/https, как в игре).
  static bool isUsableMirror(String httpSource) {
    final uri = Uri.tryParse(httpSource.trim());
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty;
  }

  /// Скачивает файл с зеркала в [targetPath] и проверяет размер и сумму.
  static Future<void> downloadFromMirror({
    required String httpSource,
    required ServerFile file,
    required String targetPath,
    void Function(int received, int total)? onProgress,
  }) async {
    final part = File('$targetPath.part');
    await part.parent.create(recursive: true);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = 'Sonic Robo Blast 2/v2.2.15';
    try {
      final request = await client.getUrl(mirrorUrl(httpSource, file));
      final response = await request.close();
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      final sink = part.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.timeout(const Duration(seconds: 60))) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, file.size);
        }
      } finally {
        await sink.close();
      }
      if (file.size > 0 && received != file.size) {
        throw const FormatException('Size mismatch');
      }
      if (!await checksumMatches(part.path, file)) {
        throw FormatException(FileHash.isMd5(file.md5) ? 'MD5 mismatch' : 'Checksum mismatch');
      }
      await part.rename(targetPath);
    } catch (_) {
      if (await part.exists()) await part.delete();
      rethrow;
    } finally {
      client.close(force: true);
    }
  }
}
