#!/usr/bin/env bash
# apt-get install with retries. The runners' Azure mirror sometimes stops
# resolving ("Temporary failure resolving 'azure.archive.ubuntu.com'") and
# apt then waits for ages: after a failed attempt the mirror is dropped and
# archive.ubuntu.com is used instead.
set -u
opts=(-o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30)
for attempt in 1 2 3; do
  if sudo apt-get "${opts[@]}" update && sudo apt-get "${opts[@]}" install -y "$@"; then
    exit 0
  fi
  echo "apt-get failed (attempt $attempt), switching away from the Azure mirror"
  for f in /etc/apt/apt-mirrors.txt /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [ -f "$f" ] && sudo sed -i 's#http://azure.archive.ubuntu.com/ubuntu#http://archive.ubuntu.com/ubuntu#g' "$f"
  done
  sleep $((attempt * 15))
done
exit 1
