import '../services/platform_utils.dart';
import 'game.dart';

/// Исполняемый файл (сборка SRB2), которым можно запустить игру.
/// [command] — путь к exe (в кавычках, если есть пробелы) или команда
/// вроде `flatpak run org.srb2.SRB2`.
class LaunchExecutable {
  final String id;
  final String name;
  final String command;

  const LaunchExecutable({required this.id, required this.name, required this.command});

  LaunchExecutable copyWith({String? name, String? command}) =>
      LaunchExecutable(id: id, name: name ?? this.name, command: command ?? this.command);

  /// Сам исполняемый файл (первое слово команды).
  String get program {
    final parts = PlatformUtils.splitCommandLine(command);
    return parts.isEmpty ? command : parts.first;
  }

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'command': command};

  static LaunchExecutable? fromJson(dynamic j) {
    if (j is! Map) return null;
    final id = j['id'];
    final name = j['name'];
    final command = j['command'];
    if (id is! String || command is! String || command.trim().isEmpty) return null;
    return LaunchExecutable(
      id: id,
      name: name is String && name.trim().isNotEmpty ? name.trim() : suggestName(command),
      command: command.trim(),
    );
  }

  static int _seq = 0;
  static String newId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${(_seq++).toRadixString(36)}';

  static List<String> _pathSegments(String command) {
    final parts = PlatformUtils.splitCommandLine(command);
    final program = parts.isEmpty ? command.trim() : parts.first;
    return program.split(RegExp(r'[/\\]')).where((x) => x.isNotEmpty).toList();
  }

  /// Имя по умолчанию — имя файла без расширения: `...\x32\srb2win.exe` →
  /// `srb2win`, `flatpak run ...` → `flatpak`. Понимает оба разделителя на любой ОС.
  static String suggestName(String command) {
    final segments = _pathSegments(command);
    if (segments.isEmpty) return command.trim();
    final file = segments.last;
    final dot = file.lastIndexOf('.');
    return dot > 0 ? file.substring(0, dot) : file;
  }

  /// Папка, в которой лежит exe (`x32`, `TSoURDt3rd_x64`), или пустая строка.
  static String folderName(String command) {
    final segments = _pathSegments(command);
    if (segments.length < 2) return '';
    final dir = segments[segments.length - 2];
    // Корень диска ("C:") или относительный путь ("./srb2") — папки нет.
    return dir.endsWith(':') || dir == '.' || dir == '..' ? '' : dir;
  }
}

/// Простой флаг командной строки SRB2 (галочка).
class LaunchFlag {
  final String arg;
  final String label;
  final String hint;
  const LaunchFlag(this.arg, this.label, this.hint);
}

/// Флаги SRB2 2.2.15 (проверены по исходникам игры).
class LaunchFlags {
  LaunchFlags._();

  static const windowed = LaunchFlag('-win', 'Windowed', 'Start in a window instead of fullscreen.');
  static const borderless = LaunchFlag('-borderless', 'Borderless window', 'Window without a title bar and frame.');
  static const noSound = LaunchFlag('-nosound', 'No sound effects', 'Disable sound effects.');
  static const noMusic = LaunchFlag('-nomusic', 'No music', 'Disable music.');
  static const skipIntro = LaunchFlag('-skipintro', 'Skip intro', 'Go straight to the title screen.');
  static const noData = LaunchFlag(
    '-nodata',
    "Don't load or save progress",
    'Play with empty game data (records, emblems, unlocks). Nothing is saved, '
        'so your real progress stays untouched. Handy for testing addons.',
  );
  static const resetData = LaunchFlag(
    '-resetdata',
    'Reset progress',
    'Start with empty game data and SAVE it: erases your records, emblems and unlocks.',
  );
  static const noDownload = LaunchFlag(
      '-nodownload', "Don't download addons", "Don't download missing addons when joining a server.");
  static const noUpload = LaunchFlag(
      '-noupload', "Don't upload addons", "When hosting, don't let players download addons from you.");
  static const noMouse = LaunchFlag('-nomouse', 'No mouse', 'Disable mouse input.');
  static const noMouseGrab =
      LaunchFlag('-nomousegrab', "Don't grab mouse", "Don't capture the mouse cursor in the game window.");
  static const noJoy = LaunchFlag('-nojoy', 'No gamepad', 'Disable joysticks and gamepads.');
  static const console =
      LaunchFlag('-console', 'Console window', 'Open a separate console window with the game log.');
  static const debug = LaunchFlag('-debug', 'Debug mode', 'Developer mode with extra debug output.');

  /// Только SRB2 (в SRB2Kart и Ring Racers параметр отключён).
  static const ultimate = LaunchFlag('-ultimatemode', 'Ultimate mode',
      'Hardcore: one life and no rings. Die and you start over.');

  /// Порядок, в котором флаги попадают в командную строку.
  static const all = [
    windowed, borderless, noSound, noMusic, skipIntro, ultimate, noData, resetData, //
    noDownload, noUpload, noMouse, noMouseGrab, noJoy, console, debug,
  ];
}

enum RendererMode { auto, opengl, software }

enum NetMode { off, host, dedicated, join }

/// Режимы игры SRB2 2.2.15 для -gametype (Gametype_Names в g_game.c;
/// игра сравнивает без учёта регистра). Можно указать и кастомный режим.
/// У других игр — свои, см. [GameDef.gametypes].
const srb2Gametypes = ['Co-op', 'Competition', 'Race', 'Match', 'Team Match', 'Tag', 'Hide & Seek', 'CTF'];

/// Консольная команда или переменная, которая передаётся как `+имя значение`
/// (SRB2 выполняет их после загрузки, M_PushSpecialParameters).
class ConsoleEntry {
  final String name;
  final String value;
  final bool enabled;
  const ConsoleEntry(this.name, this.value, {this.enabled = true});

  /// Аргументы: `+maxsend 200000`. Значение — одним аргументом (игра сама
  /// берёт его в кавычки, так что пробелы в servername работают); значения
  /// с кавычками разбиваются на несколько аргументов.
  List<String> toArgs() {
    final v = value.trim();
    if (name.trim().isEmpty) return const [];
    return [
      '+${name.trim()}',
      if (v.isNotEmpty) ...(v.contains('"') ? PlatformUtils.splitCommandLine(v) : [v]),
    ];
  }

  Map<String, dynamic> toJson() => {'name': name, 'value': value, 'enabled': enabled};

  static ConsoleEntry? fromJson(dynamic j) {
    if (j is! Map || j['name'] is! String) return null;
    return ConsoleEntry(
      j['name'] as String,
      j['value'] is String ? j['value'] as String : '',
      enabled: j['enabled'] != false,
    );
  }
}

/// Галочки и поля командной строки. Общие для всех экзешников одной игры.
class LaunchOptions {
  RendererMode renderer = RendererMode.auto;
  NetMode net = NetMode.off;
  final Set<String> flags = {};
  bool customResolution = false;
  String width = '';
  String height = '';
  /// Карта для -warp ('' — без -warp, игра начинается как обычно).
  String warpMap = '';

  /// -warp передаётся (карта указана).
  bool get warpEnabled => warpMap.trim().isNotEmpty;

  /// Всегда родной цвет персонажа: вместо своего +color — prefcolor его
  /// S_SKIN (в Ring Racers — `+color Default`).
  bool defaultColor = false;
  String joinAddress = '';
  String room = '';
  String adminPassword = '';

  /// -gametype для своего сервера ('' — не указывать).
  String gametype = '';

  /// Консольные команды и переменные (+имя значение).
  List<ConsoleEntry> console = [];

  bool has(LaunchFlag f) => flags.contains(f.arg);

  /// Значение консольной переменной (+name), '' — не задана.
  String cvar(String name) {
    for (final c in console) {
      if (c.enabled && c.name.toLowerCase() == name) return c.value;
    }
    return '';
  }

  /// Задаёт +name value; пустое значение — переменная не передаётся.
  void setCvar(String name, String value) {
    console = [
      for (final c in console)
        if (c.name.toLowerCase() != name) c,
      if (value.trim().isNotEmpty) ConsoleEntry(name, value.trim()),
    ];
  }

  /// Копия для подключения к серверу [address] (кнопка Join на вкладке Servers):
  /// остальные галочки сохраняются, сетевой режим заменяется на -connect.
  LaunchOptions forJoining(String address) => LaunchOptions.fromJson(toJson())
    ..net = NetMode.join
    ..joinAddress = address;

  /// Аргументы для игры (без `-file`, его добавляет очередь). У игр без
  /// комнат мастер-сервера (Ring Racers) -room не передаётся. [skinColor] —
  /// родной цвет (prefcolor) персонажа +skin для [defaultColor].
  List<String> toArgs({GameDef game = Games.srb2, String skinColor = ''}) {
    final args = <String>[];

    if (renderer == RendererMode.opengl) args.add('-opengl');
    if (renderer == RendererMode.software) args.add('-software');

    for (final f in LaunchFlags.all) {
      if (identical(f, LaunchFlags.ultimate) && game != Games.srb2) continue; // есть только в SRB2
      if (flags.contains(f.arg)) args.add(f.arg);
    }

    if (customResolution) {
      final w = int.tryParse(width.trim());
      final h = int.tryParse(height.trim());
      if (w != null && w > 0 && h != null && h > 0) {
        args.addAll(['-width', '$w', '-height', '$h']);
      }
    }

    // При подключении к серверу карту и режим выбирает сервер; -warp ещё и
    // запустил бы локальную игру до подключения.
    final joining = net == NetMode.join;
    if (!joining && warpEnabled) {
      args.addAll(['-warp', warpMap.trim()]);
    }

    switch (net) {
      case NetMode.off:
        break;
      case NetMode.host:
        args.add('-server');
      case NetMode.dedicated:
        args.add('-dedicated');
      case NetMode.join:
        // "+connect" — консольная команда после загрузки игры: сначала грузятся
        // аддоны из -file (с "-connect" SRB2 их пропускает), потом подключение,
        // как из меню. "any" — поиск сервера в локальной сети.
        args.addAll(['+connect', joinAddress.trim().isEmpty ? game.lanConnect : joinAddress.trim()]);
    }

    if (net == NetMode.host || net == NetMode.dedicated) {
      final roomId = int.tryParse(room.trim());
      if (roomId != null && game.hasRooms) args.addAll(['-room', '$roomId']);
      if (adminPassword.isNotEmpty) args.addAll(['-password', adminPassword]);
    }

    if (!joining && gametype.trim().isNotEmpty) args.addAll(['-gametype', gametype.trim()]);

    for (final c in console) {
      // С «Всегда родной цвет» свой +color не передаём.
      if (!c.enabled || (defaultColor && c.name.trim().toLowerCase() == 'color')) continue;
      args.addAll(c.toArgs());
    }
    if (defaultColor) {
      // Ring Racers сам берёт цвет персонажа по значению Default; SRB2 и
      // SRB2Kart — только по имени цвета (неизвестен — игра решит сама).
      final color = game.engine == 'drrr' ? 'Default' : skinColor.trim();
      if (color.isNotEmpty) args.addAll(['+color', color]);
    }

    return args;
  }

  Map<String, dynamic> toJson() => {
        'renderer': renderer.name,
        'net': net.name,
        'flags': (flags.toList()..sort()),
        'customResolution': customResolution,
        'width': width,
        'height': height,
        'warpMap': warpMap,
        'defaultColor': defaultColor,
        'joinAddress': joinAddress,
        'room': room,
        'adminPassword': adminPassword,
        'gametype': gametype,
        'console': console.map((c) => c.toJson()).toList(),
      };

  static LaunchOptions fromJson(dynamic j) {
    final o = LaunchOptions();
    if (j is! Map) return o;
    String str(String key) => j[key] is String ? j[key] as String : '';
    bool flag(String key) => j[key] == true;

    o.renderer = RendererMode.values.asNameMap()[j['renderer']] ?? RendererMode.auto;
    o.net = NetMode.values.asNameMap()[j['net']] ?? NetMode.off;
    final known = LaunchFlags.all.map((f) => f.arg).toSet();
    if (j['flags'] is List) {
      o.flags.addAll((j['flags'] as List).whereType<String>().where(known.contains));
    }
    o.customResolution = flag('customResolution');
    o.width = str('width');
    o.height = str('height');
    o.warpMap = str('warpMap');
    // Раньше -warp включался отдельной галочкой: выключенная — без карты.
    if (j['warpEnabled'] == false) o.warpMap = '';
    o.defaultColor = flag('defaultColor');
    o.joinAddress = str('joinAddress');
    o.room = str('room');
    o.adminPassword = str('adminPassword');
    o.gametype = str('gametype');
    if (j['console'] is List) {
      o.console = [
        for (final e in j['console'] as List)
          if (ConsoleEntry.fromJson(e) case final entry?) entry,
      ];
    }
    return o;
  }
}

/// Профиль запуска: галочки, консольные команды, доп. параметры и очередь
/// аддонов — сохраняется и выбирается целиком (как в SLADE).
class LaunchProfile {
  final String name;
  final String params;

  /// Галочки и поля (LaunchOptions.toJson); null — старый набор, где были
  /// только доп. параметры.
  final Map<String, dynamic>? options;

  /// Очередь аддонов (-file); null — не трогать очередь при выборе.
  final List<String>? queue;

  const LaunchProfile({required this.name, required this.params, this.options, this.queue});

  Map<String, dynamic> toJson() => {
        'name': name,
        'params': params,
        if (options != null) 'options': options,
        if (queue != null) 'queue': queue,
      };

  static LaunchProfile? fromJson(dynamic j) {
    if (j is! Map) return null;
    final params = j['params'] is String ? (j['params'] as String).trim() : '';
    final name = j['name'] is String && (j['name'] as String).trim().isNotEmpty
        ? (j['name'] as String).trim()
        : params;
    if (name.isEmpty) return null;
    return LaunchProfile(
      name: name,
      params: params,
      options: j['options'] is Map ? Map<String, dynamic>.from(j['options'] as Map) : null,
      queue: j['queue'] is List ? [for (final e in j['queue'] as List) '$e'] : null,
    );
  }
}
