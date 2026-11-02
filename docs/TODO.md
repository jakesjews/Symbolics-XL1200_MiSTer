# To do

In the order they'll be done. Bugs come first whenever they turn up.

1. A compatibility pass, in progress ([NOTES.md](NOTES.md#compatibility)
   has what passed: Zmacs, Document Examiner, Inspector, Debugger, Peek, a
   full GC, Save World and booting the saved world, the MacIvory animation
   world's programs, ephemeral GC flips, the number types through the FPA).
   Left: an overnight run; the collection's applications that need a file
   or tape route in (Macsyma, Illustrate, TeX). Anything that breaks is
   reproduced in the free-running simulation or the model.
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
2. Check the device models against their manuals
   (`research/downloads/xl1200-documentation-addendum`): the 82586 (Intel
   reference manual), the DUSCC (SCN26562/68562 users' guide, AN416, AN419),
   the SCN2674 (Signetics data sheet), the WD33C93A (data sheet, version
   differences and bug list; decide which revision the XL1200 has).
3. FPA timing, once the processor's is close: the manual's latencies in FPA
   clocks (the FPA has its own clock on the Merlin-II) scaled to the Ivory's,
   and the busy tag (dtp-null) on an early read. The status queue (registers
   4, 5, 7, 8, 9, 10: destinations and previous status).
4. Calendar clock as GMT: Genera reads it as GMT, MiSTer's RTC is local time.
5. Network, what's left after the wired port: the bridge into MiSTer's main
   program upstream (a pull request); WiFi through a tap interface with
   proxy ARP on the MiSTer; namespace entries for the hosts Genera should
   talk to (its FTP and file servers refuse strangers), from `mkworld`; an
   Ethernet address per core.
6. Disk throughput: the SCSI model moves one 1280-byte block a request
   through MiSTer's image path (three 512-byte sectors into a 2 KB staging
   buffer, one round trip to the main program each), so Save World wrote at
   about 125 blocks a second, 160 KB/s, and Load World and paging are
   bounded the same way; a 1990 SCSI disk did several times that. Measure
   Load World, Save World and paging on the MiSTer, then move many blocks a
   request (`sd_blk_cnt` allows 64 sectors) through a bigger staging buffer
   or straight into DDR3, with read-ahead on sequential reads.
7. A color screen without the FrameThrower, optional: emulate the Univision
   UDC-3400, the third-party VME color board Symbolics sold for the XL400,
   whose driver is in source on the 8.3 CD (`sys.sct/color/univision*.lisp`,
   `vme-color.lisp`) and loaded into every Ivory world's Color system,
   the animation world's included. (The FrameThrower's driver is binary
   only, with a 1.9 MB microcode load and a command queue: not an option.)
   The board is an 8-bit frame buffer with a 2048-pixel pitch, two 1-bit
   overlay planes, three Bt458 palettes and four control words; its Intel
   82786 graphics coprocessor is skipped, since the driver's settable
   `remote-drawing-enabled` makes the Ivory draw into the buffer itself,
   and the interrupts only restart the coprocessor. To build: the Merlin-II
   VME window (physical addresses with bits 31:30 set, the polled-access
   registers at 0x88000040-0x88000100 and the VIC068 error bits, all in
   `i-sys/vme-bus.lisp` and `vme-defs.lisp`) onto 16 MB of DDR3 for the
   board's space at VME 0x90000000; a DDR readout client with a line
   buffer, the palette and the overlays into the video mixer; an OSD
   Display option (Console, Color, Auto from the board's video-enable bit,
   which Genera sets when the mouse is on the color screen). Run the screen
   at 1152 × 880 through a sync format we define, so the video timing never
   changes; the driver hard-codes 1280 × 1024 only in pan wraparound. On
   the Genera side an init file saved into the world: define the controller
   at its address, the sync format, make the screen with remote drawing
   off. Unverified until it draws: the driver's init against our registers,
   the S-Graphics programs on a non-FrameThrower screen (they ran on CAD
   buffers and NuVista cards), the fit (about a thousand ALMs more on a
   design that fits by seed; a separate color RBF is the fallback). The 8.3
   world needs the Color system loaded from the CD.
8. 16 MW of main memory, the XL1200's maximum (4 MW standard, three 4 MW
   expansion boards; the FEP probes the slots at 0x10000000, 0x20000000 and
   0x30000000): the memory module and decode a few address bits wider, the
   DDR3 clear longer, the FEP's sizing answered so the herald reads 16.0M
   words. A 4 MW session fetched 8 MW from disk (Peek's storage meters,
   docs/NOTES.md), so this is what makes a fat world comfortable.
9. The master disk: one Genera 8.3 world with the applications preloaded
   (Color, CLIM with Genera-CLIM and the demos, Concordia, Statice, Joshua
   and Jericho, Metering, Illustrate and TeX if they load, the documentation)
   saved on the core and made the default; the bare world kept; the 8.1.1
   animation world separate (different base system). The handoff with the
   archive names, versions and traps: research/XL1200_Application_Installation_Handoff.md.
   The FEP partition grows to fit (the disk tool); each application gets a
   boot-and-use check on the MiSTer before it ships.
10. The real Merlin-II boot PROM in place of the stand-in, if a dump turns up.
11. Speed, only if the machine is really behind: measured after each step
    (`PROFILE=1` on `sim/system` counts cycles by state) and against the
    published times. Standing (Oct 2026, build 30 at 50 MHz): `(fib 30)`
    2.80 s against the XL1201's 4.1 s; Gabriel 6.56x the 3600 overall, the
    list-bound benchmarks 5.2x to 6.0x (Boyer, Div2, Traverse: DDR
    misses). Whether that is slower than a real XL1200 isn't known: the
    "about 6x" for a real Ivory is an estimate, and no Gabriel run from an
    XL1200 has turned up (documentation wanted below). Nothing here until
    one does, or a program is visibly slow. If it is: the memory path's
    miss cost and the pipelined memory interface (the Internals manual: up
    to four requests outstanding, one word per cycle); a cache twice the
    size changed nothing (Oct 31 2026, [NOTES.md](NOTES.md#performance)),
    so the work is the miss path (an earlier restart, a prefetch of the
    next line, a miss overlapped with the next instruction). Check against
    the Internals manual's block-transfer rates, Gabriel, fib, and de
    Kleer's prime-implicate tests. No part slower than the real machine;
    faster is fine. The clock stays at 50 MHz (30.77 and 35 MHz were built
    and dropped: they put list-bound code further behind). The RTL's
    structure follows the chip, not the model; each step is checked on the
    MiSTer, not in lockstep.

## Documentation still wanted

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
