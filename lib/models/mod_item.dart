import 'dart:io';

import '../services/platform_utils.dart';
import 'game.dart';
import '../utils/natural_compare.dart';

/// Тип файла из репозитория:
/// - [addon] — обычный аддон для игры (pk3, wad, lua, soc).
/// - [models] — набор 3D моделей (zip/pk3).
/// - [appWindows] — сборка/исполняемый файл для Windows (zip с exe/dll или exe).
/// - [appLinux] — сборка/исполняемый файл для Linux (бинарник или AppImage).
enum ModFileType {
  addon,
  models,
  appWindows,
  appLinux;

  static ModFileType fromString(String? raw) {
    return switch (raw?.trim().toLowerCase()) {
      'models' => ModFileType.models,
      'app_windows' => ModFileType.appWindows,
      'app_linux' => ModFileType.appLinux,
      _ => ModFileType.addon,
    };
  }

  String get wireName => switch (this) {
        ModFileType.addon => 'addon',
        ModFileType.models => 'models',
        ModFileType.appWindows => 'app_windows',
        ModFileType.appLinux => 'app_linux',
      };

  bool isSupportedOnPlatform({bool? isWindows, bool? isLinux}) {
    final win = isWindows ?? Platform.isWindows;
    final lin = isLinux ?? Platform.isLinux;
    return switch (this) {
      ModFileType.addon => true,
      ModFileType.models => true,
      ModFileType.appWindows => win,
      ModFileType.appLinux => lin,
    };
  }

  bool get isBuild => this == ModFileType.appWindows || this == ModFileType.appLinux;
}

/// Файл аддона. В формате с версиями (index_version 2) у каждого файла
/// свои `version` и `changelog`; файлы с одинаковой версией — одна версия.
class ModFile {
  final String name;
  final String hash;
  final String md5; // эталонная контрольная сумма, нижний регистр
  final int size; // размер в байтах (для процентов), 0 — неизвестен
  final String version; // '' — версия не указана
  final String changelog;
  final ModFileType type;

  /// Для каких игр файл (коды [GameDef.id]): `"games": ["srb2", "drrr"]`
  /// у файла или у аддона; по умолчанию — SRB2.
  final List<String> games;

  ModFile({
    required this.name,
    required this.hash,
    required this.md5,
    this.size = 0,
    this.version = '',
    this.changelog = '',
    this.games = defaultGames,
    this.type = ModFileType.addon,
  });

  static const defaultGames = ['srb2'];

  bool supports(String gameId) => games.contains(gameId);

  /// Разбирает `games`: список или одна строка; коды — в нижнем регистре,
  /// синонимы ("RingRacers") приводятся к коду. null — поле не указано.
  static List<String>? parseGames(dynamic raw) {
    final items = raw is List ? raw : (raw is String ? raw.split(RegExp(r'[,\s]+')) : null);
    if (items == null) return null;
    final out = <String>[];
    for (final g in items) {
      final id = Games.normalizeId('$g');
      if (id.isNotEmpty && !out.contains(id)) out.add(id);
    }
    return out.isEmpty ? null : out;
  }

  /// Ключ файла внутри аддона: одно имя может быть у разных версий.
  String get key => '$version\u0000$name';

  /// [defaultVersion]/[defaultChangelog] — из старого формата, где они
  /// указывались у аддона, а не у файла.
  factory ModFile.fromJson(
    Map<String, dynamic> json, {
    String defaultVersion = '',
    String defaultChangelog = '',
    List<String> inheritedGames = ModFile.defaultGames,
  }) {
    final version = '${json['version'] ?? ''}'.trim();
    final changelog = json['changelog'] is String ? (json['changelog'] as String).trim() : '';
    return ModFile(
      // Имя попадает в путь внутри DOWNLOAD — чистим его от "../", ":" и т.п.
      name: PlatformUtils.safeFileName('${json['name'] ?? ''}') ?? 'mod_file.pk3',
      hash: '${json['hash'] ?? ''}'.trim(),
      md5: '${json['md5'] ?? ''}'.trim().toLowerCase(),
      size: int.tryParse('${json['size'] ?? 0}') ?? 0,
      version: version.isEmpty ? defaultVersion : version,
      changelog: changelog.isEmpty ? defaultChangelog : changelog,
      games: parseGames(json['games']) ?? inheritedGames,
      type: ModFileType.fromString(json['type'] as String?),
    );
  }
}

/// Версия аддона: её файлы и changelog.
class AddonVersion {
  final String name;
  final String changelog;
  final List<ModFile> files;

  const AddonVersion(this.name, this.changelog, this.files);

  String get label => name.isEmpty ? 'Unversioned' : name;
}

class ModItem {
  /// Категория для аддонов, у которых в манифесте её нет. Всегда в конце списка.
  static const defaultCategory = 'Other';

  /// Категории по алфавиту, [defaultCategory] — последней.
  static int compareCategories(String a, String b) {
    if (a == b) return 0;
    if (a == defaultCategory) return 1;
    if (b == defaultCategory) return -1;
    return naturalCompare(a, b);
  }

  /// Аддоны по алфавиту (без учёта регистра, числа как числа).
  static int compareByName(ModItem a, ModItem b) => naturalCompare(a.name, b.name);

  final String id;
  final String name;
  final String category;
  final String imageHash;
  final String repositorySource;

  /// `tags`, `uploader`, `description` — одно значение на все версии или
  /// своё у версий: `"tags": {"2.0.2": [...], "2.0.3": [...]}`. Значение
  /// версии без своей записи — от ближайшей более старой версии из записей
  /// (иначе ближайшей более новой). Пусто — у аддона это поле одно на все.
  final Map<String, List<String>> tagsByVersion;
  final Map<String, String> uploaderByVersion;
  final Map<String, String> descriptionByVersion;

  final List<String> _tags;
  final String _uploader;
  final String _description;

  /// Версии от новой к старой (сортировка "как числа": V1.10 > V1.9).
  final List<AddonVersion> versions;

  /// Все файлы всех версий.
  final List<ModFile> files;

  ModItem({
    required this.id,
    required this.name,
    required this.category,
    required String uploader,
    required String description,
    required this.imageHash,
    required this.versions,
    required this.repositorySource,
    required List<String> tags,
    this.tagsByVersion = const {},
    this.uploaderByVersion = const {},
    this.descriptionByVersion = const {},
  })  : _tags = tags,
        _uploader = uploader,
        _description = description,
        files = [for (final v in versions) ...v.files];

  /// Теги, кто загрузил, описание последней версии — для списка, поиска и
  /// панели тегов. У выбранной версии — [tagsFor] и т.п.
  List<String> get tags => tagsFor(version);

  /// Кто загрузил аддон в репозиторий (`uploader`; в старых манифестах —
  /// `authors`, через запятую).
  String get uploader => uploaderFor(version);
  String get description => descriptionFor(version);

  List<String> tagsFor(String? version) => _forVersion(tagsByVersion, version) ?? _tags;
  String uploaderFor(String? version) => _forVersion(uploaderByVersion, version) ?? _uploader;
  String descriptionFor(String? version) => _forVersion(descriptionByVersion, version) ?? _description;

  /// Значение версии [version]: своё, иначе ближайшей более старой версии из
  /// [byVersion], иначе ближайшей более новой; null — записей нет.
  static T? _forVersion<T>(Map<String, T> byVersion, String? version) {
    if (byVersion.isEmpty) return null;
    final v = version ?? '';
    if (byVersion.containsKey(v)) return byVersion[v];
    final keys = byVersion.keys.toList()..sort(naturalCompare);
    String? older, newer;
    for (final k in keys) {
      if (naturalCompare(k, v) < 0) {
        older = k;
      } else {
        newer ??= k;
      }
    }
    return byVersion[older ?? newer];
  }

  /// Последняя версия.
  AddonVersion? get latest => versions.isEmpty ? null : versions.first;
  String get version => latest?.name ?? '';
  String get changelog => latest?.changelog ?? '';
  bool get hasSeveralVersions => versions.length > 1;

  AddonVersion? versionNamed(String? name) {
    for (final v in versions) {
      if (v.name == name) return v;
    }
    return null;
  }

  /// Для каких игр есть файлы аддона.
  Set<String> get games => {for (final f in files) ...f.games};

  /// Аддон только с файлами для игры [gameId]; null — для неё файлов нет.
  /// [orBase] — и файлы основы (своя игра с `base_addons`).
  ModItem? forGame(String gameId, {String? orBase}) {
    if (files.isEmpty) return null;
    bool fits(ModFile f) => f.supports(gameId) || (orBase != null && f.supports(orBase));
    if (files.every(fits)) return this;
    final own = [for (final f in files) if (fits(f)) f];
    if (own.isEmpty) return null;
    return ModItem(
      id: id,
      name: name,
      category: category,
      uploader: _uploader,
      description: _description,
      imageHash: imageHash,
      versions: groupVersions(own),
      repositorySource: repositorySource,
      tags: _tags,
      tagsByVersion: tagsByVersion,
      uploaderByVersion: uploaderByVersion,
      descriptionByVersion: descriptionByVersion,
    );
  }

  /// Ключ аддона (для запоминания выбранной версии).
  String get key => '$repositorySource\u0000$id\u0000$name';

  /// Группирует файлы по версиям; порядок файлов внутри версии сохраняется.
  static List<AddonVersion> groupVersions(List<ModFile> files) {
    final byVersion = <String, List<ModFile>>{};
    for (final f in files) {
      byVersion.putIfAbsent(f.version, () => []).add(f);
    }
    final versions = [
      for (final e in byVersion.entries)
        AddonVersion(
          e.key,
          e.value.map((f) => f.changelog).firstWhere((c) => c.isNotEmpty, orElse: () => ''),
          e.value,
        ),
    ];
    versions.sort((a, b) => naturalCompare(b.name, a.name)); // новые — первыми
    return versions;
  }

  /// Строка или список строк → строка через запятую.
  static String _join(dynamic v) => v is List
      ? v.map((e) => '$e'.trim()).where((e) => e.isNotEmpty).join(', ')
      : (v == null ? '' : '$v'.trim());

  /// Теги в нижнем регистре.
  static List<String> _tagList(dynamic v) =>
      v is List ? [for (final t in v) if ('$t'.trim().isNotEmpty) '$t'.toLowerCase().trim()] : const [];

  /// Поле по версиям (`{"2.0.2": ...}`) → версия → значение; не словарь — пусто.
  static Map<String, T> _byVersion<T>(dynamic v, T Function(dynamic) parse) =>
      v is Map ? {for (final e in v.entries) '${e.key}'.trim(): parse(e.value)} : const {};

  factory ModItem.fromJson(
    Map<String, dynamic> json, {
    required String source,
    bool? isWindows,
    bool? isLinux,
  }) {
    // Старый формат: одна версия и changelog у всего аддона.
    final legacyVersion = '${json['version'] ?? ''}'.trim();
    final legacyChangelog = json['changelog'] is String ? (json['changelog'] as String).trim() : '';

    // Игры аддона — по умолчанию для его файлов: одно значение на все версии
    // или по версиям (`{"2.0.2": ["srb2"], "2.0.3": ["srb2", "drrr"]}`, то же
    // правило, что у tags); `games` у файла — важнее.
    final rawGames = json['games'];
    final addonGames = (rawGames is Map ? null : ModFile.parseGames(rawGames)) ?? ModFile.defaultGames;
    final gamesByVersion = <String, List<String>>{
      if (rawGames is Map)
        for (final e in rawGames.entries) '${e.key}'.trim(): ?ModFile.parseGames(e.value),
    };
    List<String> gamesFor(String version) => _forVersion(gamesByVersion, version) ?? addonGames;

    final rawFiles = json['files'] as List<dynamic>? ?? [];
    final allFiles = [
      for (final f in rawFiles)
        if (f is Map<String, dynamic>)
          ModFile.fromJson(f,
              defaultVersion: legacyVersion,
              defaultChangelog: legacyChangelog,
              inheritedGames: gamesFor(switch ('${f['version'] ?? ''}'.trim()) {
                '' => legacyVersion,
                final v => v,
              })),
    ];
    final files = [
      for (final f in allFiles)
        if (f.type.isSupportedOnPlatform(isWindows: isWindows, isLinux: isLinux)) f,
    ];

    if (files.isEmpty && json['file_hash'] != null) {
      files.add(ModFile(
        name: PlatformUtils.safeFileName('${json['id'] ?? 'mod'}.pk3') ?? 'mod.pk3',
        hash: '${json['file_hash']}',
        md5: '${json['md5'] ?? ''}'.trim().toLowerCase(),
        size: int.tryParse('${json['size'] ?? 0}') ?? 0,
        version: legacyVersion,
        changelog: legacyChangelog,
        games: gamesFor(legacyVersion),
      ));
    }

    // uploader: строка или список; если его нет — старое поле authors.
    final rawUploader = json['uploader'] ?? json['authors'];

    final name = '${json['name'] ?? ''}'.trim();
    final category = '${json['category'] ?? ''}'.trim();

    return ModItem(
      id: '${json['id'] ?? ''}',
      name: name.isEmpty ? 'Untitled' : name,
      category: category.isEmpty ? defaultCategory : category,
      // tags / uploader / description — одно на все версии или по версиям.
      uploader: rawUploader is Map ? '' : _join(rawUploader),
      description: json['description'] is Map ? '' : '${json['description'] ?? ''}',
      imageHash: '${json['image_hash'] ?? ''}',
      versions: groupVersions(files),
      repositorySource: source,
      tags: _tagList(json['tags']),
      tagsByVersion: _byVersion(json['tags'], _tagList),
      uploaderByVersion: _byVersion(rawUploader, _join),
      descriptionByVersion: _byVersion(json['description'], (v) => v == null ? '' : '$v'),
    );
  }
}
