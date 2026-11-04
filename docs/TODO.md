# To do

In the order they'll be done. Bugs come first whenever they turn up.

1. A compatibility pass, in progress ([NOTES.md](NOTES.md#compatibility)
   has what passed: Zmacs, Document Examiner, Inspector, Debugger, Peek, a
   full GC, Save World and booting the saved world, the MacIvory animation
   world's programs, ephemeral GC flips, the number types through the FPA).
   Left: an overnight run; a use check of each application in the fat
   world on the MiSTer (item 9).
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
   Ethernet address per core. The machine's address: the fat image has
   192.168.50.92 fixed (the user's LAN) in two FEP files, the Hello.boot's
   `Set Network Address` and the standalone namespace's host entry, and
   Genera 8.3 has no DHCP, BOOTP or RARP client. A user can type `Set
   Network Address CHAOS|1200,INTERNET|A.B.C.D` at the FEP after Hello
   (`|` is Insert on the core): Genera takes it (checked Nov 2 2026, it
   answered at the typed address only) and notes under the herald that the
   namespace still has the old one. Next `fepfs.py set-address IMAGE
   A.B.C.D` rewriting both files (check that the saved world takes a
   changed namespace file at boot), and a gateway entry for traffic
   beyond the LAN, then DHCP: a small client in
   Lisp in the fat world asking the router at boot and putting the lease
   in the running namespace (any LAN, the bridge as it is; NAT in the main
   program instead would need port forwards and kernel support).
6. Disk throughput: the SCSI model now moves ten blocks a request with a
   read window (before: one 1280-byte block a round trip, Save World at
   about 125 blocks a second, 160 KB/s). Measure Load World, Save World and
   paging on the MiSTer against that; a 1990 SCSI disk did several times
   the old figure. If still short, read straight into DDR3.
7. A SCSI CD-ROM drive: Genera 8.3 shipped only on CD-ROM for Ivory
   machines (8.3 Release Notes), and on an XL a drive on the SCSI bus is
   read as ISO 9660 through `host|CDROMn:` pathnames, n its SCSI address
   (8.3 installation guides; `SYS:IO;ISO9660-ACCESS-PATH`), and the FEP's
   Breath of Life can restore from it (8.1 Release Notes). A third target
   in `xl_scsi` answering as a CD-ROM (2048-byte sectors, four card
   sectors each; INQUIRY as a removable CD-ROM; Genera's
   `SYS:IO;ISO9660-ACCESS-PATH` issues only TEST UNIT READY, READ CAPACITY
   and READ(6), and handles UNIT ATTENTION after a change), read-only, an
   OSD slot for an `.iso` (the stock block interface; disc formats like
   `.cue`/`.bin` or `.chd` would be the main program's side, as other
   cores' CD support is). Test media: the user's
   `bolix_cd.iso` (the 8.3 distribution CD); `Copy File` of a world from
   it, then a Breath of Life restore.
8. A SCSI tape drive (on hold, Nov 2 2026: after the fat image and the
   CD-ROM): the XL's optional tape unit, in the top drive slot,
   is a 3M MCD-40 SCSI cartridge drive taking DC 2000 cartridges (XL
   User's Guide: "MCD-405/SCSI"), which Genera drives as
   `3M-MCD-40-SCSI-tape-drive` with QIC-100 8192-byte blocks
   (`SYS:LMTAPE;SCSI-TAPE`, which also takes generic SCSI sequential
   drives); backups, Restore Distribution, Breath of Life. A target in
   `xl_scsi` answering as that drive over a tape image file (a format to
   choose: blocks and filemarks), an OSD slot for it. Not needed for
   distributions: `Restore Distribution :Use Disk Yes` reads them from a
   FEP file (`tools/distfile.py`, docs/NOTES.md).
9. The master disk: the fat world, version 3 (Nov 2 2026,
   [NOTES.md](NOTES.md#the-fat-world-version-3-nov-2-2026)), has every
   application of the checklist that runs on an Ivory in one world
   (`Genera-8-3-fat.ilod.4`), Flavors Statice in its own small world.
   The XL1200 serves Concordia's locks and has a Statice file system with
   a sample database. Left: a boot-and-use check of the rest on the MiSTer
   (docs/applications.md); a save from Concordia itself; Illustrate's frame
   never appears; Macsyma and NS stop at their license passwords.
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
