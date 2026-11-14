import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'map_preview.dart';
import 'midi_synth.dart';
import 'music.dart';
import 'native_music.dart';

/// Второй проход по трекам: длительность и теги из самих файлов (у модулей
/// и музыки приставок — через libopenmpt/libgme).
class MusicDetails {
  MusicDetails._();

  static Future<Map<(String, String), TrackDetails>> readInBackground(
    List<(String, String, MusicFormat)> items, {
    String? openmpt,
    String? gme,
  }) =>
      Isolate.run(() => read(items, openmpt: openmpt, gme: gme));

  /// [items] — (файл, запись, формат); ключ результата — (файл, запись).
  /// Треков, для которых нет нужной библиотеки, в результате нет — их
  /// прочитаем, когда она появится.
  static Map<(String, String), TrackDetails> read(
    List<(String, String, MusicFormat)> items, {
    String? openmpt,
    String? gme,
  }) {
    final byFile = <String, List<(String, MusicFormat)>>{};
    for (final (file, entry, format) in items) {
      (byFile[file] ??= []).add((entry, format));
    }
    final out = <(String, String), TrackDetails>{};
    for (final MapEntry(key: file, value: list) in byFile.entries) {
      AddonArchive? archive;
      try {
        if (list.any((x) => x.$1.isNotEmpty)) archive = AddonArchive.open(file);
        for (final (entry, format) in list) {
          TrackDetails? details;
          try {
            final bytes = entry.isEmpty ? File(file).readAsBytesSync() : MusicScanner.readEntry(archive!, entry);
            details = of(bytes, format, openmpt: openmpt, gme: gme);
          } catch (_) {
            details = const TrackDetails(); // не читается — не пробуем снова
          }
          if (details != null) out[(file, entry)] = details;
        }
      } catch (_) {
        // файл не открылся
      } finally {
        archive?.close();
      }
    }
    return out;
  }

  /// Сведения о треке; null — нужна библиотека, которой нет.
  static TrackDetails? of(Uint8List bytes, MusicFormat format, {String? openmpt, String? gme}) {
    var f = MusicScanner.detectFormat(bytes);
    if (f == MusicFormat.unknown) f = format;
    if (f.isSynth) return TrackDetails(durationMs: (MidiFile.parse(bytes).duration * 1000).round());
    if (f.isTracker) return openmpt == null ? null : NativeMusic.details(openmpt, bytes, f);
    if (f.isGme) return gme == null ? null : NativeMusic.details(gme, bytes, f);
    return TrackDetails(durationMs: MusicScanner.durationMs(bytes, f));
  }
}
