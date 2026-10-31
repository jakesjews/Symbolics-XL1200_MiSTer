# Symbolics XL1200 core — working notes

Facts established so far, with where they came from. Unverified guesses are
marked as such.

## Approach

Replicate a real XL1200 as closely as the surviving material allows: the
Ivory processor with the Merlin-II main board and the Merlin I/O board,
booting the FEP (v333) from the machine's own FEPFS disks, then Genera.

1. `emu/` — instruction-level C++ model of the Ivory and the XL1200 hardware,
   the golden model for the RTL. It boots the real IFEP kernel from the disk
   image to `FEP Command:` and runs `Hello` and `Show Configuration`, matching
   photos of a real XL1201.
2. `rtl/` — the FPGA implementation, checked against the model (`sim/ivory`
   runs the RTL processor in lockstep with it through the FEP boot).
3. `tools/` — Python helpers: FEPFS file reader, Ivory assembler and
   disassembler; `tools/world/` the reference VLM (a tool for building Genera
   worlds, not part of the core).

Agreed departures from a real XL1200 (forced by missing material):
- No dump of the Merlin boot PROM exists: a stand-in written in Ivory code
  does its job (find the FEP kernel through the disk label, load it, start it).
- The Symbolics logic around the WTL3164 FPA is undocumented: its interface
  comes from how Genera drives it, the arithmetic from the 3164's manual
  ([FPA](#fpa-weitek-wtl3164)).
- The 82586 Ethernet chip answers Genera but has no network yet.

Plan for the hardware (phase 1), each step checked against the model:
1. The stand-in boot PROM, in the model first (replacing `load_fep_file`).
2. RTL: memory (DDR3), main board (PROM, NVRAM/clock, control registers),
   I/O board (buffer memory, WD33C93A SCSI on MiSTer disk images, DUSCC and
   AM9517 console link, video memory and timing), in Verilator.
3. The 80 MHz console's timing, decoded from what the FEP programs.
4. MiSTer top level (disk images as `S` mounts, PS/2 into the console link,
   video), then the FEP prompt on the hardware.
Phase 2: Genera 8.3, the native world an XL1200 ran (`GENERA_8_3.ILOD` from
the Genera 8.3 distribution CD, which also has the native driver sources:
`i-sys/console.lisp`, `i-sys/merlin-scsi-hardware.lisp`,
`storage/merlin-scsi-disk-driver.lisp`, `network/82586-ethernet-driver.lisp`,
`serial/merlin-interface.lisp`, `l-sys/nbs-*.lisp`), loaded by the FEP from
the FEP disk as on a real machine.

## CPU (Ivory rev 4)

- Words are 40 bits: cdr<39:38> type<37:32> data<31:0>. Halfword PC.
- Instruction set: `sys.sct/i-sys/opdef.lisp` (opcode table generated into
  `emu/opcodes.inc`), semantics from the I-Machine Architecture Spec rev 2
  (chapters 3–5) cross-checked against the VLM emulator
  (`linux-vlm/alpha-emulator`).
- Type checks follow the hardware, which is laxer than the spec text:
  e.g. `%unsigned-lessp` compares data fields of any type (the FEP uses it on
  pointers).
- Stack: modelled as write-through memory (no separate 128-word stack cache).
  The architecture requires stack-cache writes to write through, and Genera's
  stack-group switch dumps the cache with raw block reads, which is a no-op in
  this model.
- Address translation: map cache backed by the PHT (spec 2.3); the PHT hash
  box is implemented from the spec. VMA=PMA zone: VMA 0xF8000000+x → PA x.
- Traps: pre/post traps per spec 5.1; frame layout and control-register masks
  from VLM (`fccrmask = ~0x074FFFFF`). FEP mode (trap mode 3) takes every trap
  through the FEP-mode trap vector register (internal register 01024).
- Memory cycle numbering follows sysdef (`BIND-READ`=2, `BIND-READ-NO-MONITOR`=4),
  which disagrees with the spec's table.
- BARs hold an address and its physical-ness only ("BARs need to store 33
  bits"): reading one gives a locative or a physical address, whatever tag
  was written (the VLM's ReadRegisterBARx pushes a locative). Genera's
  `DO-COMPILED-FUNCTION-INSTRUCTIONS` takes each constant's location from
  the BAR it loaded with a compiled function, so `compile-file` failed
  ("The first argument to the CDR instruction, #<compiled function>, was
  not a list or a locative") while the BAR kept the function's tag.
  Confirmed on the MiSTer: with this, the FPA's integers in R0 and the
  manual's FPA behaviour, `compile-file` of `sys:examples;gabriel-benchmarks`
  completes (log in first, and leave the FEP disk some free blocks).
- Floating point: with the FPA enabled (internal register 021 bit 0) the chip
  runs single-float arithmetic and predicates, and fixnum multiplies, on it;
  otherwise float operands take the arithmetic-dispatch exception and Lisp
  emulates them ([FPA](#fpa-weitek-wtl3164)).

## Boot

- INIT sets PC to VMA=PMA 0o777400100 = VMA 0xFFFE0040 (dtp-even-pc), i.e. the
  boot PROM at physical 0x07FE0000 (64K words), entry at offset 0o100.
- Boot communication area = first words of the PROM (sysdf1.lisp):
  emb-comm-area, system-type, stack-base, stack-size, spy-pc, …, spy-block,
  …, prom-version. Words 0o40..0o43 / 0o60..0o63 hold the serial number one
  byte per word (`si:machine-model`).
- The boot PROM normally loads the FEP kernel (`I333-kernel.fep`) from the
  FEPFS disk and calls FEP-STARTUP (FEP comm area word 2, 0xF8041002).
  No dump of the Merlin boot PROM has been found, so `tools/bootprom.py`
  writes a stand-in (`rtl/xl/boot_prom.mem`, Ivory code assembled with
  `tools/ivasm.py`): the boot communication area as data, then code that
  turns the main board's memory cache on (0x0A000004 mode 2: the FEP never
  does, and Genera warns "On-board memory cache is defective or disabled"
  without it), resets the WD33C93 the way the FEP does, finds the first SCSI
  target whose label names a kernel, loads the kernel by its load map (12
  blocks a READ(10) through buffer page 4), records BOOT-FEP-KERNEL-DPN,
  builds FEP-STARTUP's frame on the boot stack, sets the stack cache lower
  bound to its FP and jumps to it. `xlemu` boots through it from
  reset (about 1.8M instructions); `-k` still loads a kernel file directly.
  Two Ivory details it ran into: the field instructions (`ldb`, `dpb`) take a
  left rotation, not a bit position; and a value returned from a function
  loses its cdr code, so kernel words are stored where they are built.
- FEP comm area at VMA 0xF8041000; system comm area 0xF8041100; trap vector
  0xF8040000; NIL 0xF8041200, T 0xF8041208.
- System types (sysdef): XL400 = #o1004, XL1200 = #o1011, MacIvory-3 = #o1014,
  NXP1000 = #o1015. Merlin-II = XL1200/UX1200S/UX1200G.

## Physical address map (from the IFEP kernel's accesses)

| PA | What | Evidence |
|----|------|----------|
| 0x00000000– | Main memory (4 MW on the reference XL1201 main board) | |
| 0x07FE0000–0x07FEFFFF | Boot PROM | spec 2.1.4 |
| 0x09000000–0x090007FF | NVRAM, byte per word; clock at 0x7F8–0x7FF (MK48T02-style); FEP options in bank 0 | sysdef `MERLIN-NVRAM-FEP-OPTIONS`; kernel uses 0x090007F8 |
| 0x0A000000 | Merlin-II control (bit 1 = run light) | wired-screen.lisp |
| 0x0A000004 | Merlin-II cache control | sysdef |
| 0x0A000008 | Board configuration (read as fixnum by the FEP's hardware-configuration code; MacIvory reads coprocessor 0o1003 instead) | kernel |
| 0x0A00000C | Status bits polled with a 1 s timeout (MacIvory: coprocessor 0o1001) | kernel |
| 0x10000000, 0x20000000, 0x30000000 | Probed for memory boards (bus error = absent) | kernel |
| 0x48000000, 0x58000000, 0x68000000 | Probed for boards | kernel |
| 0x40000000/0x44000000 | Merlin I/O board #0 (0x50000000/0x54000000 for #1) | kernel |
| 0x88000000 | VME interface; 0x88000200+n looks like VIC068 register n (byte offset 4n+3) | kernel writes match VIC068 init values |

Coprocessor register 0o1002 is the microsecond clock (same number the VLM uses).

## I/O board

- SCSI: Western Digital WD33C93A (string in `I333-info.flod`).
- Ethernet: Intel 82586 (`merlin-82586-make-and-initialize-ethernet`).
- Console: phase-encoded video + SLB serial to the standard Symbolics console.
  SLB bytes are `1TTTCCCC` (sysdef `*SLB-CONSOLE-BYTE-TYPES*`): mouse switch,
  mouse move, all keys up, status, key down, key up, serial window, serial in.
  Keyboard codes: LispEngineer/symbolics-console-protocol, MAME symbolics.cpp.

## Console video: an SCN2674 behind the "sync program"

The FEP's `(SETF CONSOLE-MONITOR-PARAMETERS)` -> `SCREEN-INITIALIZE` (B&W-SCREEN)
-> `VIDEO-MEMORY-LOAD-SYNC-PROGRAM` (MERLIN-VIDEO-MEMORY) writes 0 to the video
control register (I/O board 0x0402C000), 0 to 0x0402D001, the sync program's
values one by one to 0x0402D000, 41 (#x29) to 0x0402D001, then sets control
bit 1. The values come from `PRECALCULATED-SCN2674-SYNC-PROGRAM` in the
kernel, which returns, per monitor:

- `:80MHZ` (our console; FEP: "Black and white 80MHz console"):
  (56 14 9 2 109 35 0 192), -3, 1, 1152, 880
- `:MONITERM`: (56 14 9 4 109 35 0 192), -1, -2, 1152, 880

So the video timing comes from a Signetics SCN2674 video display controller:
0x0402D000 is its initialization register port (IR0, IR1, ... in turn) and
0x0402D001 its command register (0 = reset, #x29 presumably display on). Read
with MAME's `scn2674.cpp` formulas (`research/downloads/mame/`):

- IR0 = 56: 8 scan lines a character row. IR4 = 109: 110 rows -> 880 lines.
- IR5 = 35: 36 characters a row; a character is one 32-pixel video word, so
  1152 pixels and a 2.5 MHz character clock (80 MHz / 32).
- IR1 = 14: equalizing constant 15; IR2 = 9: hsync 4, back porch 3 characters.
  Line = 2 x (15 + 2 x 4) = 46 characters = 1472 pixels: 36 visible, front
  porch 3, sync 4, back porch 3. 80 MHz / 1472 = 54.35 kHz.
- IR3 = 2: front porch 4, back porch 8 lines; IR7 = 192: vsync 7 lines.
  Frame = 880 + 4 + 7 + 8 = 899 lines: 60.45 Hz.
- The other two values (-3, 1 for the 80 MHz monitor) look like horizontal
  and vertical adjustments for the monitor; 1152 x 880 is the raster.

The raster starts at video memory word 0 of each 64-word (2048-pixel) line.
The FEP draws its console in a 1024 x 846 window at (61, 18) inside it and
sets the rest to 1. A 1 bit is black (the real screen is black on white,
IMG_1040) while control bit 0 is clear; the FEP leaves it clear (control = 2).

## Media

- `fepfs-lmfs-kernel.dd` etc.: raw SD-card dumps of a SCSI2SD v7 used as a
  1280-byte-block SCSI disk on an XL1201 (Douglas Fields, 2016). SCSI2SD stores
  each 1280-byte block in three 512-byte SD sectors, so block n is at byte
  n*1536 (the 256 pad bytes are 'D', the fill pattern he used). The files are
  truncated at 102,400,000 bytes (66,666 whole blocks). They contain the I333
  kernel, FLODs and boot scripts but no Genera world (`tools/fepfs.py mkworld`
  adds one, see "FEP file system layout"). On his machine this disk
  was SCSI address 3 = `FEP10:`; as SCSI address 0 it is `FEP7:`.
- FLOD overlays: a text header (command table), then records
  `address(4) count(4) count*(data LE(4) + cdr/tag(1)) checksum(4)`, ending
  with a negative count. All I333 overlays load into 0xF8001000-0xF80066FF.

## Reference machine

Douglas Fields' XL1201 (symbolics.lisp.engineer, 2016), which made our disk
images (`fepfs-lmfs.tar`: photos and a Genera 8.3 transcript, kept in
`research/media/reference/`):

- `Show Machine Configuration` (Genera 8.3): Merlin-II Main Board s/n 582
  manufactured 1991-02-20, ECO level 1, 4.0MW, Ivory rev4A, FPA. Merlin IO
  Board #0 s/n 1129 manufactured 1992-04-04, ECO level 5. Ethernet address
  08-00-05-07-48-23. SCSI targets 0-3 disks (target 3 = these 80,000-block
  images), target 6 a Genera 8.3 CD-ROM image.
- FEP `Show Configuration`: XL1200 4.0 Processor with FPA; Serial number
  SN-582; Revision level 1.0 / I/O Board 0; Revision level 5.0 / 2048k words
  physical memory at 0 and at 0o10000000 / Black and white 80MHz console 0.
- Photo of the FEP after `Hello` from this disk (IMG_1040): the same lines
  `xlemu` prints, black text on a white screen.

## FEP memory layout (VMA=PMA, physical 0-0x3FFFF)

| VMA | Use | Evidence |
|-----|-----|----------|
| 0xF8000100-0xF8000FFF | boot stack (*BOOT-STACK-BASE*/SIZE) | VLM life-support `BootComm.h` uses the same; overlays start at 0xF8001000 |
| 0xF8001000-0xF80066FF | overlay area | FLOD load records |
| 0xF8006700-0xF800BFFF | FEP heap | kernel constants passed to %ALLOCATE-INITIALIZE |
| 0xF800C000-0xF8017FFF | IFEP kernel | kernel load map |
| 0xF8040000 | trap vector | |
| 0xF8041000/0xF8041100 | FEP / system communication areas | sysdf1 |

Boot data area (sysdf1 BOOT-DATA-AREA, at *BOOT-SPY-BLOCK-ADDRESS*, octal
offsets from 56): BOOT-FEP-KERNEL-DPN at +63 octal holds the disk address the
kernel came from; bits 31:27 are the FEP unit number, which becomes the
default `FEPn:` device.

## How the FEP kernel is found on disk

From diffing Douglas Fields' dumps before and after `Copy Flod Files` installed
a kernel (`fepfs-lmfs-files.dd` vs `fepfs-lmfs-kernel.dd`):

- The disk label is in blocks 0, 1 and 2 (three identical copies). Installing
  the kernel changed two of its 32-bit words (see "FEP file system layout";
  read as tagged words they are word 42 and the tag bytes of words 44-47):
  LABL-FEP-DPN (word 53) = 20151, the DPN of the kernel file's header block,
  and LABL-COLOR-STARTUP-DPN (word 55) = 20599, the header of
  `I333-FrameThrower.sync.11`.
- Block 20151 is the file's FEPFS header ("FEPF", type "fep", author "DRJ",
  name "I333-kernel"); the kernel's 193 data blocks follow contiguously from
  20152, block 0 holding the load map (`Machine::load_fep_file`).
- So a boot PROM reads the label, then the load map at LABL-FEP-DPN + 1, then
  the blocks the map names (relative to LABL-FEP-DPN + 1), and starts
  FEP-STARTUP. The boot data area's BOOT-FEP-KERNEL-DPN gets the header's DPN.
  (The stand-in assumes the data follows the header; the header's data map
  says where it really is.)

## FEP disk numbering (XL-SETUP-DISK-CONTROLLERS)

FEP units 0-6 are ESDI drives on I/O board 0, units 7-14 SCSI targets 0-7, then
the same for board 1. SCSI target 0 is `FEP7:`. (Matches Douglas Fields'
`Show Machine Configuration`: SCSI address 3 was `FEP10:`.)

## FEP file system layout

From Genera 8.3's `sys.sct/l-sys/fep-stream.lisp` and `fep-access-paths.lisp`
(both `Base: 8`: undotted numbers there are octal), checked against all four
of Douglas Fields' dumps. `tools/fepfs.py` reads and writes it (`ls`, `get`,
`mkworld`).

- Blocks are 1280 bytes, numbered by DPN from 0. The file system's own blocks
  are 320 little-endian 32-bit words (`%page-size32` = 320 on the Ivory,
  `storage/disk-definitions.lisp:41`); a file's data blocks hold whatever the
  file holds (a world's: 256 tagged words, as `tools/fepfile.py` reads them).
  Strings are 4 characters a word, low byte first, NUL-padded. Times are
  universal time (seconds since 1900, GMT).
- Every block starts with FEPH (`fep-stream.lisp:113`): 0 id ("LABL", "FEPF",
  "FEPD", "FEPP"), 1 header version, 2 npages (1), 3 timestamp, 4 sequence
  number.
- LABL, blocks 0-2 (`:169`): 5 cylinders, 6 heads, 7 blocks per track
  (5000 x 1 x 16 = 80,000 blocks on these disks, more than the dumps hold),
  8 creation date, 9-15 author, 16-23 pack name, 24-47 comment, 48 root
  directory header DPN (65), 49 pack id, 50 fast mode, 51 disk type,
  52 DIAGNOSTIC.FEP header (132), 53 FEP kernel header, 54 backup kernel,
  55 color startup (sync program) header. 53-55 are 0 when unset.
- FEPF, a file header (`:123`): 5 owning directory (sequence number of the
  directory page holding its entry), 6 version, 7 type (4 characters),
  8 creation date, 9-15 author, 16-23 name (32 characters), 24-47 comment,
  48 length in bytes, 49 flags (bit 0 directory, 1 dont-delete, 2 fixed,
  3 deleted), 50 number of map entries, from 51 map entries of two words:
  npages<23:0> indirect<24> suspect<25>, then the first DPN. The file's blocks
  are the runs in order (`fep-file-data-map-collect`, `:967`). An indirect
  entry names a FEPP block (same layout, entries from 51); 134 entries fit a
  block. None of the dumps has an indirect entry.
- FEPD, a directory page (`:191`): 5 page number in the directory,
  13 number of entries, from 14 entries of 11 words: name (8), type, version,
  header DPN; 27 a page. A directory is a file with the directory flag whose
  blocks are FEPD pages; the root directory lists itself as
  `ROOT-DIRECTORY.DIR`, its subdirectories as `name.DIR` (`douglas.DIR` on the
  dumps).
- Free map: the file `FREE-PAGES.FEP` (blocks 133-140): bit k of word i of its
  block b is DPN b*10240 + i*32 + k, 1 = in use; bits past the label's size
  don't count (`fep-access-paths.lisp:318`, `:378`). Genera allocates first
  fit from DPN 0, a new file's header block first (`fep-stream.lisp:1495`).
- `SEQUENCE-NUMBER.FEP` (block 142): word 0 is the highest file sequence
  number handed out; Genera takes 64 (#o100) at a time
  (`fep-access-paths.lisp:254`): 6 on the empty disk, 70 after the Genera
  session that made files 7-10, 134 after the one that made 71-81.
- A fresh file system (`fepfs-empty.dd`), all dont-delete, 144 blocks in use:
  `ROOT-DIRECTORY.DIR` (header 65, page 64), `DISK-LABEL.FEP` (0-63, header
  66), `BAD-BLOCKS.FEP` (empty, 67), `DIAGNOSTIC.FEP` (68-131, header 132),
  `FREE-PAGES.FEP` (133-140, 141), `SEQUENCE-NUMBER.FEP` (142, 143).
- The FEP reads the same structure: its `Show Directory` on
  `fepfs-lmfs-kernel.dd` lists what `fepfs.py ls` does (`@` = dont-delete).

World files:

- `GENERA_8_3.ILOD` on the CD is the world file's contents: 44,402 blocks of
  tagged words. The four tag bytes of the first word are "HIJc", the VLM's
  `IvoryWorldFileCookie` (`research/downloads/github/Lord-Nightmare_vlm/
  world_tools.h:139`); words 8 on are its load map. A
  world Genera saves gets length = blocks * 1280 (`disk-save.lisp:374`).
- `tools/fepfs.py mkworld TEMPLATE WORLD OUT` copies a FEPFS image, grows it
  to the label's size (80,000 blocks, 122,880,000 bytes), and adds
  `>Genera-8-3.ilod` and `>Page.page` (the rest of the disk). On
  `fepfs-lmfs-kernel.dd`: world header 20610, data 20611-65012, paging file
  14,986 blocks.
- The FEP (xlemu) lists it (`FEP7:>Genera-8-3.ilod.1 44402 56834560(8)`),
  offers it as Load World's default, and `Load World` prints "The Lisp Release
  of this world is Genera 8.3" and "[Adding paging file FEP7:>Page.page.1 ...
  14986 pages done.]", reading world blocks 0-269. Without `Page.page` it
  prints "Error adding FEP7:>Page.page.newest: ... not found" (the FEP's
  default paging file) and returns to the prompt. `Start` then enters the
  world, which halts the model ("PHT search did not terminate").
- Guesses: the paging file's contents don't matter (`mkworld` leaves its
  blocks as they are); whether 14,986 paging blocks are enough for Genera is
  unknown.

## Console details found while bringing up the FEP

- Switchpack status: bits 2:1 are the monitor type (STREAM-MONITOR-ID does
  `(ldb (byte 2 1) switchpack)`); 1 = Moniterm. Bits 0 and 4 are two more flags.
- Key numbers: `:symbolics` layout in `embedding/keyboards/keyboards.lisp`
  (copied into `emu/keyboard.h`).

## I/O board details found while bringing up the FEP

- SCSI DMA: 0x4401A000 = buffer window in 4K-word pages (start page bits 2:0,
  end page + 1 bits 5:3), 0x4401B800 = low 12 bits of the starting word
  address. 0x4401A800/0x4401B000 are the ESDI equivalents. Bytes go into the
  buffer low byte first.
- WD33C93A: after Select-and-Transfer the FEP expects status 0x16 and then
  0x85 (disconnect) unless EDI is set (MAME `wd33c9x.cpp` agrees). Statuses
  queue; reading the status register presents the next one.
- ID PROM at 0x44016000: 32 bytes, one per word in bits 15:8. Bytes 0,1 =
  AA 55; 16-21 Ethernet address; 28 = checksum of the first byte[29] bytes,
  each rotated left by (index mod 8); 30 = 00; 31 = FF. The XL1200 path also
  reads the Ethernet address from 0x41008000 (6 words, bits 15:8).

## CPU details found while bringing up the FEP

- fast-aref-1/fast-aset-1 with a stale array register (event count changed)
  rebuild it in hardware for short-prefix arrays; only long-prefix arrays and
  array instances take the instruction exception (the FEP's trap handler only
  copes with long arrays). VLM does the same.
- Error traps pass a microstate number; the FEP only prints it ("Error trap
  #o~O"), Genera decodes it with a per-chip-revision table (not yet modelled).

## Genera 8.5 (OpenGenera world)

Superseded by the Genera 8.3 CD (above), kept for the record. OpenGenera
2.0's `Genera-8-5.vlod` was
compiled for the VLM only: `SYSTEM-CASE` expands at compile time
(`sys2/macro.lisp`, `*SYSTEM-TYPE-ABBREVIATIONS*` for `#+VLM` maps MERLIN etc.
to nothing), so e.g. its `INITIALIZE-DISK` unconditionally calls
`INITIALIZE-EMBEDDED-DISKS`. The native Merlin modules that sysdcl declares
for `:imach` (`i-sys;console`, `i-sys;merlin-scsi-hardware`,
`storage;merlin-scsi-disk-driver`, `storage;merlin-esdi-disk-driver`,
`82586-ethernet-driver`, `imach-interfaces`) are neither in the world nor in
sys.sct. The sources that are there still have their Merlin branches (e.g.
`io1/time.lisp` sets the calendar with `MERLIN-SET-CALENDAR-CLOCK-INTERNAL`).
The world does contain Genera's native bitmap screen code (`BITBLT`,
`%DRAW-CHAR`, flavors `MAIN-SCREEN`, `SINGLE-BIT-VME-DIRECT-MAIN-SCREEN`).

Running it on the XL1200 therefore means recompiling, for the Merlin, the
sources whose machine-specific branches were compiled out, and writing the
missing modules.

Unpatched Genera 8.5 only keeps a two-digit year from the calendar clock and
rejects 20xx.

### %BLOCK-n-READ-SHIFT: the VLM differs from the Ivory

The I-Machine Architecture Specification says the top byte-s+1 bits of the
result come from the rotated memory word and the rest from the rotate latch.
The VLM (`alpha-emulator/imacblok.lisp`) deposits the field at byte-r
instead, which agrees only when byte-r + byte-s = 31, as BitBLT always uses.
Genera's one-word glyph routines (`window/idraw.lisp`
`%DRAW-NARROW-CHARACTER-1-1/1-2`) use byte-s = 31 with any rotation, and with
the VLM's semantics glyphs whose destination bit lies left of their source bit
take every row from the previous one (stray dots above letters, garbled small
fonts). The VLM never shows this because X draws its screen text. The
emulator follows the specification.

Bug found by Genera: internal registers >= 0o1000 were decoded as per-BAR
registers by their low bits (BindingStackLimit 0o1006 went to BAR0).

## Interrupts

From Genera 8.3 `i-sys/io-register-definitions.lisp` and `i-sys/interrupts.lisp`:

- `%merlin-ii-interrupt-register` = physical 0x0A00000C. Reads give the
  pending sources (raw cycle, fixnum); writes set the mask (Genera keeps a
  copy in `*merlin-interrupt-mask-register*`, so the register needn't read
  back the mask). Sources must be cleared at the device.
- Bits: 0 timer 2 (periodic), 1 timers 1&0 (interval), 2/3 VME low/high
  (Merlin-II), 8 SCSI controller (WD33C93 INT), 9 SCSI trigger, 10 SCSI
  overrun, 11 SCSI reset, 12-15 ESDI, 16 serial controller (DUSCC), 17 serial
  DMA, 18 Ethernet (82586); 20-31 the same as 8-19 for I/O board 1.
- Bit 1 is the only low-priority sequence break source; all the others are
  high priority (`merlin-ii-high-priority-sequence-break` services any of
  `#x4FF7FF0D` under the mask).
- 82C54 timer at physical 0o01000000000 = 0x08000000, registers 0-3 =
  counters 0-2 and control (`write-82C54-register`). Counter 2 is the
  periodic timer (mode 0, reloaded by each interrupt), counters 1 and 0
  cascade as the interval timer. Clock rate on Merlin not yet confirmed
  (the Domino comment says 10 MHz; `setup-periodic-timer` loads
  `*sequence-break-interval*`, capped at 65535, directly).

## Genera 8.3

`tools/fepfs.py mkworld` builds a FEP disk with `GENERA_8_3.ILOD` and a
paging file. On it, `Load World FEP7:>Genera-8-3.ilod` then `Start` boots
Genera 8.3 to the Dynamic Lisp Listener ("a Symbolics XL1200", 4.0M words).
In the model that is about 3.5G instructions (two minutes of `xlemu` at
~31M instructions/s; device time counted in instructions makes the FEP's
disk waits long). On the MiSTer it takes about 90 s from `Start`; typed
forms evaluate and the mouse brings up Genera's menus. With the FPA no
warnings remain.

Genera reads the calendar clock as GMT and shows local time by its time
zone (EST until the site says otherwise); MiSTer's RTC is local time, so the
status line is off by the zone (6:49 shown at 11:49 EDT). MiSTer sends a core
the RTC once, when it loads it (`send_rtc(3)` in `user_io.cpp`; only Minimig
gets it again every minute), so a core loaded just after the MiSTer starts,
before its clock is set from the network, gets a wrong time, and Genera asks
for the date.

What it took (first in the model, then the RTL):

- 82C54 timer and interrupt register (`emu/pit.cpp`, previous section):
  `Start` writes the timer first.
- Stack cache lower bound. The boot PROM has to set it (the stand-in sets it
  to FP of FEP-STARTUP's frame): `INVOKE-ON-FEP-STACK` compares it with
  `*boot-stack-base*`/`*boot-stack-size*` (PROM words 2 and 3) to tell
  whether it is already on the FEP stack, and relocated the stack to nowhere
  when it read 0. And the hardware lowers it: a return to a frame below the
  bound reloads that frame into the cache (spec: the return instruction makes
  sure the frame returned to is in the cache), so the bound becomes FP.
  Genera's stack-group switch dumps the cache from the bound up to FP; with a
  stale bound above FP the count went negative and walked the whole stack
  region. The model's stack is otherwise write-through memory; it doesn't
  raise the bound on overflow (Genera's comment: the chip's cache is 128
  words and overflow is `D.SP<6:2> = stack-cache-overflow-limit`).
- PHT rehash: the next bucket is `state<24:0> << 3`, masked; the mask's top
  four bits are don't-cares (`SEARCH-PHT`, `storage/i-storage-defs.lisp`).
  Genera's mask is 0xF000FFF8, and keeping its top bits sent PHT probes to
  0x800629B0 and the like.
- Error microstates for chip revision 4. Genera decodes an error trap by
  looking its microstate up in `DBG:*TRAP-DISPATCH-TABLES*` for the chip
  revision; the model's numbering was rev 5 (the VLM's), so trap-on-exit
  (rev 4: 1225, rev 5: 79) was decoded as a RETURN-MULTIPLE type error.
  `tools/errortable.py` maps each rev-5 microstate to a rev-4 one with the
  same descriptor, from Open Genera's world (it has both tables; the 8.3
  world's rev-4 table is identical). `tools/worldfile.py` reads `.ilod` and
  `.vlod` worlds (after the VLM's `world_tools.c`).
- 82586 Ethernet (`emu/i82586.cpp`, no network): Genera halts with "82586
  appears to be hung: RESET failed" if it doesn't answer. Its pins are a
  latch at I/O board 0x44016000 (Genera: base + #o400260000; bit 7 releases
  RESET, a falling edge on bit 6 is channel attention, bit 5 releases
  loopback), and they read back in bits 7:5 (Genera sets them with
  `%p-ldb`; bits 15:8 are still the ID PROM's first byte). The chip sees the
  buffer memory as bytes, address bits 16:0, low byte of each word first:
  Genera's area is buffer words 0x7000-0x7FFF, the SCP at 0x7FFD
  (= 0xFFFFF6). INT is interrupt register bit 18.
- Calendar clock: Genera 8.3 rejects a two-digit year past 1999 ("Unable to
  get time from the network or the calendar clock"). The model, like the
  core's default, runs the clock 28 years behind (`XLEMU_CLOCK_TODAY` turns
  that off).

## FPA (Weitek WTL3164)

The XL1200's floating-point accelerator is a Weitek WTL3164 behind the
Ivory's coprocessor bus (addresses 0-0o777; the microsecond clock is at
0o1002). `emu/fpa.cpp` follows the chip's manual (3164/3364 64-Bit
Floating-Point Data Path Units, November 1989, 208 pages,
`research/downloads/weitek/WTL3164_3364_Nov1989.pdf`, with a tesseract OCR
next to it) for the arithmetic, and Genera (`i-sys/float.lisp`,
`sys2/bignum.lisp`) for the Symbolics glue around it, which no document
describes:

- Registers: writes to 0, 2, 3 load R0 high, R0 low, R1 low; a write to an
  operation's address + 1 loads R1 high and starts it (X in R0, Y in R1, a
  unary operation's operand in R1, the result in R0). Reads: 1 R1 low, 2 R0
  high, 3 R0 low, 0o400 R0 as an integer, op + 2 a predicate's result. A
  32-bit integer sits in bits 52:21 of a register (manual 6.1): the fixnum
  multiplicand (0o374) and integer results are in R0, the integer operand
  of an operation in R1. That matters: Genera's interrupt-time save
  (`WITH-FLOATING-POINT-STATUS-SAVED`) keeps R0 high and low and R1 low, and
  `AR-2` multiplies through the FPA and reads the product a few
  instructions later; with separate integer registers another process's
  product could land in between (seen on the MiSTer as "The subscript,
  -5872006, used with the FAST-AREF-1 instruction ... was negative" during
  `compile-file`). A single-precision result clears R0 low (manual 6.1).
  0o600 + n is status register n (bits 31:24): 0 modes (rounding 26:25,
  FPEX sticky 30), 2 trap enables, 3 sticky flags, 6 adder (31:28) and
  multiplier (27:24) status codes, 11 FPEX (31), condition (29), divider
  status (27:24). 0o624 resets it. Flags and enables share Genera's layout:
  31 NaN, 30 invalid, 29 division by zero, 28 denormalized input, 27
  overflow, 26 underflow, 25 inexact, 24 integer overflow.
- Operation addresses are the Ivory opcode's low five bits shifted left two
  (0o000 add, 0o004 sub, 0o010 multiply, 0o014 and 0o044 the two divides,
  0o060 negate, 0o100-0o130 =, <, > and their no-pop forms, 0o160-0o170
  zerop, minusp, plusp), plus 0o200 for double precision; 0o374 is fixnum
  multiply and 0o400-0o554 the conversions, square roots and absolute
  values (`*fpa-operations*`). So the Ivory can issue an instruction's
  operation directly, and it does: Genera's trap handlers for single-float
  `+ - * /`, the comparisons, `zerop`/`minusp`/`plusp` and negation read
  the FPA's result and status without starting an operation, so the chip
  has run it. Rev 4 Ivories also multiply fixnums on it (the "doesn't wait
  long enough for an integer multiply" handler in `sys2/bignum.lisp`).
  Double floats are done by Lisp through the same registers.
- Every read is tagged: dtp-single-float normally, dtp-fixnum while FPEX is
  set (an exception whose trap is enabled, or a result Lisp has to finish),
  dtp-null while busy (Genera's state save loops until the tag is a fixnum
  or single-float). The chip pushes a dtp-single-float result and takes the
  instruction's arithmetic trap for anything else; the handlers then read
  the status, fix up the result and clear FPEX (`SINGLE-FLOAT-TRAP-BODY`).
- Exceptions (manual 12, 19.5): sticky flags are set whatever the enables;
  FPEX is raised by an enabled exception and always by an underflow, and
  FPEX-taken (SR11 bit 7) stays until software clears it. An underflow
  gives an UNRM (hidden one, exponent in two's complement, status
  "unnormalized"), its significand rounded when SR2 bit 2 (UNF CONTROL;
  Genera's "underflow trap enable") is set, which Genera's default does,
  truncated otherwise; Lisp turns it into a denormal. An overflow gives
  infinity or the largest number by the rounding mode. Denormalized
  operands count as zero and raise their flag when SR2 bit 4 (DNRM CONTROL)
  is set; Lisp recomputes. An operation on a NaN is invalid and gives the
  default NaN (sign 0, all ones); compares with a NaN are false and set the
  NaN flag, and those with > or < are invalid too; negate and absolute
  value are logical operations (no exceptions, NaNs kept). Compares set
  FPCN but leave the status codes.
- Our FPA finishes every operation before the next access, so the busy tag
  never shows; the RTL holds the bus off instead.

Choices with no source behind them (the glue): the predicate result in bit
0; which Weitek instructions the operations are (negate as the chip's
logical `neg`, compares as its ordered predicates). Not modelled: the
status queue (SR4, 5, 7, 8, 9: destinations; SR10: the previous status),
FAST mode, the latencies (manual 9.2: add and multiply 2 cycles, divide
⌈14/N⌉+3 single and ⌈28/N⌉+3 double, square root ⌈25/N⌉+3 and ⌈54/N⌉+3,
N the divide clock's multiple).

Checks: `sim/fpa/fpa_test` (the C++ against the host's IEEE arithmetic in
all four rounding modes, ~5M cases), `sim/fpa/obj_dir/Vxl_fpa_unit`
(`rtl/xl/xl_fpa_unit.sv` against the C++, every bit, flag and status, 10M
random operations including denormals, NaNs and infinities), and
`sim/system` in lockstep (RTL machine with `xl_fpa` against the model): ten
20M-instruction windows from 330M (Genera enables the FPA at 332M) to 3.63G
(the Listener evaluating float forms) match. In the model,
Genera 8.3 enables it (`*enable-fpa-p*`, `W3X64-EXISTS-P` multiplies two
patterns) and runs ~250K operations booting; forms like `(sqrt 2d0)`,
`(cos 1d0)`, `(float 123456789)`, `(* 100000 100000)`, overflow, underflow
and division by zero give the same results as with the FPA removed
(`XLEMU_NO_FPA=1`), which brings back "Floating point coprocessor is missing,
defective, or disabled". On the MiSTer (71% of the ALMs, 47 DSP blocks, +0.33
ns setup slack at 50 MHz) `(cli::fp-coprocessor-enabled-p)` is T, the same
forms print the same results, and overflow, underflow and a fixnum multiply
overflowing into a bignum take their traps as in the model.

## Performance

Published numbers for real machines:
- Gabriel, *Performance and Evaluation of Lisp Systems* (1985,
  [dreamsongs.com/Files/Timrep.pdf](https://www.dreamsongs.com/Files/Timrep.pdf)),
  Symbolics 3600 + IFU, CPU seconds: Tak 0.43, Stak 2.30, Ctak 5.04, Takl
  4.95, Boyer 9.40 (+1.77 GC), Browse 21.43, Destructive 2.18, Traverse 35.34
  (init 6.37), Deriv 3.79, Dderiv 3.89, Div2 1.51 / 2.50, FFT 3.87, Puzzle
  11.04, Triang 116.99.
- XL1201 (the XL1200's board set in a smaller chassis), Genera 8.3, measured
  by Douglas Fields (2016, symbolics.lisp.engineer), elapsed time of
  `(defun fib (n) (if (or (= n 0) (= n 1)) 1 (+ (fib (- n 1)) (fib (- n 2)))))`
  after `(compile 'fib)`: (fib 20) 0.0334 s, (fib 30) 4.097 s, (fib 36) 73.9 s,
  (fib 38) 192.1 s; a MacIvory III (same chip) 4.097 s for (fib 30).
- XL1200, de Kleer, "An Improved Incremental Algorithm for Generating Prime
  Implicates" (AAAI 1992, Table 1, trie column): K44 0.46 s, K54 1.1 s, K55
  8.6 s, K66 224 s, K67 2541 s, Regulator 85 s, BD 38 s, Adder 721 s. The
  code survives in the Building Problem Solvers distribution (`cltms.lisp`,
  `ltms-ex.lisp`, `(keanp 4 4)` etc.), revised since; the paper notes symbol
  order changes the times.
- Ratios: initial Ivories "3-5 times" Symbolics' 1987 products (Baker et
  al., ICCD 1987); XL1200 launch (April 1990) 5x a 3640 (Tech Monitor
  reported 600%); Genera 8.1's install guide rates the XL1200 3x the XL400;
  later Ivories about 6x the 3600, at 30.75 MHz (a 61.5 MHz oscillator
  halved, on a MacIvory III). Symbolics' current VLM comparison uses the
  XL1200 as 1x on the Gabriel benchmarks.
- The real Ivory: four-stage pipeline, simple instructions (push, add, eq)
  in one cycle, a 32-word instruction cache filled by its own prefetcher, a
  128-word top-of-stack cache, a 32-word scratchpad, a 16-entry TLB.
- Its memory interface (Genera *Internals*, "Ivory Memory Operations"):
  pipelined, up to four requests outstanding, one word per processor cycle
  from interleaved memory; used for instruction fetch, map cache fills, the
  stack cache, method lookup and lists. The block subprimitives copy an array
  at "asymptotically approaching two cycles per element" and sum one at one
  element per cycle: a cycle-level check that doesn't depend on the clock.
- Clock: a 61.5 MHz oscillator (Valpey-Fisher VF155, "61.500000MHz") sits
  next to the Ivory on an XL1201's Merlin-II board (read from Douglas
  Fields's board photographs, symbolics.lisp.engineer; the board inventory
  there lists a clock PAL at AA16, BC-LCLK-G_N, part 115958-A). The same
  oscillator is on a MacIvory III, where OldVCR infers a divide-by-two from a
  Symbolics white paper: that is where the often-quoted 30.75 MHz comes from.
  An XL1200 owner's page (Michael Parker) says 40 MHz without a source. The
  1987 Ivory paper says a two-phase clock is used and the adders work twice a
  clock cycle, not how the oscillator relates to a machine cycle; the first
  Ivory ran "in the vicinity of 150 ns" a cycle, the second ~100 ns (NASA
  spaceborne VHSIC multiprocessor paper, 1988, in the addendum). So:
  oscillator 61.5 MHz, photographed; machine-cycle rate unresolved. The
  model's instruction counts for fib against the XL1201's times give
  instructions per second, which bounds the cycle rate from below (calls and
  returns take several cycles each).

Genera ships the suite: `sys:examples;gabriel-benchmarks.lisp`;
`(gabriel::run-series-to-file "FEP7:>gabriel.text")` (not exported) writes the
times to a FEP file. Baseline on the MiSTer (Oct 2026, build `output_files8`,
4 MW, FPA on), CPU seconds against the 3600 + IFU:

| Benchmark | MiSTer | 3600 | 3600 / MiSTer |
|---|---|---|---|
| Boyer | 6.92 | 9.40 | 1.36 |
| Browse | 11.20 | 21.43 | 1.91 |
| Destructive | 1.29 | 2.18 | 1.69 |
| Traverse init / run | 4.22 / 24.85 | 6.37 / 35.34 | 1.51 / 1.42 |
| Tak / Stak / Ctak / Takl | 0.37 / 1.05 / 5.96 / 3.39 | 0.43 / 2.30 / 5.04 / 4.95 | 1.16 / 2.18 / 0.85 / 1.46 |
| Deriv / Dderiv | 1.79 / 2.05 | 3.79 / 3.89 | 2.11 / 1.90 |
| Div2 iterative / recursive | 1.32 / 1.48 | 1.51 / 2.50 | 1.14 / 1.69 |
| FFT | 2.24 | 3.87 | 1.73 |
| Puzzle | 26.52 | 11.04 | 0.42 |
| Triang | 83.28 | 116.99 | 1.40 |

Instructions per benchmark from the model (its clock runs at 4 instructions
a microsecond, so Genera's CPU seconds there are instruction counts), and
the MiSTer's cycles an instruction from them:

| Benchmark | M instructions | MiSTer cycles/instruction |
|---|---|---|
| Boyer | 11.3 | 30.5 |
| Browse | 18.8 | 29.8 |
| Destructive | 2.2 | 29.6 |
| Traverse init / run | 6.4 / 37.8 | 32.8 / 32.9 |
| Tak / Stak / Ctak / Takl | 0.63 / 1.27 / 10.9 / 5.5 | 29.4 / 41.4 / 27.3 / 30.6 |
| Deriv / Dderiv | 3.1 / 3.5 | 28.6 / 29.1 |
| Div2 iterative / recursive | 2.1 / 2.4 | 31.0 / 30.8 |
| FFT | 2.7 | 42.0 |
| Puzzle | 49.0 | 27.1 |
| Triang | 135.3 | 30.8 |

fib in the model: (fib 25) 2.72M instructions, (fib 30) 30.15M (11.2 an
invocation). The XL1201's 4.097 s for (fib 30) is then 7.4M instructions a
second: 4.2 cycles an instruction at 30.75 MHz, 5.4 at 40 MHz, 1.4 at 10
MHz; the last is impossible for a mix of calls and returns, so the machine
cycle is in the 30-40 MHz range. The MiSTer does 1.72M a second.

Stak (special binding) and FFT (floating point through the FPA) cost the
most cycles an instruction. Puzzle runs 49M instructions where the 3600
took 11 s: Genera 8.3's version does more work than the 1985 one, which is
why it is the outlier in the table above.

Geometric mean 1.41x the 3600, against ~6x for a real Ivory: about 4x slow,
as fib shows ((fib 30) 17.50 s, (fib 36) 312.76 s, 4.27x and 4.23x the
XL1201's). Genera's elapsed time for (fib 36) agreed with the host's clock
(the result appeared between 306.7 and 326.9 s), so the microsecond clock
keeps real time. Puzzle (2-D arrays) and Ctak (catch/throw) are the
outliers. The suite took 15.5 minutes; it nearly exhausts the bench disk's
paging space (Genera warns that a Start GC :Immediately will soon not fit).

The rebuild of the processor after the real chip's structures is in
`docs/ivory.md`, with each step's measurement; the first, the stack cache,
brought `(fib 30)` to 9.33 s (15.5 cycles an instruction).

Before it, the RTL Ivory averaged ~29 cycles an instruction at 50 MHz, two thirds of
them waiting ~7 cycles per memory access (`PROFILE=1` on `sim/system`),
where the real chip's stack cache, TLB and instruction cache answer in a
cycle; and at least five states (fetch, fetch wait, decode, execute, retire)
even with no memory access.

## RTL Ivory (`rtl/ivory/`)

`ivory_cpu.sv` is a state machine that follows the C++ model function by
function (the comments name the routine each group of states implements).
Memory is one 40-bit word per transaction. `ivory_mmu.sv` translates
(`ivory_core.sv` puts the two together with a physical bus): the map cache
(4096 entries, direct-mapped, one block RAM) and the PHT search, step for
step as the model's `translate`/`map_fill`/`note_write`, so they make the
same memory cycles in the same order. It answers each access with the trap
vector to take (page not resident, fault request, write fault) and the
page's transport-trap bit, which the processor's read and write cycles check
with the oldspace registers (Table 13's transport column). The map-cache
internal registers (PHT base and mask, map cache control, load/invalidate
map) drive it; writing the base, mask or control clears the map (4096
cycles). Subroutines (raw access, cycle-type reads/writes with
forwarding, push/pop, operand fetch, car/cdr, unbind) use a small return
stack; a trap abandons it. `tools/gen_ivory_states.py` generates the state
enum from the sources.

It was verified in lockstep with the C++ model under Verilator (`sim/ivory/`,
the processor alone on the model's bus): from reset through the boot PROM,
the FEP boot and `Hello`, 165M instructions, 141 opcodes, every register and
every memory word written agreeing after each instruction (earlier, 420M
instructions of a Genera 8.5 boot on the VLM's memory model). With the MMU
(`ivory_core` on the model's physical bus) it runs Genera 8.3: lockstep
runs at about 0.1-0.15M instructions/s, so `LOCKSTEP_FROM=N` lets a second
C++ processor run the RTL's machine for the first N steps, then the RTL takes
over from its registers with both map caches empty. Windows of 40M
instructions from 400M to 2.5G (Genera starting up, then idle at the
Listener) agreed.

The model keeps the RTL's one-word instruction buffer: the second halfword
instruction of a word doesn't fetch (or translate) the word again; a
processor write to that address, or a coprocessor access, forgets it.
Without it the two diverged on `count-map-reloads` when the first half
evicted its own page from the map cache.

Speed: about 13 cycles an instruction with single-cycle memory, after an
instruction-word buffer (the second halfword instruction of a word doesn't
fetch it again) and memory requests issued straight from the state that
needs them. Quartus 17.0.2, 5CSEBA6, processor alone: 15.5K ALMs (37%),
4.3K registers, 7 DSP blocks, Fmax 61 MHz (slow 85C).

## RTL boards (`rtl/xl/`)

Each follows its C++ counterpart in `emu/`:

- `xl_machine`: processor, address decode (as `Machine::phys_read`), boot
  PROM (512-word block RAM from `boot_prom.mem`), main board registers
  (0x0A00000C is the interrupt register: pending sources, mask), VME
  registers, the coprocessor bus (the FPA below 0o1000, the microsecond
  clock at 0o1002), device time, the
  sequence-break requests (high priority: any enabled source but bit 1).
- `xl_pit`: the 82C54 (as `emu/pit.cpp`). A tick in the same cycle as a
  register write counts the cycle after, as the model counts it after the
  instruction (it used to be dropped).
- `xl_fpa`, `xl_fpa_unit`: the WTL3164 (as `emu/fpa.cpp`): registers and bus
  in `xl_fpa`, arithmetic in `xl_fpa_unit` over several cycles (multiply in
  four 64x16 steps, divide 56 restoring steps, square root 64), the bus held
  off until it finishes.
- `xl_mem`: main memory and the I/O board's buffer memory in DDR3, one word
  per 64-bit DDR word (main memory at DDR word 0x06000000, buffer at
  0x06400000). Main memory goes through an 8K-word direct-mapped cache
  (four-word lines, write-through, allocate on read): only the processor
  touches main memory, the I/O board's DMA stays in its buffer memory. DDR3
  is cleared at power-up (it holds whatever the last core left).
- `xl_nvram`: MK48T02 behaviour; the clock is a BCD counter started from
  MiSTer's RTC (optionally 28 years back, as the VLM does for Genera).
- `xl_iob`: registers, DUSCC and AM9517 subsets for the console link, the
  buffer memory arbiter (console DMA, SCSI DMA, 82586, processor).
- `xl_i82586`: the Ethernet chip without a network (as `emu/i82586.cpp`),
  16-bit cycles on the buffer memory.
- `xl_scsi`: WD33C93 and disk targets on MiSTer `S` mounts: a 1280-byte
  block is three 512-byte sectors of a SCSI2SD-layout image, through a
  staging buffer.
- `xl_console`: the console end of the serial line bus (key, mouse and
  status messages); `xl_keyboard` maps PS/2 to Symbolics keys.
- `xl_video`: video memory (block RAM, second port on the 80 MHz dot clock)
  and an SCN2674 timing generator driven by the initialization registers the
  FEP writes. Departure: the sync runs from power-up with the 80 MHz
  monitor's settings (a real SCN2674 is silent until programmed), so the
  MiSTer's display keeps its signal; the picture stays blank until the FEP
  turns it on. The OSD's "Debug line" draws eight status words in hex across
  the top 16 lines (`xl_machine` lists them).

`sim/system/` checks them: `Vxl_machine` (obj_dir) runs the RTL machine
(DDR3 model, SD model) in lockstep with the C++ machine, with device time
counted in instructions as the model does (`LOCKSTEP`: SCSI commands
complete within the instruction that starts them, the console byte rate and
video counters follow the model; the timer ticks on the edge an instruction
retires and the processor waits a cycle before the next, so it sees the
sequence-break requests the model's would). From reset through `Hello`,
`Load World`, `Start` and Genera's first 70M instructions (timer and
interrupts, both 82586 initializations): 260M instructions, 158 opcodes,
no difference, video memory identical (85 minutes at ~51K instructions/s).
To start anywhere else, `LOCKSTEP_FROM=N` runs the model alone for N
instructions (~30M/s), then `transfer.h` copies its state into the RTL
machine before its first instruction: processor registers, RAM and buffer
memory into the DDR3 model, video memory, NVRAM and its running clock, the
WD33C93's registers and queued statuses, DUSCC, AM9517, board registers,
console link state and queued bytes, 82C54, interrupt mask, 82586, and the
disk image. Map caches and instruction buffers start empty on both sides;
the SCN2674 registers keep their defaults (they don't affect the
comparison). The lockstep build has every signal public
(`--public-flat-rw`, about 2% slower) and a DDR3 model without wait states
(the comparison doesn't depend on memory timing). Windows of 20M
instructions run in parallel, about 12 minutes each. Both machines start their
calendar clocks from the host's time, so runs of the same window can take
different paths. The transfer has to set registers, not port wires: Verilator
keeps both, and recomputes the wire (`pit_out` was set instead of
`pit.out`, so in about half the windows the RTL missed one OUT1 edge and its
interval timer fired 8 instructions late). The bench also compares the 82C54s
after every instruction and reports the first difference.
`obj_free/Vxl_machine` runs it as on the
MiSTer (microseconds of the 50 MHz clock, SCSI commands running while the FEP
polls, memory cleared from junk, the dot clock running) and saves the screen.

## Debug line

The OSD's "Debug line" shows eight words in hex across the top of the
picture and sends them to the UART (`/dev/ttyS1` on the MiSTer, 115200 8N1)
twice a second (`xl_machine`):

1. instructions executed (low 32 bits)
2. PC (word address of the next instruction)
3. bits 31:24 halt reason, 20 halted, 16 memory ready (DDR3 cleared), 15:12
   memory state, 9:8 trap mode (3 = FEP), 7:0 display frames
4. microseconds since power-up
5. SCSI: 31:24 targets present, 19:16 command engine state, 15:8 WD33C93
   auxiliary status, 7:0 last command opcode
6. SCSI target 0's size in 1280-byte blocks
7. 31:24 video control register, 20 display on, 19:16 SCN2674 register
   pointer, 15:0 disk image reads
8. 31:24 image mount cycles, 23:16 machine resets, 15:0 entries to the boot
   PROM

With it on, the display timing stays at the 80 MHz monitor's and video
memory is shown even while the FEP has the display off.

## Quartus and MiSTer lessons

- Quartus 17 (Lite) infers byte-enabled block RAM only from the SystemVerilog
  packed form (`logic [3:0][7:0] ram [N]`, `ram[a][i] <= byte`); with part
  selects a 64 KB RAM became flip-flops and synthesis ran for tens of minutes.
- A RAM with a read/write port and a read port on another clock, written in
  the plain "read old data" style, becomes one copy per read port; Quartus's
  true dual-port form (a write returns the new data) keeps one copy.
- A pixel clock with thousands of loads can land on a regional clock and the
  fit then fails fixing hold times on the HDMI path: force it global
  (`GLOBAL_SIGNAL` in the qsf). FITTER_AGGRESSIVE_ROUTABILITY_OPTIMIZATION
  made a congested design route where seeds 1-3 failed.
- DDR3 holds leftovers when a core starts; nothing can assume zeroed memory.
- A DDR3 burst cut short (e.g. by resetting the machine when a file download
  starts) wedges the HPS SDRAM port: DDRAM_BUSY stays high and Main_MiSTer
  hangs on ioctl_wait (once the whole board reset). Put MiSTer's
  `f2sdram_safe_terminator` (sys/) on any DDR3 master that can be reset.
- F options with a load address (`FC1,EXT,Title,24200000`) make Main_MiSTer
  write the file straight into DDR3 (fast) and remember it; the core sees only
  ioctl_download, with the size in ioctl_addr. Streaming through ioctl_wr ran
  about 0.5 MB/s.
- `video_mixer` with `GAMMA(1)` latches pixels and syncs on rising edges of
  `ce_pix` (`gamma_corr`), so with the pixel clock as `CLK_VIDEO` and `ce_pix`
  held at 1 its outputs freeze after the first cycle: no picture on HDMI or
  direct video, no screenshots. Gamma needs a video clock of four times the
  pixel rate; this core uses `GAMMA(0)`.
- Bring-up without a picture: the OSD's "Debug line" also sends the debug
  words to the core's UART, which is the ARM's `/dev/ttyS1`
  (`stty -F /dev/ttyS1 115200 raw -echo; cat /dev/ttyS1` on the MiSTer).
  Screenshots need `screenshots/<core>/` to exist.
- Test tools: `tools/mister/run.sh load|shot|type` (copy and start the core,
  take a MiSTer screenshot, type or move the mouse through a uinput device
  made by `tools/mister/kbd.py`). Screenshots need direct video off.
- JTAG: the MiSTer's USB-Blaster (the DE10-Nano's USB port) is plugged into
  the Ubuntu server; `tools/mister/jtag.sh chain|load SOF` runs `jtagconfig`
  or `quartus_pgm` in the Quartus container (`--privileged -v
  /dev/bus/usb`). The chain is the HPS (4BA00477) then the 5CSEBA6, so the
  FPGA is device 2. A load takes ~5 s against ~1 min to copy and load an
  .rbf; afterwards the script restarts MiSTer's main program, which finds the
  core already configured, sets up video and mounts the disks. Typed keys
  did not reach the core after one such restart (Oct 2026), probably
  MiSTer's menu left open (it doesn't show in screenshots); unconfirmed.
  SignalTap
  (`quartus_stp`) works through the same cable when a bug only shows on the
  hardware.
