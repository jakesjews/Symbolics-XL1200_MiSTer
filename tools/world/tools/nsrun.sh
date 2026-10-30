#!/bin/sh
# Run a command inside the VLM's private user+network namespace (as namespace "root").
#   tools/nsrun.sh ip addr
#   tools/nsrun.sh tcpdump -Z root -n -i tap0
HERE=$(cd "$(dirname "$0")/.." && pwd)
P=$(cat "$HERE/run/genera.pid" 2>/dev/null)
if [ -z "$P" ] || ! kill -0 "$P" 2>/dev/null; then
    P=$(pgrep -f "linux-vlm/src/gener[a]" | head -1)
fi
[ -z "$P" ] && { echo "VLM is not running" >&2; exit 1; }
exec nsenter -t "$P" -U -n --preserve-credentials "$@"
