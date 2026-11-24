import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../i18n.dart';
import '../models/game.dart';
import '../models/mod_item.dart';
import '../models/srb2_server.dart';
import 'addon_paths.dart';
import 'antd_daemon.dart';
import 'autonomi_service.dart';
import 'downloads.dart';
import 'platform_utils.dart';
import 'server_files.dart';
import 'srb2_file_transfer.dart';

/// Файл из подключённых репозиториев (для скачивания аддонов сервера по MD5).
typedef RepoFileRef = (ModItem mod, ModFile file);

/// Откуда скачивается аддон сервера.
enum ServerFileSource { mirror, server, repository }

/// Скачивание аддонов сервера (кнопки Download missing / Join на вкладке
/// Servers). Живёт отдельно от вкладки: если уйти на другую вкладку,
/// скачивание продолжается, а по возвращении вкладка показывает его ход.
class ServerDownloads extends ChangeNotifier {
  ServerDownloads._();
  static final ServerDownloads instance = ServerDownloads._();

  /// Индекс файлов папки игры и где лежат аддоны выбранного сервера
  /// (MD5 → путь, '' — нет).
  LocalFileIndex? index;
  final Map<String, String> local = {};

  /// MD5 → прогресс (null — неизвестен) идущих скачиваний, ошибки, источник.
  final Map<String, double?> downloading = {};
  final Map<String, String> errors = {};
  final Map<String, ServerFileSource> sourceOf = {};

  /// Идёт пакетное скачивание; для какого сервера (ключ строки списка).
  bool busy = false;
  String? serverKey;
  bool cancelled = false;
  int batchIndex = 0;
  int batchTotal = 0;

  void cancel() {
    cancelled = true;
    notifyListeners();
  }

  /// Что-то поменяли снаружи (вкладка проверила файлы сервера).
  void changed() => notifyListeners();

  /// Источники по порядку: ваши репозитории (по MD5 — не нагружают
  /// сервер), HTTP-зеркало сервера, сам сервер по UDP (как в игре). Не
  /// вышло — пробуется следующий.
  static List<ServerFileSource> sourcesFor(ServerFile f, ServerInfo info, Map<String, RepoFileRef> repoFiles) {
    if (f.isFolder) return const [];
    final fileId = info.files.indexOf(f);
    return [
      if (repoFiles.containsKey(f.md5)) ServerFileSource.repository,
      if (ServerFileDownloader.isUsableMirror(info.httpSource)) ServerFileSource.mirror,
      // "Too large" сервер 2.2.15 тоже помечает как "отдаст" — тогда сработает следующий источник.
      if (f.willSend == ServerFileSend.yes && Srb2FileTransfer.canRequest(fileId)) ServerFileSource.server,
    ];
  }

  static String sourceLabel(ServerFileSource? s) => switch (s) {
        ServerFileSource.mirror => tr('the HTTP mirror'),
        ServerFileSource.server => tr('the server'),
        ServerFileSource.repository => tr('your repository'),
        null => '',
      };

  /// Скачивает [files] сервера [key] в папку загрузок игры. true — все
  /// скачаны и не было отмены.
  Future<bool> download({
    required List<ServerFile> files,
    required ServerInfo info,
    required String key,
    required String host,
    required int port,
    required String serverName,
    required GameDef game,
    required String? gameFolder,
    required Map<String, RepoFileRef> repoFiles,
  }) async {
    if (gameFolder == null || files.isEmpty) return files.isEmpty;
    if (busy) return false;
    final downloadDir = p.joinAll([gameFolder, ...game.downloadPath]);
    final center = DownloadCenter.instance;

    busy = true;
    serverKey = key;
    cancelled = false;
    batchIndex = 0;
    batchTotal = files.length;
    notifyListeners();

    Srb2FileTransfer? transfer; // одно UDP-соединение на все файлы сервера
    var allOk = true;
    try {
      for (final f in files) {
        if (cancelled) break;
        batchIndex++;
        downloading[f.md5] = null;
        errors.remove(f.md5);
        notifyListeners();
        final item = center.start(f.name, tr('Server: {name}', {'name': serverName}), cancel: cancel);

        String? lastError;
        var ok = false;
        try {
          final target = await ServerFileDownloader.targetPath(downloadDir, f);
          if (target == null) throw const TransferException('Bad file name');

          for (final source in sourcesFor(f, info, repoFiles)) {
            if (cancelled) break;
            sourceOf[f.md5] = source;
            downloading[f.md5] = null;
            notifyListeners();
            center.update(item, source: sourceLabel(source));
            void progress(double value) {
              downloading[f.md5] = value;
              notifyListeners();
              center.update(item, progress: value);
            }

            var savedTo = target;

            try {
              switch (source) {
                case ServerFileSource.mirror:
                  await ServerFileDownloader.downloadFromMirror(
                    httpSource: info.httpSource,
                    file: f,
                    targetPath: target,
                    onProgress: (got, total) {
                      if (total > 0) progress(got / total);
                    },
                  );
                case ServerFileSource.server:
                  transfer ??= Srb2FileTransfer(host, port, protocol: game.protocol);
                  await transfer.download(
                    fileId: info.files.indexOf(f),
                    file: f,
                    targetPath: target,
                    onProgress: (got, total) {
                      if (total > 0) progress(got / total);
                    },
                    isCancelled: () => cancelled,
                  );
                case ServerFileSource.repository:
                  if (!await AntdDaemon.ensureRunning()) {
                    throw TransferException(tr('Autonomi is not running'));
                  }
                  // Как на вкладке Addons: DOWNLOAD/<аддон>/<версия>/, под именем от сервера.
                  savedTo = await repoTarget(downloadDir, repoFiles[f.md5]!, f);
                  final done = await AutonomiService.downloadFile(
                    hash: repoFiles[f.md5]!.$2.hash,
                    outputFilePath: savedTo,
                    expectedMd5: f.md5,
                    expectedSize: f.size,
                    onStage: (stage) => center.update(item, stage: stage),
                    onChunks: (done, total) {
                      center.update(item, chunksDone: done, chunksTotal: total);
                      if (total > 0) {
                        progress((done / total).clamp(0.0, 0.99).toDouble());
                      }
                    },
                    onProgress: (value, _, _) => progress(value),
                  );
                  if (!done) throw TransferException(tr('Download from the repository failed'));
              }
              ok = true;
              index?.add(savedTo);
              local[f.md5] = savedTo;
              notifyListeners();
              break;
            } on TransferCancelled {
              break;
            } catch (e) {
              lastError = e is FormatException ? e.message : '$e';
            }
          }
        } catch (e) {
          lastError = '$e';
        }

        if (ok) {
          center.finish(item, DownloadState.done);
        } else {
          allOk = false;
          if (cancelled) {
            center.finish(item, DownloadState.cancelled);
          } else {
            errors[f.md5] = lastError ?? tr('No source to download from');
            center.finish(item, DownloadState.failed, error: errors[f.md5]);
          }
        }
        downloading.remove(f.md5);
        notifyListeners();
      }
    } finally {
      // Обязательно: иначе сервер продолжит слать нам фрагменты.
      try {
        await transfer?.close();
      } catch (_) {}
      busy = false;
      notifyListeners();
    }
    return allOk && !cancelled;
  }

  /// Путь для аддона сервера, найденного в репозитории: папка его версии.
  /// Если там уже другой файл с тем же именем — подпапка по MD5 (ничего не затираем).
  static Future<String> repoTarget(String downloadDir, RepoFileRef ref, ServerFile f) async {
    final name = PlatformUtils.safeFileName(f.name) ?? ref.$2.name;
    final path = AddonPaths.target(downloadDir, ref.$1, ref.$2, fileName: name);
    if (!await File(path).exists() || await LocalFileIndex.md5Of(path) == f.md5) return path;
    return p.join(p.dirname(path), f.md5.substring(0, 8), name);
  }
}
