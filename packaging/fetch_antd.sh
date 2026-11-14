#!/usr/bin/env bash
# Puts antd (the Autonomi daemon) into a launcher build, so users do not have
# to download it on the first start.
#
#   packaging/fetch_antd.sh <release asset> <destination folder> <binary name>
#
# The version is the one the launcher expects (_version in
# lib/services/antd_daemon.dart). The binary is checked against SHA256SUMS of
# the same release. Sources, in order: the GitHub release, then the official
# GitLab mirror (gitlab.com/autonomi/ant-sdk); the next one is tried when a
# download or the check fails. Next to it: VERSION (the launcher uses the bundled antd
# only if it matches) and the ant-sdk licenses (MIT OR Apache-2.0).
#
# ANTD_CACHE (optional): a folder kept between CI runs (actions/cache). A
# verified download is stored there; when no source gives the release
# (on 2026-11-12 github.com/WithAutonomi/ant-sdk answered 404), the cached
# copy is used. With neither, the build goes on without antd (a warning):
# the launcher downloads it on first start, and users who already ran it
# have it in their data folder.
set -euo pipefail

asset="$1"
dest="$2"
name="$3"

version="$(sed -n "s/.*_version = '\(v[^']*\)'.*/\1/p" lib/services/antd_daemon.dart | head -1)"
if [ -z "$version" ]; then
  echo "antd version not found in lib/services/antd_daemon.dart" >&2
  exit 1
fi

# "<release files URL> <license files URL>" per source. On GitLab the
# licenses are files of the release too.
gitlab="https://gitlab.com/api/v4/projects/88885118/packages/generic/ant-sdk/$version"
sources=(
  "https://github.com/WithAutonomi/ant-sdk/releases/download/$version https://raw.githubusercontent.com/WithAutonomi/ant-sdk/$version"
  "$gitlab $gitlab"
)

# Downloads sometimes break off: retry, and show the error.
get() {
  curl -fSL --retry 5 --retry-delay 10 --retry-all-errors --connect-timeout 30 --max-time 600 -o "$2" "$1"
}

# Fills folder $1 with $asset, VERSION and the licenses from the release at
# $2 (licenses at $3); fails on any error.
fetch() {
  local out="$1" base="$2" raw="$3" tmp
  tmp="$(mktemp -d)"
  get "$base/$asset" "$tmp/$asset" || return 1
  get "$base/SHA256SUMS" "$tmp/SHA256SUMS" || return 1

  # Lines look like "<sha256>  <file>" (the file may have a "*" or a folder).
  local expected actual
  expected="$(awk -v a="$asset" '{ n = $2; sub(/^\*/, "", n); sub(/.*\//, "", n); if (n == a) print $1 }' "$tmp/SHA256SUMS" | head -1)"
  actual="$(sha256sum "$tmp/$asset" | awk '{ print $1 }')"
  if [ -z "$expected" ] || [ "$actual" != "$expected" ]; then
    echo "SHA256 mismatch for $asset: got $actual, expected ${expected:-nothing in SHA256SUMS}" >&2
    return 1
  fi
  get "$raw/LICENSE-MIT" "$tmp/LICENSE-MIT" || return 1
  get "$raw/LICENSE-APACHE" "$tmp/LICENSE-APACHE" || return 1
  mkdir -p "$out"
  cp "$tmp/$asset" "$tmp/LICENSE-MIT" "$tmp/LICENSE-APACHE" "$out/"
  printf '%s\n' "$version" > "$out/VERSION"
  rm -rf "$tmp"
}

# A complete copy of this version in folder $1?
complete() {
  [ -f "$1/$asset" ] && [ -f "$1/LICENSE-MIT" ] && [ -f "$1/LICENSE-APACHE" ] &&
    [ "$(cat "$1/VERSION" 2>/dev/null)" = "$version" ]
}

src=""
cache="${ANTD_CACHE:-}"
if [ -n "$cache" ] && complete "$cache"; then
  src="$cache"
  echo "antd $version ($asset) from the CI cache"
else
  dl="${cache:-$(mktemp -d)}"
  for s in "${sources[@]}"; do
    read -r base raw <<< "$s"
    echo "antd $version ($asset) from ${base#https://}"
    if fetch "$dl" "$base" "$raw" && complete "$dl"; then
      src="$dl"
      break
    fi
    echo "antd: ${base#https://} failed, trying the next source" >&2
  done
fi

if [ -z "$src" ]; then
  echo "::warning::antd $version ($asset) could not be downloaded and is not cached: the build has no bundled antd (the launcher downloads it on first start)."
  exit 0
fi

mkdir -p "$dest"
cp "$src/$asset" "$dest/$name"
chmod 755 "$dest/$name"
cp "$src/VERSION" "$src/LICENSE-MIT" "$src/LICENSE-APACHE" "$dest/"
echo "Bundled antd $version ($asset) into $dest"
