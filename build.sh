#!/usr/bin/env bash
# Build the core with Quartus 17.0.2 Lite in Docker (an image with MiSTer's
# Quartus version), on this machine or on another one over ssh.
#   ./build.sh                    compile here (Docker running x86-64 images)
#   BUILD_HOST=HOST ./build.sh    copy the tree to HOST:~/REMOTE_DIR, compile there, fetch the results
# The core and the log end up in OUT_DIR (default output_files): XL1200.rbf, quartus.log.
set -euo pipefail
cd "$(dirname "$0")"
image=${QUARTUS_IMAGE:-theypsilon/quartus-lite-c5:17.0.2.docker0}
remote_dir=${REMOTE_DIR:-xl1200-core}   # a second directory lets two builds run at once
out=${OUT_DIR:-output_files}
compile="docker run --rm --user \$(id -u):\$(id -g) -e HOME=/tmp -v \"\$PWD\":/project -w /project $image \
  /opt/intelFPGA_lite/quartus/bin/quartus_sh --flow compile XL1200 > quartus.log 2>&1; \
  tail -5 quartus.log; grep -E 'Timing requirements not met|Worst-case setup slack' quartus.log output_files/*.sta.summary 2>/dev/null | head"

python3 tools/gen_ivory_states.py
if [ -n "${BUILD_HOST:-}" ]; then
  rsync -az --delete --exclude=.git --exclude=research --exclude=emu --exclude=sim --exclude=snaps \
    --exclude=db --exclude=incremental_db --exclude='output_files*' --exclude=syn --exclude=build-mac \
    ./ "$BUILD_HOST:$remote_dir/"
  ssh "$BUILD_HOST" "cd ~/$remote_dir && $compile"
  mkdir -p "$out"
  rsync -az "$BUILD_HOST:$remote_dir/output_files/" "$out/"
  rsync -az "$BUILD_HOST:$remote_dir/quartus.log" "$out/"
else
  bash -c "$compile"
  if [ "$out" != output_files ]; then mkdir -p "$out"; cp -R output_files/. "$out/"; cp quartus.log "$out/"; fi
fi
ls -l "$out/XL1200.rbf"
