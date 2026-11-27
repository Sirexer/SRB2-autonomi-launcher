import 'dart:io';

import '../services/characters.dart' show BuiltInSonic;
import 'model_format.dart';
import 'skin_colors_data.dart';
import 'srb2_server.dart';

export 'model_format.dart';

/// Как получать список серверов с мастер-сервера.
enum MasterApi {
  /// SRB2: `GET <ms>/servers` и `<ms>/rooms` (комнаты, имена, версии).
  srb2,

  /// Ring Racers: `GET <ms>/games/RingRacers/<MODVERSION>/servers` —
  /// только адрес, порт и контакт.
  kart,
}

/// Поддерживаемая игра. Всё, что зависит от игры: папка данных, сборки,
/// мастер-серверы, сетевой протокол, режимы игры. Настройки каждой игры
/// хранятся отдельно (ключи с [prefsPrefix]).
class GameDef {
  /// Код игры в манифесте (`"games": ["srb2", "drrr"]`).
  final String id;

  /// Короткое имя для переключателя и подписей.
  final String name;
  final String fullName;

  /// Поддерживаемая версия (для подсказок).
  final String version;

  /// Главный файл данных — по нему узнаём папку игры.
  final String mainFile;

  /// Куда игра сама скачивает аддоны с серверов, относительно папки игры.
  /// Туда же лаунчер кладёт аддоны из репозиториев.
  final List<String> downloadPath;

  final List<String> defaultMasters;
  final MasterApi masterApi;
  final NetProtocol protocol;

  /// Режимы для -gametype (игра сравнивает без учёта регистра).
  final List<String> gametypes;

  /// Есть ли комнаты на мастер-сервере (-room).
  final bool hasRooms;

  /// Префикс ключей настроек: '' у SRB2 (старые ключи), 'drrr.' и т.д.
  final String prefsPrefix;

  final String windowsCommand;
  final String linuxCommand;
  final List<String> windowsExecutables;
  final List<String> linuxExecutables;

  /// Подстроки имени файла, по которым сканер отмечает сборки игры.
  final List<String> executableHints;

  /// Папки данных на Linux относительно HOME (подсказка для папки игры).
  final List<String> linuxDataFolders;

  /// Иконка игры (assets/games).
  String get iconAsset => 'assets/games/$engine.png';

  /// Файлы игры с палитрой PLAYPAL (относительно папки игры) — для картинок
  /// уровней в формате Doom-патча.
  final List<String> paletteFiles;

  /// Файлы игры со встроенными картами (для картинки карты сервера).
  final List<String> baseMapFiles;

  /// Файлы игры со встроенными персонажами в порядке загрузки: номер скина
  /// в игре = номер в общем списке (файлы игры, потом аддоны).
  final List<String> baseSkinFiles;

  /// Файлы игры с музыкой и MUSICDEF (для плеера).
  final List<String> musicFiles;

  /// Картинка уровня — lump PICTURE внутри карты (Ring Racers), а не MAPxxP.
  final bool pictureInsideMaps;

  /// Строка для `+connect` (поиск сервера в локальной сети).
  final String lanConnect;

  /// MODVERSION поддерживаемой версии (src/version.h, doomdef.h): по нему
  /// мастер-сервер сообщает о выходе новой версии, а у Kart Krew — ещё и
  /// выбирается список серверов (SRB2 56, SRB2Kart 10, Ring Racers 13).
  final int modVersion;

  /// MODID SRB2 для запроса версии (`versions/18`); у Kart Krew не нужен.
  final int modId;

  /// Своя игра (описание в JSON): код встроенной игры, на которой она
  /// основана; '' — встроенная. От него — параметры запуска, цвета, режимы
  /// и т.п. ([engine]); настройки и аддоны — по [id].
  final String engineId;

  /// Своя игра: иконка — файл (PNG); null — иконка основы.
  final String? iconFile;

  /// Своя игра: показывать и аддоны основы (`games` с кодом [engine]).
  final bool baseAddons;

  /// Своя игра: свои файлы игры с расширением аддонов (как [ownAddonFiles]).
  final List<String> customOwnFiles;

  /// Описание своей игры, как оно пришло в JSON (для экспорта).
  final Map<String, dynamic>? definition;

  /// Формат 3D-моделей своей игры (`"models"` в JSON), если он задан
  /// ([hasModelsOverride]); иначе — по [engine]. Смотрите [models].
  final ModelFormat? modelsOverride;
  final bool hasModelsOverride;

  /// Имя `.cfg`-файла конфига своей игры (`"config_file"` в JSON); null — как у [engine].
  final String? configFileOverride;

  /// Переопределения и дополнения редактора конфига из JSON (`"config"`).
  final Map<String, dynamic>? configDefinition;

  const GameDef({
    required this.id,
    required this.name,
    required this.fullName,
    required this.version,
    required this.mainFile,
    required this.downloadPath,
    required this.defaultMasters,
    required this.masterApi,
    required this.protocol,
    required this.gametypes,
    required this.hasRooms,
    required this.prefsPrefix,
    required this.windowsCommand,
    required this.linuxCommand,
    required this.windowsExecutables,
    required this.linuxExecutables,
    required this.executableHints,
    required this.linuxDataFolders,
    this.lanConnect = 'any',
    this.paletteFiles = const [],
    this.baseMapFiles = const [],
    this.pictureInsideMaps = false,
    this.musicFiles = const [],
    this.baseSkinFiles = const [],
    required this.modVersion,
    this.modId = 0,
    this.engineId = '',
    this.iconFile,
    this.baseAddons = false,
    this.customOwnFiles = const [],
    this.definition,
    this.modelsOverride,
    this.hasModelsOverride = false,
    this.configFileOverride,
    this.configDefinition,
  });

  /// Имя файла конфига игры (`config.cfg`, `kartconfig.cfg`, `ringconfig.cfg`, `blanconfig.cfg`).
  String get configFileName =>
      configFileOverride ??
      switch (engine) {
        'srb2kart' => 'kartconfig.cfg',
        'drrr' => 'ringconfig.cfg',
        _ => 'config.cfg',
      };

  /// Как игра читает 3D-модели; null — модели не поддерживаются.
  ModelFormat? get models => hasModelsOverride ? modelsOverride : ModelFormat.forEngine(engine);

  /// Своя игра (из JSON), а не встроенная.
  bool get isCustom => engineId.isNotEmpty;

  /// Код встроенной игры, как которая ведёт себя эта: у встроенной — [id].
  String get engine => engineId.isEmpty ? id : engineId;

  /// Код основы, чьи аддоны тоже показываются ([baseAddons]); null — нет.
  String? get addonBase => baseAddons && engine != id ? engine : null;

  /// Переменная режима Encore (зеркальная трасса с палитрой Encore):
  /// `+kartencore On` в SRB2Kart, `+encore On` в Ring Racers; null — режима
  /// нет. Игра включает его и при -warp, без открытия в меню; только в Race
  /// (в Ring Racers ещё в Versus).
  String? get encoreCvar => switch (engine) {
        'srb2kart' => 'kartencore',
        'drrr' => 'encore',
        _ => null,
      };

  /// Скорость игры (Gear): переменная и её значения (значение → подпись).
  /// SRB2Kart — `kartspeed` 0/1/2 (Easy/Normal/Hard), Ring Racers —
  /// `gamespeed` 0/1/2 (Gear 1–3; без параметра — Auto Gear). null — нет.
  (String, List<(String, String)>)? get gearCvar => switch (engine) {
        'srb2kart' => ('kartspeed', const [('0', 'Gear 1 (Easy)'), ('1', 'Gear 2 (Normal)'), ('2', 'Gear 3 (Hard)')]),
        'drrr' => ('gamespeed', const [('0', 'Gear 1'), ('1', 'Gear 2'), ('2', 'Gear 3')]),
        _ => null,
      };

  /// Боты (Ring Racers): `bots` 0 (Off) … 13 (Lv.MAX). null — в игре их нет.
  String? get botsCvar => engine == 'drrr' ? 'bots' : null;

  /// Свои файлы игры с расширением аддонов (.pk3): в списке «В папке игры» их
  /// нет. У SRB2Kart свои файлы — .kart/.srb/.dta, туда они и так не попадают.
  List<String> get ownAddonFiles => isCustom ? customOwnFiles : switch (id) {
        'srb2' => const ['srb2.pk3', 'zones.pk3', 'characters.pk3', 'patch.pk3', 'music.pk3', 'patch_music.pk3'],
        'srb2legacy' => const ['legacy.pk3'],
        'drrr' => const [
            'bios.pk3', 'scripts.pk3', 'gfx.pk3', 'textures_general.pk3', 'textures_segazones.pk3', //
            'textures_originalzones.pk3', 'chars.pk3', 'followers.pk3', 'maps.pk3', 'unlocks.pk3', //
            'staffghosts.pk3', 'patch.pk3', 'sounds.pk3', 'music.pk3', 'altmusic.pk3', 'shaders.pk3',
          ],
        _ => const [],
      };

  /// Встроенные цвета персонажей (номер = SKINCOLOR_*).
  List<(String, List<int>)> get skinColors => switch (engine) {
        'srb2kart' => VanillaSkinColors.srb2kart,
        'drrr' => VanillaSkinColors.drrr,
        'srb2legacy' => VanillaSkinColors.srb2legacy,
        _ => VanillaSkinColors.srb2,
      };

  /// Кадры спрайта XTRA для иконки персонажа по порядку предпочтения:
  /// у SRB2 — C (жизни), у Ring Racers — B (как в chars.pk3:
  /// skins/<персонаж>/XTRAB0), затем A и C.
  String get skinIconFrames => engine == 'drrr' ? 'BAC' : 'C';

  /// Портрет XTRAB0 уже в цветах персонажа (SRB2); в Ring Racers XTRAB —
  /// значок «Wanted», его без перекраски не показать.
  bool get skinPortraits => engine != 'drrr';

  /// В выборе персонажа (Launch) — портрет (charsel в SRB2 Legacy), а не
  /// маленькая иконка.
  bool get pickerPortraits => engine == 'srb2legacy';

  /// У персонажей есть статы карта (скорость и вес, S_SKIN kartspeed/kartweight).
  bool get kartStats => engine == 'srb2kart' || engine == 'drrr';

  /// У Соника, Тейлза и Наклза описания из кода SRB2 (меню выбора персонажа).
  bool get vanillaSkinDescriptions => engine == 'srb2' || engine == 'srb2legacy';

  /// Есть консольная переменная http_source (HTTP-зеркало аддонов); в SRB2
  /// 2.1 (Legacy) её нет.
  bool get hasHttpSource => engine != 'srb2legacy';

  /// Соник задан в коде игры, а не в S_SKIN: SRB2 2.1 (Legacy) и SRB2Kart
  /// (и его форки, например BlanKart).
  BuiltInSonic get builtInSonic => switch (engine) {
        'srb2legacy' => BuiltInSonic.legacy,
        'srb2kart' => BuiltInSonic.kart,
        _ => BuiltInSonic.none,
      };

  /// Вкладка Progress по gamedata.dat: SRB2 2.2, Legacy (форк 2.1) и
  /// SRB2Kart (kartdata.dat). У Ring Racers — своя вкладка (ringdata.dat).
  /// У своих игр файлы прогресса бывают другими — у них вкладки нет.
  bool get hasProgress => id == 'srb2' || id == 'srb2legacy' || id == 'srb2kart';

  /// Цвета для выбора `+color` в Launch: имена — как их принимает игра,
  /// ramp — для образца, который рисуется в палитре SRB2 2.2. У SRB2 Legacy
  /// своя палитра (2.1), поэтому образец — тот же или похожий цвет 2.2.
  /// Супер-цвета не предлагаются.
  List<(String, List<int>)> get launchSkinColors {
    bool superColor(String n) => n.startsWith('Super ') || RegExp(r'^[TK]?SUPER\d').hasMatch(n);
    if (engine != 'srb2legacy') {
      return [for (final c in skinColors) if (c.$1 != 'None' && !superColor(c.$1)) c];
    }
    String key(String n) => n.toUpperCase().replaceAll(RegExp(r'[\s_]'), '');
    const like = {'STEELBLUE': 'SLATE', 'PEACH': 'PEACHY', 'DARKRED': 'CRIMSON', 'NEONGREEN': 'LIME', 'ZIM': 'FOREST'};
    final modern = {for (final c in VanillaSkinColors.srb2) key(c.$1): c.$2};
    return [
      for (final (name, ramp) in VanillaSkinColors.srb2legacy)
        if (name != 'None' && !superColor(name)) (name, modern[like[key(name)] ?? key(name)] ?? ramp),
    ];
  }

  /// startcolor по умолчанию (Sk_SetDefaultValue): какие 16 индексов
  /// палитры перекрашиваются в цвет персонажа.
  int get skinStartColor => engine == 'srb2kart' || engine == 'srb2legacy' ? 160 : 96;

  /// Ключ настройки этой игры.
  String key(String base) => '$prefsPrefix$base';

  /// Какие TypeOfLevel карт берут встроенные режимы (как в G_TOLFlag игр).
  static const _gametypeLevels = <String, Map<String, List<String>>>{
    'srb2': {
      'co-op': ['COOP'],
      'competition': ['COMPETITION'],
      'race': ['RACE'],
      'match': ['MATCH'],
      'team match': ['MATCH'],
      'tag': ['TAG'],
      'hide & seek': ['TAG'],
      'ctf': ['CTF'],
    },
    'srb2legacy': {
      'co-op': ['COOP'],
      'competition': ['COMPETITION'],
      'race': ['RACE'],
      'match': ['MATCH'],
      'team match': ['MATCH'],
      'tag': ['TAG'],
      'hide & seek': ['TAG'],
      'ctf': ['CTF'],
    },
    'srb2kart': {
      'race': ['RACE'],
      'battle': ['MATCH', 'BATTLE'],
    },
    'drrr': {
      'race': ['RACE'],
      'battle': ['BATTLE', 'MATCH'],
    },
  };

  /// TypeOfLevel встроенного режима [gametype]; null — режим не встроенный.
  List<String>? gametypeLevels(String gametype) => _gametypeLevels[engine]?[gametype.trim().toLowerCase()];

  /// Имя TypeOfLevel как в таблице игры: «Co-op» → COOP, «Single Player» → SOLO.
  static String normalizeLevelType(String t) {
    final n = t.toUpperCase().replaceFirst(RegExp(r'^TOL_'), '').replaceAll(RegExp(r'[^A-Z0-9]'), '');
    return switch (n) {
      'SP' || 'SINGLE' || 'SINGLEPLAYER' => 'SOLO',
      'CHRISTMAS' || 'WINTER' => 'XMAS',
      _ => n,
    };
  }

  /// Подходит ли карта с TypeOfLevel [mapTypes] режиму с [levels]. Если
  /// чего-то из них не знаем — считаем, что подходит.
  static bool levelFits(List<String> mapTypes, List<String> levels) {
    if (mapTypes.isEmpty || levels.isEmpty) return true;
    final map = {for (final t in mapTypes) normalizeLevelType(t)};
    return levels.any((l) => map.contains(normalizeLevelType(l)));
  }

  String defaultCommand({bool? windows}) => (windows ?? Platform.isWindows) ? windowsCommand : linuxCommand;

  List<String> knownExecutables({bool? windows}) =>
      (windows ?? Platform.isWindows) ? windowsExecutables : linuxExecutables;

  static String _base(String master) => master.endsWith('/') ? master.substring(0, master.length - 1) : master;

  /// Путь списка серверов на мастер-сервере [master]. [modVersion] — у
  /// Kart Krew список свой для каждой версии игры (по умолчанию — наша).
  String serversUrl(String master, {int? modVersion}) {
    final base = _base(master);
    return switch (masterApi) {
      MasterApi.srb2 => '$base/servers',
      // Игра добавляет ко всем запросам HMS_QUERY_VERSION ("?v=2.2"),
      // без него мастер-сервер Kart Krew не отдаёт список.
      MasterApi.kart => '$base/games/${protocol.application}/${modVersion ?? this.modVersion}/servers?v=2.2',
    };
  }

  /// Запрос последней версии игры (HMS_compare_mod_version): ответ
  /// "MODVERSION название", например "57 2.2.16".
  String versionUrl(String master) {
    final base = _base(master);
    return switch (masterApi) {
      MasterApi.srb2 => '$base/versions/$modId',
      MasterApi.kart => '$base/games/${protocol.application}/version?v=2.2',
    };
  }

  /// Разбор ответа на [versionUrl]; null — непонятный ответ.
  static GameRelease? parseVersion(String body) {
    final line = body.replaceAll('\r', '').split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
    final space = line.trim().indexOf(' ');
    if (space <= 0) return null;
    final number = int.tryParse(line.trim().substring(0, space));
    final name = line.trim().substring(space + 1).trim();
    return number == null || name.isEmpty ? null : GameRelease(number, name);
  }


  List<MasterServerEntry> parseServers(String body) => switch (masterApi) {
        MasterApi.srb2 => MasterServerParser.parseServers(body),
        MasterApi.kart => MasterServerParser.parseKartServers(body, version: version),
      };

  @override
  String toString() => id;
}

/// Последняя версия игры по данным мастер-сервера.
class GameRelease {
  /// MODVERSION.
  final int number;

  /// Название версии ("2.2.16").
  final String name;

  const GameRelease(this.number, this.name);
}

/// Все поддерживаемые игры.
class Games {
  Games._();

  static const srb2 = GameDef(
    id: 'srb2',
    name: 'SRB2',
    fullName: 'Sonic Robo Blast 2',
    version: '2.2.15',
    mainFile: 'srb2.pk3',
    downloadPath: ['DOWNLOAD'],
    defaultMasters: ['https://ds.ms.srb2.org/MS/0', 'https://ms.weissblatt.cc/api/srb2http'],
    masterApi: MasterApi.srb2,
    protocol: NetProtocol.srb2,
    gametypes: ['Co-op', 'Competition', 'Race', 'Match', 'Team Match', 'Tag', 'Hide & Seek', 'CTF'],
    hasRooms: true,
    prefsPrefix: '',
    windowsCommand: 'srb2win.exe',
    linuxCommand: 'srb2',
    windowsExecutables: ['srb2win.exe', 'srb2win64.exe', 'srb2.exe'],
    linuxExecutables: ['lsdl2srb2', 'srb2'],
    executableHints: ['srb2'],
    linuxDataFolders: ['.srb2', '.var/app/org.srb2.SRB2/.srb2'],
    modVersion: 56,
    paletteFiles: ['srb2.pk3'],
    baseMapFiles: ['srb2.pk3', 'zones.pk3'],
    baseSkinFiles: ['srb2.pk3', 'player.dta', 'zones.pk3', 'characters.pk3', 'patch.pk3'],
    // music.pk3 — OST; MUSICDEF с названиями может быть и в srb2.pk3.
    musicFiles: ['srb2.pk3', 'zones.pk3', 'music.dta', 'music.pk3'],
    modId: 18,
  );

  /// SRB2 Legacy — форк SRB2 2.1.30 (srb2-preservation/srb2-legacy). Главный
  /// файл — srb2.srb, данные — .dta, папка пользователя — srb2_21. Мастер-
  /// серверы — старого вида, `хост:порт` (TCP 28900), см. LegacyMaster.
  static const srb2legacy = GameDef(
    id: 'srb2legacy',
    name: 'SRB2 Legacy',
    fullName: 'Sonic Robo Blast 2 Legacy',
    version: '2.1.30',
    mainFile: 'srb2.srb',
    downloadPath: ['DOWNLOAD'],
    defaultMasters: ['ms.srb2classic.net:28900', 'ms.weissblatt.cc:28900'],
    masterApi: MasterApi.srb2,
    protocol: NetProtocol.legacy,
    gametypes: ['Co-op', 'Competition', 'Race', 'Match', 'Team Match', 'Tag', 'Hide & Seek', 'CTF'],
    hasRooms: true,
    prefsPrefix: 'srb2legacy.',
    windowsCommand: 'srb2legacywin.exe',
    linuxCommand: 'srb2legacy',
    windowsExecutables: ['srb2legacywin.exe', 'srb2legacywin64.exe', 'srb2legacy.exe'],
    linuxExecutables: ['lsdl2srb2legacy', 'srb2legacy'],
    executableHints: ['srb2legacy', 'legacy'],
    linuxDataFolders: ['.srb2_21'],
    modVersion: 35,
    paletteFiles: ['srb2.srb'],
    baseMapFiles: ['srb2.srb', 'zones.dta', 'patch.dta', 'legacy.pk3'],
    baseSkinFiles: ['srb2.srb', 'player.dta', 'patch.dta', 'legacy.pk3'],
    musicFiles: ['srb2.srb', 'zones.dta', 'music.dta', 'patch.dta', 'legacy.pk3'],
    modId: 12,
  );

  /// Dr. Robotnik's Ring Racers 2.4. Аддоны с серверов игра кладёт в
  /// `addons/DOWNLOAD`, ищет файлы по имени и MD5 рекурсивно в папке игры.
  static const drrr = GameDef(
    id: 'drrr',
    name: 'Ring Racers',
    fullName: "Dr. Robotnik's Ring Racers",
    version: '2.4',
    mainFile: 'bios.pk3',
    downloadPath: ['addons', 'DOWNLOAD'],
    defaultMasters: ['https://ms.kartkrew.org/ms/api', 'https://ms.weissblatt.cc/api/srb2kart'],
    masterApi: MasterApi.kart,
    protocol: NetProtocol.ringRacers,
    gametypes: ['Race', 'Battle'],
    hasRooms: false,
    prefsPrefix: 'drrr.',
    windowsCommand: 'ringracers.exe',
    linuxCommand: 'ringracers',
    windowsExecutables: ['ringracers.exe', 'ringracers_x64.exe'],
    linuxExecutables: ['ringracers', 'ringracers.AppImage'],
    executableHints: ['ringracers', 'ring racers', 'drrr'],
    linuxDataFolders: ['.ringracers', '.var/app/org.kartkrew.RingRacers/.ringracers'],
    modVersion: 13,
    paletteFiles: ['bios.pk3', 'data/gfx.pk3'],
    baseMapFiles: ['bios.pk3', 'data/gfx.pk3', 'data/maps.pk3'],
    baseSkinFiles: ['bios.pk3', 'data/chars.pk3'],
    musicFiles: ['bios.pk3', 'data/scripts.pk3', 'data/maps.pk3', 'data/sounds.pk3', 'data/music.pk3', 'data/altmusic.pk3'],
    pictureInsideMaps: true,
  );

  /// SRB2Kart 1.6. Главный файл — srb2.srb, аддоны с серверов — в DOWNLOAD,
  /// мастер-сервер — тот же, что у Ring Racers (games/SRB2Kart/10/servers).
  static const srb2kart = GameDef(
    id: 'srb2kart',
    name: 'SRB2Kart',
    fullName: 'Sonic Robo Blast 2 Kart',
    version: '1.6',
    mainFile: 'srb2.srb',
    downloadPath: ['DOWNLOAD'],
    defaultMasters: ['https://ms.kartkrew.org/ms/api', 'https://ms.weissblatt.cc/api/srb2kart'],
    masterApi: MasterApi.kart,
    protocol: NetProtocol.srb2Kart,
    gametypes: ['Race', 'Battle'],
    hasRooms: false,
    prefsPrefix: 'srb2kart.',
    windowsCommand: 'srb2kart.exe',
    linuxCommand: 'srb2kart',
    windowsExecutables: ['srb2kart.exe', 'srb2kart64.exe'],
    linuxExecutables: ['srb2kart', 'lsdl2srb2kart'],
    executableHints: ['srb2kart', 'kart'],
    linuxDataFolders: ['.srb2kart', '.var/app/org.srb2.SRB2Kart/.srb2kart'],
    modVersion: 10,
    paletteFiles: ['srb2.srb', 'gfx.kart'],
    baseMapFiles: ['srb2.srb', 'gfx.kart', 'maps.kart'],
    baseSkinFiles: ['srb2.srb', 'gfx.kart', 'chars.kart', 'maps.kart', 'patch.kart'],
    musicFiles: ['srb2.srb', 'maps.kart', 'sounds.kart', 'music.kart'],
  );

  /// Встроенные игры: SRB2 есть всегда, остальные можно выключить.
  static const builtIn = [srb2, srb2legacy, srb2kart, drrr];

  /// Свои игры (описания в JSON; CustomGames загружает их из настроек).
  static List<GameDef> custom = [];

  /// Выключенные игры (коды): в переключателе их нет. SRB2 не выключается.
  static Set<String> disabled = {};

  /// Все известные игры: встроенные и свои, включённые и выключенные.
  static List<GameDef> get all => [...builtIn, ...custom];

  /// Включённые: их показывает переключатель игры.
  static List<GameDef> get enabled => [for (final g in all) if (g == srb2 || !disabled.contains(g.id)) g];

  static bool isEnabled(GameDef g) => g == srb2 || !disabled.contains(g.id);

  /// Код занят встроенной игрой или её синонимом.
  static bool isReserved(String id) {
    final n = normalizeId(id);
    return builtIn.any((g) => g.id == n);
  }

  /// Своя игра из описания [j] (JSON): `id`, `name`, `base` (код встроенной
  /// игры) обязательны; остальное — как у основы, если не задано.
  /// [iconFile] — файл иконки (уже скопированный). FormatException — с
  /// понятным текстом, что не так.
  static GameDef fromDefinition(Map<String, dynamic> j, {String? iconFile}) {
    String str(String k) => j[k] is String ? (j[k] as String).trim() : '';
    List<String>? list(String k) {
      final v = j[k];
      if (v is String) return [v];
      if (v is List) return [for (final x in v) if ('$x'.trim().isNotEmpty) '$x'.trim()];
      return null;
    }

    final id = str('id').toLowerCase();
    if (!RegExp(r'^[a-z0-9][a-z0-9_.-]{1,40}$').hasMatch(id)) {
      throw FormatException('"id" must be 2-41 lowercase letters, digits, "_", "-" or "." (got "${j['id']}")');
    }
    if (isReserved(id)) throw FormatException('"$id" is a built-in game');
    final name = str('name');
    if (name.isEmpty) throw FormatException('$id: "name" is missing');
    final baseId = normalizeId(str('base'));
    final base = builtIn.where((g) => g.id == baseId).firstOrNull;
    if (base == null) throw FormatException('$id: "base" must be one of srb2, srb2legacy, srb2kart, drrr');
    final NetProtocol protocol;
    try {
      final p = j['protocol'];
      protocol = p == null || (p is String && p.trim().isEmpty) ? base.protocol : NetProtocol.fromJson(p);
    } on FormatException catch (e) {
      throw FormatException('$id: ${e.message}');
    }
    final api = switch (str('master_api').toLowerCase()) {
      '' => base.masterApi,
      'srb2' => MasterApi.srb2,
      'kart' => MasterApi.kart,
      final x => throw FormatException('$id: "master_api" must be srb2 or kart (got "$x")'),
    };
    final exe = j['executables'] is Map ? j['executables'] as Map : const {};
    List<String>? exeList(String k) {
      final v = exe[k];
      if (v is String) return [v];
      if (v is List) return [for (final x in v) if ('$x'.trim().isNotEmpty) '$x'.trim()];
      return null;
    }

    final windows = exeList('windows') ?? base.windowsExecutables;
    final linux = exeList('linux') ?? base.linuxExecutables;
    final download = list('download_path');
    final ModelFormat? models;
    try {
      models = ModelFormat.fromJson(j['models'], ModelFormat.forEngine(base.id));
    } on FormatException catch (e) {
      throw FormatException('$id: ${e.message}');
    }
    final cfgFile = str('config_file');
    final rawConfig = j['config'];
    if (rawConfig != null && rawConfig is! Map) {
      throw FormatException('$id: "config" must be an object');
    }
    int intOf(String k, int fallback) => j[k] is num ? (j[k] as num).toInt() : int.tryParse('${j[k] ?? ''}') ?? fallback;
    return GameDef(
      id: id,
      name: name,
      fullName: str('full_name').isEmpty ? name : str('full_name'),
      version: str('version').isEmpty ? base.version : str('version'),
      mainFile: str('main_file').isEmpty ? base.mainFile : str('main_file'),
      downloadPath: download == null
          ? base.downloadPath
          : [for (final d in download) ...d.split(RegExp(r'[/\\]')).where((x) => x.isNotEmpty)],
      defaultMasters: list('masters') ?? base.defaultMasters,
      masterApi: api,
      protocol: protocol,
      gametypes: list('gametypes') ?? base.gametypes,
      hasRooms: j['has_rooms'] is bool ? j['has_rooms'] as bool : base.hasRooms,
      prefsPrefix: 'game.$id.',
      windowsCommand: windows.isEmpty ? base.windowsCommand : windows.first,
      linuxCommand: linux.isEmpty ? base.linuxCommand : linux.first,
      windowsExecutables: windows,
      linuxExecutables: linux,
      executableHints: list('executable_hints') ?? [id],
      linuxDataFolders: list('linux_data_folders') ?? const [],
      lanConnect: base.lanConnect,
      paletteFiles: list('palette_files') ?? base.paletteFiles,
      baseMapFiles: list('map_files') ?? base.baseMapFiles,
      pictureInsideMaps: j['picture_inside_maps'] is bool ? j['picture_inside_maps'] as bool : base.pictureInsideMaps,
      musicFiles: list('music_files') ?? base.musicFiles,
      baseSkinFiles: list('skin_files') ?? base.baseSkinFiles,
      modVersion: intOf('mod_version', base.modVersion),
      modId: intOf('mod_id', base.modId),
      engineId: base.id,
      iconFile: iconFile,
      baseAddons: j['base_addons'] == true,
      customOwnFiles: list('own_files') ?? const [],
      definition: Map<String, dynamic>.from(j),
      modelsOverride: models,
      hasModelsOverride: j.containsKey('models'),
      configFileOverride: cfgFile.isEmpty ? null : cfgFile,
      configDefinition: rawConfig is Map ? Map<String, dynamic>.from(rawConfig) : null,
    );
  }

  /// Названия стандартных мастер-серверов (адрес → название).
  static const masterNames = {
    'https://ds.ms.srb2.org/MS/0': 'SRB2 Master Server',
    'https://ms.weissblatt.cc/api/srb2http': 'Weissblatt',
    'https://ms.kartkrew.org/ms/api': 'Kart Krew',
    'https://ms.weissblatt.cc/api/srb2kart': 'Weissblatt',
    'ms.srb2classic.net:28900': 'SRB2 Classic',
    'ms.weissblatt.cc:28900': 'Weissblatt',
  };

  /// Другие названия в манифестах.
  static const _aliases = {
    'sonic robo blast 2': 'srb2',
    'sonic robo blast 2 legacy': 'srb2legacy',
    'ringracers': 'drrr',
    'ring racers': 'drrr',
    'rr': 'drrr',
    'drringracers': 'drrr',
    'kart': 'srb2kart',
    'srb2 kart': 'srb2kart',
    'sonic robo blast 2 kart': 'srb2kart',
  };

  /// Код игры из манифеста: нижний регистр, без пробелов по краям, синонимы.
  static String normalizeId(String raw) {
    final s = raw.trim().toLowerCase();
    return _aliases[s] ?? s;
  }

  static GameDef byId(String? id) => find(id) ?? srb2;

  /// Игра с кодом [id] (встроенная или своя); null — такой нет.
  static GameDef? find(String? id) {
    final n = normalizeId(id ?? '');
    for (final g in all) {
      if (g.id == n) return g;
    }
    return null;
  }
}
