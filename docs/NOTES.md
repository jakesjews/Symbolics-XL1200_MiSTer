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
| 0x00000000–0x003FFFFF, 0x10000000–0x103FFFFF, 0x20000000–0x203FFFFF, 0x30000000–0x303FFFFF | Main memory: 4 MW on the main board at 0 and a 4 MW memory expansion board in each of the three memory slots (16 MW, the XL1200's most; the reference XL1201's main board has 4 MW and no boards). The FEP's hardware tables size the main board in 2 MW chunks, at most four (probes at 0, 0o10000000, 0x400000, 0x600000: a contiguous 16 MW shows as 8 MW), then take the memory boards from the ECO register's nibbles 1-3 (F = empty, `find-merlin-boards` in i-sys/configuration.lisp does the same) and size each present board at its slot (0x10000000, 0x20000000, 0x30000000, in 4 MW steps); it also probes 0x58000000 and 0x68000000 for other boards. With ECO 0xFFF51111 `Show Configuration` lists Memory Expansion Boards 0-2 and 2048k, 2048k, 4096k, 4096k, 4096k words, in the emulator, on the RTL bench and on the MiSTer (seed 9 of Nov 2 2026). In DDR3 at word 0x0600_0000 + {slot, offset} (byte 0x30000000), a 40-bit word a DDR word; the I/O board's buffer memory at 0x0700_0000, the color board's 16 MB at 0x0710_0000 | FEP `Show Configuration` in the emulator, Nov 2026 |
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

### The MacIvory disk and the full image

The collection's `MacIvory_Virginal_9GB.img.7z` (the loper-os factory disk,
9,105,018,880 bytes) is an Apple partition map with four HFS Standard
volumes: "Mac-OS-8" (the Mac system, the MacIvory software) and "FEP0",
"FEP1", "FEP2", each holding one 2,145,117,440-byte Mac file "MacIvory
FEPn" (hfsutils reads them: `hmount`, `hcopy -r "FEP0:MacIvory FEP0"`;
7-Zip can't, it only reads HFS+).  That file is a FEP file system with
the same FEPD/FEPF structures as an XL disk, 1280-byte blocks at stride
1280, every 32-bit word byte-swapped (`swap32.py`), and the LABL at block
13 instead of 0: `fepfs.py -S 1280 -L 13 ls` lists it.  FEP0 has the
I328 (MacIvory) FEP, two 500,000-block paging files, `Genera-8-3.ilod`
(the distribution world, 44,402 blocks), `Genera-8-3-Y2K-fixed.ilod`
(2,072 blocks: a layered world over it, which `Boot.boot` loads), the
netboot core, `animation-mac-6-2.ilod` (78,919 blocks), a `patches`
directory (Y2K-fix, kbd-repeat, comm-chip-hung-fix, fepfs-patch,
copy-world-patch, doc-on-*), and `fspt.fspt`, 16 bytes of text
"fep1:>lmfs.file": the file system partition table naming the LMFS
partition, which is FEP1's one file, `lmfs.file.1`, 770,000 blocks
(985.6 MB; the 198 MB of files the collection's recovery toolkit lists:
Joshua, Concordia, Statice, CLIM, DNA, documentation, fonts).  FEP2 is
empty.  A partition's FEPF has no byte length (`get` copies its blocks).

The full image, `research/media/disks/xl1200-full.vhd` (1,150,000 blocks,
1.77 GB): `mkworld` with the CD's world, `--standalone --internet`, 120,000
paging blocks, then `fepfs.py add` of the MacIvory LMFS partition (it
becomes `>lmfs.file.2`; the template's 20,000-block `lmfs.file.1` stays
unused), an `fspt.fspt` saying "fep7:>lmfs.file" (newest), the animation
world, and the XL1201 patches from Douglas Fields' GitHub
`LispEngineer/genera-patches` (`y2k-fix.lisp`/`.ibin`, Reti's private
patch of 2000-01-01 for TIME:READ-CALENDAR-CLOCK and the who-line's
two-digit year; `calendar-clock-y2k-fix`, `kbd-repeat`,
`comm-chip-hung-fix`, `fepfs-patch`, `copy-world-patch`), kept in
`research/downloads/genera-patches` (gitignored).

On the MiSTer (Oct 31 2026, build 36) it boots and Genera mounts the
MacIvory LMFS as `XL1200:>` (192,490 records, 23% used; `>sys>site>`
holds the MacIvory's 146 system files), once the `fspt.fspt` was written
without its trailing Return: with it Genera parsed the partition's type
as "fileδ" (longer than 4 characters) and entered the debugger at the
first LMFS access, though the MacIvory's own table has the same byte.
`Copy File FEP7:>sys-translations.text XL1200:>sys>site>sys.translations`,
`Load File FEP7:>y2k-fix.lisp` ("Genera 8 3 y2k patches" in the herald),
`Save World FEP7:>Genera-8-3-full.ilod` (44,706 blocks, six minutes) and
its boot file; cold-booted with the OSD's Clock at "Today" (status bit 6,
written straight into `config/XL1200.CFG`), `(nth-value 5
(decode-universal-time (get-universal-time)))` is 2026.  The image is
the master `research/media/disks/xl1200-full.vhd`.

The animation world (Genera 8.1.1, System 436.39) takes the same patch:
`Load File FEP7:>y2k-fix.lisp` traps on each of its `SCT:` patch-section
functions, which 8.1.1 has in `SI:` (FILES-PATCHED-IN-THIS-PATCH-FILE,
BEGIN-PATCH-SECTION, PATCH-SECTION-SOURCE-FILE, PATCH-SECTION-ATTRIBUTES;
Super-D then P in the debugger takes the SI definition permanently), then
loads ("DOMINO is not a defined system type" is a warning).  8.1.1's Save
World takes Complete or Incremental first: `Save World Incremental
FEP7:>animation-mac-6-2-y2k.ilod` writes 3,080 blocks over the parent
world in under a minute, "Genera 8 3 y2k patches" in its herald, the
label "436.39, 2 private patches"; No to the boot file, which stays with
the 8.3 world.  Cold-booted with Clock at "Today" it answers 2026 too, so
the full disk's both worlds take today's date.

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

### Loading systems on the full disk

The full disk's world came from the MacIvory image, and its SYS logical host
still carries the translations of the site that restored the distribution
(`SYS:COLOR;**;` to `DISTRIBUTION|DIS-R-HOST:>rel-8-3>sys>color>**>` and
so on for every directory), while the file on the disk,
`XL1200:>sys>site>sys.translations`, has the two entries that point at
`XL1200:>sys>`. So `Load System Color` fails at once with "The host
DISTRIBUTION|DIS-R-HOST is not accessible" even though every file it needs
is in `XL1200:>sys>color>`. Loading the file into the world first fixes it:
`(load "xl1200:>sys>site>sys.translations")`; then `Load System Color`
finds the system's own site files (`sys:site;color.system` and those of
its components Graphics Support, Genera Extensions, Essential Image
Substrate, Color System Documentation, SGD Book Design, FrameThrower and
its XL interface) and loads Color 426 with its documentation, about four
minutes on the core, with a `**MORE**` to answer now and then. A world
saved after that keeps the translations. `FEP7:>Genera-8-3-color.ilod` on
the user's MiSTer is that world (56,873 blocks; the FEP partition had room
for one more), with the sync format and `color::make-mister-color-screen`
from `tools/genera/mister-color.lisp` defined; the boot file still loads
the full world.

A freeze (Nov 1 2026, build 40, the full world with Color loaded in the
session, MORE off): `Load System CLIM` stopped four minutes in, reading
`sys:clim;rel-2;clim;output-protocol.ibin` (the who-line said 12%): the
who-line clock stayed at 5:40:59, the screen never changed again, the mouse
did not move the cursor, and Genera did not answer pings; MiSTer's main
program was polling normally and the card logged no errors. Nothing in a
release build says what the processor or the DDR3 port were doing, hence
the OSD notices in XL1200.sv for the next build. Recovered by reloading
the core; the session's Color load was lost (save the world before the
next long load). Incremental saves need IDS on first: Genera 8.3's `Save
World` only offers Incremental when `si:*sysout-enabled-p*` is true, which
`(si:enable-sysout)` sets (the `Enable IDS` command typed at the Listener
left no trace); `Save World Incremental FEP7:>Genera-8-3-color.ilod` then
asks the herald and label questions as a full save does.

The trap behind it (Nov 2 2026, the second attempt, from the saved Color
world): "The PUSH-INSTANCE-VARIABLE microcode ran into an invalid mapping
table" at PC 11 of a CLOS :around method while loading ptypes2.ibin. In the
Debugger the frame's mapping table was sound (short prefix, 255 entries) and
entry 3 was the compiled function CLOS-INTERNALS::MAPPING-TABLE-CALL-READER,
the designed "reader" case; Genera's handler for the push-instance-variable
instruction exception (debugger/itrap.lisp) calls such an entry, but the
core had raised an error trap, whose path (the SUBSCRIPT-BOUNDS-ERROR
dispatch) knows only flavors and :UPDATE entries. Two things were wrong, in
the RTL and the model alike: the index came through the addressing-mode
decode, so an operand whose mode bits aren't 3 (CLOS writes other values
there) read FP|3, self's address, as the index and failed the bounds check
against the table's 255; and a non-fixnum entry raised an error trap. The
VLM (the authority on the chip's behavior; its :10-bit-immediate format
comment: "10 bit operand is in arg1, truncated 8 bit is in arg2", and the
instance-variable code uses arg2 with one entry point for all modes)
takes the operand's low byte as the index whatever the mode bits say, and
sends a non-fixnum entry to the instruction exception with the index (after
the value for pop and movem) as arguments. Taking all ten bits instead
looped the FEP in traps; the eight-bit form is what both implementations do
now. The emulator reproduced the load in three minutes (the second trap
it hit, a data read at a mapping table's header in a pop-instance-variable,
was the same decode with mode bits 1 or 2), which is how the fix was tried
before any build.

The third trap (Nov 2 2026, the same load with the fixes in, run with a
fixed calendar clock so it repeats instruction for instruction): a
pop-instance-variable's header read of its mapping table found
DTP-GC-FORWARD. An ephemeral flip 2.5 million instructions earlier had
condemned the table's half of level 0, a transport trap elsewhere had then
copied it, and the pointer the instruction used was a full-word constant in
the method's compiled code, pushed as it was. The page (0x8804f4) was marked
right: its PHT entry said it referenced ephemeral group 0 and had the
transport-trap bit, and the scavenger would have rewritten the constant when
it reached the page; the spec's appendix on the Revision 0 implementation
says what the chip does meanwhile: it "always traps when executing an
instruction from a page with transport-trap=1. Later implementations may be
able to do an actual oldspace check in this case." Neither the model nor
the RTL checked anything on an instruction fetch. Both now take the
transport trap, naming the word, when a fetched word is a pointer into
oldspace and its page has the bit (the later-revision form; the RTL reads a
word it got from the instruction cache once more through the memory stage
for the page's bit, only in that rare case). Genera's handler transports
every oldspace reference in the page: in the replay the constant 26 words
before trapped first and the handler's rewrite of the mapping-table
constant followed 2,000 instructions later; the load went on.

### The logic-variable instructions (Nov 2 2026)

`Load System Jericho` stopped on "Unexpected trap through 4013": compiled
Joshua code ran `dereference` (opcode 013), which the model and the RTL
raised as an instruction exception, and Genera 8.3 has no handler for it.
A check over every instruction rather than application by application: the
world's trap vector table (instruction exceptions at 0xF8040800 plus the
opcode) fills 34 of the 256 vectors (car, cdr, the array and
instance-variable instructions, ldb, dpb, rplaca and so on); the other 222
go to `UNEXPECTED-TRAP-HANDLER`. Every instruction exception the model or
the RTL raises is for one of the 34 except the five logic-variable
instructions (`dereference`, `logic-tail-test`, `push-global-logic-variable`,
`push-local-logic-variables`, `unify`), and every arithmetic type pair
either raises has a handler in the arithmetic vectors, so no other program
should meet this kind of gap.

No spec section covers them (the spec we have still lists
DTP-LOGIC-VARIABLE among the 3600's types an I machine lacks). What there
is: Genera's compiler emits only `dereference`, to read a variable declared
`logic-variable`, and `push-local-logic-variables`, its peephole for
unbound variables pushed in place (each a logic-variable pointer to its own
cell); Genera's manual ("Instructions That Change Ivory Registers") says
BAR-2 and BAR-3 change only by Joshua instructions,
`push-global-logic-variable` and `unify`; the VLM implements four in
`alpha-emulator/ifunjosh.as` and leaves `unify` unimplemented; and Joshua's
own patches say Ivory revisions 0 to 2 had logic variables acting like
EVCPs. Both implementations now follow the VLM's four.

They need one thing the spec's Table 13 predates: the VLM's memory-action
table (taken from Symbolics' `ISOFT:EMULATOR;DEFS`, `memoryem.lisp`) has a
logic-variable column, and a data-read or raw-translate of a
logic-variable word returns it as an EVCP with its cdr code (a header read
traps, everything else takes it as data). An unbound variable is a cell
holding a logic-variable pointer to itself; anything read out of memory
that refers to a variable is then an EVCP, which later reads follow to the
binding. Without it the first try smashed a symbol: in Jericho's
grandparent example a query list built while `?who` was unbound still held
the logic-variable pointer after `?who` was bound, `car` returned it as it
was, and Joshua's `unify` took it for an unbound variable
(`unbound-logic-variable-p` tests the type alone) and stored through it into
the symbol's header. Following chains in `dereference` instead did not help;
the transform did. Two choices of ours: `push-global-logic-variable` puts
the unbound variable in its new cell where the VLM stores the EVCP it
pushes (a pointer to itself that a read would follow forever), and `unify`
still raises its exception (its semantics aren't known and the compiler
never emits it).

Checked: `tools/cputest.py` has each instruction and the transform with
their expected words; in the emulator Joshua and Jericho load, and
Jericho's examples answer: "``Me'' is his own grampaw!" and "``Daughter''
is her own grammaw!", the monkey-and-bananas and blocks-world plans, the
circuit diagnosis (`HT:M2`), Tweety flying, not flying as a penguin and
flying again when that is withdrawn, and the Midsummer TMS demo's
contradiction graph and its backtracking prompt (it asks the user, as
designed). The RTL machine, started from a snapshot after the load and
running alone, prints the grandparent answer too. On the MiSTer (seed 5:
34,766 ALMs, 83%; setup slack +0.436 ns worst, hold +0.199; seeds 2 and 6
also met timing, 3 could not fit; started from another XL1200 core, as a
start from the menu hung then, see "Quartus and MiSTer lessons") the fat
world's second version boots with Joshua and Jericho in its herald, and the
grandparent example, Tweety and the circuit diagnosis answer as in the
emulator.

### The emulator as a debugger

What found the third trap in an afternoon, all in `emu/main.cpp`:
`XLEMU_EPOCH=seconds` fixes the calendar clock to the machine's cycles, so a
run repeats exactly and an instruction count names a moment; `-W FILE`
writes the whole machine (processor, 128 MB of memory, devices, NVRAM) when
the run stops and copies the disk image next to it as `FILE.disk`, and `-R
FILE` resumes from it (on a fresh copy of the disk; `-n` stays absolute and
`-Kat` counts from the resume), so the twelve minutes to a trap at
instruction 2.93 billion became a snapshot at 2.92 billion and one-second
replays; `XLEMU_WATCH=vma` logs every read and write of a word with the PC,
opcode and instruction count (the frame word, then the mapping table's old
address, then the code word, each a replay); `XLEMU_ERRLOG=1` also logs the
ephemeral-oldspace register's writes (the flips) and the transport traps
on instruction fetch; `XLEMU_MAPCHECK=1` compares the map cache's PHT bits
with the PHT on every write (they agreed throughout; the bookkeeping was
not the fault); `XLEMU_PHTVMA=vma` prints that page's PHT and map entries
at every flip and at the end. The lockstep bench's model logs the same
with `XLEMU_ERRLOG=1` (`sim/system/tb_system.cpp`). `-b PC` prints the
control stack each time the PC reaches that word, and `XLEMU_BT=1` at the
end, with each frame's function named from its compiled-function header
(what found the smashed symbol above, from `%UNIFY-VARIABLE` up through
Joshua's `UNIFY-LIST` to `FIND-OWN-GRANDPARENT`).

For long scripted sessions (building a world): `XLEMU_STOP_ON=TEXT` stops
the run 50 million instructions after the disk is written with TEXT, so a
batch that ends by writing a results file with a marker (built at run time,
`(format o "XLEMU-~A" "FINISHED")`, so the typed text itself can't be paged
out and trip it) stops when it is done instead of at a guessed limit (but
not across a Save World, which writes memory and any marker string still in
it: run the save with `XLEMU_STOP_ON` unset);
`XLEMU_SHOT_EVERY=N` rewrites the `-V` screen every N million instructions
(written to a temporary name and renamed), to watch a run from outside;
SIGUSR1 stops a run as its limit would, screen and `-W` snapshot written, so
a session waiting at a prompt is resumed with the answer instead of rerun.

### The fat world (Nov 2 2026)

`FEP7:>Genera-8-3-fat.ilod.1` (81,381 blocks, a complete save) holds the
full world plus Color 426 with Color Demo and the FrameThrower systems,
CLIM 66.3 with Genera-CLIM, PostScript-CLIM, CLIM Demo and CLIM
Documentation, Statice Runtime, Statice and Statice Browser 460, Concordia
439.1, Metering 439 and Hacks 435, and `color:make-mister-color-screen`
(the forms of `tools/genera/mister-color.lisp`). `boot.boot` loads it, so
`Hello` then `Boot` brings it up. Built in the emulator in about forty
minutes from the full image (`XLEMU_EPOCH` fixed, a snapshot after each
stage): `fepfs.py grow` to 2,000,000 blocks first (a running Genera keeps
the FEP free map in memory, so never under one), `Hello`, `Boot`, login,
`(load "xl1200:>sys>site>sys.translations")`, `Load System Color`, the
color-screen forms, then the systems in that order through
`(sct:load-system s :query nil)` with `si:inhibit-fdefine-warnings` set,
then `(si:disk-save "FEP7:>Genera-8-3-fat.ilod" nil :query nil :boot-file
"FEP7:>boot.boot")`, which asks nothing (the herald from the systems'
versions) and updates the boot file. On the MiSTer (build 41) it boots
with that herald, Color Demo's bars draw on the color board and
`(clim-demo::start-demo)` opens the demo launcher. The image is
`~/Downloads/XL1200-Genera-8-3-fat.vhd` on the user's Mac (3.07 GB,
832,384 blocks free with the second version below; licensed media, not in
the repository).

Order matters: CLIM-Demo's browser needs PostScript-CLIM's package, and
Statice needs Statice-Runtime loaded first. Joshua needs a `JOSHUA`
logical host: `XL1200:>sys>site>joshua.translations` (on the disk) maps
`JOSHUA:**;` to `XL1200:>sys>**>` as `SYS:` is, its files being in
`>sys>code>`, `>sys>examples>`, `>sys>data>`. Jericho stopped on
"Unexpected trap through 4013" until the logic-variable instructions
worked (above); then, from a snapshot of the first fat world booted, login,
`(load "xl1200:>sys>site>joshua.translations")`, Joshua and Jericho through
`sct:load-system`, `tv:more-processing-global-enable` and
`si:inhibit-fdefine-warnings` back to their defaults, and `(si:disk-save
"FEP7:>Genera-8-3-fat.ilod.2" nil :query nil :boot-file "FEP7:>boot.boot")`
(85,498 blocks; without the version it asks to overwrite the running
world's own file, which it still pages from). Booted cold, its herald adds
Joshua 237.3 and Jericho 237.0 and the grandparent example answers; the
first version and its boot file are deleted and expunged (81,384 blocks).
Left out: Illustrate and TeX (tape restores), and Concordia's saving needs
a lock server; Statice needs a database set up before it does anything. Genera's
`ignore-errors` in a CL-USER Listener returns NIL and T on an error, not
the condition (`conditions:handler-case` gives the message): the first
batch read four failures as successes that way.

### The fat world, version 3 (Nov 2 2026)

`FEP7:>Genera-8-3-fat.ilod.4` (161,211 blocks, a complete save; `boot.boot`
loads it) adds to version 2 everything else the application checklist
(`research/XL1200_Application_Installation_Handoff.md`) names that runs on
an Ivory: Symbolics C 437, Fortran 431, Pascal 430, Conversion Tools 430,
Joshua Metering 206, DBFS Utilities 439, NFS Server 435, X Server 424,
Mailer 434, Domain Name Server 432, Print Spooler 435, DNA 434; Images 430,
Image Data, Color Editor 420, Fast Fourier Transforms 11, Fourier Fractals
21, Graphics Library and Toolkit, Colorize Tables 23 (S-Colorize), S-Convert
12, S-Compositor 15; Illustrate 425; TeX, LaTeX, SliTeX, YTeX, BibTeX,
INITeX, VIRTeX, TANGLE, WEAVE, DVItype, POOLtype, TFtoPL and PLtoTF 425 with
the DVI previewer; CL-HTTP 60.57 with HTTP Base Client, W3P, W4, W4
Examples, CL-HTTP-CLIM and the HTML Parser; Macsyma 421.45; Basic-,
Schematic-, VLSI-, PCB- and Gate-Array-NS 36; Screamer 3.12; Soar 5.2.2.
Flavors Statice can't share a world with Statice (both define the STATICE
and DBFS packages), so it is `FEP7:>Genera-8-3-flavors-statice.ilod`, 7,644
blocks saved incrementally over `Genera-8-3-full.ilod` (`Hello`, `Load World
FEP7:>Genera-8-3-flavors-statice.ilod`, `Start`). The animation world stays
as it was. The herald now has more systems than its ten-per-column table
fits across the screen; Genera draws it that way, and `Show Herald` lists
them all.

Getting the files there: `tools/distfile.py` reads and writes Genera's
distribution files, the "dummy tape" files `Restore Distribution :Use Disk
Yes` takes: an embedded-length stream (`sys.sct/distribution/`), a
directory form, then each file as an attributes record and its contents,
compressed ones as Unix `compress` LZW behind a Symbolics preamble. Seven
went onto the FEP disk with `fepfs.py add` and were restored: the 8.3 CD's
`8_3_COLOR_DIST.TAPE` (the GRAPHICS: and IMAGES: trees, Fourier Fractals,
the sample images), Illustrate's and TeX's distributions (the
collection's `*.dist.*` pieces concatenated), CL-HTTP's
`lispm-60-57.reel-1` (written on an Ivory under 8.3, `.ibin` files), and
three made by `distfile.py make`: Macsyma and NS from the pinned sys.sct's
`contributed/` and the site files. A second round after a save and a cold
boot (a running Genera keeps the FEP free map in memory) added Screamer
3.12 (`ftp.ai.mit.edu/pub/screamer`, which lists Genera 8.3), Soar 5.2.2
(the CMU AI Repository's `soar5.tar`), TeX's `initex.pool` and
`virtex.pool` (`SYS:TEX;`), and CL-HTTP 60.57's `www` and `examples` trees
from its source archive. The logical hosts are ours,
`tools/genera/site/`: GRAPHICS: is SYS: (where the MacIvory disk already
had FFT, Convert and the rest), IMAGES: SYS:IMAGES;, ILL: SYS:ILLUSTRATE;,
HTTP: and its HTML-PARSER:, SPT: and BTREE: under SYS:CONTRIBUTED;CL-HTTP;.

What each needed:

- TeX's component directories ask for the Pascal runtime 411 (Genera 8.0,
  on its tape); 8.3 has 431. Loaded at `:version :newest` with SCT's
  "component systems at other versions" menu answered with the loaded
  versions (rebinding `sct::collect-component-versions-from-menu` for the
  batch: `:query nil` doesn't cover that menu). Loading TeX preloads its
  format by running VIRTeX, which writes `texput.log` in
  `fs:default-pathname`, `XL1200:>foo>` in our worlds, a directory that
  doesn't exist: the world's default is now `XL1200:>lispm>`, created on the
  disk (the Lisp-Machine user's home directory).
- W4 Examples loads `HTTP:EXAMPLES;DOCUMENTATION`, which the reel lacks; the
  60.57 source archive has it.
- Macsyma and NS were compiled on Open Genera (`.vbin`, Macsyma's component
  directory written on a VLM). Renamed `.ibin` (and `m-macros` back to
  `m_macros`), they load at `:version :newest` and run: Macsyma 421.45's
  frame and NS's editor draw. Both then stop at their license checks,
  Macsyma Inc's password and the NS password the namespace should hold,
  each keyed to the machine ID (62686). Nothing here works around them.
- Screamer's source reads as ANSI Common Lisp, where its CLtL1
  `SPECIAL-FORM-P` is an undefined `SCREAMER::SPECIAL-FORM-P` (MIT's ibin
  has the same reference); `tools/genera/contributed/screamer/genera.lisp`
  defines it as `LISP:SPECIAL-FORM-P`, and it is compiled here.
  `(screamer:all-values (screamer:an-integer-between 1 5))` gives
  `(1 2 3 4 5)`.
- Soar 5.2.2 has package workarounds for Lucid, CCL, Allegro and TI, none
  for Genera. Two lines of `soar5.lisp` on the disk are changed (the new
  version beside the original): `(pushnew :sx *features*)` is commented
  out (SoarX needs Garnet, and Genera has an SX package), and the init file
  is `soar-init.lisp`, not `.soar-init.lisp` (a name an LMFS reads as a
  version "lisp"). Before compiling, CL-USER keeps `SCL:ACCEPT` and
  `SCL:INSTANCE` (shadowing imports) where Soar's own symbols would clash.
  Soar installs its syntax in the global readtable when it loads, which
  breaks backquote everywhere, so the load ends with `(soarresetsyntax)`;
  and Genera's `load` reads a file with its own Syntax attribute's
  readtable, so `.soar` files go through `soar-load`
  (`tools/genera/contributed/soar/genera.lisp`): `(soar-load
  "sys:contributed;soar;lib;default;default.soar")`, the task the same
  way, `(run)` with no typeahead (Soar breaks on a pending key). The
  waterjug task searches and finds its solution.

- Illustrate 425 (MIT's, from 1983-86, distributed for Genera 8.0 by
  A. I. Architects) loads but doesn't come up, on the MiSTer and in the
  emulator alike, in the fat world and alone in the full world: Select
  Activity (or Illustrate's own `(ill t)`) leaves no window selected, the
  frame's process "Ill Frame 1" in Output Hold and the selecting process
  waiting on a Sheet Lock (Peek). Exposing the frame by hand draws its panes
  and then traps on an unbound `ILL:*ILLUSTRATE-FRAME*` in
  `ILL:DRAW-DASH-PATTERN` (the frame sets it only before `:select`); setting
  it before `:expose` (a `:before :expose` method) doesn't change the
  Select path. Left installed. Select `L` and Control-Meta-Abort get the
  Listener back.

Checked on the MiSTer (build 42) after the cold boot: CL-HTTP answers a
browser on the LAN (`(http:enable-http-service)` after login; its
documentation page and a GIF from the restored `www` tree, the GIF
byte-identical to the source); TeX typesets a page and the DVI Previewer
shows it; on the color screen the Images system draws the 8-bit sample
images (`images:mandelbrot;`, `images:8bit;`) and S-Colorize opens. A
24-bit image (`images:paint;mandrill`) stops on an undefined
`COLOR:IMAGE-PROCESS-MACRO-INTERNAL` when reduced to 8 bits, and Fourier
Fractals' images draw without a color map. `docs/applications.md` has the
whole list.

Then on the MiSTer, into the image itself (no new world: the changes are
the namespace and files on the disk):

- The XL1200 is its own Concordia lock server. Concordia locks a record
  before saving it through Lock Simple, a network service (protocol
  `:lock-simple`, TCP port 666) it looks for on the host holding the file or
  on a `:lock-simple-server` named by the host or the site. The host object
  got the service triple `LOCK-SIMPLE TCP LOCK-SIMPLE` (its property list's
  `:service`, then `net:update-object-permanently`, as Statice's Add DBFS
  PAGE Service does). The server takes only trusted hosts
  (`:reject-unless-trusted`), and the standalone site trusted none, so even
  the XL1200 connecting to itself was refused: the site's SECURE-SUBNETS is
  now `INTERNET All` (the user's call: security doesn't matter here), then
  `(tcp::parse-secure-subnets)`. After a reboot,
  `(lock-simple:write-lock "x" :pathname #p"XL1200:>lispm>test.sab")` and
  its unlock succeed, as Concordia's own call would, and the status line
  shows "LOCK-SIMPLE serving XL1200". A record saved from Concordia itself
  is still to try.
- A Statice file system, XLDB: `Create Statice File System XLDB` with a
  5,000-block partition (`FEP7:>Statice>XLDB-part0.file`, the directory in
  `XLDB.UFD`; the first try looped on "FEP Directory not found" for the
  `>Statice>` it had just created, and worked once it existed), which adds
  the namespace object and the DBFS-PAGE service, then `Add ASYNCH DBFS
  PAGE Service` and `Create Directory XLDB:>finance>`. The tutorial's bank
  database is `XLDB:>finance>bank`, and `XL1200:>lispm>bank.lisp` defines
  its schema and `bank-accounts`, `make-new-account` and
  `transfer-between-accounts` (accounts found with `for-each`: the
  tutorial's `account-named`, typed at the Listener, took its argument for
  a database); it holds Alice, Bob and Carol and kept them across a reboot.

Batches ran in the emulator from snapshots, each a typed form loading its
systems through `conditions:handler-case` and writing the results to a FEP
file ending in a stop marker (see "The emulator as a debugger"). The image,
after the lock server and Statice work on the MiSTer, a clean `Halt
Machine` and a copy back, is `~/Downloads/XL1200-Genera-8-3-fat.vhd`
(3,072,000,000 bytes, md5 e98819eb6a90eb60c7d92be7ee3506cc, the same on the
MiSTer's card; licensed media, not in the repository).

### The color screen at login (Nov 3 2026)

`FEP7:>Genera-8-3-fat-init.ilod.1` is version 3 plus a login step: every
Login loads `XL1200:>lispm>lispm-init.lisp` (the Lisp-Machine user's home
directory, LISPM-NAME LISPM), which makes the color screen once per boot
(`tools/genera/lispm-init.lisp`, `*color-screen*` in CL-USER), so the
System Menu's color programs have a screen without anything typed. Login
loads no init file on its own here: the Login command's `:Init File`
defaults to None in this world, though `si:*login-load-init-file-p*` is T
(`sys2/login.lisp` loads `fs:init-file-pathname "LISPM"` only when asked).
So CL-USER's `load-lispm-init-file` loads that pathname with
`:if-does-not-exist nil` inside `conditions:handler-case`, and
`(si::add-initialization "Load the LISPM-INIT file" '(load-lispm-init-file)
'(:login))` runs it at every Login; the file guards itself, so an explicit
`:Init File` as well loads it twice harmlessly.

Built in the emulator from the archived image (`boot0.vhd.7z`, md5
e98819eb6a90eb60c7d92be7ee3506cc): `fepfs.py add` of the init file, Login,
`Copy File` to `XL1200:>lispm>`, the initialization, the FEP copy deleted
and expunged, then `(si:disk-save "FEP7:>Genera-8-3-fat-init.ilod" t :query
nil :boot-file "FEP7:>boot.boot")`. That made a complete world (161,454
blocks, not an incremental one), and `boot.boot.6` loads it. A cold boot
with Hello and Boot brings it up, and a plain `Login Lisp-Machine` loads the
file (the emulator has no color board, so the file reports "No suitable
UNIVISION controller found" and carries on); `Halt Machine` before the
image was taken. `Genera-8-3-fat.ilod.4` stays on the FEP. The image is
`research/media/disks/fat-init/boot0.vhd` (licensed media, not in the
repository); the screen made at login is yet to be seen on the MiSTer.

### Paging with 4 MW

Peek's storage meters (Select P, Meters, "Storage meters") on the MiSTer
after a session of the full world: boot, Load System Color, Save World, two
idle hours. 16,384 usable pages of 256 words (4 MW); 33,602 pages fetched
from disk, 28,493 of them from the world file; 39,154 pages created; 64,366
pages flushed to make room, 7,573 of them modified and written to the
paging file; 142 s in page faults; 34,000 of the 120,000 paging-file pages
in use. The machine brought in twice its memory and spent minutes waiting
for it, mostly in the Color load and the save; an idle Listener needs
little. The XL1200 shipped with 4 MW (20 MB) and took up to 16 MW (80 MB)
on three 4 MW expansion boards, which is what the FEP's probes of
0x10000000, 0x20000000 and 0x30000000 look for.

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
  Interpreted, the same defun typed at a Listener and not compiled: (fib 20)
  4.13 s on the core against 0.026 s compiled (Nov 2 2026, build 40), 160x,
  so an interpreted (fib 30) is about seven minutes and a real XL1200's
  longer still; a user's "fib 30 ran five minutes" was this.
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

| Benchmark | M instructions | MiSTer cycles/instruction, build 8 | build 25 |
|---|---|---|---|
| Boyer | 11.3 | 30.5 | 7.9 |
| Browse | 18.8 | 29.8 | 6.8 |
| Destructive | 2.2 | 29.6 | 6.0 |
| Traverse init / run | 6.4 / 37.8 | 32.8 / 32.9 | 7.2 / 7.1 |
| Tak / Stak / Ctak / Takl | 0.63 / 1.27 / 10.9 / 5.5 | 29.4 / 41.4 / 27.3 / 30.6 | 4.8 / 10.7 / 4.8 / 6.2 |
| Deriv / Dderiv | 3.1 / 3.5 | 28.6 / 29.1 | 7.0 / 7.3 |
| Div2 iterative / recursive | 2.1 / 2.4 | 31.0 / 30.8 | 6.9 / 10.4 |
| FFT | 2.7 | 42.0 | 8.6 |
| Puzzle | 49.0 | 27.1 | 4.7 |
| Triang | 135.3 | 30.8 | 6.4 |

fib in the model: (fib 25) 2.72M instructions, (fib 30) 30.15M (11.2 an
invocation). The XL1201's 4.097 s for (fib 30) is then 7.4M instructions a
second: 4.2 cycles an instruction at 30.75 MHz, 5.4 at 40 MHz, 1.4 at 10
MHz; the last is impossible for a mix of calls and returns, so the machine
cycle is in the 30-40 MHz range. The MiSTer does 1.72M a second.

Stak (special binding) and FFT (floating point through the FPA) cost the
most cycles an instruction, and still do on build 25, with the
recursive Div2, Boyer and Traverse (list structure spread over the heap:
the DDR cache's misses) next; Tak, Ctak, fib and Puzzle run at the
pipeline's 4.7-4.8. Puzzle runs 49M instructions where the 3600
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
`docs/ivory.md`, with each step's measurement; the stack cache brought
`(fib 30)` to 9.33 s (15.5 cycles an instruction), the instruction cache
and TLB to 6.43 s, the pipeline steps to 3.68 s and 3.06 s, the memory
path to 2.81 s (build 23, 4.7 cycles; build 25 with the array elements
through the shared units the same), under the XL1201's 4.10 s;
Gabriel's geometric mean against the 3600 went 1.41x, 2.31x, 4.73x,
4.97x, 6.4x (a real Ivory ~6x), then 6.55x with the DDR cache answering
misses early and posting writes (build 27: Stak and the recursive Div2
11-13% faster), the compute-bound benchmarks past the real machine and
Puzzle (2.4x: Genera 8.3's version does more work) the outlier. Builds
28-31 (the prefetcher waiting for the memory, a miss passing the write
queue, a valid bit per cached word, the framework's YC and ALSA paths
compiled out with its own `MISTER_DISABLE_YC` and `MISTER_DISABLE_ALSA`
flags; the YC encoder came back for a while and is out again since Nov 1
2026: it only modulates color onto the core's own timing, and composite or
S-Video needs 15.7 kHz lines, not this machine's 54.35 kHz, so no TV can
lock to it; 246 ALMs and two multipliers in build 39)
measured the same, 6.56x and 2.80 s, and the speed work stops there;
the clock is the one lever left.

Before it, the RTL Ivory averaged ~29 cycles an instruction at 50 MHz, two thirds of
them waiting ~7 cycles per memory access (`PROFILE=1` on `sim/system`),
where the real chip's stack cache, TLB and instruction cache answer in a
cycle; and at least five states (fetch, fetch wait, decode, execute, retire)
even with no memory access.

The cache's size is not the lever either (Oct 31 2026): the DDR cache
doubled to 4096 lines of 4 words (16K words, 44 more M10Ks, no more logic;
seed 3 routed with 0.480 ns of slack, seeds 1 and 2 did not) ran the suite
at Boyer 1.702 s (5.52x the 3600), Traverse 6.02 s (5.87x), Div2 recursive
0.445 s (5.62x), Deriv 0.409 s (9.27x), Stak 0.240 s (9.58x), Puzzle
4.60 s, Triang 17.33 s: geometric mean 6.58x against build 30's 6.56x,
Boyer and Traverse unchanged, Div2 and Deriv 8% better, the rest noise.
Reverted. Boyer's working set outruns 16K words as it did 8K and Traverse
already fitted: both pay the latency of each miss, so the lever is the miss
path (an earlier restart, a prefetch of the next line, overlapping a miss
with the next instruction), not a bigger cache.

## Compatibility

Driven from the Mac with `tools/mister/run.sh type` (the Symbolics keys on
the PC function keys, `{ctrl x}` and `{meta x}` chords) and `shot`, Oct 31
2026, on build 30/31 (50 MHz).

Genera 8.3 on the 80,000-block bench disk: Zmacs (Select-E, Find File on
FEP7:, typing, Control-X Control-S, which asks "Who are you really?" under
the Lisp-Machine login and then writes `FEP7:>compat.lisp.1`), the
Document Examiner (Select-D, the candidates pane lists every Genera book:
the documentation database is on the disk), the Inspector (Select-I on
`*package*`), Peek (Select-P), Abort back to top level. `Start GC
:Immediately` on that disk warned "Address space low" five times and the
machine froze once it reached 0 words (the status line clock stopped):
the bench disk's 3.1M words of paging space is less than physical memory,
which Genera says will crash it, so the GC check moves to the 300 MB disk
(`fepfs.py mkworld --blocks 240000`, 174,895 blocks of paging).

On the 300 MB disk, configured as a standalone site (below): `Start GC
:Immediately` collected 186,360 words of dynamic space into 100,134 in 80
seconds, `(gc-immediately)` after it 138,931 into 101,563 in 90 seconds;
`(car 1)` enters the Debugger with the trap message and the five proceed
options; Abort returns to top level.

The "This Lisp world has not been configured for use at the local site"
box goes away by booting the world at Symbolics' standalone site, the way
a new XL1200 shipped (the Genera 8.3 Software Installation Guide for XL
Family Machines, "The Symbolics Standalone Site"): `Set Boot Options :Site
Name Standalone` and `Set Boot Options :Namespace Descriptor File ...` in
the Hello.boot, and the namespace files from the CD's
`sys.sct/standalone-site/xl1200/` (one host, XL1200, one user,
Lisp-Machine). The namespace files can live on the FEP disk (`mkworld
--text`); the host's Chaos address is 1200 to match the FEP's Local.boot.
The banner then reads "This machine is Standalone XL1200". The site's
`sys.translations` cannot: FEP file types are at most four characters, and
Genera looks for it at `XL1200:>sys>site>sys.translations` on the local
LMFS (a real XL keeps all the site files there), so until it exists the
boot prints "Unable to change site to Standalone. The directory >sys does
not exist" and carries on with the site's namespace loaded. `mkworld
--standalone` writes all of these (the namespace files, a Hello.boot.2
with the boot options, and `sys-translations.text` to copy); in Genera,
`Create Directory XL1200:>sys>` and `>sys>site>` on the template's empty
LMFS (20,000 blocks: 4,990 LMFS records of 5,056 bytes) and `Copy File
FEP7:>sys-translations.text XL1200:>sys>site>sys.translations` finish the
site; the translations map `SYS:SITE;` to that directory and `SYS:` to
`XL1200:>sys>` (the CD's version points at `local:>rel-8-1>sys>`, where
the sources would be restored).

`Save World FEP7:>Genera-8-3-site.ilod` after that: it shows the herald
(the site name is in it: "Standalone XL1200") and the disk-label title
"Genera 8.3" for confirmation, runs the before-cold initializations, logs
out, prints "System Shutdown ..." and writes the world with the scheduler
off (the status line's clock stops); 44,554 blocks in about six minutes,
125 blocks a second, sequentially into the free space. Then "Update boot
file to load FEP7:>Genera-8-3-site.ilod.1?": Yes, the default
`FEP7:>boot.boot`, and since the template has no boot.boot a file-error
menu offers Super-C, "Use the following as the contents of the boot file
instead: Load World FEP7:>Genera-8-3-site.ilod.1 / Start", which writes
it (46 bytes). After a cold start, `Hello` then `Boot` at the FEP runs
that file: the saved world's banner reads "Loaded from
FEP7:>Genera-8-3-site.ilod.1", "This machine is Standalone XL1200", with
no site message, 4.0M words physical and 29.3M words of swap (the
120,000-block paging file), and it is up within fifteen seconds of `Boot`
where the distribution world took eighty (its first boot does the site
and namespace work). Save World logs out first, so the saved world still
starts at "Please login".

Numbers, typed at the Listener of the saved world and checked against
Python (Oct 31 2026, build 30): bignums (`(expt 2 100)`, a 30-digit by
9-digit product, `(isqrt (expt 10 40))`, `(gcd (expt 2 64) (expt 6 20))`,
`(truncate (expt 3 50) 7)`), ratios (`22/7`, `(+ 1/3 2/3)` = 1,
`(expt 2/3 10)` = 1024/59049), double floats (`(sqrt 2.0d0)` =
1.4142135623730951d0, `(exp 1.0d0)`, `(/ 1.0d0 3)`, `(atan 1.0d0 1.0d0)`,
`(log 100.0d0 10)` = 2.0d0, `(truncate 1.0d19)`), single floats
(`(sqrt 2.0)` = 1.4142135, `(/ 1.0 3)` = 0.33333334, `(exp 10.0)` =
22026.465) and complex numbers (`(* #C(1 2) #C(3 4))` = #C(-5 10),
`(sqrt -2.0d0)` = #C(0.0 1.4142135623730951d0), `(/ #C(1 1) #C(1 -1))` =
#C(0 1); Genera gives `(sqrt -1)` as the exact #C(0 1)) all agree.
`(sin 1.0d0)` is 0.8414709848078966d0 against the correctly rounded
...965, and `(expt 1.1d0 100)` is 13780.61233982241d0 where repeated
multiplication gives ...2238: Genera's own series and exp-of-log
algorithms, a few units in the last place, not the FPA's basic
operations. The basic operations themselves round correctly: `(/ 1.0d0
7)` = 0.14285714285714285d0, `(* 3.0d0 0.1d0)` and `(+ 0.1d0 0.2d0)` =
0.30000000000000004d0, `(- 0.3d0 0.1d0)` = 0.19999999999999998d0, `(/
22.0d0 7)`, `(sqrt 3.0d0)`, `(* 1.0000000000000002d0
1.0000000000000002d0)` = 1.0000000000000004d0, 1 ± 1d-17/1d-16 = 1.0d0,
`(/ 1.0d0 1.0d-300)` = 9.999999999999999d299, `(* 123456789.0d0
987654321.0d0)` = 1.2193263111263526d17, `(/ 2.0d0 3.0d0)`; single `(+
0.1 0.2)` and `(* 3.0 0.1)` = 0.3, `(/ 1.0 7)` = 0.14285715, 16777217.0
reads as 1.6777216e7 and 16777216.0 + 1.0 stays there; `(* 1.0d0 (expt
2 1023))` = 8.98846567431158d307. The traps: `(* 1.0e20 1.0e20)` signals
the single-float overflow (`cli::signal-single-float-trap`, traps
134217728, exponent 255, non-trap result +1e∞) with the Debugger's "use
the infinite result" option; `(* 1.0d300 1.0d10)` and `(float (expt 2
1024) 1.0d0)` the double-float overflow (in `%double-floating-multiply`
and `%double-floating-scale`, exponent 2047); `(* 1.0d-200 1.0d-200)` the
underflow ("too small in magnitude to be representable as a normalized
double-precision floating-point number", traps 67108864, exponent -306)
offering the zero result.

Genera 8.3's own programs, every one Select Help lists, open on the
saved world and draw their frames: Converse (Select-C), the Document
Examiner (D), the Editor (E), File System Operations (F, with Local LMFS
Operations), the Inspector (I), the Listener (L), Zmail (M, "No current
message sequence"), Notifications (N), Peek (P, its help page), Frame-Up
(Q, the layout of a dummy program), Terminal (T, "Connect:") and the
Flavor Examiner (X).

Ephemeral GC: `(time (dotimes (i 50) (make-list 100000)))`, 5M words of
consing, took 7.4 s (4.1 s in the storage system, 3.8 s of it creating
and destroying pages) and flipped the ephemeral collector; `Show GC
Status` afterwards: ephemeral GC on, 172 ephemeral GCs in the generation
count, 5,092,981 words consed since cold boot and 4,835,225 reclaimed,
with 14.6M words available before a `Start GC :Immediately` might run out
of space.

The MacIvory animation world (`animation-mac-6-2.ilod`, Genera 8.1.1,
System 436.39, from the user's collection) boots on the core from its own
300 MB disk: the banner says "a Symbolics XL1200", 4.0M words physical and
34.3M words of swap, with FrameThrower 10.52, Color, Graphics Library,
Images, Live Window, Graphics Toolkit, PaintAmation, S-Geometry, S-Dynamics,
S-Render, S-Compositor, S-Convert, S-Record, S-Colorize, Experimental
Solitaire and the rest loaded. Each Select-key program opened and drew
its frame: S-Paint, the S-Dynamics script editor with the S-Geometry
viewer and camera menus, S-Compositor, S-Record (warnings only: no file
server for its options file, no video recorder in the namespace),
S-Convert, S-Colorize, Frame-Up, the Flavor Examiner, File System
Operations (with Local LMFS Operations), Zmail, Converse, Terminal,
Object Attributes; FrameThrower Utilities reports "No color configuration
file found", as it would with no FrameThrower. The Joshua, Concordia,
Statice and CLIM named in the collection's audit are installed files on
the MacIvory disk, not systems in this world.

## Network

The 82586 on the I/O board reaches a real network the way the Sun, NeXT,
SGI, HP 9000, Macintosh and Amiga cores do: the chip stays in the FPGA and
Main_MiSTer is the wire.  Frames cross a mailbox in DDR3 at ARM physical
0x1FF00000 (64 KB, outside the core's memory; the same window those
cores use) that Main polls from its main loop and moves to a raw socket on
eth0 (promiscuous, with a BPF filter on the guest's MAC), eth1, a macvlan
child of eth0, or a tap device, as the OSD's Network option says (eth0,
Off, eth1, macvlan, tap0: the Sun cores' order, so Main's code for them
serves).  Nothing runs by hand.  Over WiFi only tap0 can work: a WiFi
client may only send frames with its own MAC, so eth0's raw socket and the
macvlan fail there; tap0 with routing (proxy ARP both sides) on the MiSTer
would put Genera on the LAN at its own address, a follow-up.

- `rtl/xl/xl_eth_hps.sv` is the SparcStation 20 core's `eth_hps.sv`
  (GPL-2+) with the magic word "XLETH001": the mailbox protocol SSETH002
  (magic, generation, TX and RX write/read counts, the MAC word, 8 TX
  slots and 16 RX slots of 2 KB with a length header; Main appends the
  FCS to received frames and computes the LADRF hash), 10 Mb/s pacing of
  received frames, the station/broadcast/multicast/promiscuous filter,
  loopback, and the drops (Main not running: 50 ms; network off: at
  once).  `rtl/xl/ddram_arb.sv`, the same core's arbiter, puts it on the
  DDR port behind `xl_mem` (master 0, with priority).
- `rtl/xl/xl_i82586.sv` grew the transmit and receive engines on Genera's
  structures (`network/82586-ethernet-driver.lisp`): a transmit block's
  TBD chain is pushed to the wire 16 bits at a time (byte enables for odd
  starts and ends; with AL-LOC 0 the destination, the station address and
  the length from the block go first) and the block completes with C and
  OK once the wire has the frame; a received frame goes to the RFD at the
  RFA and its RBD chain (the one the RFD names, or the one in use),
  buffer by buffer with actual counts, F and EOF, the RFD getting the
  first RBD's offset, C and OK (and the address and length fields with
  AL-LOC 0), then FR; EL on an RFD ends the area (no resources, RNR), S
  suspends, an RBD with EL inside a frame truncates it; IA-setup sets the
  station address (published to Main), configure takes AL-LOC, loopback,
  promiscuous and broadcast disable, MC-setup opens the multicast filter.
  Genera's driver configures AL-LOC 1 (addresses in the buffers), 192-byte
  receive buffers (a 1514-byte frame spans eight), sixty frames, and
  restarts the RU itself when it runs out.  The FCS is not stored.
- `sim/ether/` drives the chip as the driver does and plays Main's side of
  the mailbox (the structures Genera lays out, Main's CRC and hash): the
  handshake, configure and IA-setup, transmits of one buffer, a chain with
  odd lengths and an odd start, 1514 and 14 bytes, receives across two
  and eight buffers, an odd broadcast, a frame for another station
  (consumed, not delivered), suspend and resume, the last RFD and the
  driver's restart, AL-LOC 0 both ways, and the network off.  489k cycles.
- Main's side: `tools/mister/Main_MiSTer-xl1200-enet.patch`,
  `support/xl1200/xl1200_enet.cpp` (the Sun bridge keyed on XLETH001, the
  OSD option at status bits 10:8, macvlan child "xl0") and the three
  user_io hooks, for a pull request to MiSTer-devel/Main_MiSTer.  Built
  with the Arm GNU 10.2 toolchain on the Ubuntu server
  (`~/dev/mister/toolchain`, `~/dev/mister/Main_MiSTer`).
- The namespace: `fepfs.py mkworld --standalone --internet A.B.C.D` adds
  the INTERNET network, the host's address and its TCP services (TELNET,
  TCP-FTP, TIME) and a `Set Network Address CHAOS|1200,INTERNET|A.B.C.D`
  line to the Hello.boot.  The station address is the ID PROM's
  08:00:05:12:00:01 (`xl_iob`'s ETHERNET parameter), the same for every
  core.
- Fitting it (Oct 31 2026): the Ethernet logic (the bridge 1,232 ALUTs,
  the arbiter 372, the 82586 grown from 517 to 1,817) took the design from
  79% to 86% of the ALMs, and the standard fit's router, five minutes
  before, ran for four hours in the same hot region (X22-32, Y35-45: the
  processor's interconnect, 65% peak before, 84% after) and was killed.
  A fast fit fails to route the pre-Ethernet RTL too, so that was never a
  diagnostic.  Seed 2 routed the same RTL in 32 minutes (84% ALMs, 0.032
  ns setup slack).  Since then the 82586 forms every descriptor address
  with one adder (1,374 ALUTs) and the debug line is a debug build's
  (`XL_DEBUG`).  A build past an hour gets killed; a LogicLock region
  reserving the processor's area is the next lever if seeds stop working.
- On the MiSTer (seed-2 build, Main_MiSTer of Oct 2025 with the patch,
  the official binary kept as `/media/fat/MiSTer.orig-20261031`, started
  by hand with its output in `/tmp/mister.log`; a 240,000-block disk from
  `mkworld --standalone --internet 192.168.50.92`, eth0 on the LAN at
  1 Gb/s): Main opens eth0 at the core start and attaches its filter on
  08:00:05:12:00:01 once the core publishes the MAC (80 s later, the
  mailbox comes up with the core); Genera boots, Hello.boot's `Set
  Network Address` gives it INTERNET|192.168.50.92, and with nothing else
  done it answers ARP and echoes pings from the Mac: `tools/mister/
  mailbox.py` (run on the MiSTer) reads the mailbox from `/dev/mem` and
  decodes the frames left in the rings, which showed the Mac's requests
  in the receive ring and Genera's replies in the transmit ring, 94 bytes
  for 98-byte requests.  `xl_iob` had left the chip's `tx_crcgen` output
  unconnected, so the bridge took each frame as carrying an FCS and cut
  four bytes (the unit bench wires the chip to the bridge directly and
  could not see it; `verilator -Wwarn-UNDRIVEN` on `xl_machine` does).
- With the wire (build 36: seed 2, 82% ALMs, 0.434 ns slack, the router
  20 minutes): Genera answers the Mac's ping 39 s after `Start`, before
  its herald is up (5 of 5, 7-87 ms round trip; replies 98 bytes); its
  FTP server takes the Mac's connection and answers "421 FTP permission
  denied to INTERNET|192.168.50.80" (the Mac is no namespace host) and
  logs the broken connection; port 23 is refused because Genera 8.3 has
  no telnet server (`sys.sct` defines the login protocols for the
  client only), the UDP TIME port doesn't answer.  Seeds of the same
  code: 1 ran past the hour twice, 2 routed twice (0.032 and 0.434 ns),
  4 and 5 (the Mac's CrossOver Quartus, the same 17.0.2 build 602,
  `build-mac.sh`) gave up on congestion in three minutes at 73-74%
  peak, the design's margin being what it is.  The site setup and Save
  World on the network disk (44,564 blocks in six minutes again) gave
  the network master image; cold-booted from the FEP with Hello and
  Boot it answers ping 9 s after Boot, without a login.  The patched main
  program is `/media/fat/MiSTer_xl1200` and MiSTer.ini's `[XL1200]`
  section says `main=MiSTer_xl1200`: at a core's start Main resolves the
  section's `main` under /media/fat and restarts itself with that binary
  if it isn't the one running (`user_io.cpp`, as the DVD and Falcon
  cores' sections do), so the official `/media/fat/MiSTer` serves every
  other core.  (Swapping the binaries under a running patched Main and
  reloading rebooted the board once; from the menu the switch is clean.)
  The section also carries direct_video 0 while the core is tested from
  the Mac.

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
  block is three 512-byte sectors of a SCSI2SD-layout image. A read asks
  the main program for ten blocks (30 sectors) at a time into a 16 KB
  staging buffer and keeps that window, so the following reads of a
  sequential transfer (Load World, paging in a run of pages) are served
  from it; writes are grouped the same way, ten blocks a request. (Before
  Nov 2 2026 every block was its own round trip to the main program.)
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
`LOCKSTEP_SNAPSHOT=FILE` starts both from an xlemu snapshot instead (`-W`;
the disk argument a copy of `FILE.disk`; steps and typing counted from it),
and `FREE=1` then runs the RTL alone, for what it does with the state on its
own screen. Starting inside Genera found the bench behind the speed work:
the transfer now fills the RTL's stack cache (128 words by address bits 6:0)
from the model's memory, the comparison takes a word in the stack cache
window from the cache (the RTL writes the window back only when it moves;
the lower bound is 0 until Genera sets it, so runs from reset never saw
this), and the lockstep instruction count is 34 bits (the microsecond clock
is a quarter of it, and a snapshot is past 2^32). It still stops at the
first low-priority sequence break, which the model takes an instruction
before the RTL (docs/TODO.md).
`obj_free/Vxl_machine` runs it as on the
MiSTer (microseconds of the 50 MHz clock, SCSI commands running while the FEP
polls, memory cleared from junk, the dot clock running) and saves the screen.
It types TEXT from a given second (`|` Return, `~` a 10 s wait) and
profiles cycles by state (`PROFILE=1`, from an instruction count or
`PROFILE_FROM=typed`, the last key). At about 50 wall seconds per
simulated second (one thread; `--threads` makes it several times slower)
a Genera boot plus one Gabriel benchmark is a 3-4 hour run on the Ubuntu
server: `Hello|Load World FEP7:>Genera-8-3.ilod|~~Start|` and twelve
`~`, then `Login Lisp-Machine|~`, the load of the benchmarks' ibin and
`~~~`, then `(gabriel::run-one 'gabriel::boyer)|`; Genera's Listener is
up by 150 s of simulated time (Oct 2026).

## VMEbus and the color screen (Univision UDC-3400)

On the MiSTer (Nov 2 2026, seed 9 of the 16 MW tree, build 41 candidate): the
incremental Color world boots with "16.0M words Physical memory" in the
herald; after the sync format and `color::make-mister-color-screen` are
defined at the Listener and the screen made, the picture switches to the
color board (Display Auto) and a `tv:lisp-listener` made with `:superior`
the color screen draws there: white frame, yellow cursor, the label, exactly
as the bench's frame capture predicted. The B&W console stays underneath
(Display Console shows it).

Real color, without writing code: `Load System Color-Demo` (sys:color;demo;,
about four minutes on the core), then a window on the color screen and the
demo's patterns into it: `(setq w (tv:make-window 'tv:window :superior cs
:expose-p t :left 0 :top 0 :width 1152 :height 880))`,
`(color::full-field-color-bars w)`, `(color::test-colors w)` (the chip chart
with the six primaries, the ramps and the gray scale), `(color::smpte-color-bars w)`;
`(color:demo)` is the menu-driven version. A screen object is not a drawing
stream: `graphics:draw-rectangle` with `:stream cs` errors in
GRAPHICS::WITH-NEW-STREAM-TRANSFORM; draw into a window. `(send cs
:set-video-on nil)` turns the board's video off (Display Auto shows the
console again), `(send cs :set-video-on t)` back.

The XL1200 has no color output of its own; the color option Symbolics sold
for the XL400 was a third-party VMEbus board, the Univision UDC-3400, and
Genera 8.3's driver for it is in source on the CD (`sys.sct/color/univision.lisp`,
`univision-82786.lisp`, `vme-color.lisp`, `imach-common-color.lisp`) and
loaded into every Ivory world's Color system. The core puts one of those
boards on the Merlin-II's VMEbus (`rtl/xl/xl_vme.sv`, `xl_udc3400.sv`) and
shows its picture on the console's raster (the OSD's Display option; the
FrameThrower's driver is binary only, with a 1.9 MB microcode load, so it
was never an option).

How Genera reaches the bus (`i-sys/vme-defs.lisp`, `vme-bus.lisp`,
`sys/istack.lisp`):

- The direct window: a physical address with bits 31:30 set is VME word
  address A29:2 in bits 27:0; A31:30 come from the direct access register at
  0x88000040 (the Lisp keeps that and the VIC068's request level and release
  mode per process, rewritten at every stack-group switch). Every transfer
  is 32 bits; bits 29:28 pick a "shuffle" of the data: 0 as is, 1 bytes
  reversed, 2 nibbles, 3 bits. Lisp arrays are little-endian (element 0 in
  the low bits) and VME bytes big-endian, so an 8-bit raster is a bus array
  with the byte shuffle and a 1-bit one with the bit shuffle.
- Polled access (`sys:bus-read`, `bus-write`), for other sizes and for
  probing: data in the register at 0x88000080 (read or written through the
  shuffle in bits 29:28), the size in bits 15:14 of 0x88000140 (0 = 4
  bytes), the VME byte address written to 0x88000100 for a read or
  0x880000C0 for a write; the VIC068's bus error status register (word
  0x8800022E) then says whether anything answered (the Lisp clears it
  first, tests 0x6F after). A 16-bit or 8-bit value sits in the lanes of
  its offset (lane 0 is D31:24); the Lisp shifts it there and back.
- The slave buffer (0x80000000) and the window with nothing in it are bus
  errors (nothing is there; the interface's other registers and the VIC068's
  read back as written, which the FEP's boot and Genera's VME initialization
  expect).

The board, at VME 0x90000000, 16 MB: four control words (status with the
board ID 0xC000 in bits 31:16, bit 9 the sticky vertical blanking flag
cleared by writing 1, bit 5 video enable, bits 1-2 interrupts; vector,
control and plane mask kept), three Bt458 RAMDACs at +0x100, +0x110, +0x120
(address, palette data, control, overlay data; a byte each), the Intel
82786's registers at +0x200 (memory, except that the status register at
0x226 always shows the poll bit), overlay planes at +0x100000 and +0x140000
(a bit a pixel, 256 bytes a line), the 82786's display list at +0x180000
and the frame buffer at +0x800000 (a byte a pixel, 2048 a line, 1024
lines). All but the registers is DDR3 (two VME words a DDR word, 16 MB at
0x34000000, cleared at power-up with the rest). A byte-wide register takes
D7:0 of whatever transfer reaches it: lane 3 of a longword, the odd lane of
a 16-bit cycle (the driver writes the RAMDACs both ways: `%memory-write`
through the window and `bus-write :byte-size 2` in the commented-out
Univision console of `i-sys/console.lisp`); it answers on D7:0 with the
other lanes floating high, which is how `ramdac-type` tells a Bt458 (the
address register reading 0xF01 after four palette reads) from a Bt457.

The 82786 graphics coprocessor isn't there. Its driver flavor has a
settable `remote-drawing-enabled`; with it off every drawing method falls
back to drawing into the bus arrays, the init program it writes is never
waited for, and the interrupts (which only restart it) never come. The
display processor's pan, zoom and wraparound live in its window descriptor
in the display list, which the core doesn't read: the picture is always
line 0, pixel 0 of the frame buffer, through the green Bt458's palette (the
one the driver loads with the colors in 8-bit mode; red and blue get zeros)
with the overlay planes as its command register enables them (bit 6
palette enable, bits 1:0 the overlays; overlay colors from its overlay
registers). The 1152 x 880 raster comes from a sync format the init file
defines (`tools/genera/mister-color.lisp`): the driver hard-codes 1280 x
1024 only in pan wraparound. Each line is fetched into a line buffer (the
pixels in 8-pixel DDR beats, bursts of up to 32; then the two overlays)
while the line before shows, the fetch of the next line started at the
first dot of each; the board's DDR master goes first in the arbiter chain
(`arb_hi`: board, then `arb_lo`: memory, network) so a fetch never waits on
a cache miss, and the processor's bus accesses to the board slot in between
the bursts.

The Color system finds the board itself: `find-univision-controllers`
(`:finder` in `color/support/imach-parts.lisp`) polls a 32-bit read at
0x00000000, 0x01000000, ... 0xFF000000, catching the bus errors, and
defines a controller wherever bits 31:16 read 0xC000. The cache of found
controllers is cleared before a cold boot, so a saved world probes again.
Function-X moves the mouse between the screens (the Color System manual,
"Additional Color System Features").

Display is Console or Color since Nov 2 2026 (status bit 12, so a saved
Console or Color keeps its meaning and a saved Auto reads as Console). Auto,
which followed the board's video-enable bit, switched the picture to an
empty color screen as soon as one was made; the user dropped it. Pause shows
the other screen until Display is next changed: hps_io turns the Pause
key's byte sequence into one press event, E0 77, with no release
(`sys/hps_io.sv`), which the keyboard map doesn't use. The text above that
says Auto describes the core before then.

## Debug line

A debug build (`XL_DEBUG` in XL1200.qsf; the release build leaves it out,
a few hundred ALUTs) has an OSD "Debug line" that shows eight words in hex
across the top of the picture and sends them to the UART (`/dev/ttyS1` on
the MiSTer, 115200 8N1) twice a second while the option is on (bit 7 of
the first byte of `config/XL1200.CFG`, so a test can set it before a
start and read `stty -F /dev/ttyS1 115200 raw; cat /dev/ttyS1` over ssh;
`xl_machine`):

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

### Where the logic goes, and what was trimmed (Nov 2 2026)

The fitter's entity table for seed 9 (34,690 ALMs): the Ivory processor
16,844; the framework about 6,400 (scaler 2,046, audio 876, the two OSDs,
one per output path, 1,089, HPS I/O 525); the I/O board 2,734 (SCSI 916,
82586 819, video 323, console 285); FPA 2,495; MMU 1,704 (the chip's
16-entry map cache, in registers); instruction cache 682; color board 608;
Ethernet bridge 708. Nothing is there for the model or the benches: the
lockstep paths hang off the `LOCKSTEP` parameter, 0 in the build, and the
instruction counter and halt code only feed the debug words of `XL_DEBUG`.

Measured by synthesis alone (`quartus_map`, five minutes, "Implemented N
logic cells", against 68,536 for commit bf411b0), three changes with no
effect on behavior went in:

- FPA: one 64-bit right shifter and sticky mask serve both the add
  alignment and the integer conversions (different states); with the MMU's
  one set of 16 comparators and one encoder for the request and the
  load/invalidate lookups (a request waits while those are pending):
  223 logic cells.
- The scandoubler tied off in `XL1200.sv` (and Hq2x with it): 818 logic
  cells and 144 RAM segments (58 M10K, a tenth of the device's). The
  console's raster is 1152x880 progressive at 54.35 kHz lines; doubling it
  on `forced_scandoubler=1` gave 109 kHz that no display takes, so the
  doubler had no working mode. HDMI is unaffected (the scaler always took
  the native raster when the doubler was off, the default).

Added at the same time, for the color board's sake: the OSD's gamma through
the framework's `gamma_fast` (three tables, one lookup a pixel, instantiated
in `XL1200.sv` between the pixels and the mixer). The mixer's own
`gamma_corr` reads one table four times a pixel on a video clock four times
the pixel rate, which an 80 MHz dot clock cannot give, which is why the core
had no gamma before. Three M10K and a few dozen ALMs. All of it together,
by synthesis: 67,537 logic cells and 1,867 RAM segments, down 999 and 120.

Measured and kept out, the user's choice: `MISTER_DOWNSCALE_NN` with
`MISTER_DISABLE_ADAPTIVE` would save 470 logic cells and 40 RAM segments
but drop the HDMI scaler's adaptive filter and polyphase downscaling.
Left for later, each needing an extra cycle or a mux in a critical path:
the processor's four other barrel shifters (two in `ash`, the bignum shift,
the ALU's rotate) against the shared rotate unit, roughly 400 ALMs.

- Screenshots with direct video on: MiSTer's own `screenshot` command grabs
  the scaler's frame buffer, which with direct video is a low-resolution
  shadow of the picture, so the tests used to turn direct video off in the
  `[XL1200]` section of MiSTer.ini. The RetroTink 4K (firmware 1.99.9 and
  later) captures its input to a PNG on its SD card: AUX 5 on the remote
  asks "Capture now? [Cancel] [OK]" in its OSD. `tools/mister/rt4k.py
  capture OUT.png` does the whole round through the DonutShop bridge's
  WebSocket (ws://donutshop.local:81, the RetroTink's serial bytes as binary
  messages: `remote aux5`, `remote right`, `remote ok`, `ls screenshots`
  until the file stops growing, `get -- screenshots/NAME` as RTL1 frames
  with the device's SHA-256, `rm`); 84 s for the 6 MB of a 1920 x 1080
  capture at 2 Mbaud. The replies arrive prefixed with the port they came
  in on (`[COM] `). The web client in the DonutShop page is the protocol
  reference (its sections 3.2 and 3.3). At 84 s a capture it is for checking
  the direct-video output itself; ordinary tests keep using MiSTer's
  screenshots with `direct_video=0` in the `[XL1200]` section for the test
  and removed after.

- `make lint` (Nov 2 2026): Verilator with its full warning set over XL1200.sv
  and rtl/, the framework parsed for the interfaces the top level instantiates
  and every diagnostic from sys/ off (lint/exclusions.vlt; sys/ is never linted
  or formatted). Waived with reasons: the SCSI engine's blocking temporaries
  (BLKSEQ), registers written from two always_ff blocks on the one clock
  (MULTIDRIVEN), unused signals and parameters (to prune), and the framework
  ports the top level leaves unconnected, each by name. Clean at that date;
  it would have caught a register used before its declaration in XL1200.sv
  that a Quartus run would have found an hour later.
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
- Register arrays into RAM, where it pays (Nov 1 2026): the DUSCC's 64
  registers were 512 flops and a 64-way mux because the reset loop cleared
  them; without the reset (an `initial` block for the simulator and the
  power-up contents; the FEP programs every register it uses) and with the
  read landing in `duscc_q` a cycle later, taken into the polled latch in
  I_ACK, Quartus infers a RAM. The other two small arrays stay in flops:
  the processor's whole-word internal registers (`irw`, 16 live of 32) are
  read by name all over the pipeline (binding stack pointer and limit,
  control stack limits, catch-block list, event count), so only the
  %read-internal-register mux could move, against keeping a RAM copy
  coherent with ten named write sites; the WD33C93's 32 bytes are read by
  name throughout the SCSI engine for 256 flops in all. Checked in the
  free-running simulation (FEP boot, Hello and Boot through the DUSCC's
  receive path, Genera to its herald). Build 39 (seed 3): 33,982 ALMs
  (81%) and 27,176 registers against build 36's 34,378 and 27,805, the
  DUSCC a 64 x 8 block RAM, every timing corner met (setup 0.517 ns, hold
  0.252 ns); seed 2, which had routed build 36, gave up on congestion in
  22 minutes. The placement lottery doesn't care about 1%.
- Build 40 (Nov 2 2026, `releases/XL1200_20261102.rbf`): the Ivory's
  fast-aref-1/fast-aset-1 following a physical-address array base
  (docs/ivory.md) and the framework's Y/C encoder compiled out, nothing
  else; the color board is not in it. Seed 2: 33,919 ALMs (81%), setup slack
  1.422 ns on the core clock, 0.036 ns in the HDMI PLL domain, hold 0.25 ns;
  seed 4 also met timing (0.146 / 0.264 ns); seed 3 passed the hour and was
  killed; the same seed 2 with the encoder still in had fitted with a 0.115
  ns miss in the HDMI domain. Both good seeds booted the full world on the
  MiSTer (FEP, Hello, Boot, login, evaluation). The color build of the same
  tree fits at 82-83% but its first two seeds (2, 3) missed the core clock by
  0.7-1.0 ns on the Ivory's own paths (ooff/t0/st into p_w and sp, TNS -41
  ns): the lottery at that density, not a new path; more seeds running.
- Build 41 (Nov 2 2026, `releases/XL1200_20261102.rbf`, replacing build 40,
  which was never published): the 16 MW of memory boards, the Univision
  color board, the three CLIM fixes (instance-variable index and
  exceptions, the transport trap on an instruction fetch), ten SCSI blocks
  a request, the shared FPA shifter and MMU comparators, no scandoubler,
  OSD gamma. Seed 5 (Mac): 34,199 ALMs (82%), block memory 56% (61%
  before), setup slack +0.383 ns core, +0.298 HPS, +0.406 HDMI, +2.509
  video; seed 1 also met timing (+0.145 core); seeds 2 and 4 could not
  fit. On the MiSTer: the Color world boots, `(time (sct:load-system
  "CLIM" :query nil))` 367.3 s with 1.4 s waiting for pages (seed 19 of
  the previous commit: 364.5 s), floating point through the FPA correct,
  the color board draws, `(fib 30)` 2.80 s as before.
- Build 42 (Nov 2 2026, `releases/XL1200_20261102.rbf`, replacing build 41):
  the logic-variable instructions (Joshua and Jericho) and the start from
  MiSTer's menu (no DDR3 command while RESET is up). Seed 9 of 70fd834:
  34,613 ALMs (83%), block memory 56%, setup slack +0.850 ns core, +0.762
  video, +1.816 HPS, +0.253 HDMI, hold +0.251; seeds 2 and 7 could not meet
  timing or fit, 1, 8 and 10 were stopped once 9 passed. On the MiSTer:
  three starts from the menu with `boot0.vhd` and one through an MGL reach
  the FEP prompt, as does a start from the running core; the fat world's
  second version boots with Joshua and Jericho, and the grandparent example
  and Tweety answer.
- A DDR3 burst cut short (e.g. by resetting the machine when a file download
  starts) wedges the HPS SDRAM port: DDRAM_BUSY stays high and Main_MiSTer
  hangs on ioctl_wait (once the whole board reset). Put MiSTer's
  `f2sdram_safe_terminator` (sys/) on any DDR3 master that can be reset.
- The terminator isn't enough on its own (Nov 2 2026): while RESET is up it
  forwards nothing but the transaction it is finishing, yet still passes the
  port's waitrequest back, so a command started then looks taken and is
  never answered. Started from MiSTer's menu, the official Main releases
  the core's reset, then restarts as MiSTer_xl1200 (MiSTer.ini's `main=`)
  and raises RESET again with the machine running; the memory controller,
  which RESET doesn't stop, finished the processor's last access with a
  read in that window, the arbiter (which hands read data back in the
  order it took the commands) gave every later read's data to the master
  before it, and the memory controller waited in `M_BUF_WAIT` for good: a
  black screen, the debug line frozen at PC FFFE006E in the boot PROM. Every
  start from the menu did it (build 41 too); a start from another XL1200
  core has no second RESET, and with `main=` commented out the menu start
  worked. `xl_machine` now owns the port: the terminator behind a gate that
  starts no command while RESET is up or for 1024 cycles after, letting a
  waiting command or the rest of a write burst through. Four starts from
  the menu on the debug build reached the FEP prompt. `tb_free`'s
  `MENU=a,b,c,d` (and `MENU_MOUNT=early`) raise RESET in that pattern; the
  bench boots either way, its model port answering differently, so the
  hardware was the test.
- F options with a load address (`FC1,EXT,Title,24200000`) make Main_MiSTer
  write the file straight into DDR3 (fast) and remember it; the core sees only
  ioctl_download, with the size in ioctl_addr. Streaming through ioctl_wr ran
  about 0.5 MB/s.
- `video_mixer` with `GAMMA(1)` latches pixels and syncs on rising edges of
  `ce_pix` (`gamma_corr`), so with the pixel clock as `CLK_VIDEO` and `ce_pix`
  held at 1 its outputs freeze after the first cycle: no picture on HDMI or
  direct video, no screenshots. Gamma needs a video clock of four times the
  pixel rate; this core uses `GAMMA(0)`.
- Never start a second copy of the main program on a running board: it
  unlinks and recreates `/dev/MiSTer_cmd`, and the one still running keeps
  reading the old, now nameless pipe, so every later write to the new pipe
  blocks. The way back without a reboot is the running program's own
  descriptor: `readlink /proc/PID/fd/*` finds the fd of `/dev/MiSTer_cmd
  (deleted)`, and `echo load_core ... > /proc/PID/fd/N` reaches it; the
  restarted program then makes a fresh pipe.
- Bring-up without a picture: the OSD's "Debug line" also sends the debug
  words to the core's UART, which is the ARM's `/dev/ttyS1`
  (`stty -F /dev/ttyS1 115200 raw -echo; cat /dev/ttyS1` on the MiSTer).
  Screenshots need `screenshots/<core>/` to exist.
- Timing: the core's clocks (50 MHz processor and boards, 80 MHz dot
  clock) have met timing in every fitted build; what fails first, from
  about 80% logic use, is the framework's HDMI scaler (`ascal`, register
  to register inside it on the HDMI pixel clock, by 0.3-0.7 ns): the
  fitter spreads it out when the chip is congested, so taking logic out of
  the core is what gives it room; seeds aren't tried. `quartus_sta -t`
  with `report_timing -to_clock [get_clocks {*pll_hdmi*}]` lists the paths
  (the default report only has the summary).
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
