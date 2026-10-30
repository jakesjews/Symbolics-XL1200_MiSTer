#!/bin/sh
# Type into the running Genera with xdotool.
#   ./gtype.sh "(+ 1 2)"              type text into the main Genera window
#   ./gtype.sh -k Return              send keys (xdotool key names, e.g. super+a, BackSpace)
#   ./gtype.sh -w "Cold Load" TEXT    target another window by name (regex)
# A Lisp form is evaluated as soon as its closing paren is typed; Command Processor
# commands need -k Return afterwards.
HERE=$(cd "$(dirname "$0")" && pwd)
DISPLAY=$(cat "$HERE/run/display"); export DISPLAY
PAT="^Genera on"
if [ "$1" = "-w" ]; then PAT=$2; shift 2; fi
WIN=$(xdotool search --name "$PAT" | tail -1)
[ -z "$WIN" ] && WIN=$(xdotool search --name "Cold Load" | tail -1)
[ -z "$WIN" ] && { echo "no Genera window found" >&2; exit 1; }
eval "$(xdotool getwindowgeometry --shell "$WIN")"
xdotool mousemove $((X + WIDTH/2)) $((Y + HEIGHT/2))
xdotool windowfocus "$WIN" 2>/dev/null
if [ "$1" = "-k" ]; then shift; xdotool key --delay 80 "$@"; else xdotool type --delay 60 "$1"; fi
