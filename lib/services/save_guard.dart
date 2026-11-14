import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_log.dart';
import 'game_progress.dart';
import 'map_preview.dart' show AddonArchive;
import 'ring_progress.dart';

/// Что за файл сохранения и как его проверять.
enum SaveKind {
  /// gamedata.dat SRB2 2.2 / SRB2 Legacy (и свои .dat левелпаков).
  srbData,

  /// kartdata.dat SRB2Kart.
  kartData,

  /// ringdata.dat Ring Racers.
  ringData,

  /// ringprofiles.prf Ring Racers.
  ringProfiles,

  /// Слот одиночной игры SRB2 / Legacy (`srb2sav1.ssg`, `<пак>1.ssg`).
  srbSave,

  /// Незаконченный Гран-при Ring Racers (`gpringsav.bkp`).
  ringSave,
}

/// Итог проверки файла: цел ли он и общее время в игре (тики; null — в
/// файле его нет).
typedef SaveCheck = ({bool ok, int? playTime});

enum SaveEventType {
  /// Файл был повреждён и восстановлен из копии.
  restored,

  /// Файл повреждён, а целой копии нет.
  brokenNoBackup,

  /// Файл цел, но времени в игре в нём меньше, чем в копии: прогресс
  /// сбросили (сам игрок или игра) — копию не трогаем, спрашиваем.
  decreased,
}

class SaveEvent {
  final SaveEventType type;
  final String gameId, folder, file;

  /// Время копии (у [SaveEventType.restored] — той, что восстановлена).
  final DateTime? backupTime;
  final int? backupPlayTime, currentPlayTime;

  /// Куда отложен повреждённый файл.
  final String? brokenCopy;

  /// Восстановлен из копии самой игры (`ringdata.dat.bak`), а не лаунчера.
  final bool fromGameBackup;

  const SaveEvent(this.type, this.gameId, this.folder, this.file,
      {this.backupTime, this.backupPlayTime, this.currentPlayTime, this.brokenCopy, this.fromGameBackup = false});
}

/// Копия одного файла.
class SaveBackup {
  final String file;
  final String path;
  final DateTime time;
  final int? playTime;
  const SaveBackup(this.file, this.path, this.time, this.playTime);
}

/// Какие файлы сохранений проверять: файлы данных по имени и слоты по
/// началу имени (`srb2sav` → `srb2sav1.ssg`; у Ring Racers — `gpringsav.bkp`).
class SaveTargets {
  final Set<String> dataFiles;
  final Set<String> savePrefixes;
  const SaveTargets(this.dataFiles, this.savePrefixes);

  bool wants(String gameId, String name) {
    final n = name.toLowerCase();
    switch (SaveGuard.kindOf(gameId, n)) {
      case null:
        return false;
      case SaveKind.srbSave:
        return savePrefixes.any((x) => RegExp('^${RegExp.escape(x)}\\d+\\.ssg\$').hasMatch(n));
      case SaveKind.ringSave:
        return savePrefixes.any((x) => n == 'gp$x.bkp');
      default:
        return dataFiles.contains(n);
    }
  }
}

/// Чем заменить повреждённый файл: копия лаунчера или самой игры.
class SaveSource {
  final String path;
  final DateTime? time;
  final SaveCheck check;

  /// Копия самой игры (`ringdata.dat.bak`).
  final bool fromGame;
  const SaveSource(this.path, this.time, this.check, this.fromGame);
}

/// Защита сохранений: последняя целая копия каждого файла сохранения и
/// восстановление повреждённых.
///
/// - Целый файл — копируется в папку лаунчера (одна копия на файл, только
///   если он изменился).
/// - Повреждённый (обрезан, из нулей — так бывает, если ПК выключился во
///   время записи) — откладывается в папку «Damaged», а на его место
///   кладётся копия ([SaveEventType.restored]).
/// - Целый, но с меньшим временем в игре, чем в копии, — прогресс сброшен:
///   копия не перезаписывается, решает игрок ([SaveEventType.decreased]).
///
/// Файлы ищутся в папке игры (как у вкладки Progress): .dat, сохранения
/// (.ssg; у Ring Racers — ringprofiles.prf и gp*.bkp). Неизвестный файл
/// без копии и не прочитанный — не сохранение игры, не трогаем.
class SaveGuard {
  SaveGuard._();

  /// Настройка «Защищать сохранения» (Experimental; по умолчанию выключена).
  static bool enabled = false;
  static const prefsKey = 'save_protection';

  /// Папка для копий; null — папка данных лаунчера (тесты задают свою).
  static String? rootOverride;

  /// Пауза перед повторным чтением повреждённого файла: вдруг игра как раз
  /// его пишет.
  static Duration settle = const Duration(milliseconds: 1500);

  static Future<String> root() async =>
      rootOverride ?? p.join((await getApplicationSupportDirectory()).path, 'save_backups');

  /// Папка повреждённых (и заменённых) файлов — одна на все игры.
  static Future<String> damagedFolder() async => p.join(await root(), 'Damaged');

  /// Папка копий игры [gameId] с папкой [folder].
  static Future<String> backupFolder(String gameId, String folder) async {
    final key = md5.convert(utf8.encode(_normFolder(folder))).toString().substring(0, 10);
    return p.join(await root(), '$gameId-$key');
  }

  static String _normFolder(String folder) {
    final n = p.normalize(p.absolute(folder));
    return Platform.isWindows ? n.toLowerCase() : n;
  }

  /// Что за файл [name] у игры [gameId]; null — не сохранение.
  static SaveKind? kindOf(String gameId, String name) {
    final n = name.toLowerCase();
    final ext = p.extension(n);
    switch (gameId) {
      case 'srb2':
      case 'srb2legacy':
        if (ext == '.dat') return SaveKind.srbData;
        if (ext == '.ssg') return SaveKind.srbSave;
      case 'srb2kart':
        if (ext == '.dat') return SaveKind.kartData;
      case 'drrr':
        if (ext == '.dat') return SaveKind.ringData;
        if (ext == '.prf') return SaveKind.ringProfiles;
        if (ext == '.bkp' && n.startsWith('gp')) return SaveKind.ringSave;
    }
    return null;
  }

  /// Цел ли файл: тот же разбор, что во вкладке Progress, и те же проверки,
  /// что делает игра при загрузке.
  static SaveCheck validate(SaveKind kind, Uint8List bytes) {
    const bad = (ok: false, playTime: null);
    try {
      switch (kind) {
        case SaveKind.srbData:
          return (ok: true, playTime: GameData.parse(bytes).totalPlayTime);
        case SaveKind.kartData:
          return (ok: true, playTime: GameData.parseKart(bytes).totalPlayTime);
        case SaveKind.ringData:
          return (ok: true, playTime: RingData.parse(bytes).playTimeTotal);
        case SaveKind.ringProfiles:
          RingProfile.parse(bytes);
          return (ok: true, playTime: null);
        case SaveKind.srbSave:
          return (ok: _savegame(bytes, 0), playTime: null);
        case SaveKind.ringSave:
          return (ok: _savegame(bytes, 1), playTime: null);
      }
    } catch (_) {
      return bad;
    }
  }

  /// Сохранение (G_SaveGame): с [offset] — строка "version N" в 16 байтах
  /// (дополнена нулями), в конце — маркер 0x1d (P_ArchiveLuabanksAndConsistency).
  static bool _savegame(Uint8List b, int offset) {
    const size = 16;
    if (b.length < offset + size + 1 || b.last != 0x1d) return false;
    final header = b.sublist(offset, offset + size);
    final end = header.indexOf(0);
    if (end < 9) return false;
    final text = ascii.decode(header.sublist(0, end), allowInvalid: true);
    if (!RegExp(r'^version \d+$').hasMatch(text)) return false;
    return header.skip(end).every((x) => x == 0);
  }

  // ---- копии ----

  static Future<Map<String, dynamic>> _readIndex(String dir) async {
    try {
      final j = jsonDecode(await File(p.join(dir, 'index.json')).readAsString());
      if (j is Map<String, dynamic>) return j;
    } catch (_) {}
    return {};
  }

  static Future<void> _writeIndex(String dir, Map<String, dynamic> index) async {
    await Directory(dir).create(recursive: true);
    final tmp = File(p.join(dir, 'index.json.tmp'));
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(index));
    await tmp.rename(p.join(dir, 'index.json'));
  }

  static Map<String, dynamic> _files(Map<String, dynamic> index) {
    final f = index['files'];
    if (f is Map<String, dynamic>) return f;
    return index['files'] = <String, dynamic>{};
  }

  /// Копии игры [gameId] с папкой [folder] (по имени файла).
  static Future<List<SaveBackup>> backups(String gameId, String folder) async {
    final dir = await backupFolder(gameId, folder);
    final index = await _readIndex(dir);
    final out = <SaveBackup>[];
    for (final e in _files(index).entries) {
      final v = e.value;
      if (v is! Map) continue;
      final path = p.join(dir, '${v['name'] ?? e.key}');
      if (!File(path).existsSync()) continue;
      out.add(SaveBackup('${v['name'] ?? e.key}', path, DateTime.tryParse('${v['time']}') ?? DateTime(2000),
          v['playTime'] is int ? v['playTime'] as int : null));
    }
    out.sort((a, b) => a.file.toLowerCase().compareTo(b.file.toLowerCase()));
    return out;
  }

  static Future<void> _store(String dir, Map<String, dynamic> index, String name, Uint8List bytes, SaveCheck check,
      String hash) async {
    await Directory(dir).create(recursive: true);
    final tmp = File(p.join(dir, '$name.tmp'));
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(p.join(dir, name));
    _files(index)[name.toLowerCase()] = {
      'name': name,
      'md5': hash,
      'size': bytes.length,
      'time': DateTime.now().toIso8601String(),
      if (check.playTime != null) 'playTime': check.playTime,
    };
  }

  // ---- какие файлы ----

  /// Файлы, которые нужны запуску: основные файлы игры и `GameData` из
  /// MainCfg запускаемых аддонов [gameData] (`mypack.dat`), с их слотами.
  static SaveTargets targetsFor(String gameId, Iterable<String> gameData) {
    final data = <String>{};
    final prefixes = <String>{};
    switch (gameId) {
      case 'srb2':
      case 'srb2legacy':
        data.add('gamedata.dat');
        prefixes.add('srb2sav');
      case 'srb2kart':
        data.add('kartdata.dat');
      case 'drrr':
        data.addAll(['ringdata.dat', 'ringprofiles.prf']);
        prefixes.add('ringsav');
    }
    for (final g in gameData) {
      final n = g.toLowerCase();
      data.add(n);
      // Как в игре: папка Time Attack и слоты — имя без 4 символов расширения.
      if (gameId != 'srb2kart') prefixes.add(n.length >= 4 ? n.substring(0, n.length - 4) : n);
    }
    return SaveTargets(data, prefixes);
  }

  static final Map<String, (DateTime, int, String?)> _gameDataCache = {};

  /// `GameData` из MainCfg файлов [files] (имена в нижнем регистре). Архивы
  /// открываются в фоновом изоляте; файл, что не менялся, — из кэша.
  static Future<Set<String>> gameDataOf(List<String> files) async {
    final out = <String>{};
    final unknown = <String>[];
    for (final f in files) {
      try {
        final st = File(f).statSync();
        final c = _gameDataCache[f];
        if (c != null && c.$1 == st.modified && c.$2 == st.size) {
          if (c.$3 != null) out.add(c.$3!);
          continue;
        }
      } catch (_) {
        continue;
      }
      unknown.add(f);
    }
    if (unknown.isEmpty) return out;
    final found = await Isolate.run(() => {for (final f in unknown) f: _gameDataIn(f)});
    for (final e in found.entries) {
      try {
        final st = File(e.key).statSync();
        _gameDataCache[e.key] = (st.modified, st.size, e.value);
      } catch (_) {}
      if (e.value != null) out.add(e.value!);
    }
    return out;
  }

  /// `GameData = x.dat` в SOC архива (последний, как в игре) или null.
  static String? _gameDataIn(String path) {
    String? found;
    void scan(String text) {
      var mainCfg = false;
      for (final raw in const LineSplitter().convert(text)) {
        final line = raw.trim();
        if (line.isEmpty || line.startsWith('#')) continue;
        final eq = line.indexOf('=');
        if (eq < 0) {
          mainCfg = line.split(RegExp(r'\s+')).first.toUpperCase() == 'MAINCFG';
          continue;
        }
        if (mainCfg && line.substring(0, eq).trim().toUpperCase() == 'GAMEDATA') {
          final v = line.substring(eq + 1).trim().split(RegExp(r'\s')).first;
          if (v.isNotEmpty) found = v.toLowerCase();
        }
      }
    }

    final ext = p.extension(path).toLowerCase();
    if (ext == '.soc' || ext == '.txt') {
      try {
        scan(latin1.decode(File(path).readAsBytesSync(), allowInvalid: true));
      } catch (_) {}
      return found;
    }
    final a = AddonArchive.open(path);
    if (a == null) return null;
    try {
      for (final e in a.entries) {
        if (!ProgressDefs.isSocEntry(a, e) || e.size > 8 << 20) continue;
        try {
          scan(latin1.decode(a.read(e), allowInvalid: true));
        } catch (_) {}
      }
    } finally {
      a.close();
    }
    return found;
  }

  // ---- проверка ----

  static Future<void> _lock = Future.value();

  /// Файлы, что уже проверены: путь → (время изменения, размер).
  static final Map<String, (DateTime, int)> _seen = {};

  /// О каких повреждённых без копии уже сказали: путь|время изменения.
  static final Set<String> _reported = {};

  /// Проверяет файлы [only] игры [gameId] в папке [folder] и обновляет их
  /// копии.
  ///
  /// [repair] = false — фоновая проверка (пока игра, может быть, запущена):
  /// только копирует целые файлы, которые не менялись хотя бы несколько
  /// секунд; повреждённые и «уменьшившиеся» не трогает. [repair] = true —
  /// перед запуском игры: восстанавливает повреждённые и сообщает об
  /// уменьшившихся.
  static Future<List<SaveEvent>> check(String gameId, String folder,
      {required bool repair, required SaveTargets only}) {
    final run = _lock.then((_) => _check(gameId, folder, repair: repair, only: only));
    _lock = run.then((_) {}, onError: (_) {});
    return run;
  }

  static Future<List<SaveEvent>> _check(String gameId, String folder,
      {required bool repair, required SaveTargets only}) async {
    final events = <SaveEvent>[];
    if (!enabled) return events;
    final dir = await backupFolder(gameId, folder);
    final index = await _readIndex(dir);
    var changed = false;

    List<File> files;
    try {
      files = Directory(folder)
          .listSync(followLinks: false)
          .whereType<File>()
          .where((f) => only.wants(gameId, p.basename(f.path)))
          .toList();
    } catch (_) {
      return events;
    }

    for (final f in files) {
      final name = p.basename(f.path);
      final kind = kindOf(gameId, name)!;
      FileStat stat;
      try {
        stat = f.statSync();
      } catch (_) {
        continue;
      }
      final seen = _seen[f.path];
      if (seen != null && seen.$1 == stat.modified && seen.$2 == stat.size) continue;
      // Фоном — только файлы, которые уже не пишутся.
      if (!repair && DateTime.now().difference(stat.modified) < const Duration(seconds: 5)) continue;

      Uint8List bytes;
      try {
        bytes = await f.readAsBytes();
      } catch (_) {
        continue;
      }
      final check = validate(kind, bytes);
      final entry = _files(index)[name.toLowerCase()];
      final backupPath = entry is Map ? p.join(dir, '${entry['name'] ?? name}') : null;
      final hasBackup = backupPath != null && File(backupPath).existsSync();

      if (check.ok) {
        final hash = md5.convert(bytes).toString();
        if (hasBackup && entry['md5'] == hash) {
          _seen[f.path] = (stat.modified, stat.size);
          continue;
        }
        final oldTime = hasBackup ? entry['playTime'] : null;
        if (oldTime is int && check.playTime != null && check.playTime! < oldTime) {
          if (repair) {
            events.add(SaveEvent(SaveEventType.decreased, gameId, folder, name,
                backupTime: DateTime.tryParse('${entry['time']}'),
                backupPlayTime: oldTime,
                currentPlayTime: check.playTime));
          }
          continue;
        }
        await _store(dir, index, name, bytes, check, hash);
        changed = true;
        _seen[f.path] = (stat.modified, stat.size);
        continue;
      }

      // Повреждён (или ещё пишется).
      if (!repair) continue;
      final source = await _bestSource(kind, f.path, hasBackup ? backupPath : null,
          hasBackup ? DateTime.tryParse('${entry['time']}') : null);
      if (source == null) {
        if (_reported.add('${f.path}|${stat.modified}')) {
          events.add(SaveEvent(SaveEventType.brokenNoBackup, gameId, folder, name));
        }
        _seen[f.path] = (stat.modified, stat.size);
        continue;
      }
      // Есть чем заменить — но сначала убедиться, что игра его не пишет.
      await Future<void>.delayed(settle);
      try {
        final again = await f.readAsBytes();
        if (again.length != bytes.length || md5.convert(again) != md5.convert(bytes)) continue;
      } catch (_) {
        continue;
      }
      try {
        events.add(await _replace(gameId, folder, dir, index, f, source));
        changed = true;
      } catch (e) {
        AppLog.console('[saves] could not restore $name: $e');
      }
    }

    if (changed) {
      index['game'] = gameId;
      index['folder'] = folder;
      await _writeIndex(dir, index);
    }
    return events;
  }

  /// Чем заменить повреждённый [path]: копия лаунчера [backup] или копия
  /// самой игры (`ringdata.dat.bak`) — целая и с большим временем в игре.
  static Future<SaveSource?> _bestSource(SaveKind kind, String path, String? backup, DateTime? backupTime) async {
    final sources = <SaveSource>[];
    if (backup != null) {
      try {
        final c = validate(kind, await File(backup).readAsBytes());
        if (c.ok) sources.add(SaveSource(backup, backupTime, c, false));
      } catch (_) {}
    }
    final gameBak = File('$path.bak');
    if (gameBak.existsSync()) {
      try {
        final c = validate(kind, await gameBak.readAsBytes());
        if (c.ok) sources.add(SaveSource(gameBak.path, gameBak.lastModifiedSync(), c, true));
      } catch (_) {}
    }
    if (sources.isEmpty) return null;
    sources.sort((a, b) => (b.check.playTime ?? -1).compareTo(a.check.playTime ?? -1));
    return sources.first;
  }

  /// Повреждённый [f] — в «Damaged», на его место — [source].
  static Future<SaveEvent> _replace(String gameId, String folder, String dir, Map<String, dynamic> index, File f,
      SaveSource source) async {
    final name = p.basename(f.path);
    final moved = await _moveToDamaged(f, gameId);
    await _copyInto(source.path, f.path);
    AppLog.console('[saves] $name was damaged: restored from ${source.path}, damaged file moved to $moved');
    final restored = await File(f.path).readAsBytes();
    await _store(dir, index, name, restored, source.check, md5.convert(restored).toString());
    final st = File(f.path).statSync();
    _seen[f.path] = (st.modified, st.size);
    return SaveEvent(SaveEventType.restored, gameId, folder, name,
        backupTime: source.time,
        backupPlayTime: source.check.playTime,
        brokenCopy: moved,
        fromGameBackup: source.fromGame);
  }

  /// Чем можно заменить файл [file] (для вкладки Progress, когда он не
  /// читается): копия лаунчера или самой игры; null — нечем.
  static Future<SaveSource?> sourceFor(String gameId, String folder, String file) async {
    final kind = kindOf(gameId, file);
    if (kind == null) return null;
    final dir = await backupFolder(gameId, folder);
    final entry = _files(await _readIndex(dir))[file.toLowerCase()];
    final backup = entry is Map ? p.join(dir, '${entry['name'] ?? file}') : null;
    return _bestSource(kind, p.join(folder, file), backup != null && File(backup).existsSync() ? backup : null,
        entry is Map ? DateTime.tryParse('${entry['time']}') : null);
  }

  /// Заменить повреждённый [file] лучшей копией ([sourceFor]); null — нечем.
  static Future<SaveEvent?> repair(String gameId, String folder, String file) {
    final run = _lock.then((_) async {
      final source = await sourceFor(gameId, folder, file);
      if (source == null) return null;
      final dir = await backupFolder(gameId, folder);
      final index = await _readIndex(dir);
      final e = await _replace(gameId, folder, dir, index, File(p.join(folder, file)), source);
      index['game'] = gameId;
      index['folder'] = folder;
      await _writeIndex(dir, index);
      return e;
    });
    _lock = run.then((_) {}, onError: (_) {});
    return run;
  }

  /// «Это я сбросил прогресс»: копия — нынешний файл.
  static Future<void> keepCurrent(SaveEvent e) => _lock = _lock.then((_) async {
        final f = File(p.join(e.folder, e.file));
        final kind = kindOf(e.gameId, e.file);
        if (kind == null || !f.existsSync()) return;
        final bytes = await f.readAsBytes();
        final check = validate(kind, bytes);
        if (!check.ok) return;
        final dir = await backupFolder(e.gameId, e.folder);
        final index = await _readIndex(dir);
        await _store(dir, index, e.file, bytes, check, md5.convert(bytes).toString());
        index['game'] = e.gameId;
        index['folder'] = e.folder;
        await _writeIndex(dir, index);
        final st = f.statSync();
        _seen[f.path] = (st.modified, st.size);
      }).catchError((Object err) => AppLog.console('[saves] could not update the copy of ${e.file}: $err'));

  /// Вернуть копию файла [file]: нынешний откладывается в папку «Damaged»
  /// (с пометкой «replaced»). Путь отложенного файла; null — копии нет.
  static Future<String?> restore(String gameId, String folder, String file) {
    final run = _lock.then((_) async {
      final dir = await backupFolder(gameId, folder);
      final index = await _readIndex(dir);
      final entry = _files(index)[file.toLowerCase()];
      if (entry is! Map) return null;
      final backup = p.join(dir, '${entry['name'] ?? file}');
      if (!File(backup).existsSync()) return null;
      final target = File(p.join(folder, file));
      String? moved;
      if (target.existsSync()) moved = await _moveToDamaged(target, gameId, replaced: true);
      await _copyInto(backup, target.path);
      final st = target.statSync();
      _seen[target.path] = (st.modified, st.size);
      AppLog.console('[saves] $file restored from the copy; the previous file moved to ${moved ?? '-'}');
      return moved ?? '';
    });
    _lock = run.then((_) {}, onError: (_) {});
    return run;
  }

  /// Переносит [f] в папку «Damaged»: `2026-11-13 19-07-55 drrr ringdata.dat`.
  static Future<String> _moveToDamaged(File f, String gameId, {bool replaced = false}) async {
    final damaged = await damagedFolder();
    await Directory(damaged).create(recursive: true);
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}-${two(now.minute)}-${two(now.second)}';
    var target = p.join(damaged, '$stamp $gameId ${p.basename(f.path)}${replaced ? ' (replaced)' : ''}');
    for (var i = 2; File(target).existsSync(); i++) {
      target = p.join(damaged, '$stamp $gameId ${p.basename(f.path)} ($i)${replaced ? ' (replaced)' : ''}');
    }
    try {
      await f.rename(target);
    } on FileSystemException {
      // Другой диск: копируем и удаляем.
      await f.copy(target);
      await f.delete();
    }
    return target;
  }

  /// Копирует [from] на место [to] через временный файл рядом с [to].
  static Future<void> _copyInto(String from, String to) async {
    final tmp = '$to.restoring';
    await File(from).copy(tmp);
    await File(tmp).rename(to);
  }

  /// Для тестов: забыть, что уже проверено.
  static void resetMemory() {
    _seen.clear();
    _reported.clear();
  }
}
