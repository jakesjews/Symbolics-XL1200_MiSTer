#!/usr/bin/env bash
# Test the core on the MiSTer (ssh root@mister).
#   tools/mister/run.sh load RBF      copy the core to _Computer and start it
#   tools/mister/run.sh shot OUT.png  take a screenshot and fetch it
#   tools/mister/run.sh type TEXT     type on the core (tools/mister/kbd.py)
set -euo pipefail
# file arguments are relative to where this is run from
if [ $# -ge 2 ] && [ "$1" != type ] && [ "${2#/}" = "$2" ]; then set -- "$1" "$PWD/$2"; fi
cd "$(dirname "$0")"
case "$1" in
  load)
    name=XL1200_$(date +%Y%m%d).rbf
    scp -q "$2" "root@mister:/media/fat/_Computer/$name"
    # a core copied while Quartus was still writing it won't configure, and
    # MiSTer quits (no picture); only load an exact copy
    want=$(md5 -q "$2")
    got=$(ssh root@mister "sync; md5sum /media/fat/_Computer/$name" | cut -d' ' -f1)
    if [ "$want" != "$got" ]; then echo "copy differs from $2; not loading" >&2; exit 1; fi
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
