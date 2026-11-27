import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:srb2_autonomi_launcher/services/map_preview.dart';
import 'package:srb2_autonomi_launcher/services/midi_synth.dart';
import 'package:srb2_autonomi_launcher/services/music.dart';
import 'package:srb2_autonomi_launcher/services/music_details.dart';
import 'package:srb2_autonomi_launcher/services/music_player.dart';
import 'package:srb2_autonomi_launcher/services/native_music.dart';

import 'map_preview_test.dart' show buildWad, buildZip;

List<int> _u32le(int v) => [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];
List<int> _u16le(int v) => [v & 0xFF, (v >> 8) & 0xFF];

/// Минимальный Ogg: страница с пакетом id Vorbis и страница с комментариями.
Uint8List fakeOgg(Map<String, String> tags, {int rate = 44100, int? granule}) {
  List<int> page(List<int> packet, int seq, [int pos = 0]) {
    final segs = <int>[];
    var left = packet.length;
    while (left >= 255) {
      segs.add(255);
      left -= 255;
    }
    segs.add(left);
    return [...ascii.encode('OggS'), 0, 0, ..._u32le(pos), ..._u32le(0), ...List.filled(4, 0), ..._u32le(seq), ...List.filled(4, 0), segs.length, ...segs, ...packet];
  }

  final id = [1, ...ascii.encode('vorbis'), ..._u32le(0), 2, ..._u32le(rate), ...List.filled(13, 0)];
  final comments = [
    3, ...ascii.encode('vorbis'), ..._u32le(4), ...ascii.encode('test'), ..._u32le(tags.length),
    for (final e in tags.entries) ...[..._u32le(utf8.encode('${e.key}=${e.value}').length), ...utf8.encode('${e.key}=${e.value}')],
    1,
  ];
  return Uint8List.fromList([
    ...page(id, 0),
    ...page(comments, 1),
    if (granule != null) ...page(List.filled(10, 0), 2, granule), // «звук» до позиции granule
  ]);
}

/// MIDI формата 0: темп 120 BPM (500000 мкс), 96 тиков на четверть,
/// нота 60 на четверть, затем нота 64 на четверть.
Uint8List fakeMidi() {
  final track = [
    0, 0xFF, 0x51, 3, 0x07, 0xA1, 0x20, // темп
    0, 0xC0, 0, // программа 0
    0, 0x90, 60, 100,
    96, 0x80, 60, 0,
    0, 0x90, 64, 100,
    96, 0x90, 64, 0, // note on с нулевой скоростью = note off
    0, 0xFF, 0x2F, 0,
  ];
  return Uint8List.fromList([
    ...ascii.encode('MThd'), 0, 0, 0, 6, 0, 0, 0, 1, 0, 96, //
    ...ascii.encode('MTrk'), ..._u32le(track.length).reversed, ...track,
  ]);
}

/// Минимальный SoundFont: один пресет (0:0) → один инструмент → один
/// сэмпл (меандр 441 Гц, петля по всему сэмплу). [unused] — ещё один сэмпл
/// такой длины, на который не ссылается ни один инструмент.
Uint8List fakeSf2({int unused = 0}) {
  List<int> chunk(String id, List<int> data) => [...ascii.encode(id), ..._u32le(data.length), ...data, if (data.length.isOdd) 0];
  List<int> list(String type, List<int> body) => chunk('LIST', [...ascii.encode(type), ...body]);
  List<int> name(String s) => [...ascii.encode(s), ...List.filled(20 - s.length, 0)];
  List<int> gen(int op, int amount) => [..._u16le(op), ..._u16le(amount & 0xFFFF)];

  const n = 1000; // 10 периодов по 100 сэмплов при 44100 Гц
  final smpl = <int>[
    for (var i = 0; i < n; i++) ..._u16le((10000 * (i % 100 < 50 ? 1 : -1)) & 0xFFFF),
    ...List.filled(46 * 2, 0),
    if (unused > 0) ...[for (var i = 0; i < unused; i++) ..._u16le(i & 0x7FFF), ...List.filled(46 * 2, 0)],
  ];
  final phdr = [
    ...name('Test'), ..._u16le(0), ..._u16le(0), ..._u16le(0), ...List.filled(12, 0),
    ...name('EOP'), ..._u16le(0), ..._u16le(0), ..._u16le(1), ...List.filled(12, 0),
  ];
  final pbag = [..._u16le(0), ..._u16le(0), ..._u16le(1), ..._u16le(0)];
  final pgen = [...gen(41, 0), ...gen(0, 0)];
  final inst = [...name('Square'), ..._u16le(0), ...name('EOI'), ..._u16le(1)];
  final ibag = [..._u16le(0), ..._u16le(0), ..._u16le(2), ..._u16le(0)];
  final igen = [...gen(54, 1), ...gen(53, 0), ...gen(0, 0)];
  final shdr = [
    ...name('sq'), ..._u32le(0), ..._u32le(n), ..._u32le(0), ..._u32le(n), ..._u32le(44100), 69, 0, ..._u16le(0), ..._u16le(1),
    if (unused > 0) ...[
      ...name('big'), ..._u32le(n + 46), ..._u32le(n + 46 + unused), ..._u32le(n + 46), ..._u32le(n + 46 + unused),
      ..._u32le(44100), 60, 0, ..._u16le(0), ..._u16le(1),
    ],
    ...name('EOS'), ...List.filled(26, 0),
  ];
  final body = [
    ...ascii.encode('sfbk'),
    ...list('INFO', chunk('ifil', [2, 0, 1, 0])),
    ...list('sdta', chunk('smpl', smpl)),
    ...list('pdta', [
      ...chunk('phdr', phdr), ...chunk('pbag', pbag), ...chunk('pmod', List.filled(10, 0)), ...chunk('pgen', pgen),
      ...chunk('inst', inst), ...chunk('ibag', ibag), ...chunk('imod', List.filled(10, 0)), ...chunk('igen', igen),
      ...chunk('shdr', shdr),
    ]),
  ];
  return Uint8List.fromList(chunk('RIFF', body));
}

double _rms(Int16List pcm, int from, int to) {
  var sum = 0.0;
  for (var i = from; i < to; i++) {
    sum += pcm[i] * pcm[i].toDouble();
  }
  return (sum / (to - from)).abs();
}

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('music_'));
  tearDown(() => dir.delete(recursive: true));

  test('MUSICDEF of SRB2 2.2', () {
    final defs = MusicScanner.parseMusicDef(File('test/fixtures/musicdef.txt').readAsStringSync());
    expect(defs['GFZ1']!.title, 'Greenflower 1');
    expect(defs['GFZ1']!.authors, startsWith('clairebun, Shane Strife'));
    expect(defs['_TITLE']!.title, 'Titlescreen');
    expect(defs.values.any((d) => d.altTitle == 'Castle Eggman 1'), isTrue);
    expect(defs.length, greaterThan(60));
    // Несколько имён и приставка O_.
    final multi = MusicScanner.parseMusicDef('Lump O_AAA,BBB\nTitle = Two_Names\n');
    expect(multi.keys, ['AAA', 'BBB']);
  });

  test('WAD: O_/D_ lumps and M_START..M_END, PK3: Music/ with subfolders, MUSICDEF titles', () async {
    final wad = p.join(dir.path, 'music.wad');
    await File(wad).writeAsBytes(buildWad([
      ('MUSICDEF', ascii.encode('Lump GFZ1\nTitle = Greenflower_1\nAuthors = clairebun\n')),
      ('O_GFZ1', fakeOgg({})),
      ('D_BOSS', fakeMidi()),
      ('M_START', []),
      ('INTRO', fakeOgg({})),
      ('JUNK', ascii.encode('not music')), // нераспознанное — не показываем
      ('M_END', []),
      ('PLAYPAL', List.filled(768, 0)),
    ]));
    final pk3 = p.join(dir.path, 'pack.pk3');
    await File(pk3).writeAsBytes(buildZip([
      ('Music/Zone1/O_THZ1.ogg', fakeOgg({'LOOPMS': '1500'})),
      ('Music/D_FUN.mid', fakeMidi()),
      ('Sounds/DSJUMP.ogg', fakeOgg({})), // не музыка
      ('Textures/AltDashPad/D_0_MN1.lmp', ascii.encode('Doom patch texture data')), // текстура с D_, не музыка
    ]));
    final tracks = MusicScanner.scan([wad, pk3]);
    expect(tracks.map((t) => t.lump), ['GFZ1', 'BOSS', 'INTRO', 'THZ1', 'FUN']);
    expect(tracks.first.title, 'Greenflower 1');
    expect(tracks.first.format, MusicFormat.ogg); // lump без расширения — по первым байтам
    expect(tracks.first.authors, 'clairebun');
    expect(tracks[1].format, MusicFormat.midi);
    expect(tracks[3].format, MusicFormat.ogg);

    final data = MusicScanner.load(tracks[3]);
    expect(data.format, MusicFormat.ogg);
    expect(data.loopStart, const Duration(milliseconds: 1500));
    expect(MusicScanner.load(tracks[1]).format, MusicFormat.midi);
  });

  test('head of a deflated zip entry without reading all of it', () {
    // Несжимаемые данные: сжатая запись больше, чем читается для заголовка.
    var x = 12345;
    final big = Uint8List.fromList([
      ...ascii.encode('OggS'),
      for (var i = 0; i < 200000; i++) (x = (x * 1103515245 + 12345) & 0x7FFFFFFF) >> 16 & 0xFF,
    ]);
    final pk3 = p.join(dir.path, 'big.pk3');
    File(pk3).writeAsBytesSync(buildZip([('Music/O_BIG', big), ('Music/O_SMALL', fakeOgg({}))]));
    final a = AddonArchive.open(pk3)!;
    try {
      expect(a.entries.first.compressedSize, greaterThan(2048 * 16 + 1024));
      expect(a.readHead(a.entries.first, 2048), big.sublist(0, 2048));
      expect(a.readHead(a.entries.last, 2048), fakeOgg({}));
    } finally {
      a.close();
    }
    final tracks = MusicScanner.scan([pk3]);
    expect(tracks.map((t) => t.format), [MusicFormat.ogg, MusicFormat.ogg]);
  });

  test('player list: search, hidden formats, A-Z sort by file groups', () {
    MusicTrack t(String file, String lump, {String title = '', MusicFormat f = MusicFormat.ogg}) =>
        MusicTrack(file: file, entry: lump, lump: lump, title: title, format: f);
    final tracks = [
      t('/g/zones.pk3', 'THZ2', title: 'Techno Hill 2'),
      t('/g/zones.pk3', 'GFZ10', title: 'Greenflower 10'),
      t('/g/zones.pk3', 'GFZ2', title: 'Greenflower 2'),
      t('/a/Addon.wad', 'BOSS', f: MusicFormat.midi),
      t('/a/Addon.wad', 'ACT1', title: 'Zeta'),
    ];
    List<String> lumps(List<MusicTrack> l) => [for (final x in l) x.lump];
    expect(lumps(arrangeTracks(tracks)), ['THZ2', 'GFZ10', 'GFZ2', 'BOSS', 'ACT1']);
    expect(lumps(arrangeTracks(tracks, sort: MusicSort.title)), ['BOSS', 'ACT1', 'GFZ2', 'GFZ10', 'THZ2']);
    expect(lumps(arrangeTracks(tracks, sort: MusicSort.lump)), ['ACT1', 'BOSS', 'GFZ2', 'GFZ10', 'THZ2']);
    expect(lumps(arrangeTracks(tracks, hidden: {MusicFormat.midi})), ['THZ2', 'GFZ10', 'GFZ2', 'ACT1']);
    expect(lumps(arrangeTracks(tracks, query: 'greenflower')), ['GFZ10', 'GFZ2']);
    expect(lumps(arrangeTracks(tracks, query: 'addon')), ['BOSS', 'ACT1']);
    expect(naturalCompare('Act 2', 'act 10'), lessThan(0));

    // Разделы (игра, категория) — в порядке появления, и при сортировке тоже.
    final mixed = [
      t('/srb2/zones.pk3', 'GFZ1').withSource('srb2', MusicCategory.game),
      t('/srb2/DOWNLOAD/b.pk3', 'B').withSource('srb2', MusicCategory.addons),
      t('/srb2/DOWNLOAD/a.pk3', 'A').withSource('srb2', MusicCategory.addons),
      t('/kart/music.kart', 'KART').withSource('srb2kart', MusicCategory.game),
      t('/home/x.ogg', 'X').withSource('', MusicCategory.opened),
    ];
    expect(lumps(arrangeTracks(mixed, sort: MusicSort.title)), ['GFZ1', 'A', 'B', 'KART', 'X']);
    expect(lumps(arrangeTracks(mixed, query: 'srb2kart', gameNames: {'srb2kart': 'SRB2Kart'})), ['KART']);
    expect(mixed[1].section, isNot(mixed[0].section));
    expect(naturalCompare('MAP01', 'MAP1'), 0);
  });

  test('loop points: LOOPMS, LOOPPOINT in samples, COMMENT', () {
    expect(MusicScanner.loopFromTags({'LOOPMS': '30250'}, 44100), const Duration(milliseconds: 30250));
    expect(MusicScanner.loopFromTags({'LOOPPOINT': '1334025'}, 44100), const Duration(microseconds: 30250000));
    expect(MusicScanner.loopFromTags({'COMMENT': 'LOOPPOINT=44100'}, 44100), const Duration(seconds: 1));
    expect(MusicScanner.loopFromTags({}, 44100), isNull);
    expect(MusicScanner.loopPoint(fakeOgg({'LOOPPOINT': '48000'}, rate: 48000), MusicFormat.ogg), const Duration(seconds: 1));
  });

  test('format detection', () {
    Uint8List b(List<int> x) => Uint8List.fromList([...x, ...List.filled(1200, 0)]);
    expect(MusicScanner.detectFormat(fakeOgg({})), MusicFormat.ogg);
    expect(MusicScanner.detectFormat(fakeMidi()), MusicFormat.midi);
    expect(MusicScanner.detectFormat(b(ascii.encode('fLaC'))), MusicFormat.flac);
    expect(MusicScanner.detectFormat(b(ascii.encode('ID3'))), MusicFormat.mp3);
    expect(MusicScanner.detectFormat(b(ascii.encode('Extended Module: x'))), MusicFormat.xm);
    expect(MusicScanner.detectFormat(b(ascii.encode('IMPM'))), MusicFormat.it);
    expect(MusicScanner.detectFormat(b([...List.filled(44, 0), ...ascii.encode('SCRM')])), MusicFormat.s3m);
    expect(MusicScanner.detectFormat(b([...List.filled(1080, 0), ...ascii.encode('M.K.')])), MusicFormat.mod);
    expect(MusicScanner.detectFormat(b(ascii.encode('SNES-SPC700 Sound File'))), MusicFormat.spc);
    expect(MusicScanner.detectFormat(b(ascii.encode('Vgm '))), MusicFormat.vgm);
    expect(MusicScanner.detectFormat(b([0x1F, 0x8B])), MusicFormat.vgz);
    expect(MusicScanner.detectFormat(b(ascii.encode('NESM\x1A'))), MusicFormat.nsf);
    expect(MusicScanner.formatFromExtension('it'), MusicFormat.it);
    expect(MusicScanner.formatFromExtension('vgz'), MusicFormat.vgz);
    expect(MusicFormat.opus.playable, isFalse);
    expect(MusicFormat.ogg.playable, isTrue);
    expect(MusicFormat.xm.playable && MusicFormat.xm.isTracker && !MusicFormat.xm.isGme, isTrue);
    expect(MusicFormat.vgz.isGme && MusicFormat.spc.isGme && MusicFormat.ay.isGme, isTrue);
    expect(MusicFormat.mus.isSynth && MusicFormat.midi.isSynth, isTrue);
    expect(MusicFormat.it.label, 'IT');
    expect(MusicFormat.it.extension, 'wav'); // в движок идёт уже отрисованным
  });

  test('MIDI: tempo, running status, note off by velocity 0', () {
    final m = MidiFile.parse(fakeMidi());
    final notes = m.events.where((e) => e.type == 0x90 || e.type == 0x80).toList();
    expect(notes.map((e) => e.time), [0.0, 0.5, 0.5, 1.0]);
    expect(m.duration, 1.0);
  });

  test('MIDI: SysEx before the tempo and between notes does not shift the track', () {
    // Как в D_S1CNTI: сброс GS в начале дорожки, затем темп 240 BPM.
    const gsReset = [0xF0, 10, 0x41, 0x10, 0x42, 0x12, 0x40, 0x00, 0x7F, 0x00, 0x41, 0xF7];
    final track = [
      0, ...gsReset,
      0, 0xFF, 0x51, 3, 0x03, 0xD0, 0x90, // 250000 мкс на четверть
      0, 0x90, 60, 100,
      96, 0x80, 60, 0,
      0, ...gsReset, // посреди нот
      0, 0x90, 64, 100,
      96, 0x80, 64, 0,
      0, 0xFF, 0x2F, 0,
    ];
    final m = MidiFile.parse(Uint8List.fromList([
      ...ascii.encode('MThd'), 0, 0, 0, 6, 0, 0, 0, 1, 0, 96, //
      ...ascii.encode('MTrk'), ..._u32le(track.length).reversed, ...track,
    ]));
    expect([for (final e in m.events) (e.time, e.status, e.a)],
        [(0.0, 0x90, 60), (0.25, 0x80, 60), (0.25, 0x90, 64), (0.5, 0x80, 64)]);
  });

  test('old scan cache: MIDI and MUS durations are read again, others kept', () {
    final info = MusicFileInfo(
      tracks: const [('D_A', 'D_A', MusicFormat.midi), ('O_B', 'O_B', MusicFormat.ogg), ('D_C', 'D_C', MusicFormat.mus)],
      details: {
        'D_A': const TrackDetails(durationMs: 7385000),
        'O_B': const TrackDetails(durationMs: 60000),
        'D_C': const TrackDetails(durationMs: 1000),
      },
    );
    MusicPlayer.dropSynthDetails(info);
    expect(info.details.keys, ['O_B']);
  });

  test('Doom MUS converts to MIDI events', () {
    final mus = Uint8List.fromList([
      ...ascii.encode('MUS'), 0x1A, ..._u16le(10), ..._u16le(16), ..._u16le(1), ..._u16le(0), ..._u16le(0), ..._u16le(0),
      0x1F, 36, // ударные (канал 15 → 10-й канал MIDI), громкость по умолчанию
      0x90, 0x80 | 60, 110, 70, // нота с громкостью, потом пауза 70 тиков (0.5 с)
      0x80, 60, 70, // отпустить, пауза
      0x60, // конец партитуры
    ]);
    expect(MusicScanner.detectFormat(mus), MusicFormat.mus);
    final m = MidiFile.parse(mus);
    expect([for (final e in m.events) (e.time, e.status, e.a, e.b)], [
      (0.0, 0x99, 36, 100),
      (0.0, 0x90, 60, 110),
      (0.5, 0x80, 60, 0),
    ]);
    expect(m.duration, 1.0);
    expect(_rms(MidiRenderer.render(m, null), 0, 44100), greaterThan(1000));
  });

  test('MIDI renders with the built-in synth and with a SoundFont', () {
    final simple = MidiRenderer.render(MidiFile.parse(fakeMidi()), null);
    expect(simple.length, greaterThan(44100 * 2 * 2)); // 1 с + хвост, стерео
    expect(_rms(simple, 0, 44100), greaterThan(1000)); // звучит
    expect(_rms(simple, simple.length - 2000, simple.length), lessThan(10)); // затихло

    final font = SoundFont.parse(fakeSf2());
    final sf = MidiRenderer.render(MidiFile.parse(fakeMidi()), font);
    expect(_rms(sf, 0, 44100), greaterThan(1000));

    final wav = MidiRenderer.wav(simple, 44100, 2);
    expect(ascii.decode(wav.sublist(0, 4)), 'RIFF');
    expect(MusicScanner.detectFormat(wav), MusicFormat.wav);
  });

  test('SoundFont from a file reads only the samples that sound', () async {
    final path = p.join(dir.path, 'big.sf2');
    await File(path).writeAsBytes(fakeSf2(unused: 300000));
    final font = SoundFont.load(path);
    try {
      expect(font.loadedSamples, 0);
      final pcm = MidiRenderer.render(MidiFile.parse(fakeMidi()), font);
      expect(_rms(pcm, 0, 44100), greaterThan(1000));
      expect(font.loadedSamples, 1001); // сэмпл и нулевой разделитель после него
      // Тот же звук, что из байтов в памяти.
      expect(pcm, MidiRenderer.render(MidiFile.parse(fakeMidi()), SoundFont.parse(fakeSf2())));
    } finally {
      font.close();
    }

    // В отдельном изоляте — с прогрессом, результат тот же.
    final progress = <double>[];
    final wav = await MidiRenderer.renderToWavInBackground(fakeMidi(), path, onProgress: progress.add);
    expect(progress, isNotEmpty);
    expect(progress.every((x) => x >= 0 && x < 1), isTrue);
    final again = SoundFont.load(path);
    try {
      expect(wav, MidiRenderer.renderToWav(fakeMidi(), again));
    } finally {
      again.close();
    }
    // Не SoundFont — понятная ошибка, а не зависание.
    await expectLater(
      MidiRenderer.renderToWavInBackground(fakeMidi(), p.join(dir.path, 'missing.sf2')),
      throwsA(anything),
    );
  });

  test('MUSICDEF of the game does not rename an addon track; levels of a track', () {
    final game = p.join(dir.path, 'srb2.pk3');
    File(game).writeAsBytesSync(buildZip([
      ('MUSICDEF', ascii.encode('Lump _TITLE\nTitle = Titlescreen\nAuthors = Vanilla\n\nLump GFZ1\nTitle = Greenflower_1\n')),
      ('Music/O__TITLE.ogg', fakeOgg({})),
      ('Music/O_GFZ1.ogg', fakeOgg({})),
      ('SOC/levels.soc', ascii.encode('Level 1\nLevelname = Greenflower Zone\nAct = 1\nMusic = O_GFZ1\n\n'
          'Level 2\nLevelname = Greenflower Zone\nAct = 2\nMusic = GFZ2\n')),
    ]));
    final addon = p.join(dir.path, 'addon.wad');
    File(addon).writeAsBytesSync(buildWad([
      ('O__TITLE', fakeOgg({})), // замена без своего MUSICDEF
      ('O_GFZ1', fakeOgg({})),
      ('O_MYSONG', fakeOgg({})),
      ('MAINCFG', ascii.encode('Level 2\nMusic = MYSONG\n')),
    ]));
    final sources = [
      MusicSource(game, 'srb2', MusicCategory.game),
      MusicSource(addon, 'srb2', MusicCategory.addons),
    ];
    final infos = {for (final s in sources) s.path: MusicScanner.scanFile(s.path)};
    final tracks = MusicLibrary.compose(sources, infos);
    MusicTrack find(String file, String lump) => tracks.firstWhere((t) => t.file == file && t.lump == lump);
    expect(find(game, '_TITLE').title, 'Titlescreen');
    expect(find(game, '_TITLE').authors, 'Vanilla');
    expect(find(addon, '_TITLE').title, ''); // не «Titlescreen» из файлов игры
    expect(find(addon, '_TITLE').displayAuthors, '');
    expect(find(addon, 'GFZ1').category, MusicCategory.addons);

    List<(String, String, bool)> levels(MusicTrack t) =>
        [for (final l in MusicLibrary.levelsOf(t, sources, infos)) (l.map, l.title, l.fromTrackFile)];
    expect(levels(find(game, 'GFZ1')), [('MAP01', 'Greenflower Zone 1', false)]);
    expect(levels(find(addon, 'GFZ1')), [('MAP01', 'Greenflower Zone 1', false)]); // заменяет музыку уровня игры
    expect(levels(find(addon, 'MYSONG')), [('MAP02', 'Greenflower Zone 2', true)]); // аддон сменил музыку MAP02
    expect(levels(find(game, '_TITLE')), isEmpty);

    // Сведения о файле переживают сохранение в кэш.
    final again = MusicFileInfo.fromJson(jsonDecode(jsonEncode(infos[game]!.toJson())) as Map<String, Object?>);
    expect(again.tracks, infos[game]!.tracks);
    expect(again.defs['_TITLE']!.authors, 'Vanilla');
    expect(again.levelMusic['MAP01'], ['GFZ1']);
    expect(again.levelTitles['MAP02'], 'Greenflower Zone 2');
    final withDetails = MusicFileInfo(details: {'#0': const TrackDetails(durationMs: 1234, title: 'T', subtracks: 3)});
    final d = MusicFileInfo.fromJson(jsonDecode(jsonEncode(withDetails.toJson())) as Map<String, Object?>).details['#0']!;
    expect((d.durationMs, d.title, d.subtracks), (1234, 'T', 3));
  });

  test('an unreadable MUSICDEF does not hide the tracks of the file', () {
    // MUSICDEF «сжат» неизвестным методом (12 — bzip2): прочитать его нельзя.
    final zip = buildZip([('MUSICDEF', ascii.encode('Lump GFZ1\nTitle = X\n')), ('Music/O_GFZ1.ogg', fakeOgg({}))]);
    final central = zip.length - 22 - (46 + 8) - (46 + 16);
    ByteData.sublistView(zip).setUint16(central + 10, 12, Endian.little); // метод в центральном каталоге
    final path = p.join(dir.path, 'music.pk3');
    File(path).writeAsBytesSync(zip);
    final tracks = MusicScanner.scan([path]);
    expect(tracks.map((t) => t.lump), ['GFZ1']);
    expect(tracks.single.title, ''); // названия нет, но трек есть
  });

  test('duplicates are looked for within one game only', () {
    final song = fakeOgg({'TITLE': 'Same'});
    final modern = p.join(dir.path, 'music.pk3');
    File(modern).writeAsBytesSync(buildZip([('Music/O_MAP01M.ogg', song)]));
    final legacy = p.join(dir.path, 'music.dta');
    File(legacy).writeAsBytesSync(buildWad([('O_MAP01M', song), ('O_COPY', song)]));
    final sources = [
      MusicSource(modern, 'srb2', MusicCategory.game),
      MusicSource(legacy, 'srb2legacy', MusicCategory.game),
    ];
    final tracks = MusicLibrary.compose(sources, {for (final s in sources) s.path: MusicScanner.scanFile(s.path)});
    // Копия в другой игре видна, копия в той же игре — скрыта.
    expect([for (final t in arrangeTracks(tracks, hideDuplicates: true)) (p.basename(t.file), t.lump)],
        [('music.pk3', 'MAP01M'), ('music.dta', 'MAP01M')]);
  });

  test('duplicates: the same music in several files is shown once', () {
    final song = fakeOgg({'TITLE': 'Same'});
    final v1 = p.join(dir.path, 'Pack-v1.pk3');
    File(v1).writeAsBytesSync(buildZip([('Music/O_SONG.ogg', song), ('Music/O_OLD.ogg', fakeOgg({'TITLE': 'Old'}))]));
    final v2 = p.join(dir.path, 'Pack-v2.pk3');
    File(v2).writeAsBytesSync(buildZip([('Music/O_SONG.ogg', song)]));
    final wad = p.join(dir.path, 'copy.wad');
    File(wad).writeAsBytesSync(buildWad([('O_RENAME', song)]));
    final opened = p.join(dir.path, 'opened.wad');
    File(opened).writeAsBytesSync(buildWad([('O_SONG', song)]));
    final sources = [
      MusicSource(v1, 'srb2', MusicCategory.downloads),
      MusicSource(v2, 'srb2', MusicCategory.downloads),
      MusicSource(wad, 'srb2', MusicCategory.folder),
      MusicSource(opened, '', MusicCategory.opened),
    ];
    final infos = {for (final s in sources) s.path: MusicScanner.scanFile(s.path)};
    final tracks = MusicLibrary.compose(sources, infos);
    MusicTrack find(String file, String lump) => tracks.firstWhere((t) => t.file == file && t.lump == lump);
    // PK3 и WAD — один отпечаток (размер и CRC-32 содержимого).
    expect(find(v1, 'SONG').fingerprint, isNotEmpty);
    expect(find(v2, 'SONG').fingerprint, find(v1, 'SONG').fingerprint);
    expect(find(wad, 'RENAME').fingerprint, find(v1, 'SONG').fingerprint);
    expect(find(v1, 'OLD').fingerprint, isNot(find(v1, 'SONG').fingerprint));

    List<(String, String)> shown(List<MusicTrack> list) => [for (final t in list) (p.basename(t.file), t.lump)];
    // Остаётся более новая версия (v2), копии в других разделах скрыты; открытые вручную — нет.
    expect(shown(arrangeTracks(tracks, hideDuplicates: true)),
        [('Pack-v1.pk3', 'OLD'), ('Pack-v2.pk3', 'SONG'), ('opened.wad', 'SONG')]);
    expect(arrangeTracks(tracks).length, 5);
    // Поиск по имени файла находит и его копию.
    expect(shown(arrangeTracks(tracks, hideDuplicates: true, query: 'v1')), [('Pack-v1.pk3', 'SONG'), ('Pack-v1.pk3', 'OLD')]);
    expect(duplicateTrackKeys(tracks), {find(v1, 'SONG').key, find(wad, 'RENAME').key});
    // Избранное не скрывается и остаётся вместо своих копий.
    expect(duplicateTrackKeys(tracks, keep: {find(v1, 'SONG').key}), {find(v2, 'SONG').key, find(wad, 'RENAME').key});
    expect(duplicateTrackKeys(tracks, keep: {find(v1, 'SONG').key, find(wad, 'RENAME').key}), {find(v2, 'SONG').key});

    final again = MusicFileInfo.fromJson(jsonDecode(jsonEncode(infos[wad]!.toJson())) as Map<String, Object?>);
    expect(again.fingerprints, infos[wad]!.fingerprints);
  });

  test('SOC level music: Music and old MusicSlot', () {
    final info = MapScanner.parseSocInfo('Level 1\nLevelname = A\nMusic = O_GFZ1\n\nLevel 2\nMusicSlot = 5\n\n'
        'Level RR_TEST\nMusic = RRA, RRB\n');
    expect(info.music['MAP01'], ['GFZ1']);
    expect(info.music['MAP02'], ['MAP05M']);
    expect(info.music['RR_TEST'], ['RRA', 'RRB']);

    final more = MapScanner.parseSocInfo('Level 3\nMusic = NONE\n\nLevel RR_TEST\nMusic = RRA\nEncoreMusic = RRAE, RRBE\n');
    expect(more.music['MAP03'], isEmpty); // тишина, а не MAP03M
    expect(more.encoreMusic['RR_TEST'], ['RRAE', 'RRBE']);
  });

  test('level music: MAPxxM by default, Music = NONE, Encore', () {
    final kart = p.join(dir.path, 'pack.pk3');
    File(kart).writeAsBytesSync(buildZip([
      ('Maps/MAPY8.wad', buildWad([('MAPY8', []), ('THINGS', [0])])),
      ('Music/O_MAPY8M.ogg', fakeOgg({})),
      ('Music/O_MAPY8E.ogg', fakeOgg({})),
      ('Music/O_MAPY9M.ogg', fakeOgg({})),
      ('SOC/levels.soc', ascii.encode('Level Y8\nLevelName = Killer Skies\nTypeOfLevel = Race\n\n'
          'Level Y9\nLevelName = Quiet Zone\nMusic = NONE\n')),
    ]));
    final rr = p.join(dir.path, 'rr.pk3');
    File(rr).writeAsBytesSync(buildZip([
      ('Maps/MAP01.wad', buildWad([('MAP01', []), ('THINGS', [0])])),
      ('Music/O_MAP01M.ogg', fakeOgg({})),
      ('Music/O_RRA.ogg', fakeOgg({})),
      ('Music/O_RRAE.ogg', fakeOgg({})),
      ('SOC/levels.soc', ascii.encode('Level RR_TEST\nLevelName = Test Run\nMusic = RRA\nEncoreMusic = RRAE\n')),
    ]));
    final sources = [
      MusicSource(kart, 'srb2kart', MusicCategory.addons),
      MusicSource(rr, 'drrr', MusicCategory.addons),
    ];
    final infos = {for (final s in sources) s.path: MusicScanner.scanFile(s.path)};
    final tracks = MusicLibrary.compose(sources, infos);
    List<(String, String, bool, bool)> levels(String file, String lump) => [
          for (final l in MusicLibrary.levelsOf(tracks.firstWhere((t) => t.file == file && t.lump == lump), sources, infos))
            (l.map, l.title, l.encore, l.byName),
        ];
    expect(levels(kart, 'MAPY8M'), [('MAPY8', 'Killer Skies', false, false)]); // Music не задан — MAPY8M
    expect(levels(kart, 'MAPY8E'), [('MAPY8', 'Killer Skies', true, true)]); // Encore только по имени
    expect(levels(kart, 'MAPY9M'), isEmpty); // Music = NONE
    expect(levels(rr, 'MAP01M'), isEmpty); // у Ring Racers музыки по умолчанию нет
    expect(levels(rr, 'RRA'), [('RR_TEST', 'Test Run', false, false)]);
    expect(levels(rr, 'RRAE'), [('RR_TEST', 'Test Run', true, false)]);

    final again = MusicFileInfo.fromJson(jsonDecode(jsonEncode(infos[rr]!.toJson())) as Map<String, Object?>);
    expect(again.levelEncore['RR_TEST'], ['RRAE']);
  });

  test('durations from headers: WAV, OGG, FLAC, MP3, MIDI', () {
    final wav = MidiRenderer.wav(Int16List(44100 * 2), 44100, 2);
    expect(MusicScanner.durationMs(wav, MusicFormat.wav), 1000);
    expect(MusicScanner.durationMs(fakeOgg({}, granule: 88200), MusicFormat.ogg), 2000);
    expect(MusicScanner.durationMs(fakeOgg({}), MusicFormat.ogg), isNull); // позиции нет

    final flac = Uint8List(42);
    flac.setAll(0, ascii.encode('fLaC'));
    flac.setAll(4, [0x80, 0, 0, 34]); // последний блок, STREAMINFO
    // 44100 Гц (20 бит), 2 канала, 16 бит, 88200 сэмплов.
    flac.setAll(18, [0x0A, 0xC4, 0x42, 0xF0, 0x00, 0x01, 0x58, 0x88]);
    expect(MusicScanner.durationMs(flac, MusicFormat.flac), 2000);

    // MPEG1 Layer III 128 кбит/с, 44100 Гц: 16000 байт — 1 с.
    final mp3 = Uint8List(16000)..setAll(0, [0xFF, 0xFB, 0x90, 0x00]);
    expect(MusicScanner.durationMs(mp3, MusicFormat.mp3), 1000);
    expect(MusicScanner.detectFormat(mp3), MusicFormat.mp3);

    expect(MusicDetails.of(fakeMidi(), MusicFormat.midi)!.durationMs, 1000);
    expect(MusicDetails.of(fakeOgg({}, granule: 44100), MusicFormat.ogg)!.durationMs, 1000);
    expect(MusicDetails.of(Uint8List.fromList(ascii.encode('IMPM')), MusicFormat.it), isNull); // без libopenmpt — потом
  });

  // Рендер библиотеками игры — если они есть в системе (в CI ставятся
  // пакеты libgme0 и libopenmpt0), иначе тест пропускается.
  test('VGM through libgme', () async {
    final lib = NativeMusic.find(NativeLib.gme, const []);
    if (lib == null) {
      markTestSkipped('libgme not found');
      return;
    }
    // VGM 1.50: SN76489, тон на канале 0 одну секунду.
    final data = [0x50, 0x8F, 0x50, 0x06, 0x50, 0x90, 0x61, 0x44, 0xAC, 0x66];
    final head = ByteData(0x40)
      ..setUint32(0x00, 0x206D6756, Endian.little) // 'Vgm '
      ..setUint32(0x04, 0x40 + data.length - 4, Endian.little)
      ..setUint32(0x08, 0x150, Endian.little)
      ..setUint32(0x0C, 3579545, Endian.little)
      ..setUint32(0x18, 44100, Endian.little)
      ..setUint32(0x34, 0x40 - 0x34, Endian.little);
    final vgm = Uint8List.fromList([...head.buffer.asUint8List(), ...data]);
    expect(MusicScanner.detectFormat(vgm), MusicFormat.vgm);
    for (final bytes in [vgm, Uint8List.fromList(gzip.encode(vgm))]) {
      final progress = <double>[];
      final (wav, loop) =
          await NativeMusic.renderInBackground(bytes, MusicFormat.vgm, lib, onProgress: progress.add);
      expect(MusicScanner.detectFormat(wav), MusicFormat.wav);
      expect(loop, isNull); // петли в файле нет
      final pcm = Int16List.sublistView(wav, 44);
      expect(pcm.length, closeTo(44100 * 2, 2048));
      expect(_rms(pcm, 0, pcm.length), greaterThan(1000));
      expect(progress, isNotEmpty);
    }
  });

  test('MOD through libopenmpt', () async {
    final lib = NativeMusic.find(NativeLib.openmpt, const []);
    if (lib == null) {
      markTestSkipped('libopenmpt not found');
      return;
    }
    // ProTracker: 1 сэмпл (меандр, петля), 1 паттерн 64 строки, нота в первой.
    final mod = Uint8List(1084 + 1024 + 64);
    final bd = ByteData.sublistView(mod);
    mod.setAll(0, ascii.encode('test'));
    bd
      ..setUint16(20 + 22, 32) // длина сэмпла в словах (big-endian)
      ..setUint8(20 + 25, 64) // громкость
      ..setUint16(20 + 28, 32); // длина петли в словах
    mod[950] = 1; // длина песни
    mod[951] = 127;
    mod.setAll(1080, ascii.encode('M.K.'));
    mod.setAll(1084, [0x01, 0xAC, 0x10, 0x00]); // сэмпл 1, период 428 (C-2)
    for (var i = 0; i < 64; i++) {
      mod[1084 + 1024 + i] = i < 32 ? 100 : 156; // ±100 (signed 8 бит)
    }
    expect(MusicScanner.detectFormat(mod), MusicFormat.mod);
    final (wav, loop) = await NativeMusic.renderInBackground(mod, MusicFormat.mod, lib);
    expect(loop, isNull);
    final pcm = Int16List.sublistView(wav, 44);
    // 64 строки × 6 тиков при 125 BPM = 7.68 с.
    expect(pcm.length / 2 / 44100, closeTo(7.68, 0.2));
    expect(_rms(pcm, 0, 44100), greaterThan(1000));
  });

  test('export names and extensions', () {
    const t = MusicTrack(file: '/a/addon.pk3', entry: 'Music/O_GFZ1.ogg', lump: 'GFZ1', title: 'Greenflower: 1?');
    expect(MusicPlayer.exportFileName(t), 'GFZ1 - Greenflower_ 1_');
    expect(MusicPlayer.exportFileName(const MusicTrack(file: 'x', entry: '#1', lump: 'BOSS')), 'BOSS');
    expect(MusicPlayer.exportExtension(MusicFormat.midi, Uint8List(0)), 'mid');
    expect(MusicPlayer.exportExtension(MusicFormat.it, Uint8List(0)), 'it');
    expect(MusicPlayer.exportExtension(MusicFormat.nsf, Uint8List.fromList(ascii.encode('NSFE...'))), 'nsfe');
  });

  test('MusicPlayer safely stops, shuts down and reports missing audio DLL without crashing', () async {
    final player = MusicPlayer();
    expect(player.spectrum(), isNull);
    player.stopSpectrum();
    await player.stop();
    await player.shutdown();

    final ogg = p.join(dir.path, 'song.ogg');
    File(ogg).writeAsBytesSync(fakeOgg({}));
    const t = MusicTrack(file: 'missing_song', entry: 'song.ogg', lump: 'SONG');
    await player.play(MusicTrack(file: ogg, entry: 'song.ogg', lump: 'SONG'));
    // На тестовом раннере без flutter_soloud_plugin.dll ошибка ловится в player.error, не падая.
    expect(player.error, isNotNull);
    expect(player.loading, isFalse);
    await player.play(t);
    expect(player.error, isNotNull);
    player.dispose();
  });
}
