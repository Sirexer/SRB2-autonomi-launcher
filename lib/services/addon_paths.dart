import 'package:path/path.dart' as p;

import '../models/mod_item.dart';
import 'platform_utils.dart';

/// Где лежат файлы аддонов: `DOWNLOAD/<Имя аддона>/<версия>/<файл>`.
///
/// SRB2 ищет аддоны по имени и MD5 рекурсивно в папке игры (до 10 уровней),
/// поэтому разные версии могут лежать рядом, а сервер найдёт нужную по MD5.
class AddonPaths {
  AddonPaths._();

  /// Раскладывать по папкам `<аддон>/<версия>/` (настройка; по умолчанию да).
  /// Выключено — файлы кладутся прямо в DOWNLOAD.
  static bool versionFolders = true;

  static String addonFolder(ModItem mod) =>
      PlatformUtils.safeFileName(mod.name) ?? PlatformUtils.safeFileName(mod.id) ?? 'Addon';

  /// Куда скачивать файл версии. [fileName] — другое имя файла (например,
  /// то, под которым его ждёт сервер).
  static String target(String downloadDir, ModItem mod, ModFile file, {String? fileName}) =>
      versionFolders ? versionedTarget(downloadDir, mod, file, fileName: fileName) : p.join(downloadDir, fileName ?? file.name);

  /// `DOWNLOAD/<аддон>/<версия>/<файл>`.
  static String versionedTarget(String downloadDir, ModItem mod, ModFile file, {String? fileName}) {
    final version = PlatformUtils.safeFileName(file.version);
    return p.joinAll([
      downloadDir,
      addonFolder(mod),
      if (version != null) version,
      fileName ?? file.name,
    ]);
  }

  /// Где искать уже скачанный файл: папка версии, затем корень DOWNLOAD
  /// (туда сохраняли прошлые версии лаунчера).
  static List<String> candidates(String downloadDir, ModItem mod, ModFile file) => versionFolders
      ? [versionedTarget(downloadDir, mod, file), p.join(downloadDir, file.name)]
      : [p.join(downloadDir, file.name), versionedTarget(downloadDir, mod, file)];
}
