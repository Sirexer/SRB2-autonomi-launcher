/// Как игра читает 3D-модели (только OpenGL): файл со списком моделей,
/// папка с ними и пределы строк списка (hw_md2.c, HWR_InitModels).
///
/// Строка списка — `имя путь масштаб смещение`, игра читает её через
/// `fscanf("%Ns %31s %f %f")`: имя длиннее [nameMax] или путь длиннее 31
/// символа рвут строку, и всё ниже молча не читается.
class ModelFormat {
  /// Список моделей (`models.dat`, в SRB2Kart — `mdls.dat`).
  final String datFile;

  /// Папка моделей (`models`, в SRB2Kart — `mdls`); пути в списке — от неё.
  final String folder;

  /// Самое длинное имя в списке.
  final int nameMax;

  /// Самый длинный путь к модели в списке.
  static const pathMax = 31;

  /// Понимает ли игра префикс `PLAYER` (`PLAYERFANG` — только скин fang).
  final bool playerPrefix;

  /// Другие списки, которые игра читает после [datFile] (их строки
  /// перекрывают наши): у BlanKart — `blanmodels.dat`.
  final List<String> extraDatFiles;

  /// Читает ли игра MD3 (SRB2 2.1 / Legacy — только MD2).
  final bool md3;

  const ModelFormat({
    required this.datFile,
    required this.folder,
    required this.nameMax,
    this.playerPrefix = true,
    this.extraDatFiles = const [],
    this.md3 = true,
  });

  /// Модель персонажа (скина), а не объекта (спрайта). Как в игре:
  /// `PLAYERимя` — скин; иначе игра сначала ищет спрайт, а имена спрайтов —
  /// ровно 4 символа, так что имя другой длины — скин. (Скин из 4 букв без
  /// такого спрайта игра тоже найдёт, но здесь он попадёт в объекты.)
  bool isSkin(String name) {
    final n = name.toUpperCase();
    if (playerPrefix && n.startsWith('PLAYER') && n.length > 6) return true;
    return n.length != 4;
  }

  static const srb2 = ModelFormat(datFile: 'models.dat', folder: 'models', nameMax: 25);
  static const srb2kart = ModelFormat(datFile: 'mdls.dat', folder: 'mdls', nameMax: 19, playerPrefix: false);
  static const ringRacers = ModelFormat(datFile: 'models.dat', folder: 'models', nameMax: 23);

  /// SRB2 Legacy (2.1): `md2.dat` и папка `md2` только в домашней папке
  /// игры, имя до 19 символов, без PLAYER, только MD2.
  static const legacy = ModelFormat(
    datFile: 'md2.dat',
    folder: 'md2',
    nameMax: 19,
    playerPrefix: false,
    md3: false,
  );

  /// Формат встроенной игры; null — модели не поддерживаются.
  static ModelFormat? forEngine(String engine) => switch (engine) {
        'srb2' => srb2,
        'srb2legacy' => legacy,
        'srb2kart' => srb2kart,
        'drrr' => ringRacers,
        _ => null,
      };

  /// Из описания своей игры (`"models": {...}`), недостающее — из [base].
  /// `"models": false` — модели не поддерживаются.
  static ModelFormat? fromJson(Object? j, ModelFormat? base) {
    if (j == null) return base;
    if (j == false) return null;
    if (j is! Map) throw const FormatException('"models" must be an object');
    String str(String k, String? def) {
      final v = j[k];
      if (v is String && v.trim().isNotEmpty) return v.trim();
      if (def != null) return def;
      throw FormatException('"models": "$k" is missing');
    }

    final max = j['name_max'];
    final extra = j['extra_files'];
    return ModelFormat(
      datFile: str('file', base?.datFile),
      folder: str('folder', base?.folder),
      nameMax: max is num ? max.toInt().clamp(4, 64) : base?.nameMax ?? 25,
      playerPrefix: j['player_prefix'] is bool ? j['player_prefix'] as bool : base?.playerPrefix ?? true,
      md3: j['md3'] is bool ? j['md3'] as bool : base?.md3 ?? true,
      extraDatFiles: extra is List
          ? [for (final x in extra) if ('$x'.trim().isNotEmpty) '$x'.trim()]
          : base?.extraDatFiles ?? const [],
    );
  }
}
