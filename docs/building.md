# Building and testing

## What you need

- Python 3, make and a C++17 compiler
- [Verilator](https://verilator.org) 5, for the lint and the simulations
- For the core, Quartus Prime Lite 17.0.2, MiSTer's version: Docker with the
  `theypsilon/quartus-lite-c5:17.0.2.docker0` image (`build.sh`), or Quartus
  for Windows in a CrossOver bottle on a Mac (`build-mac.sh`)
- For `MiSTer_xl1200`, the
  [Arm GNU 10.2 toolchain](https://developer.arm.com/downloads/-/gnu-a)
  (`gcc-arm-10.2-2020.11-x86_64-arm-none-linux-gnueabihf`)

## The core

1. `./build.sh` compiles in Docker here; `BUILD_HOST=HOST ./build.sh`
   copies the tree to `HOST` over ssh, compiles there and fetches the
   results.
2. The core is `output_files/XL1200.rbf`.

**The design fills about 84% of the FPGA, so some fitter seeds don't fit or
miss timing**: change `SEED` in `XL1200.qsf` and build again. The seed
there is the release's, which was compiled with `build-mac.sh`; the same
seed gives another result in Docker (seed 4 doesn't route there), so with
`build.sh` expect to try a few.

## Tests

`make test` runs everything that needs no Symbolics software:

- the Verilator lint of `XL1200.sv` and `rtl/`
- the emulator's build and its CPU tests (`tools/cputest.py`)
- the floating-point unit: the model against the host's IEEE arithmetic, the
  RTL's arithmetic against the model, the RTL on its bus with its latencies
  (`sim/fpa`)
- the 82586 Ethernet chip with Main's mailbox (`sim/ether`)
- the calendar clock: MiSTer's timestamp to the chip's registers and the
  running clock, against the host's `gmtime` (`sim/nvram`)
- the SCSI chip with its disks and CD-ROM drive, driven as Genera drives
  it, on generated images (`sim/scsi`)

The rest need an XL1200 FEP disk image:

- `emu/xlemu -d DISK.dd`: the emulator from reset to the FEP prompt
  (`-c DISC.iso` puts a disc in its CD-ROM drive)
- `sim/ivory`: `make`, then `./obj_dir/Vivory_core ../../rtl/xl/boot_prom.mem DISK.dd`,
  the RTL processor in lockstep with the emulator
- `sim/system`: `make`, then `./obj_dir/Vxl_machine DISK.dd` (the whole
  machine in lockstep) or `./obj_free/Vxl_machine DISK.dd SECONDS` (free
  running, as on the MiSTer); `XLCD=DISC.iso` puts a disc in the drive

## MiSTer_xl1200

MiSTer's main program with the core's Ethernet bridge and its clock as GMT:
the `xl1200` branch
of [jakesjews/Main_MiSTer](https://github.com/jakesjews/Main_MiSTer/tree/xl1200),
or [tools/mister/Main_MiSTer-xl1200.patch](../tools/mister/Main_MiSTer-xl1200.patch)
on [MiSTer-devel/Main_MiSTer](https://github.com/MiSTer-devel/Main_MiSTer).
With the toolchain's `bin` on `PATH`, `make` there builds `bin/MiSTer`.

## Files that can't be in the repository

Symbolics software is licensed, so these come from your own media; the
gitignored `research/media/` is the place for them:

- An XL1200 FEP disk image (a SCSI2SD dump with the I333 FEP kernel and its
  FLODs): the emulator, `sim/ivory`, `sim/system`, `tools/fepfs.py mkworld`;
  `emu/xlemu` looks for `research/media/disks/fepfs-lmfs-kernel.dd` without `-d`
- A Genera 8.3 world, `GENERA_8_3.ILOD` from the Genera 8.3 CD, to build a
  disk ([Building a disk](../Readme.md#building-a-disk))
- For the reference VLM ([tools/world](../tools/world/README.md)),
  `Genera-8-5.vlod` and `VLM_debugger` from Open Genera 2.0

## On a MiSTer

`tools/mister/run.sh` copies and starts a core, takes screenshots and types
on it (`kbd.py`); `tools/mister/jtag.sh` loads a `.sof` over JTAG. They reach
the MiSTer as `MISTER` (default `root@mister`); `jtag.sh` runs Quartus on
`JTAG_HOST`, the Linux machine with the USB-Blaster, or here.
