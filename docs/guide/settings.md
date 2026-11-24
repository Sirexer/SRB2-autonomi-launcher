# Settings and everything else

**English** | [Русский](settings.ru.md)

## Settings window

All settings are in the **Settings** window (the gear at the top). The shared
sections come first: **General** (language, theme, Autonomi, launcher build,
updates, data), **Games** (which games are in the switcher, custom games),
**Addons** (hidden tags, tags on the add-on page, repository updates, list
sections), **Experimental** (player, progress, save protection). Below, under
the **game** picker, are the game's sections: **Game folder**, **Launch**
(executables), **Servers** and [**Models**](#3d-models). The game can be picked right in the window —
it does not change the launcher's current game. The settings buttons on the
tabs open the matching section.

## First start

A wizard is shown once:

1. **language and theme** — your system's language is preselected if there is
   a translation;
2. **repository** from `pointer.txt` — download and add it or not;
3. **games** — which to show and which custom games to add from
   `another_games.json`; then, optionally, the folder and executable of each
   game (found ones are filled in);
4. **experimental features** — player, progress, save protection.

## Game folder

The folder with the game's files (`srb2.pk3`, `bios.pk3`…; usually found by
itself on Linux). The game is started with it as the working folder, so
`config.cfg`, saves and the downloads folder come from there even if the
executables are elsewhere. On Windows do not pick a folder inside
`C:\Program Files`: add-ons cannot be saved there without administrator
rights.

**Hidden folders** (same place, per game): add-ons in these folders are not
shown in Other downloads and In the game folder; repository add-ons are shown
anyway. A folder inside the game folder is stored relative to it.

## 3D models

Settings → **Models** (per game) puts several model packs together into one.
Models are shown only with the game's OpenGL renderer.

| Game | List | Folder | Name up to |
|---|---|---|---|
| SRB2 | `models.dat` | `models/` | 25 characters |
| SRB2Kart | `mdls.dat` | `mdls/` | 19 characters |
| Ring Racers | `models.dat` | `models/` | 23 characters |
| BlanKart | `models.dat` (then its own `blanmodels.dat`) | `models/` | 25 characters |
| SRB2 Legacy | `md2.dat` | `md2/` | 19 characters, MD2 only |

SRB2 Legacy (2.1) reads only MD2 models: MD3 ones are left out of its pack.

- **Packs.** Add a `.zip` (or a folder) with the list and the models folder.
  A pack made to be unpacked straight into `models/` (the list next to
  folders like `LFMAIN/`, no `models/` folder) works too: then the paths
  start next to the list. The game's current models can be added as a pack
  too (**Add as a pack**).
  Only the files named in the list are kept — the rest is reported. Packs are
  stored by the launcher, each on its own.
- **Order.** When packs have a model with the same name (two Sonics), the
  higher pack wins (a version without its model file is skipped); drag packs
  to reorder, switch a pack off to leave it out.
- **Models.** Every model name with its version, in two groups: characters
  (skins) and objects (sprites). As in the game, `PLAYERname` is a skin and a
  sprite name has exactly 4 characters, so other names are skins (a 4-letter
  skin name is listed under objects). Click a model to look at it:
  it turns with the mouse, plays its animations (speed, step frame by frame,
  the frame's name) and is painted in a player color the way the game does
  it (`_blend.png`). The model is shown the way the game draws it — mirrored
  compared to the file, so text on monitors reads right. Next to it are the versions
  from all packs — **Use this version**, **By pack order** or **Turn off**.
  Under the pack name each model shows what is in the game now: **in the
  game** (the same version), another file, **not in the game**, or no file.
  Models that are only in the game are listed too — they are gone after
  installing unless you add the game models as a pack. Filters: in the game,
  several versions, chosen by you, problems.
- **Checks.** The game stops reading the list at the first bad line (a
  comment, a name or path too long) and silently skips the rest; the launcher
  writes the list without comments and checks names and paths (up to 31
  characters). Models without a model file are left out. A model without its
  own texture is fine: the game uses the object's sprite. File names are
  written exactly as in the list, so the pack also works on Linux, where
  `SONIC_Blend.png` is not `SONIC_blend.png`.
- **Cleaning.** The card at the top checks the game's own list: where the
  game stops reading it, models without files, file name case. **Clean
  models.dat** removes those lines and fixes the case; the old list goes to a
  backup (only the list) and can be rolled back. In a pack, the menu has
  **Remove models without files**.
- **Same paths.** If two packs have `PLAY/SONIC.md3`, the second one goes to
  its own folder (`P2/PLAY/SONIC.md3`); a path that would be too long gets
  shorter.
- Choosing packs and versions changes only the launcher's plan: the game
  sees it after **Install to the game**. Until then a banner at the top says
  how many models are not in the game yet and has the same button.
- **Install to the game** puts the pack into the game folder; what was there
  goes to `models.srb2al-backups` (`mdls.srb2al-backups` for SRB2Kart) next
  to it. **Backups** lists the last five: **Roll back** returns one (what is
  installed then goes to a new backup). Close the game first.
- **Save as .zip** saves the same pack — the list and the models folder — to
  share it.

## Language and theme

Languages: English, Russian, Ukrainian, German, Spanish, Portuguese
(Brazilian). Until you choose one, the system's language is used. How to add
a language: [translations.md](../translations.md).

Themes: four built-in and six in the `themes` folder (Ocean, Ruby, Gold,
Steel, Midnight, the light Daylight); make your own in the editor. Details:
[themes.md](../themes.md).

## Notifications

The bell button in the title bar (order: notifications, downloads, settings);
the number is how many are new.

- **Repository updated** — new add-ons and add-ons with new versions.
- **Add-on update** — a downloaded add-on of the current game has a newer
  version. Each version is reported once (remembered after a restart too).
- **Save protection** — a save was restored, or is damaged with no copy.

## Launcher updates

New versions come from the
[GitHub releases](https://github.com/Sirexer/SRB2-autonomi-launcher/releases).
On start the launcher checks for a newer version and shows a window with the
changelog and **Update now**, **Later** (asks again next start) and **Skip
this update**. Settings → General has "Check for updates when the launcher
starts", Check for updates (shows a skipped version too) and the current
version.

Update now downloads the file for your system, checks it, replaces the
launcher and restarts it; a running game keeps running. On Windows
`user_data` (portable mode), your own `pointer.txt` and your own language
files are not touched. On Linux the AppImage is replaced; a launcher not
started from an AppImage, or without write access to its folder, opens the
download page instead.

## One launcher at a time

A second start brings the open launcher to the front and quits (two launchers
would get in each other's way). `--new-instance` opens another one anyway.

## Where the data is

- Settings, caches, themes, save copies and `antd`:
  - Windows: `%APPDATA%\SRB2 Autonomi Launcher\`
  - Linux: `~/.local/share/com.srb2.autonomi_launcher/`
  - in **portable mode** — `user_data` next to the launcher: put an empty file
    named `portable` (or `portable.txt`) next to `srb2al.exe` (or the
    `.AppImage`).

  Where it is now: Settings → General → Launcher data.
- The log is `logs/launcher.log` (the previous run: `launcher.old.log`): handy
  if something went wrong.
- Caches (`addon_contents_cache.json`, `music/scan_cache.json`,
  `music_render/`) can be deleted — they are rebuilt.
- Model packs are in `model_packs/<game>/` (one folder per pack and
  `setup.json` with the order and your choices).

## Autonomi (antd)

Add-ons are downloaded through the Autonomi daemon `antd`
([ant-sdk](https://github.com/WithAutonomi/ant-sdk)). It ships with the
launcher and starts by itself; nothing to download. If the daemon stops
answering, the launcher restarts it (at most once a minute); by hand:
Settings → General → Restart Autonomi. If you run `antd` yourself on
`127.0.0.1:8082` and it answers, the launcher uses it.

## Saving power

- Unchanged files are not analyzed again: add-ons, music and rendered tracks
  come from the cache.
- While the window is minimized, background work waits.
- Animated covers (GIF): all, only the selected one, or still — Settings →
  Addons → Animated icons.
- Groups in Addons and Music start collapsed.
