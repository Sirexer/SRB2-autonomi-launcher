import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:srb2_autonomi_launcher/services/ring_progress.dart';
import 'package:srb2_autonomi_launcher/services/ubjson.dart';

import 'map_preview_test.dart' show buildZip;

/// UBJSON, как его пишет Ring Racers (srb2::JsonValue::to_ubjson): объекты и
/// массивы с `#` (числом элементов), числа — D (double), строки — S U<длина>.
List<int> ubj(Object? v) {
  final out = <int>[];
  void str(String s) {
    final b = utf8.encode(s);
    out
      ..add(0x55) // U
      ..add(b.length)
      ..addAll(b);
  }

  void value(Object? v) {
    switch (v) {
      case null:
        out.add(0x5A);
      case bool b:
        out.add(b ? 0x54 : 0x46);
      case num n:
        out.add(0x44);
        out.addAll((ByteData(8)..setFloat64(0, n.toDouble())).buffer.asUint8List());
      case String s:
        out.add(0x53);
        str(s);
      case List l:
        out
          ..add(0x5B)
          ..add(0x23);
        value(l.length);
        // Число элементов — U, а не D.
        out.removeRange(out.length - 9, out.length);
        out
          ..add(0x55)
          ..add(l.length);
        for (final x in l) {
          value(x);
        }
      case Map m:
        out
          ..add(0x7B)
          ..add(0x23)
          ..add(0x55)
          ..add(m.length);
        for (final e in m.entries) {
          str(e.key as String);
          value(e.value);
        }
    }
  }

  value(v);
  return out;
}

void main() {
  test('UBJSON: optimized containers, typed arrays, unsized ones, numbers', () {
    expect(Ubjson.decode(Uint8List.fromList(ubj({'a': [1, true, 'x'], 'b': {'c': null}}))), {
      'a': [1.0, true, 'x'],
      'b': {'c': null},
    });
    // [$U#U3 1 2 3] и {i 5 } без размера.
    expect(Ubjson.decode(Uint8List.fromList([0x5B, 0x24, 0x55, 0x23, 0x55, 3, 1, 2, 3])), [1, 2, 3]);
    expect(Ubjson.decode(Uint8List.fromList([0x7B, 0x55, 1, 0x6B, 0x69, 0xFB, 0x7D])), {'k': -5});
    expect(() => Ubjson.decode(Uint8List.fromList([0x5B, 0x23, 0x55, 3, 0x54])), throwsFormatException);
  });

  test('ringdata.dat and ringprofiles.prf', () async {
    final dir = await Directory.systemTemp.createTemp('ring_');
    addTearDown(() => dir.delete(recursive: true));
    final data = {
      'playtime': {'total': 35 * 3600, 'race': 35 * 600},
      'rounds': {'race': 65, 'battle': 0},
      'rings': {'total': 38860},
      'challengekeys': {'chaokeys': 280},
      'unlockables': [true, false, true],
      'emblems': [false, true],
      'cups': {
        'RR_RING': {
          'name': 'RR_RING',
          'records': [
            {'bestplacement': 1, 'gotemerald': true, 'bestgrade': 5, 'bestskin': 'surge'},
            {'bestplacement': 0, 'gotemerald': false, 'bestgrade': 0, 'bestskin': ''},
          ],
        },
      },
      'maps': {
        'RR_GREENHILLS': {
          'visited': {'visited': true, 'beaten': true},
          'stats': {
            'timeattack': {'besttime': 3500, 'bestlap': 1100},
            'spbattack': {'besttime': 0, 'bestlap': 0},
            'time': {'total': 7000},
          },
        },
      },
      'skins': {
        'Surge': {
          'records': {'wins': 69, 'rounds': 89, 'time': {'total': 466507}},
        },
      },
    };
    File(p.join(dir.path, 'ringdata.dat')).writeAsBytesSync([0x21, 0xD3, 0x5E, 0xBA, 2, 0, ...ubj(data)]);
    File(p.join(dir.path, 'ringprofiles.prf')).writeAsBytesSync([
      ...ascii.encode('RINGPRFL'), 0, 0, 0, 0,
      ...ubj({
        'profiles': [
          {
            'profilename': 'PRFA', 'playername': 'Sirexer', 'skinname': 'surge', 'colorname': 'Scarlet',
            'followername': 'Tornado', 'records': {'wins': 478, 'rounds': 573},
            'secretkey': [1, 2, 3], // не читается
          },
        ],
      }),
    ]);
    final game = p.join(dir.path, 'scripts.pk3');
    File(game).writeAsBytesSync(buildZip([
      ('SOC/CUPS.soc', ascii.encode('Cup RR_RING\nRealName = Ring\nIcon = CUPRING\n'
          'LevelList = RR_GreenHills, RR_Other\n\nEmblem 2\nType = Time\nMapName = RR_GREENHILLS\nVar = 2*TICRATE\n\n'
          'Unlockable 1\nName = Sonic\nConditionSet = 1\n\nUnlockable 3\nName = Tails\n\n'
          'Level RR_GREENHILLS\nLevelName = Green Hills\n')),
    ]));

    final r = RingProgress.loadSync(dir.path, [game], const []);
    final d = r.data;
    expect((d.playTimeTotal, d.rounds['race'], d.totalRings, d.chaoKeys), (35 * 3600, 65, 38860, 280));
    expect((d.unlockedCount, d.emblemsCollected), (2, 1));
    expect(d.cups['RR_RING'], [(placement: 1, grade: 5, emerald: true, skin: 'surge'), null]);
    expect(ringGrade(5), 'S');
    final gh = d.maps['RR_GREENHILLS']!;
    expect((gh.visited, gh.beaten, gh.bestTime, gh.bestLap, gh.hasRecord), (true, true, 3500, 1100, true));
    expect(d.skins['surge'], (wins: 69, rounds: 89, time: 466507));

    expect(r.profiles.single.playerName, 'Sirexer');
    expect((r.profiles.single.skin, r.profiles.single.wins, r.profiles.single.rounds), ('surge', 478, 573));

    final cup = r.defs.cups.single;
    expect((cup.id, cup.title, cup.icon), ('RR_RING', 'Ring', 'CUPRING'));
    expect(cup.levels, ['RR_GREENHILLS', 'RR_OTHER']);
    expect(RingCup('RR_SNEAKER').title, 'Sneaker');
    final medal = r.defs.medalsOf('RR_GREENHILLS').single;
    expect((medal.number, medal.type, medal.target, d.collected(medal.number - 1)), (2, 'TIME', 70, true));
    expect(r.defs.challenges.length, 2);
    expect(r.defs.mapTitles['RR_GREENHILLS'], 'Green Hills');

    expect(() => RingData.parse(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7])), throwsFormatException);
  });
}
