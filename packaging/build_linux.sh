#!/usr/bin/env bash
# Local Linux build, the same steps as the linux-appimage job in
# .github/workflows/build.yml. Run from the repository root (in WSL: keep the
# clone in the Linux file system, under ~/, not in /mnt/c):
#
#   bash packaging/build_linux.sh
#
# Result: SRB2-Autonomi-Launcher-x86_64.AppImage in the repository root.
set -euo pipefail

FLUTTER_WANT="$(sed -n "s/^  FLUTTER_VERSION: '\(.*\)'/\1/p" .github/workflows/build.yml | head -1)"
FLUTTER_HAVE="$(flutter --version --machine 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["frameworkVersion"])' || echo '?')"
if [ "$FLUTTER_HAVE" != "$FLUTTER_WANT" ]; then
  echo "WARNING: Flutter $FLUTTER_HAVE, the builds use $FLUTTER_WANT (see FLUTTER_VERSION in build.yml)." >&2
fi

flutter pub get

# Host countries on the Servers tab (DB-IP Lite). Not fatal.
python3 tools/build_geoip.py assets/geoip/country.bin || echo "WARNING: GeoIP database not built" >&2

# The bundle is made anew (it goes into the AppImage as a whole): no files
# left over from earlier builds.
rm -rf build/linux/x64/release/bundle
# Launcher version: $BUILD_VERSION, or the release tag on this commit
# (beta-release3); the launcher compares it with the latest release.
VERSION="${BUILD_VERSION:-$(git describe --tags --exact-match 2>/dev/null || true)}"
NO_OPUS_OGG_LIBS=1 flutter build linux --release \
  --dart-define=BUILD_DATE="$(date -u '+%Y-%m-%d %H:%M UTC')" \
  --dart-define=BUILD_COMMIT="$(git rev-parse --short=7 HEAD)" \
  --dart-define=BUILD_FLUTTER="$FLUTTER_HAVE" \
  --dart-define=BUILD_VERSION="$VERSION"

APPDIR=AppDir
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin/lib"
cp -r build/linux/x64/release/bundle/* "$APPDIR/usr/bin/"

# libepoxy (Flutter needs it, not every system has it).
EPOXY="$(ldd build/linux/x64/release/bundle/lib/libflutter_linux_gtk.so | awk '/libepoxy/ {print $3}' | head -1)"
if [ -z "$EPOXY" ]; then EPOXY="$(ldconfig -p | awk '/libepoxy\.so\.0/ {print $NF}' | head -1)"; fi
cp -L "$EPOXY" "$APPDIR/usr/bin/lib/"

# Music libraries (libopenmpt, libgme and the codecs libopenmpt uses).
for lib in libgme.so.0 libopenmpt.so.0 libmpg123.so.0 libogg.so.0 libvorbis.so.0 libvorbisfile.so.3; do
  path="$(ldconfig -p | awk -v l="$lib" '$1 == l && /x86-64/ {print $NF}' | head -1)"
  if [ -n "$path" ]; then cp -L "$path" "$APPDIR/usr/bin/lib/"; echo "Bundled $path"; else echo "Not found: $lib"; fi
  # Its license (Debian/Ubuntu: /usr/share/doc/<package>/copyright) goes with
  # it, in lib/licenses (libgme is LGPL).
  pkg="$(dpkg -S "$(readlink -f "$path" 2>/dev/null || echo "$path")" 2>/dev/null | head -1 | cut -d: -f1)"
  if [ -n "$path" ] && [ -n "$pkg" ] && [ -f "/usr/share/doc/$pkg/copyright" ]; then
    mkdir -p "$APPDIR/usr/bin/lib/licenses"
    cp "/usr/share/doc/$pkg/copyright" "$APPDIR/usr/bin/lib/licenses/$pkg.copyright"
  fi
done

# antd: downloaded (or from .antd-cache); without it the build goes on.
ANTD_CACHE=.antd-cache bash packaging/fetch_antd.sh antd-linux-amd64 "$APPDIR/usr/bin/antd" antd

cp packaging/linux/AppRun "$APPDIR/AppRun"
chmod +x "$APPDIR/AppRun"
cp packaging/linux/srb2al.desktop "$APPDIR/"
cp packaging/linux/srb2al.png "$APPDIR/srb2al.png"
# The repository the launcher offers to connect on the first start (it also
# looks for pointer.txt next to the .AppImage, which wins).
cp packaging/pointer.txt "$APPDIR/usr/bin/pointer.txt"
# Attribution of the data in the launcher (DB-IP, flags).
cp packaging/NOTICE.txt "$APPDIR/usr/bin/NOTICE.txt"
# Custom games (BlanKart) offered on the first start.
cp packaging/another_games.json "$APPDIR/usr/bin/another_games.json"

if [ ! -x appimagetool-x86_64.AppImage ]; then
  curl -fSL --retry 5 --retry-delay 10 --retry-all-errors -o appimagetool-x86_64.AppImage \
    https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
  chmod +x appimagetool-x86_64.AppImage
fi
ARCH=x86_64 ./appimagetool-x86_64.AppImage --appimage-extract-and-run "$APPDIR" SRB2-Autonomi-Launcher-x86_64.AppImage
echo "Done: $(pwd)/SRB2-Autonomi-Launcher-x86_64.AppImage"
