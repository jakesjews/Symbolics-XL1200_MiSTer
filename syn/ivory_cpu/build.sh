#!/usr/bin/env bash
# Synthesize the Ivory processor alone on the Ubuntu Quartus host.
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 tools/gen_ivory_states.py >/dev/null
rsync -az --relative rtl/ivory syn/ivory_cpu/ivory_cpu.qpf syn/ivory_cpu/ivory_cpu.qsf syn/ivory_cpu/ivory_cpu.sdc \
  ubuntu:dev/mister/xl1200-core/
ssh ubuntu 'cd ~/dev/mister/xl1200-core/syn/ivory_cpu && docker run --rm --user $(id -u):$(id -g) -e HOME=/tmp \
  -v $HOME/dev/mister/xl1200-core:/project -w /project/syn/ivory_cpu theypsilon/quartus-lite-c5:17.0.2.docker0 \
  /opt/intelFPGA_lite/quartus/bin/quartus_sh --flow compile ivory_cpu > quartus.log 2>&1; tail -5 quartus.log'
