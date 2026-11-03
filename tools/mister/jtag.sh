#!/usr/bin/env bash
# The MiSTer's FPGA over a USB-Blaster on its JTAG header. Quartus runs in the
# same Docker image as build.sh, as root with the USB bus passed through, on the
# Linux machine the Blaster is plugged into: JTAG_HOST over ssh (unset: here).
# MISTER is the MiSTer's ssh login (default root@mister).
#   tools/mister/jtag.sh chain      list the JTAG chain (HPS, then the FPGA)
#   tools/mister/jtag.sh load SOF   configure the FPGA from a .sof
# After a load, MiSTer's main program is restarted: it finds the core already
# in the FPGA, sets up video and mounts the disk images as on a core load.
# Loading a core from the menu afterwards puts the SD card's .rbf back.
set -euo pipefail
image=${QUARTUS_IMAGE:-theypsilon/quartus-lite-c5:17.0.2.docker0}
remote_dir=${REMOTE_DIR:-xl1200-jtag}
mister=${MISTER:-root@mister}
on_host() { if [ -n "${JTAG_HOST:-}" ]; then ssh "$JTAG_HOST" "$1"; else bash -c "$1"; fi; }
run() {
  on_host "docker run --rm --privileged -v /dev/bus/usb:/dev/bus/usb -v \$HOME/$remote_dir:/work \
    -w /work $image /opt/intelFPGA_lite/quartus/bin/$*"
}
case "${1:-}" in
  chain)
    on_host "mkdir -p ~/$remote_dir"
    run jtagconfig
    ;;
  load)
    sof=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
    on_host "mkdir -p ~/$remote_dir"
    if [ -n "${JTAG_HOST:-}" ]; then scp -q "$sof" "$JTAG_HOST:$remote_dir/core.sof"; else cp "$sof" ~/"$remote_dir"/core.sof; fi
    run quartus_pgm -c 1 -m jtag -o "'p;core.sof@2'"
    ssh "$mister" 'killall MiSTer; sleep 1; cd /media/fat && (setsid ./MiSTer </dev/null >/dev/console 2>&1 &)'
    ;;
  *) echo "usage: $0 chain | load SOF" >&2; exit 2 ;;
esac
