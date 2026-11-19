# Progress (experimental)

**English** | [Русский](progress.ru.md)

The **Progress** tab is turned on in Settings → Experimental (off by default)
and comes after Music. It shows your single player progress the way the
game's Statistics and Record Attack screens do — for **SRB2**, **SRB2
Legacy**, **SRB2Kart** and **Ring Racers**. Progress files are only read; the
launcher does not change them.

## SRB2 and SRB2 Legacy

- **Summary**, like Statistics: play time, the sum of Record Attack records
  (score, time, rings; "not cleared: N" where there is no record), emblems X/Y
  (extra ones included), how many times the game was cleared (with all
  emeralds, in Ultimate), the file's path and save time.
- **Levels**, like Statistics: picture, title with SRB2 colors, the level's
  emblems (collected ones in their color; the tooltip tells what is needed and
  the haiku hint), records with the emblem goal, marks for cleared, all
  emeralds, Ultimate, Perfect. NiGHTS levels show grade, score and time per
  mare. The `-warp` button sets the level on the Launch tab.
- **Extra emblems** and **secrets** with their conditions; hidden locked ones
  show as "???".
- "Unvisited levels" also shows levels you have not been to.

## Level packs

- The picker at the top: the game or an add-on with its own progress. As in
  the game, only an add-on that declares `GameData = name.dat` in its SOC
  `MainCfg` has its own progress; levels, emblems and secrets come from the
  game's SOC and then the add-on's. A level pack shows only its own levels.
- Add-ons are found among those downloaded from repositories (the queued
  version, otherwise the newest) and those added with **Add Map Pack** (for
  SRB2 Legacy the only way so far). The ✎ button sets which files of a pack
  are loaded and in which order.
- Badges: Cleared, 100% (all emblems), Ultimate. A pack can be hidden (bring it
  back in Settings → Experimental); an add-on with its own progress has a
  Progress row on its Addons page.
- **Play** starts the game with the pack's files only — no Launch options,
  queue, netgame or `-warp`: with them the game does not save progress.

## SRB2Kart

Play time, matches played, Grand Prix cleared, visited and cleared tracks,
Record Attack records (time and best lap), medals, extra emblems and secrets
(cups, Hard, Encore, Hell Attack). Level packs with their own `GameData` work
as in SRB2.

## Ring Racers

A tab of its own: summary (time per mode, rounds, rings, Chao keys,
challenges, medals), profiles (name, character in its color, follower, wins),
Grand Prix cups by difficulty (best place, grade, emerald, best character),
characters with wins and **Time Attack** — tracks by cup with Time Attack / SPB
Attack records and the badges of Statistics.

Refresh rereads everything; otherwise a file is read again only when the game
changes it. How the progress files work is in
[internals.md](../internals.md#progress-files).
