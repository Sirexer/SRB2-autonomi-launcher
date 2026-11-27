import 'package:flutter/services.dart';

import '../models/game.dart';

/// Вкладки редактора конфига.
enum ConfigSubTab {
  video,
  audio,
  controls,
  playerCamera,
  gameplayHud,
  serverNet,
  all,
}

/// Тип элемента управления для консольной переменной.
enum CvarKind {
  toggle,
  dropdown,
  integer,
  decimal,
  sliderInt,
  color,
  text,
  folder,
  file,
}

/// Описание консольной переменной для структурированных вкладок.
class CvarSpec {
  final String name;
  final List<String> playerNames;
  final bool perPlayer;
  final String label;
  final String description;
  final ConfigSubTab tab;
  final String group;
  final CvarKind kind;
  final String defaultValue;
  final List<String> options;
  final double? min;
  final double? max;
  final List<String> fileExtensions;

  /// Ключ опции Launch, которая при включении перекрывает эту переменную (`renderer`, `win`, `nosound`, `nomusic`, `resolution`, `nomouse`, `nojoy`, и т.д.).
  final String? launchOverride;

  /// Варианты для bool-тумблеров (`On/Off` по умолчанию или `Yes/No`).
  final String trueValue;
  final String falseValue;

  const CvarSpec({
    required this.name,
    this.playerNames = const [],
    this.perPlayer = false,
    required this.label,
    this.description = '',
    required this.tab,
    required this.group,
    required this.kind,
    required this.defaultValue,
    this.options = const [],
    this.min,
    this.max,
    this.fileExtensions = const [],
    this.launchOverride,
    this.trueValue = 'On',
    this.falseValue = 'Off',
  });

  /// Имя переменной для игрока [player] (1..4); null — если параметр общий (только для [player] == 1).
  String? nameForPlayer(int player) {
    if (player <= 1) return name;
    if (playerNames.isNotEmpty) {
      return player - 1 < playerNames.length ? playerNames[player - 1] : null;
    }
    if (!perPlayer) return null;
    if (name.startsWith('cam_')) return 'cam${player}_${name.substring(4)}';
    if (name.startsWith('joy_')) return 'joy${player}_${name.substring(4)}';
    if (name.startsWith('joyaxis_')) return 'joyaxis${player}_${name.substring(8)}';
    return '$name$player';
  }

  bool get supportsMultiplePlayers => perPlayer || playerNames.length > 1;

  bool matchesName(String key) {
    final k = key.toLowerCase();
    if (k == name.toLowerCase()) return true;
    for (var p = 2; p <= 4; p++) {
      final pn = nameForPlayer(p);
      if (pn != null && pn.toLowerCase() == k) return true;
    }
    return false;
  }

  static bool isTruthy(String? value) {
    final v = value?.trim().toLowerCase() ?? '';
    return v == 'on' || v == 'yes' || v == '1' || v == 'true';
  }

  factory CvarSpec.fromJson(Map<String, dynamic> j) {
    final name = (j['name'] ?? '').toString().trim();
    if (name.isEmpty) throw const FormatException('cvar entry missing "name"');
    final label = (j['label'] ?? name).toString();
    final tab = _parseTab((j['tab'] ?? 'gameplayHud').toString());
    final kind = _parseKind((j['kind'] ?? 'text').toString());
    final pNames = j['player_names'] is List
        ? [for (final x in j['player_names'] as List) x.toString()]
        : const <String>[];
    final opts = j['options'] is List ? [for (final x in j['options'] as List) x.toString()] : const <String>[];
    final exts = j['file_extensions'] is List
        ? [for (final x in j['file_extensions'] as List) x.toString()]
        : const <String>[];
    return CvarSpec(
      name: name,
      playerNames: pNames,
      perPlayer: j['per_player'] == true,
      label: label,
      description: (j['description'] ?? '').toString(),
      tab: tab,
      group: (j['group'] ?? 'Game specific').toString(),
      kind: kind,
      defaultValue: (j['default'] ?? '').toString(),
      options: opts,
      min: j['min'] is num ? (j['min'] as num).toDouble() : null,
      max: j['max'] is num ? (j['max'] as num).toDouble() : null,
      fileExtensions: exts,
      launchOverride: j['launch_override']?.toString(),
      trueValue: (j['true_value'] ?? 'On').toString(),
      falseValue: (j['false_value'] ?? 'Off').toString(),
    );
  }

  static ConfigSubTab _parseTab(String raw) => switch (raw.trim().toLowerCase()) {
        'video' => ConfigSubTab.video,
        'audio' => ConfigSubTab.audio,
        'controls' => ConfigSubTab.controls,
        'playercamera' || 'player_camera' || 'player' || 'camera' => ConfigSubTab.playerCamera,
        'gameplayhud' || 'gameplay_hud' || 'gameplay' || 'hud' => ConfigSubTab.gameplayHud,
        'servernet' || 'server_net' || 'server' || 'network' => ConfigSubTab.serverNet,
        _ => ConfigSubTab.gameplayHud,
      };

  static CvarKind _parseKind(String raw) => switch (raw.trim().toLowerCase()) {
        'toggle' || 'bool' || 'boolean' => CvarKind.toggle,
        'dropdown' || 'enum' || 'select' => CvarKind.dropdown,
        'integer' || 'int' => CvarKind.integer,
        'decimal' || 'float' || 'number' => CvarKind.decimal,
        'sliderint' || 'slider_int' || 'slider' => CvarKind.sliderInt,
        'color' => CvarKind.color,
        'folder' || 'dir' => CvarKind.folder,
        'file' => CvarKind.file,
        _ => CvarKind.text,
      };
}

/// Действие `setcontrol` / `setcontrol2`..`setcontrol4`.
class ControlActionSpec {
  final String command;
  final String label;
  final String group;

  const ControlActionSpec(this.command, this.label, this.group);

  factory ControlActionSpec.fromJson(Map<String, dynamic> j) {
    final cmd = (j['command'] ?? '').toString().trim();
    if (cmd.isEmpty) throw const FormatException('control entry missing "command"');
    return ControlActionSpec(
      cmd,
      (j['label'] ?? cmd).toString(),
      (j['group'] ?? 'Actions').toString(),
    );
  }
}

/// Итоговая схема редактора конфига для конкретной игры.
class GameConfigSchema {
  final int maxPlayers;
  final List<CvarSpec> specs;
  final List<ControlActionSpec> controlActions;
  final List<String> gamepadDetectControls;

  const GameConfigSchema({
    required this.maxPlayers,
    required this.specs,
    required this.controlActions,
    this.gamepadDetectControls = const [],
  });

  bool isCuratedCvar(String name) {
    final lower = name.toLowerCase();
    for (final s in specs) {
      if (s.matchesName(lower)) return true;
    }
    return false;
  }

  String? defaultFor(String name) {
    for (final s in specs) {
      if (s.matchesName(name)) return s.defaultValue;
    }
    return null;
  }
}

/// Схемы вкладок, переменных и привязок клавиш для SRB2, Legacy, SRB2Kart,
/// Ring Racers и пользовательских игр из `another_games.json` (на базе основы).
class Srb2ConfigSchema {
  Srb2ConfigSchema._();

  static const tabs = <(ConfigSubTab, String)>[
    (ConfigSubTab.video, 'Video'),
    (ConfigSubTab.audio, 'Audio'),
    (ConfigSubTab.controls, 'Controls'),
    (ConfigSubTab.playerCamera, 'Player & Camera'),
    (ConfigSubTab.gameplayHud, 'Gameplay & HUD'),
    (ConfigSubTab.serverNet, 'Server & Netgame'),
    (ConfigSubTab.all, 'All variables'),
  ];

  static const _commonGamepadKeys = <String>[
    'KEY0',
    'mouse1',
    'mouse2',
    'mouse3',
    'wheel 1 up',
    'wheel 1 down',
    'joy1',
    'joy2',
    'joy3',
    'joy4',
    'joy5',
    'joy6',
    'joy7',
    'joy8',
    'joy9',
    'joy10',
    'joy11',
    'joy12',
    'hatup',
    'hatdown',
    'hatleft',
    'hatright',
    'sec_joy1',
    'sec_joy2',
    'sec_joy3',
    'sec_joy4',
    'sec_joy5',
    'sec_joy6',
    'sec_joy7',
    'sec_joy8',
    'sec_joy9',
    'sec_joy10',
    'A BUTTON',
    'B BUTTON',
    'X BUTTON',
    'Y BUTTON',
    'L BUMPER',
    'R BUMPER',
    'L TRIGGER',
    'R TRIGGER',
    'START BUTTON',
    'D-PAD UP',
    'D-PAD DOWN',
    'D-PAD LEFT',
    'D-PAD RIGHT',
    'L-STICK UP',
    'L-STICK DOWN',
    'L-STICK LEFT',
    'L-STICK RIGHT',
    'L-STICK CLICK',
    'R-STICK UP',
    'R-STICK DOWN',
    'R-STICK LEFT',
    'R-STICK RIGHT',
    'R-STICK CLICK',
    'BACK BUTTON',
  ];

  static List<String> get quickKeyPresets => _commonGamepadKeys;

  static const _joyAxes = <String>[
    'None',
    'X-Axis',
    'X-Axis-',
    'Y-Axis',
    'Y-Axis-',
    'Z-Axis',
    'Z-Axis-',
    'X-Rudder',
    'X-Rudder-',
    'Y-Rudder',
    'Y-Rudder-',
    'Z-Rudder',
    'Z-Rudder-',
  ];

  static const _kartJoyAxes = <String>[
    'None',
    'Left X',
    'Left X-',
    'Left Y',
    'Left Y-',
    'Right X',
    'Right X-',
    'Right Y',
    'Right Y-',
    'L Trigger',
    'R Trigger',
    'D-Pad X',
    'D-Pad Y',
  ];

  static const _drawDistances = <String>[
    'Infinite',
    'None',
    '256',
    '512',
    '1024',
    '1536',
    '2048',
    '3072',
    '4096',
    '6144',
    '8192',
  ];

  // -------------------- Общие блоки переменных --------------------

  static const _commonVideo = <CvarSpec>[
    CvarSpec(
      name: 'fullscreen',
      label: 'Fullscreen',
      description: 'Display game in fullscreen mode.',
      tab: ConfigSubTab.video,
      group: 'Screen & Renderer',
      kind: CvarKind.toggle,
      defaultValue: 'Yes',
      trueValue: 'Yes',
      falseValue: 'No',
      launchOverride: 'win',
    ),
    CvarSpec(
      name: 'scr_width',
      label: 'Fullscreen width',
      description: 'Screen width used in fullscreen mode.',
      tab: ConfigSubTab.video,
      group: 'Screen & Renderer',
      kind: CvarKind.integer,
      defaultValue: '1280',
      min: 320,
      max: 7680,
      launchOverride: 'resolution',
    ),
    CvarSpec(
      name: 'scr_height',
      label: 'Fullscreen height',
      description: 'Screen height used in fullscreen mode.',
      tab: ConfigSubTab.video,
      group: 'Screen & Renderer',
      kind: CvarKind.integer,
      defaultValue: '800',
      min: 200,
      max: 4320,
      launchOverride: 'resolution',
    ),
    CvarSpec(
      name: 'scr_depth',
      label: 'Color depth',
      description: 'Screen bit depth (mostly OpenGL quality).',
      tab: ConfigSubTab.video,
      group: 'Screen & Renderer',
      kind: CvarKind.dropdown,
      defaultValue: '16 bits',
      options: ['8 bits', '16 bits', '24 bits', '32 bits'],
    ),
    CvarSpec(
      name: 'vid_wait',
      label: 'Vertical sync (VSync)',
      description: 'Synchronize frames with monitor refresh rate.',
      tab: ConfigSubTab.video,
      group: 'Screen & Renderer',
      kind: CvarKind.toggle,
      defaultValue: 'On',
    ),
    CvarSpec(
      name: 'fpscap',
      label: 'FPS cap',
      description: 'Maximum frame rate ("Match refresh rate", "Unlimited", or 35–300).',
      tab: ConfigSubTab.video,
      group: 'Screen & Renderer',
      kind: CvarKind.dropdown,
      defaultValue: 'Match refresh rate',
      options: ['Match refresh rate', 'Unlimited', '35', '60', '75', '120', '144', '165', '240', '300'],
    ),
    CvarSpec(
      name: 'showfps',
      label: 'Show FPS',
      description: 'Display framerate counter on the HUD.',
      tab: ConfigSubTab.video,
      group: 'Screen & Renderer',
      kind: CvarKind.dropdown,
      defaultValue: 'No',
      options: ['No', 'Yes', 'Full', 'Compact'],
    ),
    CvarSpec(
      name: 'fov',
      perPlayer: false,
      label: 'Field of view (FOV)',
      description: 'Camera field of view in degrees (default 90).',
      tab: ConfigSubTab.video,
      group: 'Screen & Renderer',
      kind: CvarKind.decimal,
      defaultValue: '90',
      min: 20,
      max: 179,
    ),
    CvarSpec(
      name: 'drawdist',
      label: 'Draw distance',
      description: 'Maximum sprite draw distance.',
      tab: ConfigSubTab.video,
      group: 'World & Rendering',
      kind: CvarKind.dropdown,
      defaultValue: 'Infinite',
      options: _drawDistances,
    ),
    CvarSpec(
      name: 'drawdist_precip',
      label: 'Precipitation draw distance',
      description: 'Draw distance for rain and snow particles.',
      tab: ConfigSubTab.video,
      group: 'World & Rendering',
      kind: CvarKind.dropdown,
      defaultValue: '1024',
      options: [..._drawDistances, 'Farthest'],
    ),
    CvarSpec(
      name: 'skybox',
      label: 'Render skyboxes',
      tab: ConfigSubTab.video,
      group: 'World & Rendering',
      kind: CvarKind.toggle,
      defaultValue: 'On',
    ),
    CvarSpec(
      name: 'translucency',
      label: 'Sprite translucency',
      tab: ConfigSubTab.video,
      group: 'World & Rendering',
      kind: CvarKind.toggle,
      defaultValue: 'On',
    ),
    CvarSpec(
      name: 'maxportals',
      label: 'Max portal depth',
      description: 'Recursive visual portal limit (0–12).',
      tab: ConfigSubTab.video,
      group: 'World & Rendering',
      kind: CvarKind.sliderInt,
      defaultValue: '2',
      min: 0,
      max: 12,
    ),
    CvarSpec(
      name: 'homremoval',
      label: 'Clear before redraw (HOM)',
      tab: ConfigSubTab.video,
      group: 'World & Rendering',
      kind: CvarKind.dropdown,
      defaultValue: 'No',
      options: ['No', 'Yes', 'Flash'],
    ),
    CvarSpec(
      name: 'gr_shaders',
      label: 'OpenGL shaders',
      tab: ConfigSubTab.video,
      group: 'OpenGL & 3D Models',
      kind: CvarKind.dropdown,
      defaultValue: 'On',
      options: ['Off', 'On', 'Ignore custom shaders'],
    ),
    CvarSpec(
      name: 'gr_filtermode',
      label: 'Texture filter mode',
      tab: ConfigSubTab.video,
      group: 'OpenGL & 3D Models',
      kind: CvarKind.dropdown,
      defaultValue: 'Nearest',
      options: ['Nearest', 'Bilinear', 'Trilinear', 'Linear_Nearest', 'Nearest_Linear', 'Nearest_Mipmap'],
    ),
    CvarSpec(
      name: 'gr_anisotropicmode',
      label: 'Anisotropic filtering',
      description: 'Anisotropic level (1 = off, up to GPU max e.g. 16).',
      tab: ConfigSubTab.video,
      group: 'OpenGL & 3D Models',
      kind: CvarKind.dropdown,
      defaultValue: '1',
      options: ['1', '2', '4', '8', '16'],
    ),
    CvarSpec(
      name: 'gr_skydome',
      label: 'Render sky as dome',
      tab: ConfigSubTab.video,
      group: 'OpenGL & 3D Models',
      kind: CvarKind.toggle,
      defaultValue: 'On',
    ),
    CvarSpec(
      name: 'gr_spritebillboarding',
      label: 'Sprite billboarding',
      tab: ConfigSubTab.video,
      group: 'OpenGL & 3D Models',
      kind: CvarKind.toggle,
      defaultValue: 'Off',
    ),
    CvarSpec(
      name: 'gr_fakecontrast',
      label: 'Fake contrast',
      tab: ConfigSubTab.video,
      group: 'OpenGL & 3D Models',
      kind: CvarKind.dropdown,
      defaultValue: 'Smooth',
      options: ['Off', 'Standard', 'Smooth'],
    ),
    CvarSpec(
      name: 'gr_shearing',
      label: 'Software-style y-shearing',
      tab: ConfigSubTab.video,
      group: 'OpenGL & 3D Models',
      kind: CvarKind.toggle,
      defaultValue: 'Off',
    ),
    CvarSpec(
      name: 'gamma',
      label: 'Brightness (Gamma)',
      description: 'Overall brightness (-15 to 5, default 0).',
      tab: ConfigSubTab.video,
      group: 'Brightness & Color',
      kind: CvarKind.sliderInt,
      defaultValue: '0',
      min: -15,
      max: 5,
    ),
    CvarSpec(
      name: 'saturation',
      label: 'Saturation',
      description: 'Color saturation (0 to 10, default 10).',
      tab: ConfigSubTab.video,
      group: 'Brightness & Color',
      kind: CvarKind.sliderInt,
      defaultValue: '10',
      min: 0,
      max: 10,
    ),
  ];

  static const _commonAudioBehavior = <CvarSpec>[
    CvarSpec(
      name: 'snd_channels',
      label: 'Sound channels',
      description: 'Simultaneous mixing channels (e.g. 16, 32, 64).',
      tab: ConfigSubTab.audio,
      group: 'Volume & Channels',
      kind: CvarKind.integer,
      defaultValue: '32',
      min: 1,
      max: 128,
    ),
    CvarSpec(
      name: 'playsoundsifunfocused',
      label: 'Play sounds when unfocused',
      tab: ConfigSubTab.audio,
      group: 'Behavior',
      kind: CvarKind.toggle,
      defaultValue: 'Yes',
      trueValue: 'Yes',
      falseValue: 'No',
    ),
    CvarSpec(
      name: 'playmusicifunfocused',
      label: 'Play music when unfocused',
      tab: ConfigSubTab.audio,
      group: 'Behavior',
      kind: CvarKind.toggle,
      defaultValue: 'No',
      trueValue: 'Yes',
      falseValue: 'No',
    ),
    CvarSpec(
      name: 'surround',
      label: 'Surround sound',
      tab: ConfigSubTab.audio,
      group: 'Behavior',
      kind: CvarKind.toggle,
      defaultValue: 'Off',
    ),
    CvarSpec(
      name: 'stereoreverse',
      label: 'Reverse stereo channels',
      tab: ConfigSubTab.audio,
      group: 'Behavior',
      kind: CvarKind.toggle,
      defaultValue: 'Off',
    ),
    CvarSpec(
      name: 'precachesound',
      label: 'Precache sound effects',
      tab: ConfigSubTab.audio,
      group: 'Behavior',
      kind: CvarKind.toggle,
      defaultValue: 'Off',
    ),
  ];

  static const _commonChatConsoleAndFiles = <CvarSpec>[
    CvarSpec(
      name: 'chatmode',
      label: 'Chat display mode',
      tab: ConfigSubTab.gameplayHud,
      group: 'Chat & Console',
      kind: CvarKind.dropdown,
      defaultValue: 'Window',
      options: ['Window', 'Console', 'Off', 'Yes'],
    ),
    CvarSpec(
      name: 'chatwidth',
      label: 'Chat box width',
      tab: ConfigSubTab.gameplayHud,
      group: 'Chat & Console',
      kind: CvarKind.integer,
      defaultValue: '128',
      min: 64,
      max: 320,
    ),
    CvarSpec(
      name: 'chatheight',
      label: 'Chat box height (lines)',
      tab: ConfigSubTab.gameplayHud,
      group: 'Chat & Console',
      kind: CvarKind.sliderInt,
      defaultValue: '8',
      min: 6,
      max: 22,
    ),
    CvarSpec(
      name: 'chattime',
      label: 'Chat message fade time (sec)',
      tab: ConfigSubTab.gameplayHud,
      group: 'Chat & Console',
      kind: CvarKind.integer,
      defaultValue: '8',
      min: 5,
      max: 999,
    ),
    CvarSpec(
      name: 'chatbacktint',
      label: 'Chat background tint',
      tab: ConfigSubTab.gameplayHud,
      group: 'Chat & Console',
      kind: CvarKind.toggle,
      defaultValue: 'On',
    ),
    CvarSpec(
      name: 'chatnotifications',
      label: 'Chat sound notifications',
      tab: ConfigSubTab.gameplayHud,
      group: 'Chat & Console',
      kind: CvarKind.toggle,
      defaultValue: 'On',
    ),
    CvarSpec(
      name: 'chatspamprotection',
      label: 'Chat spam protection',
      tab: ConfigSubTab.gameplayHud,
      group: 'Chat & Console',
      kind: CvarKind.toggle,
      defaultValue: 'On',
    ),
    CvarSpec(
      name: 'con_textsize',
      label: 'Console text size',
      tab: ConfigSubTab.gameplayHud,
      group: 'Chat & Console',
      kind: CvarKind.dropdown,
      defaultValue: 'Medium',
      options: ['Small', 'Medium', 'Large'],
    ),
    CvarSpec(
      name: 'con_backpic',
      label: 'Console background',
      tab: ConfigSubTab.gameplayHud,
      group: 'Chat & Console',
      kind: CvarKind.dropdown,
      defaultValue: 'translucent',
      options: ['translucent', 'picture'],
    ),
    CvarSpec(
      name: 'con_backcolor',
      label: 'Console background color',
      tab: ConfigSubTab.gameplayHud,
      group: 'Chat & Console',
      kind: CvarKind.dropdown,
      defaultValue: 'Green',
      options: [
        'White', 'Black', 'Sepia', 'Brown', 'Pink', 'Raspberry', 'Red', 'Creamsicle',
        'Orange', 'Gold', 'Yellow', 'Green', 'Blue', 'Steel Blue', 'Purple', 'Lavender', 'Cyan',
      ],
    ),
    CvarSpec(
      name: 'con_height',
      label: 'Console height (%)',
      tab: ConfigSubTab.gameplayHud,
      group: 'Chat & Console',
      kind: CvarKind.sliderInt,
      defaultValue: '50',
      min: 10,
      max: 100,
    ),
    CvarSpec(
      name: 'moviemode_mode',
      label: 'Movie recording mode',
      tab: ConfigSubTab.gameplayHud,
      group: 'Screenshots & Folders',
      kind: CvarKind.dropdown,
      defaultValue: 'GIF',
      options: ['GIF', 'aPNG'],
    ),
    CvarSpec(
      name: 'screenshot_option',
      label: 'Screenshots storage',
      tab: ConfigSubTab.gameplayHud,
      group: 'Screenshots & Folders',
      kind: CvarKind.dropdown,
      defaultValue: 'Default',
      options: ['Default', 'HOME', 'SRB2', 'Custom'],
    ),
    CvarSpec(
      name: 'screenshot_folder',
      label: 'Custom screenshots folder',
      tab: ConfigSubTab.gameplayHud,
      group: 'Screenshots & Folders',
      kind: CvarKind.folder,
      defaultValue: '',
    ),
    CvarSpec(
      name: 'addons_option',
      label: 'In-game addons menu folder mode',
      tab: ConfigSubTab.gameplayHud,
      group: 'Screenshots & Folders',
      kind: CvarKind.dropdown,
      defaultValue: 'Default',
      options: ['Default', 'HOME', 'SRB2', 'Custom'],
    ),
    CvarSpec(
      name: 'addons_folder',
      label: 'Custom addons folder',
      tab: ConfigSubTab.gameplayHud,
      group: 'Screenshots & Folders',
      kind: CvarKind.folder,
      defaultValue: '',
    ),
    CvarSpec(
      name: 'addons_showall',
      label: 'Show unsupported file types in Addons menu',
      tab: ConfigSubTab.gameplayHud,
      group: 'Screenshots & Folders',
      kind: CvarKind.toggle,
      defaultValue: 'No',
      trueValue: 'Yes',
      falseValue: 'No',
    ),
  ];

  static const _commonServerNet = <CvarSpec>[
    CvarSpec(
      name: 'servername',
      label: 'Server name',
      tab: ConfigSubTab.serverNet,
      group: 'Hosting & Network',
      kind: CvarKind.text,
      defaultValue: 'SRB2 server',
      launchOverride: 'servername',
    ),
    CvarSpec(
      name: 'maxplayers',
      label: 'Max players (2–32)',
      tab: ConfigSubTab.serverNet,
      group: 'Hosting & Network',
      kind: CvarKind.sliderInt,
      defaultValue: '8',
      min: 1,
      max: 32,
      launchOverride: 'maxplayers',
    ),
    CvarSpec(
      name: 'allowjoin',
      label: 'Allow players to join',
      tab: ConfigSubTab.serverNet,
      group: 'Hosting & Network',
      kind: CvarKind.toggle,
      defaultValue: 'On',
    ),
    CvarSpec(
      name: 'downloadspeed',
      label: 'File upload speed (packets/tic)',
      tab: ConfigSubTab.serverNet,
      group: 'Hosting & Network',
      kind: CvarKind.integer,
      defaultValue: '16',
      min: 1,
      max: 300,
    ),
    CvarSpec(
      name: 'maxsend',
      label: 'Max downloadable file size (KB)',
      tab: ConfigSubTab.serverNet,
      group: 'Hosting & Network',
      kind: CvarKind.integer,
      defaultValue: '4096',
      min: 0,
      max: 1000000,
    ),
    CvarSpec(
      name: 'showjoinaddress',
      label: 'Show IP address of joiners',
      tab: ConfigSubTab.serverNet,
      group: 'Hosting & Network',
      kind: CvarKind.toggle,
      defaultValue: 'Off',
    ),
    CvarSpec(
      name: 'noticedownload',
      label: 'Log file downloads in console',
      tab: ConfigSubTab.serverNet,
      group: 'Hosting & Network',
      kind: CvarKind.toggle,
      defaultValue: 'Off',
    ),
    CvarSpec(
      name: 'showping',
      label: 'Show ping on HUD',
      tab: ConfigSubTab.serverNet,
      group: 'Hosting & Network',
      kind: CvarKind.dropdown,
      defaultValue: 'Always',
      options: ['Off', 'Warning', 'Always'],
    ),
    CvarSpec(
      name: 'nettimeout',
      label: 'Network timeout (tics)',
      tab: ConfigSubTab.serverNet,
      group: 'Hosting & Network',
      kind: CvarKind.integer,
      defaultValue: '350',
      min: 5,
      max: 2100,
    ),
    CvarSpec(
      name: 'jointimeout',
      label: 'Join download timeout (tics)',
      tab: ConfigSubTab.serverNet,
      group: 'Hosting & Network',
      kind: CvarKind.integer,
      defaultValue: '350',
      min: 5,
      max: 2100,
    ),
    CvarSpec(
      name: 'masterserver',
      label: 'Master server URL',
      tab: ConfigSubTab.serverNet,
      group: 'Master Server & AFK',
      kind: CvarKind.text,
      defaultValue: 'https://mb.srb2.org/MS/0',
    ),
    CvarSpec(
      name: 'masterserver_update_rate',
      label: 'Master server update rate (min)',
      tab: ConfigSubTab.serverNet,
      group: 'Master Server & AFK',
      kind: CvarKind.sliderInt,
      defaultValue: '15',
      min: 2,
      max: 60,
    ),
    CvarSpec(
      name: 'inttime',
      label: 'Intermission timer (sec)',
      tab: ConfigSubTab.serverNet,
      group: 'Multiplayer Rules',
      kind: CvarKind.integer,
      defaultValue: '10',
      min: 0,
      max: 3600,
    ),
    CvarSpec(
      name: 'pausepermission',
      label: 'Who can pause netgame',
      tab: ConfigSubTab.serverNet,
      group: 'Multiplayer Rules',
      kind: CvarKind.dropdown,
      defaultValue: 'Server',
      options: ['Server', 'Server Admins', 'All'],
    ),
    CvarSpec(
      name: 'skipmapcheck',
      label: 'Skip map gametype compatibility check',
      tab: ConfigSubTab.serverNet,
      group: 'Multiplayer Rules',
      kind: CvarKind.toggle,
      defaultValue: 'Off',
    ),
  ];

  // -------------------- SRB2 2.2 --------------------

  static const _srb2Controls = <ControlActionSpec>[
    ControlActionSpec('forward', 'Forward', 'Movement'),
    ControlActionSpec('backward', 'Backward', 'Movement'),
    ControlActionSpec('strafeleft', 'Strafe left', 'Movement'),
    ControlActionSpec('straferight', 'Strafe right', 'Movement'),
    ControlActionSpec('turnleft', 'Turn left', 'Movement'),
    ControlActionSpec('turnright', 'Turn right', 'Movement'),
    ControlActionSpec('jump', 'Jump', 'Actions'),
    ControlActionSpec('spin', 'Spin / Spindash', 'Actions'),
    ControlActionSpec('fire', 'Fire / Ring', 'Actions'),
    ControlActionSpec('firenormal', 'Fire normal ring', 'Actions'),
    ControlActionSpec('tossflag', 'Toss flag / Drop', 'Actions'),
    ControlActionSpec('custom1', 'Custom action 1', 'Actions'),
    ControlActionSpec('custom2', 'Custom action 2', 'Actions'),
    ControlActionSpec('custom3', 'Custom action 3', 'Actions'),
    ControlActionSpec('lookup', 'Look up', 'Camera'),
    ControlActionSpec('lookdown', 'Look down', 'Camera'),
    ControlActionSpec('centerview', 'Center view', 'Camera'),
    ControlActionSpec('mouseaiming', 'Mouse look', 'Camera'),
    ControlActionSpec('camtoggle', 'Toggle camera', 'Camera'),
    ControlActionSpec('camreset', 'Reset camera', 'Camera'),
    ControlActionSpec('weaponnext', 'Next weapon', 'Weapons'),
    ControlActionSpec('weaponprev', 'Previous weapon', 'Weapons'),
    ControlActionSpec('weapon1', 'Weapon 1 (Infinity)', 'Weapons'),
    ControlActionSpec('weapon2', 'Weapon 2 (Auto)', 'Weapons'),
    ControlActionSpec('weapon3', 'Weapon 3 (Bounce)', 'Weapons'),
    ControlActionSpec('weapon4', 'Weapon 4 (Scatter)', 'Weapons'),
    ControlActionSpec('weapon5', 'Weapon 5 (Grenade)', 'Weapons'),
    ControlActionSpec('weapon6', 'Weapon 6 (Explosion)', 'Weapons'),
    ControlActionSpec('weapon7', 'Weapon 7 (Rail)', 'Weapons'),
    ControlActionSpec('weapon8', 'Weapon 8', 'Weapons'),
    ControlActionSpec('weapon9', 'Weapon 9', 'Weapons'),
    ControlActionSpec('weapon10', 'Weapon 10', 'Weapons'),
    ControlActionSpec('talkkey', 'Chat', 'System'),
    ControlActionSpec('teamtalkkey', 'Team chat', 'System'),
    ControlActionSpec('scores', 'Show rankings', 'System'),
    ControlActionSpec('pause', 'Pause', 'System'),
    ControlActionSpec('systemmenu', 'Open menu', 'System'),
    ControlActionSpec('console', 'Console', 'System'),
    ControlActionSpec('screenshot', 'Screenshot', 'System'),
    ControlActionSpec('recordgif', 'Record GIF / aPNG', 'System'),
    ControlActionSpec('viewpoint', 'Next spectator / coop view', 'System'),
    ControlActionSpec('viewpointprev', 'Previous view', 'System'),
  ];

  static const _srb2Specs = <CvarSpec>[
    ..._commonVideo,
    CvarSpec(
      name: 'renderer',
      label: 'Renderer',
      description: 'Software or OpenGL hardware acceleration.',
      tab: ConfigSubTab.video,
      group: 'Screen & Renderer',
      kind: CvarKind.dropdown,
      defaultValue: 'Software',
      options: ['Software', 'OpenGL'],
      launchOverride: 'renderer',
    ),
    CvarSpec(
      name: 'scr_width_w',
      label: 'Windowed width',
      description: 'Window width when running in windowed mode.',
      tab: ConfigSubTab.video,
      group: 'Screen & Renderer',
      kind: CvarKind.integer,
      defaultValue: '1280',
      min: 320,
      max: 7680,
      launchOverride: 'resolution',
    ),
    CvarSpec(
      name: 'scr_height_w',
      label: 'Windowed height',
      description: 'Window height when running in windowed mode.',
      tab: ConfigSubTab.video,
      group: 'Screen & Renderer',
      kind: CvarKind.integer,
      defaultValue: '800',
      min: 200,
      max: 4320,
      launchOverride: 'resolution',
    ),
    CvarSpec(
      name: 'drawdist_nights',
      label: 'NiGHTS draw distance',
      description: 'Sprite draw distance in NiGHTS levels.',
      tab: ConfigSubTab.video,
      group: 'World & Rendering',
      kind: CvarKind.dropdown,
      defaultValue: '2048',
      options: _drawDistances,
    ),
    CvarSpec(
      name: 'shadow',
      label: 'Drop shadows',
      tab: ConfigSubTab.video,
      group: 'World & Rendering',
      kind: CvarKind.toggle,
      defaultValue: 'On',
    ),
    CvarSpec(
      name: 'gr_models',
      label: '3D Models (OpenGL)',
      description: 'Enable 3D model rendering instead of sprites when models are installed.',
      tab: ConfigSubTab.video,
      group: 'OpenGL & 3D Models',
      kind: CvarKind.toggle,
      defaultValue: 'Off',
    ),
    CvarSpec(
      name: 'gr_modelinterpolation',
      label: 'Model interpolation',
      tab: ConfigSubTab.video,
      group: 'OpenGL & 3D Models',
      kind: CvarKind.dropdown,
      defaultValue: 'Sometimes',
      options: ['Off', 'Sometimes', 'Always'],
    ),
    CvarSpec(
      name: 'gr_modellighting',
      label: 'Model lighting',
      tab: ConfigSubTab.video,
      group: 'OpenGL & 3D Models',
      kind: CvarKind.toggle,
      defaultValue: 'Off',
    ),
    CvarSpec(
      name: 'gr_paletterendering',
      label: 'Palette rendering',
      description: 'Authentic Software-like palette lighting & colormaps in OpenGL.',
      tab: ConfigSubTab.video,
      group: 'OpenGL & 3D Models',
      kind: CvarKind.toggle,
      defaultValue: 'On',
    ),
    CvarSpec(
      name: 'gr_palettedepth',
      label: 'Palette texture depth',
      tab: ConfigSubTab.video,
      group: 'OpenGL & 3D Models',
      kind: CvarKind.dropdown,
      defaultValue: '16 bits',
      options: ['8 bits', '16 bits', '32 bits'],
    ),
    CvarSpec(
      name: 'gr_slopecontrast',
      label: 'Slope contrast',
      tab: ConfigSubTab.video,
      group: 'OpenGL & 3D Models',
      kind: CvarKind.toggle,
      defaultValue: 'Off',
    ),
    CvarSpec(
      name: 'gr_solvetjoin',
      label: 'Solve T-joins',
      tab: ConfigSubTab.video,
      group: 'OpenGL & 3D Models',
      kind: CvarKind.toggle,
      defaultValue: 'On',
    ),
    ..._commonAudioBehavior,
    CvarSpec(
      name: 'sounds',
      label: 'Sound effects',
      tab: ConfigSubTab.audio,
      group: 'Volume & Channels',
      kind: CvarKind.toggle,
      defaultValue: 'On',
      launchOverride: 'nosound',
    ),
    CvarSpec(
      name: 'soundvolume',
      label: 'Sound volume',
      description: 'Volume from 0 to 31.',
      tab: ConfigSubTab.audio,
      group: 'Volume & Channels',
      kind: CvarKind.sliderInt,
      defaultValue: '18',
      min: 0,
      max: 31,
      launchOverride: 'nosound',
    ),
    CvarSpec(
      name: 'digimusic',
      label: 'Digital music',
      tab: ConfigSubTab.audio,
      group: 'Volume & Channels',
      kind: CvarKind.toggle,
      defaultValue: 'On',
      launchOverride: 'nomusic',
    ),
    CvarSpec(
      name: 'digmusicvolume',
      label: 'Digital music volume',
      description: 'Volume from 0 to 31.',
      tab: ConfigSubTab.audio,
      group: 'Volume & Channels',
      kind: CvarKind.sliderInt,
      defaultValue: '18',
      min: 0,
      max: 31,
      launchOverride: 'nomusic',
    ),
    CvarSpec(
      name: 'midimusic',
      label: 'MIDI music',
      tab: ConfigSubTab.audio,
      group: 'Volume & Channels',
      kind: CvarKind.toggle,
      defaultValue: 'On',
      launchOverride: 'nomusic',
    ),
    CvarSpec(
      name: 'midimusicvolume',
      label: 'MIDI music volume',
      description: 'Volume from 0 to 31.',
      tab: ConfigSubTab.audio,
      group: 'Volume & Channels',
      kind: CvarKind.sliderInt,
      defaultValue: '18',
      min: 0,
      max: 31,
      launchOverride: 'nomusic',
    ),
    CvarSpec(
      name: 'musicpref',
      label: 'Preferred music format',
      tab: ConfigSubTab.audio,
      group: 'Volume & Channels',
      kind: CvarKind.dropdown,
      defaultValue: 'Digital',
      options: ['Digital', 'MIDI'],
    ),
    CvarSpec(
      name: 'midiplayer',
      label: 'MIDI synth backend',
      tab: ConfigSubTab.audio,
      group: 'MIDI & Modules',
      kind: CvarKind.dropdown,
      defaultValue: 'Native',
      options: ['Native', 'FluidSynth', 'OPNMIDI', 'ADL', 'TiMidity', 'ModPlug'],
    ),
    CvarSpec(
      name: 'midisoundfont',
      label: 'MIDI SoundFont (.sf2)',
      description: 'Path to .sf2 soundfont for FluidSynth (relative to game folder or full path).',
      tab: ConfigSubTab.audio,
      group: 'MIDI & Modules',
      kind: CvarKind.file,
      defaultValue: '',
      fileExtensions: ['sf2', 'sf3'],
    ),
    CvarSpec(
      name: 'midisoundbank',
      label: 'TiMidity soundbank folder',
      description: 'Path to TiMidity patches folder (e.g. ./timidity).',
      tab: ConfigSubTab.audio,
      group: 'MIDI & Modules',
      kind: CvarKind.folder,
      defaultValue: './timidity',
    ),
    CvarSpec(
      name: 'modfilter',
      label: 'Module tracker interpolation',
      tab: ConfigSubTab.audio,
      group: 'MIDI & Modules',
      kind: CvarKind.dropdown,
      defaultValue: 'Default',
      options: ['Default', 'None', 'Linear', 'Cubic', 'Windowed'],
    ),
    CvarSpec(
      name: '1upsound',
      label: 'Default 1-Up sound',
      tab: ConfigSubTab.audio,
      group: 'Behavior',
      kind: CvarKind.dropdown,
      defaultValue: 'Jingle',
      options: ['Jingle', 'Sound'],
    ),
    CvarSpec(
      name: 'resetmusic',
      label: 'Reset music on death',
      tab: ConfigSubTab.audio,
      group: 'Behavior',
      kind: CvarKind.toggle,
      defaultValue: 'No',
      trueValue: 'Yes',
      falseValue: 'No',
    ),
    CvarSpec(
      name: 'resetmusicbyheader',
      label: 'Allow level header music reset',
      tab: ConfigSubTab.audio,
      group: 'Behavior',
      kind: CvarKind.toggle,
      defaultValue: 'Yes',
      trueValue: 'Yes',
      falseValue: 'No',
    ),
    CvarSpec(
      name: 'closedcaptioning',
      label: 'Closed captions for sounds',
      tab: ConfigSubTab.audio,
      group: 'Behavior',
      kind: CvarKind.toggle,
      defaultValue: 'Off',
    ),
    CvarSpec(
      name: 'use_mouse',
      perPlayer: true,
      label: 'Enable mouse',
      tab: ConfigSubTab.controls,
      group: 'Mouse & Aiming',
      kind: CvarKind.dropdown,
      defaultValue: 'On',
      options: ['Off', 'On', 'Force'],
      launchOverride: 'nomouse',
    ),
    CvarSpec(
      name: 'mousesens',
      perPlayer: true,
      label: 'Mouse horizontal speed',
      tab: ConfigSubTab.controls,
      group: 'Mouse & Aiming',
      kind: CvarKind.sliderInt,
      defaultValue: '20',
      min: 1,
      max: 100,
    ),
    CvarSpec(
      name: 'mouseysens',
      perPlayer: true,
      label: 'Mouse vertical speed',
      tab: ConfigSubTab.controls,
      group: 'Mouse & Aiming',
      kind: CvarKind.sliderInt,
      defaultValue: '20',
      min: 1,
      max: 100,
    ),
    CvarSpec(
      name: 'invertmouse',
      perPlayer: true,
      label: 'Invert mouse Y-axis',
      tab: ConfigSubTab.controls,
      group: 'Mouse & Aiming',
      kind: CvarKind.toggle,
      defaultValue: 'Off',
    ),
    CvarSpec(
      name: 'alwaysmlook',
      perPlayer: true,
      label: 'Always mouse look (1st person)',
      tab: ConfigSubTab.controls,
      group: 'Mouse & Aiming',
      kind: CvarKind.toggle,
      defaultValue: 'On',
    ),
    CvarSpec(
      name: 'chasemlook',
      perPlayer: true,
      label: 'Always mouse look (3rd person)',
      tab: ConfigSubTab.controls,
      group: 'Mouse & Aiming',
      kind: CvarKind.toggle,
      defaultValue: 'On',
    ),
    CvarSpec(
      name: 'mousemove',
      perPlayer: true,
      label: 'Mouse movement',
      tab: ConfigSubTab.controls,
      group: 'Mouse & Aiming',
      kind: CvarKind.toggle,
      defaultValue: 'Off',
    ),
    CvarSpec(
      name: 'alwaysgrabmouse',
      label: 'Always grab mouse cursor',
      tab: ConfigSubTab.controls,
      group: 'Mouse & Aiming',
      kind: CvarKind.toggle,
      defaultValue: 'Off',
      launchOverride: 'nomousegrab',
    ),
    CvarSpec(
      name: 'controlperkey',
      label: 'Controls per key',
      description: 'Allow one or multiple actions bound to the same key.',
      tab: ConfigSubTab.controls,
      group: 'Mouse & Aiming',
      kind: CvarKind.dropdown,
      defaultValue: 'One',
      options: ['One', 'Several'],
    ),
    CvarSpec(
      name: 'use_gamepad',
      perPlayer: true,
      label: 'Gamepad device index',
      description: '0 disables gamepad; 1 = first controller, 2 = second.',
      tab: ConfigSubTab.controls,
      group: 'Gamepad & Analog',
      kind: CvarKind.integer,
      defaultValue: '0',
      min: 0,
      max: 8,
      launchOverride: 'nojoy',
    ),
    CvarSpec(
      name: 'useranalog',
      perPlayer: true,
      label: 'Analog control mode',
      tab: ConfigSubTab.controls,
      group: 'Gamepad & Analog',
      kind: CvarKind.toggle,
      defaultValue: 'Off',
    ),
    CvarSpec(
      name: 'directionchar',
      perPlayer: true,
      label: 'Character facing mode',
      tab: ConfigSubTab.controls,
      group: 'Gamepad & Analog',
      kind: CvarKind.dropdown,
      defaultValue: 'Movement',
      options: ['Movement', 'Camera', 'Simple'],
    ),
    CvarSpec(
      name: 'autobrake',
      perPlayer: true,
      label: 'Auto-brake on stop',
      tab: ConfigSubTab.controls,
      group: 'Gamepad & Analog',
      kind: CvarKind.toggle,
      defaultValue: 'On',
    ),
    CvarSpec(
      name: 'joy_deadzone',
      perPlayer: true,
      label: 'Analog stick deadzone',
      tab: ConfigSubTab.controls,
      group: 'Gamepad & Analog',
      kind: CvarKind.decimal,
      defaultValue: '0.125',
      min: 0,
      max: 1,
    ),
    CvarSpec(
      name: 'joy_digdeadzone',
      perPlayer: true,
      label: 'Digital stick deadzone',
      tab: ConfigSubTab.controls,
      group: 'Gamepad & Analog',
      kind: CvarKind.decimal,
      defaultValue: '0.25',
      min: 0,
      max: 1,
    ),
    CvarSpec(name: 'joyaxis_move', perPlayer: true, label: 'Axis: Move forward/back', tab: ConfigSubTab.controls, group: 'Gamepad Axes', kind: CvarKind.dropdown, defaultValue: 'Y-Axis', options: _joyAxes),
    CvarSpec(name: 'joyaxis_side', perPlayer: true, label: 'Axis: Strafe left/right', tab: ConfigSubTab.controls, group: 'Gamepad Axes', kind: CvarKind.dropdown, defaultValue: 'X-Axis', options: _joyAxes),
    CvarSpec(name: 'joyaxis_turn', perPlayer: true, label: 'Axis: Turn camera', tab: ConfigSubTab.controls, group: 'Gamepad Axes', kind: CvarKind.dropdown, defaultValue: 'X-Rudder', options: _joyAxes),
    CvarSpec(name: 'joyaxis_look', perPlayer: true, label: 'Axis: Look up/down', tab: ConfigSubTab.controls, group: 'Gamepad Axes', kind: CvarKind.dropdown, defaultValue: 'Y-Rudder-', options: _joyAxes),
    CvarSpec(name: 'joyaxis_jump', perPlayer: true, label: 'Axis: Jump', tab: ConfigSubTab.controls, group: 'Gamepad Axes', kind: CvarKind.dropdown, defaultValue: 'None', options: _joyAxes),
    CvarSpec(name: 'joyaxis_spin', perPlayer: true, label: 'Axis: Spin', tab: ConfigSubTab.controls, group: 'Gamepad Axes', kind: CvarKind.dropdown, defaultValue: 'None', options: _joyAxes),
    CvarSpec(name: 'joyaxis_fire', perPlayer: true, label: 'Axis: Fire', tab: ConfigSubTab.controls, group: 'Gamepad Axes', kind: CvarKind.dropdown, defaultValue: 'Z-Axis-', options: _joyAxes),
    CvarSpec(name: 'joyaxis_firenormal', perPlayer: true, label: 'Axis: Fire normal', tab: ConfigSubTab.controls, group: 'Gamepad Axes', kind: CvarKind.dropdown, defaultValue: 'Z-Axis', options: _joyAxes),
    CvarSpec(name: 'name', perPlayer: true, label: 'Player name', tab: ConfigSubTab.playerCamera, group: 'Player Profile', kind: CvarKind.text, defaultValue: 'Sonic', launchOverride: 'name'),
    CvarSpec(name: 'defaultskin', perPlayer: true, label: 'Default character (skin)', tab: ConfigSubTab.playerCamera, group: 'Player Profile', kind: CvarKind.text, defaultValue: 'sonic'),
    CvarSpec(name: 'defaultcolor', perPlayer: true, label: 'Default color', tab: ConfigSubTab.playerCamera, group: 'Player Profile', kind: CvarKind.color, defaultValue: 'Blue'),
    CvarSpec(name: 'crosshair', perPlayer: true, label: 'First-person crosshair', tab: ConfigSubTab.playerCamera, group: 'Player Profile', kind: CvarKind.dropdown, defaultValue: 'Cross', options: ['Off', 'Cross', 'Angle', 'Point']),
    CvarSpec(name: 'chasecam', perPlayer: true, label: 'Third-person chase camera', tab: ConfigSubTab.playerCamera, group: 'Camera', kind: CvarKind.toggle, defaultValue: 'On'),
    CvarSpec(name: 'cam_dist', perPlayer: true, label: 'Camera distance', tab: ConfigSubTab.playerCamera, group: 'Camera', kind: CvarKind.decimal, defaultValue: '192', min: 32, max: 1024),
    CvarSpec(name: 'cam_height', perPlayer: true, label: 'Camera height offset', tab: ConfigSubTab.playerCamera, group: 'Camera', kind: CvarKind.decimal, defaultValue: '40', min: -200, max: 400),
    CvarSpec(name: 'cam_simpledist', perPlayer: true, label: 'Simple camera distance', tab: ConfigSubTab.playerCamera, group: 'Camera', kind: CvarKind.decimal, defaultValue: '224', min: 32, max: 1024),
    CvarSpec(name: 'cam_simpleheight', perPlayer: true, label: 'Simple camera height', tab: ConfigSubTab.playerCamera, group: 'Camera', kind: CvarKind.decimal, defaultValue: '48', min: -200, max: 400),
    CvarSpec(name: 'cam_speed', perPlayer: true, label: 'Camera follow speed', description: 'Speed factor from 0.0 to 1.0.', tab: ConfigSubTab.playerCamera, group: 'Camera', kind: CvarKind.decimal, defaultValue: '0.3', min: 0, max: 1),
    CvarSpec(name: 'cam_rotspeed', perPlayer: true, label: 'Camera rotation speed', description: 'Rotation speed (1–45).', tab: ConfigSubTab.playerCamera, group: 'Camera', kind: CvarKind.sliderInt, defaultValue: '10', min: 1, max: 45),
    CvarSpec(name: 'cam_turnmultiplier', perPlayer: true, label: 'Camera turn multiplier', tab: ConfigSubTab.playerCamera, group: 'Camera', kind: CvarKind.decimal, defaultValue: '1.0', min: 0.1, max: 5),
    CvarSpec(name: 'cam_adjust', perPlayer: true, label: 'Slope height adjustment', tab: ConfigSubTab.playerCamera, group: 'Camera', kind: CvarKind.toggle, defaultValue: 'On'),
    CvarSpec(name: 'cam_orbit', perPlayer: true, label: 'Camera orbit', tab: ConfigSubTab.playerCamera, group: 'Camera', kind: CvarKind.toggle, defaultValue: 'On'),
    CvarSpec(name: 'flipcam', perPlayer: true, label: 'Flip screen in reverse gravity', tab: ConfigSubTab.playerCamera, group: 'Camera', kind: CvarKind.toggle, defaultValue: 'No', trueValue: 'Yes', falseValue: 'No'),
    CvarSpec(name: 'cam_lockaimassist', perPlayer: true, label: 'Lock-on aim assist', tab: ConfigSubTab.playerCamera, group: 'Camera', kind: CvarKind.dropdown, defaultValue: 'Bosses', options: ['Off', 'Bosses', 'All']),
    CvarSpec(name: 'cam_lockedinput', perPlayer: true, label: 'Locked camera input', tab: ConfigSubTab.playerCamera, group: 'Camera', kind: CvarKind.dropdown, defaultValue: 'Strafe', options: ['Strafe', 'Turn']),
    CvarSpec(name: 'cam_centertoggle', perPlayer: true, label: 'Center camera button mode', tab: ConfigSubTab.playerCamera, group: 'Camera', kind: CvarKind.dropdown, defaultValue: 'Hold', options: ['Hold', 'Toggle']),
    CvarSpec(name: 'movebob', label: 'First-person view bob', tab: ConfigSubTab.playerCamera, group: 'Camera', kind: CvarKind.decimal, defaultValue: '1.0', min: 0, max: 2),
    ..._commonChatConsoleAndFiles,
    CvarSpec(name: 'autorecord', label: 'Auto-record Record Attack replays', tab: ConfigSubTab.gameplayHud, group: 'Gameplay', kind: CvarKind.toggle, defaultValue: 'Yes', trueValue: 'Yes', falseValue: 'No'),
    CvarSpec(name: 'instantretry', label: 'Instant retry in Record Attack', tab: ConfigSubTab.gameplayHud, group: 'Gameplay', kind: CvarKind.toggle, defaultValue: 'No', trueValue: 'Yes', falseValue: 'No'),
    CvarSpec(name: 'rollingdemos', label: 'Title screen demos', tab: ConfigSubTab.gameplayHud, group: 'Gameplay', kind: CvarKind.toggle, defaultValue: 'On'),
    CvarSpec(name: 'pauseifunfocused', label: 'Pause when window loses focus', tab: ConfigSubTab.gameplayHud, group: 'Gameplay', kind: CvarKind.toggle, defaultValue: 'Yes', trueValue: 'Yes', falseValue: 'No'),
    CvarSpec(name: 'showfocuslost', label: 'Show focus lost notice', tab: ConfigSubTab.gameplayHud, group: 'Gameplay', kind: CvarKind.toggle, defaultValue: 'No', trueValue: 'Yes', falseValue: 'No'),
    CvarSpec(name: 'tutorialprompt', label: 'Tutorial prompt', tab: ConfigSubTab.gameplayHud, group: 'Gameplay', kind: CvarKind.toggle, defaultValue: 'Off'),
    CvarSpec(name: 'cpusleep', label: 'CPU sleep (-1 = off, 0–28)', description: 'Yields CPU time back to the OS to reduce CPU usage.', tab: ConfigSubTab.gameplayHud, group: 'Gameplay', kind: CvarKind.sliderInt, defaultValue: '-1', min: -1, max: 28),
    CvarSpec(name: 'showhud', label: 'Show HUD', tab: ConfigSubTab.gameplayHud, group: 'HUD & Ghosts', kind: CvarKind.toggle, defaultValue: 'Yes', trueValue: 'Yes', falseValue: 'No'),
    CvarSpec(name: 'translucenthud', label: 'HUD opacity (0–10)', tab: ConfigSubTab.gameplayHud, group: 'HUD & Ghosts', kind: CvarKind.sliderInt, defaultValue: '10', min: 0, max: 10),
    CvarSpec(name: 'timerres', label: 'Timer display format', tab: ConfigSubTab.gameplayHud, group: 'HUD & Ghosts', kind: CvarKind.dropdown, defaultValue: 'Normal', options: ['Normal', 'Tics', 'Centiseconds', 'Mania']),
    CvarSpec(name: 'powerupdisplay', label: 'Powerup timers on HUD', tab: ConfigSubTab.gameplayHud, group: 'HUD & Ghosts', kind: CvarKind.dropdown, defaultValue: 'Always', options: ['Off', 'Always', 'First-person']),
    CvarSpec(name: 'seenames', label: 'Show player names on aim', tab: ConfigSubTab.gameplayHud, group: 'HUD & Ghosts', kind: CvarKind.dropdown, defaultValue: 'Ally/Foe', options: ['Off', 'Colorless', 'Team', 'Ally/Foe']),
    CvarSpec(name: 'compactscoreboard', label: 'Always compact scoreboard', tab: ConfigSubTab.gameplayHud, group: 'HUD & Ghosts', kind: CvarKind.toggle, defaultValue: 'Off'),
    CvarSpec(name: 'ghost_last', label: 'Ghost: Last run', tab: ConfigSubTab.gameplayHud, group: 'HUD & Ghosts', kind: CvarKind.dropdown, defaultValue: 'Show', options: ['Hide', 'Show', 'Show All']),
    CvarSpec(name: 'ghost_besttime', label: 'Ghost: Best time', tab: ConfigSubTab.gameplayHud, group: 'HUD & Ghosts', kind: CvarKind.dropdown, defaultValue: 'Show', options: ['Hide', 'Show', 'Show All']),
    CvarSpec(name: 'ghost_bestscore', label: 'Ghost: Best score', tab: ConfigSubTab.gameplayHud, group: 'HUD & Ghosts', kind: CvarKind.dropdown, defaultValue: 'Show', options: ['Hide', 'Show', 'Show All']),
    CvarSpec(name: 'ghost_bestrings', label: 'Ghost: Best rings', tab: ConfigSubTab.gameplayHud, group: 'HUD & Ghosts', kind: CvarKind.dropdown, defaultValue: 'Show', options: ['Hide', 'Show', 'Show All']),
    CvarSpec(name: 'ghost_guest', label: 'Ghost: Guest / Staff', tab: ConfigSubTab.gameplayHud, group: 'HUD & Ghosts', kind: CvarKind.dropdown, defaultValue: 'Show', options: ['Hide', 'Show']),
    CvarSpec(name: 'movie_option', label: 'Movies storage', tab: ConfigSubTab.gameplayHud, group: 'Screenshots & Folders', kind: CvarKind.dropdown, defaultValue: 'Default', options: ['Default', 'HOME', 'SRB2', 'Custom']),
    CvarSpec(name: 'movie_folder', label: 'Custom movies folder', tab: ConfigSubTab.gameplayHud, group: 'Screenshots & Folders', kind: CvarKind.folder, defaultValue: ''),
    ..._commonServerNet,
    CvarSpec(name: 'http_source', label: 'HTTP addon mirror URL', tab: ConfigSubTab.serverNet, group: 'Hosting & Network', kind: CvarKind.text, defaultValue: ''),
    CvarSpec(name: 'maxping', label: 'Max allowed ping (0 = off)', tab: ConfigSubTab.serverNet, group: 'Hosting & Network', kind: CvarKind.integer, defaultValue: '0', min: 0, max: 9999),
    CvarSpec(name: 'masterserver_room_id', label: 'Default room ID (0 = none, 33 = Standard, 28 = Casual, 38 = Custom)', tab: ConfigSubTab.serverNet, group: 'Master Server & AFK', kind: CvarKind.integer, defaultValue: '0', min: 0, max: 999),
    CvarSpec(name: 'idletime', label: 'AFK timeout (min)', tab: ConfigSubTab.serverNet, group: 'Master Server & AFK', kind: CvarKind.integer, defaultValue: '3', min: 0, max: 120),
    CvarSpec(name: 'idleaction', label: 'AFK action', tab: ConfigSubTab.serverNet, group: 'Master Server & AFK', kind: CvarKind.dropdown, defaultValue: 'Spectate', options: ['Kick', 'Spectate']),
    CvarSpec(name: 'startinglives', label: 'Co-op starting lives', tab: ConfigSubTab.serverNet, group: 'Multiplayer Rules', kind: CvarKind.integer, defaultValue: '3', min: 1, max: 99),
    CvarSpec(name: 'cooplives', label: 'Co-op life sharing', tab: ConfigSubTab.serverNet, group: 'Multiplayer Rules', kind: CvarKind.dropdown, defaultValue: 'Avoid Game Over', options: ['Infinite', 'Per-player', 'Avoid Game Over']),
    CvarSpec(name: 'coopstarposts', label: 'Co-op starposts', tab: ConfigSubTab.serverNet, group: 'Multiplayer Rules', kind: CvarKind.dropdown, defaultValue: 'Per-player', options: ['Per-player', 'Shared']),
    CvarSpec(name: 'playersforexit', label: 'Players required for level exit', tab: ConfigSubTab.serverNet, group: 'Multiplayer Rules', kind: CvarKind.dropdown, defaultValue: 'All', options: ['One', '1/4', 'Half', '3/4', 'All']),
    CvarSpec(name: 'advancemap', label: 'Advance map', tab: ConfigSubTab.serverNet, group: 'Multiplayer Rules', kind: CvarKind.dropdown, defaultValue: 'Next', options: ['Off', 'Next', 'Random']),
    CvarSpec(name: 'timelimit', label: 'Match / CTF time limit', tab: ConfigSubTab.serverNet, group: 'Multiplayer Rules', kind: CvarKind.text, defaultValue: 'None'),
    CvarSpec(name: 'pointlimit', label: 'Match / CTF point limit', tab: ConfigSubTab.serverNet, group: 'Multiplayer Rules', kind: CvarKind.text, defaultValue: 'None'),
    CvarSpec(name: 'overtime', label: 'Overtime tie-breaker', tab: ConfigSubTab.serverNet, group: 'Multiplayer Rules', kind: CvarKind.toggle, defaultValue: 'Yes', trueValue: 'Yes', falseValue: 'No'),
    CvarSpec(name: 'friendlyfire', label: 'Friendly fire', tab: ConfigSubTab.serverNet, group: 'Multiplayer Rules', kind: CvarKind.toggle, defaultValue: 'Off'),
    CvarSpec(name: 'tailspickup', label: 'Flying players can carry others', tab: ConfigSubTab.serverNet, group: 'Multiplayer Rules', kind: CvarKind.toggle, defaultValue: 'On'),
    CvarSpec(name: 'restrictskinchange', label: 'Restrict skin change mid-game', tab: ConfigSubTab.serverNet, group: 'Multiplayer Rules', kind: CvarKind.toggle, defaultValue: 'Yes', trueValue: 'Yes', falseValue: 'No'),
    CvarSpec(name: 'matchboxes', label: 'Match item boxes', tab: ConfigSubTab.serverNet, group: 'Multiplayer Rules', kind: CvarKind.dropdown, defaultValue: 'Normal', options: ['Normal', 'Mystery', 'Unchanging']),
    CvarSpec(name: 'competitionboxes', label: 'Competition item boxes', tab: ConfigSubTab.serverNet, group: 'Multiplayer Rules', kind: CvarKind.dropdown, defaultValue: 'Random', options: ['Normal', 'Random', 'Teleporters', 'Mystery']),
    CvarSpec(name: 'powerstones', label: 'Spawn Chaos Emeralds', tab: ConfigSubTab.serverNet, group: 'Multiplayer Rules', kind: CvarKind.toggle, defaultValue: 'On'),
    CvarSpec(name: 'specialrings', label: 'Special ring weapons', tab: ConfigSubTab.serverNet, group: 'Multiplayer Rules', kind: CvarKind.toggle, defaultValue: 'On'),
    CvarSpec(name: 'basenumlaps', label: 'Circuit laps', tab: ConfigSubTab.serverNet, group: 'Multiplayer Rules', kind: CvarKind.text, defaultValue: 'Map default'),
  ];

  // -------------------- SRB2 Legacy (2.1) --------------------

  static const _legacyControls = <ControlActionSpec>[
    ControlActionSpec('forward', 'Forward', 'Movement'),
    ControlActionSpec('backward', 'Backward', 'Movement'),
    ControlActionSpec('strafeleft', 'Strafe left', 'Movement'),
    ControlActionSpec('straferight', 'Strafe right', 'Movement'),
    ControlActionSpec('turnleft', 'Turn left', 'Movement'),
    ControlActionSpec('turnright', 'Turn right', 'Movement'),
    ControlActionSpec('jump', 'Jump', 'Actions'),
    ControlActionSpec('use', 'Use / Spin', 'Actions'),
    ControlActionSpec('fire', 'Fire / Ring', 'Actions'),
    ControlActionSpec('firenormal', 'Fire normal ring', 'Actions'),
    ControlActionSpec('tossflag', 'Toss flag / Drop', 'Actions'),
    ControlActionSpec('custom1', 'Custom action 1', 'Actions'),
    ControlActionSpec('custom2', 'Custom action 2', 'Actions'),
    ControlActionSpec('custom3', 'Custom action 3', 'Actions'),
    ControlActionSpec('lookup', 'Look up', 'Camera'),
    ControlActionSpec('lookdown', 'Look down', 'Camera'),
    ControlActionSpec('centerview', 'Center view', 'Camera'),
    ControlActionSpec('mouseaiming', 'Mouse look', 'Camera'),
    ControlActionSpec('camtoggle', 'Toggle camera', 'Camera'),
    ControlActionSpec('camleft', 'Rotate camera left', 'Camera'),
    ControlActionSpec('camright', 'Rotate camera right', 'Camera'),
    ControlActionSpec('camreset', 'Reset camera', 'Camera'),
    ControlActionSpec('weaponnext', 'Next weapon', 'Weapons'),
    ControlActionSpec('weaponprev', 'Previous weapon', 'Weapons'),
    ControlActionSpec('weapon1', 'Weapon 1 (Infinity)', 'Weapons'),
    ControlActionSpec('weapon2', 'Weapon 2 (Auto)', 'Weapons'),
    ControlActionSpec('weapon3', 'Weapon 3 (Bounce)', 'Weapons'),
    ControlActionSpec('weapon4', 'Weapon 4 (Scatter)', 'Weapons'),
    ControlActionSpec('weapon5', 'Weapon 5 (Grenade)', 'Weapons'),
    ControlActionSpec('weapon6', 'Weapon 6 (Explosion)', 'Weapons'),
    ControlActionSpec('weapon7', 'Weapon 7 (Rail)', 'Weapons'),
    ControlActionSpec('talkkey', 'Chat', 'System'),
    ControlActionSpec('teamtalkkey', 'Team chat', 'System'),
    ControlActionSpec('scores', 'Show rankings', 'System'),
    ControlActionSpec('pause', 'Pause', 'System'),
    ControlActionSpec('systemmenu', 'Open menu', 'System'),
    ControlActionSpec('console', 'Console', 'System'),
    ControlActionSpec('screenshot', 'Screenshot', 'System'),
    ControlActionSpec('recordgif', 'Record GIF / aPNG', 'System'),
    ControlActionSpec('viewpoint', 'Next spectator / coop view', 'System'),
  ];

  static final _legacySpecs = <CvarSpec>[
    for (final s in _srb2Specs)
      if (!const {
        'gr_models', 'midisoundfont', 'midisoundbank', 'http_source', 'use_gamepad',
        'cam_simpledist', 'cam_simpleheight', 'cam_lockaimassist', 'cam_lockedinput',
        'cam_centertoggle', 'directionchar', 'autobrake', 'autorecord', 'instantretry',
        'pauseifunfocused', 'tutorialprompt', 'masterserver_room_id', 'basenumlaps',
      }.contains(s.name))
        s.name == 'masterserver'
            ? const CvarSpec(
                name: 'masterserver',
                label: 'Master server URL',
                tab: ConfigSubTab.serverNet,
                group: 'Master Server & AFK',
                kind: CvarKind.text,
                defaultValue: 'ms.srb2classic.net:28900',
              )
            : s,
    const CvarSpec(name: 'gr_md2', label: 'MD2 3D Models (OpenGL)', tab: ConfigSubTab.video, group: 'OpenGL & 3D Models', kind: CvarKind.toggle, defaultValue: 'On'),
    const CvarSpec(name: 'gr_lightdithering', label: 'Light dithering (OpenGL)', tab: ConfigSubTab.video, group: 'OpenGL & 3D Models', kind: CvarKind.toggle, defaultValue: 'Off'),
    const CvarSpec(name: 'gr_curveshader', label: 'Curved surface shader', tab: ConfigSubTab.video, group: 'OpenGL & 3D Models', kind: CvarKind.toggle, defaultValue: 'Off'),
    const CvarSpec(name: 'r_secbright', label: 'Sector brightness offset', tab: ConfigSubTab.video, group: 'World & Rendering', kind: CvarKind.sliderInt, defaultValue: '0', min: -32, max: 32),
    const CvarSpec(name: 'r_spriteclip', label: 'Floor sprite clipping', tab: ConfigSubTab.video, group: 'World & Rendering', kind: CvarKind.toggle, defaultValue: 'On'),
    const CvarSpec(name: 'r_ffloorclip', label: 'FOF sprite clipping', tab: ConfigSubTab.video, group: 'World & Rendering', kind: CvarKind.toggle, defaultValue: 'On'),
    const CvarSpec(name: 'precipdensity', label: 'Precipitation density', tab: ConfigSubTab.video, group: 'World & Rendering', kind: CvarKind.dropdown, defaultValue: 'Moderate', options: ['None', 'Light', 'Moderate', 'Heavy', 'Maximum']),
    const CvarSpec(name: 'playtitlescreenmusic', label: 'Title screen music', tab: ConfigSubTab.audio, group: 'Behavior', kind: CvarKind.toggle, defaultValue: 'Yes', trueValue: 'Yes', falseValue: 'No'),
    const CvarSpec(name: 'use_joystick', perPlayer: true, label: 'Joystick device index', tab: ConfigSubTab.controls, group: 'Gamepad & Analog', kind: CvarKind.integer, defaultValue: '0', min: 0, max: 8, launchOverride: 'nojoy'),
    const CvarSpec(name: 'cam_clipping', perPlayer: true, label: 'Camera wall clipping', tab: ConfigSubTab.playerCamera, group: 'Camera', kind: CvarKind.dropdown, defaultValue: 'Exact', options: ['Vanilla', 'Exact']),
    const CvarSpec(name: 'cam_exact', perPlayer: true, label: 'Exact camera placement', tab: ConfigSubTab.playerCamera, group: 'Camera', kind: CvarKind.toggle, defaultValue: 'Off'),
    const CvarSpec(name: 'modernpause', label: 'Modern pause menu', tab: ConfigSubTab.gameplayHud, group: 'Gameplay', kind: CvarKind.toggle, defaultValue: 'On'),
    const CvarSpec(name: 'earthquake', label: 'Camera earthquake effect', tab: ConfigSubTab.gameplayHud, group: 'Gameplay', kind: CvarKind.toggle, defaultValue: 'On'),
    const CvarSpec(name: 'showtps', label: 'Show TPS counter', tab: ConfigSubTab.gameplayHud, group: 'HUD & Ghosts', kind: CvarKind.dropdown, defaultValue: 'Compact', options: ['No', 'Full', 'Compact']),
    const CvarSpec(name: 'sugoi_votetime', label: 'SUGOI map vote time (sec)', tab: ConfigSubTab.serverNet, group: 'Multiplayer Rules', kind: CvarKind.integer, defaultValue: '10', min: 1, max: 120),
    const CvarSpec(name: 'sugoi_whopicks', label: 'SUGOI who picks maps', tab: ConfigSubTab.serverNet, group: 'Multiplayer Rules', kind: CvarKind.dropdown, defaultValue: 'All', options: ['All', 'Server']),
  ];

  // -------------------- SRB2Kart (1.6) --------------------

  static const _kartControls = <ControlActionSpec>[
    ControlActionSpec('accelerate', 'Accelerate', 'Movement'),
    ControlActionSpec('brake', 'Brake', 'Movement'),
    ControlActionSpec('drift', 'Drift / Hop', 'Movement'),
    ControlActionSpec('turnleft', 'Turn left', 'Movement'),
    ControlActionSpec('turnright', 'Turn right', 'Movement'),
    ControlActionSpec('aimforward', 'Aim forward', 'Movement'),
    ControlActionSpec('aimbackward', 'Aim backward', 'Movement'),
    ControlActionSpec('fire', 'Use item', 'Actions'),
    ControlActionSpec('lookback', 'Look back', 'Camera'),
    ControlActionSpec('camtoggle', 'Toggle camera', 'Camera'),
    ControlActionSpec('camreset', 'Reset camera', 'Camera'),
    ControlActionSpec('lookup', 'Look up', 'Camera'),
    ControlActionSpec('lookdown', 'Look down', 'Camera'),
    ControlActionSpec('centerview', 'Center view', 'Camera'),
    ControlActionSpec('spectate', 'Spectate', 'System'),
    ControlActionSpec('talkkey', 'Chat', 'System'),
    ControlActionSpec('teamtalkkey', 'Team chat', 'System'),
    ControlActionSpec('scores', 'Show rankings', 'System'),
    ControlActionSpec('pause', 'Pause', 'System'),
    ControlActionSpec('systemmenu', 'Open menu', 'System'),
    ControlActionSpec('console', 'Console', 'System'),
    ControlActionSpec('screenshot', 'Screenshot', 'System'),
    ControlActionSpec('recordgif', 'Record GIF / aPNG', 'System'),
    ControlActionSpec('viewpoint', 'Next spectator view', 'System'),
    ControlActionSpec('custom1', 'Custom action 1', 'Actions'),
    ControlActionSpec('custom2', 'Custom action 2', 'Actions'),
    ControlActionSpec('custom3', 'Custom action 3', 'Actions'),
  ];

  static const _kartSpecs = <CvarSpec>[
    ..._commonVideo,
    CvarSpec(name: 'renderer', label: 'Renderer', tab: ConfigSubTab.video, group: 'Screen & Renderer', kind: CvarKind.dropdown, defaultValue: 'OpenGL', options: ['Software', 'OpenGL'], launchOverride: 'renderer'),
    CvarSpec(name: 'shadow', label: 'Drop shadows', tab: ConfigSubTab.video, group: 'World & Rendering', kind: CvarKind.toggle, defaultValue: 'Off'),
    CvarSpec(name: 'offsetshadows', label: 'Offset shadows', tab: ConfigSubTab.video, group: 'World & Rendering', kind: CvarKind.toggle, defaultValue: 'Off'),
    CvarSpec(name: 'gr_mdls', label: '3D Models (OpenGL)', tab: ConfigSubTab.video, group: 'OpenGL & 3D Models', kind: CvarKind.toggle, defaultValue: 'On'),
    CvarSpec(name: 'gr_fallbackplayermodel', label: 'Fallback player 3D model', tab: ConfigSubTab.video, group: 'OpenGL & 3D Models', kind: CvarKind.toggle, defaultValue: 'Off'),
    CvarSpec(name: 'gr_fovchange', label: 'Dynamic FOV on boost', tab: ConfigSubTab.video, group: 'OpenGL & 3D Models', kind: CvarKind.toggle, defaultValue: 'Off'),
    ..._commonAudioBehavior,
    CvarSpec(name: 'sounds', label: 'Sound effects', tab: ConfigSubTab.audio, group: 'Volume & Channels', kind: CvarKind.toggle, defaultValue: 'On', launchOverride: 'nosound'),
    CvarSpec(name: 'soundvolume', label: 'Sound volume', description: 'Volume from 0 to 31.', tab: ConfigSubTab.audio, group: 'Volume & Channels', kind: CvarKind.sliderInt, defaultValue: '18', min: 0, max: 31, launchOverride: 'nosound'),
    CvarSpec(name: 'digimusic', label: 'Digital music', tab: ConfigSubTab.audio, group: 'Volume & Channels', kind: CvarKind.toggle, defaultValue: 'On', launchOverride: 'nomusic'),
    CvarSpec(name: 'digmusicvolume', label: 'Digital music volume', description: 'Volume from 0 to 31.', tab: ConfigSubTab.audio, group: 'Volume & Channels', kind: CvarKind.sliderInt, defaultValue: '18', min: 0, max: 31, launchOverride: 'nomusic'),
    CvarSpec(name: 'songcredits', label: 'Show song credits banner', tab: ConfigSubTab.audio, group: 'Behavior', kind: CvarKind.toggle, defaultValue: 'On'),
    CvarSpec(name: 'kartvoices', label: 'Character voices', tab: ConfigSubTab.audio, group: 'Behavior', kind: CvarKind.dropdown, defaultValue: 'Tasteful', options: ['Off', 'Tasteful', 'All']),
    CvarSpec(name: 'kartinvinsfx', label: 'Invincibility / Grow audio', tab: ConfigSubTab.audio, group: 'Behavior', kind: CvarKind.dropdown, defaultValue: 'SFX', options: ['SFX', 'Music', 'Both']),
    CvarSpec(name: 'use_mouse', perPlayer: true, label: 'Enable mouse', tab: ConfigSubTab.controls, group: 'Mouse & Aiming', kind: CvarKind.toggle, defaultValue: 'Off', launchOverride: 'nomouse'),
    CvarSpec(name: 'mousesens', perPlayer: true, label: 'Mouse horizontal speed', tab: ConfigSubTab.controls, group: 'Mouse & Aiming', kind: CvarKind.sliderInt, defaultValue: '20', min: 1, max: 100),
    CvarSpec(name: 'mouseysens', perPlayer: true, label: 'Mouse vertical speed', tab: ConfigSubTab.controls, group: 'Mouse & Aiming', kind: CvarKind.sliderInt, defaultValue: '20', min: 1, max: 100),
    CvarSpec(name: 'invertmouse', perPlayer: true, label: 'Invert mouse Y-axis', tab: ConfigSubTab.controls, group: 'Mouse & Aiming', kind: CvarKind.toggle, defaultValue: 'Off'),
    CvarSpec(name: 'controlperkey', label: 'Controls per key', tab: ConfigSubTab.controls, group: 'Mouse & Aiming', kind: CvarKind.dropdown, defaultValue: 'Several', options: ['One', 'Several']),
    CvarSpec(name: 'use_joystick', perPlayer: true, label: 'Gamepad device index', tab: ConfigSubTab.controls, group: 'Gamepad & Analog', kind: CvarKind.integer, defaultValue: '1', min: 0, max: 8, launchOverride: 'nojoy'),
    CvarSpec(name: 'joy_xdeadzone', perPlayer: true, label: 'Horizontal stick deadzone', tab: ConfigSubTab.controls, group: 'Gamepad & Analog', kind: CvarKind.decimal, defaultValue: '0.3', min: 0, max: 1),
    CvarSpec(name: 'joy_ydeadzone', perPlayer: true, label: 'Vertical stick deadzone', tab: ConfigSubTab.controls, group: 'Gamepad & Analog', kind: CvarKind.decimal, defaultValue: '0.5', min: 0, max: 1),
    CvarSpec(name: 'joyaxis_turn', perPlayer: true, label: 'Axis: Steer left/right', tab: ConfigSubTab.controls, group: 'Gamepad Axes', kind: CvarKind.dropdown, defaultValue: 'Left X', options: _kartJoyAxes),
    CvarSpec(name: 'joyaxis_move', perPlayer: true, label: 'Axis: Accelerate / Move', tab: ConfigSubTab.controls, group: 'Gamepad Axes', kind: CvarKind.dropdown, defaultValue: 'R Trigger', options: _kartJoyAxes),
    CvarSpec(name: 'joyaxis_brake', perPlayer: true, label: 'Axis: Brake', tab: ConfigSubTab.controls, group: 'Gamepad Axes', kind: CvarKind.dropdown, defaultValue: 'None', options: _kartJoyAxes),
    CvarSpec(name: 'joyaxis_aim', perPlayer: true, label: 'Axis: Aim forward/back', tab: ConfigSubTab.controls, group: 'Gamepad Axes', kind: CvarKind.dropdown, defaultValue: 'Left Y', options: _kartJoyAxes),
    CvarSpec(name: 'joyaxis_drift', perPlayer: true, label: 'Axis: Drift', tab: ConfigSubTab.controls, group: 'Gamepad Axes', kind: CvarKind.dropdown, defaultValue: 'L Trigger', options: _kartJoyAxes),
    CvarSpec(name: 'joyaxis_fire', perPlayer: true, label: 'Axis: Use item', tab: ConfigSubTab.controls, group: 'Gamepad Axes', kind: CvarKind.dropdown, defaultValue: 'None', options: _kartJoyAxes),
    CvarSpec(name: 'joyaxis_lookback', perPlayer: true, label: 'Axis: Look back', tab: ConfigSubTab.controls, group: 'Gamepad Axes', kind: CvarKind.dropdown, defaultValue: 'None', options: _kartJoyAxes),
    CvarSpec(name: 'name', perPlayer: true, label: 'Player name', tab: ConfigSubTab.playerCamera, group: 'Player Profile', kind: CvarKind.text, defaultValue: 'Sonic', launchOverride: 'name'),
    CvarSpec(name: 'skin', perPlayer: true, label: 'Default character (skin)', tab: ConfigSubTab.playerCamera, group: 'Player Profile', kind: CvarKind.text, defaultValue: 'sonic'),
    CvarSpec(name: 'color', perPlayer: true, label: 'Default color', tab: ConfigSubTab.playerCamera, group: 'Player Profile', kind: CvarKind.color, defaultValue: 'Blue'),
    CvarSpec(name: 'cam_dist', perPlayer: true, label: 'Camera distance', tab: ConfigSubTab.playerCamera, group: 'Camera', kind: CvarKind.decimal, defaultValue: '160', min: 32, max: 1024),
    CvarSpec(name: 'cam_height', perPlayer: true, label: 'Camera height offset', tab: ConfigSubTab.playerCamera, group: 'Camera', kind: CvarKind.decimal, defaultValue: '50', min: -200, max: 400),
    CvarSpec(name: 'cam_speed', perPlayer: true, label: 'Camera follow speed', tab: ConfigSubTab.playerCamera, group: 'Camera', kind: CvarKind.decimal, defaultValue: '0.4', min: 0, max: 1),
    CvarSpec(name: 'cam_rotspeed', perPlayer: true, label: 'Camera rotation speed', tab: ConfigSubTab.playerCamera, group: 'Camera', kind: CvarKind.sliderInt, defaultValue: '10', min: 1, max: 45),
    CvarSpec(name: 'flipcam', perPlayer: true, label: 'Flip screen in reverse gravity', tab: ConfigSubTab.playerCamera, group: 'Camera', kind: CvarKind.toggle, defaultValue: 'No', trueValue: 'Yes', falseValue: 'No'),
    ..._commonChatConsoleAndFiles,
    CvarSpec(name: 'kartdisplayspeed', label: 'Speedometer units', tab: ConfigSubTab.gameplayHud, group: 'HUD & Ghosts', kind: CvarKind.dropdown, defaultValue: 'Percentage', options: ['Off', 'Percentage', 'Kilometers', 'Miles', 'Kart units']),
    CvarSpec(name: 'kartminimap', label: 'Minimap mode', tab: ConfigSubTab.gameplayHud, group: 'HUD & Ghosts', kind: CvarKind.dropdown, defaultValue: '4', options: ['0', '1', '2', '3', '4']),
    CvarSpec(name: 'kartcheck', label: 'Show Kart Check alerts', tab: ConfigSubTab.gameplayHud, group: 'HUD & Ghosts', kind: CvarKind.toggle, defaultValue: 'Yes', trueValue: 'Yes', falseValue: 'No'),
    CvarSpec(name: 'seenames', label: 'Show player names on screen', tab: ConfigSubTab.gameplayHud, group: 'HUD & Ghosts', kind: CvarKind.dropdown, defaultValue: 'Off', options: ['Off', 'On', 'Default']),
    CvarSpec(name: 'timerres', label: 'Timer display format', tab: ConfigSubTab.gameplayHud, group: 'HUD & Ghosts', kind: CvarKind.dropdown, defaultValue: 'Normal', options: ['Normal', 'Tics', 'Centiseconds']),
    CvarSpec(name: 'translucenthud', label: 'HUD opacity (0–10)', tab: ConfigSubTab.gameplayHud, group: 'HUD & Ghosts', kind: CvarKind.sliderInt, defaultValue: '10', min: 0, max: 10),
    CvarSpec(name: 'ghost_last', label: 'Ghost: Last run', tab: ConfigSubTab.gameplayHud, group: 'HUD & Ghosts', kind: CvarKind.dropdown, defaultValue: 'Show All', options: ['Hide', 'Show', 'Show All']),
    CvarSpec(name: 'ghost_besttime', label: 'Ghost: Best time', tab: ConfigSubTab.gameplayHud, group: 'HUD & Ghosts', kind: CvarKind.dropdown, defaultValue: 'Show All', options: ['Hide', 'Show', 'Show All']),
    CvarSpec(name: 'ghost_bestlap', label: 'Ghost: Best lap', tab: ConfigSubTab.gameplayHud, group: 'HUD & Ghosts', kind: CvarKind.dropdown, defaultValue: 'Show All', options: ['Hide', 'Show', 'Show All']),
    CvarSpec(name: 'ghost_guest', label: 'Ghost: Guest', tab: ConfigSubTab.gameplayHud, group: 'HUD & Ghosts', kind: CvarKind.dropdown, defaultValue: 'Show', options: ['Hide', 'Show']),
    CvarSpec(name: 'ghost_staff', label: 'Ghost: Staff', tab: ConfigSubTab.gameplayHud, group: 'HUD & Ghosts', kind: CvarKind.dropdown, defaultValue: 'Show', options: ['Hide', 'Show']),
    CvarSpec(name: 'vhspause', label: 'VHS pause effect', tab: ConfigSubTab.gameplayHud, group: 'Gameplay', kind: CvarKind.toggle, defaultValue: 'On'),
    CvarSpec(name: 'pauseifunfocused', label: 'Pause when window loses focus', tab: ConfigSubTab.gameplayHud, group: 'Gameplay', kind: CvarKind.toggle, defaultValue: 'Yes', trueValue: 'Yes', falseValue: 'No'),
    CvarSpec(name: 'showfocuslost', label: 'Show focus lost notice', tab: ConfigSubTab.gameplayHud, group: 'Gameplay', kind: CvarKind.toggle, defaultValue: 'Yes', trueValue: 'Yes', falseValue: 'No'),
    CvarSpec(name: 'rollingdemos', label: 'Title screen demos', tab: ConfigSubTab.gameplayHud, group: 'Gameplay', kind: CvarKind.toggle, defaultValue: 'On'),
    CvarSpec(name: 'cpusleep', label: 'CPU sleep (-1 = off, 0–28)', tab: ConfigSubTab.gameplayHud, group: 'Gameplay', kind: CvarKind.sliderInt, defaultValue: '1', min: -1, max: 28),
    CvarSpec(name: 'discordrp', label: 'Discord Rich Presence', tab: ConfigSubTab.gameplayHud, group: 'Gameplay', kind: CvarKind.toggle, defaultValue: 'On'),
    CvarSpec(name: 'discordasks', label: 'Discord join asks', tab: ConfigSubTab.gameplayHud, group: 'Gameplay', kind: CvarKind.toggle, defaultValue: 'Yes', trueValue: 'Yes', falseValue: 'No'),
    CvarSpec(name: 'discordstreamer', label: 'Discord streamer privacy', tab: ConfigSubTab.gameplayHud, group: 'Gameplay', kind: CvarKind.toggle, defaultValue: 'Off'),
    ..._commonServerNet,
    CvarSpec(name: 'http_source', label: 'HTTP addon mirror URL', tab: ConfigSubTab.serverNet, group: 'Hosting & Network', kind: CvarKind.text, defaultValue: ''),
    CvarSpec(name: 'server_contact', label: 'Server contact info', tab: ConfigSubTab.serverNet, group: 'Hosting & Network', kind: CvarKind.text, defaultValue: ''),
    CvarSpec(name: 'holepunchserver', label: 'UDP holepunch server', tab: ConfigSubTab.serverNet, group: 'Hosting & Network', kind: CvarKind.text, defaultValue: 'relay.kartkrew.org'),
    CvarSpec(name: 'stunserver', label: 'STUN server', tab: ConfigSubTab.serverNet, group: 'Hosting & Network', kind: CvarKind.text, defaultValue: 'stun.l.google.com:19302'),
    CvarSpec(name: 'netdemo_record', label: 'Online replay saving', tab: ConfigSubTab.serverNet, group: 'Multiplayer Rules', kind: CvarKind.dropdown, defaultValue: 'Manual Save', options: ['Off', 'Manual Save', 'Auto Save']),
  ];

  // -------------------- Ring Racers (2.4) --------------------

  static const _drrrControls = <ControlActionSpec>[
    ControlActionSpec('up', 'Up', 'Movement'),
    ControlActionSpec('down', 'Down', 'Movement'),
    ControlActionSpec('left', 'Steer left', 'Movement'),
    ControlActionSpec('right', 'Steer right', 'Movement'),
    ControlActionSpec('a', 'A (Accelerate)', 'Actions'),
    ControlActionSpec('b', 'B (Brake / Spindash)', 'Actions'),
    ControlActionSpec('c', 'C (Ring / Fastfall)', 'Actions'),
    ControlActionSpec('x', 'X (Look back)', 'Actions'),
    ControlActionSpec('y', 'Y (Spectate / Aux)', 'Actions'),
    ControlActionSpec('z', 'Z (Trick / Vote)', 'Actions'),
    ControlActionSpec('l', 'L (Drift / Item)', 'Actions'),
    ControlActionSpec('r', 'R (Item / Drift)', 'Actions'),
    ControlActionSpec('start', 'Start / Menu', 'System'),
    ControlActionSpec('abc', 'ABC macro', 'Actions'),
    ControlActionSpec('luaa', 'Lua A', 'Actions'),
    ControlActionSpec('luab', 'Lua B', 'Actions'),
    ControlActionSpec('luac', 'Lua C', 'Actions'),
    ControlActionSpec('talk', 'Chat', 'System'),
    ControlActionSpec('teamtalk', 'Team chat', 'System'),
    ControlActionSpec('rankings', 'Rankings', 'System'),
    ControlActionSpec('console', 'Console', 'System'),
    ControlActionSpec('screenshot', 'Screenshot', 'System'),
    ControlActionSpec('startmovie', 'Record video', 'System'),
    ControlActionSpec('startlossless', 'Record lossless', 'System'),
    ControlActionSpec('voicepushtotalk', 'Voice push-to-talk', 'System'),
  ];

  static final _drrrSpecs = <CvarSpec>[
    ..._commonVideo,
    const CvarSpec(name: 'renderer', label: 'Renderer', tab: ConfigSubTab.video, group: 'Screen & Renderer', kind: CvarKind.dropdown, defaultValue: 'Legacy GL', options: ['Software', 'Legacy GL', 'OpenGL'], launchOverride: 'renderer'),
    const CvarSpec(name: 'scr_effect', label: 'Screen scaling filter', tab: ConfigSubTab.video, group: 'Screen & Renderer', kind: CvarKind.dropdown, defaultValue: 'Sharp Bilinear', options: ['None', 'Nearest', 'Bilinear', 'Sharp Bilinear']),
    const CvarSpec(name: 'scr_scale', label: 'Render resolution scale', tab: ConfigSubTab.video, group: 'Screen & Renderer', kind: CvarKind.decimal, defaultValue: '1.0', min: 0.25, max: 4.0),
    const CvarSpec(name: 'parallelsoftware', label: 'Multithreaded software renderer', tab: ConfigSubTab.video, group: 'World & Rendering', kind: CvarKind.toggle, defaultValue: 'On'),
    const CvarSpec(name: 'shadow', label: 'Drop shadows', tab: ConfigSubTab.video, group: 'World & Rendering', kind: CvarKind.toggle, defaultValue: 'On'),
    const CvarSpec(name: 'gr_models', label: '3D Models (OpenGL)', tab: ConfigSubTab.video, group: 'OpenGL & 3D Models', kind: CvarKind.toggle, defaultValue: 'On'),
    const CvarSpec(name: 'gr_fovchange', label: 'Dynamic FOV on boost', tab: ConfigSubTab.video, group: 'OpenGL & 3D Models', kind: CvarKind.toggle, defaultValue: 'Off'),
    ..._commonAudioBehavior,
    const CvarSpec(name: 'sounds', label: 'Sound effects', tab: ConfigSubTab.audio, group: 'Volume & Channels', kind: CvarKind.toggle, defaultValue: 'On', launchOverride: 'nosound'),
    const CvarSpec(name: 'soundvolume', label: 'Sound volume (0–100)', tab: ConfigSubTab.audio, group: 'Volume & Channels', kind: CvarKind.sliderInt, defaultValue: '59', min: 0, max: 100, launchOverride: 'nosound'),
    const CvarSpec(name: 'music', label: 'Music', tab: ConfigSubTab.audio, group: 'Volume & Channels', kind: CvarKind.toggle, defaultValue: 'On', launchOverride: 'nomusic'),
    const CvarSpec(name: 'musicvolume', label: 'Music volume (0–100)', tab: ConfigSubTab.audio, group: 'Volume & Channels', kind: CvarKind.sliderInt, defaultValue: '59', min: 0, max: 100, launchOverride: 'nomusic'),
    const CvarSpec(name: 'volume', label: 'Master volume (0–100)', tab: ConfigSubTab.audio, group: 'Volume & Channels', kind: CvarKind.sliderInt, defaultValue: '59', min: 0, max: 100),
    const CvarSpec(name: 'voicevolume', label: 'Voice chat volume (0–100)', tab: ConfigSubTab.audio, group: 'Voice Chat', kind: CvarKind.sliderInt, defaultValue: '100', min: 0, max: 100),
    const CvarSpec(name: 'voice_mode', label: 'Voice activation mode', tab: ConfigSubTab.audio, group: 'Voice Chat', kind: CvarKind.dropdown, defaultValue: 'Activity', options: ['Activity', 'Push-to-Talk', 'Disabled']),
    const CvarSpec(name: 'voice_proximity', label: 'Proximity voice', tab: ConfigSubTab.audio, group: 'Voice Chat', kind: CvarKind.toggle, defaultValue: 'On'),
    const CvarSpec(name: 'voice_denoise', label: 'Microphone noise suppression', tab: ConfigSubTab.audio, group: 'Voice Chat', kind: CvarKind.toggle, defaultValue: 'On'),
    const CvarSpec(name: 'voice_selfmute', label: 'Mute own microphone', tab: ConfigSubTab.audio, group: 'Voice Chat', kind: CvarKind.toggle, defaultValue: 'Off'),
    const CvarSpec(name: 'voice_selfdeafen', label: 'Deafen voice chat', tab: ConfigSubTab.audio, group: 'Voice Chat', kind: CvarKind.toggle, defaultValue: 'Off'),
    const CvarSpec(name: 'streamersafemusic', label: 'Streamer-safe music mode', tab: ConfigSubTab.audio, group: 'Behavior', kind: CvarKind.toggle, defaultValue: 'Off'),
    const CvarSpec(name: 'continuousmusic', label: 'Continuous track music', tab: ConfigSubTab.audio, group: 'Behavior', kind: CvarKind.toggle, defaultValue: 'On'),
    const CvarSpec(name: 'songcredits', label: 'Show song credits banner', tab: ConfigSubTab.audio, group: 'Behavior', kind: CvarKind.toggle, defaultValue: 'On'),
    const CvarSpec(name: 'tauntvoices', label: 'Character voices', tab: ConfigSubTab.audio, group: 'Behavior', kind: CvarKind.toggle, defaultValue: 'On'),
    const CvarSpec(name: 'taunthorns', label: 'Horn sounds', tab: ConfigSubTab.audio, group: 'Behavior', kind: CvarKind.toggle, defaultValue: 'On'),
    const CvarSpec(name: 'use_mouse', label: 'Enable mouse', tab: ConfigSubTab.controls, group: 'Mouse & Aiming', kind: CvarKind.toggle, defaultValue: 'Off', launchOverride: 'nomouse'),
    const CvarSpec(name: 'alwaysgrabmouse', label: 'Always grab mouse cursor', tab: ConfigSubTab.controls, group: 'Mouse & Aiming', kind: CvarKind.toggle, defaultValue: 'Off', launchOverride: 'nomousegrab'),
    const CvarSpec(name: 'controlperkey', label: 'Controls per key', tab: ConfigSubTab.controls, group: 'Mouse & Aiming', kind: CvarKind.dropdown, defaultValue: 'One', options: ['One', 'Several']),
    const CvarSpec(name: 'deadzone', perPlayer: true, label: 'Controller stick deadzone', tab: ConfigSubTab.controls, group: 'Gamepad & Analog', kind: CvarKind.decimal, defaultValue: '0.25', min: 0, max: 1),
    const CvarSpec(name: 'rumble', perPlayer: true, label: 'Controller rumble', tab: ConfigSubTab.controls, group: 'Gamepad & Analog', kind: CvarKind.toggle, defaultValue: 'On'),
    const CvarSpec(name: 'padscale', perPlayer: true, label: 'Gamepad steering scale', tab: ConfigSubTab.controls, group: 'Gamepad & Analog', kind: CvarKind.decimal, defaultValue: '1', min: 0.1, max: 2),
    const CvarSpec(name: 'litesteer', perPlayer: true, label: 'Lite-steer assist', tab: ConfigSubTab.controls, group: 'Gamepad & Analog', kind: CvarKind.toggle, defaultValue: 'Off'),
    const CvarSpec(name: 'autoroulette', perPlayer: true, label: 'Auto item roulette', tab: ConfigSubTab.controls, group: 'Gamepad & Analog', kind: CvarKind.toggle, defaultValue: 'Off'),
    const CvarSpec(name: 'autoring', perPlayer: true, label: 'Auto ring pull', tab: ConfigSubTab.controls, group: 'Gamepad & Analog', kind: CvarKind.toggle, defaultValue: 'Off'),
    const CvarSpec(name: 'strictfastfall', perPlayer: true, label: 'Strict fastfall input', tab: ConfigSubTab.controls, group: 'Gamepad & Analog', kind: CvarKind.toggle, defaultValue: 'Off'),
    const CvarSpec(name: 'kickstartaccel', perPlayer: true, label: 'Kickstart accelerate', tab: ConfigSubTab.controls, group: 'Gamepad & Analog', kind: CvarKind.toggle, defaultValue: 'Off'),
    const CvarSpec(name: 'name', perPlayer: true, label: 'Player name', tab: ConfigSubTab.playerCamera, group: 'Player Profile', kind: CvarKind.text, defaultValue: 'Sonic', launchOverride: 'name'),
    const CvarSpec(name: 'skin', perPlayer: true, label: 'Default character (skin)', tab: ConfigSubTab.playerCamera, group: 'Player Profile', kind: CvarKind.text, defaultValue: 'sonic'),
    const CvarSpec(name: 'color', perPlayer: true, label: 'Default color', tab: ConfigSubTab.playerCamera, group: 'Player Profile', kind: CvarKind.color, defaultValue: 'Default'),
    const CvarSpec(name: 'follower', perPlayer: true, label: 'Follower companion', tab: ConfigSubTab.playerCamera, group: 'Player Profile', kind: CvarKind.text, defaultValue: 'None'),
    const CvarSpec(name: 'followercolor', perPlayer: true, label: 'Follower color', tab: ConfigSubTab.playerCamera, group: 'Player Profile', kind: CvarKind.color, defaultValue: 'Match'),
    const CvarSpec(name: 'cam_dist', perPlayer: true, label: 'Camera distance', tab: ConfigSubTab.playerCamera, group: 'Camera', kind: CvarKind.decimal, defaultValue: '190', min: 32, max: 1024),
    const CvarSpec(name: 'cam_height', perPlayer: true, label: 'Camera height offset', tab: ConfigSubTab.playerCamera, group: 'Camera', kind: CvarKind.decimal, defaultValue: '95', min: -200, max: 400),
    const CvarSpec(name: 'cam_speed', perPlayer: true, label: 'Camera follow speed', tab: ConfigSubTab.playerCamera, group: 'Camera', kind: CvarKind.decimal, defaultValue: '0.4', min: 0, max: 1),
    const CvarSpec(name: 'movebob', label: 'First-person view bob', tab: ConfigSubTab.playerCamera, group: 'Camera', kind: CvarKind.decimal, defaultValue: '1.0', min: 0, max: 2),
    ..._commonChatConsoleAndFiles,
    const CvarSpec(name: 'speedometer', label: 'Speedometer units', tab: ConfigSubTab.gameplayHud, group: 'HUD & Ghosts', kind: CvarKind.dropdown, defaultValue: 'Kilometers', options: ['Off', 'Percentage', 'Kilometers', 'Miles', 'Fracunits']),
    const CvarSpec(name: 'racesplits', label: 'Race split timer reference', tab: ConfigSubTab.gameplayHud, group: 'HUD & Ghosts', kind: CvarKind.dropdown, defaultValue: 'Leader', options: ['Off', 'Leader', 'Next']),
    const CvarSpec(name: 'attacksplits', label: 'Time Attack split reference', tab: ConfigSubTab.gameplayHud, group: 'HUD & Ghosts', kind: CvarKind.dropdown, defaultValue: 'Next', options: ['Off', 'Next', 'Best']),
    const CvarSpec(name: 'seenames', label: 'Show player names on screen', tab: ConfigSubTab.gameplayHud, group: 'HUD & Ghosts', kind: CvarKind.toggle, defaultValue: 'On'),
    const CvarSpec(name: 'showviewpointtext', label: 'Show spectated player name', tab: ConfigSubTab.gameplayHud, group: 'HUD & Ghosts', kind: CvarKind.toggle, defaultValue: 'On'),
    const CvarSpec(name: 'ghost_last', label: 'Ghost: Last run', tab: ConfigSubTab.gameplayHud, group: 'HUD & Ghosts', kind: CvarKind.dropdown, defaultValue: 'Show All', options: ['Hide', 'Show', 'Show All']),
    const CvarSpec(name: 'ghost_besttime', label: 'Ghost: Best time', tab: ConfigSubTab.gameplayHud, group: 'HUD & Ghosts', kind: CvarKind.dropdown, defaultValue: 'Show All', options: ['Hide', 'Show', 'Show All']),
    const CvarSpec(name: 'ghost_bestlap', label: 'Ghost: Best lap', tab: ConfigSubTab.gameplayHud, group: 'HUD & Ghosts', kind: CvarKind.dropdown, defaultValue: 'Show All', options: ['Hide', 'Show', 'Show All']),
    const CvarSpec(name: 'ghost_guest', label: 'Ghost: Guest', tab: ConfigSubTab.gameplayHud, group: 'HUD & Ghosts', kind: CvarKind.dropdown, defaultValue: 'Show', options: ['Hide', 'Show']),
    const CvarSpec(name: 'ghost_staff', label: 'Ghost: Staff', tab: ConfigSubTab.gameplayHud, group: 'HUD & Ghosts', kind: CvarKind.dropdown, defaultValue: 'Show', options: ['Hide', 'Show']),
    const CvarSpec(name: 'tilting', label: 'Kart slope tilting', tab: ConfigSubTab.gameplayHud, group: 'Gameplay', kind: CvarKind.toggle, defaultValue: 'On'),
    const CvarSpec(name: 'screenshake', label: 'Screen shake', tab: ConfigSubTab.gameplayHud, group: 'Gameplay', kind: CvarKind.dropdown, defaultValue: 'Full', options: ['Off', 'Reduced', 'Full']),
    const CvarSpec(name: 'reducevfx', label: 'Reduce visual effects', tab: ConfigSubTab.gameplayHud, group: 'Gameplay', kind: CvarKind.toggle, defaultValue: 'No', trueValue: 'Yes', falseValue: 'No'),
    const CvarSpec(name: 'tutorialprompt', label: 'Tutorial prompt', tab: ConfigSubTab.gameplayHud, group: 'Gameplay', kind: CvarKind.toggle, defaultValue: 'On'),
    const CvarSpec(name: 'pauseifunfocused', label: 'Pause when window loses focus', tab: ConfigSubTab.gameplayHud, group: 'Gameplay', kind: CvarKind.toggle, defaultValue: 'Yes', trueValue: 'Yes', falseValue: 'No'),
    const CvarSpec(name: 'showfocuslost', label: 'Show focus lost notice', tab: ConfigSubTab.gameplayHud, group: 'Gameplay', kind: CvarKind.toggle, defaultValue: 'Yes', trueValue: 'Yes', falseValue: 'No'),
    const CvarSpec(name: 'rollingdemos', label: 'Title screen demos', tab: ConfigSubTab.gameplayHud, group: 'Gameplay', kind: CvarKind.toggle, defaultValue: 'On'),
    const CvarSpec(name: 'cpusleep', label: 'CPU sleep (-1 = off, 0–28)', tab: ConfigSubTab.gameplayHud, group: 'Gameplay', kind: CvarKind.sliderInt, defaultValue: '1', min: -1, max: 28),
    const CvarSpec(name: 'discordrp', label: 'Discord Rich Presence', tab: ConfigSubTab.gameplayHud, group: 'Gameplay', kind: CvarKind.toggle, defaultValue: 'On'),
    const CvarSpec(name: 'discordasks', label: 'Discord join asks', tab: ConfigSubTab.gameplayHud, group: 'Gameplay', kind: CvarKind.toggle, defaultValue: 'Yes', trueValue: 'Yes', falseValue: 'No'),
    const CvarSpec(name: 'discordstreamer', label: 'Discord streamer privacy', tab: ConfigSubTab.gameplayHud, group: 'Gameplay', kind: CvarKind.toggle, defaultValue: 'Off'),
    ..._commonServerNet,
    const CvarSpec(name: 'http_source', label: 'HTTP addon mirror URL', tab: ConfigSubTab.serverNet, group: 'Hosting & Network', kind: CvarKind.text, defaultValue: ''),
    const CvarSpec(name: 'server_contact', label: 'Server contact info', tab: ConfigSubTab.serverNet, group: 'Hosting & Network', kind: CvarKind.text, defaultValue: ''),
    const CvarSpec(name: 'holepunchserver', label: 'UDP holepunch server', tab: ConfigSubTab.serverNet, group: 'Hosting & Network', kind: CvarKind.text, defaultValue: 'relay.kartkrew.org'),
    const CvarSpec(name: 'stunserver', label: 'STUN server', tab: ConfigSubTab.serverNet, group: 'Hosting & Network', kind: CvarKind.text, defaultValue: 'stun.l.google.com:19302'),
    const CvarSpec(name: 'allowguests', label: 'Allow splitscreen guests', tab: ConfigSubTab.serverNet, group: 'Multiplayer Rules', kind: CvarKind.toggle, defaultValue: 'On'),
    const CvarSpec(name: 'eliminatelast', label: 'Eliminate last place', tab: ConfigSubTab.serverNet, group: 'Multiplayer Rules', kind: CvarKind.toggle, defaultValue: 'Yes', trueValue: 'Yes', falseValue: 'No'),
    const CvarSpec(name: 'antigrief', label: 'Anti-grief timer (sec)', tab: ConfigSubTab.serverNet, group: 'Multiplayer Rules', kind: CvarKind.integer, defaultValue: '30', min: 0, max: 300),
    const CvarSpec(name: 'netdemo_record', label: 'Online replay saving', tab: ConfigSubTab.serverNet, group: 'Multiplayer Rules', kind: CvarKind.dropdown, defaultValue: 'Manual Save', options: ['Off', 'Manual Save', 'Auto Save']),
  ];

  /// Совместимость со старым кодом/тестами.
  static List<CvarSpec> get specs => _srb2Specs;

  static GameConfigSchema _baseForEngine(String engine) => switch (engine) {
        'srb2legacy' => GameConfigSchema(maxPlayers: 2, specs: _legacySpecs, controlActions: _legacyControls),
        'srb2kart' => const GameConfigSchema(maxPlayers: 4, specs: _kartSpecs, controlActions: _kartControls),
        'drrr' => GameConfigSchema(
          maxPlayers: 4,
          specs: _drrrSpecs,
          controlActions: _drrrControls,
          gamepadDetectControls: const ['up', 'down', 'left', 'right', 'a', 'b', 'c', 'x', 'y', 'z', 'l', 'r', 'start'],
        ),
        _ => const GameConfigSchema(maxPlayers: 2, specs: _srb2Specs, controlActions: _srb2Controls),
      };

  /// Возвращает схему редактора для игры [game], объединяя базовую схему её
  /// движка (`srb2`, `srb2legacy`, `srb2kart`, `drrr`) с переопределениями
  /// из `another_games` (`game.configDefinition`).
  static GameConfigSchema forGame(GameDef game) {
    final base = _baseForEngine(game.engine);
    final def = game.configDefinition;
    if (def == null || def.isEmpty) return base;

    final maxPlayers = def['players'] is num ? (def['players'] as num).toInt().clamp(1, 4) : base.maxPlayers;

    final removedCvars = <String>{
      if (def['remove_cvars'] is List)
        for (final x in def['remove_cvars'] as List) x.toString().trim().toLowerCase(),
    };
    final specs = <CvarSpec>[
      for (final s in base.specs)
        if (!removedCvars.contains(s.name.toLowerCase())) s,
    ];
    if (def['cvars'] is List) {
      for (final raw in def['cvars'] as List) {
        if (raw is! Map) continue;
        final added = CvarSpec.fromJson(Map<String, dynamic>.from(raw));
        final idx = specs.indexWhere((s) => s.name.toLowerCase() == added.name.toLowerCase());
        if (idx >= 0) {
          specs[idx] = added;
        } else {
          specs.add(added);
        }
      }
    }

    final removedControls = <String>{
      if (def['remove_controls'] is List)
        for (final x in def['remove_controls'] as List) x.toString().trim().toLowerCase(),
    };
    final controls = <ControlActionSpec>[
      for (final c in base.controlActions)
        if (!removedControls.contains(c.command.toLowerCase())) c,
    ];
    if (def['controls'] is List) {
      for (final raw in def['controls'] as List) {
        if (raw is! Map) continue;
        final added = ControlActionSpec.fromJson(Map<String, dynamic>.from(raw));
        final idx = controls.indexWhere((c) => c.command.toLowerCase() == added.command.toLowerCase());
        if (idx >= 0) {
          controls[idx] = added;
        } else {
          controls.add(added);
        }
      }
    }

    final detectControls = def['gamepad_detect_controls'] is List
        ? [
            for (final x in def['gamepad_detect_controls'] as List) x.toString().trim().toLowerCase(),
          ]
        : base.gamepadDetectControls;

    return GameConfigSchema(
      maxPlayers: maxPlayers,
      specs: specs,
      controlActions: controls,
      gamepadDetectControls: detectControls,
    );
  }

  /// Преобразует нажатую клавишу Flutter в имя клавиши SRB2 (`config.cfg`).
  static String? logicalKeyToSrb2(LogicalKeyboardKey key) {
    final id = key.keyId;
    if (id >= LogicalKeyboardKey.keyA.keyId && id <= LogicalKeyboardKey.keyZ.keyId) {
      return String.fromCharCode('a'.codeUnitAt(0) + (id - LogicalKeyboardKey.keyA.keyId));
    }
    if (id >= LogicalKeyboardKey.digit0.keyId && id <= LogicalKeyboardKey.digit9.keyId) {
      return String.fromCharCode('0'.codeUnitAt(0) + (id - LogicalKeyboardKey.digit0.keyId));
    }
    if (key == LogicalKeyboardKey.space) return 'space';
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) return 'enter';
    if (key == LogicalKeyboardKey.escape) return 'escape';
    if (key == LogicalKeyboardKey.tab) return 'tab';
    if (key == LogicalKeyboardKey.backspace) return 'backspace';
    if (key == LogicalKeyboardKey.capsLock) return 'caps lock';
    if (key == LogicalKeyboardKey.shiftLeft) return 'lshift';
    if (key == LogicalKeyboardKey.shiftRight) return 'rshift';
    if (key == LogicalKeyboardKey.controlLeft) return 'lctrl';
    if (key == LogicalKeyboardKey.controlRight) return 'rctrl';
    if (key == LogicalKeyboardKey.altLeft) return 'lalt';
    if (key == LogicalKeyboardKey.altRight) return 'ralt';
    if (key == LogicalKeyboardKey.arrowUp) return 'up arrow';
    if (key == LogicalKeyboardKey.arrowDown) return 'down arrow';
    if (key == LogicalKeyboardKey.arrowLeft) return 'left arrow';
    if (key == LogicalKeyboardKey.arrowRight) return 'right arrow';
    if (key == LogicalKeyboardKey.backquote) return 'TILDE';
    if (key == LogicalKeyboardKey.minus) return '-';
    if (key == LogicalKeyboardKey.equal) return '=';
    if (key == LogicalKeyboardKey.bracketLeft) return '[';
    if (key == LogicalKeyboardKey.bracketRight) return ']';
    if (key == LogicalKeyboardKey.backslash) return r'\';
    if (key == LogicalKeyboardKey.semicolon) return ';';
    if (key == LogicalKeyboardKey.quoteSingle) return "'";
    if (key == LogicalKeyboardKey.comma) return ',';
    if (key == LogicalKeyboardKey.period) return '.';
    if (key == LogicalKeyboardKey.slash) return '/';
    if (key == LogicalKeyboardKey.insert) return 'ins';
    if (key == LogicalKeyboardKey.delete) return 'del';
    if (key == LogicalKeyboardKey.home) return 'home';
    if (key == LogicalKeyboardKey.end) return 'end';
    if (key == LogicalKeyboardKey.pageUp) return 'pgup';
    if (key == LogicalKeyboardKey.pageDown) return 'pgdn';
    if (key == LogicalKeyboardKey.f1) return 'f1';
    if (key == LogicalKeyboardKey.f2) return 'f2';
    if (key == LogicalKeyboardKey.f3) return 'f3';
    if (key == LogicalKeyboardKey.f4) return 'f4';
    if (key == LogicalKeyboardKey.f5) return 'f5';
    if (key == LogicalKeyboardKey.f6) return 'f6';
    if (key == LogicalKeyboardKey.f7) return 'f7';
    if (key == LogicalKeyboardKey.f8) return 'f8';
    if (key == LogicalKeyboardKey.f9) return 'f9';
    if (key == LogicalKeyboardKey.f10) return 'f10';
    if (key == LogicalKeyboardKey.f11) return 'f11';
    if (key == LogicalKeyboardKey.f12) return 'f12';
    return null;
  }
}
