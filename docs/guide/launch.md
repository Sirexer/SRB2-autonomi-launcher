# Launch tab

**English** | [Русский](launch.ru.md)

## Queue (`-file`)

- The order the add-ons are loaded in. Files are added with Add to Queue on
  the Addons tab, with **Add files...** or by dropping `.wad/.pk3/.lua/.soc`
  onto the window. A queued add-on can be turned off without removing it.
- The button next to **Add files...** removes the turned-off add-ons, or all
  of them if none is off; the message has Undo.
- **Undo and redo** — the ↶ ↷ buttons above the queue or Ctrl+Z / Ctrl+Y
  (Ctrl+Shift+Z) when no text field has focus. Everything is undone: adding,
  removing, order, turning on and off, loading a profile, and also the
  character, color, map and gametype reset together with a removed add-on.
  Up to 100 steps, separate for every game.
- **Profiles** are saved sets of the queue and options.

## Executables

- The game's executables. The star marks the default one; the "⋮" menu adds,
  edits, removes or **finds executables in a folder** (the launcher looks
  through the folder and its subfolders, such as `bin`).
- A command works instead of a path: `flatpak run org.srb2.SRB2`. Quote paths
  with spaces.
- On Linux/macOS a shell alias or function works too (`alias srb2legacy=...`
  in `~/.bashrc`, `~/.zshrc`, `config.fish`): if the command is neither in the
  game folder nor on PATH but your shell (`$SHELL`) knows it, the game is
  started through the shell.
- The game is started with the game folder as its working folder (Settings →
  Game folder), so `config.cfg`, saves and `DOWNLOAD` come from there wherever
  the executable is.

## Options

Sections (other than Profile) collapse by clicking their title; a collapsed
section shows what is set in it. Order: Profile, Video, Audio, Game, Player,
Netgame, Server, Input, Console commands and variables, Debug, Extra
parameters.

- Checkboxes for the game's flags: renderer, window, sound, `-skipintro`,
  `-nodata` (play without touching your progress), netgame (`-server`,
  `-dedicated`, `-connect`) and more. Shared by all executables of the game.
- **Warp to map** — a map set means `-warp`, empty means a normal start. The
  button next to it opens the map picker; a map's "⋮" menu lists gametypes and
  **Singleplayer** (when the map is good for single player: it removes
  `-gametype` and turns off hosting). The gametype chips above the maps show
  only the maps of the chosen gametypes (any of them); none chosen — all maps.
- **Encore** (SRB2Kart, Ring Racers) — mirrored track with the Encore palette
  (`+kartencore On` / `+encore On`), Race only (also Versus in Ring Racers).
- **Gear** (SRB2Kart `+kartspeed`, Ring Racers `+gamespeed`) and **Bots**
  (Ring Racers `+bots`) — "default" passes nothing.
- **Player**: `+name`, `+skin`, `+color` and **Always default color** — the
  character's own color (`prefcolor` from its S_SKIN; `+color Default` in
  Ring Racers). Picking a color on the Addons tab clears the checkbox.
- **Netgame / Server**: when hosting you can pick the master server to list
  the server on (`+masterserver`) and load room IDs.
- **Extra parameters** — anything else; sets of them can be saved.
- The resulting command line is shown at the bottom and can be copied.

## Characters

The `+skin` picker shows the characters of the game and of the queued add-ons
with their icon, portrait and the description from the character select menu
(with SRB2 colors). In SRB2Kart, Ring Racers and BlanKart each character also
shows its speed and weight (`kartspeed`, `kartweight` from S_SKIN, 1–9; 5 if
not set) and a 9×9 grid like the game's: speed left to right, weight top to
bottom. The same stats are in the tooltips and on the add-on page.

- The icon is the character's badge (`XTRAC0` in SRB2, `facerank`/`facewant`
  in SRB2Kart, `face` in SRB2 Legacy, `XTRAB0` in Ring Racers); the portrait
  is the character select picture.
- If one of the pictures is missing, the other is used; if both are, the
  standing sprite (`STNDA2`, or `STNDA8` mirrored).
- The icon is recolored to the chosen color and to team colors.

## Colored titles

SRB2 color codes in level titles and descriptions — `^0`–`^9`, `^A`–`^F`,
`\XX` or the bytes \x80–\x8F — are shown in color everywhere: in the server
list, on add-on pages, in the map picker, in the Warp field and in the player.
