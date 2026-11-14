import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'file_actions.dart';

typedef _PlaySoundNative = Int32 Function(Pointer<Utf16> sound, IntPtr module, Uint32 flags);
typedef _PlaySoundDart = int Function(Pointer<Utf16> sound, int module, int flags);

/// Короткие звуки интерфейса без аудио-плагинов: WAV из ассетов кладётся во
/// временную папку и проигрывается системой — на Windows функцией PlaySound
/// из winmm.dll (асинхронно, без сторонних процессов), на Linux — paplay,
/// aplay или pw-play. Ошибки молча игнорируются.
class UiSound {
  UiSound._();

  static final Map<String, String> _files = {};
  static _PlaySoundDart? _playSound;

  /// Строки путей для PlaySound живут до конца работы (SND_ASYNC читает файл
  /// уже после возврата из функции).
  static final Map<String, Pointer<Utf16>> _nativePaths = {};

  static const _sndAsync = 0x0001;
  static const _sndNoDefault = 0x0002;
  static const _sndFilename = 0x00020000;

  static Future<void> play(String asset) async {
    try {
      final path = _files[asset] ??= await () async {
        final data = await rootBundle.load(asset);
        final file = File(p.join(Directory.systemTemp.path, 'srb2_launcher_${p.basename(asset)}'));
        await file.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
        return file.path;
      }();
      if (Platform.isWindows) {
        final play = _playSound ??=
            DynamicLibrary.open('winmm.dll').lookupFunction<_PlaySoundNative, _PlaySoundDart>('PlaySoundW');
        final native = _nativePaths[path] ??= path.toNativeUtf16();
        play(native, 0, _sndFilename | _sndAsync | _sndNoDefault);
        return;
      }
      final env = cleanChildEnvironment();
      for (final player in ['paplay', 'aplay', 'pw-play']) {
        try {
          await Process.start(player, [if (player == 'aplay') '-q', path],
              mode: ProcessStartMode.detached, environment: env, includeParentEnvironment: env == null);
          return;
        } on ProcessException {
          continue; // нет такой программы — пробуем следующую
        }
      }
    } catch (_) {
      // звук не обязателен
    }
  }
}
