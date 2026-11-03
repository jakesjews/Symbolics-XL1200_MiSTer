#!/usr/bin/env bash
# Test the core on the MiSTer over ssh: MISTER is its login (default root@mister).
#   tools/mister/run.sh load RBF      copy the core to _Computer and start it
#   tools/mister/run.sh shot OUT.png  take a screenshot and fetch it
#   tools/mister/run.sh type TEXT     type on the core (tools/mister/kbd.py)
#   tools/mister/run.sh mgl NAME      start the core from _Computer/NAME.mgl (mounts its disk)
# With direct video on, MiSTer's screenshots are tiny: put direct_video=0 in the
# [XL1200] section of MiSTer.ini while testing.
set -euo pipefail
mister=${MISTER:-root@mister}
# file arguments are relative to where this is run from
if [ $# -ge 2 ] && [ "$1" != type ] && [ "$1" != mgl ] && [ "${2#/}" = "$2" ]; then set -- "$1" "$PWD/$2"; fi
cd "$(dirname "$0")"
# A command to MiSTer's main program. Loading a core re-executes the program,
# which recreates /dev/MiSTer_cmd; a write that opened the old pipe in that
# window blocks forever, so give each attempt a few seconds and try again.
cmd() {
  for _ in 1 2 3 4 5 6; do
    ssh "$mister" "timeout 5 sh -c 'echo \"$1\" > /dev/MiSTer_cmd'" && return 0
    sleep 2
  done
  echo "MiSTer did not take: $1" >&2
  return 1
}
case "$1" in
  load)
    name=XL1200_$(date +%Y%m%d).rbf
    scp -q "$2" "$mister:/media/fat/_Computer/$name"
    # a core copied while Quartus was still writing it won't configure, and
    # MiSTer quits (no picture); only load an exact copy
    want=$(md5 -q "$2")
    got=$(ssh "$mister" "sync; md5sum /media/fat/_Computer/$name" | cut -d' ' -f1)
    if [ "$want" != "$got" ]; then echo "copy differs from $2; not loading" >&2; exit 1; fi
    cmd "load_core /media/fat/_Computer/$name"
    ;;
  mgl)
    cmd "load_core /media/fat/_Computer/$2.mgl"
    ;;
  shot)
    before=$(ssh "$mister" 'ls -t /media/fat/screenshots/XL1200/ 2>/dev/null | head -1')
    cmd screenshot
    for _ in $(seq 20); do
      sleep 1
      latest=$(ssh "$mister" 'ls -t /media/fat/screenshots/XL1200/ 2>/dev/null | head -1')
      [ -n "$latest" ] && [ "$latest" != "$before" ] && break
    done
    scp -q "$mister:/media/fat/screenshots/XL1200/$latest" "$2"
    echo "$2"
    ;;
  type)
    scp -q kbd.py "$mister":/tmp/kbd.py
    ssh "$mister" "python3 /tmp/kbd.py $(printf '%q' "$2")"
    ;;
  *) echo "usage: $0 load RBF | shot OUT.png | type TEXT" >&2; exit 2 ;;
esac
