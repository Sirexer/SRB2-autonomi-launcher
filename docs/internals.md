# Internals

**English** | [Русский](internals.ru.md)

Technical details — for those who change the launcher or want to know what it
does. Users do not need to read this.

## Servers

### Master servers

| API | Games | Request |
|---|---|---|
| SRB2 (HTTP) | SRB2 | `<address>/servers`; rooms: `/rooms` |
| Kart (HTTP) | SRB2Kart, Ring Racers, BlanKart | `<address>/games/<application>/<MODVERSION>/servers?v=2.2` (the Kart Krew master server does not answer without `?v=2.2`) |
| 2.1 (TCP) | SRB2 Legacy | `host:port` (port 28900): the servers of all rooms and the room names |

The latest game version is `<address>/games/<application>/version` (answer
`MODVERSION name`). The Ring Racers master server sends no server names — the
name comes from querying the server and is kept in the local list.

### Querying a server

A server is queried over UDP like the game does it: a packet with the
`doomdata_t` header and checksum, `PT_ASKINFO` → `PT_SERVERINFO` (name, map,
gametype, players, flags, add-on list) and `PT_PLAYERINFO`. If the add-ons do
not fit into one packet (`SV_LOTSOFADDONS`), the rest are requested with
`PT_TELLFILESNEEDED` / `PT_MOREFILESNEEDED`.

The games' protocols differ in packet numbers, packet version and the layout
of `serverinfo_pak` / `plrinfo` — the `NetProtocol` table in
`lib/models/srb2_server.dart` (offsets checked with `offsetof` on the packed
structs from each game's `src/d_clisrv.h`):

- **SRB2 2.2** — the answer starts with `_255` and the packet version, a file
  entry has a "folder" byte, the gametype is a string.
- **SRB2 Legacy (2.1)** — no `_255`/packet version/application, the gametype
  is a number.
- **SRB2Kart** — no refuse reason, the gametype is a number (Race/Battle).
- **Ring Racers** — commit[4] after the version, no map name, an average power
  level; plrinfo carries no skin (`0xFF`), so a player's character is found by
  name.
- **BlanKart** — like Ring Racers, but packet version 2 and an 8-byte map hash
  instead of 16 bytes (the later fields move 8 bytes earlier); plrinfo is 33
  bytes with a UINT16 skin; a file entry has a 64-bit XXH3 hash and a
  compatmode byte; the "will send" status follows SRB2 (0 yes, 1 no, 2 too
  large).

A custom game's protocol can be described in JSON — see
[custom-games.md](custom-games.md#protocol).

### Server add-ons

- A file on disk is found by name (case-insensitive, 10 folders deep) and
  checksum: MD5, or for BlanKart the XXH3-64 of the whole file (the UINT64
  bytes little-endian, as in the packet).
- Sources in order: repositories (by MD5), the server's HTTP mirror
  (`<source>/<name>?md5=<md5>`; BlanKart without `?md5=`), the server itself.
- Downloading from a server: `PT_REQUESTFILE` (with the file name for Ring
  Racers, Kart and Legacy), then fragments. SRB2 2.2 and Ring Racers
  acknowledge them with `PT_FILEACK` / `PT_FILERECEIVED`; SRB2Kart and SRB2 2.1
  use the old transfer: fragments come as "reliable" packets and the launcher
  acknowledges them on the network level (ackreturn and `PT_NOTHING`), like
  the game.
- If another file with the same name is already in the downloads folder, the
  new one goes to the subfolder `<name>/<start of checksum>/`; the game finds
  the right one by checksum.
- Loading add-ons before connecting (`-file` in the server's order +
  `+connect`): the game requires the loaded files to match the server's list.
  It is off for BlanKart: BlanKart also compares compatmode, which the game
  decides by itself for `-file` and may differ from the server's.

### Server country

The DB-IP Lite database (CC BY 4.0) is built into
`assets/geoip/country.bin` at build time (`tools/build_geoip.py`) — address
ranges and country codes; lookup is a binary search, addresses are not sent
anywhere.

## Characters

Characters are found like the game does (`R_AddSkins`): a character starts at
an `S_SKIN*` lump and its sprites follow up to `S_END`, the next `S_SKIN` /
`P_SKIN` or `S_START` (the whole folder in a PK3 where the character has its
own folder). An S_SKIN without `name` still counts (otherwise later skin
numbers would shift). Compressed WADs (`ZWAD`, LZF) are read.

- **Icon**: SRB2 — `XTRAC0` (or `XTRAC0C8`, the second frame of a shared
  lump); SRB2Kart — the lump from `facewant` / `facerank`; Legacy — `face`;
  Ring Racers — `XTRAB0`, then `XTRAA0`, `XTRAC0`.
- **Portrait**: SRB2 — `XTRAB0`; Legacy — `PicName` from SOC_PLAY, then
  `charsel` from S_SKIN.
- If one picture is missing, the other is used; if both are, `STNDA2` /
  `STNDA2A8`, `STNDA8A2` (mirrored), `STNDA0`, `STNDA8` (mirrored), `STNDA1`.
- The icon is recolored: indices `startcolor`…`startcolor+15` are replaced
  with a color ramp (`prefcolor`, the chosen color, a team color).
- SRB2 Legacy's Sonic is defined in the game's code, so the launcher adds him
  (`LIVSONIC` / `CHRSONIC`). Sonic, Tails and Knuckles get descriptions from
  the games' code unless an add-on sets its own (`PlayerText` in SOC_PLAY).
- A player's skin number on a server is the index among the game's characters
  and the server's downloaded add-ons in order; add-ons you do not have count
  as files without characters (the tooltip says the character is probably a
  guess). The server's skin list is written to the launcher console.

## Levels

- Level picture: `MAPxxP` (SRB2, SRB2Kart), `PICTURE` inside the map (Ring
  Racers); PNG or a Doom patch with the `PLAYPAL` palette from the add-on or
  the game files.
- Titles come from SOC (`Level 1` / `Level A1` / `Level RR_TEST`,
  `Levelname`, `Act`); maps MAP01–MAPZZ and maps with any name:
  `Maps/<name>.wad` in a PK3 or a map "as a folder".
- A map's gametypes come from `TypeOfLevel`, like the games' `G_TOLFlag`.

## Music

- Lookup: `O_<name>` / `D_<name>` lumps, in WADs also between
  `M_START`/`M_END`, in PK3s `Music/`; titles from `MUSICDEF`. The result is
  cached by file size and time (`music/scan_cache.json`).
- Duplicates: by size and CRC-32 of the contents (PK3s already store the CRC).
- MIDI/MUS, modules and console music are rendered to WAV first and kept in
  `music_render/` (up to 1 GB, oldest removed; all of it when
  `_renderCacheVersion` changes, so bump it when rendering changes). The own synthesizer is
  `lib/services/midi_synth.dart`; a SoundFont is read from disk in parts (only
  the samples of the notes played). Modules use libopenmpt, console music
  libgme, old OGG libvorbisfile (all through FFI).
- **MIDI device**: notes are sent by a separate isolate with its own timer
  (on Windows with `timeBeginPeriod(1)`); Windows uses `winmm`
  (`midiOutShortMsg`), Linux the ALSA sequencer
  (`snd_seq_event_output_direct`). Seeking sends silence (CC120/123), resets
  controllers and then replays all non-note events up to the new position; the
  volume is each channel's CC7 times the player volume. One track owns the
  device at a time; if the isolate does not answer, the main isolate closes
  the device by its handle.
- Visualizer: the SoLoud engine's FFT spectrum; with a MIDI device, the levels
  of the notes playing. Two-color bars are one `drawVertices` call with vertex
  colors: on Windows (Impeller over ANGLE) a gradient shader went through a
  temporary texture for every bar and frame and took hundreds of megabytes.

## Progress files

Files are only read, the way the game reads them.

- **SRB2 2.2** — `gamedata.dat` (`G_LoadGameData`): play time, visited and
  cleared levels, records, emblems, extra emblems, secrets. Levels, emblems
  and secrets come from the game's SOC (`srb2.pk3`: SOC_HEAD, SOC_EMBM,
  SOC_SECR) and the add-on's.
- **SRB2 Legacy (2.1)** — an older header, 16 extra emblems, 32 secrets, no
  extra byte per record. The 155 emblems, extra emblems and secrets are in the
  game's code (`m_cond.c`) — the launcher has them in
  `lib/services/legacy_progress_data.dart`.
- **SRB2Kart** — `kartdata.dat`; medals, extra emblems and secrets are in the
  game's code — in `lib/services/kart_progress_data.dart`.
- **Ring Racers** — `ringdata.dat` and `ringprofiles.prf`: a header and UBJSON
  (`g_gamedata.cpp`, `k_profiles.cpp`). Icons come from `gfx.pk3`, recolored
  like the game does (indices 96–111).
- The Legacy and Kart data is generated by `tools/gen_progress_defaults.py`
  from the games' sources.
- The name hash in the file is checked against the name, like the game; a
  foreign file is marked.
- An add-on has its own progress only with `GameData` in its SOC `MainCfg`;
  it can define emblems and secrets only after its `GameData`.

## Save protection

A file is checked the way the game reads it (header, length, parsing to the
end; save slots also by the `version N` line and the `0x1d` end marker). The
`GameData` found in a file is cached until the file changes. Copies are in
`save_backups/<game>-<folder code>/`, damaged files in `save_backups/Damaged`.

## Launcher updates

- The release list comes from the GitHub API (`/repos/…/releases`); if it
  refuses (60 requests an hour per address without signing in, answer 403),
  from the `releases.atom` feed (release files are then found by the CI names,
  without SHA-256).
- Newer means published after the release of this version (`BUILD_VERSION`);
  for a build without a version, published after the build time; a local
  build without a date does not check on start.
- The file is checked by size and SHA-256 (the `digest` field of the API).
- **Windows**: the zip is unpacked into `.update` next to the launcher; files
  to be replaced are renamed to `*.old` (possible even for the running exe and
  its DLLs) and the new ones take their place; on error everything is put
  back. The `*.old` files are listed in `.update_old.txt` and removed on the
  next start. An existing `pointer.txt` is kept.
- **Linux**: the new AppImage is downloaded next to the old one
  (`$APPIMAGE.new`) and renamed over it.
- Then `antd` is stopped, the launcher is started with `--new-instance` and
  the old one quits.

## One launcher at a time

Windows: a named mutex in `windows/runner/main.cpp`; Linux: GtkApplication
uniqueness over D-Bus (`linux/runner/my_application.cc`; no check without a
session bus). `--new-instance` skips it.

## Autonomi (antd)

- `antd` ships with the build (the `antd` folder next to the program) together
  with its licenses; on the first start it is copied to the data folder
  (`antd/<version>/`) and run from there. If it is missing (running from
  source) or the version differs, the launcher downloads it from GitHub, then
  from the GitLab mirror, and checks it against the release's SHA256SUMS.
- Port `127.0.0.1:8082`. Somebody else's daemon that answers is used; a hung
  own one (from the data folder) is closed and started again. After several
  time-outs in a row the daemon is restarted (at most once a minute).

## Rendering

- Impeller draws (Flutter's default); `--skia` switches to Skia. Which one is
  in the log (`renderer: ...`).
- A theme's background picture is decoded once, already scaled down (to the
  screen or 2048 px), and blurred once — not by a window-sized layer on every
  frame.
- Window opacity: Linux uses `gtk_widget_set_opacity` through the
  `srb2al/window` channel in the runner; Windows a layered window
  (`WS_EX_LAYERED`). The Windows 11 backdrop is
  `DwmSetWindowAttribute(DWMWA_SYSTEMBACKDROP_TYPE)` with the frame extended
  over the whole window.

## Data and caches

| File | What |
|---|---|
| `shared_preferences.json` | Settings |
| `addon_contents_cache.json` | What is inside add-ons |
| `music/scan_cache.json` | Music found in files |
| `music_render/` | Rendered MIDI and modules |
| `cache/images/` | Add-on covers |
| `themes/` | Your themes |
| `games/` | Icons of custom games |
| `save_backups/` | Save copies |
| `logs/launcher.log` | Log |
| `antd/` | Autonomi daemon |
