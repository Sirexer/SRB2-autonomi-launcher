# Add-on repository format (index_version 2)

**English** | [Русский](manifest-format.ru.md)

A repository is one JSON file. It is added to the launcher by its Autonomi
address, as text or as a file (the Add Repository button).

## Example

```json
{
  "index_version": 2,
  "repository_name": "SRB2 Hub",
  "mods": [
    {
      "id": "knockout",
      "name": "KNOCKOUT",
      "category": "Characters",
      "uploader": "Scarf The Wolf",
      "description": "HEY IT'S ME!! IT'S VERITY!!!",
      "tags": ["character", "demo"],
      "image_hash": "<picture address on Autonomi>",
      "files": [
        {
          "name": "CL_Knockout-V1.4a(Demo).pk3",
          "version": "V1.4a(Demo)",
          "hash": "<file address on Autonomi>",
          "md5": "<file md5>",
          "size": 170309009,
          "changelog": "First demo"
        },
        {
          "name": "CL_Knockout-V1.4b(Demo).pk3",
          "version": "V1.4b(Demo)",
          "hash": "<file address on Autonomi>",
          "md5": "<file md5>",
          "size": 170400000,
          "changelog": "Bug fixes"
        }
      ]
    }
  ]
}
```

## Add-on fields

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | Unique id inside the repository. |
| `name` | yes | Name. The folder `DOWNLOAD/<name>/` is named after it. |
| `category` | no | Category in the list; without it "Other" (at the end). |
| `uploader` | no | Who uploaded the add-on to the repository (a string or a list). The old field `authors` is read too. Can differ per version (below). |
| `description` | no | Description. Can differ per version. |
| `tags` | no | Tags (for search and hiding). Can differ per version. |
| `games` | no | Games the add-on is for (see Games). Default `["srb2"]`. Can differ per version (below). |
| `image_hash` | no | Picture address on Autonomi. |
| `files` | yes | Files of all versions (see below). |

### Per-version fields

`tags`, `uploader`, `description` and `games` are either one value for all
versions, as before, or a map "version → value" (the key is the files'
`version`):

```json
"tags": {
  "2.0.2": ["workshop", "blue_sphere", "maps"],
  "2.0.3": ["workshop", "blue_sphere", "maps", "lol"]
},
"uploader": {"1.0": "Old Person", "2.0": ["A", "B"]},
"games": {"2.0.2": ["srb2"], "2.0.3": ["srb2", "drrr"]},
"description": "One description for all versions"
```

A version without its own entry takes the value of the nearest older version
in the map (or, if there is no older one, the nearest newer), so you only list
the versions where something changed. The add-on page shows the chosen
version's values; the list, search and tag panel use the latest version's.
A file's own `games` wins over the add-on's: in the example above version
2.0.3 and later are in Ring Racers too, and 2.0.2 only in SRB2.

## File fields

| Field | Required | Meaning |
|---|---|---|
| `name` | yes | File name (`.pk3`, `.wad`, `.lua`, `.soc`). Name only, no folders. |
| `version` | yes | The version the file belongs to. |
| `hash` | yes | File address on Autonomi. |
| `md5` | yes | The file's MD5 — the launcher checks downloads with it, and SRB2 finds the file for servers by it. |
| `size` | no | Size in bytes (for download progress). |
| `changelog` | no | What changed in this version. |
| `games` | no | Games this file is for; default as the add-on. |
| `type` | no | File type: `"addon"` (default), `"models"`, `"app_windows"`, `"app_linux"`. `"models"` is for 3D model packs (imported into model packs library). `"app_windows"` and `"app_linux"` are custom game builds; only the matching build is shown on the user's OS and prompts for an install folder. |

## Tags

Tags are free strings; the launcher lowercases them. Tags are used to search
and hide add-ons (＋/－ on a tag, hidden tags in Settings → Addons), so one
word without spaces that does not start with `-` works best (`-tag` in search
means "without"). Tags match exactly: `oldschool` and `oldshcool` are different
tags, so spell them as in the lists below.

The recommended tags keep repositories consistent.

### Marks

| Tag | Meaning |
|---|---|
| `featured` | Picked by the repository's curators. |
| `open_assets` | The add-on's assets may be reused in your own add-ons. |
| `mixels` | Mixed graphic resolutions: sprites, objects or textures in another resolution next to normal ones. |
| `w.i.p.` | Work in progress. |
| `demo` | Demo version. |

### Purpose

| Tag | Meaning |
|---|---|
| `mod_dev` | For map and mod makers: resources (textures, objects, sounds), testing and debugging tools. Players do not need it. |
| `serv_management` | For server hosts: administration, moderation, service commands (for example LithiumCore). Not needed for single player. |

### Source — `source:`

| Tag | Where the add-on comes from |
|---|---|
| `source:ws` | SRB2 Workshop. |
| `source:mb` | SRB2 Message Board. |
| `source:gb` | GameBanana. |
| `source:sb` | SKYBASE. |
| `source:game_server` | Downloaded from a game server. |
| `source:unknown` | Unknown source. |

### Message Board rules — `section:`

| Tag | Meaning |
|---|---|
| `section:blue_sphere` | The add-on follows the Message Board rules. |
| `section:red_sphere` | The add-on breaks the Message Board rules: a server with it can get banned from the master server. |

### Contents

| Tag | What the add-on has |
|---|---|
| `maps` | Levels. |
| `characters` | Characters. |
| `assets` | Resources: graphics, sounds, objects. |
| `lua` | Lua scripts. |
| `sprites` | Sprites. |
| `textures` | Textures. |
| `music` | Music. |
| `badniks` | Enemies (badniks). |
| `bosses` | Bosses. |
| `gimmicks` | Level gimmicks (new objects and devices on maps). |

### Maps

| Tag | Meaning |
|---|---|
| `single_map` | One map. |
| `map_pack` | A map pack — together with one of the sizes below, so ＋`map_pack` finds all packs. |
| `small_map_pack` | A small pack: 2–5 maps. |
| `medium_map_pack` | A medium pack: 6–15 maps. |
| `large_map_pack` | A large pack: 16 maps or more. |
| `linear_maps` | Linear maps: one main path. |
| `nonlinear_maps` | Non-linear maps: several paths, exploration. |
| `slope_abuse` | Very many slopes, including ones with no gameplay use. |
| `minimum_slopes` | Few slopes. |
| `no_slopes` | No slopes. |

### Map style — `mapstyle:`

| Tag | Style |
|---|---|
| `mapstyle:oldschool` | Classic "vanilla" style of the Final Demo, 2.0 and early 2.1 days (Mystic Realm, Tortured Planet, Acid Missile, Chaos Domain…). |
| `mapstyle:vanilla` | Style of the 2.1/2.2 vanilla maps (Furen, Blast Mania, Equinox, some OLDC/ULDC and SUGOI maps). |
| `mapstyle:pancake` | Little verticality, wide spread-out maps (maps by Zaxel, Sonic1983, Sol Sestancia). |
| `mapstyle:newschool` | Modern school: very wide corridors, many slopes with no gameplay use, upscaled textures and objects (most Othius maps, MRCE, many OLDC/ULDC maps). |
| `mapstyle:mixed` | Maps that mix styles themselves or fit none of the above (some SUGOI maps, most Cyberdime and Dimension Glaber maps). |

A style is given when present, not only when it dominates: a pack gets every
style that makes a noticeable share of it (at least 2 maps or about a quarter
of the pack), not because of one map. Otherwise big packs would get every
style and the filter would be useless. A pack of different styles shows
several `mapstyle:` tags, so `mapstyle:mixed` is for maps that are mixed in
themselves.

### Gametypes — `gametype:`

`gametype:<gametype>` — the add-on (maps, mechanics) is for this gametype.
The name is as in the game, lowercase, spaces replaced with `_`:
`gametype:co-op`, `gametype:competition`, `gametype:race`, `gametype:ctf`,
`gametype:ringslinger`; add-on gametypes the same way (`gametype:rk` — Rollout
Knockout). Without a prefix: `hangout` — maps and add-ons for hanging out on a
server, `emerald_hunt` — emerald hunting.

### Ports — `port`

| Tag | Meaning |
|---|---|
| `port` | A port from another game — together with one of the refinements below. |
| `clear_port` | Ported as is, unchanged. |
| `almost_clear_port` | Almost unchanged. |
| `edited_port` | Noticeably changed. |
| `extended_port` | Extended with new content. |

### Tags recommended for hiding — `hide_tags`

```json
"hide_tags": ["hidden"]
```

Tags whose add-ons the repository recommends hiding. When the repository is
added or updated, the launcher adds new ones to the hidden tags (Settings →
Addons) if "Add recommended tags to hidden tags automatically" is on (the
default; the same checkbox is in the Add Repository window). No questions are
asked; turning the setting on adds the tags of all added repositories. A tag
removed from the hidden ones comes back with the next repository update — turn
the setting off to prevent that.

### Tag groups — `tag_groups`

The launcher's tag panel sorts tags into groups — the repository sets them
with `tag_groups` (next to `mods`):

```json
"tag_groups": [
  {
    "id": "source",
    "color": "#4FC3F7",
    "tags": ["source:ws", "source:mb", "source:gb", "source:sb", "source:game_server", "source:unknown"]
  },
  {
    "id": "content",
    "color": "#81C784",
    "tags": ["maps", "characters", "lua", "sprites", "textures", "music", "original music", "badniks", "bosses"]
  }
]
```

- `id` — group name.
- `name` — the group's title in the panel (optional). The launcher has no
  group titles of its own: without `name`, `id` is shown.
- `color` — group color, `#RRGGBB` (or `#AARRGGBB`).
- `tags` — the group's tags. A tag goes to the first group that lists it;
  unlisted ones go to "Other". A tag with its group's prefix (`source:ws` in
  group `source`) is shown without it. In search and on an add-on page a tag
  is written with its group: `source:workshop` (tag `workshop` of group
  `source`); a tag without a group is `other:tag`.
- Groups are in list order; tags in a group by number of add-ons.
- With several repositories, groups with the same `id` are merged: the tags
  add up, the color is the first repository's.
- If no repository sets `tag_groups`, the launcher groups tags itself:
  `group:name` by the prefix, tags without a prefix by a built-in list
  (`lib/services/tag_groups.dart`).

## Versions

- Files with the same `version` are **one version**. If a version has several
  files (say, a pk3 and a test map), they share `version`. The version's
  changelog is the first non-empty `changelog` among its files.
- Versions are sorted from new to old "as numbers": `2.10` is newer than
  `2.9`, `V1.4b` newer than `V1.4a`. The newest is marked latest. The order of
  files in the manifest does not matter.
- Every version has its own folder: `DOWNLOAD/<name>/<version>/<file>`.
  Versions sit side by side: SRB2 finds add-ons by name and MD5 in subfolders,
  so a server finds the right one.
- In the launcher the version is chosen on the add-on page. If the add-on's
  files are in the launch queue, the queue switches to the chosen version
  (once it is downloaded).

## Games

The launcher works with several games; the current one is chosen in the
window title, and the list shows only the add-ons (and files) for it.

| Code | Game |
|---|---|
| `srb2` | Sonic Robo Blast 2 (2.2) |
| `srb2legacy` | SRB2 Legacy (2.1) |
| `srb2kart` | SRB2Kart (1.6) |
| `drrr` | Dr. Robotnik's Ring Racers (2.4) |
| a custom game's `id` | A custom game (fork), for example `srb2blankart` — BlanKart; see [custom-games.md](custom-games.md) |

`games` is a list of codes (case does not matter; `"RingRacers"` is understood
as `drrr`, `"kart"` as `srb2kart`). A custom game with `base_addons` also shows
its base game's add-ons: BlanKart shows SRB2Kart add-ons. Set `games` on the
add-on — the default for all its files (or per version, see Per-version
fields) — and override it on a single file:

```json
{
  "id": "sonic-pack",
  "name": "Sonic Pack",
  "games": ["srb2", "drrr"],
  "files": [
    { "name": "CL_Sonic.pk3", "version": "1.0", "hash": "...", "md5": "..." },
    { "name": "KC_Sonic.pk3", "version": "1.0", "hash": "...", "md5": "...", "games": ["drrr"] }
  ]
}
```

Here SRB2 shows version 1.0 with one file, `CL_Sonic.pk3`, and Ring Racers
both files. Add-ons without `games` are SRB2 add-ons.

Files are downloaded to the game's downloads folder: `DOWNLOAD/<name>/<version>/`
for SRB2, SRB2 Legacy and SRB2Kart, `addons/DOWNLOAD/<name>/<version>/` for
Ring Racers and BlanKart.

## Old format (index_version 1)

Old manifests with `version` and `changelog` on the add-on instead of the
files are still read: the values apply to all of the add-on's files (one
version). A file's own `version` wins over the add-on's.

## Common mistakes

- JSON allows no comma after the last element (`"size": 1,}`) and needs commas
  between fields.
- Every file has its own `hash` and `md5`. The same `md5` on different files is
  almost always a copy-paste error: such a file fails the check after
  downloading.
