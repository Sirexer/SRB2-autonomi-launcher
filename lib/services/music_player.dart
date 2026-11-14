import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_activity.dart';
import 'app_log.dart';
import 'map_preview.dart';
import 'media_keys.dart';
import 'midi_synth.dart';
import 'music.dart';
import 'music_details.dart';
import 'native_music.dart';

/// Что делать, когда трек доиграл: список до конца (потом тишина), весь
/// список по кругу, повторить трек с начала или повторить его с точки петли
/// (LOOPMS, как в игре). Порядок — как переключает кнопка.
enum PlayerRepeat { once, list, track, loop }

/// Состояние плеера: список треков, текущий трек, воспроизведение.
/// Живёт в главном окне, поэтому музыка не прерывается при смене вкладок.
class MusicPlayer extends ChangeNotifier {
  static const _kLoop = 'player_loop'; // старая настройка (до режимов повтора)
  static const _kRepeat = 'player_repeat';
  static const _kShuffle = 'player_shuffle';
  static const _kVolume = 'player_volume';
  static const _kSf2 = 'player_sf2';
  static const _kFiles = 'player_files';
  static const _kSf2List = 'player_sf2_list';
  static const _kHidden = 'player_hidden_formats';
  static const _kSort = 'player_sort';
  static const _kFavorites = 'player_favorites';
  static const _kFavoritesOnly = 'player_favorites_only';
  static const _kHideDuplicates = 'player_hide_duplicates';
  static const _kExportDir = 'player_export_dir';

  /// Версии кэшей: поиска (что в файлах) и отрисованных треков. Меняются,
  /// когда меняется то, что в них лежит.
  static const _scanCacheVersion = 5; // 2: нечитаемый MUSICDEF; 3: карты «папкой»; 4: EncoreMusic; 5: отпечатки треков
  static const _renderCacheVersion = 1;

  /// Сколько места могут занять отрисованные треки на диске.
  static const _renderCacheBytes = 1 << 30;

  List<MusicTrack> tracks = const [];
  bool scanning = false;

  /// Идёт второй проход: длительность и теги треков.
  bool readingDetails = false;

  /// Файлы, открытые вручную (кнопка «Открыть», перетаскивание).
  final List<String> manualFiles = [];

  MusicTrack? current;
  MusicFormat? currentFormat;
  Duration? loopStart;
  bool loading = false;
  String? error;

  /// Дорожка многодорожечного файла (NSF, GBS...), с нуля.
  int subtrack = 0;

  PlayerRepeat repeat = PlayerRepeat.loop;
  bool shuffle = false;
  /// Громкость 0..1. Меняется — обновляется только [volumeListenable]
  /// (ползунки и кнопка звука), а не вся вкладка.
  double get volume => volumeListenable.value;
  final ValueNotifier<double> volumeListenable = ValueNotifier(0.8);

  /// Повтор трека (с начала или с точки петли) — петля в аудио-движке.
  bool get loop => repeat == PlayerRepeat.track || repeat == PlayerRepeat.loop;

  /// Громкость до выключения звука (кнопка динамика).
  double _volumeBeforeMute = 0.8;

  /// SoundFont для MIDI; null — встроенный простой синтезатор.
  String? sf2Path;

  /// Добавленные SoundFont — для быстрого переключения.
  final List<String> soundFonts = [];

  /// Скрытые форматы и порядок списка.
  final Set<MusicFormat> hiddenFormats = {};
  MusicSort sort = MusicSort.file;

  /// Свёрнутые игры и развёрнутые категории/файлы списка (категории и файлы
  /// по умолчанию свёрнуты). Только до выхода из лаунчера, не в настройках.
  final Set<String> collapsedGames = {};
  final Set<String> expandedGroups = {};

  /// Избранное (ключи треков) и фильтр «только избранное».
  final Set<String> favorites = {};
  bool favoritesOnly = false;

  /// Скрывать дубликаты: одинаковая музыка в нескольких файлах (версии одного
  /// аддона) показывается один раз.
  bool hideDuplicates = true;

  /// Доля готового рендера (0..1); null — рендера нет.
  double? renderProgress;

  /// Порядок для «следующий/предыдущий» — видимый (отфильтрованный) список.
  List<MusicTrack> playlist = const [];

  AudioSource? _source;
  SoundHandle? _handle;
  Duration length = Duration.zero;
  /// Позиция воспроизведения — отдельным уведомлением: её частые изменения
  /// перерисовывают только ползунок и время, а не всю вкладку.
  final ValueNotifier<Duration> positionListenable = ValueNotifier(Duration.zero);
  Duration get position => positionListenable.value;
  set position(Duration v) => positionListenable.value = v;
  bool paused = false;
  Timer? _timer;
  int _token = 0;
  int _scanToken = 0;

  /// Аудио-движок засыпает (освобождает звуковое устройство и свой поток),
  /// если столько времени ничего не играет; «Играть» будит его.
  static const _sleepAfter = Duration(seconds: 30);
  Timer? _sleepTimer;

  MusicPlayer() {
    AppActivity.visible.addListener(_onVisibility);
  }


  /// Папки игр (где лежат их файлы) — там же ищем libopenmpt и libgme.
  List<String> libraryDirs = const [];

  /// Файлы игр с музыкой, которые не нашлись (игра → имена) — для подсказки.
  Map<String, List<String>> missingGameFiles = const {};

  /// Название аддона файла [file] ('' — не аддон из репозитория).
  String labelOf(String file) {
    for (final s in _sources) {
      if (s.path == file) return s.label;
    }
    return '';
  }

  // --- Экспорт ---

  /// Идёт экспорт: сколько готово из скольких, что сейчас, доля текущего.
  bool exporting = false;
  int exportDone = 0;
  int exportTotal = 0;
  String exportName = '';
  double? exportProgress;
  bool _exportCancel = false;

  /// Папка последнего экспорта (окно выбора открывается в ней).
  String? lastExportDir;

  void cancelExport() => _exportCancel = true;

  /// Имя файла экспорта: «GFZ1 - Greenflower 1» (без запрещённых символов).
  static String exportFileName(MusicTrack t) {
    final title = t.displayTitle;
    final name = title.isEmpty || title == t.lump ? t.lump : '${t.lump} - $title';
    final clean = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_').trim();
    return clean.isEmpty ? 'track' : clean;
  }

  /// Расширение оригинала по формату.
  static String exportExtension(MusicFormat f, Uint8List bytes) => switch (f) {
        MusicFormat.midi => 'mid',
        MusicFormat.unknown => 'lmp',
        MusicFormat.nsf when bytes.length > 4 && String.fromCharCodes(bytes.sublist(0, 4)) == 'NSFE' => 'nsfe',
        _ => f.name,
      };

  /// Экспортирует [list] прямо в папку [dir] — оригиналами, как они лежат
  /// в аддоне (OGG, MP3, MIDI, модули...). Возвращает (сохранено, ошибки).
  Future<(int, List<String>)> export(List<MusicTrack> list, String dir) async {
    if (exporting) return (0, const <String>[]);
    exporting = true;
    _exportCancel = false;
    exportDone = 0;
    exportTotal = list.length;
    exportProgress = null;
    lastExportDir = dir;
    _save();
    notifyListeners();
    final used = <String>{};
    final errors = <String>[];
    var saved = 0;
    try {
      for (final t in list) {
        if (_exportCancel) break;
        exportName = t.displayTitle;
        notifyListeners();
        try {
          final data = await MusicScanner.loadInBackground(t);
          final ext = exportExtension(data.format, data.bytes);
          // Одинаковые имена — с номером.
          var name = exportFileName(t);
          for (var n = 2; !used.add(p.join(dir, '$name.$ext').toLowerCase()); n++) {
            name = '${exportFileName(t)} ($n)';
          }
          await File(p.join(dir, '$name.$ext')).writeAsBytes(data.bytes, flush: true);
          saved++;
        } catch (e) {
          errors.add('${t.displayTitle}: $e');
        }
        exportDone++;
        exportProgress = exportDone / exportTotal;
        notifyListeners();
      }
    } finally {
      exporting = false;
      exportProgress = null;
      exportName = '';
      notifyListeners();
    }
    return (saved, errors);
  }

  /// Найденные файлы игры [game] и сколько в каждом треков.
  List<(String, int)> gameFilesOf(String game) => [
        for (final s in _sources)
          if (s.game == game && s.category == MusicCategory.game)
            (s.path, tracks.where((t) => t.file == s.path).length),
      ];

  /// Форматы треков файла [file]: формат → сколько.
  Map<MusicFormat, int> formatsOf(String file) {
    final out = <MusicFormat, int>{};
    for (final t in tracks) {
      if (t.file == file) out[t.format] = (out[t.format] ?? 0) + 1;
    }
    return out;
  }

  // Что найдено: источники, сведения о файлах (путь → сведения), отметки
  // файлов (путь|размер|время) и кэш сведений по отметкам (на диске).
  List<MusicSource> _sources = const [];
  Map<String, MusicFileInfo> _infos = const {};
  Map<String, String> _stamps = const {};
  final Map<String, MusicFileInfo> _scanCache = {};
  bool _scanCacheLoaded = false;
  Future<void>? _saving;

  /// Треки игры по (игра|ИМЯ) и треки аддонов, которые их заменяют.
  Map<String, MusicTrack> _originals = const {};
  Map<String, List<MusicTrack>> _replacements = const {};
  final Map<String, List<LevelRef>> _levels = {};
  final Map<String, Future<Uint8List?>> _pictures = {};

  // Перемешивание: история (для «предыдущего») и ещё не сыгранные.
  final List<String> _history = [];
  List<String>? _bag;

  bool get playing => _handle != null && !paused;

  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final savedRepeat = prefs.getString(_kRepeat);
    repeat = savedRepeat == null
        ? ((prefs.getBool(_kLoop) ?? true) ? PlayerRepeat.loop : PlayerRepeat.list)
        : switch (savedRepeat) {
            'one' => PlayerRepeat.loop, // старые режимы
            'all' || 'next' => PlayerRepeat.list,
            'off' => PlayerRepeat.once,
            _ => PlayerRepeat.values.firstWhere((r) => r.name == savedRepeat, orElse: () => PlayerRepeat.loop),
          };
    shuffle = prefs.getBool(_kShuffle) ?? false;
    volumeListenable.value = (prefs.getDouble(_kVolume) ?? 0.8).clamp(0.0, 1.0);
    sf2Path = prefs.getString(_kSf2);
    manualFiles
      ..clear()
      ..addAll(prefs.getStringList(_kFiles) ?? const []);
    soundFonts
      ..clear()
      ..addAll(prefs.getStringList(_kSf2List) ?? const []);
    if (sf2Path != null && !soundFonts.contains(sf2Path)) soundFonts.add(sf2Path!);
    hiddenFormats
      ..clear()
      ..addAll([
        for (final n in prefs.getStringList(_kHidden) ?? const <String>[])
          for (final f in MusicFormat.values)
            if (f.name == n) f,
      ]);
    sort = MusicSort.values.firstWhere((s) => s.name == prefs.getString(_kSort), orElse: () => MusicSort.file);
    // Раньше сворачивание сохранялось — теперь только в памяти.
    prefs.remove('player_collapsed');
    prefs.remove('player_expanded_sections');
    favorites
      ..clear()
      ..addAll(prefs.getStringList(_kFavorites) ?? const []);
    favoritesOnly = prefs.getBool(_kFavoritesOnly) ?? false;
    hideDuplicates = prefs.getBool(_kHideDuplicates) ?? true;
    // Эквалайзера больше нет — его настройки не нужны.
    prefs.remove('player_eq_on');
    prefs.remove('player_eq_bands');
    lastExportDir = prefs.getString(_kExportDir);
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kRepeat, repeat.name);
    await prefs.setBool(_kShuffle, shuffle);
    await prefs.setDouble(_kVolume, volume);
    if (sf2Path == null) {
      await prefs.remove(_kSf2);
    } else {
      await prefs.setString(_kSf2, sf2Path!);
    }
    await prefs.setStringList(_kFiles, manualFiles);
    await prefs.setStringList(_kSf2List, soundFonts);
    await prefs.setStringList(_kHidden, [for (final f in hiddenFormats) f.name]);
    await prefs.setString(_kSort, sort.name);
    await prefs.setStringList(_kFavorites, favorites.toList());
    await prefs.setBool(_kFavoritesOnly, favoritesOnly);
    await prefs.setBool(_kHideDuplicates, hideDuplicates);
    if (lastExportDir != null) await prefs.setString(_kExportDir, lastExportDir!);
  }

  // --- Поиск музыки ---

  /// Ищет треки в [sources] (файлы игр и аддоны всех игр) и в открытых
  /// вручную файлах. Уже разобранные файлы (тот же размер и время) берутся
  /// из кэша — повторный поиск почти мгновенный. Потом вторым проходом
  /// читаются длительность и теги треков.
  Future<void> scan(List<MusicSource> sources) async {
    final token = ++_scanToken;
    scanning = true;
    notifyListeners();
    libraryDirs = {
      for (final s in sources)
        if (s.category == MusicCategory.game) ...[p.dirname(s.path), p.dirname(p.dirname(s.path))],
    }.toList();
    // Файл — в первом разделе, где встретился.
    final byPath = <String, MusicSource>{};
    for (final s in [
      ...sources,
      for (final f in manualFiles) MusicSource(f, '', MusicCategory.opened),
    ]) {
      byPath.putIfAbsent(s.path, () => s);
    }
    final list = byPath.values.toList();
    await _loadScanCache();
    final stamps = <String, String>{for (final s in list) s.path: await _stamp(s.path)};
    final missing = [
      for (final s in list)
        if (stamps[s.path]!.isNotEmpty && !_scanCache.containsKey(stamps[s.path])) s.path,
    ];
    if (missing.isNotEmpty) {
      try {
        await AppActivity.whenVisible();
        final found = await MusicScanner.scanFilesInBackground(missing);
        found.forEach((path, info) => _scanCache[stamps[path]!] = info);
      } catch (_) {}
    }
    if (token != _scanToken) return;
    _sources = list;
    _stamps = stamps;
    _infos = {
      for (final s in list)
        if (_scanCache[stamps[s.path]] case final info?) s.path: info,
    };
    _compose();
    scanning = false;
    notifyListeners();
    _saveScanCache();
    _readDetails(token);
  }

  /// Отметка файла: путь, размер и время изменения; '' — файла нет.
  static Future<String> _stamp(String path) async {
    try {
      final st = await File(path).stat();
      if (st.type == FileSystemEntityType.notFound) return '';
      return '$path|${st.size}|${st.modified.millisecondsSinceEpoch}';
    } catch (_) {
      return '';
    }
  }

  void _compose() {
    tracks = MusicLibrary.compose(_sources, _infos);
    _levels.clear();
    final originals = <String, MusicTrack>{};
    for (final t in tracks) {
      if (t.category == MusicCategory.game) originals['${t.game}|${t.lump.toUpperCase()}'] = t;
    }
    final replacements = <String, List<MusicTrack>>{};
    for (final t in tracks) {
      if (t.category == MusicCategory.game || t.game.isEmpty) continue;
      final k = '${t.game}|${t.lump.toUpperCase()}';
      if (originals.containsKey(k)) (replacements[k] ??= []).add(t);
    }
    _originals = originals;
    _replacements = replacements;
  }

  /// Трек игры, который заменяет трек аддона [t] (тот же lump); null — нет.
  MusicTrack? originalOf(MusicTrack t) =>
      t.category == MusicCategory.game || t.game.isEmpty ? null : _originals['${t.game}|${t.lump.toUpperCase()}'];

  /// Треки аддонов, заменяющие трек игры [t].
  List<MusicTrack> replacementsOf(MusicTrack t) =>
      t.category != MusicCategory.game ? const [] : _replacements['${t.game}|${t.lump.toUpperCase()}'] ?? const [];

  /// Уровни, на которых играет [t] (по заголовкам уровней из SOC).
  List<LevelRef> levelsOf(MusicTrack t) => _levels[t.key] ??= MusicLibrary.levelsOf(t, _sources, _infos);

  /// Картинка уровня [map] игры [game]: из файлов игры или [file] (аддон).
  Future<Uint8List?> levelPicture(String game, String map, {String? file}) =>
      _pictures.putIfAbsent('$game|$map|${file ?? ''}', () async {
        final gameFiles = [
          for (final s in _sources)
            if (s.game == game && s.category == MusicCategory.game) s.path,
        ];
        try {
          return await MapScanner.findPictureInBackground(
            files: [...gameFiles, if (file != null && !gameFiles.contains(file)) file],
            map: map,
            title: '',
            paletteFiles: gameFiles,
          );
        } catch (_) {
          return null;
        }
      });

  /// Второй проход: длительность и теги — пачками, список обновляется по ходу.
  Future<void> _readDetails(int token) async {
    final openmpt = NativeMusic.find(NativeLib.openmpt, libraryDirs);
    final gme = NativeMusic.find(NativeLib.gme, libraryDirs);
    final pending = <(String, String, MusicFormat)>[];
    for (final s in _sources) {
      final info = _infos[s.path];
      if (info == null) continue;
      for (final (entry, _, format) in info.tracks) {
        if (info.details.containsKey(entry)) continue;
        if ((format.isTracker && openmpt == null) || (format.isGme && gme == null)) continue;
        pending.add((s.path, entry, format));
      }
    }
    if (pending.isEmpty) return;
    readingDetails = true;
    notifyListeners();
    try {
      for (var i = 0; i < pending.length; i += 40) {
        final batch = pending.sublist(i, math.min(i + 40, pending.length));
        await AppActivity.whenVisible(); // окно свёрнуто — дочитаем потом
        if (token != _scanToken) return;
        final found = await MusicDetails.readInBackground(batch, openmpt: openmpt, gme: gme);
        if (token != _scanToken) return;
        found.forEach((key, d) => _infos[key.$1]?.details[key.$2] = d);
        _compose();
        notifyListeners();
      }
    } catch (_) {
      // остальное прочитаем при следующем поиске
    } finally {
      if (token == _scanToken) {
        readingDetails = false;
        notifyListeners();
        _saveScanCache();
      }
    }
  }

  Future<Directory> _dataDir(String name) async {
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, name));
    await dir.create(recursive: true);
    return dir;
  }

  Future<File> _scanCacheFile() async => File(p.join((await _dataDir('music')).path, 'scan_cache.json'));

  Future<void> _loadScanCache() async {
    if (_scanCacheLoaded) return;
    _scanCacheLoaded = true;
    try {
      final f = await _scanCacheFile();
      if (!await f.exists()) return;
      final text = await f.readAsString();
      final j = await Isolate.run(() => jsonDecode(text)) as Map<String, Object?>;
      if (j['v'] != _scanCacheVersion) return;
      for (final e in (j['files'] as Map).entries) {
        _scanCache[e.key as String] = MusicFileInfo.fromJson((e.value as Map).cast<String, Object?>());
      }
    } catch (_) {
      // повреждённый кэш — найдём заново
    }
  }

  /// Сохраняет кэш поиска (только файлы текущего списка).
  void _saveScanCache() {
    final keep = {for (final s in _stamps.values) if (s.isNotEmpty) s};
    _scanCache.removeWhere((k, _) => !keep.contains(k));
    final json = jsonEncode({
      'v': _scanCacheVersion,
      'files': {for (final e in _scanCache.entries) e.key: e.value.toJson()},
    });
    _saving = (_saving ?? Future<void>.value()).then((_) async {
      try {
        await (await _scanCacheFile()).writeAsString(json);
      } catch (_) {}
    });
  }

  void addFiles(Iterable<String> paths) {
    for (final f in paths) {
      if (!manualFiles.contains(f)) manualFiles.add(f);
    }
    _save();
  }

  void removeManualFile(String path) {
    manualFiles.remove(path);
    _sources = [for (final s in _sources) if (!(s.path == path && s.category == MusicCategory.opened)) s];
    _infos = {for (final s in _sources) if (_infos[s.path] case final info?) s.path: info};
    _compose();
    _save();
    notifyListeners();
  }

  // --- Воспроизведение ---

  Future<bool> _ensureEngine() async {
    final soloud = SoLoud.instance;
    if (soloud.isInitialized) return true;
    try {
      AppLog.write('audio engine starts');
      await soloud.init();
      return true;
    } catch (e) {
      error = 'Audio engine failed to start: $e';
      notifyListeners();
      return false;
    }
  }

  /// Играет [t] с начала (или с [from]); [subtrack] — дорожка
  /// многодорожечного файла.
  Future<void> play(MusicTrack t, {Duration from = Duration.zero, int subtrack = 0}) async {
    final token = ++_token;
    _cancelSleep();
    await _stopCurrent();
    if (current?.key != t.key || _history.isEmpty) {
      _history.add(t.key);
      if (_history.length > 200) _history.removeAt(0);
    }
    current = t;
    this.subtrack = subtrack;
    currentFormat = t.format;
    loopStart = null;
    error = null;
    loading = true;
    renderProgress = null;
    position = Duration.zero;
    length = Duration.zero;
    paused = false;
    notifyListeners();

    try {
      if (!await _ensureEngine()) return;
      final data = await MusicScanner.loadInBackground(t);
      if (token != _token) return;
      currentFormat = data.format;
      loopStart = data.loopStart;
      if (!data.format.playable) {
        throw UnsupportedError('This format (${data.format.label}) cannot be played in the launcher');
      }
      // Звук не распаковывается в память целиком (LoadMode.disk): движок
      // декодирует его по ходу — в разы меньше памяти, чем PCM всего трека.
      final soloud = SoLoud.instance;
      AudioSource source;
      if (data.format.isRendered) {
        final rendered = await _rendered(t, data, token);
        if (rendered == null || token != _token) return;
        final (path, bytes, loopAt) = rendered;
        // Петля из файла (VGM); у MIDI и модулей — с начала.
        if (loopAt != null) loopStart = loopAt;
        source = path != null
            ? await soloud.loadFile(path, mode: LoadMode.disk)
            : await soloud.loadMem('${t.key}#$subtrack.wav', bytes!, mode: LoadMode.disk);
      } else {
        try {
          source = await soloud.loadMem('${t.key}.${data.format.extension}', data.bytes, mode: LoadMode.disk);
        } catch (e) {
          // Встроенный декодер (stb_vorbis) не читает часть OGG — например,
          // старые с floor 0; их раскодирует libvorbisfile (в WAV, в кэш).
          if (data.format != MusicFormat.ogg) rethrow;
          final decoded = await _rendered(t, data, token, vorbis: true);
          if (decoded == null || token != _token) return;
          final (path, bytes, _) = decoded;
          source = path != null
              ? await soloud.loadFile(path, mode: LoadMode.disk)
              : await soloud.loadMem('${t.key}.wav', bytes!, mode: LoadMode.disk);
        }
      }
      if (token != _token) {
        await soloud.disposeSource(source);
        return;
      }
      _source = source;
      length = soloud.getLength(source);
      _handle = await soloud.play(
        source,
        volume: volume,
        looping: loop,
        loopingStartAt: _loopPointFor(data.format),
      );
      if (from > Duration.zero && from < length) {
        soloud.seek(_handle!, from);
        position = from;
      }
      _startTimer();
      MediaKeys.enable(_onMediaKey); // медиаклавиши — плееру, пока в нём есть музыка
    } on RenderCancelled {
      // Выбран другой трек — его play() уже всё показывает.
    } catch (e) {
      if (token == _token) error = e is UnsupportedError ? e.message ?? '$e' : '$e';
    } finally {
      if (token == _token) {
        loading = false;
        renderProgress = null;
        if (_handle == null) _scheduleSleep(); // не заиграло — движку можно спать
        notifyListeners();
      }
    }
  }

  /// Трек, который надо сначала отрисовать (MIDI/MUS, модули, музыка
  /// приставок): файл WAV в кэше на диске (движок читает его потоком, в
  /// памяти он не лежит) или, если записать не вышло, — байты. Третье — точка
  /// петли из файла.
  Future<(String?, Uint8List?, Duration?)?> _rendered(MusicTrack t, MusicData data, int token, {bool vorbis = false}) {
    void progress(double x) {
      if (token != _token) return;
      renderProgress = x;
      notifyListeners();
    }

    return _renderWav(t, data, subtrack,
        vorbis: vorbis,
        onStart: () {
          renderProgress = 0;
          notifyListeners();
        },
        onProgress: progress,
        cancelled: () => token != _token);
  }

  /// WAV трека из кэша на диске или рендером (для проигрывания и экспорта).
  Future<(String?, Uint8List?, Duration?)?> _renderWav(
    MusicTrack t,
    MusicData data,
    int subtrack, {
    bool vorbis = false,
    void Function()? onStart,
    void Function(double progress)? onProgress,
    bool Function()? cancelled,
  }) async {
    final format = data.format;
    final font = format.isSynth ? (sf2Path == null ? 'builtin' : await _stamp(sf2Path!)) : '';
    final key = md5
        .convert(utf8.encode(
            '$_renderCacheVersion|${_stamps[t.file] ?? t.file}|${t.entry}|${format.name}|$font|$subtrack${vorbis ? '|vorbisfile' : ''}'))
        .toString();
    final dir = await _dataDir('music_render');
    final wavFile = File(p.join(dir.path, '$key.wav')), loopFile = File(p.join(dir.path, '$key.loop'));
    try {
      if (await wavFile.exists()) {
        final loopMs = await loopFile.exists() ? int.tryParse(await loopFile.readAsString()) : null;
        wavFile.setLastModified(DateTime.now()).ignore(); // недавно нужный — удалится последним
        return (wavFile.path, null, loopMs == null ? null : Duration(milliseconds: loopMs));
      }
    } catch (_) {}
    if (cancelled?.call() ?? false) return null;
    void progress(double x) => onProgress?.call(x);
    onStart?.call();
    final RenderedMusic rendered;
    if (vorbis) {
      final lib = NativeMusic.findVorbisFile(libraryDirs);
      if (lib == null) {
        throw UnsupportedError('This OGG file needs libvorbisfile, and it was not found. It comes with the launcher '
            'for Windows (next to libopenmpt); on Linux install the libvorbisfile3 package.');
      }
      rendered = (await NativeMusic.decodeVorbisInBackground(data.bytes, lib, onProgress: progress, cancelled: cancelled), null);
    } else if (format.isSynth) {
      final wav = await MidiRenderer.renderToWavInBackground(data.bytes, sf2Path,
          onProgress: progress, cancelled: cancelled);
      rendered = (wav, null);
    } else {
      final lib = NativeMusic.libraryFor(format);
      final path = NativeMusic.find(lib, libraryDirs);
      if (path == null) {
        throw UnsupportedError(lib == NativeLib.openmpt
            ? 'Tracker modules are played by libopenmpt, and it was not found. It comes with SRB2 for Windows: '
                'put libopenmpt.dll next to the game or the launcher. On Linux install the libopenmpt0 package.'
            : 'This format is played by libgme (Game Music Emu), and it was not found. It comes with SRB2 for '
                'Windows: put libgme.dll next to the game or the launcher. On Linux install the libgme0 package.');
      }
      rendered = await NativeMusic.renderInBackground(data.bytes, format, path,
          subtrack: subtrack, onProgress: progress, cancelled: cancelled);
    }
    try {
      await wavFile.writeAsBytes(rendered.$1, flush: true);
      if (rendered.$2 != null) await loopFile.writeAsString('${rendered.$2!.inMilliseconds}');
      _pruneRendered(dir);
      return (wavFile.path, null, rendered.$2);
    } catch (_) {
      return (null, rendered.$1, rendered.$2);
    }
  }

  /// Убирает самые старые отрисованные треки, если кэш больше [_renderCacheBytes].
  Future<void> _pruneRendered(Directory dir) async {
    try {
      final files = [
        for (final e in await dir.list().toList())
          if (e is File && e.path.endsWith('.wav')) (e, await e.stat()),
      ]..sort((a, b) => b.$2.modified.compareTo(a.$2.modified));
      var total = 0;
      for (final (f, st) in files) {
        total += st.size;
        if (total <= _renderCacheBytes) continue;
        await f.delete();
        final l = File('${f.path.substring(0, f.path.length - 4)}.loop');
        if (await l.exists()) await l.delete();
      }
    } catch (_) {}
  }

  /// Откуда повторять: «повторить трек» и MIDI — с начала (в игре MIDI
  /// вообще не зацикливается), «с циклом» — с точки петли.
  Duration _loopPointFor(MusicFormat f) {
    final lp = f.isSynth || repeat == PlayerRepeat.track ? null : loopStart;
    return lp == null || lp >= length ? Duration.zero : lp;
  }

  /// Таймер позиции — только пока звучит; при свёрнутом окне — реже и без
  /// перерисовки (нужен лишь, чтобы заметить конец трека).
  void _startTimer() {
    _timer?.cancel();
    _timer = null;
    if (_handle == null || paused) return;
    final period = Duration(milliseconds: AppActivity.visible.value ? 250 : 1000);
    _timer = Timer.periodic(period, (_) => _tick());
  }

  void _onVisibility() {
    if (_timer != null) _startTimer();
  }

  void _tick() {
    final h = _handle;
    if (h == null) return;
    final soloud = SoLoud.instance;
    if (!soloud.getIsValidVoiceHandle(h)) {
      // Трек доиграл (без петли) — следующий или конец списка.
      _handle = null;
      _timer?.cancel();
      _timer = null;
      position = length;
      notifyListeners();
      final t = _pick(1, auto: true);
      if (t == null) {
        stop();
      } else {
        play(t);
      }
      return;
    }
    if (AppActivity.visible.value) position = soloud.getPosition(h);
  }

  void _scheduleSleep() {
    _sleepTimer?.cancel();
    _sleepTimer = Timer(_sleepAfter, _sleep);
  }

  void _cancelSleep() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
  }

  /// Ничего не играет — выключаем аудио-движок. Трек на паузе при этом
  /// выгружается, но место запоминается: «Играть» продолжит с него.
  Future<void> _sleep() async {
    _sleepTimer = null;
    if (loading || (_handle != null && !paused)) return;
    if (_handle != null) await _stopCurrent();
    MediaKeys.disable(); // звук уснул — медиаклавиши снова другим программам
    AppLog.write('audio engine sleeps');
    final soloud = SoLoud.instance;
    try {
      _releaseSpectrum();
      if (soloud.isInitialized) soloud.deinit();
    } catch (_) {}
  }

  void _onMediaKey(MediaKey key) {
    switch (key) {
      case MediaKey.playPause:
        togglePause();
      case MediaKey.next:
        next();
      case MediaKey.previous:
        previous();
      case MediaKey.stop:
        stop();
    }
  }

  Future<void> _stopCurrent() async {
    _timer?.cancel();
    final soloud = SoLoud.instance;
    final h = _handle, s = _source;
    _timer = null;
    _handle = null;
    _source = null;
    try {
      if (h != null) await soloud.stop(h);
      if (s != null) await soloud.disposeSource(s);
    } catch (_) {}
  }

  Future<void> stop() async {
    _token++;
    await _stopCurrent();
    paused = false;
    position = Duration.zero;
    loading = false;
    renderProgress = null;
    _scheduleSleep();
    notifyListeners();
  }

  /// Закрыть плеер (крестик мини-плеера): тишина, ничего не выбрано.
  Future<void> close() async {
    await stop();
    current = null;
    currentFormat = null;
    loopStart = null;
    error = null;
    length = Duration.zero;
    notifyListeners();
  }

  /// Выход из лаунчера: звук и медиаклавиши — сразу, без ожидания засыпания
  /// (иначе музыка может играть после закрытия окна).
  Future<void> shutdown() async {
    _token++;
    _cancelSleep();
    MediaKeys.disable();
    try {
      await _stopCurrent();
      final soloud = SoLoud.instance;
      _releaseSpectrum();
      if (soloud.isInitialized) soloud.deinit();
    } catch (_) {}
  }

  void togglePause() {
    final h = _handle;
    if (h == null) {
      // Остановлен — сначала; на паузе, а движок уснул, — с того же места.
      if (current != null) {
        play(current!, subtrack: subtrack, from: paused ? position : Duration.zero);
      } else {
        next();
      }
      return;
    }
    paused = !paused;
    final soloud = SoLoud.instance;
    soloud.setPause(h, paused);
    if (paused) {
      position = soloud.getPosition(h);
      _scheduleSleep();
    } else {
      _cancelSleep();
    }
    _startTimer();
    notifyListeners();
  }

  void seek(Duration to) {
    final h = _handle;
    final clamped = to < Duration.zero ? Duration.zero : (to > length ? length : to);
    if (h == null) {
      // На паузе, а движок уснул: «Играть» продолжит с нового места.
      if (current != null && paused) position = clamped;
      return;
    }
    SoLoud.instance.seek(h, clamped);
    position = clamped;
    notifyListeners();
  }

  void seekBy(Duration d) => seek(position + d);

  /// Другая дорожка многодорожечного файла — сначала.
  void setSubtrack(int n) {
    final t = current;
    if (t != null && n != subtrack) play(t, subtrack: n);
  }

  void setRepeat(PlayerRepeat r) {
    repeat = r;
    final h = _handle;
    if (h != null) {
      SoLoud.instance.setLooping(h, loop);
      if (loop) SoLoud.instance.setLoopPoint(h, _loopPointFor(currentFormat ?? MusicFormat.unknown));
    }
    _save();
    notifyListeners();
  }

  /// Следующий режим: весь список → до конца списка → трек с начала → трек с циклом.
  void cycleRepeat() => setRepeat(PlayerRepeat.values[(repeat.index + 1) % PlayerRepeat.values.length]);

  void setShuffle(bool v) {
    shuffle = v;
    _bag = null;
    _save();
    notifyListeners();
  }

  /// Кнопка динамика: выключить звук или вернуть прежнюю громкость.
  void toggleMute() {
    if (volume > 0) {
      _volumeBeforeMute = volume;
      setVolume(0);
    } else {
      setVolume(_volumeBeforeMute > 0.01 ? _volumeBeforeMute : 0.8);
    }
  }

  /// Громкость: сразу — звуку и ползункам; на диск — когда её перестали
  /// менять (ползунок шлёт десятки значений в секунду).
  void setVolume(double v) {
    volumeListenable.value = v.clamp(0.0, 1.0);
    final h = _handle;
    if (h != null) {
      try {
        SoLoud.instance.setVolume(h, volume);
      } catch (_) {}
    }
    _volumeSave?.cancel();
    _volumeSave = Timer(const Duration(milliseconds: 600), _save);
  }

  Timer? _volumeSave;

  bool isFavorite(MusicTrack t) => favorites.contains(t.key);

  void toggleFavorite(MusicTrack t) {
    if (!favorites.remove(t.key)) favorites.add(t.key);
    _save();
    notifyListeners();
  }

  void setFavoritesOnly(bool v) {
    favoritesOnly = v;
    _save();
    notifyListeners();
  }

  // --- Спектр для визуализации ---

  AudioData? _audioData;

  /// Спектр того, что звучит: 256 значений FFT (от низких к высоким); null —
  /// ничего не играет. Пока его спрашивают, движок считает FFT (немного
  /// процессора) — визуализация зовёт [stopSpectrum], когда не нужна.
  Float32List? spectrum() {
    final soloud = SoLoud.instance;
    if (!playing || !soloud.isInitialized) return null;
    try {
      if (!soloud.getVisualizationEnabled()) {
        soloud.setVisualizationEnabled(true);
        soloud.setFftSmoothing(0.75);
      }
      final data = _audioData ??= AudioData(GetSamplesKind.linear);
      data.updateSamples();
      return Float32List.fromList(data.getAudioData().sublist(0, 256));
    } catch (_) {
      return null;
    }
  }

  /// Визуализация не нужна (свёрнуто, не играет): движок не считает FFT.
  void stopSpectrum() {
    final soloud = SoLoud.instance;
    try {
      if (soloud.isInitialized && soloud.getVisualizationEnabled()) soloud.setVisualizationEnabled(false);
    } catch (_) {}
  }

  void _releaseSpectrum() {
    try {
      _audioData?.dispose();
    } catch (_) {}
    _audioData = null;
  }

  void setHideDuplicates(bool v) {
    hideDuplicates = v;
    _save();
    notifyListeners();
  }

  /// Копии трека [t] в других файлах (та же музыка), кроме него самого.
  List<MusicTrack> copiesOf(MusicTrack t) {
    if (t.fingerprint.isEmpty || t.category == MusicCategory.opened) return const [];
    if (!identical(_copiesFor, tracks)) {
      _copiesFor = tracks;
      _copies = {};
      for (final x in tracks) {
        if (x.fingerprint.isEmpty || x.category == MusicCategory.opened) continue;
        (_copies['${x.game}\u0000${x.fingerprint}'] ??= []).add(x);
      }
    }
    // Копии — в той же игре, как и у «Скрыть дубликаты».
    return [for (final x in _copies['${t.game}\u0000${t.fingerprint}'] ?? const <MusicTrack>[]) if (x.key != t.key) x];
  }

  List<MusicTrack>? _copiesFor;
  Map<String, List<MusicTrack>> _copies = {};

  /// Выбирает SoundFont (null — встроенный синтезатор). Играющий MIDI
  /// перерисовывается с новым звуком с того же места.
  void setSf2(String? path) {
    if (path == sf2Path) return;
    sf2Path = path;
    if (path != null && !soundFonts.contains(path)) soundFonts.add(path);
    _save();
    notifyListeners();
    final t = current;
    if (t != null && (currentFormat?.isSynth ?? false) && (_handle != null || loading)) {
      play(t, from: position);
    }
  }

  /// Убирает SoundFont из списка (файл не трогаем).
  void removeSoundFont(String path) {
    soundFonts.remove(path);
    if (sf2Path == path) {
      setSf2(null);
    } else {
      _save();
      notifyListeners();
    }
  }

  void setFormatHidden(MusicFormat f, bool hidden) => setFormatsHidden([f], hidden);

  void setFormatsHidden(Iterable<MusicFormat> formats, bool hidden) {
    if (hidden) {
      hiddenFormats.addAll(formats);
    } else {
      hiddenFormats.removeAll(formats);
    }
    _save();
    notifyListeners();
  }

  void showAllFormats() => setFormatsHidden(List.of(hiddenFormats), false);

  void setSort(MusicSort s) {
    sort = s;
    _save();
    notifyListeners();
  }

  /// Свёрнут ли раздел списка: игры ('game:...') по умолчанию развёрнуты,
  /// категории и файлы — свёрнуты.
  bool isCollapsed(String key) =>
      key.startsWith('game:') ? collapsedGames.contains(key) : !expandedGroups.contains(key);

  void setCollapsed(Iterable<String> keys, bool collapsed) {
    for (final k in keys) {
      if (k.startsWith('game:')) {
        if (collapsed) {
          collapsedGames.add(k);
        } else {
          collapsedGames.remove(k);
        }
      } else if (collapsed) {
        expandedGroups.remove(k);
      } else {
        expandedGroups.add(k);
      }
    }
    notifyListeners();
  }

  /// Следующий/предыдущий трек, который можно проиграть.
  void next() {
    final t = _pick(1, auto: false);
    if (t != null) play(t);
  }

  void previous() {
    final t = _pick(-1, auto: false);
    if (t != null) play(t);
  }

  static bool _playable(MusicTrack t) => t.format.playable;

  /// Следующий трек ([dir] = 1) или предыдущий (-1). [auto] — трек доиграл
  /// сам: без повтора список на последнем треке заканчивается (null).
  MusicTrack? _pick(int dir, {required bool auto}) {
    final list = [for (final t in playlist.isEmpty ? tracks : playlist) if (_playable(t)) t];
    if (list.isEmpty) return null;
    final byKey = {for (final t in list) t.key: t};
    if (shuffle) {
      if (dir < 0) {
        // Назад — по истории.
        while (_history.length >= 2) {
          _history.removeLast();
          final t = byKey[_history.removeLast()];
          if (t != null) return t;
        }
        return null;
      }
      final bag = (_bag ?? const <String>[]).where(byKey.containsKey).toList();
      if (bag.isEmpty) {
        // Все сыграны: «до конца списка» — тишина, иначе новый круг.
        if (auto && repeat == PlayerRepeat.once && _bag != null) return null;
        bag.addAll(byKey.keys.where((k) => k != current?.key));
        bag.shuffle(math.Random());
        if (bag.isEmpty) return current;
      }
      final key = bag.removeLast();
      _bag = bag;
      return byKey[key];
    }
    final i = current == null ? -1 : list.indexWhere((t) => t.key == current!.key);
    var j = i < 0 && dir < 0 ? list.length - 1 : i + dir;
    if (j >= list.length || j < 0) {
      if (auto && repeat == PlayerRepeat.once) return null; // список кончился
      j = (j % list.length + list.length) % list.length;
    }
    return list[j];
  }

  @override
  void dispose() {
    AppActivity.visible.removeListener(_onVisibility);
    MediaKeys.disable();
    _timer?.cancel();
    _cancelSleep();
    _stopCurrent();
    positionListenable.dispose();
    _volumeSave?.cancel();
    volumeListenable.dispose();
    super.dispose();
  }
}
