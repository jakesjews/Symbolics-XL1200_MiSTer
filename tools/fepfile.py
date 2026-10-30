"""Read Symbolics FEPFS files (1280-byte blocks = 256 40-bit Ivory words).

Each block is 64 groups of 20 bytes: 4 tag bytes (cdr<7:6>, type<5:0>) followed by
four little-endian 32-bit data words.
"""
import struct, sys

def words_from_bytes(data):
    out = []
    n = len(data) // 20
    for q in range(n):
        g = data[q*20:(q+1)*20]
        d = struct.unpack_from('<4I', g, 4)
        for k in range(4):
            out.append((g[k], d[k]))   # (tag byte, data)
    return out

def read_fep_file(path):
    return words_from_bytes(open(path, 'rb').read())

def fmt(w):
    tag, d = w
    return f"{tag>>6}:{tag&0x3f:02o} {d:08x}"

if __name__ == '__main__':
    ws = read_fep_file(sys.argv[1])
    start = int(sys.argv[2], 0) if len(sys.argv) > 2 else 0
    cnt = int(sys.argv[3], 0) if len(sys.argv) > 3 else 64
    for i in range(start, min(start+cnt, len(ws))):
        print(f"{i:6d} {fmt(ws[i])}")
