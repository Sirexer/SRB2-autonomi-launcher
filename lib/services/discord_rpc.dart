import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../i18n.dart';

/// Данные статуса для Discord Rich Presence.
class DiscordPresence {
  /// Тип активности: 0 = Playing, 2 = Listening.
  final int type;
  final String details;
  final String state;
  final int? startMs;
  final int? endMs;
  final String? largeImage;
  final String? largeText;
  final String? smallImage;
  final String? smallText;

  const DiscordPresence({
    this.type = 0,
    required this.details,
    this.state = '',
    this.startMs,
    this.endMs,
    this.largeImage,
    this.largeText,
    this.smallImage,
    this.smallText,
  });

  /// Обрезает строку до разрешённых Discord 2..128 символов.
  static String clampText(String text) {
    final t = text.trim();
    if (t.isEmpty) return '';
    if (t.length == 1) return '$t ';
    if (t.length <= 128) return t;
    return '${t.substring(0, 125)}...';
  }

  Map<String, Object?> toActivityJson() {
    final det = clampText(details);
    final st = clampText(state);
    final assets = <String, Object?>{
      if (largeImage != null && largeImage!.isNotEmpty) 'large_image': largeImage,
      if (largeText != null && clampText(largeText!).isNotEmpty) 'large_text': clampText(largeText!),
      if (smallImage != null && smallImage!.isNotEmpty) 'small_image': smallImage,
      if (smallText != null && clampText(smallText!).isNotEmpty) 'small_text': clampText(smallText!),
    };
    final timestamps = <String, Object?>{
      if (startMs != null) 'start': startMs! ~/ 1000,
      if (endMs != null && (startMs == null || endMs! > startMs!)) 'end': endMs! ~/ 1000,
    };
    return <String, Object?>{
      'type': type,
      if (det.isNotEmpty) 'details': det,
      if (st.isNotEmpty) 'state': st,
      if (timestamps.isNotEmpty) 'timestamps': timestamps,
      if (assets.isNotEmpty) 'assets': assets,
    };
  }

  @override
  bool operator ==(Object other) =>
      other is DiscordPresence &&
      other.type == type &&
      other.details == details &&
      other.state == state &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.largeImage == largeImage &&
      other.largeText == largeText &&
      other.smallImage == smallImage &&
      other.smallText == smallText;

  @override
  int get hashCode =>
      Object.hash(type, details, state, startMs, endMs, largeImage, largeText, smallImage, smallText);
}

/// Информация об играющем треке для формирования статуса Discord.
typedef DiscordMusicInfo = ({
  String title,
  String authors,
  String gameId,
  String sourceName,
  Duration? duration,
  int? startMs,
});

/// Информация о запущенном реплее для отображения в Discord (`type: 3`, Watching).
typedef DiscordReplayInfo = ({
  String gameId,
  String gameName,
  String character,
  String levelPack,
  String map,
  int startMs,
});

/// Сборка статуса Discord для лаунчера, музыкального плеера и просмотра реплеев.
DiscordPresence buildLauncherPresence({
  required String gameId,
  required String gameName,
  required String tab,
  required int sessionStartMs,
  String? selectedModName,
  String? selectedServerName,
  int queueCount = 0,
  DiscordMusicInfo? playingTrack,
  DiscordReplayInfo? watchingReplay,
}) {
  if (watchingReplay != null) {
    final pack = watchingReplay.levelPack.trim();
    final map = watchingReplay.map.trim();
    final charName = watchingReplay.character.trim();
    final details = switch ((pack.isNotEmpty, map.isNotEmpty)) {
      (true, true) => '$pack · $map',
      (true, false) => pack,
      (false, true) => map,
      (false, false) => watchingReplay.gameName,
    };
    final state = charName.isNotEmpty ? tr('Character: {name}', {'name': charName}) : tr('Watching replay');
    return DiscordPresence(
      type: 3,
      details: details,
      state: state,
      startMs: watchingReplay.startMs,
      largeImage: 'launcher',
      largeText: 'SRB2 Autonomi Launcher',
      smallImage: watchingReplay.gameId.isNotEmpty ? watchingReplay.gameId : 'launcher',
      smallText: watchingReplay.gameName,
    );
  }

  if (playingTrack != null) {
    final authors = playingTrack.authors.trim();
    final source = playingTrack.sourceName.trim();
    final state = authors.isNotEmpty ? authors : tr('Music player');
    final endMs = playingTrack.startMs != null && playingTrack.duration != null && playingTrack.duration! > Duration.zero
        ? playingTrack.startMs! + playingTrack.duration!.inMilliseconds
        : null;
    return DiscordPresence(
      type: 2,
      details: playingTrack.title,
      state: state,
      startMs: playingTrack.startMs,
      endMs: endMs,
      largeImage: 'launcher',
      largeText: source.isNotEmpty ? source : tr('Music player'),
      smallImage: 'music',
      smallText: tr('Music player'),
    );
  }

  final state = switch (tab) {
    'addons' => selectedModName != null && selectedModName.trim().isNotEmpty
        ? tr('Browsing addons: {name}', {'name': selectedModName.trim()})
        : tr('Browsing addons'),
    'launch' => queueCount > 0 ? tr('Ready to launch ({n} addons)', {'n': queueCount}) : tr('Ready to launch'),
    'servers' => selectedServerName != null && selectedServerName.trim().isNotEmpty
        ? tr('Server: {name}', {'name': selectedServerName.trim()})
        : tr('Browsing servers'),
    'player' => tr('In the music player'),
    'progress' => tr('Viewing progress'),
    'replays' => tr('Browsing replays'),
    _ => tr('Browsing addons'),
  };

  return DiscordPresence(
    type: 0,
    details: gameName,
    state: state,
    startMs: sessionStartMs,
    largeImage: 'launcher',
    largeText: 'SRB2 Autonomi Launcher',
    smallImage: gameId,
    smallText: gameName,
  );
}

/// Упаковка кадра локального Discord IPC: 4 байта opcode (LE), 4 байта длины (LE), UTF-8 JSON.
Uint8List encodeDiscordIpcFrame(int opcode, Map<String, Object?> payload) {
  final body = utf8.encode(jsonEncode(payload));
  final out = Uint8List(8 + body.length);
  ByteData.sublistView(out)
    ..setUint32(0, opcode, Endian.little)
    ..setUint32(4, body.length, Endian.little);
  out.setRange(8, 8 + body.length, body);
  return out;
}

/// Разбор доступных кадров Discord IPC из буфера; возвращает кадры и число прочитанных байт.
(List<(int opcode, Map<String, Object?> json)>, int consumed) decodeDiscordIpcFrames(Uint8List buf) {
  final frames = <(int, Map<String, Object?>)>[];
  var offset = 0;
  final bd = ByteData.sublistView(buf);
  while (offset + 8 <= buf.length) {
    final opcode = bd.getUint32(offset, Endian.little);
    final len = bd.getUint32(offset + 4, Endian.little);
    if (len > 4 << 20 || offset + 8 + len > buf.length) break;
    final text = utf8.decode(Uint8List.sublistView(buf, offset + 8, offset + 8 + len), allowMalformed: true);
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) frames.add((opcode, decoded.cast<String, Object?>()));
    } catch (_) {}
    offset += 8 + len;
  }
  return (frames, offset);
}

/// Клиент локального Discord Rich Presence без сторонних C++-плагинов:
/// Windows — именованный канал (`\\.\pipe\discord-ipc-N`) через `kernel32.dll`,
/// Linux — Unix domain socket (`$XDG_RUNTIME_DIR/discord-ipc-N`).
class DiscordRpcService {
  static const defaultApplicationId = '1576010079444926635';

  final String applicationId;
  bool _enabled = false;
  bool _disposed = false;
  DiscordPresence? _latest;
  SendPort? _workerPort;
  ReceivePort? _readyPort;
  bool _starting = false;

  DiscordRpcService([this.applicationId = defaultApplicationId]);

  bool get enabled => _enabled;

  Future<void> setEnabled(bool value) async {
    if (_disposed || _enabled == value) return;
    _enabled = value;
    if (value) {
      final hadPort = _workerPort != null;
      await _ensureStarted();
      if (hadPort && _latest != null) _workerPort?.send({'cmd': 'set', 'activity': _latest!.toActivityJson()});
    } else {
      _stopWorker();
    }
  }

  void update(DiscordPresence? presence) {
    if (_disposed) return;
    if (_latest == presence) return;
    _latest = presence;
    if (!_enabled) return;
    final port = _workerPort;
    if (port == null) {
      _ensureStarted();
      return;
    }
    port.send(presence == null ? const {'cmd': 'clear'} : {'cmd': 'set', 'activity': presence.toActivityJson()});
  }

  void clear() => update(null);

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _enabled = false;
    _latest = null;
    _stopWorker();
  }

  Future<void> _ensureStarted() async {
    if (_disposed || !_enabled || _workerPort != null || _starting) return;
    _starting = true;
    final ready = ReceivePort();
    _readyPort = ready;
    try {
      await Isolate.spawn(_ipcWorkerMain, (ready.sendPort, applicationId, pid));
      final first = await ready.first;
      if (first is SendPort) {
        if (_disposed || !_enabled) {
          first.send(const {'cmd': 'stop'});
          return;
        }
        _workerPort = first;
        final current = _latest;
        if (current != null) first.send({'cmd': 'set', 'activity': current.toActivityJson()});
      }
    } catch (_) {
      _stopWorker();
    } finally {
      _starting = false;
      ready.close();
      if (identical(_readyPort, ready)) _readyPort = null;
    }
  }

  void _stopWorker() {
    _workerPort?.send(const {'cmd': 'stop'});
    _workerPort = null;
    _readyPort?.close();
    _readyPort = null;
  }
}

void _ipcWorkerMain((SendPort mainPort, String clientId, int appPid) init) {
  final (mainPort, clientId, appPid) = init;
  final inbox = ReceivePort();
  mainPort.send(inbox.sendPort);

  _IpcTransport? transport;
  Map<String, Object?>? pendingActivity;
  var hasPending = false;
  var handshakeReady = false;
  var connecting = false;
  var pipeOffset = 0;
  var errorRetries = 0;
  var nonce = 0;
  var stopped = false;
  Timer? setDebounce;
  Timer? retryTimer;

  void dropTransport() {
    handshakeReady = false;
    transport?.close();
    transport = null;
  }

  void sendNow(Map<String, Object?>? activity) {
    final t = transport;
    if (t == null) {
      return;
    }
    if (!handshakeReady) return;
    final frame = encodeDiscordIpcFrame(1, {
      'cmd': 'SET_ACTIVITY',
      'args': {
        'pid': appPid,
        'activity': activity,
      },
      'nonce': '${++nonce}',
    });
    if (!t.write(frame)) {
      dropTransport();
    }
  }

  void scheduleSend([Duration delay = const Duration(milliseconds: 200)]) {
    setDebounce?.cancel();
    setDebounce = Timer(delay, () {
      if (stopped || !hasPending) return;
      if (transport == null || !handshakeReady) return;
      errorRetries = 0;
      sendNow(pendingActivity);
    });
  }

  Future<void> ensureConnected() async {
    if (stopped || transport != null || connecting) return;
    connecting = true;
    try {
      final next = await _IpcTransport.connect(
        startIndex: pipeOffset,
        onFrame: (op, payload) {
          if (stopped) return;
          if (op == 2) {
            dropTransport();
            return;
          }
          final evt = payload['evt'];
          if (evt == 'READY') {
            handshakeReady = true;
            pipeOffset = 0;
            errorRetries = 0;
            if (hasPending) scheduleSend(const Duration(milliseconds: 250));
          } else if (evt == 'ERROR' && hasPending && errorRetries < 3) {
            errorRetries++;
            retryTimer?.cancel();
            retryTimer = Timer(const Duration(seconds: 3), () {
              if (!stopped && hasPending) sendNow(pendingActivity);
            });
          }
        },
      );
      if (stopped || next == null) {
        next?.close();
        pipeOffset = 0;
        return;
      }
      if (!next.write(encodeDiscordIpcFrame(0, {'v': 1, 'client_id': clientId}))) {
        next.close();
        return;
      }
      transport = next;
      // Ждём настоящий READY до 6 с: при запуске Discord может создать канал
      // до полной готовности RPC и ответить не сразу.
      for (var i = 0; i < 60 && !stopped && transport == next && !handshakeReady; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (stopped || transport != next) return;
        if (!next.pumpIncoming()) {
          dropTransport();
          return;
        }
      }
      if (!stopped && transport == next && !handshakeReady) {
        // Канал не ответил на handshake — сбрасываем и попробуем заново.
        pipeOffset = (pipeOffset + 1) % 10;
        dropTransport();
      }
    } finally {
      connecting = false;
    }
  }

  final pollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
    if (stopped) return;
    final t = transport;
    if (t == null) return;
    if (!t.pumpIncoming()) dropTransport();
  });

  final reconnectTimer = Timer.periodic(const Duration(seconds: 3), (_) {
    if (!stopped && transport == null) ensureConnected();
  });

  inbox.listen((msg) {
    if (msg is! Map) return;
    final cmd = msg['cmd'];
    if (cmd == 'stop') {
      stopped = true;
      setDebounce?.cancel();
      retryTimer?.cancel();
      pollTimer.cancel();
      reconnectTimer.cancel();
      if (transport != null) {
        sendNow(null);
        dropTransport();
      }
      inbox.close();
      return;
    }
    if (cmd == 'clear') {
      setDebounce?.cancel();
      retryTimer?.cancel();
      hasPending = true;
      pendingActivity = null;
      sendNow(null);
      return;
    }
    if (cmd == 'set') {
      hasPending = true;
      pendingActivity = (msg['activity'] as Map).cast<String, Object?>();
      if (transport == null) ensureConnected();
      scheduleSend();
    }
  });

  ensureConnected();
}

abstract class _IpcTransport {
  bool write(Uint8List data);
  bool pumpIncoming();
  void close();

  static Future<_IpcTransport?> connect({
    int startIndex = 0,
    void Function(int op, Map<String, Object?> payload)? onFrame,
  }) =>
      Platform.isWindows
          ? Future.value(_WinPipeTransport.openAny(startIndex: startIndex, onFrame: onFrame))
          : _UnixSocketTransport.openAny(startIndex: startIndex, onFrame: onFrame);
}

typedef _CreateFileWNative = IntPtr Function(
    Pointer<Utf16>, Uint32, Uint32, Pointer<Void>, Uint32, Uint32, IntPtr);
typedef _CreateFileWDart = int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int);
typedef _WriteFileNative = Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>);
typedef _WriteFileDart = int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>);
typedef _ReadFileNative = Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>);
typedef _ReadFileDart = int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>);
typedef _PeekPipeNative = Int32 Function(
    IntPtr, Pointer<Void>, Uint32, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>);
typedef _PeekPipeDart = int Function(int, Pointer<Void>, int, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>);
typedef _CloseHandleNative = Int32 Function(IntPtr);
typedef _CloseHandleDart = int Function(int);
typedef _OpenProcessNative = IntPtr Function(Uint32, Int32, Uint32);
typedef _OpenProcessDart = int Function(int, int, int);
typedef _WaitForSingleObjectNative = Uint32 Function(IntPtr, Uint32);
typedef _WaitForSingleObjectDart = int Function(int, int);

_OpenProcessDart? _openProcess;
_WaitForSingleObjectDart? _waitForSingleObject;
_CloseHandleDart? _closeProcHandle;

/// Проверяет, жив ли процесс с указанным PID (без удержания stdin/stdout).
bool isProcessAlive(int pid) {
  if (pid <= 0) return false;
  if (Platform.isWindows) {
    if (_openProcess == null) {
      final k32 = DynamicLibrary.open('kernel32.dll');
      _openProcess = k32.lookupFunction<_OpenProcessNative, _OpenProcessDart>('OpenProcess');
      _waitForSingleObject =
          k32.lookupFunction<_WaitForSingleObjectNative, _WaitForSingleObjectDart>('WaitForSingleObject');
      _closeProcHandle = k32.lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');
    }
    const synchronize = 0x00100000;
    const waitTimeout = 0x00000102;
    final h = _openProcess!(synchronize, 0, pid);
    if (h == 0 || h == -1) return false;
    try {
      return _waitForSingleObject!(h, 0) == waitTimeout;
    } finally {
      _closeProcHandle!(h);
    }
  }
  if (Platform.isLinux) {
    try {
      final stat = File('/proc/$pid/stat').readAsStringSync();
      final rparen = stat.lastIndexOf(')');
      if (rparen < 0) return false;
      final rest = stat.substring(rparen + 1).trimLeft();
      if (rest.isEmpty) return false;
      final state = rest[0];
      return state != 'Z' && state != 'X';
    } catch (_) {
      return false;
    }
  }
  try {
    return Process.runSync('kill', ['-0', '$pid']).exitCode == 0;
  } catch (_) {
    return false;
  }
}

class _WinPipeTransport implements _IpcTransport {
  static _CreateFileWDart? _createFile;
  static _WriteFileDart? _writeFile;
  static _ReadFileDart? _readFile;
  static _PeekPipeDart? _peekPipe;
  static _CloseHandleDart? _closeHandle;

  static void _bind() {
    if (_createFile != null) return;
    final k32 = DynamicLibrary.open('kernel32.dll');
    _createFile = k32.lookupFunction<_CreateFileWNative, _CreateFileWDart>('CreateFileW');
    _writeFile = k32.lookupFunction<_WriteFileNative, _WriteFileDart>('WriteFile');
    _readFile = k32.lookupFunction<_ReadFileNative, _ReadFileDart>('ReadFile');
    _peekPipe = k32.lookupFunction<_PeekPipeNative, _PeekPipeDart>('PeekNamedPipe');
    _closeHandle = k32.lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');
  }

  final int _handle;
  final void Function(int op, Map<String, Object?> payload)? _onFrame;
  final _readBuf = calloc<Uint8>(8192);
  final _countPtr = calloc<Uint32>(1);
  final _availPtr = calloc<Uint32>(1);
  final BytesBuilder _rx = BytesBuilder(copy: false);
  bool _closed = false;

  _WinPipeTransport(this._handle, [this._onFrame]);

  static _WinPipeTransport? openAny({
    int startIndex = 0,
    void Function(int op, Map<String, Object?> payload)? onFrame,
  }) {
    _bind();
    const access = 0x80000000 | 0x40000000; // GENERIC_READ | GENERIC_WRITE
    const openExisting = 3;
    for (var offset = 0; offset < 10; offset++) {
      final i = (startIndex + offset) % 10;
      final path = '\\\\.\\pipe\\discord-ipc-$i';
      final wPath = path.toNativeUtf16();
      try {
        final h = _createFile!(wPath, access, 0, nullptr, openExisting, 0, 0);
        if (h != -1 && h != 0) return _WinPipeTransport(h, onFrame);
      } finally {
        calloc.free(wPath);
      }
    }
    return null;
  }

  @override
  bool write(Uint8List data) {
    if (_closed) return false;
    final ptr = calloc<Uint8>(data.length);
    try {
      ptr.asTypedList(data.length).setAll(0, data);
      var offset = 0;
      while (offset < data.length) {
        final ok = _writeFile!(_handle, ptr + offset, data.length - offset, _countPtr, nullptr);
        if (ok == 0 || _countPtr.value == 0) return false;
        offset += _countPtr.value;
      }
      return true;
    } finally {
      calloc.free(ptr);
    }
  }

  @override
  bool pumpIncoming() {
    if (_closed) return false;
    while (true) {
      if (_peekPipe!(_handle, nullptr, 0, nullptr, _availPtr, nullptr) == 0) return false;
      final avail = _availPtr.value;
      if (avail == 0) break;
      final toRead = avail > 8192 ? 8192 : avail;
      if (_readFile!(_handle, _readBuf, toRead, _countPtr, nullptr) == 0) return false;
      final n = _countPtr.value;
      if (n == 0) break;
      _rx.add(Uint8List.fromList(_readBuf.asTypedList(n)));
    }
    if (_rx.isNotEmpty) {
      final bytes = _rx.takeBytes();
      final (frames, consumed) = decodeDiscordIpcFrames(bytes);
      if (consumed < bytes.length) _rx.add(Uint8List.sublistView(bytes, consumed));
      for (final (op, payload) in frames) {
        if (op == 3) {
          if (!write(encodeDiscordIpcFrame(4, payload))) return false;
        } else {
          _onFrame?.call(op, payload);
        }
      }
    }
    return true;
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    try {
      writeRawClose();
    } catch (_) {}
    _closeHandle!(_handle);
    calloc.free(_readBuf);
    calloc.free(_countPtr);
    calloc.free(_availPtr);
  }

  void writeRawClose() {
    final frame = encodeDiscordIpcFrame(2, const {});
    final ptr = calloc<Uint8>(frame.length);
    try {
      ptr.asTypedList(frame.length).setAll(0, frame);
      _writeFile!(_handle, ptr, frame.length, _countPtr, nullptr);
    } finally {
      calloc.free(ptr);
    }
  }
}

class _UnixSocketTransport implements _IpcTransport {
  final Socket _socket;
  final void Function(int op, Map<String, Object?> payload)? _onFrame;
  final BytesBuilder _rx = BytesBuilder(copy: false);
  bool _alive = true;

  _UnixSocketTransport(this._socket, [this._onFrame]) {
    _socket.listen(
      (chunk) {
        _rx.add(chunk);
        final bytes = _rx.takeBytes();
        final (frames, consumed) = decodeDiscordIpcFrames(bytes);
        if (consumed < bytes.length) _rx.add(Uint8List.sublistView(bytes, consumed));
        for (final (op, payload) in frames) {
          if (op == 3) {
            write(encodeDiscordIpcFrame(4, payload));
          } else {
            _onFrame?.call(op, payload);
          }
        }
      },
      onError: (_) => _alive = false,
      onDone: () => _alive = false,
      cancelOnError: true,
    );
  }

  static Future<_UnixSocketTransport?> openAny({
    int startIndex = 0,
    void Function(int op, Map<String, Object?> payload)? onFrame,
  }) async {
    final bases = <String>{
      ?Platform.environment['XDG_RUNTIME_DIR'],
      ?Platform.environment['TMPDIR'],
      ?Platform.environment['TMP'],
      ?Platform.environment['TEMP'],
      '/tmp',
    };
    final dirs = <String>[
      for (final b in bases) ...[
        b,
        '$b/app/com.discordapp.Discord',
        '$b/snap.discord',
      ],
    ];
    for (final dir in dirs) {
      if (!Directory(dir).existsSync()) continue;
      for (var offset = 0; offset < 10; offset++) {
        final i = (startIndex + offset) % 10;
        final path = '$dir/discord-ipc-$i';
        try {
          final sock = await Socket.connect(
            InternetAddress(path, type: InternetAddressType.unix),
            0,
            timeout: const Duration(milliseconds: 500),
          );
          return _UnixSocketTransport(sock, onFrame);
        } catch (_) {}
      }
    }
    return null;
  }

  @override
  bool write(Uint8List data) {
    if (!_alive) return false;
    try {
      _socket.add(data);
      return true;
    } catch (_) {
      _alive = false;
      return false;
    }
  }

  @override
  bool pumpIncoming() => _alive;

  @override
  void close() {
    if (!_alive) return;
    _alive = false;
    try {
      _socket.add(encodeDiscordIpcFrame(2, const {}));
      _socket.destroy();
    } catch (_) {}
  }
}
