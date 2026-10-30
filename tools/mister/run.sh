#!/usr/bin/env bash
# Test the core on the MiSTer (ssh root@mister).
#   tools/mister/run.sh load RBF      copy the core to _Computer and start it
#   tools/mister/run.sh shot OUT.png  take a screenshot and fetch it
#   tools/mister/run.sh type TEXT     type on the core (tools/mister/kbd.py)
set -euo pipefail
cd "$(dirname "$0")"
case "$1" in
  load)
    name=XL1200_$(date +%Y%m%d).rbf
    scp -q "$2" "root@mister:/media/fat/_Computer/$name"
    ssh root@mister "echo 'load_core /media/fat/_Computer/$name' > /dev/MiSTer_cmd"
    ;;
  shot)
    before=$(ssh root@mister 'ls -t /media/fat/screenshots/XL1200/ 2>/dev/null | head -1')
    ssh root@mister 'echo screenshot > /dev/MiSTer_cmd'
    for _ in $(seq 20); do
      sleep 1
      latest=$(ssh root@mister 'ls -t /media/fat/screenshots/XL1200/ 2>/dev/null | head -1')
      [ -n "$latest" ] && [ "$latest" != "$before" ] && break
    done
    scp -q "root@mister:/media/fat/screenshots/XL1200/$latest" "$2"
    echo "$2"
    ;;
  type)
    scp -q kbd.py root@mister:/tmp/kbd.py
    ssh root@mister "python3 /tmp/kbd.py $(printf '%q' "$2")"
    ;;
  *) echo "usage: $0 load RBF | shot OUT.png | type TEXT" >&2; exit 2 ;;
esac
