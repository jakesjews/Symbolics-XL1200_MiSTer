#!/usr/bin/env bash
# Build the core with Quartus 17.0.2 in Docker on the Ubuntu server.
#   ./build.sh          sync, compile there, fetch output_files/XL1200.rbf
set -euo pipefail
cd "$(dirname "$0")"
image=${QUARTUS_IMAGE:-theypsilon/quartus-lite-c5:17.0.2.docker0}
remote_dir=${REMOTE_DIR:-dev/mister/xl1200-core}   # a second directory lets two builds run at once

python3 tools/gen_ivory_states.py
rsync -az --delete --exclude=.git --exclude=research --exclude=emu --exclude=sim --exclude=snaps \
  --exclude=db --exclude=incremental_db --exclude=output_files --exclude=syn \
  ./ "ubuntu:$remote_dir/"
ssh ubuntu "cd ~/$remote_dir && docker run --rm --user \$(id -u):\$(id -g) -e HOME=/tmp \
  -v \$HOME/$remote_dir:/project -w /project $image \
  /opt/intelFPGA_lite/quartus/bin/quartus_sh --flow compile XL1200 > quartus.log 2>&1; \
  tail -5 quartus.log; grep -E 'Timing requirements not met|Worst-case setup slack' quartus.log output_files/*.sta.summary 2>/dev/null | head"
out=${OUT_DIR:-output_files}
mkdir -p "$out"
rsync -az "ubuntu:$remote_dir/output_files/" "$out/"
rsync -az "ubuntu:$remote_dir/quartus.log" "$out/"
ls -l "$out/XL1200.rbf"
