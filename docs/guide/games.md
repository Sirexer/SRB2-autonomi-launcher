# Games

**English** | [Русский](games.ru.md)

The launcher supports **Sonic Robo Blast 2** (2.2), **SRB2 Legacy** (the 2.1
fork), **SRB2Kart** (1.6) and **Dr. Robotnik's Ring Racers** (2.4), plus
**custom games** — forks described in JSON (for example, BlanKart).

The game is chosen in the window title (in place of the launcher's name); the
folder button next to it opens the game folder. Every game has its own folder,
launch queue, executables, options, profiles, master servers and server list.
The add-on list shows only the add-ons for the chosen game — the `games` field
of a repository (see [repository format](../manifest-format.md#games)).

## Which games are shown

Settings → **Games**: built-in games other than Sonic Robo Blast 2 can be
turned off — they disappear from the switcher (their settings and files stay).
The first-run wizard offers the same.

## Custom games

Forks that behave like one of the built-in games are added from JSON: on the
first start from `another_games.json` next to the launcher (the release ships
BlanKart there; a game you decline is not added), or in Settings → Games →
**Add games from JSON...** (a file may hold one game or several — then you
choose which). There a custom game can be turned off, removed from the
launcher (its files on disk are not touched) or exported to JSON together with
its icon. Custom games already added from `another_games.json` are updated on
start when a new release fixes their definition.

The definition format is in [custom-games.md](../custom-games.md).

## Notes per game

### Sonic Robo Blast 2

- Game folder: the one with `srb2.pk3` (usually `~/.srb2` on Linux); add-ons
  are downloaded to `DOWNLOAD`; default executable `srb2win.exe` / `srb2`.
- Default master servers: `https://ds.ms.srb2.org/MS/0` and Weissblatt
  (`https://ms.weissblatt.cc/api/srb2http`).

### SRB2 Legacy

[srb2-preservation/srb2-legacy](https://github.com/srb2-preservation/srb2-legacy)

- Game folder: the one with `srb2.srb` (usually `~/.srb2_21` on Linux);
  add-ons go to `DOWNLOAD`; executable `srb2legacywin.exe` / `srb2legacy`.
- Old-style master servers — `host:port` (TCP, port 28900):
  `ms.srb2classic.net:28900` and `ms.weissblatt.cc:28900`. The launcher gets
  the servers of all rooms and the room names.

### SRB2Kart

- Game folder: the one with `srb2.srb` (usually `~/.srb2kart` on Linux);
  add-ons go to `DOWNLOAD`; executable `srb2kart.exe` / `srb2kart`.
- Servers come from the Kart Krew master server; Race and Battle, no rooms.

### Ring Racers

- Game folder: the one with `bios.pk3` (usually `~/.ringracers` on Linux);
  add-ons go to `addons/DOWNLOAD`; executable `ringracers.exe` / `ringracers`.
- Servers come from the Kart Krew master server
  (`https://ms.kartkrew.org/ms/api`). It does not send server names, so a name
  appears once the server is queried and is remembered. The average power level
  and Race/Battle are shown.

### BlanKart (custom game)

[NepDisk/blankart](https://codeberg.org/NepDisk/blankart), a fork of SRB2Kart.

- Game folder: the one with `main.pk3` (usually `~/.srb2kart-v2` on Linux);
  add-ons go to `addons/DOWNLOAD`, like the game's own; executable
  `blankart.exe` / `blankart`. SRB2Kart add-ons are shown too.
- Servers come from `https://ms.blankart.cc/MS/1`. A server's add-ons are
  downloaded before joining but not loaded in advance: the game loads them
  itself when connecting, the way the server says (otherwise it may answer
  "You have the wrong addons loaded").

How the launcher talks to each game's servers is in
[internals.md](../internals.md).
