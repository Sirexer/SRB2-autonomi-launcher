import '../models/mod_item.dart';

/// Какая версия аддона скачана и есть ли новее.
class AddonUpdates {
  AddonUpdates._();

  /// Один и тот же файл в разных версиях: по MD5, без него — имя и размер.
  static String identity(ModFile f) =>
      f.md5.isNotEmpty ? 'md5:${f.md5}' : 'name:${f.name.toLowerCase()}|${f.size}';

  /// Скачанная версия аддона [mod]; [present] — какие его файлы найдены
  /// ([ModFile.key]). Это самая новая версия, от которой есть свой файл —
  /// которого нет в других версиях: файл, не менявшийся между версиями
  /// (например, музыка), версию не определяет. Если все найденные файлы
  /// такие — самая новая версия, где они есть. null — ничего не найдено.
  static AddonVersion? installed(ModItem mod, Set<String> present) {
    if (present.isEmpty) return null;
    final versionsOf = <String, Set<String>>{};
    for (final v in mod.versions) {
      for (final f in v.files) {
        versionsOf.putIfAbsent(identity(f), () => {}).add(v.name);
      }
    }
    for (final v in mod.versions) {
      if (v.files.any((f) => present.contains(f.key) && versionsOf[identity(f)]!.length == 1)) return v;
    }
    for (final v in mod.versions) {
      if (v.files.any((f) => present.contains(f.key))) return v;
    }
    return null;
  }

  /// Есть ли версия новее скачанной: (скачанная, последняя) или null.
  static (AddonVersion, AddonVersion)? update(ModItem mod, Set<String> present) {
    final have = installed(mod, present);
    final latest = mod.latest;
    if (have == null || latest == null || identical(have, latest) || have.name == latest.name) return null;
    return (have, latest);
  }

  /// Что изменилось в репозитории: новые аддоны и аддоны с новыми версиями.
  static ({List<ModItem> added, List<ModItem> updated}) diff(List<ModItem> before, List<ModItem> after) {
    String id(ModItem m) => '${m.id}\u0000${m.name}';
    final old = {for (final m in before) id(m): m};
    final added = <ModItem>[];
    final updated = <ModItem>[];
    for (final m in after) {
      final was = old[id(m)];
      if (was == null) {
        added.add(m);
      } else {
        final had = {for (final v in was.versions) v.name};
        if (m.versions.any((v) => !had.contains(v.name))) updated.add(m);
      }
    }
    return (added: added, updated: updated);
  }
}
