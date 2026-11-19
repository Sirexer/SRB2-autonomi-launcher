import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:srb2_autonomi_launcher/services/midi_device_player.dart';
import 'package:srb2_autonomi_launcher/services/midi_out.dart';
import 'package:srb2_autonomi_launcher/services/midi_synth.dart';

class _Recorder extends MidiOut {
  final List<(int, int, int)> sent = [];
  @override
  int get handle => 0;
  @override
  void send(int status, int a, int b) => sent.add((status, a, b));
  @override
  void close() {}
}

int m(int status, int a, int b) => status | (a << 8) | (b << 16);

void main() {
  // Канал 0: инструмент 30 в 0 с, громкость 80, нота 60 в 1 с, отпущена в 2 с;
  // инструмент 40 в 3 с, нота 64 в 3.5 с.
  final times = Float64List.fromList([0, 0, 1, 2, 3, 3.5]);
  final msgs = Int32List.fromList([
    m(0xC0, 30, 0),
    m(0xB0, 7, 80),
    m(0x90, 60, 100),
    m(0x80, 60, 0),
    m(0xC0, 40, 0),
    m(0x90, 64, 127),
  ]);

  test('seeking replays instruments and controllers but not notes; volume scales CC7', () {
    final out = _Recorder();
    final core = MidiPlaybackCore(out, times, msgs, 4, 0.5, false);
    core.seek(3.2);
    // Тишина и сброс на всех каналах, затем инструменты до 3.2 с: 30 и 40, без нот.
    expect(out.sent.where((e) => e.$1 & 0xF0 == 0xC0).map((e) => e.$2), [30, 40]);
    expect(out.sent.where((e) => e.$1 & 0xF0 == 0x90), isEmpty);
    // Громкость канала 0: 80 × 0.5.
    expect(out.sent.lastWhere((e) => e == (0xB0, 7, 40) || (e.$1 == 0xB0 && e.$2 == 7 && e.$3 == 40)), (0xB0, 7, 40));
    out.sent.clear();
    core.setVolume(1);
    expect(out.sent.first, (0xB0, 7, 80));
  });

  test('notes are sent when their time comes; levels show the sounding note; the end is noticed', () async {
    final out = _Recorder();
    final core = MidiPlaybackCore(out, times, msgs, 3.6, 1, false);
    core.seek(3.45);
    out.sent.clear();
    expect(core.levels().every((v) => v == 0), isTrue);
    // Ждём ноту 64 (3.5 с).
    await Future<void>.delayed(const Duration(milliseconds: 80));
    core.step();
    expect(out.sent, contains((0x90, 64, 127)));
    final levels = core.levels();
    expect(levels.reduce((a, b) => a > b ? a : b), greaterThan(0.5));
    // До конца трека (3.6 с) — конец замечен, звучание остановлено.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    core.step();
    expect(core.ended, isTrue);
    expect(core.paused, isTrue);
    expect(core.time, 3.6);
  });

  test('with repeat the track starts again', () async {
    final core = MidiPlaybackCore(_Recorder(), times, msgs, 3.6, 1, true);
    core.seek(3.55);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    core.step();
    expect(core.ended, isFalse);
    expect(core.time, lessThan(0.1));
  });

  test('the next track waits until the previous one has closed the device', () async {
    final file = MidiFile([for (var i = 0; i < 6; i++) MidiEvent(times[i], msgs[i] & 0xFF, (msgs[i] >> 8) & 0x7F, (msgs[i] >> 16) & 0x7F)], 4);
    final first = await MidiDevicePlayback.start('null:', file);
    expect(MidiDevicePlayback.openCount, 1);
    // Сразу следующий трек: первый должен закрыть устройство до того, как
    // второй его откроет (иначе Windows: «занято»).
    final second = await MidiDevicePlayback.start('null:', file, from: const Duration(seconds: 1));
    expect(MidiDevicePlayback.openCount, 1);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(second.position, greaterThan(const Duration(seconds: 1)));
    await second.stop();
    await first.stop(); // уже остановлен — просто ждёт того же
    expect(MidiDevicePlayback.openCount, 0);
  });

  test('listing devices never throws (no MIDI here)', () {
    expect(MidiOut.devices, returnsNormally);
  });
}
