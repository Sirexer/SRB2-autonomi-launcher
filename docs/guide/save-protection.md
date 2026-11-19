# Save protection (experimental)

**English** | [Русский](save-protection.ru.md)

Turned on in Settings → Experimental → Save protection (off by default). The
launcher keeps **the last whole copy** of every save file and puts it back if
the file gets damaged (for example, the PC turned off while the game was
saving).

## What is checked

Only what a launch uses: the game's files and the files of packs that declare
`GameData` (the Launch queue, the pack on the Progress tab, a server's
add-ons).

| Game | Game files | Files of a pack with `GameData = mypack.dat` |
|---|---|---|
| SRB2, SRB2 Legacy | `gamedata.dat`, save slots `srb2sav*.ssg` | `mypack.dat`, slots `mypack*.ssg` |
| SRB2Kart | `kartdata.dat` | `mypack.dat` |
| Ring Racers | `ringdata.dat`, `ringprofiles.prf`, Grand Prix `gpringsav.bkp` | `mypack.dat`, `gpmypack.bkp` |

## When

- **Before every game start** (Launch, Play on Progress, joining a server):
  the launch buttons show "Checking…" meanwhile.
- **Then in the background** every 20 seconds for the files of the last
  launch: the copy is updated once a file has changed and stayed the same for
  a few seconds (also while the game runs).

A file is checked the way the game reads it: header, not cut short, the data
parses to the end.

## When a file is damaged

- Before a launch the damaged file is moved to the shared folder
  `save_backups/Damaged` (with the date and game in its name) and the copy is
  put in its place. For Ring Racers the better of two copies is used — the
  launcher's or the game's own `ringdata.dat.bak` (whichever has more play
  time).
- The **notifications button** in the title bar tells about it, with Show in
  folder. Without a copy the file is left as it is (one notification).
- **Play time went down** (progress was reset — by you or by the game): the
  copy is not overwritten, and before a launch the launcher asks: "Yes, that
  was me", "Restore the copy" or "Ask later".
- The Progress tab shows "the file is damaged" and Restore from copy instead of
  an error. The Save copies button lists the copies, restores any of them and
  opens the copies and `Damaged` folders.

Copies are kept in the launcher's data folder: `save_backups/<game>-<folder
code>/`.
