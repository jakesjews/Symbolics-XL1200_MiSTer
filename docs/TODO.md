# To do

In the order they'll be done. Bugs come first whenever they turn up.

1. Starting the core from the menu (bug, found Nov 2 2026, in build 41
   too): the screen stays black and the machine stops after the boot PROM
   has read the disk label; started while another XL1200 core runs it
   boots, and with MiSTer.ini's `main=MiSTer_xl1200` commented out it boots
   from the menu as well. From the menu the official main program releases
   the core's reset, then restarts as MiSTer_xl1200 (`app_restart`,
   `fpga_core_reset(1)`), so the core sees a second reset window after it
   has started; the OSD's Reset doesn't recover it, and the DDR3 safe
   terminator stops forwarding requests while RESET is held while still
   passing the port's waitrequest back, so a request made then would look
   taken and never answer (`xl_mem` isn't reset by RESET). A debug build's
   UART line (NOTES.md, Debug line) to see where it stops, then the fix.
2. A compatibility pass, in progress ([NOTES.md](NOTES.md#compatibility)
   has what passed: Zmacs, Document Examiner, Inspector, Debugger, Peek, a
   full GC, Save World and booting the saved world, the MacIvory animation
   world's programs, ephemeral GC flips, the number types through the FPA).
   Left: an overnight run; the collection's applications that need a file
   route in (Macsyma; Illustrate and TeX restore from a disk file, item 9).
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
   Also open: the lockstep from reset on the master disk stops at step
   1,822,307, the FEP kernel's first function entry after the boot PROM's
   `%jump` (an entry-rest-not-accepted with more arguments than it takes):
   the RTL writes the frame word {DTP-CALL-COMPILED-EVEN, the entry's PC}
   at physical 0x103 and the model does not. Present at least since build
   39; neither machine misbehaves for it (the FEP never returns there),
   so `LOCKSTEP_FROM=N` windows are used meanwhile; one of the two entry
   implementations is wrong and the spec decides.
   And the lockstep inside Genera (`LOCKSTEP_SNAPSHOT`, NOTES.md, RTL
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
3. Check the device models against their manuals
   (`research/downloads/xl1200-documentation-addendum`): the 82586 (Intel
   reference manual), the DUSCC (SCN26562/68562 users' guide, AN416, AN419),
   the SCN2674 (Signetics data sheet), the WD33C93A (data sheet, version
   differences and bug list; decide which revision the XL1200 has).
4. FPA timing, once the processor's is close: the manual's latencies in FPA
   clocks (the FPA has its own clock on the Merlin-II) scaled to the Ivory's,
   and the busy tag (dtp-null) on an early read. The status queue (registers
   4, 5, 7, 8, 9, 10: destinations and previous status).
5. Calendar clock as GMT: Genera reads it as GMT, MiSTer's RTC is local time.
6. Network, what's left after the wired port: the bridge into MiSTer's main
   program upstream (a pull request); WiFi through a tap interface with
   proxy ARP on the MiSTer; namespace entries for the hosts Genera should
   talk to (its FTP and file servers refuse strangers), from `mkworld`; an
   Ethernet address per core.
7. Disk throughput: the SCSI model now moves ten blocks a request with a
   read window (before: one 1280-byte block a round trip, Save World at
   about 125 blocks a second, 160 KB/s). Measure Load World, Save World and
   paging on the MiSTer against that; a 1990 SCSI disk did several times
   the old figure. If still short, read straight into DDR3.
8. A SCSI CD-ROM drive: Genera 8.3 shipped only on CD-ROM for Ivory
   machines (8.3 Release Notes), and on an XL a drive on the SCSI bus is
   read as ISO 9660 through `host|CDROMn:` pathnames, n its SCSI address
   (8.3 installation guides; `SYS:IO;ISO9660-ACCESS-PATH`), and the FEP's
   Breath of Life can restore from it (8.1 Release Notes). A third target
   in `xl_scsi` answering as a CD-ROM (2048-byte sectors, INQUIRY,
   READ CAPACITY, READ(10) and whatever else Genera's driver asks), an
   OSD slot for an `.iso`, read-only. Test media: the user's
   `bolix_cd.iso` (the 8.3 distribution CD); `Copy File` of a world from
   it, then a Breath of Life restore.
9. A SCSI tape drive: the XL's optional tape unit, in the top drive slot,
   is a 3M MCD-40 SCSI cartridge drive taking DC 2000 cartridges (XL
   User's Guide: "MCD-405/SCSI"), which Genera drives as
   `3M-MCD-40-SCSI-tape-drive` with QIC-100 8192-byte blocks
   (`SYS:LMTAPE;SCSI-TAPE`, which also takes generic SCSI sequential
   drives); backups, Restore Distribution, Breath of Life. A target in
   `xl_scsi` answering as that drive over a tape image file (a format to
   choose: blocks and filemarks), an OSD slot for it. Not needed for
   Illustrate and TeX: their distributions restore from a disk file (their
   RESTORING notes: concatenate the `*.dist.*` pieces, then `Restore
   Distribution :Use Disk Yes` naming the file), which only needs the file
   on the machine.
10. A color screen without the FrameThrower, optional: emulate the Univision
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
11. 16 MW of main memory, the XL1200's maximum (4 MW standard, three 4 MW
   expansion boards), in the tree and building (Nov 2 2026): the memory
   boards answer at their slots (0x10000000, 0x20000000, 0x30000000) and
   the ECO register's nibbles say they are there, which is what the FEP's
   hardware tables go by (docs/NOTES.md, the address map); the emulator's
   `Show Configuration` lists them, and build 41's herald on the MiSTer reads
   "16.0M words Physical memory, 29.3M words Swapping space". Left: Peek's
   storage meters against the 4 MW session (which fetched 8 MW from disk).
12. The master disk: the fat world is built and boots on the MiSTer
   (Nov 2 2026, [NOTES.md](NOTES.md#the-fat-world-nov-2-2026)): Color,
   CLIM with its port, PostScript, demos and documentation, Statice,
   Concordia, Metering and Hacks, on the full image grown to 2,000,000
   blocks with `fepfs.py grow`; Joshua and Jericho since the
   logic-variable instructions work (`Genera-8-3-fat.ilod.2`, the first
   version deleted). Left: Illustrate and TeX from their distribution
   files (item 9); a lock server for Concordia's saves; a boot-and-use
   check per application (Concordia, Statice, Metering, Hacks so far only
   load).
13. The real Merlin-II boot PROM in place of the stand-in, if a dump turns up.
14. Speed, only if the machine is really behind: measured after each step
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
