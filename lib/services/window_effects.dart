import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

import '../theme/app_themes.dart';
import 'app_log.dart';

/// Прозрачность окна и подложка Windows 11 (Mica/Acrylic) из темы.
/// Linux — через окно GTK (`linux/runner`, канал `srb2al/window`); Windows —
/// напрямую через WinAPI. Не вышло — окно остаётся обычным.
class WindowEffects {
  WindowEffects._();

  static const _channel = MethodChannel('srb2al/window');

  static Future<void> apply(LauncherTheme t) async {
    try {
      if (Platform.isLinux) {
        await _channel.invokeMethod('setOpacity', t.windowOpacity);
      } else if (Platform.isWindows) {
        _Win32.apply(t);
      }
    } catch (e) {
      AppLog.console('[window] effects: $e');
    }
  }
}

typedef _FindWindowExN = IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>);
typedef _FindWindowExD = int Function(int, int, Pointer<Utf16>, Pointer<Utf16>);
typedef _GetPidN = Uint32 Function(IntPtr, Pointer<Uint32>);
typedef _GetPidD = int Function(int, Pointer<Uint32>);
typedef _GetLongN = IntPtr Function(IntPtr, Int32);
typedef _GetLongD = int Function(int, int);
typedef _SetLongN = IntPtr Function(IntPtr, Int32, IntPtr);
typedef _SetLongD = int Function(int, int, int);
typedef _SetLayeredN = Int32 Function(IntPtr, Uint32, Uint8, Uint32);
typedef _SetLayeredD = int Function(int, int, int, int);
typedef _CurPidN = Uint32 Function();
typedef _CurPidD = int Function();
typedef _DwmSetN = Int32 Function(IntPtr, Uint32, Pointer<Void>, Uint32);
typedef _DwmSetD = int Function(int, int, Pointer<Void>, int);
typedef _DwmExtendN = Int32 Function(IntPtr, Pointer<Int32>);
typedef _DwmExtendD = int Function(int, Pointer<Int32>);

class _Win32 {
  static const _gwlExStyle = -20;
  static const _wsExLayered = 0x00080000;
  static const _lwaAlpha = 0x2;
  static const _dwmwaUseImmersiveDarkMode = 20;
  static const _dwmwaSystemBackdropType = 38; // Windows 11 22H2+

  static int? _hwnd;

  /// Окно лаунчера: окно Flutter-раннера нашего процесса.
  static int _window() {
    if (_hwnd != null) return _hwnd!;
    final user32 = DynamicLibrary.open('user32.dll');
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final find = user32.lookupFunction<_FindWindowExN, _FindWindowExD>('FindWindowExW');
    final pidOf = user32.lookupFunction<_GetPidN, _GetPidD>('GetWindowThreadProcessId');
    final me = kernel32.lookupFunction<_CurPidN, _CurPidD>('GetCurrentProcessId')();
    final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
    final pid = calloc<Uint32>();
    try {
      var h = 0;
      while (true) {
        h = find(0, h, cls, nullptr);
        if (h == 0) break;
        pidOf(h, pid);
        if (pid.value == me) return _hwnd = h;
      }
      throw StateError('launcher window not found');
    } finally {
      calloc.free(cls);
      calloc.free(pid);
    }
  }

  static void apply(LauncherTheme t) {
    final hwnd = _window();
    final user32 = DynamicLibrary.open('user32.dll');
    final getLong = user32.lookupFunction<_GetLongN, _GetLongD>('GetWindowLongPtrW');
    final setLong = user32.lookupFunction<_SetLongN, _SetLongD>('SetWindowLongPtrW');
    final setLayered = user32.lookupFunction<_SetLayeredN, _SetLayeredD>('SetLayeredWindowAttributes');

    // Прозрачность всего окна: «слоистое» окно с общей альфой.
    final style = getLong(hwnd, _gwlExStyle);
    if (t.windowOpacity < 1) {
      setLong(hwnd, _gwlExStyle, style | _wsExLayered);
      setLayered(hwnd, 0, (t.windowOpacity * 255).round().clamp(0, 255), _lwaAlpha);
    } else if (style & _wsExLayered != 0) {
      setLong(hwnd, _gwlExStyle, style & ~_wsExLayered);
    }

    // Подложка Windows 11: рамка растягивается на всё окно, DWM рисует под ним
    // Mica (2) или Acrylic (3); 1 — без подложки. На старых Windows не сработает.
    final dwm = DynamicLibrary.open('dwmapi.dll');
    final setAttr = dwm.lookupFunction<_DwmSetN, _DwmSetD>('DwmSetWindowAttribute');
    final extend = dwm.lookupFunction<_DwmExtendN, _DwmExtendD>('DwmExtendFrameIntoClientArea');
    final value = calloc<Int32>();
    final margins = calloc<Int32>(4);
    try {
      value.value = t.dark ? 1 : 0;
      setAttr(hwnd, _dwmwaUseImmersiveDarkMode, value.cast(), 4);
      final on = t.backdrop != 'none';
      for (var i = 0; i < 4; i++) {
        margins[i] = on ? -1 : 0;
      }
      extend(hwnd, margins);
      value.value = switch (t.backdrop) {
        'mica' => 2,
        'acrylic' => 3,
        _ => 1,
      };
      setAttr(hwnd, _dwmwaSystemBackdropType, value.cast(), 4);
    } finally {
      calloc.free(value);
      calloc.free(margins);
    }
  }
}
