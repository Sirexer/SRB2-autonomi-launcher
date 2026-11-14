import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:antd_client/antd_client.dart';
import 'app_log.dart';
import 'antd_daemon.dart';

class AutonomiService {
  // The daemon listens on 127.0.0.1 only. The default `localhost` may resolve
  // to ::1 first (Windows), which costs a failed connection attempt.
  // fileGetPublic blocks until the whole file is fetched, so the default
  // 5-minute timeout would abort large mods.
  static final AntdClient _client = AntdClient(
    baseUrl: AntdDaemon.baseUrl,
    timeout: const Duration(hours: 3),
  );

  static String _clean(String hash) =>
      hash.replaceAll('autonomi://', '').trim();

  /// Неудачи подряд (ошибка или тайм-аут). Несколько подряд — демон, скорее
  /// всего, завис: перезапускаем его (не чаще раза в минуту).
  static int _failuresInRow = 0;

  /// Идущие большие загрузки (аддоны): перезапуск их оборвал бы — не трогаем.
  static int _bigDownloads = 0;

  /// Считаем только признаки зависшего демона: тайм-аут и обрыв связи. «Файл
  /// не найден» и т.п. — ответ живого демона, он не считается.
  static void _noteResult(Object? error) {
    if (error == null) {
      _failuresInRow = 0;
      return;
    }
    final stuck = error is TimeoutException ||
        error is SocketException ||
        error is HttpException ||
        '$error'.toLowerCase().contains('connection');
    if (!stuck) return;
    if (++_failuresInRow >= 3 && _bigDownloads == 0) {
      _failuresInRow = 0;
      AntdDaemon.restart();
    }
  }

  static Future<bool> downloadFile({
    required String hash,
    required String outputFilePath,
    String? expectedMd5,
    int expectedSize = 0,
    void Function(double progress, int downloadedBytes, int totalBytes)? onProgress,
    void Function(String stage)? onStage, // 'downloading' | 'verifying'
    void Function(int done, int total)? onChunks, // из лога демона: Downloaded 3/5
    Duration? timeout, // для маленьких файлов (картинки, манифесты): завис — ошибка
  }) async {
    final tmpPath = '$outputFilePath.part';
    if (timeout == null) _bigDownloads++;
    try {
      // Гарантируем, что родительская директория существует
      final outputFile = File(outputFilePath);
      await outputFile.parent.create(recursive: true);

      onStage?.call('downloading');
      onProgress?.call(0.0, 0, expectedSize);

      final startedAt = DateTime.now().subtract(const Duration(seconds: 2));
      final outDir = outputFile.parent;
      var polling = false;
      final timer = Timer.periodic(const Duration(milliseconds: 500), (_) async {
        if (polling) return;
        polling = true;
        try {
          var bytes = 0;
          await for (final e in outDir.list(followLinks: false)) {
            if (e is! File) continue;
            final name = e.uri.pathSegments.last;
            final isAntTmp =
                name.startsWith('.ant_download_') && name.endsWith('.tmp');
            if (!isAntTmp && e.path != tmpPath) continue;
            try {
              final st = await e.stat();
              if (isAntTmp && st.modified.isBefore(startedAt)) continue;
              if (st.size > bytes) bytes = st.size;
            } catch (_) {}
          }
          if (bytes > 0) {
            final fraction = expectedSize > 0
                ? (bytes / expectedSize).clamp(0.0, 0.99).toDouble()
                : 0.0;
            onProgress?.call(fraction, bytes, expectedSize);
          }
        } catch (_) {} finally {
          polling = false;
        }
      });

      // Прогресс по чанкам из лога демона (если демон запущен лаунчером).
      // Маленькие параллельные загрузки (картинки) отсеиваем: берём запрос с наибольшим total.
      final seen = <String, ChunkProgress>{};
      StreamSubscription<ChunkProgress>? chunkSub;
      if (onChunks != null) {
        chunkSub = AntdDaemon.chunkProgress.listen((c) {
          seen[c.requestId] = c;
          var best = c;
          for (final v in seen.values) {
            if (v.total > best.total) best = v;
          }
          onChunks(best.done, best.total);
        });
      }

      try {
        final request = _client.fileGetPublic(_clean(hash), tmpPath);
        await (timeout == null ? request : request.timeout(timeout));
      } finally {
        timer.cancel();
        await chunkSub?.cancel();
      }

      if (expectedMd5 != null && expectedMd5.isNotEmpty) {
        onStage?.call('verifying');
        final actual = await calculateFileMd5(tmpPath);
        if (actual?.toLowerCase() != expectedMd5.toLowerCase()) {
          AppLog.console('MD5 mismatch for $outputFilePath');
          await File(tmpPath).delete();
          return false;
        }
      }

      await File(tmpPath).rename(outputFilePath);
      final doneBytes = await outputFile.length();
      onProgress?.call(1.0, doneBytes, doneBytes);
      _noteResult(null);
      return true;
    } catch (e) {
      AppLog.console('Autonomi download error: $e');
      _noteResult(e);
      final tmp = File(tmpPath);
      if (await tmp.exists()) await tmp.delete();
      return false;
    } finally {
      if (timeout == null) _bigDownloads--;
    }
  }

  /// Путь к картинке в кэше (файл может ещё не существовать) или null,
  /// если хэш из манифеста непригоден для имени файла.
  static Future<String?> _imagePath(String hash) async {
    // The hash comes from the manifest: keep only safe characters for the file name.
    final safeName = _clean(hash).replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
    if (safeName.isEmpty) return null;
    // Постоянная директория поддержки приложения, а не временная папка.
    final appDir = await getApplicationSupportDirectory();
    return p.join(appDir.path, 'cache', 'images', 'srb2_mod_img_$safeName.png');
  }

  /// Картинка только из кэша на диске (без обращения к демону).
  static Future<String?> cachedImage(String hash) async {
    try {
      final path = await _imagePath(hash);
      if (path == null) return null;
      final file = File(path);
      return await file.exists() && await file.length() > 0 ? path : null;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> downloadAndGetCachedImage(String hash) async {
    if (hash.isEmpty) return null;
    try {
      final cached = await cachedImage(hash);
      if (cached != null) return cached;

      final filePath = await _imagePath(hash);
      if (filePath == null) return null;
      // downloadFile сам создаёт папку кэша.
      final ok = await downloadFile(hash: _clean(hash), outputFilePath: filePath, timeout: const Duration(seconds: 90));
      return ok ? filePath : null;
    } catch (e) {
      AppLog.console('Image cache error: $e');
      return null;
    }
  }

  /// Адрес, на который ведёт pointer [address] (по цепочке до конца), как
  /// `ant pointer get`; null — такого pointer нет (это адрес файла) или демон
  /// не ответил.
  static Future<String?> resolvePointer(String address) async {
    try {
      final target = await _client.pointerResolve(_clean(address)).timeout(const Duration(seconds: 90));
      return target.target.isEmpty ? null : target.target;
    } catch (e) {
      if (e is! NotFoundError) AppLog.console('Pointer $address: $e');
      return null;
    }
  }

  /// Файл репозитория по [address]: pointer (берётся файл, на который он
  /// ведёт, — так репозиторий можно обновлять, не меняя адреса) или сам адрес
  /// файла. Возвращает (текст, pointer или null).
  static Future<(String?, String?)> downloadRepository(String address) async {
    final clean = _clean(address);
    final target = await resolvePointer(clean);
    final text = await downloadText(target ?? clean);
    return (text, target == null ? null : clean);
  }

  static Future<String?> downloadText(String hash) async {
    final appDir = await getApplicationSupportDirectory();
    final tmp = p.join(appDir.path, 'cache',
        'repo_index_${DateTime.now().millisecondsSinceEpoch}.json');
    try {
      final ok = await downloadFile(hash: hash, outputFilePath: tmp, timeout: const Duration(minutes: 3));
      if (!ok) return null;
      return await File(tmp).readAsString();
    } finally {
      final f = File(tmp);
      if (await f.exists()) await f.delete();
    }
  }

  static Future<String?> calculateFileMd5(String filePath) async {
    try {
      return await Isolate.run(() async {
        final file = File(filePath);
        if (!await file.exists()) return null;
        final digest = await md5.bind(file.openRead()).first;
        return digest.toString();
      });
    } catch (e) {
      AppLog.console('MD5 calculation error: $e');
      return null;
    }
  }
}