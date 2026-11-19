# Building and releasing

**English** | [Русский](building.ru.md)

## Flutter

You need Flutter **3.47.9** — the version CI uses (`FLUTTER_VERSION` in
`.github/workflows/build.yml`). With Flutter 3.50.0 the launcher crashed
inside the NVIDIA driver (`nvwgf2umx.dll`) on some PCs, so the version is
pinned; change it on purpose and test the Windows build.

```bash
git clone --depth 1 -b 3.47.9 https://github.com/flutter/flutter.git ~/flutter
```

Add `~/flutter/bin` to PATH. The scripts below do what CI does: build date,
commit, Flutter version and launcher version in the build, the GeoIP
database, music libraries, `antd` and packaging.

## Linux

Ubuntu (WSL works too; for an AppImage that runs on most distributions, use
Ubuntu 22.04 like CI):

```bash
sudo apt-get install -y git curl unzip xz-utils zip python3 file clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libasound2-dev libgme0 libopenmpt0
```
```bash
bash packaging/build_linux.sh
```

The result is `SRB2-Autonomi-Launcher-x86_64.AppImage` (the program itself is
in `build/linux/x64/release/bundle/`). In WSL keep the repository on the
Linux file system (`~/...`), not under `/mnt/c`: building there is many times
slower.

Sound (`flutter_soloud`) goes through ALSA, so `libasound2-dev` is needed.
Without system `libopus` and `libogg` build with `NO_OPUS_OGG_LIBS=1` (the
script does).

## Windows

Git, Visual Studio 2022 (or Build Tools) with "Desktop development with C++";
optionally Python (country database) and MSYS2 in `C:\msys64`
(libopenmpt/libgme for the player). In PowerShell, in the repository folder:

```bash
powershell -ExecutionPolicy Bypass -File packaging\build_windows.ps1
```

The result is `SRB2-Autonomi-Launcher-windows-x64.zip` (the program itself is
in `build\windows\x64\runner\Release\`). The script downloads `antd` from
GitHub, then from the GitLab mirror, and if both fail it takes the copy from
the launcher's data folder.

## Tests

```bash
flutter test
```
```bash
flutter analyze
```

## What goes into a build

| What | From | How |
|---|---|---|
| Languages | `lang/` | CMake (`install(DIRECTORY ../lang)`) |
| Themes | `themes/` | CMake (`install(DIRECTORY ../themes)`) |
| Default repository | `packaging/pointer.txt` | build scripts and CI |
| Custom games (BlanKart) | `packaging/another_games.json` | build scripts and CI |
| Data attribution | `packaging/NOTICE.txt` | build scripts and CI |
| Autonomi daemon | the [ant-sdk](https://github.com/WithAutonomi/ant-sdk) release | `packaging/fetch_antd.sh`, the Windows script |
| Server countries | DB-IP Lite database | `tools/build_geoip.py` → `assets/geoip/country.bin` |
| Flags | [flag-icons](https://github.com/lipis/flag-icons) | `tools/render_flags.js` → `assets/flags/` |
| Legacy/Kart progress data | the games' sources | `tools/gen_progress_defaults.py` |

Without the GeoIP database (a source build without the script) server
countries are simply not shown; to build it by hand:

```bash
python3 tools/build_geoip.py assets/geoip/country.bin
```

## Releasing

1. Tag a commit `beta-<something>` or `v<version>` (for example
   `beta-release3`) and push the tag to the public repository. The workflow
   `.github/workflows/build.yml` builds Windows and Linux and creates a release
   with `SRB2-Autonomi-Launcher-windows-x64.zip` and
   `SRB2-Autonomi-Launcher-x86_64.AppImage`.
2. Write the release description — the launcher's update window shows it as
   "What's new" (Markdown: headings, lists, bold).

The launcher finds the release files by these names, so do not rename them.

**The launcher version** is the release tag: CI passes it as
`--dart-define=BUILD_VERSION=<tag>`. The local scripts take the
`BUILD_VERSION` environment variable or the tag on the current commit:

```bash
BUILD_VERSION=beta-release3 bash packaging/build_linux.sh
```

In PowerShell: `$env:BUILD_VERSION = 'beta-release3'` before running the
script. How the launcher compares versions and installs an update is in
[internals.md](internals.md#launcher-updates).
