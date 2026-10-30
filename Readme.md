# Symbolics XL1200 for MiSTer

A Symbolics XL1200 Lisp machine: the Ivory processor with the machine's
Merlin-II and I/O boards and its floating-point accelerator. It boots the
XL1200's front-end processor (FEP) from a SCSI disk image, and from the FEP
it loads and starts Genera 8.3 on the 1152 × 880 black-and-white console,
with keyboard and mouse.

**Work in progress:** there is no network yet.

## What you need

- A disk image of an XL1200 FEP disk, as a raw dump of a SCSI2SD card set
  up for 1280-byte blocks
- For Genera, a Genera 8.3 world (`GENERA_8_3.ILOD` from the Genera 8.3 CD)
  on that disk: `tools/fepfs.py mkworld` copies it onto an image
  ([docs/NOTES.md](docs/NOTES.md#fep-file-system-layout))
- A keyboard and mouse
- For direct video, a display that takes 1152 × 880 at 60 Hz (54 kHz)

## Setup

1. Copy `XL1200_*.rbf` to `_Computer` on the SD card.
2. Copy the disk image to `games/XL1200/boot0.vhd`, or mount it from the OSD as SCSI disk 0.
3. Load the core; the FEP prompt appears after about ten seconds.
4. Type `Hello` and Return.
5. Type `Load World FEP7:>Genera-8-3.ilod` and Return (the name `tools/fepfs.py` gives the world).
6. Type `Start` and Return; Genera's Lisp Listener appears after about a minute and a half.

The Symbolics keys (Select, Function, Abort, Help, ...) are on the PC's
function keys: [docs/keyboard.md](docs/keyboard.md).

## Gotchas

- **The core writes to the disk image, so give it a copy.**
- Images must be SCSI2SD dumps: each 1280-byte block in 1536 bytes.
- With no disk mounted the machine halts; mounting one starts it.
- Genera 8.3 doesn't accept dates after 1999, so leave the OSD's Clock at "28 years back".

## Troubleshooting

- No FEP prompt: turn on Debug line in the OSD and read the words with
  [docs/NOTES.md](docs/NOTES.md#debug-line).
- "Unable to get time from the network or the calendar clock": set Clock to "28 years back".
- Genera asks for the date right after the MiSTer starts: MiSTer hadn't set its clock yet when the core loaded; type the date, or reload the core.
- No picture on direct video: the display has to take an 80 MHz, 54 kHz signal.

How the core is built and what has been found out about the machine:
[docs/NOTES.md](docs/NOTES.md).
