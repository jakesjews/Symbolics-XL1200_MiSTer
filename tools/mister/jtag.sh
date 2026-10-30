#!/usr/bin/env bash
# The MiSTer's FPGA over its USB-Blaster, which is plugged into the Ubuntu
# server (ssh ubuntu); Quartus runs in the same Docker image as build.sh, as
# root with the USB bus passed through.
#   tools/mister/jtag.sh chain      list the JTAG chain (HPS, then the FPGA)
#   tools/mister/jtag.sh load SOF   configure the FPGA from a .sof
# After a load, MiSTer's main program is restarted: it finds the core already
# in the FPGA, sets up video and mounts the disk images as on a core load.
# Loading a core from the menu afterwards puts the SD card's .rbf back.
set -euo pipefail
image=${QUARTUS_IMAGE:-theypsilon/quartus-lite-c5:17.0.2.docker0}
remote_dir=dev/mister/jtag
run() {
  ssh ubuntu "docker run --rm --privileged -v /dev/bus/usb:/dev/bus/usb -v \$HOME/$remote_dir:/work \
    -w /work $image /opt/intelFPGA_lite/quartus/bin/$*"
}
case "${1:-}" in
  chain)
    ssh ubuntu "mkdir -p ~/$remote_dir"
    run jtagconfig
    ;;
  load)
    sof=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
    ssh ubuntu "mkdir -p ~/$remote_dir"
    scp -q "$sof" "ubuntu:$remote_dir/core.sof"
    run quartus_pgm -c 1 -m jtag -o "'p;core.sof@2'"
    ssh root@mister 'killall MiSTer; sleep 1; cd /media/fat && (setsid ./MiSTer </dev/null >/dev/console 2>&1 &)'
    ;;
  *) echo "usage: $0 chain | load SOF" >&2; exit 2 ;;
esac
