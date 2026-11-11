# Symbolics XL1200 for MiSTer

**This core was created with AI**

A Symbolics XL1200 Lisp machine: the Ivory processor, the Merlin-II and I/O
boards and the floating-point accelerator. It boots the XL1200's front-end
processor (FEP) from a SCSI disk image and runs Genera 8.3 on the 1152 × 880
black-and-white console, with keyboard, mouse, Ethernet and a CD-ROM drive.

Work in progress: [docs/TODO.md](docs/TODO.md).

## What you need

- The core and the main program from [releases](releases/)
- The prebuilt disk, `boot0.vhd.7z` (Genera 8.3 with its applications):
  search [archive.org](https://archive.org) for its SHA-1,
  `53d11962da7163762fda8f6f0d9cd43a23c05a4c`. Or a disk you build
  ([Building a disk](#building-a-disk))
- A keyboard and mouse
- For direct video, a display that takes 1152 × 880 at 60 Hz (54 kHz)

## Setup

1. Copy the newest `XL1200_*.rbf` from [releases](releases/) to `_Computer`
   on the SD card.
2. Copy [releases/MiSTer_xl1200](releases/MiSTer_xl1200) to the root of the
   SD card, next to `MiSTer`. It is MiSTer's main program with the core's
   Ethernet bridge and its clock; without it the core runs, but Genera has
   no network and its clock is off by your time zone.
3. Add to `MiSTer.ini`:

   ```
   [XL1200]
   main=MiSTer_xl1200
   ```

4. Unpack `boot0.vhd` into `games/XL1200/`; the core mounts it when it
   starts.
5. Start XL1200 from the Computer menu.
6. At the `FEP Command:` prompt type `Hello`, then `Boot`. `Boot` loads the
   disk's default world, Genera 8.3 with its applications.
7. In Genera, `Login Lisp-Machine`.

The Symbolics keys (Select, Function, Abort, Help, ...) are on the PC's
function keys: [docs/keyboard.md](docs/keyboard.md).

## The prebuilt disk

What the default world holds, and how to start each application:
[docs/applications.md](docs/applications.md).

The disk's other worlds load at the FEP prompt after `Hello`, in place of
`Boot`:

- The Genera 8.1.1 animation world (S-Paint, S-Geometry, S-Dynamics and the
  other S-Graphics programs), with the color screen made at boot and Craig
  Reynolds' Boids: `Load World FEP7:>animation-mac-6-2-color.ilod`, then
  `Start`. For the flock, Select G (S-Geometry), then type `(boids:demo)`;
  any key stops it
- Flavors Statice: `Load World FEP7:>Genera-8-3-flavors-statice.ilod`, then
  `Start`

Genera's network address on this disk is 192.168.50.92;
[Network](#network) has how to change it.

Type `Halt Machine` in Genera before you switch cores or copy the image off
the card. It leaves you at the FEP's prompt: `Continue` goes back to Genera,
`Hello` and `Boot` start it again.

## CD-ROM

The OSD's `SCSI CD-ROM 2` takes a disc image (`.iso`), and Genera reads the
disc as `CDROM2:`. With the Genera 8.3 CD in it:

- `Show Directory CDROM2:>*.*`
- `Copy File CDROM2:>WORLDS>GENERA_8_3.ILOD FEP7:>Genera-8-3.ilod`
- in the FEP-Tape activity, `Read Image File CDROM2:>DISTRIBUTION>BASIC_WORLD.TAPE`

## Building a disk

You need a Genera 8.3 world (`GENERA_8_3.ILOD` from the Genera 8.3 CD) and an
XL1200 FEP disk image, a raw SCSI2SD dump with 1280-byte blocks
([docs/NOTES.md](docs/NOTES.md#fep-file-system-layout)).

1. `python3 tools/fepfs.py mkworld FEPDISK.dd GENERA_8_3.ILOD boot0.vhd --blocks 240000 --paging 120000 --standalone`
   (add `--internet A.B.C.D` for the [network](#network)).
2. Copy it to `games/XL1200/boot0.vhd` and start the core. At the FEP prompt
   type `Hello`, `Load World FEP7:>Genera-8-3.ilod`, `Start`.
3. Once, in Genera: `Login Lisp-Machine`, `Create Directory XL1200:>sys>`,
   `Create Directory XL1200:>sys>site>`,
   `Copy File FEP7:>sys-translations.text XL1200:>sys>site>sys.translations`.
4. Save it: `Save World FEP7:>Genera-8-3-site.ilod`; Y to the herald and the
   label, Yes to the boot file, Return for its name, Super-C (Windows-C) to
   write it.
5. From then on type `Hello` and `Boot` at the FEP.

### The full disk

The MacIvory factory disk image that circulates holds a Genera file system
with Joshua, Concordia, Statice, CLIM, the documentation and fonts, the
animation world and the Y2K patches. The disk tool reads it and puts all of
it on an XL1200 disk, the Y2K patch loaded into both worlds, so the OSD's
Clock can be "Today":
[docs/NOTES.md](docs/NOTES.md#the-macivory-disk-and-the-full-image).
`Hello` and `Boot` start Genera 8.3; for the animation world type `Hello`,
`Load World FEP7:>animation-mac-6-2-y2k.ilod`, `Start`.

## Network

Genera 8.3 joins your LAN through the MiSTer at an address you give it. Other
machines can ping it and move files to and from it with FTP, and Genera's
Terminal program opens telnet sessions on your LAN or beyond it.

You need `MiSTer_xl1200` from [Setup](#setup) step 2, a free address on your
LAN (Genera 8.3 has no DHCP) and your router's address.

1. With a cable in the MiSTer, leave the OSD's Network option at `eth0`. Over
   WiFi, set it to `tap0` and add the [tap setup](docs/NOTES.md#wifi), with
   Genera's address in it, to the MiSTer's `user-startup.sh`.
2. Start Genera and `Login Lisp-Machine`.
3. `Edit File FEP7:>Hello.boot`.
4. Change the `Set Network Address` line to
   `Set Network Address CHAOS|1200,INTERNET|A.B.C.D;gateway=G.G.G.G`, with
   Genera's address and your router's (Insert types `|`).
5. Save with Control-X Control-S.
6. Select L, `Halt Machine`, `Yes`, then at the FEP's prompt type `Hello`
   and `Boot`.
7. From another machine, `ping A.B.C.D`.
8. Once, to stop the note "The namespace needs to be fixed" at boot:
   `Edit Namespace Object Host XL1200`, right-click the old `INTERNET`
   address, `Remove this field`, then type `Save Object` and `Y`.

For one start only, type the line from step 4 at the FEP after `Hello`. A
disk you build gets its address with `--internet A.B.C.D`.

Using it:

- FTP from another machine, in active mode, as `lisp-machine`:
  `curl -P - -u lisp-machine:x "ftp://A.B.C.D/%3Elispm%3Ebank.lisp" -o bank.lisp`
  fetches `>lispm>bank.lisp`, and
  `curl -P - -u lisp-machine:x -T hello.text "ftp://A.B.C.D/%3Elispm%3Ehello.text"`
  sends a file there.
- Telnet from Genera: Select T, type the host as `INTERNET|A.B.C.D`, answer
  N until it offers TELNET, then Y.

How it works, and the bridge in the main program
([tools/mister/Main_MiSTer-xl1200.patch](tools/mister/Main_MiSTer-xl1200.patch)
until it is upstream): [docs/NOTES.md](docs/NOTES.md#network).

## Gotchas

- **The core writes to the disk image, so keep the `.7z` (or another copy) to start over from.**
- Images must be SCSI2SD dumps: each 1280-byte block in 1536 bytes.
- Disc images must be `.iso`; `.cue`/`.bin` and `.chd` aren't read.
- With no disk mounted the machine halts; mounting one starts it.
- Genera 8.3 doesn't accept dates after 1999: leave Clock at "28 years back" unless the world has the Y2K patch.
- Save World shows "System Shutdown ..." with the clock stopped for several minutes; wait for "Saved to".
- To compile files, log in first.
- Log in at Genera's console before using FTP from another machine: a connection made earlier hangs, and file saves with it, until you press Function 0 S at the console.
- Genera 8.3 has no telnet server; other machines reach it by FTP.
- Every XL1200 core has the same Ethernet address, so one per LAN.

## Troubleshooting

- "Unable to get time from the network or the calendar clock": Clock to "28 years back".
- Genera's time is off by your time zone: `MiSTer_xl1200` from step 2 isn't running (`main=` in `MiSTer.ini`); MiSTer's own main program sends the clock as local time, and Genera reads it as GMT.
- Genera asks for the date right after the MiSTer starts: it booted before MiSTer had the time from the network; type the date, or start the core again.
- "This Lisp world has not been configured for use at the local site": the disk was built without `--standalone`.
- "Unable to change site to Standalone. The directory >sys does not exist": step 3 of [Building a disk](#building-a-disk) hasn't been done on this disk.
- A full GC freezes Genera: the paging file is smaller than physical memory; build the disk with `--blocks 240000`.
- No picture on direct video: the display has to take an 80 MHz, 54 kHz signal.
- Genera doesn't answer ping: `MiSTer_xl1200` and its `MiSTer.ini` entry, the Network option (`eth0` with a cable, `tap0` over WiFi), an address on your LAN (the prebuilt disk's is 192.168.50.92).
- A connection beyond your LAN fails just after Genera starts: try again in a minute.
- FTP connects but a transfer is refused: the client is in passive mode; use active mode.
- No FEP prompt: a debug build's Debug line shows where it stopped, [docs/NOTES.md](docs/NOTES.md#debug-line).

Building the core and running the tests: [docs/building.md](docs/building.md).
How the core works and what was found out about the machine:
[docs/NOTES.md](docs/NOTES.md).

## Credits

- [MiSTer-devel](https://github.com/MiSTer-devel): the MiSTer framework and
  main program, whose Ethernet bridges for the Sun and NeXT cores this one
  follows.
- The [SparcStation 20 core](https://github.com/MiSTer-devel/SunSparcStation20_MiSTer):
  the DDR arbiter and the Ethernet mailbox client, used under the GPL.
- Douglas Fields, [symbolics.lisp.engineer](https://symbolics.lisp.engineer)
  and [genera-patches](https://github.com/LispEngineer/genera-patches):
  the XL1201 patches with the Y2K fix, and the XL1201 timings and
  photographs the notes rely on.
- [Bitsavers](https://bitsavers.org): the Symbolics and chip documentation.
- Richard Gabriel's *Performance and Evaluation of Lisp Systems*: the
  benchmarks and the 3600 times.
- Symbolics: Genera and the Ivory, and the Genera 8.3 sources on the CD,
  the reference for how the boards behave.
