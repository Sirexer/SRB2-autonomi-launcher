/// Когда и из какого коммита собран лаунчер: сборка в CI передаёт
/// `--dart-define=BUILD_DATE=...` и `--dart-define=BUILD_COMMIT=...`.
/// По ним видно, последняя ли версия у человека (Настройки → Общие, журнал).
class BuildInfo {
  /// Время сборки в UTC, например `2026-11-12 05:55 UTC`; пусто — собрано локально.
  static const date = String.fromEnvironment('BUILD_DATE');

  /// Короткий хэш коммита; пусто — собрано локально.
  static const commit = String.fromEnvironment('BUILD_COMMIT');

  /// Версия лаунчера — тег релиза (`beta-release2`); пусто — не релиз.
  static const version = String.fromEnvironment('BUILD_VERSION');

  /// Версия Flutter, которой собран лаунчер.
  static const flutter = String.fromEnvironment('BUILD_FLUTTER');

  static bool get isLocal => date.isEmpty;

  /// Одной строкой: `2026-11-12 05:55 UTC · 61d6b43 · Flutter 3.47.9` или пусто.
  static String get summary => [
        if (version.isNotEmpty) version,
        if (date.isNotEmpty) date,
        if (commit.isNotEmpty) commit,
        if (flutter.isNotEmpty) 'Flutter $flutter',
      ].join(' · ');
}
