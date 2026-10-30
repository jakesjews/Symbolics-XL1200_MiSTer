#!/usr/bin/env python3
"""Convert an X11 xwd dump (ZPixmap, 24/32 bpp TrueColor or 8-bit with colormap) to PNG."""
import struct, sys
from PIL import Image

def convert(src, dst):
    data = open(src, "rb").read()
    hdr = struct.unpack(">25I", data[:100])
    (header_size, version, pixmap_format, depth, width, height, xoffset,
     byte_order, bitmap_unit, bitmap_bit_order, bitmap_pad, bits_per_pixel,
     bytes_per_line, visual_class, red_mask, green_mask, blue_mask,
     bits_per_rgb, colormap_entries, ncolors, window_width, window_height,
     window_x, window_y, window_bdrwidth) = hdr
    off = header_size
    cmap = []
    for i in range(ncolors):
        pixel, r, g, b, flags, pad = struct.unpack(">IHHHBB", data[off + 12*i: off + 12*i + 12])
        cmap.append((pixel, r >> 8, g >> 8, b >> 8))
    off += 12 * ncolors
    pix = data[off: off + bytes_per_line * height]
    if bits_per_pixel == 32:
        mode = "BGRX" if byte_order == 0 else "XRGB"
        img = Image.frombuffer("RGB", (width, height), pix, "raw", mode, bytes_per_line, 1)
    elif bits_per_pixel == 8:
        img = Image.frombuffer("P", (width, height), pix, "raw", "P", bytes_per_line, 1)
        pal = [0] * 768
        for p, r, g, b in cmap:
            if p < 256:
                pal[3*p:3*p+3] = [r, g, b]
        img.putpalette(pal)
        img = img.convert("RGB")
    else:
        raise SystemExit("unsupported bits_per_pixel %d" % bits_per_pixel)
    img.save(dst)

if __name__ == "__main__":
    convert(sys.argv[1], sys.argv[2])
