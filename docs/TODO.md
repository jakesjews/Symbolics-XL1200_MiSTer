# To do

In the order they'll be done. Bugs come first whenever they turn up.

1. A compatibility pass, in progress ([NOTES.md](NOTES.md#compatibility)
   has what passed: Zmacs, Document Examiner, Inspector, Debugger, Peek, a
   full GC, Save World and booting the saved world, the MacIvory animation
   world's programs, ephemeral GC flips, the number types through the FPA,
   the CD-ROM drive: listings, worlds copied byte for byte, a FEP-Tape
   restore from the CD's tape image).
   Left: an overnight run; a use check of each application in the fat
   world on the MiSTer ([applications.md](applications.md)); for the
   CD-ROM drive ([NOTES.md](NOTES.md#the-cd-rom-drive-nov-10-2026)), a
   disc changed
   through the OSD while Genera runs (the new disc's UNIT ATTENTION is
   checked in `sim/scsi` only), and a whole install from the 8.3 CD as its
   guide has it: FEP-Tape's `Read Image File` of `BASIC_WORLD.TAPE` with
   the kernel, flods and world onto a disk, and a boot from that world.
   Anything that breaks is reproduced in the free-running simulation or the
   model.
   Found and fixed in the tree (Nov 2 2026, docs/NOTES.md): `Load System
   CLIM` trapped in the processor's instance-variable instructions, which
   decoded the operand field's mode bits as an addressing mode (CLOS puts
   other values there; the chip takes the low byte as the index whatever
   the mode bits say) and raised an error trap on a non-fixnum mapping
   table entry where the chip raises an instruction exception (CLOS
   readers and writers live in the table as compiled functions). The
   emulator replays the whole Color and CLIM load from the master disk in
   minutes; the fix is checked there first, then in lockstep and on the
   MiSTer. The same load then hit a stale pointer constant in compiled
   code after an ephemeral flip: the chip takes a transport trap when it
   executes an instruction from a page whose transport-trap bit is set
   (spec appendix), which neither implementation did; both do now, the
   emulator finished the CLIM load with it (NOTES.md, "The third trap"),
   and build 41 loads CLIM on the MiSTer (367 s, `time` says 1.4 s of it
   waiting for pages: processor-bound). Still open: the freeze four minutes into the first CLIM load on
   build 40 (the who-line clock stopped, no response; the second attempt
   got further and trapped instead), which the OSD halt and stall notices
   in the next build would name if it comes back.
   Also open: the lockstep inside Genera (`LOCKSTEP_SNAPSHOT`, NOTES.md, RTL
   boards) stops at the first low-priority sequence break: the model takes
   it an instruction before the RTL, whose fetch now samples the request in
   the cycle the previous instruction retires, before the bench's timer
   tick (the notes' "waits a cycle before the next" predates the speed
   work). Until then `FREE=1` runs the RTL alone from a snapshot.
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
2. Network, what's left after the wired port: the bridge into MiSTer's main
   program upstream (a pull request); an Ethernet address per core. The
   address, the gateway and WiFi are the user's to set, as the README's
   Network section has them
   ([NOTES.md](NOTES.md#setting-the-address-nov-10-2026)); no DHCP client
   and no tool that rewrites the image.
3. The RS-232 port: DUSCC channel B (Genera's serial unit 1, AM9517
   channels 2 and 3, interrupt bits 16 and 17) on MiSTer's UART, so
   Genera's serial streams work; today output on it never completes and a
   `close` waits forever ([NOTES.md](NOTES.md#the-io-chips-against-their-manuals-nov-4-2026)).
   A UART with the baud rate and framing from its registers, 4-byte FIFOs,
   the ready bits driving the two DMA channels, end of count and status
   interrupts, the modem lines, the chip's reset values and its
   write-1-to-clear status registers (about 400-700 ALMs, estimated).
4. Speed, only if the machine is really behind: measured after each step
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
