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
- Ethernet (82586) and the Weitek FPA come after the console and disks.

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
- Floating point: no FPA modelled; float operands take the arithmetic-dispatch
  exception and Lisp emulates them. (The real XL1200 has a Weitek WTL3164 FPA on
  coprocessor addresses; sysdef lists its operation addresses.)

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
  resets the WD33C93 the way the FEP does, finds the first SCSI target whose
  label names a kernel, loads the kernel by its load map (12 blocks a READ(10)
  through buffer page 4), records BOOT-FEP-KERNEL-DPN, builds FEP-STARTUP's
  frame on the boot stack and jumps to it. `xlemu` boots through it from
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

## Interrupts (what Genera needs; not yet modelled)

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

## Genera 8.3 bring-up in the model (in progress)

`tools/fepfs.py mkworld` builds a FEP disk with `GENERA_8_3.ILOD` and a
paging file; on it the FEP's `Load World FEP7:>Genera-8-3.ilod` reports "The
Lisp Release of this world is Genera 8.3". Then `Start`:

- It writes the 82C54 (0x08000000) first; without a timer there it took a
  bus error and lost its way. `emu/pit.cpp` models the 82C54 now.
- It then initializes an empty PHT (PHT-BASE 0x59080, PHT-MASK 0xF000FFF8:
  8192 buckets, every PHT0 = 1:10 0xFFFFFF80, every PHT1 fixnum 0), clears
  the screen, switches to Lisp's stack (0xF000021D) and takes an instruction
  exception (opcode 3, setup-1d-array); pushing that trap's frame faults
  (page not resident: the stack page isn't in the PHT) and the model halts
  ("trap while pushing a trap frame"). Open question: what should have
  mapped the stack (wired pages loaded by `Start`, the stack cache absorbing
  the pushes, or something the FEP expected from hardware we don't model).

## RTL Ivory (`rtl/ivory/`)

`ivory_cpu.sv` is a state machine that follows the C++ model function by
function (the comments name the routine each group of states implements).
Memory is one 40-bit word per transaction; the processor marks physical
addresses (DTP-PHYSICAL-ADDRESS), and the memory system answers with the trap
vector to take. Subroutines (raw access, cycle-type reads/writes with
forwarding, push/pop, operand fetch, car/cdr, unbind) use a small return
stack; a trap abandons it. `tools/gen_ivory_states.py` generates the state
enum from the sources.

It was verified in lockstep with the C++ model under Verilator (`sim/ivory/`,
the processor alone on the model's bus): from reset through the boot PROM,
the FEP boot and `Hello`, 165M instructions, 141 opcodes, every register and
every memory word written agreeing after each instruction (earlier, 420M
instructions of a Genera 8.5 boot on the VLM's memory model).

Speed: about 13 cycles an instruction with single-cycle memory, after an
instruction-word buffer (the second halfword instruction of a word doesn't
fetch it again) and memory requests issued straight from the state that
needs them. Quartus 17.0.2, 5CSEBA6, processor alone: 15.5K ALMs (37%),
4.3K registers, 7 DSP blocks, Fmax 61 MHz (slow 85C).

## RTL boards (`rtl/xl/`)

Each follows its C++ counterpart in `emu/`:

- `xl_machine`: processor, address decode (as `Machine::phys_read`), boot
  PROM (512-word block RAM from `boot_prom.mem`), main board registers, VME
  registers, the microsecond clock (coprocessor 0o1002), device time.
- `xl_mem`: main memory and the I/O board's buffer memory in DDR3, one word
  per 64-bit DDR word (main memory at DDR word 0x06000000, buffer at
  0x06400000). Main memory goes through an 8K-word direct-mapped cache
  (four-word lines, write-through, allocate on read): only the processor
  touches main memory, the I/O board's DMA stays in its buffer memory. DDR3
  is cleared at power-up (it holds whatever the last core left).
- `xl_nvram`: MK48T02 behaviour; the clock is a BCD counter started from
  MiSTer's RTC (optionally 28 years back, as the VLM does for Genera).
- `xl_iob`: registers, DUSCC and AM9517 subsets for the console link, the
  buffer memory arbiter (console DMA, SCSI DMA, processor).
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
video counters follow the model); `obj_free/Vxl_machine` runs it as on the
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
