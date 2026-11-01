# Symbolics XL1200 for MiSTer

A Symbolics XL1200 Lisp machine: the Ivory processor, the Merlin-II and I/O
boards and the floating-point accelerator. It boots the XL1200's front-end
processor (FEP) from a SCSI disk image and runs Genera 8.3 on the 1152 × 880
black-and-white console, with keyboard, mouse and Ethernet.

Work in progress: [docs/TODO.md](docs/TODO.md).

## What you need

- A Genera 8.3 world (`GENERA_8_3.ILOD` from the Genera 8.3 CD)
- An XL1200 FEP disk image, a raw SCSI2SD dump with 1280-byte blocks (the
  disk tool builds a disk from one and the world:
  [docs/NOTES.md](docs/NOTES.md#fep-file-system-layout))
- A keyboard and mouse
- For direct video, a display that takes 1152 × 880 at 60 Hz (54 kHz)

## Setup

1. Copy the newest `XL1200_*.rbf` from [releases](releases/) to `_Computer` on
   the SD card.
2. Build the disk: `python3 tools/fepfs.py mkworld FEPDISK.dd GENERA_8_3.ILOD boot0.vhd --blocks 240000 --paging 120000 --standalone`
   (add `--internet A.B.C.D` for the [network](#network)).
3. Copy it to `games/XL1200/boot0.vhd`; the core mounts it when it starts.
4. Start XL1200 from the Computer menu. At the FEP prompt type `Hello`,
   `Load World FEP7:>Genera-8-3.ilod`, `Start`.
5. Once, in Genera: `Login Lisp-Machine`, `Create Directory XL1200:>sys>`,
   `Create Directory XL1200:>sys>site>`,
   `Copy File FEP7:>sys-translations.text XL1200:>sys>site>sys.translations`.
6. Save it: `Save World FEP7:>Genera-8-3-site.ilod`; Y to the herald and the
   label, Yes to the boot file, Return for its name, Super-C (Windows-C) to
   write it.
7. From then on type `Hello` and `Boot` at the FEP; Genera is up in seconds.

The Symbolics keys (Select, Function, Abort, Help, ...) are on the PC's
function keys: [docs/keyboard.md](docs/keyboard.md).

## Network

Genera's Ethernet goes out of the MiSTer's wired port; MiSTer's main program
carries the frames, as for the Sun and NeXT cores, so nothing runs by hand.
Build the disk with `--internet A.B.C.D` (a free address on your LAN); the
OSD's Network option picks the port or turns it off. Genera answers ping and
serves FTP (Genera 8.3 has no telnet server). Until the bridge is upstream,
copy [releases/MiSTer_xl1200](releases/MiSTer_xl1200), the main program built
with [tools/mister/Main_MiSTer-xl1200-enet.patch](tools/mister/Main_MiSTer-xl1200-enet.patch),
to the root of the SD card and add to `MiSTer.ini`:

```
[XL1200]
main=MiSTer_xl1200
```

WiFi can't carry it, and every XL1200 core has the same Ethernet address.

## The full disk

The MacIvory factory disk image that circulates holds a Genera file system
with Joshua, Concordia, Statice, CLIM, the documentation and fonts, the
animation world and the Y2K patches. The disk tool reads it and puts all of
it on an XL1200 disk, the Y2K patch loaded into both worlds, so the OSD's
Clock can be "Today":
[docs/NOTES.md](docs/NOTES.md#the-macivory-disk-and-the-full-image).
`Hello` and `Boot` start Genera 8.3; for the animation world type `Hello`,
`Load World FEP7:>animation-mac-6-2-y2k.ilod`, `Start`.

## Gotchas

- **The core writes to the disk image, so give it a copy.**
- Images must be SCSI2SD dumps: each 1280-byte block in 1536 bytes.
- With no disk mounted the machine halts; mounting one starts it.
- Genera 8.3 doesn't accept dates after 1999: leave Clock at "28 years back" unless the world has the Y2K patch.
- Save World shows "System Shutdown ..." with the clock stopped for several minutes; wait for "Saved to".
- To compile files, log in first.

## Troubleshooting

- "Unable to get time from the network or the calendar clock": Clock to "28 years back".
- Genera asks for the date right after the MiSTer starts: it loaded before MiSTer set its clock; type the date, or reload the core.
- "This Lisp world has not been configured for use at the local site": the disk was built without `--standalone`.
- "Unable to change site to Standalone. The directory >sys does not exist": step 5 hasn't been done on this disk.
- A full GC freezes Genera: the paging file is smaller than physical memory; build the disk with `--blocks 240000`.
- No picture on direct video: the display has to take an 80 MHz, 54 kHz signal.
- Genera doesn't answer ping: a cable in the MiSTer's port, the main program with the bridge, the disk built with `--internet`.
- No FEP prompt: a debug build's Debug line shows where it stopped, [docs/NOTES.md](docs/NOTES.md#debug-line).

How the core is built and what was found out about the machine:
[docs/NOTES.md](docs/NOTES.md).

## Credits

- [MiSTer-devel](https://github.com/MiSTer-devel): the MiSTer framework and
  main program, whose Ethernet bridges for the Sun and NeXT cores this one
  follows.
- The [SparcStation 20 core](https://github.com/MiSTer-devel/SunSparcStation20_MiSTer):
  the DDR arbiter and the Ethernet mailbox client, used under the GPL.
- Douglas Fields, [symbolics.lisp.engineer](https://symbolics.lisp.engineer)
  and [genera-patches](https://github.com/LispEngineer/genera-patches):
  the XL1201 patches with the Y2K fix, the FEP disk the template comes from,
  and the XL1201 timings and photographs the notes rely on.
- [loper-os](https://www.loper-os.org/?p=2943): the MacIvory factory disk
  image behind the full disk.
- [Bitsavers](https://bitsavers.org): the Symbolics and chip documentation.
- Richard Gabriel's *Performance and Evaluation of Lisp Systems*: the
  benchmarks and the 3600 times.
- Symbolics: Genera and the Ivory, and the Genera 8.3 sources on the CD,
  the reference for how the boards behave.
