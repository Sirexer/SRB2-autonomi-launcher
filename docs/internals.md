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

## Palettes

A picture is drawn with the last loaded `PLAYPAL`; inside one file the game
takes the first lump with the name (`W_CheckNumForNamePwad`). BlanKart has two
palettes: its own in `main.pk3/Palette/PLAYPAL.pal` and the old SRB2Kart one.
Files in its compatibility mode (`d_main`: `srb2.srb`, `gfx.kart`,
`textures.kart`, `chars.kart`, `maps.kart`, `bonuschars.kart`; add-ons: a WAD
`*.kart` or a file named `K…`) are drawn in the old palette and their colors
are translated with the `PALREMAP` table (`MakePatch` →
`R_DoPaletteRemapPatch`). `PaletteResolver` (`map_preview.dart`) does the same
when the game files have `PALREMAP` — only BlanKart has it — so maps,
character icons and emblems get the palette of the file they come from.

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

## Replays

`lib/services/replays.dart`, `lib/ui/replays_tab.dart`. Only a 16 KiB head and
an 8 KiB tail of each `.lmp` are read during scanning.

- **SRB2 2.2 / SRB2 Legacy 2.1** (`\xf0SRB2Replay\x0f`): version `version`/`subversion`,
  `demoVersion`, MD5 checksum `0x10..0x1F` (over `0x20..EOF`), `PLAY`, `uint16 mapNumber`.
  For `demoVersion >= 16`, a `uint16` add-on table (`cstr name` + 16-byte MD5)
  sits at `0x37`, followed by time, score, rings, player name, skin and color.
  For `demoVersion < 16` (2.1 and early 2.2), local/repository add-ons are
  matched by the replay subfolder against `MainCfg → GameData` in SOC or by
  archive filename (`resolveAddonsByFolder`).
- **SRB2Kart** (`\xf0KartReplay\x0f`, `version < 2`): `title[64]`, MD5 checksum
  `0x50..0x5F` (over `0x60..checksumEnd`, where `checksumEnd` is right after the
  last `\xff\x80` tic terminator or `length - 1`), `PLAY`, `uint16 mapNumber`,
  `mapmd5[16]`, `demoflags`, `gametype` (0 Race, 1 Battle), `uint8 numAddons`
  at `0x78` (`cstr name` + 16-byte MD5). Time Attack reads time/netvars/player
  from the header; finished network replays read winner standings (fixed 16-byte
  name, skin, color + `uint32` time/score) after `\xff\x80`.
- **Ring Racers** (`\xf0KartReplay\x0f`, `version >= 2`): `title[64]`, MD5
  checksum `0x50..0x5F`, `PLAY`, `cstr mapName`, `mapmd5[16]`, `demoflags[2]`,
  `cstr gametype`, flags byte, `uint8 numAddons`, `uint8 nSkins` (`16 + 6`
  bytes per skin) and an EOF UBJSON `standings` object.
- **BlanKart** (`\xf0BlanReplay\x0f`, `version 2`): `title[64]`, 64-bit
  XXH3-64 LE checksum `0x50..0x57` (over `0x60..pos(\xff\x80)+2`), `PLAY`,
  `cstr mapName`, `maphash[8]`, `demoflags`, `cstr gametype` (+ server/MOTD
  strings for `demoVersion >= 11`), `uint8 numAddons` where each entry stores
  `cstr name`, 8-byte XXH3-64 hash and a `compatMode` byte, plus standings after
  `\xff\x80` (`cstr` fields for `demoVersion > 12`).
- **Header patching (`SRB2AL-Replays/temp/replay.lmp`)**: because `-force` is
  unreliable on mod-gated demos, when the user toggles add-ons, enables Extra
  add-ons or uses a local file with a different checksum (`exact == false` via
  `LocalFileIndex.firstByName`), `ReplayScanner.prepareTempReplay` rewrites
  the recorded add-on table and recomputes the format-specific header checksum.
  `temp/` is skipped by the scanner.

## 3D models

`lib/services/model_packs.dart`, `model_mesh.dart`; Settings → Models
(`lib/ui/models_settings.dart`, preview: `model_preview_dialog.dart`,
`model_viewer.dart`).

- **Formats** (`ModelFormat`, from `hw_md2.c` of each game): SRB2 Legacy
  (2.1) `md2.dat`/`md2/`, `%19s`, no `PLAYER`, MD2 only, home folder only; SRB2
  `models.dat`/`models/`, name `%25s`; SRB2Kart `mdls.dat`/`mdls/`, `%19s`, no
  `PLAYER` prefix; Ring Racers `%23s`; BlanKart reads `models.dat`, then
  `blanmodels.dat`. A path is `%31s` everywhere. The list is read by
  `fscanf("%Ns %31s %f %f") == 4` — the first bad line stops reading
  (`ModelDat.parse` does the same and reports where). The game looks in its
  home folder first, then next to the executable: the launcher's game folder
  is the home/working folder.
- **Textures**: `<model path without extension>.png` (or `.pcx`); for player
  colors `_blend.png`. Without a PNG the game maps the object's sprite on the
  model (`adjustTextureCoords`).
- **Library**: `model_packs/<game>/<pack>/pack.json` + `files/` (only files
  from the list, spelled as in the list); `setup.json` — order, disabled
  packs, manual choices. Repository model archives are downloaded to
  `models/<game>/<pack>/<version>/` in the launcher data directory (not the
  game's `DOWNLOAD`). Both deep/backslash `.zip` paths and archives with
  multiple versioned folders/lists are supported; if no `.dat` file is present,
  `ModelDat.extractFromReadme` can parse model entries from `README` /
  `Read Please!.txt`. In a pack the last line with a name wins (as in the game).
- **Build**: the chosen version of each name; the path is kept, a clash with
  another pack's file goes to `P<n>/…`, a too long path to `P<n>/<file>` or
  `P<n>/M<k>.md3`. Install: files are copied to `<folder>.srb2al-new`, the old
  folder and list are renamed into `<folder>.srb2al-backups/<date>/`, then the
  new ones are renamed into place (five backups kept); a mark
  `.srb2al-models.json` in the folder says the launcher put it there.
- **Mirroring**: the game turns model vertices into GL as (x, z, −y) and puts
  the world in as (x, z, y) (`DrawModelEx`; 2.1 converts MD2 the same way in
  `md2_readModel`), so in the game a model is mirrored compared to its file;
  the preview negates Y too.
- **Preview**: MD3 (vertices ×1/64, frames by name: `SPR2_STND+i00` → STND,
  `SUPER…`) and MD2 (each triangle corner is its own vertex); drawn by
  `rasterizeModel` (`model_raster.dart`) with a depth test per pixel, like
  the game's OpenGL — sorting whole triangles hid small details such as
  pupils; texels under half alpha are skipped; a textured model is not shaded
  (colors as in the file), an untextured one gets flat light per face. Player color —
  `blendSkinColor`, a port of `HWR_CreateBlendedTexture` (regular colors).

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

## Discord Rich Presence

`lib/services/discord_rpc.dart`; Settings → Experimental → Discord Rich
Presence (off by default, `discord_rpc_enabled`).

- **IPC without C++ plugins**: runs in a background isolate; on Windows
  connects to `\\.\pipe\discord-ipc-0..9` through `kernel32.dll` (`dart:ffi`),
  on Linux — to Unix domain sockets (`discord-ipc-0..9`) under
  `$XDG_RUNTIME_DIR`, `$TMPDIR`, `$TMP`, `$TEMP` or `/tmp` (including Flatpak
  and Snap paths).
- **Handshake and updates**: waits for Discord's `READY` event (with a 1.5 s
  fallback), replies to `PING` frames, coalesces rapid `SET_ACTIVITY` updates
  with a 200 ms debounce and retries once after 3 s on `ERROR`.
- **Activity modes**:
  - `type: 0` (Playing) — launcher status: current game, session timer, active
    tab (open add-on, launch queue count, selected server with player count,
    progress or replays).
  - `type: 2` (Listening) — active music player track: title, authors, track
    source in `large_text` (repository add-on name, file name for local/server
    files, or game name for vanilla files) and seek/loop-aware timestamps.
  - `type: 3` (Watching) — started replay (`levelPack · map`, character name),
    cleared automatically when the game process exits (`isProcessAlive(pid)`).
  The large image is always `launcher`, with `gameId` or `music` as the small
  corner icon.

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
| `model_packs/` | Model packs (Settings → Models) |
| `models/` | Repository model archives |
| `logs/launcher.log` | Log |
| `antd/` | Autonomi daemon |
