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
2. Build the disk: `python3 tools/fepfs.py mkworld FEPDISK.dd GENERA_8_3.ILOD boot0.vhd --blocks 240000 --paging 120000 --standalone`
   (a 300 MB disk with the world, Symbolics' standalone site, paging space and room for a saved world);
   add `--internet A.B.C.D` for the [network](#network).
3. Copy it to `games/XL1200/boot0.vhd`.
4. Copy `XL1200.mgl` to `_Computer` and start the core from it; it mounts the disk
   and the FEP prompt appears. (Or load the core and mount the image from the OSD
   as SCSI disk 0.)
5. Type `Hello`, then `Load World FEP7:>Genera-8-3.ilod`, then `Start`; Genera's
   Lisp Listener comes up at site Standalone.
6. Once, finish the site: `Login Lisp-Machine`, `Create Directory XL1200:>sys>`,
   `Create Directory XL1200:>sys>site>`, then
   `Copy File FEP7:>sys-translations.text XL1200:>sys>site>sys.translations`.
7. Save it: `Save World FEP7:>Genera-8-3-site.ilod`; answer Y to the herald and
   the label, Yes to updating the boot file, Return for `FEP7:>boot.boot`, and
   Super-C (Windows-C) when it says the file isn't found, to write it.
8. From then on type `Hello` and `Boot` at the FEP; Genera is up in seconds.

The Symbolics keys (Select, Function, Abort, Help, ...) are on the PC's
function keys: [docs/keyboard.md](docs/keyboard.md).

## Network

Genera's Ethernet goes out of the MiSTer's wired port: MiSTer's main
program carries the frames, as it does for the Sun, NeXT and Amiga cores,
so there is nothing to run. Build the disk with `--internet A.B.C.D` (a
free address on your LAN) and Genera comes up on it; the OSD's Network
option picks the port (eth0 by default) or turns it off. Verified: Genera
answers ping, and its FTP server answers connections (it refuses hosts it
doesn't know; Genera 8.3 has no telnet server). Until the bridge is in
MiSTer's main program upstream, it needs the one built from
[tools/mister/Main_MiSTer-xl1200-enet.patch](tools/mister/Main_MiSTer-xl1200-enet.patch):
copy it to the SD card as `MiSTer_xl1200` and put

```
[XL1200]
main=MiSTer_xl1200
```

in `MiSTer.ini`; MiSTer switches to it for this core and back for the
others. WiFi can't carry it, and every XL1200 core has the same Ethernet
address, so run one per LAN.

## Gotchas

- **The core writes to the disk image, so give it a copy.**
- Images must be SCSI2SD dumps: each 1280-byte block in 1536 bytes.
- With no disk mounted the machine halts; mounting one starts it.
- Genera 8.3 doesn't accept dates after 1999, so leave the OSD's Clock at "28 years back".
- Save World shows "System Shutdown ..." with the clock stopped for several minutes while it writes; wait for "Saved to".
- To compile files, log in first (`Login Lisp-Machine`).

## Troubleshooting

- No FEP prompt: a debug build's Debug line in the OSD shows where it
  stopped, see [docs/NOTES.md](docs/NOTES.md#debug-line).
- "Unable to get time from the network or the calendar clock": set Clock to "28 years back".
- Genera asks for the date right after the MiSTer starts: MiSTer hadn't set its clock yet when the core loaded; type the date, or reload the core.
- "This Lisp world has not been configured for use at the local site": the disk was built without `--standalone`.
- "Unable to change site to Standalone. The directory >sys does not exist": step 6 hasn't been done on this disk.
- A full GC freezes Genera: the paging file is smaller than physical memory (4M words); build the disk with `--blocks 240000`.
- No picture on direct video: the display has to take an 80 MHz, 54 kHz signal.
- Genera doesn't answer ping: a cable in the MiSTer's port, the main program with the bridge (`[a2065] Opened eth0` in its output), and the disk built with `--internet`.

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
   - No part slower than the real machine; faster is fine. Standing (Oct
     2026, build 30 at 50 MHz): `(fib 30)` 2.80 s against the XL1201's
     4.1 s, Gabriel 6.56x the 3600 against a real Ivory's ~6x, but the
     list-bound benchmarks under it (Boyer 5.5x, Div2 5.2x, Traverse
     6.0x: DDR misses). Lifting those to the real machine's pace is the
     speed work left, after the compatibility pass; the clock stays at
     50 MHz until then (30.77 and 35 MHz were built and dropped: they
     put list-bound code further behind).
2. A compatibility pass, in progress ([docs/NOTES.md](docs/NOTES.md#compatibility)
   has what passed: Zmacs, Document Examiner, Inspector, Debugger, Peek, a
   full GC, Save World and booting the saved world, the MacIvory animation
   world's programs). Left: ephemeral GC flips; bignums, ratios, double
   floats and complex numbers through the FPA; an overnight run; the
   collection's applications that need a file or tape route in (Macsyma,
   Illustrate, TeX). Anything that breaks is reproduced in the free-running simulation or the model.
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
7. A master disk image beyond the saved standalone world of the setup:
   quality of life patches (dates past 1999), and the applications:
   Illustrate and TeX (distribution tapes), the Genera 8.1.1 animation world
   from the MacIvory disk (its graphics want color hardware).
8. Network, what's left after the [wired port](#network): the bridge into
   MiSTer's main program upstream (a pull request); WiFi through a tap
   interface with proxy ARP on the MiSTer; namespace entries for the hosts
   Genera should talk to (its FTP and file servers refuse strangers), from
   `mkworld`; an Ethernet address per core.
9. Disk throughput: the SCSI model moves one 1280-byte block a request
   through MiSTer's image path (three 512-byte sectors into a 2 KB staging
   buffer, one round trip to the main program each), so Save World wrote at
   about 125 blocks a second, 160 KB/s, and Load World and paging are
   bounded the same way; a 1990 SCSI disk did several times that. Measure
   Load World, Save World and paging on the MiSTer, then move many blocks a
   request (`sd_blk_cnt` allows 64 sectors) through a bigger staging buffer
   or straight into DDR3, with read-ahead on sequential reads.
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
