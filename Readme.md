# Symbolics XL1200 for MiSTer

A Symbolics XL1200 Lisp machine: the Ivory processor with the machine's
Merlin-II and I/O boards. It boots the XL1200's front-end processor (FEP)
software from a SCSI disk image and runs FEP commands on the 1152 × 880
black-and-white console.

**Work in progress:** the FEP runs; Genera doesn't boot yet.

## What you need

- A disk image of an XL1200 FEP disk, as a raw dump of a SCSI2SD card set
  up for 1280-byte blocks
- A keyboard
- For direct video, a display that takes 1152 × 880 at 60 Hz (54 kHz)

## Setup

1. Copy `XL1200_*.rbf` to `_Computer` on the SD card.
2. Copy the disk image to `games/XL1200/boot0.vhd`, or mount it from the OSD as SCSI disk 0.
3. Load the core; the FEP prompt appears after about ten seconds.
4. Type `Hello` and Return.

The Symbolics keys (Select, Function, Abort, Help, ...) are on the PC's
function keys: [docs/keyboard.md](docs/keyboard.md).

## Gotchas

- **The core writes to the disk image, so give it a copy.**
- Images must be SCSI2SD dumps: each 1280-byte block in 1536 bytes.
- With no disk mounted the machine halts; mounting one starts it.

## Troubleshooting

- No FEP prompt: turn on Debug line in the OSD and read the words with
  [docs/NOTES.md](docs/NOTES.md#debug-line).
- No picture on direct video: the display has to take an 80 MHz, 54 kHz signal.

How the core is built and what has been found out about the machine:
[docs/NOTES.md](docs/NOTES.md).
