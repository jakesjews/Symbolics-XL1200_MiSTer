"""Load an ILOD world image (see prepare_symbolics_media.py) and look up symbols.

ILOD: 5 bytes per word (data LE32 + cdr/tag byte); magic word, then segments of
(vma, length, words...) terminated by a zero vma and length.
"""
import sys
import numpy as np


class World:
    def __init__(self, path):
        raw = np.fromfile(path, dtype=np.uint8)
        n = len(raw) // 5
        r = raw[: n * 5].reshape(n, 5)
        data = r[:, 0:4].copy().view('<u4').reshape(n)
        tagb = r[:, 4]
        assert data[0] == 0x444F4C49
        self.segs = []   # (vma, data array, tag array)
        i = 1
        while i + 1 < n:
            vma, ln = int(data[i]), int(data[i + 1])
            if vma == 0 and ln == 0:
                break
            self.segs.append((vma, data[i + 2:i + 2 + ln], tagb[i + 2:i + 2 + ln]))
            i += 2 + ln
        self.segs.sort(key=lambda s: s[0])

    def word(self, a):
        for vma, d, t in self.segs:
            if vma <= a < vma + len(d):
                return int(t[a - vma]), int(d[a - vma])
        return None

    def find_string(self, s):
        """Addresses of string headers whose contents are exactly s."""
        b = s.encode('latin-1')
        out = []
        for vma, d, t in self.segs:
            bs = d.tobytes()
            start = 0
            while True:
                k = bs.find(b, start)
                if k < 0:
                    break
                start = k + 1
                if k % 4:
                    continue
                w = k // 4
                if w == 0:
                    continue
                ht, hd = int(t[w - 1]) & 0x3f, int(d[w - 1])
                if ht == 3 and (hd & 0x7fff) == len(b) and not (hd >> 23) & 1:
                    out.append(vma + w - 1)
        return out

    def find_refs(self, addr, tag=None):
        out = []
        for vma, d, t in self.segs:
            idx = np.nonzero(d == addr)[0]
            for k in idx:
                tt = int(t[k]) & 0x3f
                if tag is None or tt == tag:
                    out.append((vma + int(k), tt))
        return out

    def symbols(self, name):
        res = []
        for sa in self.find_string(name):
            for a, tt in self.find_refs(sa, 2):   # header-p pointing at the name
                res.append(a)
        return res


if __name__ == '__main__':
    w = World(sys.argv[1])
    for name in sys.argv[2:]:
        for a in w.symbols(name):
            cells = [w.word(a + k) for k in range(5)]
            print(name, hex(a), ' '.join(f"{c[0] & 0x3f:02o}:{c[1]:08x}" for c in cells))


def all_symbols(w):
    """Yield (symbol address, name) for every symbol whose name is a short string."""
    import numpy as np
    for vma, d, t in w.segs:
        idx = np.nonzero((t & 0x3f) == 2)[0]
        for k in idx:
            na = int(d[k])
            h = w.word(na)
            if not h or (h[0] & 0x3f) != 3 or (h[1] >> 23) & 1:
                continue
            n = h[1] & 0x7fff
            if n == 0 or n > 200 or ((h[1] >> 26) & 0x3f) not in (0o24, 0o25):
                continue
            chars = []
            for i in range((n + 3) // 4):
                x = w.word(na + 1 + i)
                if not x:
                    break
                chars.append(x[1].to_bytes(4, 'little'))
            yield vma + int(k), b''.join(chars)[:n].decode('latin-1')


class WorldImage:
    """Adapter so ivory.disassemble() and ivory.Image helpers can read a World."""
    def __init__(self, world):
        import bisect
        self.w = world
        self.starts = [v for v, d, t in world.segs]

    def __getitem__(self, a):
        import bisect
        a &= 0xffffffff
        i = bisect.bisect_right(self.starts, a) - 1
        if i < 0:
            return None
        vma, d, t = self.w.segs[i]
        if a - vma >= len(d):
            return None
        return (int(t[a - vma]), int(d[a - vma]))
