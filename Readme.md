# Symbolics XL1200 for MiSTer

A Symbolics XL1200 Lisp machine: the Ivory processor with the machine's
Merlin-II and I/O boards and its floating-point accelerator. It boots the
XL1200's front-end processor (FEP) from a SCSI disk image, and from the FEP
it loads and starts Genera 8.3 on the 1152 × 880 black-and-white console,
with keyboard and mouse.

**Work in progress:** see [To do](#to-do).

## What you need

- A disk image of an XL1200 FEP disk, as a raw dump of a SCSI2SD card set
  up for 1280-byte blocks
- For Genera, a Genera 8.3 world (`GENERA_8_3.ILOD` from the Genera 8.3 CD)
  on that disk: `tools/fepfs.py mkworld` copies it onto an image
  ([docs/NOTES.md](docs/NOTES.md#fep-file-system-layout))
- A keyboard and mouse
- For direct video, a display that takes 1152 × 880 at 60 Hz (54 kHz)

## Setup

1. Copy `XL1200_*.rbf` to `_Computer` on the SD card.
2. Copy the disk image to `games/XL1200/boot0.vhd`.
3. Copy `XL1200.mgl` to `_Computer` and start the core from it; it mounts the disk
   and the FEP prompt appears after about ten seconds. (Or load the core and mount
   the image from the OSD as SCSI disk 0.)
4. Type `Hello` and Return.
5. Type `Load World FEP7:>Genera-8-3.ilod` and Return (the name `tools/fepfs.py` gives the world).
6. Type `Start` and Return; Genera's Lisp Listener appears after about a minute and a half.

The Symbolics keys (Select, Function, Abort, Help, ...) are on the PC's
function keys: [docs/keyboard.md](docs/keyboard.md).

## Gotchas

- **The core writes to the disk image, so give it a copy.**
- Images must be SCSI2SD dumps: each 1280-byte block in 1536 bytes.
- With no disk mounted the machine halts; mounting one starts it.
- Genera 8.3 doesn't accept dates after 1999, so leave the OSD's Clock at "28 years back".
- To compile files, log in first (`Login Lisp-Machine`) and leave free space on the FEP disk (`tools/fepfs.py mkworld --paging`).

## Troubleshooting

- No FEP prompt: turn on Debug line in the OSD and read the words with
  [docs/NOTES.md](docs/NOTES.md#debug-line).
- "Unable to get time from the network or the calendar clock": set Clock to "28 years back".
- Genera asks for the date right after the MiSTer starts: MiSTer hadn't set its clock yet when the core loaded; type the date, or reload the core.
- No picture on direct video: the display has to take an 80 MHz, 54 kHz signal.

## To do

In the order they'll be done. Bugs come first whenever they turn up.

1. Speed the way the real Ivory gets it, measured after each step
   (`PROFILE=1` on `sim/system` counts cycles by state) and against the
   published times. The RTL's structure follows the chip, not the model;
   each step is checked on the MiSTer, not in lockstep.
   - The memory path, where the list- and array-bound benchmarks (Boyer,
     Traverse, Puzzle, Div2) still lag the real machine: the DDR cache's
     miss cost and the pipelined memory interface (the Internals manual: up
     to four requests outstanding, one word per cycle).
   - Check against the Internals manual's block-transfer rates (an array
     copy approaching two cycles per element, an array sum one per cycle),
     Gabriel, fib, and de Kleer's prime-implicate tests (needs the Building
     Problem Solvers code).
   - Land in the real machine's ballpark, not well past it. Standing (Oct
     2026, build 23 at 50 MHz): `(fib 30)` 2.81 s against the XL1201's
     4.1 s, Gabriel 6.4x the 3600 against a real Ivory's ~6x (compute-bound
     code past it, list- and array-bound code under it). The clock is
     the lever (30.75 MHz assumed for the chip: the Merlin-II's 61.5 MHz
     oscillator halved), to be set after the FrameThrower; no cycle-exact
     throttling.
2. A compatibility pass on the rebuilt core (not on this one: bugs in the
   old state machine aren't worth fixing): Zmacs (edit and save a file), Document
   Examiner, the Inspector, the Debugger, Peek; a full GC (`Start GC
   :Immediately`) and ephemeral GC flips; Save World and booting the saved
   world; bignums, ratios, double floats and complex numbers through the FPA;
   an overnight run. Anything that breaks is reproduced in the free-running simulation or the model.
   Lockstep only proves the RTL matches our model, so build a regression
   suite with its own expected answers, in place before the speed work:
   - Instruction tests on the RTL processor alone (`sim/ivory`, seconds):
     each opcode's edge cases (overflow, type traps, cdr codes, trap frames),
     later the pipeline's hazards (dependent instructions, stack cache spill
     and refill, traps mid-instruction); expected values from the spec and
     the VLM, written into the tests. Mine the Ivory Design Verification
     document (1987) for Symbolics' own chip tests.
   - A Lisp test file (arithmetic of every number type, lists, arrays,
     strings, closures, special binding, unwind-protect, errors, GC flips,
     process switches) writing a results file. Golden output from Symbolics'
     VLM (`tools/world/`); the same file on the model, the free-running RTL
     in Verilator and the MiSTer. The free bench (`sim/system/tb_free.cpp`)
     needs the model's state handover (`transfer.h`): the model boots Genera
     and loads the tests, the RTL runs them.
   - Gabriel and fib as speed regressions: cycle counts in Verilator, times
     on the MiSTer.
3. Check the device models against their manuals
   (`research/downloads/xl1200-documentation-addendum`): the 82586 (Intel
   reference manual), the DUSCC (SCN26562/68562 users' guide, AN416, AN419),
   the SCN2674 (Signetics data sheet), the WD33C93A (data sheet, version
   differences and bug list; decide which revision the XL1200 has).
4. Small register arrays into RAM: the processor's internal registers (32 x
   32 bits), the DUSCC's 64 bytes, the WD33C93's 32 bytes.
5. FPA timing, once the processor's is close: the manual's latencies in FPA
   clocks (the FPA has its own clock on the Merlin-II) scaled to the Ivory's,
   and the busy tag (dtp-null) on an early read. The status queue (registers
   4, 5, 7, 8, 9, 10: destinations and previous status).
6. Calendar clock as GMT: Genera reads it as GMT, MiSTer's RTC is local time.
7. A master disk image: a configured world (`Set Site`, saved), quality of
   life patches (dates past 1999), and the applications: Illustrate and TeX
   (distribution tapes), the Genera 8.1.1 animation world from the MacIvory
   disk (its graphics want color hardware).
8. Network: the 82586 to a real network. Cores can't reach the MiSTer's
   Ethernet themselves; MiSTer's main program bridges it for a few cores
   (Minimig, NeXT, Sun), so this needs a change there.
9. Color and FrameThrower graphics.
10. The real Merlin-II boot PROM in place of the stand-in, if a dump turns up.

Documentation still wanted:
- The Merlin-II boot PROMs (a dump; the CY7C291 PROMs' data sheet is in the
  addendum), schematics or PAL equations (the FPA interface PALs MII-FP0-WR,
  MII-FP0-RD, MII-FP1, MII-FPA-MISC; the memory and cache controller, built
  around IDT6178S tag RAMs), a field service or hardware manual.
- The 1990 XL1200 performance white paper Symbolics offered at launch;
  Weste, "Lisp chips increase power with symbolic processing", Computer
  Design 26:18 (1987).
- `(gabriel::run-series)` output from a real XL1200, XL1201 or MacIvory III.
- Ivory instruction timings and rev 4/4A errata; the Ivory's machine-cycle
  rate on the Merlin-II: the oscillator is 61.5 MHz (photographed), the
  divider isn't known (30.75 MHz is an inference, 40 MHz an owner's claim);
  the clock PAL at AA16 (BC-LCLK-G_N, 115958-A) or a measurement would
  settle it.

How the core is built and what has been found out about the machine:
[docs/NOTES.md](docs/NOTES.md).
