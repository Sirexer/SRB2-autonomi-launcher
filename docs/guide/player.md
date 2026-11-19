# Music player (experimental)

**English** | [Русский](player.ru.md)

Turned on in Settings → Experimental → Music player (or in the first-run
wizard). The **Music** tab comes after Servers and plays the music of all
games — from the game files (`music.pk3` and others), downloaded add-ons,
other downloads and files you open; an add-on does not have to be queued.

## List

- Sections: game → Game files / Add-ons / Other downloads / In the game
  folder → file; each collapses (all expanded while searching).
- Music is found like the game finds it: `O_<name>` / `D_<name>` lumps, in WADs
  also between `M_START` and `M_END`, in PK3s the `Music/` folder. Titles and
  authors come from `MUSICDEF` (each game has its own), otherwise from the
  file's tags. Special tracks (`_TITLE`, `_1UP`, `_SHOES`…) get a readable name.
- Search, format filter, sort by title or music name, favorites (★).
- **Hide duplicates** (on by default): the same music in several files (say,
  versions of an add-on) is listed once; the contents are compared, not the
  name. A badge with a number tells in how many other files the track is.
- Files can be dropped onto the tab (`.sf2` goes to the SoundFont list).

## Formats

OGG Vorbis, MP3, FLAC, WAV, MIDI and Doom MUS, tracker modules MOD/XM/IT/S3M
(libopenmpt) and console music SPC, VGM/VGZ, NSF, GBS, GYM, HES, KSS, SAP, AY
(libgme) — with the same libraries the game uses. The launcher looks for them
next to itself (the `lib` folder), in the game folders and in the system
(Linux: `libopenmpt0`, `libgme0`; the AppImage has them). Old OGG files the
built-in decoder cannot open are decoded with libvorbisfile. Opus is not
played.

## Playback

- Loops start at `LOOPMS` / `LOOPPOINT` from the file's tags, otherwise at the
  beginning; the loop start is marked on the slider. The repeat button: to
  the end of the list / the whole list / track from the start / track with its
  loop. Shuffle, and a track picker for multi-track files (NSF, GBS…).
- **Plays on**: the levels where the track plays (`Music =` in SOC, or
  `MAPxxM` like the game); clicking one sets it for `-warp`. An add-on track
  replacing a game track is marked; ⇄ switches to the original or the
  replacement at the same place.
- Under the track: its add-on and file, Show in folder and **Export** — the
  track, all music of the file or the selected tracks — as the original files
  (OGG, MP3, MIDI, modules...).
- Keys: Space pauses, ←/→ seek 5 s, Ctrl+←/→ change track, ↑/↓ volume, Ctrl+F
  search. Media keys work system-wide on Windows while the player has music;
  on Linux while the window is active.
- A mini player is shown at the bottom of other tabs (the cross closes it).
- Visualizer bars above the title (their colors come from the theme).

## MIDI

The **SoundFont** button above the list chooses where MIDI goes:

- **The launcher's synthesizer**: simple built-in sounds or a **SoundFont**
  (`.sf2`) — added ones stay in the list for quick switching. A track is
  rendered first (progress in percent) and kept on disk, so it starts at once
  next time. Big SoundFonts are fast: only the samples of the notes played are
  read from disk.
- **A MIDI device of the system** (the default on Windows): Microsoft GS
  Wavetable Synth (how MIDI sounds in the game itself), VirtualMIDISynth, an
  external synthesizer; on Linux, ALSA ports (FluidSynth, TiMidity++). The
  track starts at once; seek, pause and volume work as usual and the
  visualizer shows the notes playing. If the device is busy (the game or
  another program uses it), the launcher's synthesizer plays the track and a
  warning is shown under the title.

## Saving power

The position updates only the slider, the timer runs only while music plays,
and after 30 seconds of silence the sound engine is shut down (a paused
position is remembered). The music scan is cached; rendered MIDI and modules
are kept on disk (up to 1 GB).
