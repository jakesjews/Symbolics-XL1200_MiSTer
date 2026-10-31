#!/usr/bin/env python3
"""The Ethernet mailbox in the MiSTer's DDR3, read live.

Run it on the MiSTer:  ssh root@mister python3 - < tools/mister/mailbox.py

Prints the header words (the magic, the generation counter, the ring
pointers, the published MAC) and the Ethernet header of every frame left
in the transmit ring (8 slots, from Genera) and the receive ring (16
slots, from the LAN), with ARP and IP decoded. The pointers say whether
either side moves: TX_WPTR counts the frames the core transmitted,
TX_RPTR those Main sent on; RX_WPTR the frames Main offered, RX_RPTR
those the core took. docs/NOTES.md, Network.
"""
import mmap
import struct

BASE = 0x1FF00000
f = open("/dev/mem", "r+b")
m = mmap.mmap(f.fileno(), 0x10000, offset=BASE)

names = ["MAGIC", "GEN", "TX_WPTR", "TX_RPTR", "RX_WPTR", "RX_RPTR", "MAC"]
for i, n in enumerate(names):
    v = struct.unpack_from("<Q", m, i * 8)[0]
    extra = ""
    if n == "MAGIC":
        extra = repr(struct.pack(">Q", v).decode("ascii", "replace"))
    if n == "MAC":
        extra = "valid" if v >> 63 else "not valid"
        extra += " " + ":".join("%02x" % ((v >> s) & 0xff) for s in range(40, -1, -8))
    print("%-8s %016x  %s" % (n, v, extra))


def frame(base, slot, ring):
    off = base + slot * 2048
    h = struct.unpack_from("<Q", m, off)[0]
    ln = h & 0x7ff
    d = m[off + 8:off + 8 + min(ln, 64)]
    if ln < 14:
        print("%s slot %2d len %4d" % (ring, slot, ln))
        return
    et = (d[12] << 8) | d[13]
    extra = ""
    if et == 0x0806 and ln >= 42:
        extra = "ARP op=%d %d.%d.%d.%d -> %d.%d.%d.%d" % (
            (d[20] << 8) | d[21], d[28], d[29], d[30], d[31], d[38], d[39], d[40], d[41])
    elif et == 0x0800 and ln >= 34:
        extra = "IP proto=%d %d.%d.%d.%d -> %d.%d.%d.%d" % (
            d[23], d[26], d[27], d[28], d[29], d[30], d[31], d[32], d[33])
    elif et == 0x0804:
        extra = "Chaos"
    print("%s slot %2d len %4d dst %s src %s type %04x %s" % (
        ring, slot, ln, d[0:6].hex(":"), d[6:12].hex(":"), et, extra))


print("transmit ring (the core's frames; RX lengths include Main's 4-byte FCS, TX lengths don't)")
for s in range(8):
    frame(0x1000, s, "TX")
print("receive ring (the LAN's frames)")
for s in range(16):
    frame(0x5000, s, "RX")
