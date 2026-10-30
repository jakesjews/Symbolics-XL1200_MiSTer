#!/bin/sh
# Runs INSIDE the unprivileged user+network namespace created by pasta (see run-genera.sh).
# We are "root" only inside this namespace, which is enough to create the tap device the
# VLM needs and to bind the NFS ports.  Nothing here touches the host's network.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
: "${VLM_TAP:=tap0}"
# The VLM assumes the Linux end of the link is .1 on the guest's /24 (Genera's DIS-EMB-HOST).
: "${VLM_HOST_IP:=10.0.0.1}"
: "${VLM_GUEST_IP:=10.0.0.2}"

ip link set lo up
ip tuntap add dev "$VLM_TAP" mode tap
ip addr add "$VLM_HOST_IP/24" dev "$VLM_TAP"
ip link set "$VLM_TAP" up

# User-space NFS v2 server so Genera can read/write DIS-EMB-HOST:/home/... files.
if [ "${VLM_NFS:-1}" != 0 ]; then
    setsid python3 -I "$HERE/tools/nfs2d.py" --bind "$VLM_HOST_IP" \
        --root "${VLM_NFS_ROOT:-$HERE/work}" --log "$HERE/run/nfs2d.log" \
        > "$HERE/run/nfs2d.out" 2>&1 < /dev/null &
fi

cd "$HERE/run"
exec "$HERE/linux-vlm/src/genera" \
    -world "${VLM_WORLD:?set VLM_WORLD to the world file}" \
    -debugger "${VLM_DEBUGGER:?set VLM_DEBUGGER to the VLM_debugger file}" \
    -network "$VLM_TAP:INTERNET|$VLM_GUEST_IP;mask=255.255.255.0;gateway=$VLM_HOST_IP" \
    -vm "${VLM_VM_MB:-2048}" \
    "$@"
