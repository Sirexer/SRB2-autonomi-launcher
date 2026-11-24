import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../models/game.dart';
import 'app_log.dart';
import 'map_preview.dart';

/// Форматы музыки SRB2. OGG/MP3/FLAC/WAV играет аудио-движок; MIDI и MUS —
/// свой синтезатор (с SoundFont); трекерные модули — libopenmpt, музыка
/// приставок (SPC, VGM...) — libgme, те же библиотеки, что у самой игры.
enum MusicFormat {
  ogg, opus, mp3, flac, wav, midi, mus, //
  mod, xm, it, s3m, mptm, //
  spc, vgm, vgz, nsf, gbs, gym, hes, kss, sap, ay, //
  unknown,
}

extension MusicFormatInfo on MusicFormat {
  /// Можно ли проиграть в лаунчере (Opus движок не собран).
  bool get playable => this != MusicFormat.opus && this != MusicFormat.unknown;

  /// Через встроенный синтезатор MIDI.
  bool get isSynth => this == MusicFormat.midi || this == MusicFormat.mus;

  /// Трекерный модуль (libopenmpt).
  bool get isTracker => const {MusicFormat.mod, MusicFormat.xm, MusicFormat.it, MusicFormat.s3m, MusicFormat.mptm}.contains(this);

  /// Музыка приставок (libgme).
  bool get isGme => index >= MusicFormat.spc.index && index <= MusicFormat.ay.index;

  /// Сначала рендерится в WAV (синтезатором или библиотекой).
  bool get isRendered => isSynth || isTracker || isGme;

  String get label => switch (this) {
        MusicFormat.opus => 'Opus',
        MusicFormat.midi => 'MIDI',
        MusicFormat.unknown => '?',
        _ => name.toUpperCase(),
      };

  /// Расширение для загрузки в аудио-движок.
  String get extension => switch (this) {
        MusicFormat.ogg => 'ogg',
        MusicFormat.opus => 'opus',
        MusicFormat.mp3 => 'mp3',
        MusicFormat.flac => 'flac',
        MusicFormat.unknown => 'bin',
        _ => 'wav', // WAV и всё, что рендерится в WAV
      };
}

/// Откуда файл с музыкой: файлы самой игры, скачанные аддоны репозиториев,
/// другие загрузки (папка DOWNLOAD: с серверов), другие аддоны в папке игры
/// или файлы, открытые в плеере вручную.
enum MusicCategory { game, addons, downloads, folder, opened }

/// Файл, где искать музыку, с игрой ('' — без игры) и категорией.
class MusicSource {
  final String path;
  final String game;
  final MusicCategory category;

  /// Название аддона из репозитория ('' — нет: файл игры, загрузка с сервера).
  final String label;
  const MusicSource(this.path, this.game, this.category, [this.label = '']);
}

/// Трек: lump музыки в WAD/PK3 или отдельный файл.
class MusicTrack {
  /// Файл (WAD/PK3 или сам аудиофайл).
  final String file;

  /// Путь записи внутри архива; '' — сам файл.
  final String entry;

  /// Имя музыки без приставки O_/D_ ("GFZ1"), как в MUSICDEF и Level header.
  final String lump;
  final String title;
  final String altTitle;
  final String authors;

  /// Формат по расширению или приставке (точно — после чтения файла).
  final MusicFormat format;

  /// Игра (GameDef.id; '' — файл открыт вручную) и категория файла.
  final String game;
  final MusicCategory category;

  /// Длительность и теги из самого файла (null — ещё не прочитаны).
  final TrackDetails? details;

  /// «Отпечаток» содержимого (размер и CRC-32): у одинаковой музыки в разных
  /// файлах — один и тот же; '' — неизвестен.
  final String fingerprint;

  const MusicTrack({
    required this.file,
    required this.entry,
    required this.lump,
    this.title = '',
    this.altTitle = '',
    this.authors = '',
    this.format = MusicFormat.unknown,
    this.game = '',
    this.category = MusicCategory.opened,
    this.details,
    this.fingerprint = '',
  });

  MusicTrack withSource(String game, MusicCategory category) => MusicTrack(
        file: file,
        entry: entry,
        lump: lump,
        title: title,
        altTitle: altTitle,
        authors: authors,
        format: format,
        game: game,
        category: category,
        details: details,
        fingerprint: fingerprint,
      );

  /// Длительность одного прохода (у петли — вступление и одна петля).
  Duration? get duration => details?.durationMs == null ? null : Duration(milliseconds: details!.durationMs!);

  /// Раздел списка: игра и категория.
  String get section => '$game|${category.name}';

  String get key => '$file|$entry';

  /// Название для показа: Title из MUSICDEF, название из тегов файла или имя lump.
  String get displayTitle => title.isNotEmpty ? title : (details?.title.isNotEmpty ?? false) ? details!.title : lump;

  /// Авторы: из MUSICDEF или из тегов файла.
  String get displayAuthors => authors.isNotEmpty ? authors : details?.author ?? '';
}

/// Что известно о треке из самого файла: длительность и теги (у модулей —
/// название и автор, у музыки приставок — ещё и игра, число дорожек).
class TrackDetails {
  final int? durationMs;
  final String title;
  final String author;
  final String game;
  final int subtracks;

  const TrackDetails({this.durationMs, this.title = '', this.author = '', this.game = '', this.subtracks = 1});

  Map<String, Object?> toJson() => {
        if (durationMs != null) 'd': durationMs,
        if (title.isNotEmpty) 't': title,
        if (author.isNotEmpty) 'a': author,
        if (game.isNotEmpty) 'g': game,
        if (subtracks != 1) 'n': subtracks,
      };

  static TrackDetails fromJson(Map<String, Object?> j) => TrackDetails(
        durationMs: j['d'] as int?,
        title: j['t'] as String? ?? '',
        author: j['a'] as String? ?? '',
        game: j['g'] as String? ?? '',
        subtracks: j['n'] as int? ?? 1,
      );
}

/// Что найдено в одном файле: музыка, MUSICDEF и уровни из SOC (какая
/// музыка где играет). Не меняется, пока не меняется файл — кэшируется.
class MusicFileInfo {
  /// (запись, имя музыки, формат) по порядку.
  final List<(String, String, MusicFormat)> tracks;
  final Map<String, MusicDef> defs;

  /// Карта → музыка уровня (имена без O_) и карта → название уровня.
  final Map<String, List<String>> levelMusic;
  final Map<String, String> levelTitles;

  /// Карта → музыка уровня в режиме Encore (Ring Racers: EncoreMusic).
  final Map<String, List<String>> levelEncore;

  /// Карты уровней, которые есть в самом файле.
  final Set<String> maps;

  /// Длительность и теги: запись → сведения (дополняются вторым проходом).
  final Map<String, TrackDetails> details;

  /// Запись → «отпечаток» содержимого (см. [MusicTrack.fingerprint]).
  final Map<String, String> fingerprints;

  MusicFileInfo({
    this.tracks = const [],
    this.defs = const {},
    this.levelMusic = const {},
    this.levelTitles = const {},
    this.levelEncore = const {},
    this.maps = const {},
    this.fingerprints = const {},
    Map<String, TrackDetails>? details,
  }) : details = details ?? {};

  Map<String, Object?> toJson() => {
        'tracks': [for (final (e, l, f) in tracks) [e, l, f.name]],
        'defs': {for (final d in defs.entries) d.key: [d.value.title, d.value.altTitle, d.value.authors]},
        'music': levelMusic,
        'titles': levelTitles,
        'encore': levelEncore,
        'maps': maps.toList(),
        'details': {for (final d in details.entries) d.key: d.value.toJson()},
        'fp': fingerprints,
      };

  static MusicFileInfo fromJson(Map<String, Object?> j) {
    MusicFormat format(String n) => MusicFormat.values.firstWhere((f) => f.name == n, orElse: () => MusicFormat.unknown);
    return MusicFileInfo(
      tracks: [
        for (final t in (j['tracks'] as List? ?? const []).cast<List>())
          (t[0] as String, t[1] as String, format(t[2] as String)),
      ],
      defs: {
        for (final d in (j['defs'] as Map? ?? const {}).entries)
          d.key as String: MusicDef((d.value as List)[0] as String, d.value[1] as String, d.value[2] as String),
      },
      levelMusic: {
        for (final m in (j['music'] as Map? ?? const {}).entries)
          m.key as String: [for (final x in m.value as List) x as String],
      },
      levelTitles: {for (final t in (j['titles'] as Map? ?? const {}).entries) t.key as String: t.value as String},
      levelEncore: {
        for (final m in (j['encore'] as Map? ?? const {}).entries)
          m.key as String: [for (final x in m.value as List) x as String],
      },
      maps: {for (final m in j['maps'] as List? ?? const []) m as String},
      fingerprints: {for (final f in (j['fp'] as Map? ?? const {}).entries) f.key as String: f.value as String},
      details: {
        for (final d in (j['details'] as Map? ?? const {}).entries)
          d.key as String: TrackDetails.fromJson((d.value as Map).cast<String, Object?>()),
      },
    );
  }
}

/// Уровень, на котором играет трек.
class LevelRef {
  final String map;
  final String title;

  /// Уровень (или его музыка) задан в файле самого трека, а не в игре.
  final bool fromTrackFile;

  /// Трек играет на уровне в режиме Encore.
  final bool encore;

  /// Encore — только по имени: SRB2Kart сама не включает O_MAPxxE (имя
  /// MAPxxE у неё — палитра Encore), такую музыку ставит Lua аддона.
  final bool byName;

  const LevelRef(this.map, this.title, {this.fromTrackFile = false, this.encore = false, this.byName = false});
}

/// Сборка списка треков из найденного в файлах.
class MusicLibrary {
  MusicLibrary._();

  /// Треки [sources] по порядку. Названия из MUSICDEF: у файлов игры — из
  /// файлов этой игры (поздний важнее), у аддонов и других файлов — только из
  /// их собственного MUSICDEF: трек аддона, заменивший, например, _TITLE, не
  /// получает название и авторов трека игры.
  static List<MusicTrack> compose(List<MusicSource> sources, Map<String, MusicFileInfo> infos) {
    final gameDefs = <String, Map<String, MusicDef>>{};
    for (final s in sources) {
      if (s.category != MusicCategory.game) continue;
      if (infos[s.path] case final info?) (gameDefs[s.game] ??= {}).addAll(info.defs);
    }
    return [
      for (final s in sources)
        if (infos[s.path] case final info?)
          for (final (entry, lump, format) in info.tracks)
            if ((s.category == MusicCategory.game ? gameDefs[s.game] : info.defs)?[lump.toUpperCase()] case final def)
              MusicTrack(
                file: s.path,
                entry: entry,
                lump: lump,
                title: def?.title ?? '',
                altTitle: def?.altTitle ?? '',
                authors: def?.authors ?? '',
                format: format,
                game: s.game,
                category: s.category,
                details: info.details[entry],
                fingerprint: info.fingerprints[entry] ?? '',
              ),
    ];
  }

  /// Уровни, где играет [t]: по заголовкам уровней игры, а у трека аддона —
  /// ещё и по SOC его файла (аддон может сменить музыку уровня или добавить
  /// свои уровни). [sources] — те же, что для [compose].
  ///
  /// Как в игре: у уровня без `Music` (и `MusicSlot`) в SRB2 и SRB2Kart
  /// играет MAPxxM (у Ring Racers по умолчанию музыки нет); `Music = NONE` —
  /// тишина. Encore: в Ring Racers — `EncoreMusic`, в SRB2Kart — O_MAPxxE по
  /// имени (её включает Lua аддона, не сама игра).
  static List<LevelRef> levelsOf(MusicTrack t, List<MusicSource> sources, Map<String, MusicFileInfo> infos) {
    final music = <String, List<String>>{};
    final encore = <String, List<String>>{};
    final titles = <String, String>{};
    final known = <String>{}; // уровни с заголовком или картой
    void add(MusicFileInfo info) {
      music.addAll(info.levelMusic);
      encore.addAll(info.levelEncore);
      titles.addAll(info.levelTitles);
      known
        ..addAll(info.levelMusic.keys)
        ..addAll(info.levelEncore.keys)
        ..addAll(info.levelTitles.keys)
        ..addAll(info.maps);
    }

    if (t.category != MusicCategory.opened) {
      for (final s in sources) {
        if (s.category != MusicCategory.game || s.game != t.game) continue;
        if (infos[s.path] case final info?) add(info);
      }
    }
    final own = t.category == MusicCategory.game ? null : infos[t.file];
    if (own != null) add(own);

    final engine = Games.find(t.game)?.engine ?? t.game;
    final ringRacers = engine == 'drrr';
    final lump = t.lump.toUpperCase();
    final maps = known.toList()..sort((a, b) => MapScanner.mapOrder(a).compareTo(MapScanner.mapOrder(b)));
    final result = <LevelRef>[];
    for (final m in maps) {
      final numbered = MapScanner.mapNumber(m) > 0;
      final normal = music[m] ?? (ringRacers || !numbered ? const <String>[] : ['${m}M']);
      final fromFile = own != null &&
          (own.levelMusic.containsKey(m) ||
              own.levelEncore.containsKey(m) ||
              own.levelTitles.containsKey(m) ||
              own.maps.contains(m));
      if (normal.contains(lump)) {
        result.add(LevelRef(m, titles[m] ?? '', fromTrackFile: fromFile));
      } else if (encore[m]?.contains(lump) ?? false) {
        result.add(LevelRef(m, titles[m] ?? '', fromTrackFile: fromFile, encore: true));
      } else if (engine == 'srb2kart' && numbered && lump == '${m}E') {
        result.add(LevelRef(m, titles[m] ?? '', fromTrackFile: fromFile, encore: true, byName: true));
      }
    }
    return result;
  }
}

/// Порядок треков в плеере: как в файле, по названию или по имени музыки.
enum MusicSort { file, title, lump }

/// Список плеера: поиск, скрытые форматы и сортировка. Треки остаются
/// сгруппированы по разделам (игра и категория — в порядке [tracks]) и
/// файлам; при сортировке по алфавиту файлы внутри раздела тоже идут по
/// алфавиту. [gameNames] — названия игр для поиска ("kart").
List<MusicTrack> arrangeTracks(
  List<MusicTrack> tracks, {
  String query = '',
  Set<MusicFormat> hidden = const {},
  MusicSort sort = MusicSort.file,
  Map<String, String> gameNames = const {},
  bool hideDuplicates = false,
  Set<String> keep = const {},
}) {
  final q = query.trim().toLowerCase();
  bool matches(MusicTrack t) =>
      q.isEmpty ||
      t.lump.toLowerCase().contains(q) ||
      t.displayTitle.toLowerCase().contains(q) ||
      t.altTitle.toLowerCase().contains(q) ||
      t.displayAuthors.toLowerCase().contains(q) ||
      (t.details?.game.toLowerCase().contains(q) ?? false) ||
      _baseName(t.file).toLowerCase().contains(q) ||
      (gameNames[t.game]?.toLowerCase().contains(q) ?? false);
  // Порядок разделов — по первому появлению.
  final sectionRank = <String, int>{};
  for (final t in tracks) {
    sectionRank.putIfAbsent(t.section, () => sectionRank.length);
  }
  final shown = [for (final t in tracks) if (!hidden.contains(t.format) && matches(t)) t];
  // Дубликаты — среди найденного: поиск по имени файла находит и его копию.
  final duplicates = hideDuplicates ? duplicateTrackKeys(shown, keep: keep) : const <String>{};
  // Группы по файлам в порядке первого появления.
  final groups = <String, List<MusicTrack>>{};
  for (final t in shown) {
    if (duplicates.contains(t.key)) continue;
    (groups[t.file] ??= []).add(t);
  }
  final files = groups.keys.toList();
  int rank(String file) => sectionRank[groups[file]!.first.section]!;
  // Файлы одного раздела — вместе (стабильно: по первому появлению).
  final firstSeen = {for (var i = 0; i < files.length; i++) files[i]: i};
  files.sort((a, b) {
    final r = rank(a) - rank(b);
    if (r != 0) return r;
    if (sort != MusicSort.file) {
      final c = naturalCompare(_baseName(a), _baseName(b));
      if (c != 0) return c;
    }
    return firstSeen[a]! - firstSeen[b]!;
  });
  if (sort != MusicSort.file) {
    for (final list in groups.values) {
      list.sort((a, b) {
        var c = sort == MusicSort.title ? naturalCompare(a.displayTitle, b.displayTitle) : 0;
        if (c == 0) c = naturalCompare(a.lump, b.lump);
        return c != 0 ? c : a.entry.compareTo(b.entry);
      });
    }
  }
  return [for (final f in files) ...groups[f]!];
}

String _baseName(String path) => path.substring(path.lastIndexOf(RegExp(r'[/\\]')) + 1);

/// Ключи треков-дубликатов: такая же музыка (тот же [MusicTrack.fingerprint])
/// есть в другом треке, который остаётся. Остаётся трек из более раннего
/// раздела (файлы игры, аддоны, другие загрузки, папка игры); в одном
/// разделе — из файла, чьё имя по алфавиту дальше (обычно более новая
/// версия: v6.3 после v6.2); в одном файле — первый. Открытые вручную не
/// скрываются и не скрывают другие. Треки из [keep] (избранное) никогда не
/// скрываются и остаются вместо своих копий. Дубликаты ищутся внутри одной
/// игры: одна и та же музыка в SRB2 и SRB2 Legacy видна у обеих.
Set<String> duplicateTrackKeys(List<MusicTrack> tracks, {Set<String> keep = const {}}) {
  final sectionRank = <String, int>{};
  for (final t in tracks) {
    sectionRank.putIfAbsent(t.section, () => sectionRank.length);
  }
  bool better(MusicTrack a, MusicTrack b) {
    final ka = keep.contains(a.key), kb = keep.contains(b.key);
    if (ka != kb) return ka;
    final r = sectionRank[a.section]! - sectionRank[b.section]!;
    if (r != 0) return r < 0;
    if (a.file == b.file) return false;
    return naturalCompare(_baseName(a.file), _baseName(b.file)) > 0;
  }

  String id(MusicTrack t) => '${t.game}\u0000${t.fingerprint}';
  final kept = <String, MusicTrack>{};
  for (final t in tracks) {
    if (t.fingerprint.isEmpty || t.category == MusicCategory.opened) continue;
    final current = kept[id(t)];
    if (current == null || better(t, current)) kept[id(t)] = t;
  }
  return {
    for (final t in tracks)
      if (t.fingerprint.isNotEmpty &&
          t.category != MusicCategory.opened &&
          !keep.contains(t.key) &&
          kept[id(t)]!.key != t.key)
        t.key,
  };
}

/// Сравнение без учёта регистра, числа — по значению ("Act 2" < "Act 10").
int naturalCompare(String a, String b) {
  a = a.toLowerCase();
  b = b.toLowerCase();
  bool digit(int c) => c >= 0x30 && c <= 0x39;
  var i = 0, j = 0;
  while (i < a.length && j < b.length) {
    final ca = a.codeUnitAt(i), cb = b.codeUnitAt(j);
    if (digit(ca) && digit(cb)) {
      var ie = i, je = j;
      while (ie < a.length && digit(a.codeUnitAt(ie))) {
        ie++;
      }
      while (je < b.length && digit(b.codeUnitAt(je))) {
        je++;
      }
      final da = a.substring(i, ie).replaceFirst(RegExp(r'^0+(?=.)'), '');
      final db = b.substring(j, je).replaceFirst(RegExp(r'^0+(?=.)'), '');
      if (da.length != db.length) return da.length - db.length;
      final c = da.compareTo(db);
      if (c != 0) return c;
      i = ie;
      j = je;
    } else {
      if (ca != cb) return ca - cb;
      i++;
      j++;
    }
  }
  return (a.length - i) - (b.length - j);
}

/// Описание трека из MUSICDEF.
class MusicDef {
  final String title;
  final String altTitle;
  final String authors;
  const MusicDef(this.title, this.altTitle, this.authors);
}

/// Данные трека для проигрывания.
class MusicData {
  final Uint8List bytes;
  final MusicFormat format;

  /// Точка петли (LOOPMS / LOOPPOINT); null — с начала.
  final Duration? loopStart;
  const MusicData(this.bytes, this.format, this.loopStart);
}

class MusicScanner {
  MusicScanner._();

  static const audioExtensions = {
    'ogg', 'oga', 'opus', 'mp3', 'flac', 'wav', 'mid', 'midi', 'mus', //
    'mod', 'xm', 'it', 's3m', 'mptm', 'spc', 'vgm', 'vgz', 'nsf', 'nsfe', 'gbs', 'gym', 'hes', 'kss', 'sap', 'ay',
  };

  /// Что в файлах [files] (путь → сведения), в отдельном изоляте.
  /// Пачками по несколько файлов: если на каком-то файле изолят упал, остальные
  /// всё равно разберутся (а этот — отдельно или в следующий раз).
  static Future<Map<String, MusicFileInfo>> scanFilesInBackground(List<String> files) async {
    final out = <String, MusicFileInfo>{};
    for (var i = 0; i < files.length; i += 8) {
      final chunk = files.sublist(i, math.min(i + 8, files.length));
      try {
        out.addAll(await Isolate.run(() => {for (final f in chunk) f: scanFile(f)}));
      } catch (_) {
        for (final f in chunk) {
          try {
            out[f] = await Isolate.run(() => scanFile(f));
          } catch (e) {
            AppLog.console('[music] cannot scan $f: $e');
          }
        }
      }
    }
    return out;
  }

  /// Треки из [files] по порядку — каждый файл со своим MUSICDEF (для
  /// открытых вручную файлов и тестов).
  static List<MusicTrack> scan(List<String> files) => MusicLibrary.compose(
        [for (final f in files) MusicSource(f, '', MusicCategory.opened)],
        {for (final f in files) f: scanFile(f)},
      );

  /// Музыка, MUSICDEF и уровни файла; битый файл — пустые сведения.
  static MusicFileInfo scanFile(String path) {
    final raw = <(String, String, String, MusicFormat)>[];
    final defs = <String, MusicDef>{};
    final levels = SocInfo();
    final maps = <String>{};
    final fingerprints = <String, String>{};
    try {
      _scanFile(path, raw, defs, levels, maps, fingerprints);
    } catch (e) {
      // битый файл — без его треков (что нашлось до ошибки — остаётся)
      AppLog.console('[music] $path: $e');
    }
    return MusicFileInfo(
      tracks: [for (final (_, entry, lump, format) in raw) (entry, lump, format)],
      defs: defs,
      levelMusic: levels.music,
      levelTitles: levels.titles,
      levelEncore: levels.encoreMusic,
      maps: maps,
      fingerprints: fingerprints,
    );
  }

  static String _ext(String path) {
    final name = path.substring(path.lastIndexOf(RegExp(r'[/\\]')) + 1);
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }

  static MusicFormat formatFromExtension(String ext) => switch (ext) {
        'ogg' || 'oga' => MusicFormat.ogg,
        'opus' => MusicFormat.opus,
        'mp3' => MusicFormat.mp3,
        'flac' => MusicFormat.flac,
        'wav' => MusicFormat.wav,
        'mid' || 'midi' => MusicFormat.midi,
        'mus' => MusicFormat.mus,
        'mod' => MusicFormat.mod,
        'xm' => MusicFormat.xm,
        'it' => MusicFormat.it,
        's3m' => MusicFormat.s3m,
        'mptm' => MusicFormat.mptm,
        'spc' => MusicFormat.spc,
        'vgm' => MusicFormat.vgm,
        'vgz' => MusicFormat.vgz,
        'nsf' || 'nsfe' => MusicFormat.nsf,
        'gbs' => MusicFormat.gbs,
        'gym' => MusicFormat.gym,
        'hes' => MusicFormat.hes,
        'kss' => MusicFormat.kss,
        'sap' => MusicFormat.sap,
        'ay' => MusicFormat.ay,
        _ => MusicFormat.unknown,
      };

  /// Имя музыки из имени lump: "O_GFZ1" → "GFZ1".
  static String musicName(String lump) {
    final u = lump.toUpperCase();
    return u.startsWith('O_') || u.startsWith('D_') ? lump.substring(2) : lump;
  }

  static void _scanFile(String path, List<(String, String, String, MusicFormat)> out, Map<String, MusicDef> defs,
      SocInfo levels, Set<String> maps, Map<String, String> fingerprints) {
    final ext = _ext(path);
    if (audioExtensions.contains(ext)) {
      // Отдельный аудиофайл.
      final base = path.substring(path.lastIndexOf(RegExp(r'[/\\]')) + 1);
      final name = base.contains('.') ? base.substring(0, base.lastIndexOf('.')) : base;
      out.add((path, '', name, formatFromExtension(ext)));
      return;
    }
    final a = AddonArchive.open(path);
    if (a == null) return;
    try {
      // Уровни: какая музыка где играет.
      levels.addAll(MapScanner.readSocInfo(a));
      maps.addAll(MapScanner.mapNames(a));
      // MUSICDEF.
      for (final e in a.entries) {
        if (e.name != 'MUSICDEF' || e.size > 4 << 20) continue;
        // Не прочитался (например, неизвестный метод сжатия) — без названий,
        // но треки файла всё равно ищем.
        try {
          defs.addAll(parseMusicDef(latin1.decode(a.read(e), allowInvalid: true)));
        } catch (_) {}
      }
      final seen = <String>{};
      if (a.isZip) {
        for (final e in a.entries) {
          final inMusic = e.lowerPath.startsWith('music/');
          // В PK3 музыка либо в папке music/, либо в корне с префиксом O_/D_
          final isRoot = !e.path.contains('/') && !e.path.contains('\\');
          final prefixed = e.name.startsWith('O_') || e.name.startsWith('D_');
          if (!inMusic && !(isRoot && prefixed)) continue;
          if (e.name == 'MUSICDEF' || e.size == 0) continue;
          final name = musicName(e.name);
          var format = formatFromExtension(_ext(e.path));
          if (format == MusicFormat.unknown) format = _sniff(a, e);
          // Нераспознанное — не музыка (или формат, который не сыграть): не показываем.
          if (format == MusicFormat.unknown) continue;
          if (seen.add(e.path)) {
            out.add((path, e.path, name, format));
            fingerprints[e.path] = _fingerprint(a, e);
          }
        }
      } else {
        var inMarkers = false;
        for (var i = 0; i < a.entries.length; i++) {
          final e = a.entries[i];
          if (e.name == 'M_START' || e.name == 'MS_START') {
            inMarkers = true;
            continue;
          }
          if (e.name == 'M_END' || e.name == 'MS_END') {
            inMarkers = false;
            continue;
          }
          final prefixed = e.name.startsWith('O_') || e.name.startsWith('D_');
          if ((!inMarkers && !prefixed) || e.size == 0) continue;
          var format = _sniff(a, e);
          // В WAD имена lump могут повторяться — запись различаем по номеру.
          if (format == MusicFormat.unknown) continue;
          out.add((path, '#$i', musicName(e.name), format));
          fingerprints['#$i'] = _fingerprint(a, e);
        }
      }
    } finally {
      a.close();
    }
  }

  /// «Отпечаток» записи: размер и CRC-32 содержимого. У PK3 CRC уже есть в
  /// каталоге zip, у WAD считаем (результат кэшируется вместе с файлом).
  /// Огромные записи (больше 64 МБ) не читаем — без отпечатка.
  static String _fingerprint(AddonArchive a, ArchiveEntry e) {
    try {
      if (a.isZip && e.crc != 0) return '${e.size}:${e.crc.toRadixString(16)}';
      if (e.size <= 0 || e.size > 64 << 20) return '';
      return '${e.size}:${MapScanner.crc32(a.read(e)).toRadixString(16)}';
    } catch (_) {
      return '';
    }
  }

  /// Формат по первым байтам записи (у lumps WAD и файлов без расширения),
  /// чтобы фильтр форматов работал до проигрывания.
  static MusicFormat _sniff(AddonArchive a, ArchiveEntry e) {
    try {
      return detectFormat(a.readHead(e, 2048));
    } catch (_) {
      return MusicFormat.unknown;
    }
  }

  /// MUSICDEF: блоки `Lump NAME` (или `Lump A,B`) и поля Title, AltTitle,
  /// Authors; '_' в значениях — пробелы.
  static Map<String, MusicDef> parseMusicDef(String text) {
    final out = <String, MusicDef>{};
    var names = <String>[];
    var title = '', alt = '', authors = '';
    void flush() {
      for (final n in names) {
        out[n] = MusicDef(title, alt, authors);
      }
      names = [];
      title = alt = authors = '';
    }

    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.split('#').first.trim();
      if (line.isEmpty) continue;
      final eq = line.indexOf('=');
      if (eq < 0) {
        final parts = line.split(RegExp(r'\s+'));
        if (parts.first.toUpperCase() == 'LUMP' && parts.length >= 2) {
          flush();
          names = [
            for (final n in parts.sublist(1).join(' ').split(','))
              if (n.trim().isNotEmpty) musicName(n.trim()).toUpperCase(),
          ];
        }
        continue;
      }
      if (names.isEmpty) continue;
      final key = line.substring(0, eq).trim().toUpperCase();
      final value = line.substring(eq + 1).trim().replaceAll('_', ' ');
      if (key == 'TITLE') title = value;
      if (key == 'ALTTITLE') alt = value;
      if (key == 'AUTHORS') authors = value;
    }
    flush();
    return out;
  }

  // --- Чтение трека ---

  static Future<MusicData> loadInBackground(MusicTrack t) => Isolate.run(() => load(t));

  static MusicData load(MusicTrack t) {
    Uint8List bytes;
    if (t.entry.isEmpty) {
      bytes = File(t.file).readAsBytesSync();
    } else {
      final a = AddonArchive.open(t.file);
      if (a == null) throw const FileSystemException('Cannot open the file');
      try {
        bytes = readEntry(a, t.entry);
      } finally {
        a.close();
      }
    }
    // Формат по содержимому; если не узнали (MOD без подписи) — по имени.
    var format = detectFormat(bytes);
    if (format == MusicFormat.unknown) format = t.format;
    return MusicData(bytes, format, loopPoint(bytes, format));
  }

  /// Данные записи [entry] трека ('#номер' в WAD, путь в PK3).
  static Uint8List readEntry(AddonArchive a, String entry) {
    ArchiveEntry? e;
    if (entry.startsWith('#')) {
      final i = int.parse(entry.substring(1));
      if (i < a.entries.length) e = a.entries[i];
    } else {
      for (final x in a.entries) {
        if (x.path == entry) e = x;
      }
    }
    if (e == null) throw const FileSystemException('Track not found');
    return Uint8List.fromList(a.read(e));
  }

  // --- Длительность (без декодирования) ---

  /// Длительность WAV, OGG Vorbis/Opus, FLAC и MP3 по заголовкам; null —
  /// не удалось или другой формат.
  static int? durationMs(Uint8List b, MusicFormat f) {
    try {
      final seconds = switch (f) {
        MusicFormat.wav => _wavSeconds(b),
        MusicFormat.ogg || MusicFormat.opus => _oggSeconds(b),
        MusicFormat.flac => _flacSeconds(b),
        MusicFormat.mp3 => _mp3Seconds(b),
        _ => null,
      };
      return seconds == null || !seconds.isFinite || seconds <= 0 ? null : (seconds * 1000).round();
    } catch (_) {
      return null;
    }
  }

  static double? _wavSeconds(Uint8List b) {
    final bd = ByteData.sublistView(b);
    var byteRate = 0;
    for (var p = 12; p + 8 <= b.length;) {
      final id = latin1.decode(b.sublist(p, p + 4));
      final len = bd.getUint32(p + 4, Endian.little);
      if (id == 'fmt ' && p + 16 <= b.length) byteRate = bd.getUint32(p + 16, Endian.little);
      if (id == 'data') return byteRate <= 0 ? null : math.min(len, b.length - p - 8) / byteRate;
      p += 8 + len + (len & 1);
    }
    return null;
  }

  /// Позиция последней страницы Ogg (granule) / частота; у Opus — 48 кГц
  /// минус pre-skip.
  static double? _oggSeconds(Uint8List b) {
    if (!_starts(b, _a('OggS'))) return null;
    final bd = ByteData.sublistView(b);
    final first = 27 + b[26];
    var rate = 0, preSkip = 0;
    if (_starts(b, _a('OpusHead'), first)) {
      rate = 48000;
      preSkip = bd.getUint16(first + 10, Endian.little);
    } else if (_starts(b, [1, ..._a('vorbis')], first)) {
      rate = bd.getUint32(first + 12, Endian.little);
    }
    if (rate <= 0) return null;
    // Последняя страница — ищем 'OggS' с конца.
    for (var p = b.length - 27; p >= 0 && p >= b.length - (1 << 20); p--) {
      if (b[p] != 0x4F || !_starts(b, _a('OggS'), p)) continue;
      final granule = bd.getUint32(p + 6, Endian.little) + bd.getUint32(p + 10, Endian.little) * 4294967296;
      if (granule <= 0 || granule >= 0x7FFFFFFFFFFFF) continue; // -1 у неполной страницы
      return (granule - preSkip) / rate;
    }
    return null;
  }

  static double? _flacSeconds(Uint8List b) {
    if (!_starts(b, _a('fLaC')) || b.length < 26 || b[4] & 0x7F != 0) return null; // STREAMINFO первым
    final rate = (b[18] << 12) | (b[19] << 4) | (b[20] >> 4);
    final total = (b[21] & 0x0F) * 4294967296 + ((b[22] << 24) | (b[23] << 16) | (b[24] << 8) | b[25]);
    return rate <= 0 || total <= 0 ? null : total / rate;
  }

  /// MP3 (Layer III): по заголовку Xing/Info или VBRI, иначе по битрейту
  /// первого кадра (CBR).
  static double? _mp3Seconds(Uint8List b) {
    var p = 0;
    if (_starts(b, _a('ID3')) && b.length > 10) {
      p = 10 + ((b[6] & 0x7F) << 21 | (b[7] & 0x7F) << 14 | (b[8] & 0x7F) << 7 | (b[9] & 0x7F));
      if (b[5] & 0x10 != 0) p += 10; // footer
    }
    // Первый кадр: синхронизация 11 бит.
    final limit = math.min(b.length - 4, p + 65536);
    while (p < limit && !(b[p] == 0xFF && b[p + 1] & 0xE0 == 0xE0 && (b[p + 1] >> 1) & 3 == 1)) {
      p++;
    }
    if (p >= limit) return null;
    final version = (b[p + 1] >> 3) & 3; // 3 — MPEG1, 2 — MPEG2, 0 — MPEG2.5
    final bitrateIndex = b[p + 2] >> 4, rateIndex = (b[p + 2] >> 2) & 3;
    if (version == 1 || bitrateIndex == 0 || bitrateIndex == 15 || rateIndex == 3) return null;
    final mpeg1 = version == 3;
    final rate = const [44100, 48000, 32000][rateIndex] ~/ (mpeg1 ? 1 : (version == 2 ? 2 : 4));
    final bitrate = (mpeg1
            ? const [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
            : const [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160])[bitrateIndex] *
        1000;
    final samplesPerFrame = mpeg1 ? 1152 : 576;
    final mono = b[p + 3] >> 6 == 3;
    final bd = ByteData.sublistView(b);
    // Xing/Info — сразу после side info.
    final xing = p + 4 + (mpeg1 ? (mono ? 17 : 32) : (mono ? 9 : 17));
    if (xing + 12 <= b.length && (_starts(b, _a('Xing'), xing) || _starts(b, _a('Info'), xing))) {
      if (bd.getUint32(xing + 4) & 1 != 0) return bd.getUint32(xing + 8) * samplesPerFrame / rate;
    }
    final vbri = p + 36;
    if (vbri + 18 <= b.length && _starts(b, _a('VBRI'), vbri)) {
      return bd.getUint32(vbri + 14) * samplesPerFrame / rate;
    }
    return (b.length - p) * 8 / bitrate;
  }

  static bool _starts(Uint8List b, List<int> magic, [int at = 0]) {
    if (b.length < at + magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (b[at + i] != magic[i]) return false;
    }
    return true;
  }

  static List<int> _a(String s) => ascii.encode(s);

  /// Формат по содержимому.
  static MusicFormat detectFormat(Uint8List b) {
    if (_starts(b, _a('OggS'))) {
      final head = b.length < 200 ? b : Uint8List.sublistView(b, 0, 200);
      return _indexOf(head, _a('OpusHead')) >= 0 ? MusicFormat.opus : MusicFormat.ogg;
    }
    if (_starts(b, _a('fLaC'))) return MusicFormat.flac;
    if (_starts(b, _a('RIFF')) && _starts(b, _a('WAVE'), 8)) return MusicFormat.wav;
    if (_starts(b, _a('MThd'))) return MusicFormat.midi;
    if (_starts(b, [0x4D, 0x55, 0x53, 0x1A])) return MusicFormat.mus;
    if (_starts(b, _a('ID3')) || (b.length > 2 && b[0] == 0xFF && (b[1] & 0xE0) == 0xE0)) return MusicFormat.mp3;
    if (_starts(b, _a('Extended Module'))) return MusicFormat.xm;
    if (_starts(b, _a('IMPM'))) return MusicFormat.it;
    if (_starts(b, _a('SCRM'), 44)) return MusicFormat.s3m;
    if (b.length > 1084) {
      final sig = latin1.decode(b.sublist(1080, 1084));
      if (RegExp(r'^(M\.K\.|M!K!|M&K!|FLT[48]|[1-9]CHN|[1-3][0-9]CH|CD81|OKTA)$').hasMatch(sig)) return MusicFormat.mod;
    }
    const gme = {
      'SNES-SPC700': MusicFormat.spc, 'Vgm ': MusicFormat.vgm, 'NESM': MusicFormat.nsf, 'NSFE': MusicFormat.nsf, //
      'GBS': MusicFormat.gbs, 'GYMX': MusicFormat.gym, 'HESM': MusicFormat.hes, 'KSCC': MusicFormat.kss,
      'KSSX': MusicFormat.kss, 'SAP': MusicFormat.sap, 'ZXAY': MusicFormat.ay,
    };
    for (final e in gme.entries) {
      if (_starts(b, _a(e.key))) return e.value;
    }
    if (_starts(b, [0x1F, 0x8B])) return MusicFormat.vgz; // сжатый VGM
    return MusicFormat.unknown;
  }

  static int _indexOf(Uint8List hay, List<int> needle) {
    outer:
    for (var i = 0; i + needle.length <= hay.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (hay[i + j] != needle[j]) continue outer;
      }
      return i;
    }
    return -1;
  }

  // --- Точка петли ---

  /// LOOPMS (мс), LOOPPOINT (сэмплы) или COMMENT "LOOPPOINT=..." из тегов.
  static Duration? loopPoint(Uint8List b, MusicFormat f) {
    try {
      final (tags, rate) = switch (f) {
        MusicFormat.ogg || MusicFormat.opus => _oggTags(b),
        MusicFormat.flac => _flacTags(b),
        MusicFormat.mp3 => (_id3Tags(b), 44100),
        _ => (const <String, String>{}, 44100),
      };
      return loopFromTags(tags, rate);
    } catch (_) {
      return null;
    }
  }

  static Duration? loopFromTags(Map<String, String> tags, int sampleRate) {
    final ms = int.tryParse(tags['LOOPMS']?.trim() ?? '');
    if (ms != null && ms >= 0) return Duration(milliseconds: ms);
    var samples = int.tryParse(tags['LOOPPOINT']?.trim() ?? '');
    if (samples == null) {
      final m = RegExp(r'LOOPPOINT\s*=\s*(\d+)', caseSensitive: false).firstMatch(tags['COMMENT'] ?? '');
      samples = m == null ? null : int.parse(m.group(1)!);
    }
    if (samples == null || samples < 0 || sampleRate <= 0) return null;
    return Duration(microseconds: samples * 1000000 ~/ sampleRate);
  }

  /// Комментарии Vorbis/Opus из первых пакетов Ogg и частота.
  static (Map<String, String>, int) _oggTags(Uint8List b) {
    final packets = <BytesBuilder>[BytesBuilder()];
    var p = 0;
    while (p + 27 <= b.length && packets.length <= 3) {
      if (!_starts(b, _a('OggS'), p)) break;
      final segs = b[p + 26];
      var data = p + 27 + segs;
      for (var i = 0; i < segs && packets.length <= 3; i++) {
        final len = b[p + 27 + i];
        if (data + len > b.length) break;
        packets.last.add(Uint8List.sublistView(b, data, data + len));
        data += len;
        if (len < 255) packets.add(BytesBuilder()); // конец пакета
      }
      p = data;
    }
    final list = [for (final x in packets) x.toBytes()];
    var rate = 44100;
    if (list.isNotEmpty && _starts(list[0], [0x01, ..._a('vorbis')]) && list[0].length >= 16) {
      rate = ByteData.sublistView(list[0]).getUint32(12, Endian.little);
    } else if (list.isNotEmpty && _starts(list[0], _a('OpusHead'))) {
      rate = 48000; // Opus всегда декодируется в 48 кГц
    }
    for (final pkt in list.skip(1)) {
      if (_starts(pkt, [0x03, ..._a('vorbis')])) return (_vorbisComments(pkt, 7), rate);
      if (_starts(pkt, _a('OpusTags'))) return (_vorbisComments(pkt, 8), rate);
    }
    return (const {}, rate);
  }

  static Map<String, String> _vorbisComments(Uint8List b, int at) {
    final bd = ByteData.sublistView(b);
    var p = at;
    final vendor = bd.getUint32(p, Endian.little);
    p += 4 + vendor;
    final n = bd.getUint32(p, Endian.little);
    p += 4;
    final tags = <String, String>{};
    for (var i = 0; i < n && p + 4 <= b.length; i++) {
      final len = bd.getUint32(p, Endian.little);
      p += 4;
      if (p + len > b.length) break;
      final s = utf8.decode(b.sublist(p, p + len), allowMalformed: true);
      p += len;
      final eq = s.indexOf('=');
      if (eq > 0) tags.putIfAbsent(s.substring(0, eq).toUpperCase(), () => s.substring(eq + 1));
    }
    return tags;
  }

  static (Map<String, String>, int) _flacTags(Uint8List b) {
    var p = 4;
    var rate = 44100;
    var tags = <String, String>{};
    while (p + 4 <= b.length) {
      final last = b[p] & 0x80 != 0;
      final type = b[p] & 0x7F;
      final len = (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3];
      final body = p + 4;
      if (body + len > b.length) break;
      if (type == 0 && len >= 13) rate = (b[body + 10] << 12) | (b[body + 11] << 4) | (b[body + 12] >> 4);
      if (type == 4) tags = _vorbisComments(Uint8List.sublistView(b, body, body + len), 0);
      p = body + len;
      if (last) break;
    }
    return (tags, rate);
  }

  /// ID3v2: кадры TXXX ("LOOPMS"/"LOOPPOINT") и COMM.
  static Map<String, String> _id3Tags(Uint8List b) {
    final tags = <String, String>{};
    if (!_starts(b, _a('ID3')) || b.length < 10) return tags;
    final major = b[3];
    int syncsafe(int at) => (b[at] << 21) | (b[at + 1] << 14) | (b[at + 2] << 7) | b[at + 3];
    final size = syncsafe(6);
    var p = 10;
    final end = (10 + size).clamp(0, b.length);
    while (p + 10 <= end) {
      final id = latin1.decode(b.sublist(p, p + 4));
      if (id.codeUnitAt(0) == 0) break;
      final len = major >= 4 ? syncsafe(p + 4) : ByteData.sublistView(b).getUint32(p + 4);
      final body = p + 10;
      if (body + len > end || len <= 0) break;
      if (id == 'TXXX' || id == 'COMM') {
        final enc = b[body];
        final text = enc == 1 || enc == 2
            ? String.fromCharCodes(Uint16List.sublistView(Uint8List.fromList(b.sublist(body + 1, body + len - ((len - 1) % 2)))))
            : latin1.decode(b.sublist(body + 1, body + len), allowInvalid: true);
        if (id == 'TXXX') {
          final parts = text.split('\u0000').where((x) => x.isNotEmpty).toList();
          if (parts.length >= 2) tags[parts[0].replaceAll('﻿', '').toUpperCase()] = parts[1].replaceAll('﻿', '');
        } else {
          tags['COMMENT'] = text;
        }
      }
      p = body + len;
    }
    return tags;
  }
}
