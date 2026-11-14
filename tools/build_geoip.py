#!/usr/bin/env python3
"""Builds assets/geoip/country.bin (IPv4 -> country) for the Servers tab.

Source: DB-IP "IP to Country Lite" (https://db-ip.com), CC BY 4.0 (from the
npm package @ip-location-db/dbip-country, or db-ip.com directly) — the
launcher credits it in the README. Run in CI before `flutter build`:

    python3 tools/build_geoip.py assets/geoip/country.bin

Format (see lib/services/geoip.dart): b"GEO4", count (uint32 BE), then
`count` ranges sorted by start: start (uint32 BE) + country (2 ASCII bytes,
"--" = unknown). A range lasts until the next one starts.
"""
import csv
import datetime
import gzip
import io
import ipaddress
import json
import struct
import sys
import tarfile
import time
import urllib.request

# Те же данные DB-IP Lite в npm-пакете (обновляется каждый месяц): registry
# npm доступен из CI надёжнее, чем download.db-ip.com (тот отвечает 403).
NPM = "https://registry.npmjs.org/@ip-location-db/dbip-country"
URL = "https://download.db-ip.com/free/dbip-country-lite-{}.csv.gz"
HEADERS = {"User-Agent": "Mozilla/5.0 (compatible; launcher-geoip-build)"}


def get(url: str) -> bytes:
    with urllib.request.urlopen(urllib.request.Request(url, headers=HEADERS), timeout=180) as r:
        return r.read()


def from_npm() -> bytes:
    meta = json.loads(get(NPM))
    tarball = meta["versions"][meta["dist-tags"]["latest"]]["dist"]["tarball"]
    with tarfile.open(fileobj=io.BytesIO(get(tarball)), mode="r:gz") as tar:
        member = tar.getmember("package/dbip-country-ipv4.csv")
        return tar.extractfile(member).read()


def from_dbip() -> bytes:
    today = datetime.date.today()
    last = None
    for month in [today, today.replace(day=1) - datetime.timedelta(days=1)]:  # этот месяц, затем прошлый
        try:
            return gzip.decompress(get(URL.format(month.strftime("%Y-%m"))))
        except Exception as e:  # месяц ещё не выложен
            last = e
    raise last


def fetch() -> bytes:
    last_error = None
    for attempt in range(3):
        for source in (from_npm, from_dbip):
            try:
                return source()
            except Exception as e:  # сбой сети — следующий источник / попытка
                last_error = e
                print(f"{source.__name__}: {e}")
        time.sleep(5 * (attempt + 1))
    raise SystemExit(f"cannot download DB-IP Lite: {last_error}")


def main(out_path: str) -> None:
    ranges = []  # (start, end, country)
    for row in csv.reader(io.StringIO(fetch().decode("utf-8"))):
        if len(row) < 3 or ":" in row[0]:
            continue  # IPv6 — servers are listed by IPv4
        start = int(ipaddress.IPv4Address(row[0]))
        end = int(ipaddress.IPv4Address(row[1]))
        code = row[2].strip().upper()
        if len(code) != 2 or not code.isalpha() or code == "ZZ":
            code = "--"
        ranges.append((start, end, code))
    ranges.sort()

    entries = []  # (start, country), gaps filled with "--", neighbours merged
    expected = 0
    for start, end, code in ranges:
        if start > expected:
            entries.append((expected, "--"))
        if not entries or entries[-1][1] != code:
            entries.append((start, code))
        expected = max(expected, end + 1)
    if expected <= 0xFFFFFFFF:
        entries.append((expected, "--"))
    entries = [e for i, e in enumerate(entries) if i == 0 or e[1] != entries[i - 1][1]]

    with open(out_path, "wb") as f:
        f.write(b"GEO4" + struct.pack(">I", len(entries)))
        for start, code in entries:
            f.write(struct.pack(">I", start) + code.encode("ascii"))
    print(f"{out_path}: {len(entries)} ranges")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "assets/geoip/country.bin")
