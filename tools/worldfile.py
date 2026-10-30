"""Read Genera world files: Ivory (.ilod) and VLM (.vlod), after the VLM's
world_tools.c.

Both start with a header page in Ivory file format (1280 bytes = 256 Qs, in
groups of four tag bytes then four little-endian data words) holding the load
maps: (address, opcode<31:24>|count<23:0>, data) triples.  Opcodes: 0 data
pages (data = first page number), 1 constant, 2 constant incremented, 3 copy.
Ivory worlds store data pages in the same format; VLM worlds store 8192-word
pages as separate data and tag blocks.

    python3 tools/worldfile.py WORLD SYMBOL-NAME     print the symbol's value cell
"""
import bisect
import sys
import numpy as np
from ivory import Image, T, wtype

IVORY_COOKIE = 0o14322444510
VLM_COOKIE = 0o24342504610


class WorldFile(Image):
    def __init__(self, path):
        super().__init__()
        self.raw = np.fromfile(path, dtype=np.uint8)
        q = self._ivory_page(0)
        cookie = int(self.raw[0:4].view('<u4')[0])   # the file's first four bytes
        self.vlm = cookie == VLM_COOKIE
        if self.vlm:
            version = q[0][1]
            wired_q, unwired_q, bases_q, first_map_q = (1, 0, 2, 8) if version & 1 else (1, 0, 3, 8)
            bases = q[bases_q][1]
            self.data_base, self.tags_base = bases & 0x0FFFFFFF, bases >> 28
        else:
            assert cookie == IVORY_COOKIE, f"not a world file (cookie {cookie:o})"
            wired_q, unwired_q, first_map_q = 1, 2, 8
        n = q[wired_q][1] + (q[unwired_q][1] if unwired_q else 0)
        words = [self._ivory_q(first_map_q + i) for i in range(3 * n)]
        self.entries = []
        for i in range(n):
            addr = words[3 * i][1]
            op = words[3 * i + 1][1]
            self.entries.append((addr, op & 0xFFFFFF, op >> 24, words[3 * i + 2]))
        # later entries win where entries overlap
        self.entries.sort(key=lambda e: e[0])
        self.starts = [e[0] for e in self.entries]
        if self.vlm:
            self.vdata = self.raw[: len(self.raw) // 4 * 4].view('<u4')
        else:
            n = len(self.raw) // 1280
            groups = self.raw[: n * 1280].reshape(n * 64, 20)
            self.ftags = groups[:, 0:4].reshape(-1)
            self.fdata = groups[:, 4:20].copy().view('<u4').reshape(-1)

    def _ivory_page(self, page):
        return [self._ivory_q(page * 256 + i) for i in range(256)]

    def _ivory_q(self, fq):
        page, q = divmod(fq, 256)
        base = page * 1280 + 20 * (q >> 2)
        tag = int(self.raw[base + (q & 3)])
        data = int(self.raw[base + 4 + 4 * (q & 3): base + 8 + 4 * (q & 3)].view('<u4')[0])
        return tag, data

    def _page_word(self, page, i):
        if self.vlm:
            page += i // 8192
            i %= 8192
            d = int(self.vdata[(8192 * (self.data_base + page * 4)) // 4 + i])
            t = int(self.raw[8192 * (self.tags_base + page) + i])
            return t, d
        fq = page * 256 + i
        return int(self.ftags[fq]), int(self.fdata[fq])

    def __getitem__(self, a):
        i = bisect.bisect_right(self.starts, a) - 1
        while i >= 0:
            addr, count, op, data = self.entries[i]
            if addr <= a < addr + count:
                k = a - addr
                if op == 0:
                    return self._page_word(data[1], k)
                if op == 1:
                    return data
                if op == 2:
                    return data[0], (data[1] + k) & 0xFFFFFFFF
                if op == 3:
                    return self[data[1] + k]
            if a - addr > 0x1000000:
                break
            i -= 1
        return None

    def data_pages(self):
        """Yield (vma, tags, data) arrays for every data-page entry."""
        for addr, count, op, data in self.entries:
            if op != 0:
                continue
            if self.vlm:
                page = data[1]
                d0 = (8192 * (self.data_base + page * 4)) // 4
                t0 = 8192 * (self.tags_base + page)
                yield addr, self.raw[t0: t0 + count], self.vdata[d0: d0 + count]
            else:
                f0 = data[1] * 256
                yield addr, self.ftags[f0: f0 + count], self.fdata[f0: f0 + count]

    def find_strings(self, s):
        """VMAs of simple string headers whose contents are exactly s."""
        b = s.encode('latin-1')
        first = int.from_bytes((b + b'\0\0\0\0')[:4], 'little')
        out = []
        for vma, tags, data in self.data_pages():
            for k in np.nonzero(data == first)[0]:
                k = int(k)
                if k == 0 or (int(tags[k - 1]) & 0x3F) != T['HEADER-I']:
                    continue
                if self.string(vma + k - 1, len(b) + 1) == s:
                    out.append(vma + k - 1)
        return out

    def find_refs(self, target, tag):
        """VMAs of words with the given tag (low six bits) whose data is target."""
        out = []
        for vma, tags, data in self.data_pages():
            for k in np.nonzero(data == target)[0]:
                if (int(tags[k]) & 0x3F) == tag:
                    out.append(vma + int(k))
        return out

    def symbols(self, name):
        """Symbol addresses whose print name is name (symbol header -> name string)."""
        return [a for s in self.find_strings(name) for a in self.find_refs(s, T['HEADER-P'])]

    def array_elements(self, w):
        """Elements of a simple (short-prefix) array object word."""
        a = w[1]
        h = self[a]
        assert h and wtype(h) == T['HEADER-I'], f"no array header at {a:08x}"
        n = h[1] & 0x7FFF
        return [self[a + 1 + i] for i in range(n)]


if __name__ == '__main__':
    w = WorldFile(sys.argv[1])
    for s in w.symbols(sys.argv[2]):
        print(f"{s:08x}", w.obj_repr(w[s + 1]))
