#!/bin/sh
# Grab the whole Xvfb screen used by run-genera.sh as PNG (the .xwd is kept too).
#   ./screenshot.sh [name]   -> shots/<name>.png
HERE=$(cd "$(dirname "$0")" && pwd)
DISPLAY=$(cat "$HERE/run/display"); export DISPLAY
mkdir -p "$HERE/shots"
NAME=${1:-$(date +%Y%m%d-%H%M%S)}
# timeout: a client holding a server grab would otherwise hang xwd forever
timeout 20 xwd -root -silent > "$HERE/shots/$NAME.xwd" || { echo "xwd failed (X server grabbed or gone?)" >&2; exit 1; }
python3 -I "$HERE/xwd2png.py" "$HERE/shots/$NAME.xwd" "$HERE/shots/$NAME.png" && echo "$HERE/shots/$NAME.png"
