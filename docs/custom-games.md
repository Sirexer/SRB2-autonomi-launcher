# Custom games (JSON)

**English** | [Русский](custom-games.ru.md)

Besides the built-in games (SRB2, SRB2 Legacy, SRB2Kart, Ring Racers) the
launcher supports **custom games** — forks that behave like one of the
built-in games (for example [BlanKart](https://codeberg.org/NepDisk/blankart),
a fork of SRB2Kart). A custom game is described in JSON; the behaviour
(launching, options, skins, colors, downloading server add-ons) comes from
the base game (`base`), and what differs — game files, executables, master
servers, the network protocol — is set in the definition.

## Where to add one

- **First start.** The wizard offers the games from `another_games.json` next
  to the launcher (the release has it, with BlanKart). A game left unticked is
  not added.
- **Settings → Games → Add games from JSON...** A file may describe one game
  or several — then the launcher lists them and you pick which to add. A game
  with the same `id` is replaced by the new definition.

Also in Settings → Games:

- built-in games other than Sonic Robo Blast 2 can be **turned off** — they
  disappear from the game switcher (settings and files stay; turn them back on
  any time);
- a custom game can be turned off or **removed** from the launcher: the game
  on disk is not touched, and it comes back only from its JSON;
- **Export** saves a custom game's definition to a file (with its icon) to
  share it.

## File format

One game is an object; several are a list or `{"games": [...]}`:

```json
{
  "games": [
    {
      "id": "srb2blankart",
      "name": "BlanKart",
      "full_name": "SRB2Kart: BlanKart",
      "base": "srb2kart",
      "version": "2.0",
      "models": { "file": "models.dat", "folder": "models", "name_max": 25, "player_prefix": true, "extra_files": ["blanmodels.dat"] },
      "protocol": { "base": "ringracers", "packet_version": 2, "...": "see below" },
      "master_api": "kart",
      "masters": ["https://ms.blankart.cc/MS/1"],
      "mod_version": 12,
      "main_file": "main.pk3",
      "download_path": "addons/DOWNLOAD",
      "executables": {
        "windows": ["blankart.exe"],
        "linux": ["blankart"]
      },
      "linux_data_folders": [".srb2kart-v2"],
      "base_addons": true,
      "own_files": ["main.pk3", "mappatch.pk3", "patch.pk3", "blanmusic.pk3"],
      "icon": "blankart.png"
    }
  ]
}
```

Required fields:

| Field | Meaning |
|---|---|
| `id` | Game code: 2–41 characters, lowercase Latin letters, digits, `_`, `-`, `.`. Must not be a built-in game. The game's settings are stored under it and add-ons are matched by it (`games` in a repository). |
| `name` | Short name (in the switcher and labels). |
| `base` | Base game: `srb2`, `srb2legacy`, `srb2kart` or `drrr`. |

Optional (the base game's value is used without them):

| Field | Meaning |
|---|---|
| `full_name` | Full name (default: `name`). |
| `version` | Game version for labels. |
| `icon` | Icon (PNG): a path relative to the JSON file or `data:image/png;base64,...`. Without it, the base game's icon. |
| `protocol` | Server query protocol: a built-in name (`srb2`, `srb2legacy`, `srb2kart`, `ringracers`, `blankart`) or an object — see Protocol. |
| `master_api` | Master server kind: `srb2` (`/servers`) or `kart` (`/games/<application>/<mod_version>/servers`). |
| `masters` | Default master servers (a list). |
| `mod_version`, `mod_id` | The game's MODVERSION / MODID: the master server lists its servers and reports a new version by them. |
| `main_file` | The file that identifies the game folder. |
| `download_path` | Add-on downloads folder inside the game folder (for example `"DOWNLOAD"` or `"addons/DOWNLOAD"`). |
| `gametypes` | Gametypes for the server filter. |
| `has_rooms` | Whether the master server has rooms. |
| `executables` | Executable names: `{"windows": [...], "linux": [...]}`; the first is the default command. |
| `executable_hints` | Words in an executable's file name that tell the launcher it is this game (default: `id`). |
| `linux_data_folders` | Game folders on Linux relative to home (for suggestions). |
| `palette_files`, `map_files`, `skin_files`, `music_files` | Game files with the palette, maps, skins and music. |
| `picture_inside_maps` | Map pictures are inside the map files. |
| `base_addons` | `true` — show the base game's add-ons too (the fork loads them). |
| `own_files` | The game's own files with add-on extensions (`.pk3`) — they are not listed under In the game folder. |
| `models` | How the game reads 3D models (Settings → Models): `file` — the list (`models.dat`), `folder` — the models folder, `name_max` — the longest name the game reads, `player_prefix` — whether `PLAYERNAME` means a skin, `extra_files` — lists the game reads after `file` (their lines win), `md3` — whether the game reads MD3 (`false`: MD2 only). Missing keys come from the base game; `false` — no models. |

Errors in a definition (a missing field, an unknown base or protocol) are
shown in the game picker — such a game cannot be added; the others in the
file can.

## Protocol

The launcher queries a game's servers directly (UDP): it asks for serverinfo
(name, map, players, add-ons) and the player list, and can download a server's
add-ons before joining. Forks often differ a little — other packet numbers or
field offsets. Then `protocol` is an object: `base` is the built-in protocol
it resembles, the other fields are what differs (anything missing comes from
the base). The full BlanKart protocol is in
[packaging/another_games.json](../packaging/another_games.json).

| Field | Meaning |
|---|---|
| `base` | Required: `srb2`, `legacy`, `srb2kart`, `ringracers` or `blankart`. |
| `application` | The SRB2APPLICATION the server sends in serverinfo. |
| `packet_version`, `version`, `subversion` | The game's PACKETVERSION, VERSION and SUBVERSION: the server answers only if they match. |
| `has_packet_version_prefix` | The answer starts with `_255` and the packet version (2.2 and later; not in 2.1). |
| `version_format` | How to show the version: `srb2` (VERSION 202, SUBVERSION 15 → "2.2.15") or `major.minor` (2 and 4 → "2.4"). |
| `packets` | Packet numbers: `client_quit`, `ask_info`, `server_info`, `player_info`, `request_file`, `file_fragment`, `file_ack`, `file_received`, `tell_files_needed`, `more_files_needed` (`-1` — no such packet). |
| `server_info` | serverinfo field offsets from the start of the packet data: `application`, `version`, `players`, `refuse_reason`, `gametype`, `modified`, `flags`, `file_count`, `level_time`, `server_name`, `map_name`, `map_title`, `act_num`, `is_zone`, `http_source`, `avg_power_level`, `file_needed`. `null` — no such field (`refuse_reason`, `map_name`, `http_source`, `avg_power_level`). |
| `player_info` | A player record in plrinfo: `size` (record size), offsets `team`, `skin`, `score`, `time`; `skin_wide` — the skin is 2 bytes, not 1. |
| `file_entry_has_folder` | A file entry has an "is a folder" byte (SRB2 2.2). |
| `file_hash_bytes` | Size of a file's checksum: 16 (MD5) or, for example, 8 (XXH3-64 of the whole file, as in BlanKart; the launcher computes it). |
| `file_entry_extra` | Bytes after the checksum in a file entry (BlanKart: compatmode). |
| `preload_files` | `false` — do not load a server's add-ons in advance (`-file`); the game loads them itself when joining. Needed when the game checks not only the files but how they are loaded (BlanKart: compatmode — with `-file` it may differ from the server's and the game says "You have the wrong addons loaded"). |
| `request_file_with_name` | The file request (PT_REQUESTFILE) has the name after the number. |
| `legacy_file_transfer` | Old file transfer (SRB2Kart, SRB2 2.1): fragments are acknowledged on the network level, no PT_FILEACK. |
| `will_send` | How to read "will the server send the file": `srb2` or `kart`. |
| `gametype_names` | The gametype comes as a number: `{"2": "Race", "3": "Battle"}`; `null` — as a string. |
| `base_skins` | Built-in skins by number — for the player list. |

Offsets and numbers come from the game's sources (for SRB2-like games
`src/d_clisrv.h` / `src/netcode/protocol.h`, the `serverinfo_pak` and
`plrinfo` structs). Errors in a protocol definition are shown like other
definition errors.
