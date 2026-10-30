#!/bin/sh
# Run the reference VLM with the Genera 8.5 world, headless.
#   ./run-genera.sh [start] [extra genera args]  start Xvfb + VLM in the background and wait
#                                                 until the Genera Lisp Listener window is up
#   ./run-genera.sh stop                          stop everything this script started
#   ./run-genera.sh status                        show what is running
# Settings (environment): VLM_SCREEN=1280x1024x24  VLM_DISPLAY_NUM=70 (first display tried)
#   VLM_WORLD, VLM_DEBUGGER, VLM_VM_MB=2048, VLM_NFS=0 (no file server), VLM_NFS_ROOT=work/ (under this directory),
#   VLM_BOOT_TIMEOUT=300 (seconds), VLM_CALENDAR_SHIFT_YEARS=28,
#   VLM_XPROXY=1 (log the VLM's X11 protocol traffic to run/xproxy.log)
HERE=$(cd "$(dirname "$0")" && pwd)
RUN="$HERE/run"
mkdir -p "$RUN"

pid_alive() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }

stop() {
    # genera itself: the VLM blocks SIGTERM, so give it a moment and then SIGKILL it
    if pid_alive "$RUN/genera.pid"; then
        kill "$(cat "$RUN/genera.pid")"; sleep 1
        pid_alive "$RUN/genera.pid" && kill -9 "$(cat "$RUN/genera.pid")"
    fi
    pkill -f "$HERE/tools/nfs2[d].py"
    pid_alive "$RUN/vlm.pid" && kill "$(cat "$RUN/vlm.pid")"           # pasta
    pid_alive "$RUN/xproxy.pid" && kill "$(cat "$RUN/xproxy.pid")"
    pid_alive "$RUN/xvfb.pid" && kill "$(cat "$RUN/xvfb.pid")"
    rm -f "$RUN/genera.pid" "$RUN/vlm.pid" "$RUN/xvfb.pid" "$RUN/xproxy.pid"
}

status() {
    if pid_alive "$RUN/genera.pid"; then
        echo "VLM running (pid $(cat "$RUN/genera.pid")) on DISPLAY=$(cat "$RUN/display")"
    else
        echo "VLM not running"
    fi
    pgrep -af "$HERE/tools/nfs2[d].py" > /dev/null && echo "NFS server running (log: $RUN/nfs2d.log)"
}

case "$1" in
    stop) stop; exit 0 ;;
    status) status; exit 0 ;;
    start) shift ;;
esac

if pid_alive "$RUN/genera.pid"; then status; exit 0; fi
stop 2>/dev/null

# Pick a free X display number.
N=${VLM_DISPLAY_NUM:-70}
while [ -e "/tmp/.X$N-lock" ] || [ -e "/tmp/.X11-unix/X$N" ]; do N=$((N+1)); done
DISPLAY=":$N"; export DISPLAY
echo "$DISPLAY" > "$RUN/display"

setsid nohup Xvfb "$DISPLAY" -screen 0 "${VLM_SCREEN:-1280x1024x24}" -nolisten tcp \
    > "$RUN/xvfb.log" 2>&1 < /dev/null &
echo $! > "$RUN/xvfb.pid"
i=0; while [ ! -e "/tmp/.X11-unix/X$N" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done

# pasta gives us an unprivileged user+network namespace (no sudo needed) in which
# genera-netns.sh can create the tap device the VLM insists on, plus the NFS server.
# pasta's AppArmor profile only lets it exec programs under /usr/bin, hence /bin/sh.
VLMDISPLAY=$DISPLAY
if [ "${VLM_XPROXY:-0}" != 0 ]; then
    # Debug: route the VLM's X connections through a protocol-logging proxy (run/xproxy.log).
    P=$((N+1)); while [ -e "/tmp/.X$P-lock" ] || [ -e "/tmp/.X11-unix/X$P" ]; do P=$((P+1)); done
    setsid nohup python3 -I "$HERE/tools/xproxy.py" "$P" "$N" "$RUN/xproxy.log" \
        > "$RUN/xproxy.out" 2>&1 < /dev/null &
    echo $! > "$RUN/xproxy.pid"
    sleep 1; VLMDISPLAY=":$P"
fi
DISPLAY=$VLMDISPLAY setsid nohup pasta --quiet -t none -u none -T none -U none -- \
    /bin/sh "$HERE/genera-netns.sh" "$@" > "$RUN/vlm.log" 2>&1 < /dev/null &
echo $! > "$RUN/vlm.pid"
echo "Genera VLM starting on DISPLAY=$DISPLAY (log: $RUN/vlm.log)"

# Wait for the main Genera window ("Genera on DIS-LOCAL-HOST").  pasta also puts the VLM in
# its own PID namespace, so record genera's host PID from out here.
T=${VLM_BOOT_TIMEOUT:-300}; t=0
while [ $t -lt "$T" ]; do
    [ -s "$RUN/genera.pid" ] || pgrep -n -f "$HERE/linux-vlm/src/gener[a]" > "$RUN/genera.pid"
    if xdotool search --name "^Genera on" > /dev/null 2>&1; then
        sleep 5      # let it finish drawing the herald
        echo "Genera is up (Lisp Listener ready) after ~${t}s"
        exit 0
    fi
    if ! pid_alive "$RUN/vlm.pid"; then
        echo "VLM exited during boot; last log lines:"; tail -20 "$RUN/vlm.log"; exit 1
    fi
    sleep 2; t=$((t+2))
done
echo "Timed out after ${T}s waiting for the Genera window (try ./screenshot.sh to see why)"
exit 1
