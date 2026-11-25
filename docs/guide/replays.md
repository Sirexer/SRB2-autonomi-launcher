# Replays (experimental)

**English** | [Русский](replays.ru.md)

The **Replays** tab is turned on in Settings → Experimental (off by default)
or during the first-run wizard. It browses `.lmp` replays for **Sonic Robo Blast
2 (2.2)**, **SRB2 Legacy (2.1)**, **SRB2Kart**, **Dr. Robotnik's Ring Racers**
and compatible forks (such as **BlanKart**), inspects their maps, characters
and required add-ons, and launches playback through `-playdemo`.

## Where replays come from

| Game | Built-in folders scanned | Imported folder |
|---|---|---|
| SRB2 (2.2) | `data/replay/`, `replay/` | `SRB2AL-Replays/` |
| SRB2 Legacy (2.1) | `replay/` | `SRB2AL-Replays/` |
| SRB2Kart | `replay/` (`kart/`, `online/`) | `SRB2AL-Replays/` |
| Ring Racers | `media/replay/` (`ringracers/`, `online/`) | `SRB2AL-Replays/` |
| BlanKart | `media/replay/` (`online/`) | `SRB2AL-Replays/` |

- **From disk...**, **From URL...** or dragging and dropping `.lmp` files into
  the tab copies them into `<game folder>/SRB2AL-Replays/` without touching the
  game's own replay directories.
- Each card's menu (`⋮`) also offers **Save copy to SRB2AL-Replays...**, **Show
  in folder** and **Delete**.
- Duplicate runs in the same folder (`-last`, `-time-best`, `-lap-best`,
  `-score-best`, `-rings-best` with matching size and header checksum) are
  grouped into one card with variant badges.

## Add-ons and playback

- **Embedded add-on list** (SRB2 2.2 `demoversion >= 16`, SRB2Kart, Ring
  Racers, BlanKart): the launcher looks up each add-on in the game folder by
  name and checksum (MD5, or XXH3-64 for BlanKart):
  - **Green check** — exact file and checksum found on disk.
  - **Amber check** — file with the same name and a different checksum was
    found on disk (for example an updated official pack such as
    `bonuschars.kart` in the game root); the launcher updates the replay header
    when launching.
  - **Download** — missing on disk, but the matching file is in a connected
    Autonomi repository.
  - **Missing** — not found on disk or in repositories; **Play** lets you
    download missing repository files or launch anyway.
- **Older replays without an add-on list** (SRB2 Legacy 2.1, SRB2 2.2
  `demoversion < 16`): add-ons are detected from the replay subfolder name
  against SOC `MainCfg → GameData` (for example `kimokawaiii`) or archive file
  names, and can be downloaded from repositories if missing.
- **Extra addons** (top bar, per game): extra files to load after the replay's
  own add-ons (for example `L_SpectatorCamera_V2.3.lua`).
- **Edit addons & play...** (`⋮` menu): toggle individual recorded add-ons and
  add extra `.lua`, `.pk3`, `.wad`, `.kart` or `.soc` files for a single run.
- When the loaded add-ons or their checksums differ from the original header,
  the launcher writes a temporary patched file to
  `SRB2AL-Replays/temp/replay.lmp` (updating the add-on list and header
  checksum, without using `-force`) and hides `temp/` from the replay list.
- The split **Play** button lets you pick a specific game build when several are
  configured.
