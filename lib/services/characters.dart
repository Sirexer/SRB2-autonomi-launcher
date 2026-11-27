import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'map_preview.dart';

/// Соник, заданный в коде игры (R_InitSkins), а не в S_SKIN: SRB2 2.1
/// (Legacy) и SRB2Kart (там же BlanKart, который дописывает его P_SKIN).
enum BuiltInSonic { none, legacy, kart }

/// Цвет персонажа: имя и 16 индексов палитры.
typedef SkinColor = (String, List<int>);

/// Персонаж (скин) из S_SKIN.
class CharacterInfo {
  /// Имя скина для консоли (`skin sonic`), в нижнем регистре.
  final String name;

  /// Имя для людей (`realname`, '_' → пробел).
  final String realname;

  /// Иконка в предпочитаемом цвете (PNG); null — нет, показывается заглушка.
  final Uint8List? icon;

  /// Файл, из которого персонаж.
  final String file;

  /// Портрет `XTRAB0` (уже в цветах персонажа, не перекрашивается); null — нет.
  final Uint8List? portrait;

  /// `prefcolor` из S_SKIN ("Blue", "Firecopper"); '' — не указан.
  final String prefColor;

  /// Ramp цвета [prefColor], если он нашёлся.
  final List<int>? prefRamp;

  /// Первый из 16 перекрашиваемых индексов палитры (`startcolor`).
  final int startColor;

  /// Описание из меню выбора персонажа (`PlayerText` в SOC-блоке
  /// `Character`, SOC_PLAY); '' — нет. Может содержать цвета SRB2.
  final String description;

  /// Статы карта из S_SKIN (`kartspeed`, `kartweight`, 1–9; SRB2Kart, Ring
  /// Racers, BlanKart); null — не указаны (игра берёт 5).
  final int? kartSpeed, kartWeight;

  // Иконка в индексах палитры — для перекраски в другие цвета (команды).
  final int _w, _h;
  final Uint8List? _pixels, _mask, _palette;
  final Map<String, Uint8List?> _recolored = {};

  CharacterInfo(this.name, this.realname, this.icon, this.file,
      {this.portrait,
      this.prefColor = '',
      this.prefRamp,
      this.startColor = 96,
      this.description = '',
      this.kartSpeed,
      this.kartWeight,
      int w = 0,
      int h = 0,
      Uint8List? pixels,
      Uint8List? mask,
      Uint8List? palette})
      : _w = w,
        _h = h,
        _pixels = pixels,
        _mask = mask,
        _palette = palette;

  /// Иконка в цвете [ramp] (например, красная команда). PNG-иконки и иконки
  /// без палитры не перекрашиваются — тогда [icon].
  /// Тот же персонаж под другим именем скина.
  CharacterInfo _renamed(String newName) => CharacterInfo(newName, realname, icon, file,
      portrait: portrait,
      prefColor: prefColor,
      prefRamp: prefRamp,
      startColor: startColor,
      description: description,
      kartSpeed: kartSpeed,
      kartWeight: kartWeight,
      w: _w,
      h: _h,
      pixels: _pixels,
      mask: _mask,
      palette: _palette);

  Uint8List? iconWithRamp(List<int>? ramp) {
    if (ramp == null || _pixels == null || _palette == null) return icon;
    return _recolored.putIfAbsent(ramp.join(','),
        () => CharacterScanner.render(_w, _h, _pixels, _mask!, _palette, startColor, ramp));
  }
}

/// Поиск персонажей в WAD/PK3 — как R_AddSkins в игре:
///
/// - персонаж начинается с lump `S_SKIN*` (первые 6 символов: S_SKIN1, S_SKIN2...);
/// - его спрайты идут следом до `S_END`, следующего `S_SKIN`/`P_SKIN` или
///   `S_START` (в PK3 S_END обычно нет — граница по следующему S_SKIN);
///   порядок — как записи лежат в файле;
/// - иконка: SRB2 / Ring Racers — спрайт `XTRAC0` среди спрайтов скина;
///   SRB2Kart — lump из `facewant` / `facerank` в S_SKIN; Ring Racers —
///   кадры спрайта `XTRA`: A — значок в таблице мест, C — миникарта
///   (ST_LoadFaceGraphics);
/// - в PK3 с папками на персонажа спрайты — все файлы его папки (порядок
///   записей в zip бывает любым);
/// - описание — `PlayerText` из SOC-блока `Character` с его `SkinName`;
/// - цвет: индексы `startcolor`…`startcolor+15` заменяются на ramp цвета
///   `prefcolor` — встроенного или своего из SOC (`SKINCOLOR`) / Lua (`skincolors[...]`).
class CharacterScanner {
  CharacterScanner._();

  /// Описания ванильных персонажей, заданные в коде SRB2 2.1 (m_menu.c,
  /// M_SetupChoosePlayer); \x82…\x80 — жёлтый. Переносы строк, сделанные
  /// под ширину меню, убраны. SOC (SOC_PLAY) их заменяет.
  static const vanillaDescriptions = <String, String>{
    'sonic': '\x82Sonic\x80 is the fastest of the three, but also the hardest to control. Beginners beware, '
        'but experts will find Sonic very powerful.\n\n'
        '\x82Ability:\x80 Speed Thok\nDouble jump to zoom forward with a huge burst of speed.\n\n'
        '\x82Tip:\x80 Simply letting go of forward does not slow down in SRB2. To slow down, hold the opposite '
        'direction.',
    'tails': "\x82Tails\x80 is the most mobile of the three, but has the slowest speed. Because of his mobility, "
        "he's well-suited to beginners.\n\n"
        '\x82Ability:\x80 Fly\nDouble jump to start flying for a limited time. Repetitively hit the jump button '
        'to ascend.\n\n'
        '\x82Tip:\x80 To quickly descend while flying, hit the spin button.',
    'knuckles': "\x82Knuckles\x80 is well-rounded and can destroy breakable walls simply by touching them, but "
        "he can't jump as high as the other two.\n\n"
        '\x82Ability:\x80 Glide & Climb\nDouble jump to glide in the air as long as jump is held. Glide into a '
        'wall to climb it.\n\n'
        '\x82Tip:\x80 Press spin while climbing to jump off the wall; press jump instead to jump off and face '
        'away from the wall.',
  };

  static Future<List<CharacterInfo>> scanAllInBackground(List<String> files, List<String> paletteFiles,
          {List<SkinColor> colors = const [],
          int startColor = 96,
          String iconFrames = 'C',
          bool portraits = true,
          BuiltInSonic builtInSonic = BuiltInSonic.none,
          Map<String, String> baseDescriptions = const {}}) =>
      Isolate.run(() => scanAll(files, paletteFiles,
          colors: colors,
          startColor: startColor,
          iconFrames: iconFrames,
          portraits: portraits,
          builtInSonic: builtInSonic,
          baseDescriptions: baseDescriptions));

  /// Все персонажи [files] в порядке загрузки. Номер в списке совпадает с
  /// номером скина в игре (сервер присылает его в списке игроков).
  /// [colors] — встроенные цвета игры; [startColor] — startcolor по умолчанию.
  /// [iconFrames] — кадры `XTRA` для иконки по порядку предпочтения ('C' у
  /// SRB2, 'BAC' у Ring Racers); [portraits] — искать портрет XTRAB0 (в SRB2
  /// он уже в цветах персонажа, в Ring Racers — нет); [builtInSonic] — Соник
  /// из кода игры (SRB2 2.1, SRB2Kart), а не из S_SKIN; [baseDescriptions] —
  /// описания по умолчанию (скин → текст), SOC их заменяет.
  static List<CharacterInfo> scanAll(List<String> files, List<String> paletteFiles,
      {List<SkinColor> colors = const [],
      int startColor = 96,
      String iconFrames = 'C',
      bool portraits = true,
      BuiltInSonic builtInSonic = BuiltInSonic.none,
      Map<String, String> baseDescriptions = const {}}) {
    final archives = <(String, AddonArchive)>[
      for (final f in files)
        if (AddonArchive.open(f) case final a?) (f, a),
    ];
    try {
      // Палитра на файл: у BlanKart файлы режима совместимости — со своей
      // перекраской (PaletteResolver).
      final palettes = PaletteResolver([for (final a in archives) a.$2], paletteFiles);
      final paletteOf = palettes.forFile;

      // Свои цвета и описания из всех файлов (персонаж может брать цвет из
      // другого аддона, описание тоже бывает в отдельном файле).
      final all = <SkinColor>[...colors];
      // Описания из кода игры, затем из SOC (SOC важнее).
      final descriptions = <String, String>{...baseDescriptions};
      final picNames = <String, String>{};
      for (final (_, a) in archives) {
        for (final (isSoc, text) in _scripts(a)) {
          if (isSoc) {
            all.addAll(parseSocColors(text));
            for (final MapEntry(key: skin, value: (description, picName)) in parseSocCharacters(text).entries) {
              if (description.isNotEmpty) descriptions[skin] = description;
              if (picName.isNotEmpty) picNames[skin] = picName;
            }
          } else {
            all.addAll(parseLuaColors(text));
          }
        }
      }
      final out = <CharacterInfo>[];
      // SRB2 2.1: Соник (скин 0) задан в коде игры (R_InitSkins), S_SKIN у
      // него нет — только спрайты и LIVSONIC / CHRSONIC в player.dta.
      if (builtInSonic == BuiltInSonic.legacy) {
        for (final (path, a) in archives) {
          final face = a.find('LIVSONIC');
          if (face == null) continue;
          final portrait = portraits ? _findIn(archives, picNames['sonic'] ?? 'CHRSONIC', prefer: a) : null;
          final icon = (a, face, false);
          out.add(_character('sonic', 'Sonic', path, icon,
              portrait == null ? (portraits ? icon : null) : (portrait.$1, portrait.$2, false), paletteOf,
              startColor, 'Blue', findColor(all, 'Blue'), descriptions['sonic'] ?? ''));
          break;
        }
      }
      // SRB2Kart: скин 0 — Соник из кода: лица PLAYWANT/PLAYRANK, Blue,
      // скорость 8, вес 2. BlanKart создаёт его пустым перед chars.kart и
      // дописывает P_SKIN (ниже).
      if (builtInSonic == BuiltInSonic.kart) {
        final face = _findIn(archives, 'PLAYWANT') ?? _findIn(archives, 'PLAYRANK');
        final from = face == null ? null : archives.where((x) => identical(x.$2, face.$1)).firstOrNull?.$1;
        final icon = face == null ? null : (face.$1, face.$2, false);
        out.add(_character('sonic', 'Sonic', from ?? (archives.isEmpty ? '' : archives.first.$1), icon,
            portraits ? icon : null, paletteOf, startColor, 'Blue', findColor(all, 'Blue'), descriptions['sonic'] ?? '',
            kartSpeed: 8, kartWeight: 2));
      }
      for (final (path, a) in archives) {
        for (final c in _skinsIn(path, a, paletteOf, all, startColor, descriptions, iconFrames, portraits,
            (name) => _findIn(archives, name, prefer: a), picNames)) {
          // Имя занято — игра называет скин «имя+номер» (sonic5), если и
          // оно занято — оставляет «skin».
          if (out.any((x) => x.name == c.name)) {
            final alt = '${c.name}${out.length}';
            out.add(c._renamed(out.any((x) => x.name == alt) ? 'skin' : alt));
          } else {
            out.add(c);
          }
        }
        // P_SKIN — правки уже загруженных скинов (R_PatchSkins, после S_SKIN файла).
        _patchSkins(a, out, archives, all, paletteOf);
      }
      return out;
    } finally {
      for (final a in archives) {
        a.$2.close();
      }
    }
  }

  /// Персонаж по имени игрока: Ring Racers не сообщает скин игроков
  /// (всегда 255), но боты и игроки без своего имени зовутся по персонажу —
  /// его `realname` (`Metal_Sonic` → «Metal Sonic»), реже `name`. Регистр,
  /// пробелы и '_' не важны; при повторах — последний загруженный.
  static CharacterInfo? findByName(List<CharacterInfo> characters, String playerName) {
    String key(String s) => s.replaceAll('_', ' ').replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
    final want = key(playerName);
    if (want.isEmpty) return null;
    for (final c in characters.reversed) {
      if (key(c.realname) == want) return c;
    }
    for (final c in characters.reversed) {
      if (key(c.name) == want) return c;
    }
    return null;
  }

  /// Ramp цвета по имени (без учёта регистра, пробелов, '_' и приставки
  /// SKINCOLOR_) или по номеру. Последний объявленный цвет важнее.
  static List<int>? findColor(List<SkinColor> colors, String nameOrNumber) {
    final n = int.tryParse(nameOrNumber.trim());
    if (n != null) return n > 0 && n < colors.length ? colors[n].$2 : null;
    final want = _colorKey(nameOrNumber);
    if (want.isEmpty) return null;
    for (final c in colors.reversed) {
      if (_colorKey(c.$1) == want) return c.$2;
    }
    return null;
  }

  static String _colorKey(String s) {
    var k = s.trim().toUpperCase();
    if (k.startsWith('SKINCOLOR_')) k = k.substring(10);
    return k.replaceAll(RegExp(r'[\s_]'), '');
  }

  static bool _isMarker(String name, String prefix) => name.length >= 6 && name.startsWith(prefix);

  static List<CharacterInfo> _skinsIn(String path, AddonArchive a, Uint8List? Function(String file) palette,
      List<SkinColor> colors, int defaultStart, Map<String, String> descriptions, String iconFrames, bool portraits,
      [(AddonArchive, ArchiveEntry)? Function(String lump)? findAnywhere, Map<String, String> picNames = const {}]) {
    final out = <CharacterInfo>[];
    final entries = a.entries;
    // Папки PK3 с одним S_SKIN — папка персонажа.
    final skinsInFolder = <String, int>{};
    if (a.isZip) {
      for (final e in entries) {
        if (_isMarker(e.name, 'S_SKIN')) skinsInFolder[e.folder] = (skinsInFolder[e.folder] ?? 0) + 1;
      }
    }
    for (var i = 0; i < entries.length; i++) {
      if (!_isMarker(entries[i].name, 'S_SKIN')) continue;
      Map<String, String> fields;
      try {
        fields = parseSkin(latin1.decode(a.read(entries[i]), allowInvalid: true));
      } catch (_) {
        continue;
      }
      // Без name игра всё равно добавляет скин («skin N», realname «Someone»):
      // пропустить его — сдвинуть номера скинов всех следующих.
      final named = (fields['name'] ?? '').toLowerCase();
      final name = named.isEmpty ? 'skin' : named;
      final realname = (fields['realname'] ?? (named.isEmpty ? 'Someone' : name)).replaceAll('_', ' ');
      final start = int.tryParse(fields['startcolor'] ?? '') ?? defaultStart;
      final pref = fields['prefcolor'] ?? '';
      final ramp = pref.isEmpty ? null : findColor(colors, pref);

      final sprites = _spritesOf(entries, i, skinsInFolder);

      (AddonArchive, ArchiveEntry)? iconLump;
      // SRB2Kart: facewant/facerank/facemmap; SRB2 2.1 (Legacy): face. Игра
      // ищет их во всех загруженных файлах (BlanKart: S_SKIN в main.pk3,
      // картинки — в chars.kart), сначала — в своём.
      for (final key in ['facewant', 'facerank', 'facemmap', 'face']) {
        final lump = fields[key];
        if (lump == null || lump.isEmpty || iconLump != null) continue;
        final up = lump.toUpperCase();
        if (a.find(up) case final e?) {
          iconLump = (a, e);
        } else {
          iconLump = findAnywhere?.call(up);
        }
      }
      for (final frame in iconFrames.split('')) {
        if (iconLump == null) {
          if (_xtraFrame(sprites, frame) case final e?) iconLump = (a, e);
        }
      }

      // Портрет — как есть, без перекраски. 2.1: PicName из SOC_PLAY, затем
      // charsel из S_SKIN (как M_DrawSetupChoosePlayerMenu); 2.2: XTRAB0.
      (AddonArchive, ArchiveEntry)? portrait;
      if (portraits) {
        for (final lump in [picNames[name] ?? '', (fields['charsel'] ?? '').toUpperCase()]) {
          if (lump.isEmpty || portrait != null) continue;
          if (a.find(lump) case final e?) {
            portrait = (a, e);
          } else {
            portrait = findAnywhere?.call(lump);
          }
        }
        if (portrait == null) {
          if (_xtraFrame(sprites, 'B') case final e?) portrait = (a, e);
        }
      }
      // Нет одной из картинок — берётся другая; нет обеих — спрайт стоящего
      // персонажа STNDA2 (у STNDA8 — отражённый: так он смотрит как A2).
      (AddonArchive, ArchiveEntry, bool)? icon = iconLump == null ? null : (iconLump.$1, iconLump.$2, false);
      (AddonArchive, ArchiveEntry, bool)? face = portrait == null ? null : (portrait.$1, portrait.$2, false);
      icon ??= face;
      if (portraits) face ??= icon;
      if (icon == null) {
        if (_standFrame(sprites) case (final e, final flip)) {
          icon = (a, e, flip);
          if (portraits) face = icon;
        }
      }
      out.add(_character(name, realname, path, icon, face, palette, start, pref, ramp, descriptions[name] ?? '',
          kartSpeed: _kartStat(fields, 'kartspeed'), kartWeight: _kartStat(fields, 'kartweight')));
    }
    return out;
  }

  /// Стат карта из S_SKIN как GETKARTSTAT в игре: atoi и 1..9; null — нет.
  static int? _kartStat(Map<String, String> fields, String key) {
    final v = fields[key];
    if (v == null) return null;
    return (int.tryParse(RegExp(r'^\s*[+-]?\d+').stringMatch(v)?.trim() ?? '') ?? 0).clamp(1, 9);
  }

  /// P_SKIN файла [a]: дописывает поля уже загруженных скинов по `name`
  /// (R_PatchSkins). Лица ищутся во всех файлах, цвет — среди [colors].
  static void _patchSkins(AddonArchive a, List<CharacterInfo> out, List<(String, AddonArchive)> archives,
      List<SkinColor> colors, Uint8List? Function(String file) palette) {
    for (final e in a.entries) {
      if (!_isMarker(e.name, 'P_SKIN')) continue;
      Map<String, String> fields;
      try {
        fields = parseSkin(latin1.decode(a.read(e), allowInvalid: true));
      } catch (_) {
        continue;
      }
      final name = (fields['name'] ?? '').toLowerCase();
      final i = out.lastIndexWhere((c) => c.name == name);
      if (name.isEmpty || i < 0) continue;
      final c = out[i];
      final realname = fields['realname']?.replaceAll('_', ' ') ?? c.realname;
      final pref = fields['prefcolor'] ?? c.prefColor;
      final ramp = fields.containsKey('prefcolor') ? findColor(colors, pref) : c.prefRamp;
      final start = int.tryParse(fields['startcolor'] ?? '') ?? c.startColor;
      final speed = _kartStat(fields, 'kartspeed') ?? c.kartSpeed;
      final weight = _kartStat(fields, 'kartweight') ?? c.kartWeight;
      (AddonArchive, ArchiveEntry)? face;
      for (final key in ['facewant', 'facerank', 'facemmap', 'face']) {
        final lump = fields[key];
        if (lump != null && lump.isNotEmpty) face ??= _findIn(archives, lump.toUpperCase(), prefer: a);
      }
      if (face != null) {
        final fresh = _character(c.name, realname, c.file, (face.$1, face.$2, false), null, palette, start, pref, ramp,
            c.description,
            kartSpeed: speed, kartWeight: weight);
        out[i] = CharacterInfo(c.name, realname, fresh.icon, c.file,
            portrait: c.portrait ?? fresh.icon,
            prefColor: pref,
            prefRamp: ramp,
            startColor: start,
            description: c.description,
            kartSpeed: speed,
            kartWeight: weight,
            w: fresh._w,
            h: fresh._h,
            pixels: fresh._pixels,
            mask: fresh._mask,
            palette: fresh._palette);
      } else {
        out[i] = CharacterInfo(c.name, realname, ramp == c.prefRamp ? c.icon : c.iconWithRamp(ramp), c.file,
            portrait: c.portrait,
            prefColor: pref,
            prefRamp: ramp,
            startColor: start,
            description: c.description,
            kartSpeed: speed,
            kartWeight: weight,
            w: c._w,
            h: c._h,
            pixels: c._pixels,
            mask: c._mask,
            palette: c._palette);
      }
    }
  }

  /// Персонаж: иконка [iconLump] в цвете [ramp] (перекрашивается и потом),
  /// портрет [portraitLump] как есть.
  static CharacterInfo _character(String name, String realname, String path,
      (AddonArchive, ArchiveEntry, bool)? iconLump, (AddonArchive, ArchiveEntry, bool)? portraitLump,
      Uint8List? Function(String file) palette, int start, String pref, List<int>? ramp, String description,
      {int? kartSpeed, int? kartWeight}) {
    Uint8List? portrait;
    if (portraitLump != null) {
      try {
        portrait = iconFromLump(portraitLump.$1.read(portraitLump.$2), () => palette(portraitLump.$1.path),
            flip: portraitLump.$3);
      } catch (_) {
        portrait = null;
      }
    }
    Uint8List? icon;
    (int, int, Uint8List, Uint8List)? indexed;
    Uint8List? pal;
    if (iconLump != null) {
      try {
        final data = iconLump.$1.read(iconLump.$2);
        if (_isPng(data)) {
          icon = data; // PNG не перекрашиваем (и не отражаем)
        } else {
          indexed = MapScanner.decodePatchIndexed(data);
          if (indexed != null && iconLump.$3) indexed = flipped(indexed);
          // Палитра — файла, где лежит картинка (BlanKart: режим совместимости).
          pal = palette(iconLump.$1.path);
          if (indexed != null && pal != null) {
            icon = render(indexed.$1, indexed.$2, indexed.$3, indexed.$4, pal, start, ramp);
          }
        }
      } catch (_) {
        icon = null;
      }
    }
    return CharacterInfo(name, realname, icon, path,
        portrait: portrait,
        prefColor: pref,
        prefRamp: ramp,
        startColor: start,
        description: description,
        kartSpeed: kartSpeed,
        kartWeight: kartWeight,
        w: indexed?.$1 ?? 0,
        h: indexed?.$2 ?? 0,
        pixels: pal == null ? null : indexed?.$3,
        mask: pal == null ? null : indexed?.$4,
        palette: pal);
  }

  /// Lump [name] — сначала в [prefer], затем в остальных файлах с конца
  /// (последний загруженный важнее, как в игре).
  static (AddonArchive, ArchiveEntry)? _findIn(List<(String, AddonArchive)> archives, String name,
      {AddonArchive? prefer}) {
    if (name.isEmpty) return null;
    if (prefer?.find(name) case final e?) return (prefer!, e);
    for (final (_, a) in archives.reversed) {
      if (a.find(name) case final e?) return (a, e);
    }
    return null;
  }

  /// Спрайты персонажа, чей S_SKIN — запись [skin]. В PK3, где у
  /// персонажа своя папка, — все файлы папки и подпапок (кроме папок
  /// других персонажей). Иначе, как в игре, — записи после S_SKIN до S_END,
  /// следующего S_SKIN / P_SKIN или S_START.
  static List<ArchiveEntry> _spritesOf(List<ArchiveEntry> entries, int skin, Map<String, int> skinsInFolder) {
    final folder = entries[skin].folder;
    if (folder.isNotEmpty && skinsInFolder[folder] == 1) {
      bool otherSkin(String f) => f != folder && skinsInFolder.containsKey(f);
      final inFolder = [
        for (final e in entries)
          if (e.folder.startsWith(folder) && !_isMarker(e.name, 'S_SKIN') && !otherSkin(e.folder)) e,
      ];
      // В папке скина нет спрайтов XTRA — берём ещё, как игра
      // (R_LoadSkinSprites): записи архива после S_SKIN до S_END / следующего
      // S_SKIN. Так устроены, например, файлы, где спрайты лежат не в папке S_SKIN.
      if (inFolder.any((e) => e.name.startsWith('XTRA'))) return inFolder;
      return [...inFolder, ..._spritesAfter(entries, skin)];
    }
    return _spritesAfter(entries, skin);
  }

  /// Записи после S_SKIN [skin] до S_END, S_START или следующего S_SKIN /
  /// P_SKIN — спрайты скина в порядке архива, как их берёт игра.
  static List<ArchiveEntry> _spritesAfter(List<ArchiveEntry> entries, int skin) {
    final out = <ArchiveEntry>[];
    for (var j = skin + 1; j < entries.length; j++) {
      final n = entries[j].name;
      if (n == 'S_END' || n == 'S_START' || _isMarker(n, 'S_SKIN') || _isMarker(n, 'P_SKIN')) break;
      out.add(entries[j]);
    }
    return out;
  }

  /// Кадр [frame] спрайта XTRA: `XTRAC0`, `XTRAC0C8` (общий lump для двух
  /// кадров) или второй кадр общего lump (`XTRAB0C0`).
  static ArchiveEntry? _xtraFrame(List<ArchiveEntry> sprites, String frame) {
    ArchiveEntry? second;
    for (final e in sprites) {
      final n = e.name;
      if (!n.startsWith('XTRA') || n.length < 6) continue;
      if (n[4] == frame && n[5] == '0') return e;
      if (n.length >= 8 && n[6] == frame && n[7] == '0') second ??= e;
    }
    return second;
  }

  static bool _isPng(Uint8List d) => d.length >= 4 && d[0] == 0x89 && d[1] == 0x50 && d[2] == 0x4E && d[3] == 0x47;

  /// Иконка в индексах → PNG: индексы start…start+15 — из [ramp] (если есть).
  static Uint8List render(int w, int h, Uint8List pixels, Uint8List mask, Uint8List palette, int start,
      List<int>? ramp) {
    final rgba = Uint8List(w * h * 4);
    for (var i = 0; i < pixels.length; i++) {
      if (mask[i] == 0) continue;
      var c = pixels[i];
      if (ramp != null && c >= start && c < start + 16 && c - start < ramp.length) c = ramp[c - start] & 0xFF;
      rgba[i * 4] = palette[c * 3];
      rgba[i * 4 + 1] = palette[c * 3 + 1];
      rgba[i * 4 + 2] = palette[c * 3 + 2];
      rgba[i * 4 + 3] = 255;
    }
    return MapScanner.encodePng(w, h, rgba);
  }

  /// Иконка из lump без перекраски (для совместимости).
  static Uint8List? iconFromLump(Uint8List data, Uint8List? Function() palette, {bool flip = false}) {
    if (_isPng(data)) return data;
    final pal = palette();
    var indexed = MapScanner.decodePatchIndexed(data);
    if (pal == null || indexed == null) return null;
    if (flip) indexed = flipped(indexed);
    return render(indexed.$1, indexed.$2, indexed.$3, indexed.$4, pal, 0, null);
  }

  /// Картинка в индексах, отражённая по горизонтали.
  static (int, int, Uint8List, Uint8List) flipped((int, int, Uint8List, Uint8List) img) {
    final (w, h, pixels, mask) = img;
    final p = Uint8List(pixels.length), m = Uint8List(mask.length);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        p[y * w + x] = pixels[y * w + (w - 1 - x)];
        m[y * w + x] = mask[y * w + (w - 1 - x)];
      }
    }
    return (w, h, p, m);
  }

  /// Спрайт стоящего персонажа под углом 2 (STND, кадр A) и нужно ли его
  /// отражать. По порядку: `STNDA2`/`STNDA2A8` как есть, `STNDA8A2` (A2 —
  /// отражение), `STNDA0` (один на все углы), `STNDA8` — отражённый,
  /// `STNDA1` — анфас. null — спрайта нет.
  static (ArchiveEntry, bool)? _standFrame(List<ArchiveEntry> sprites) {
    (ArchiveEntry, bool)? best;
    var rank = 99;
    for (final e in sprites) {
      final n = e.name;
      if (!n.startsWith('STND') || n.length < 6 || n[4] != 'A') continue;
      final (r, flip) = switch (n.substring(5)) {
        final rest when rest.startsWith('2') => (0, false),
        final rest when rest.length >= 3 && rest[1] == 'A' && rest[2] == '2' => (1, true),
        final rest when rest.startsWith('0') => (2, false),
        final rest when rest.startsWith('8') => (3, true),
        final rest when rest.startsWith('1') => (4, false),
        _ => (99, false),
      };
      if (r < rank) {
        rank = r;
        best = (e, flip);
      }
    }
    return best;
  }

  /// Свои цвета аддона: SOC-блоки `SKINCOLOR ...` и Lua `skincolors[...] = {...}`.
  /// SOC — как их грузит игра (SOC/, SOC_*, MAINCFG, OBJCTCFG); Lua — Lua/,
  /// Init.lua в PK3, LUA_* в WAD.
  static List<SkinColor> customColors(AddonArchive a) => [
        for (final d in customColorDefs(a)) (d.name, d.ramp),
      ];

  /// То же, что [customColors], но с флагом доступности (`accessible`).
  static List<({String name, List<int> ramp, bool accessible})> customColorDefs(AddonArchive a) => [
        for (final (isSoc, text) in _scripts(a)) ...(isSoc ? parseSocColorDefs(text) : parseLuaColorDefs(text)),
      ];

  /// Тексты SOC (true) и Lua (false) архива — те, что грузит игра.
  static List<(bool, String)> _scripts(AddonArchive a) {
    final out = <(bool, String)>[];
    for (final e in a.entries) {
      final lower = e.lowerPath;
      final isSoc = a.isZip
          ? lower.startsWith('soc/')
          : e.name == 'MAINCFG' || e.name == 'OBJCTCFG' || e.name.startsWith('SOC_');
      final isLua = a.isZip ? lower.startsWith('lua/') || lower == 'init.lua' : e.name.startsWith('LUA_');
      if ((!isSoc && !isLua) || e.size > 8 << 20) continue;
      try {
        out.add((isSoc, latin1.decode(a.read(e), allowInvalid: true)));
      } catch (_) {
        // битый файл — пропускаем
      }
    }
    return out;
  }

  /// SOC-блоки `Character N` (SOC_PLAY): `SkinName` → `PlayerText`.
  /// PlayerText, как в readPlayer игры, идёт до `#` и может занимать
  /// несколько строк.
  static Map<String, String> parseSocDescriptions(String text) => {
        for (final MapEntry(key: skin, value: (description, _)) in parseSocCharacters(text).entries)
          if (description.isNotEmpty) skin: description,
      };

  /// SOC-блоки `Character N`: `SkinName` → (PlayerText, PicName). PicName —
  /// картинка меню выбора персонажа (в 2.1 она важнее charsel из S_SKIN).
  static Map<String, (String, String)> parseSocCharacters(String text) {
    final out = <String, (String, String)>{};
    final lines = const LineSplitter().convert(text);
    var inCharacter = false;
    var skin = '';
    var description = '';
    var picName = '';
    void flush() {
      if (inCharacter && skin.isNotEmpty && (description.isNotEmpty || picName.isNotEmpty)) {
        out[skin] = (description, picName);
      }
      inCharacter = false;
      skin = '';
      description = '';
      picName = '';
    }

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) {
        flush();
        continue;
      }
      if (line.startsWith('#')) continue;
      final eq = line.indexOf('=');
      final word = line.split(RegExp(r'[\s=]+')).first.toUpperCase();
      if (eq < 0) {
        flush();
        inCharacter = word == 'CHARACTER';
        continue;
      }
      if (!inCharacter) continue;
      final value = line.substring(eq + 1).trim();
      if (word == 'PLAYERTEXT') {
        final buf = StringBuffer();
        var rest = value;
        var j = i;
        while (true) {
          final hash = rest.indexOf('#');
          if (hash >= 0) {
            buf.write(rest.substring(0, hash));
            break;
          }
          buf.write(rest);
          if (++j >= lines.length) break;
          buf.write('\n');
          rest = lines[j].trimRight();
        }
        i = j;
        description = buf.toString().trim();
      } else if (word == 'SKINNAME') {
        skin = value.split(RegExp(r'\s')).first.toLowerCase();
      } else if (word == 'PICNAME') {
        picName = value.split(RegExp(r'\s')).first.toUpperCase();
      }
    }
    flush();
    return out;
  }

  static List<int>? _ramp(String list) {
    final r = [
      for (final v in list.split(RegExp(r'[,\s]+')))
        if (int.tryParse(v.trim()) case final n?) n,
    ];
    return r.length >= 16 ? r.sublist(0, 16) : null;
  }

  /// Объединённый цвет: обычный (1 кадр) или анимированный супер-цвет (несколько).
  static List<({String name, List<List<int>> ramps, bool selectable})> groupColors(
    List<SkinColor> colors, {
    Set<String> hidden = const {},
    bool Function(String name)? isHidden,
  }) {
    final stepRe = RegExp(r'^(.*?)(?:[\s_]+)?(\d+)$');
    final groups = <({String key, String base, bool selectable, List<(int step, String name, List<int> ramp)> items})>[];
    final byKey = <String, int>{};

    for (final (name, ramp) in colors) {
      final isHid = hidden.contains(name.toLowerCase()) || (isHidden?.call(name) ?? false);
      final m = isHid ? stepRe.firstMatch(name.trim()) : null;
      final base = m?.group(1)?.trim() ?? '';
      final step = m == null ? null : int.tryParse(m.group(2)!);
      if (isHid && m != null && step != null && base.isNotEmpty) {
        final k = base.toLowerCase();
        var idx = byKey[k];
        if (idx == null) {
          idx = groups.length;
          byKey[k] = idx;
          groups.add((key: k, base: base, selectable: false, items: []));
        }
        groups[idx].items.add((step, name, ramp));
      } else {
        groups.add((key: '', base: name, selectable: !isHid, items: [(0, name, ramp)]));
      }
    }

    final out = <({String name, List<List<int>> ramps, bool selectable})>[];
    for (final g in groups) {
      if (g.key.isEmpty || g.items.length < 2) {
        for (final item in g.items) {
          out.add((name: item.$2, ramps: [item.$3], selectable: g.selectable));
        }
      } else {
        final sorted = [...g.items]..sort((a, b) => a.$1.compareTo(b.$1));
        out.add((name: g.base, ramps: [for (final item in sorted) item.$3], selectable: g.selectable));
      }
    }
    return out;
  }

  /// Порядок кадров переливания «туда-обратно» (как в игре: 1→5→1).
  static List<int> pulseIndices(int count) {
    if (count <= 1) return const [0];
    if (count == 2) return const [0, 1];
    return [for (var i = 0; i < count; i++) i, for (var i = count - 2; i >= 1; i--) i];
  }

  /// Представительный кадр анимированного цвета при отключённой анимации.
  static List<int> stillRamp(List<List<int>> ramps) =>
      ramps[ramps.length <= 2 ? ramps.length - 1 : (ramps.length * 3 ~/ 4)];

  static final _superIdRe = RegExp(r'^(?:SKINCOLOR_)?[TK]?SUPER.*\d$', caseSensitive: false);

  /// SOC: `SKINCOLOR SKINCOLOR_X` + `NAME = ...` + `RAMP = a,b,...` + `ACCESSIBLE = ...`.
  static List<SkinColor> parseSocColors(String text) => [for (final d in parseSocColorDefs(text)) (d.name, d.ramp)];

  static List<({String name, List<int> ramp, bool accessible})> parseSocColorDefs(String text) {
    final out = <({String name, List<int> ramp, bool accessible})>[];
    String? id;
    String? name;
    List<int>? ramp;
    bool? accessible;
    void flush() {
      if (id != null && ramp != null) {
        final resolvedName = name ?? id!;
        final ok = accessible ?? !_superIdRe.hasMatch(id!);
        out.add((name: resolvedName, ramp: ramp!, accessible: ok));
      }
      id = null;
      name = null;
      ramp = null;
      accessible = null;
    }

    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.split('#').first.trim();
      if (line.isEmpty) {
        flush();
        continue;
      }
      final eq = line.indexOf('=');
      if (eq < 0) {
        flush();
        final parts = line.split(RegExp(r'\s+'));
        if (parts.length >= 2 && parts[0].toUpperCase() == 'SKINCOLOR') id = parts[1];
        continue;
      }
      if (id == null) continue;
      final key = line.substring(0, eq).trim().toUpperCase();
      final value = line.substring(eq + 1).trim();
      if (key == 'NAME') name = value;
      if (key == 'RAMP') ramp = _ramp(value);
      if (key == 'ACCESSIBLE') {
        final v = value.toLowerCase();
        if (v == 'false' || v == 'no' || v == '0') accessible = false;
        if (v == 'true' || v == 'yes' || v == '1') accessible = true;
      }
    }
    flush();
    return out;
  }

  /// Lua: `skincolors[SKINCOLOR_X] = { name = "X", ramp = {...}, accessible = ... }`.
  static List<SkinColor> parseLuaColors(String text) => [for (final d in parseLuaColorDefs(text)) (d.name, d.ramp)];

  static List<({String name, List<int> ramp, bool accessible})> parseLuaColorDefs(String text) {
    final out = <({String name, List<int> ramp, bool accessible})>[];
    final start = RegExp(r'skincolors\s*\[\s*([A-Za-z0-9_]+)\s*\]\s*=\s*\{');
    for (final m in start.allMatches(text)) {
      // Тело таблицы до парной скобки.
      var depth = 1;
      var i = m.end;
      while (i < text.length && depth > 0) {
        final c = text[i];
        if (c == '{') depth++;
        if (c == '}') depth--;
        i++;
      }
      final body = text.substring(m.end, i - 1);
      final name = RegExp(r'''name\s*=\s*["']([^"']*)["']''').firstMatch(body)?.group(1);
      final rampText = RegExp(r'ramp\s*=\s*\{([^}]*)\}').firstMatch(body)?.group(1);
      final ramp = rampText == null ? null : _ramp(rampText);
      if (ramp != null) {
        final id = m.group(1)!;
        final accMatch = RegExp(r'accessible\s*=\s*(true|false)', caseSensitive: false).firstMatch(body);
        final accessible = accMatch != null
            ? accMatch.group(1)!.toLowerCase() == 'true'
            : !_superIdRe.hasMatch(id);
        out.add((name: name ?? id, ramp: ramp, accessible: accessible));
      }
    }
    return out;
  }

  /// S_SKIN: строки `ключ = значение`, комментарии `//` и `#`.
  static Map<String, String> parseSkin(String text) {
    final fields = <String, String>{};
    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('//') || line.startsWith('#')) continue;
      final eq = line.indexOf('=');
      if (eq <= 0) continue;
      final key = line.substring(0, eq).trim().toLowerCase();
      var value = line.substring(eq + 1).trim();
      // Игра берёт одно слово (strtok по пробелам).
      final space = value.indexOf(RegExp(r'\s'));
      if (space > 0) value = value.substring(0, space);
      fields.putIfAbsent(key, () => value);
    }
    return fields;
  }
}
