# To do

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
     put list-bound code further behind). A cache twice the size changed
     nothing (Oct 31 2026, [NOTES.md](NOTES.md#performance)): the work is
     the miss path (an earlier restart, a prefetch of the next line, a
     miss overlapped with the next instruction).
2. A compatibility pass, in progress ([NOTES.md](NOTES.md#compatibility)
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
7. The master disk beyond the full disk: the applications that need a file
   or tape route in (Illustrate and TeX distribution tapes, Macsyma).
8. Network, what's left after the wired port: the bridge into MiSTer's main
   program upstream (a pull request); WiFi through a tap interface with
   proxy ARP on the MiSTer; namespace entries for the hosts Genera should
   talk to (its FTP and file servers refuse strangers), from `mkworld`; an
   Ethernet address per core.
9. Disk throughput: the SCSI model moves one 1280-byte block a request
   through MiSTer's image path (three 512-byte sectors into a 2 KB staging
   buffer, one round trip to the main program each), so Save World wrote at
   about 125 blocks a second, 160 KB/s, and Load World and paging are
   bounded the same way; a 1990 SCSI disk did several times that. Measure
   Load World, Save World and paging on the MiSTer, then move many blocks a
   request (`sd_blk_cnt` allows 64 sectors) through a bigger staging buffer
   or straight into DDR3, with read-ahead on sequential reads.
10. The real Merlin-II boot PROM in place of the stand-in, if a dump turns up.

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
