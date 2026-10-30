#!/bin/sh
# (Re)start the user-space NFS server inside the running VLM's namespace.
HERE=$(cd "$(dirname "$0")/.." && pwd)
pkill -f "tools/nfs2[d].py"
sleep 0.5
"$HERE/tools/nsrun.sh" sh -c "setsid nohup python3 -I '$HERE/tools/nfs2d.py' --bind '${VLM_HOST_IP:-10.0.0.1}' --root '${VLM_NFS_ROOT:-$HERE/work}' --log '$HERE/run/nfs2d.log' > '$HERE/run/nfs2d.out' 2>&1 < /dev/null &"
sleep 0.5
pgrep -af "tools/nfs2[d].py"
