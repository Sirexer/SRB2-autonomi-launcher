import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

enum MediaKey { playPause, next, previous, stop }

/// Медиаклавиши клавиатуры во всей системе (Windows), даже когда окно
/// лаунчера не в фокусе. Клавиши регистрируются (RegisterHotKey) в отдельном
/// изоляте со своей очередью сообщений. Пока они зарегистрированы, другие
/// программы их не получают — поэтому плеер включает их, только пока в нём
/// есть музыка, и отпускает, когда звук засыпает.
///
/// В других системах (и если клавиши уже заняты другой программой) медиа-
/// клавиши работают, когда окно лаунчера активно.
class MediaKeys {
  MediaKeys._();

  static void Function(MediaKey key)? _onKey;
  static Isolate? _isolate;
  static ReceivePort? _port;
  static int _threadId = 0;
  static bool _starting = false;

  /// Перехват нужен (enable без последующего disable).
  static bool _wanted = false;

  /// Включает перехват; [onKey] — что делать по нажатию.
  static Future<void> enable(void Function(MediaKey key) onKey) async {
    _onKey = onKey;
    _wanted = true;
    if (!Platform.isWindows || _isolate != null || _starting) return;
    _starting = true;
    final port = ReceivePort();
    _port = port;
    port.listen((msg) {
      if (msg is (String, int)) {
        final (kind, value) = msg;
        if (kind == 'thread') {
          _threadId = value;
          // Пока изолят запускался, перехват уже отключили.
          if (!_wanted) _quit();
        }
        if (kind == 'key' && value >= 1 && value <= MediaKey.values.length) _onKey?.call(MediaKey.values[value - 1]);
      } else if (msg == null) {
        // Изолят завершился.
        _isolate = null;
        _threadId = 0;
        port.close();
        if (identical(_port, port)) _port = null;
      }
    });
    try {
      _isolate = await Isolate.spawn(_hotkeyLoop, port.sendPort, onExit: port.sendPort);
    } catch (_) {
      port.close();
      _port = null;
    } finally {
      _starting = false;
    }
  }

  /// Отпускает клавиши — их снова получают другие программы.
  static void disable() {
    _wanted = false;
    _quit();
  }

  static void _quit() {
    final thread = _threadId;
    if (thread == 0) return;
    try {
      final user32 = DynamicLibrary.open('user32.dll');
      final post = user32.lookupFunction<Int32 Function(Uint32, Uint32, IntPtr, IntPtr), int Function(int, int, int, int)>(
          'PostThreadMessageW');
      post(thread, 0x0012 /* WM_QUIT */, 0, 0);
    } catch (_) {}
    _threadId = 0;
  }
}

/// Поток изолята: регистрирует клавиши и ждёт WM_HOTKEY, пока не придёт
/// WM_QUIT. Изолят не отдаёт управление циклу событий, поэтому всё время
/// остаётся на одном потоке ОС — его очередь сообщений и получает клавиши.
/// Ждём не бесконечно, а по 250 мс: иначе при закрытии лаунчера виртуальная
/// машина Dart не может остановить изолят и процесс не завершается.
void _hotkeyLoop(SendPort out) {
  final user32 = DynamicLibrary.open('user32.dll');
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final register = user32.lookupFunction<Int32 Function(IntPtr, Int32, Uint32, Uint32), int Function(int, int, int, int)>(
      'RegisterHotKey');
  final unregister = user32.lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>('UnregisterHotKey');
  final wait = user32.lookupFunction<Uint32 Function(Uint32, Pointer<IntPtr>, Int32, Uint32, Uint32),
      int Function(int, Pointer<IntPtr>, int, int, int)>('MsgWaitForMultipleObjects');
  final peek = user32.lookupFunction<Int32 Function(Pointer<Uint8>, IntPtr, Uint32, Uint32, Uint32),
      int Function(Pointer<Uint8>, int, int, int, int)>('PeekMessageW');
  final threadId = kernel32.lookupFunction<Uint32 Function(), int Function()>('GetCurrentThreadId')();

  // Номер = позиция в MediaKey + 1; виртуальные коды медиаклавиш.
  const keys = {1: 0xB3, 2: 0xB0, 3: 0xB1, 4: 0xB2}; // Play/Pause, Next, Previous, Stop
  final registered = <int>[];
  for (final MapEntry(key: id, value: vk) in keys.entries) {
    if (register(0, id, 0x4000 /* MOD_NOREPEAT */, vk) != 0) registered.add(id);
  }
  out.send(('thread', threadId));
  if (registered.isEmpty) return; // заняты другой программой — работаем только в окне

  // MSG (x64): hwnd 8, message 4 (+4), wParam 8, lParam 8, time 4, pt 8, private 4 = 48 байт.
  final msg = calloc<Uint8>(64);
  try {
    loop:
    while (true) {
      wait(0, nullptr, 0, 250, 0x04FF /* QS_ALLINPUT */);
      while (peek(msg, 0, 0, 0, 1 /* PM_REMOVE */) != 0) {
        final message = Pointer<Uint32>.fromAddress(msg.address + 8).value;
        if (message == 0x0012 /* WM_QUIT */) break loop;
        if (message == 0x0312 /* WM_HOTKEY */) {
          out.send(('key', Pointer<IntPtr>.fromAddress(msg.address + 16).value));
        }
      }
    }
  } finally {
    for (final id in registered) {
      unregister(0, id);
    }
    calloc.free(msg);
  }
}
