# Addons tab

**English** | [Русский](addons.ru.md)

## Repositories

- An add-on repository is a JSON file; the format is in
  [manifest-format.md](../manifest-format.md). Every file has its own
  `version` and `changelog`.
- Connect one with **Add Repository** (the wide button above the search box):
  by the address of the file on Autonomi, by a **pointer** (a changeable link
  to the file), as text or as a file from disk. On the first start the
  launcher offers the repository from `pointer.txt` next to it.
- Repositories added by pointer are checked on every start: if the pointer
  leads to a new file, the add-on list is updated — at once, after asking (the
  default) or never (Settings → Addons → Repository updates). The ⟳ button
  next to Add Repository checks them at any time and tells what changed; a ⟳
  button for each repository is turned on in Settings → Addons (shown when
  more than one repository is added by pointer).
- If a pointer repository is updated from a file, the pointer is kept but not
  applied on start (an icon on the repository), so the file is not
  overwritten; ⟳ updates it from the pointer.
- A repository can recommend hiding add-ons with some tags (`hide_tags`). The
  launcher adds them to the hidden tags if "Add recommended tags to hidden
  tags automatically" is on (the default; the checkbox is in Settings → Addons
  and in the Add Repository window).

## Versions and files

- An add-on with several versions has a version picker on its page (latest,
  downloaded) and the version's changelog.
- Every version has its own folder: `DOWNLOAD/<add-on>/<version>/<file>`, so
  versions do not overwrite each other. If another file is already in place
  (damaged or edited), the launcher asks: replace, keep both or cancel.
- Files are downloaded one at a time: while one is downloading, Download on
  another file queues it ("Queued" with a cross to remove it). A failed file
  does not stop the queue.
- If an add-on's files are in the launch queue, the queue switches to the
  chosen version once it is downloaded.
- If a file does not match its MD5, its "⋮" menu can replace it with this
  version, delete, rename or move it.

## Add-on page

Name, tags, description and changelog; then the files with MD5 checks and
download buttons; below, what is inside the downloaded files: **gametypes**,
**levels**, **characters** and **skin colors**. Sections collapse by clicking
their title.

- **Levels**: picture, map name and title from SOC; "?" if there is no
  picture. Clicking a map adds the file to the queue and sets `-warp <map>`;
  its "⋮" menu lists the gametypes the map supports (choosing one sets both
  `-warp` and `-gametype`).
- **Characters**: icon, portrait and the description from the character
  select menu.
- The star adds the add-on to favorites; the star button by the search box
  shows favorites only.

## Search and tags

Conditions are separated by spaces; all of them must match.

- `word` — in the name, category, uploader and the contents of the files
  (maps, gametypes, characters, colors), but not in tags; `-word` removes
  add-ons that have it.
- `group:tag` — only add-ons with the tag (`source:workshop`,
  `content:maps`), `-group:tag` — without it. Tags match exactly; quote tags
  with spaces: `"content:original music"`.
- You do not need to type the group: from two letters, matching tags drop
  down (`work` → `source:workshop`) in the group's color with the number of
  add-ons.
- The label button by the search box lists all tags of the game by group:
  click to search with a tag, click again to exclude it, a third time to
  clear. Groups and their colors come from the repository (`tag_groups`).
- Tags on an add-on page are colored by group, with ＋ (search with it) and －
  (hide add-ons with it). How tags look (with or without the group, order,
  all at once or the first 8) is set in Settings → Addons → Tags on the add-on
  page.
- Hidden tags: Settings → Addons → Hidden tags.

## Add-ons not from repositories

Files whose MD5 matches no repository file are listed at the bottom:

- **Other downloads** — from the downloads folder (`DOWNLOAD`;
  `addons/DOWNLOAD` for Ring Racers and BlanKart): downloaded from servers or
  by the game itself;
- **In the game folder** — from the rest of the game folder (for example
  `data/addons/Levels`). The folder is searched like the game does it: 10
  levels deep, without `screenshots`, `replay` and so on; the games' own
  files (`srb2.pk3`, `bios.pk3`…) are not listed.

The lists are refreshed when you open the tab and after downloads; ⟳ in a
section's title looks for new and removed files at once. Each section is
turned off by its checkbox in Settings → Addons, and single folders can be
hidden in Settings → Game folder → Hidden folders (repository add-ons are
shown anyway).

## Downloads

The **Downloads** button in the window title shows all downloads — from
repositories and from servers: progress, queue, errors and cancel (a
repository download that has started cannot be cancelled; a queued one can).
