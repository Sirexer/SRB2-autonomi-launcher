#!/usr/bin/env bash
# Puts libopenmpt and libgme (the music player's tracker and console music
# libraries, as in the game) with their MSYS2 dependencies into the lib folder
# next to the Windows build. Runs in an MSYS2 MINGW64 shell from the
# repository root: the windows job in build.yml and packaging/build_windows.ps1.
set -u

dest="build/windows/x64/runner/Release/lib"
for pkg in mingw-w64-x86_64-libopenmpt mingw-w64-x86_64-libgme; do
  pacman -S --noconfirm --needed "$pkg" || echo "Package not available: $pkg"
done
mkdir -p "$dest"
found=0
copied=()
for dll in /mingw64/bin/libopenmpt*.dll /mingw64/bin/libgme*.dll; do
  [ -f "$dll" ] || continue
  found=1
  cp "$dll" "$dest/"
  copied+=("$dll")
  echo "Bundled $dll"
  # Their dependencies from mingw64 (codecs, libstdc++...), not system DLLs.
  for dep in $(ldd "$dll" | awk '$3 ~ /^\/mingw64\// {print $3}'); do
    cp -n "$dep" "$dest/" && copied+=("$dep") && echo "  + $dep"
  done
done

# The license files of the packages these DLLs come from (libgme is LGPL:
# its license has to go with it), in lib/licenses/<package>.
for f in "${copied[@]}"; do
  pkg="$(pacman -Qoq "$f" 2>/dev/null | head -1)"
  [ -n "$pkg" ] || continue
  name="${pkg#mingw-w64-x86_64-}"
  if [ -d "/mingw64/share/licenses/$name" ] && [ ! -d "$dest/licenses/$name" ]; then
    mkdir -p "$dest/licenses"
    cp -r "/mingw64/share/licenses/$name" "$dest/licenses/$name" && echo "  license: $name"
  fi
done
ls -la "$dest"
[ "$found" = 1 ] || { echo "No libopenmpt/libgme DLLs in /mingw64/bin" >&2; exit 1; }
