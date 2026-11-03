#!/usr/bin/env bash
# Build the core on a Mac with Quartus 17.0.2 Lite for Windows installed in a
# CrossOver bottle (WINE, CX_BOTTLE and QUARTUS_SH say where).
#   [SEED=N] [OUT_DIR=output_filesN] ./build-mac.sh
# Compiles a copy of the tree in build-mac/ (gitignored) and leaves
# XL1200.rbf and quartus.log in OUT_DIR.
set -euo pipefail
cd "$(dirname "$0")"
wine=${WINE:-/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine}
qsh=${QUARTUS_SH:-'C:\intelFPGA_lite\17.0\quartus\bin64\quartus_sh.exe'}
dir=build-mac
out=${OUT_DIR:-output_files}

python3 tools/gen_ivory_states.py
mkdir -p "$dir"
rsync -a --delete --exclude=.git --exclude=research --exclude=emu --exclude=sim --exclude=snaps \
  --exclude=db --exclude=incremental_db --exclude='output_files*' --exclude=syn --exclude=build-mac \
  ./ "$dir/"
if [ -n "${SEED:-}" ]; then
  sed -i '' "s/-name SEED [0-9]*/-name SEED $SEED/" "$dir/XL1200.qsf"
fi
(cd "$dir" && CX_BOTTLE=${CX_BOTTLE:-Quartus} "$wine" "$qsh" --flow compile XL1200 > quartus.log 2>&1) || true
tail -5 "$dir/quartus.log"
grep -E 'Timing requirements not met|Worst-case setup slack' "$dir/quartus.log" "$dir"/output_files/*.sta.summary 2>/dev/null | head
mkdir -p "$out"
cp "$dir"/output_files/XL1200.rbf "$dir"/output_files/*.summary "$dir/quartus.log" "$out/"
ls -l "$out/XL1200.rbf"
