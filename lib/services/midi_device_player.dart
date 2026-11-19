import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'midi_out.dart';
import 'midi_synth.dart';

/// Проигрывание MIDI на устройство системы ([MidiOut]): ноты отправляет
/// отдельный изолят по своему таймеру. Пауза — тишина на всех каналах;
/// перемотка — тишина и заново все инструменты, контроллеры и высота тона
/// до нового места; громкость — громкость каналов (CC7), устройство не
/// трогается. Для визуализации — уровни звучащих нот по полосам.
class MidiDevicePlayback {
  /// Полос визуализации (как у плеера).
  static const bars = 48;

  final SendPort _commands;
  final ReceivePort _events;
  final Isolate _isolate;

  /// Длина трека.
  final Duration length;

  Duration _reported = Duration.zero;
  final Stopwatch _since = Stopwatch();
  bool _paused = false;

  /// Трек доиграл до конца (без повтора).
  bool finished = false;

  /// Уровни полос 0..1 (последние присланные).
  Float32List levels = Float32List(bars);

  /// Устройство отказало во время игры (текст ошибки).
  String? error;

  MidiDevicePlayback._(this._commands, this._events, this._isolate, this.length, this._device);

  final String _device;

  /// Дескриптор устройства из изолята — закрыть, если изолят пришлось убить.
  int _handle = 0;

  /// Устройством владеет один трек за раз: следующий ждёт, пока прошлый
  /// закроет устройство (иначе Windows отвечает «занято», ошибка 4).
  static MidiDevicePlayback? _current;

  /// Сколько устройств сейчас открыто (для тестов: не больше одного).
  @visibleForTesting
  static int get openCount => _current == null ? 0 : 1;
  static Future<void>? _stopping;
  Future<void>? _stopFuture;

  /// Открывает устройство [device] и начинает играть [file] с [from].
  /// Не открылось — исключение с причиной.
  static Future<MidiDevicePlayback> start(String device, MidiFile file,
      {Duration from = Duration.zero, double volume = 1, bool loop = false}) async {
    if (_current case final previous?) await previous.stop();
    if (_stopping case final s?) await s;
    final events = ReceivePort();
    final n = file.events.length;
    final times = Float64List(n);
    final msgs = Int32List(n);
    for (var i = 0; i < n; i++) {
      final e = file.events[i];
      times[i] = e.time;
      msgs[i] = e.status | (e.a << 8) | (e.b << 16);
    }
    final isolate = await Isolate.spawn(
      _run,
      _Start(events.sendPort, device, TransferableTypedData.fromList([times]),
          TransferableTypedData.fromList([msgs]), file.duration, from.inMicroseconds / 1e6, volume, loop),
      debugName: 'midi-out',
    );
    final ready = Completer<SendPort>();
    late MidiDevicePlayback playback;
    var handle = 0;
    events.listen((m) {
      if (m is (SendPort, int)) {
        handle = m.$2;
        ready.complete(m.$1);
      } else if (m is String) {
        if (!ready.isCompleted) {
          ready.completeError(StateError(m));
        } else {
          playback.error = m;
        }
      } else if (m is (double, Float32List?)) {
        playback._reported = Duration(microseconds: (m.$1 * 1e6).round());
        playback._since
          ..reset()
          ..start();
        if (m.$2 != null) playback.levels = m.$2!;
      } else if (m == #end) {
        playback.finished = true;
      }
    });
    try {
      final commands = await ready.future.timeout(const Duration(seconds: 10));
      playback = MidiDevicePlayback._(
          commands, events, isolate, Duration(microseconds: (file.duration * 1e6).round()), device);
      playback._handle = handle;
      playback._reported = from;
      playback._since.start();
      _current = playback;
      return playback;
    } catch (_) {
      events.close();
      isolate.kill(priority: Isolate.immediate);
      MidiOut.forceClose(device, handle);
      rethrow;
    }
  }

  /// Где сейчас трек (между отчётами изолята — по своим часам).
  Duration get position {
    if (_paused || finished) return _reported;
    final p = _reported + _since.elapsed;
    return p > length ? length : p;
  }

  void pause() {
    _reported = position;
    _paused = true;
    _commands.send(#pause);
  }

  void resume() {
    _paused = false;
    _since
      ..reset()
      ..start();
    _commands.send(#resume);
  }

  void seek(Duration to) {
    finished = false;
    _reported = to;
    _since
      ..reset()
      ..start();
    _commands.send(('seek', to.inMicroseconds / 1e6));
  }

  void setVolume(double v) => _commands.send(('volume', v));

  void setLoop(bool v) => _commands.send(('loop', v));

  /// Тишина, устройство закрывается, изолят выходит. Повторный вызов ждёт
  /// того же.
  Future<void> stop() => _stopFuture ??= _stopNow();

  Future<void> _stopNow() async {
    final stopping = _stopping = () async {
      final done = Completer<void>();
      final exit = ReceivePort();
      exit.listen((_) {
        if (!done.isCompleted) done.complete();
      });
      _isolate.addOnExitListener(exit.sendPort);
      _commands.send(#stop);
      await done.future.timeout(const Duration(seconds: 2), onTimeout: () {
        // Изолят не ответил: убить и закрыть устройство отсюда.
        _isolate.kill(priority: Isolate.immediate);
        MidiOut.forceClose(_device, _handle);
      });
      exit.close();
      _events.close();
    }();
    await stopping;
    if (identical(_current, this)) _current = null;
    if (identical(_stopping, stopping)) _stopping = null;
  }

  // --- Изолят ---

  static Future<void> _run(_Start s) async {
    MidiOut out;
    try {
      out = MidiOut.open(s.device);
    } catch (e) {
      s.reply.send('$e');
      return;
    }
    final player = MidiPlaybackCore(out, s.times.materialize().asFloat64List(), s.msgs.materialize().asInt32List(), s.duration,
        s.volume, s.loop);
    final commands = ReceivePort();
    s.reply.send((commands.sendPort, out.handle));
    var stopped = false;
    commands.listen((m) {
      switch (m) {
        case #pause:
          player.pause();
        case #resume:
          player.resume();
        case #stop:
          stopped = true;
        case ('seek', final double t):
          player.seek(t);
        case ('volume', final double v):
          player.setVolume(v);
        case ('loop', final bool v):
          player.loop = v;
      }
    });
    player.seek(s.from);
    var lastReport = -1.0;
    try {
      while (!stopped) {
        final now = player.step();
        if (player.ended) {
          s.reply.send(#end);
          player.ended = false;
        }
        // Отчёт ~30 раз в секунду: место и уровни полос.
        if (now - lastReport >= 0.033 || now < lastReport) {
          lastReport = now;
          s.reply.send((player.time, player.levels()));
        }
        // Сон до ближайшей ноты, но не дольше 2 мс: команды тоже нужно читать.
        await Future<void>.delayed(Duration(microseconds: (player.untilNext() * 1e6).clamp(500, 2000).round()));
      }
    } finally {
      out.close();
      commands.close();
    }
  }
}

class _Start {
  final SendPort reply;
  final String device;
  final TransferableTypedData times, msgs;
  final double duration, from, volume;
  final bool loop;
  _Start(this.reply, this.device, this.times, this.msgs, this.duration, this.from, this.volume, this.loop);
}

/// Состояние проигрывания в изоляте (открыт для тестов).
@visibleForTesting
class MidiPlaybackCore {
  final MidiOut out;
  final Float64List times;
  final Int32List msgs;
  final double duration;
  double volume;
  bool loop;

  MidiPlaybackCore(this.out, this.times, this.msgs, this.duration, this.volume, this.loop);

  final Stopwatch _clock = Stopwatch();
  double _offset = 0; // время трека в момент запуска часов
  int _next = 0;
  bool paused = false;
  bool ended = false;

  /// Громкость каналов из файла (CC7); отправляется умноженной на [volume].
  final List<int> _channelVolume = List.filled(16, 100);

  /// Звучащие ноты: канал*128+нота → сила.
  final Map<int, int> _notes = {};

  double get time => paused ? _offset : _offset + _clock.elapsedMicroseconds / 1e6;

  /// Отправляет всё, чему пришло время; текущее время трека.
  double step() {
    if (paused) return time;
    final t = time;
    while (_next < times.length && times[_next] <= t) {
      _send(msgs[_next++]);
    }
    if (_next >= times.length && t >= duration) {
      if (loop) {
        seek(0);
      } else if (!ended && !paused) {
        pause();
        _offset = duration;
        ended = true;
      }
    }
    return t;
  }

  /// Секунд до следующего события.
  double untilNext() => _next < times.length && !paused ? math.max(0, times[_next] - time) : 0.002;

  void _send(int m) {
    final status = m & 0xFF, a = (m >> 8) & 0x7F, b = (m >> 16) & 0x7F;
    final ch = status & 0x0F;
    switch (status & 0xF0) {
      case 0x90 when b > 0:
        _notes[ch * 128 + a] = b;
      case 0x80 || 0x90:
        _notes.remove(ch * 128 + a);
      case 0xB0 when a == 7:
        _channelVolume[ch] = b;
        out.send(status, a, (b * volume).round());
        return;
      case 0xB0 when a == 120 || a == 123:
        _notes.removeWhere((k, _) => k ~/ 128 == ch);
    }
    out.send(status, a, b);
  }

  void pause() {
    if (paused) return;
    _offset = time;
    _clock.stop();
    paused = true;
    out.silence();
    _notes.clear();
  }

  void resume() {
    if (!paused) return;
    paused = false;
    _clock
      ..reset()
      ..start();
  }

  /// К времени [t]: тишина, затем все не-нотные события до [t] (инструменты,
  /// контроллеры, высота тона) — как будто трек играл с начала.
  void seek(double t) {
    out.silence();
    _notes.clear();
    for (var ch = 0; ch < 16; ch++) {
      out.send(0xB0 | ch, 121, 0); // Reset All Controllers
      out.send(0xE0 | ch, 0, 0x40); // высота тона — по центру
      _channelVolume[ch] = 100;
    }
    var i = 0;
    while (i < times.length && times[i] < t) {
      final m = msgs[i++];
      final type = m & 0xF0;
      if (type == 0x80 || type == 0x90 || type == 0xA0) continue;
      _send(m);
    }
    for (var ch = 0; ch < 16; ch++) {
      out.send(0xB0 | ch, 7, (_channelVolume[ch] * volume).round());
    }
    _next = i;
    _offset = t;
    ended = false;
    _clock
      ..reset()
      ..start();
    if (paused) _clock.stop();
  }

  void setVolume(double v) {
    volume = v.clamp(0.0, 1.0);
    for (var ch = 0; ch < 16; ch++) {
      out.send(0xB0 | ch, 7, (_channelVolume[ch] * volume).round());
    }
  }

  /// Уровни полос: ноты 24…107 (C1…B7) по [MidiDevicePlayback.bars] полосам,
  /// сила — по самой громкой ноте полосы. Ударные (канал 10) — по всем низам.
  Float32List levels() {
    final out = Float32List(MidiDevicePlayback.bars);
    for (final MapEntry(key: k, value: v) in _notes.entries) {
      final ch = k ~/ 128, note = k % 128;
      final level = math.pow(v / 127, 0.7).toDouble() * (_channelVolume[ch] / 127);
      final bar = ch == 9
          ? (note % 8)
          : (((note - 24).clamp(0, 83)) * MidiDevicePlayback.bars ~/ 84);
      if (level > out[bar]) out[bar] = level;
    }
    return out;
  }
}
