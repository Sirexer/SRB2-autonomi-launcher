# Servers tab

**English** | [Русский](servers.ru.md)

## List

- Servers come from the game's master servers; their lists are merged. Every
  server is queried directly, like the game does: name, players, ping, map,
  gametype, version, add-on list.
- Columns sort by clicking their title; names are shown with SRB2 colors.
  My servers (★) are always on top.
- Icons before the name: the host's country flag ("?" unknown, "(lh)" this
  computer), dedicated or listen server, vanilla or modified, cheats, why you
  cannot join (ban, full, closed) and "from the local list". The country comes
  from a database inside the launcher — addresses are not sent anywhere.
- The server's version is a plain chip: the launcher does not know which game
  version you have installed, so servers of another version are not marked.

## Filters

My servers, Hide empty, Hide offline (on by default), Modified, Hide local
list and gametypes (including add-on gametypes). In Settings → Servers:

- **Hide unsupported servers** — those answering "Unsupported server
  (different game version)";
- **Hide IPv6 addresses** (on by default) — you cannot really join them, and
  they are not queried.

Your servers are always shown.

## Blacklist

Shared by all games. The button next to the star on a server's page adds:

- this server (IP:port);
- every server at this IP;
- servers with a word in the name (case and colors do not matter).

Such servers are hidden, and those added by address are not even queried.
The list and manual adding are in Settings → Servers → Blacklist.

## Master servers, your servers, local list

- **Master servers** (Settings → Servers): name, address and status, an
  on/off switch, Check, Edit, Remove, Add. An address is an http(s) URL or
  `host:port` (old 2.1 master servers).
- **Your servers** (the "+" button or ★ on a server) are queried directly and
  work without a master server.
- **Local list**: servers seen on the master server are saved and stay in the
  list (with a clock) when the master server is down. They are kept for a
  time counted from the server's last answer: forever, a month, a week, a day,
  or not saved.

## Joining and server add-ons

A server's add-ons are compared with the game folder by name and checksum
(like the game does). **Join** (or a double click) first downloads the
missing add-ons to the downloads folder, then starts the game. Sources, in
order:

1. your repositories, if they have the same file (no load on the server);
2. the server's HTTP mirror, if it has one;
3. the server itself, with the game's own protocol (if downloading is
   allowed there and the file is not too large).

If one source fails, the next one is tried. Downloads can be cancelled;
**Download missing** downloads without joining and keeps going when you
switch tabs.

With "Load addons into the game before connecting", the server's add-ons are
passed with `-file` in the server's order and the game joins without the
"Loading addons" screen; without it the game loads them itself. BlanKart has
no such checkbox: it loads a server's add-ons only by itself.
