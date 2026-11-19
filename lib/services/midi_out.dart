import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// MIDI-устройство вывода системы.
class MidiDevice {
  /// Код для настроек: `win:*` (MIDI Mapper — устройство Windows по
  /// умолчанию), `win:<имя>`, `alsa:<клиент>:<порт>` (по именам: номера
  /// клиентов ALSA меняются от запуска к запуску).
  final String id;
  final String name;
  const MidiDevice(this.id, this.name);
}

/// Вывод MIDI на устройство системы: Windows — winmm (midiOut*), Linux —
/// ALSA sequencer. Всё через FFI; одно открытое устройство — один объект.
abstract class MidiOut {
  /// Устройства вывода; пусто — нет (или система не поддерживается).
  static List<MidiDevice> devices() {
    try {
      if (Platform.isWindows) return _WinMidiOut.devices();
      if (Platform.isLinux) return _AlsaMidiOut.devices();
    } catch (_) {}
    return const [];
  }

  /// Открывает устройство [id]; ошибка — исключение.
  static MidiOut open(String id) {
    if (id == 'null:') return _NullMidiOut(); // для тестов: никуда
    if (Platform.isWindows && id.startsWith('win:')) return _WinMidiOut.open(id.substring(4));
    if (Platform.isLinux && id.startsWith('alsa:')) return _AlsaMidiOut.open(id.substring(5));
    throw UnsupportedError('MIDI device "$id" is not available on this system');
  }

  /// Системный дескриптор открытого устройства (HMIDIOUT / snd_seq_t*):
  /// если поток вывода пришлось убить, главный поток закроет устройство им
  /// ([forceClose]), иначе оно останется занятым до выхода из лаунчера.
  int get handle;

  /// Закрывает устройство [id] по [handle] (из другого потока).
  static void forceClose(String id, int handle) {
    if (handle == 0) return;
    try {
      if (Platform.isWindows && id.startsWith('win:')) {
        _WinMidiOut.closeHandle(handle);
      } else if (Platform.isLinux && id.startsWith('alsa:')) {
        _AlsaMidiOut.closeHandle(handle);
      }
    } catch (_) {}
  }

  /// Короткое сообщение: статус (0x80..0xEF с каналом) и два байта данных.
  void send(int status, int a, int b);

  /// Тишина на всех каналах (All Sound Off, All Notes Off).
  void silence() {
    for (var ch = 0; ch < 16; ch++) {
      send(0xB0 | ch, 120, 0);
      send(0xB0 | ch, 123, 0);
    }
  }

  void close();
}

/// Устройство «никуда» (для тестов).
class _NullMidiOut extends MidiOut {
  @override
  int get handle => 0;
  @override
  void send(int status, int a, int b) {}
  @override
  void close() {}
}

// --- Windows: winmm ---

typedef _GetNumN = Uint32 Function();
typedef _GetNumD = int Function();
typedef _GetCapsN = Uint32 Function(UintPtr, Pointer<Uint8>, Uint32);
typedef _GetCapsD = int Function(int, Pointer<Uint8>, int);
typedef _OpenN = Uint32 Function(Pointer<IntPtr>, Uint32, UintPtr, UintPtr, Uint32);
typedef _OpenD = int Function(Pointer<IntPtr>, int, int, int, int);
typedef _ShortN = Uint32 Function(IntPtr, Uint32);
typedef _ShortD = int Function(int, int);
typedef _HandleN = Uint32 Function(IntPtr);
typedef _HandleD = int Function(int);
typedef _PeriodN = Uint32 Function(Uint32);
typedef _PeriodD = int Function(int);

class _WinMidiOut extends MidiOut {
  static const _mapper = 0xFFFFFFFF; // MIDI_MAPPER
  static const _capsSize = 84; // MIDIOUTCAPSW
  static final _lib = DynamicLibrary.open('winmm.dll');
  static final _num = _lib.lookupFunction<_GetNumN, _GetNumD>('midiOutGetNumDevs');
  static final _caps = _lib.lookupFunction<_GetCapsN, _GetCapsD>('midiOutGetDevCapsW');
  static final _open = _lib.lookupFunction<_OpenN, _OpenD>('midiOutOpen');
  static final _short = _lib.lookupFunction<_ShortN, _ShortD>('midiOutShortMsg');
  static final _reset = _lib.lookupFunction<_HandleN, _HandleD>('midiOutReset');
  static final _close = _lib.lookupFunction<_HandleN, _HandleD>('midiOutClose');
  static final _timeBegin = _lib.lookupFunction<_PeriodN, _PeriodD>('timeBeginPeriod');
  static final _timeEnd = _lib.lookupFunction<_PeriodN, _PeriodD>('timeEndPeriod');

  final int _h;
  _WinMidiOut(this._h);

  @override
  int get handle => _h;

  static void closeHandle(int h) {
    _reset(h);
    _close(h);
  }

  static const _allocated = 4; // MMSYSERR_ALLOCATED: устройство занято

  static String _name(int id) {
    final caps = calloc<Uint8>(_capsSize);
    try {
      if (_caps(id, caps, _capsSize) != 0) return '';
      // szPname: WCHAR[32] со смещения 8.
      return (caps + 8).cast<Utf16>().toDartString();
    } finally {
      calloc.free(caps);
    }
  }

  static List<MidiDevice> devices() => [
        const MidiDevice('win:*', 'Windows default (MIDI Mapper)'),
        for (var i = 0; i < _num(); i++)
          if (_name(i) case final n when n.isNotEmpty) MidiDevice('win:$n', n),
      ];

  static _WinMidiOut open(String name) {
    var id = _mapper;
    if (name != '*') {
      id = -1;
      for (var i = 0; i < _num(); i++) {
        if (_name(i) == name) id = i;
      }
      if (id == -1) throw StateError('MIDI device "$name" is not connected');
    }
    final h = calloc<IntPtr>();
    try {
      // Занято — обычно прошлый трек ещё отпускает устройство: подождать.
      var r = _open(h, id, 0, 0, 0); // CALLBACK_NULL
      for (var i = 0; r == _allocated && i < 20; i++) {
        sleep(const Duration(milliseconds: 100));
        r = _open(h, id, 0, 0, 0);
      }
      if (r == _allocated) {
        throw StateError('the device is busy (another program or the game is using it)');
      }
      if (r != 0) throw StateError('midiOutOpen failed ($r)');
      // Точный таймер Windows (иначе сон — по 15 мс, ноты «плывут»).
      _timeBegin(1);
      return _WinMidiOut(h.value);
    } finally {
      calloc.free(h);
    }
  }

  @override
  void send(int status, int a, int b) => _short(_h, (status & 0xFF) | ((a & 0x7F) << 8) | ((b & 0x7F) << 16));

  @override
  void close() {
    silence();
    _reset(_h);
    _close(_h);
    _timeEnd(1);
  }
}

// --- Linux: ALSA sequencer ---

typedef _SeqOpenN = Int32 Function(Pointer<Pointer<Void>>, Pointer<Utf8>, Int32, Int32);
typedef _SeqOpenD = int Function(Pointer<Pointer<Void>>, Pointer<Utf8>, int, int);
typedef _SeqPtrN = Int32 Function(Pointer<Void>);
typedef _SeqPtrD = int Function(Pointer<Void>);
typedef _SeqNameN = Int32 Function(Pointer<Void>, Pointer<Utf8>);
typedef _SeqNameD = int Function(Pointer<Void>, Pointer<Utf8>);
typedef _SeqPortN = Int32 Function(Pointer<Void>, Pointer<Utf8>, Uint32, Uint32);
typedef _SeqPortD = int Function(Pointer<Void>, Pointer<Utf8>, int, int);
typedef _SeqConnN = Int32 Function(Pointer<Void>, Int32, Int32, Int32);
typedef _SeqConnD = int Function(Pointer<Void>, int, int, int);
typedef _SeqEvN = Int32 Function(Pointer<Void>, Pointer<Uint8>);
typedef _SeqEvD = int Function(Pointer<Void>, Pointer<Uint8>);
typedef _InfoMallocN = Int32 Function(Pointer<Pointer<Void>>);
typedef _InfoMallocD = int Function(Pointer<Pointer<Void>>);
typedef _InfoFreeN = Void Function(Pointer<Void>);
typedef _InfoFreeD = void Function(Pointer<Void>);
typedef _InfoSetN = Void Function(Pointer<Void>, Int32);
typedef _InfoSetD = void Function(Pointer<Void>, int);
typedef _InfoGetN = Int32 Function(Pointer<Void>);
typedef _InfoGetD = int Function(Pointer<Void>);
typedef _InfoUGetN = Uint32 Function(Pointer<Void>);
typedef _InfoUGetD = int Function(Pointer<Void>);
typedef _InfoNameN = Pointer<Utf8> Function(Pointer<Void>);
typedef _InfoNameD = Pointer<Utf8> Function(Pointer<Void>);
typedef _QueryN = Int32 Function(Pointer<Void>, Pointer<Void>);
typedef _QueryD = int Function(Pointer<Void>, Pointer<Void>);

class _AlsaMidiOut extends MidiOut {
  static final _lib = DynamicLibrary.open('libasound.so.2');
  static final _seqOpen = _lib.lookupFunction<_SeqOpenN, _SeqOpenD>('snd_seq_open');
  static final _seqClose = _lib.lookupFunction<_SeqPtrN, _SeqPtrD>('snd_seq_close');
  static final _setName = _lib.lookupFunction<_SeqNameN, _SeqNameD>('snd_seq_set_client_name');
  static final _createPort = _lib.lookupFunction<_SeqPortN, _SeqPortD>('snd_seq_create_simple_port');
  static final _connectTo = _lib.lookupFunction<_SeqConnN, _SeqConnD>('snd_seq_connect_to');
  static final _outputDirect = _lib.lookupFunction<_SeqEvN, _SeqEvD>('snd_seq_event_output_direct');
  static final _clientMalloc = _lib.lookupFunction<_InfoMallocN, _InfoMallocD>('snd_seq_client_info_malloc');
  static final _clientFree = _lib.lookupFunction<_InfoFreeN, _InfoFreeD>('snd_seq_client_info_free');
  static final _clientSet = _lib.lookupFunction<_InfoSetN, _InfoSetD>('snd_seq_client_info_set_client');
  static final _clientGet = _lib.lookupFunction<_InfoGetN, _InfoGetD>('snd_seq_client_info_get_client');
  static final _clientName = _lib.lookupFunction<_InfoNameN, _InfoNameD>('snd_seq_client_info_get_name');
  static final _nextClient = _lib.lookupFunction<_QueryN, _QueryD>('snd_seq_query_next_client');
  static final _portMalloc = _lib.lookupFunction<_InfoMallocN, _InfoMallocD>('snd_seq_port_info_malloc');
  static final _portFree = _lib.lookupFunction<_InfoFreeN, _InfoFreeD>('snd_seq_port_info_free');
  static final _portSetClient = _lib.lookupFunction<_InfoSetN, _InfoSetD>('snd_seq_port_info_set_client');
  static final _portSetPort = _lib.lookupFunction<_InfoSetN, _InfoSetD>('snd_seq_port_info_set_port');
  static final _portGet = _lib.lookupFunction<_InfoGetN, _InfoGetD>('snd_seq_port_info_get_port');
  static final _portCaps = _lib.lookupFunction<_InfoUGetN, _InfoUGetD>('snd_seq_port_info_get_capability');
  static final _portName = _lib.lookupFunction<_InfoNameN, _InfoNameD>('snd_seq_port_info_get_name');
  static final _nextPort = _lib.lookupFunction<_QueryN, _QueryD>('snd_seq_query_next_port');

  static const _streamOutput = 1; // SND_SEQ_OPEN_OUTPUT
  static const _capWrite = 1 << 1, _capSubsWrite = 1 << 6, _capRead = 1 << 0, _capSubsRead = 1 << 5;
  static const _systemClient = 0; // клиенты 0 (System) и 14 (Midi Through) — не синтезаторы
  static const _throughClient = 14;

  final Pointer<Void> _seq;
  final int _port;
  final Pointer<Uint8> _ev = calloc<Uint8>(28); // snd_seq_event_t

  _AlsaMidiOut(this._seq, this._port);

  @override
  int get handle => _seq.address;

  static void closeHandle(int h) => _seqClose(Pointer<Void>.fromAddress(h));

  static Pointer<Void> _openSeq() {
    final h = calloc<Pointer<Void>>();
    final name = 'default'.toNativeUtf8();
    try {
      final r = _seqOpen(h, name, _streamOutput, 0);
      if (r < 0) throw StateError('ALSA sequencer is not available ($r)');
      return h.value;
    } finally {
      calloc.free(name);
      calloc.free(h);
    }
  }

  /// Порты, в которые можно писать: (клиент, порт, имя клиента, имя порта).
  static List<(int, int, String, String)> _ports(Pointer<Void> seq) {
    final out = <(int, int, String, String)>[];
    final ci = calloc<Pointer<Void>>(), pi = calloc<Pointer<Void>>();
    _clientMalloc(ci);
    _portMalloc(pi);
    try {
      _clientSet(ci.value, -1);
      while (_nextClient(seq, ci.value) >= 0) {
        final client = _clientGet(ci.value);
        if (client == _systemClient || client == _throughClient) continue;
        final clientName = _clientName(ci.value).toDartString();
        _portSetClient(pi.value, client);
        _portSetPort(pi.value, -1);
        while (_nextPort(seq, pi.value) >= 0) {
          final caps = _portCaps(pi.value);
          if (caps & (_capWrite | _capSubsWrite) != (_capWrite | _capSubsWrite)) continue;
          out.add((client, _portGet(pi.value), clientName, _portName(pi.value).toDartString()));
        }
      }
    } finally {
      _clientFree(ci.value);
      _portFree(pi.value);
      calloc.free(ci);
      calloc.free(pi);
    }
    return out;
  }

  static List<MidiDevice> devices() {
    // Нет секвенсора (модуль ALSA не загружен, контейнер) — и спрашивать нечего.
    if (!File('/dev/snd/seq').existsSync()) return const [];
    final seq = _openSeq();
    try {
      return [
        for (final (_, _, c, port) in _ports(seq)) MidiDevice('alsa:$c:$port', c == port ? c : '$c — $port'),
      ];
    } finally {
      _seqClose(seq);
    }
  }

  static _AlsaMidiOut open(String names) {
    final seq = _openSeq();
    try {
      final match = _ports(seq).where((p) => '${p.$3}:${p.$4}' == names).firstOrNull;
      if (match == null) throw StateError('MIDI device "$names" is not available');
      final me = 'SRB2 Autonomi Launcher'.toNativeUtf8();
      final portName = 'Music player'.toNativeUtf8();
      try {
        _setName(seq, me);
        final port = _createPort(seq, portName, _capRead | _capSubsRead, 1 << 1 | 1 << 20); // MIDI_GENERIC | APPLICATION
        if (port < 0) throw StateError('ALSA: could not create a port ($port)');
        final r = _connectTo(seq, port, match.$1, match.$2);
        if (r < 0) throw StateError('ALSA: could not connect to ${match.$3} ($r)');
        return _AlsaMidiOut(seq, port);
      } finally {
        calloc.free(me);
        calloc.free(portName);
      }
    } catch (_) {
      _seqClose(seq);
      rethrow;
    }
  }

  // Типы событий ALSA (asoundef / seq_event.h).
  static const _noteOn = 6, _noteOff = 7, _keyPress = 8, _controller = 10, _pgmChange = 11, _chanPress = 12,
      _pitchBend = 13;

  @override
  void send(int status, int a, int b) {
    final ev = _ev.asTypedList(28)..fillRange(0, 28, 0);
    final d = ByteData.sublistView(ev);
    final ch = status & 0x0F;
    final type = switch (status & 0xF0) {
      0x90 => b == 0 ? _noteOff : _noteOn,
      0x80 => _noteOff,
      0xA0 => _keyPress,
      0xB0 => _controller,
      0xC0 => _pgmChange,
      0xD0 => _chanPress,
      0xE0 => _pitchBend,
      _ => -1,
    };
    if (type < 0) return;
    ev[0] = type;
    ev[1] = 0; // flags: тики, фиксированная длина
    ev[3] = 253; // SND_SEQ_QUEUE_DIRECT
    ev[12] = 0; // source.client — подставит ALSA
    ev[13] = _port; // source.port
    ev[14] = 254; // dest.client: SND_SEQ_ADDRESS_SUBSCRIBERS
    ev[15] = 0;
    // data (с 16): note {channel, note, velocity, off_velocity, duration} или
    // control {channel, unused[3], param, value}.
    ev[16] = ch;
    switch (type) {
      case _noteOn || _noteOff || _keyPress:
        ev[17] = a & 0x7F;
        ev[18] = b & 0x7F;
      case _controller:
        d.setUint32(20, a & 0x7F, Endian.host);
        d.setInt32(24, b & 0x7F, Endian.host);
      case _pgmChange || _chanPress:
        d.setInt32(24, a & 0x7F, Endian.host);
      case _pitchBend:
        d.setInt32(24, ((b & 0x7F) << 7 | (a & 0x7F)) - 8192, Endian.host);
    }
    _outputDirect(_seq, _ev);
  }

  @override
  void close() {
    silence();
    _seqClose(_seq);
    calloc.free(_ev);
  }
}
