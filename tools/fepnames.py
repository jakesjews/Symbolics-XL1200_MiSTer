"""Decode the compressed symbol/string pseudo-pointers in an IFEP kernel.

Symbols and strings the FEP kernel only needs for its Device-PROM DDT debugger
are not stored as real objects.  Instead the compiler emitted DTP-SYMBOL (030)
and DTP-STRING-INSTANCE (023) words whose "addresses" encode the print name
against *KERNEL-COMPRESSED-STRING-ARRAY* (FEP communication-area word
0xF804103F), an ART-Q array of six tables:

  [0] alphabet  ART-STRING, 32 chars "&*,.0:ABCDEFGHIKLMNOPRSTUVWXYZ~<Return>"
  [1] chars5    ART-FIXNUM, a continuous LSB-first stream of 5-bit alphabet codes
  [2] chars8    ART-FIXNUM, raw 8-bit characters, 4 per word little-endian
  [3] words     ART-Q, one 33-bit entry (tag bit 0 = data bit 32) per word:
        b32=0 b31=0  length<30:24>, offset<23:0> into chars5
        b32=1 b31=0  length<30:24>, offset<23:0> into chars8 (mixed case etc.)
        b32=0 b31=1  up to 6 inline 5-bit codes, first char most significant
        b32=1 b31=1  up to 3 inline 8-bit chars, first char most significant
  [4] symseq    ART-FIXNUM, LSB-first stream of 12-bit word indices
  [5] strseq    ART-FIXNUM, LSB-first stream of 14-bit elements mode<13:12>|word<11:0>

Pseudo-pointer formats (the data field of the 030/023 word):

  0xF9hhhlll  symbol: word[lll], or word[hhh]-word[lll] when hhh != 0
  0xF900mlll  string: word[lll] with case mode m
  0xFA......  count = bits 23:17, offset = bits 16:0
              symbol: count 12-bit indices from symseq, joined with "-"
              string: count 14-bit elements from strseq, joined with " "

Case modes for strings: 0 verbatim, 1 upper, 2 lower, 3 capitalized.  Package
prefixes (e.g. "SYSTEM:", "IFEPC::", ":" for keywords) are part of the words.
"""
import sys

COMPRESSED_STRING_ARRAY_CELL = 0xF804103F   # *KERNEL-COMPRESSED-STRING-ARRAY*

DTP_SYMBOL = 0o30
DTP_STRING_INSTANCE = 0o23

_CHARMAP = {0x8D: '\n', 0x89: '\t'}         # Symbolics Return/Tab


def _chr(c):
    return _CHARMAP.get(c) or chr(c)


def _array(img, addr):
    """Return (array-type, [words]) for a short-prefix array at addr, or None."""
    h = img[addr]
    if h is None or (h[0] & 0x3f) != 0o3 or (h[1] >> 23) & 1:
        return None
    n = h[1] & 0x7fff
    ws = [img[addr + 1 + i] for i in range(n)]
    if any(w is None for w in ws):
        return None
    return (h[1] >> 26) & 0x3f, ws


def _stream(ws):
    v = 0
    for i, w in enumerate(ws):
        v |= w[1] << (32 * i)
    return v, 32 * len(ws)


def _capitalize(s):
    """Common Lisp STRING-CAPITALIZE."""
    out, in_word = [], False
    for c in s:
        if c.isalnum():
            out.append(c.lower() if in_word else c.upper())
            in_word = True
        else:
            out.append(c)
            in_word = False
    return ''.join(out)


class _Tables:
    def __init__(self, img):
        cell = img[COMPRESSED_STRING_ARRAY_CELL]
        if cell is None:
            raise ValueError("no *KERNEL-COMPRESSED-STRING-ARRAY*")
        top = _array(img, cell[1])
        if top is None or len(top[1]) < 6:
            raise ValueError("bad *KERNEL-COMPRESSED-STRING-ARRAY*")
        parts = [_array(img, w[1]) for w in top[1][:6]]
        if any(p is None for p in parts):
            raise ValueError("missing compressed-string subarray")
        alpha_ws = parts[0][1]
        self.alphabet = ''.join(_chr((alpha_ws[i // 4][1] >> (8 * (i % 4))) & 0xff)
                                for i in range(32))
        self.chars5, self.chars5_bits = _stream(parts[1][1])
        self.chars8 = b''.join(w[1].to_bytes(4, 'little') for w in parts[2][1])
        self.words = parts[3][1]
        self.symseq, self.symseq_bits = _stream(parts[4][1])
        self.strseq, self.strseq_bits = _stream(parts[5][1])
        self._cache = {}

    def word(self, j):
        if j in self._cache:
            return self._cache[j]
        if not 0 <= j < len(self.words):
            return None
        tag, v = self.words[j]
        b32 = tag & 1
        if v >> 31:
            x = v & 0x7fffffff
            out = []
            if b32:
                while x:
                    out.append(_chr(x & 0xff))
                    x >>= 8
            else:
                while x:
                    out.append(self.alphabet[x & 31])
                    x >>= 5
            s = ''.join(reversed(out))
        else:
            n, off = (v >> 24) & 0x7f, v & 0xffffff
            if b32:
                if off + n > len(self.chars8):
                    return None
                s = ''.join(_chr(c) for c in self.chars8[off:off + n])
            else:
                if 5 * (off + n) > self.chars5_bits:
                    return None
                s = ''.join(self.alphabet[(self.chars5 >> (5 * (off + i))) & 31]
                            for i in range(n))
        self._cache[j] = s
        return s

    def cased_word(self, e):
        mode, j = (e >> 12) & 3, e & 0xfff
        s = self.word(j)
        if s is None:
            return None
        if mode == 1:
            return s.upper()
        if mode == 2:
            return s.lower()
        if mode == 3:
            return _capitalize(s)
        return s

    def symbol(self, p):
        hi, v = p >> 24, p & 0xffffff
        if hi == 0xF9:
            a, b = v >> 12, v & 0xfff
            parts = [self.word(a), self.word(b)] if a else [self.word(b)]
        elif hi == 0xFA:
            n, off = v >> 17, v & 0x1ffff
            if n == 0 or 12 * (off + n) > self.symseq_bits:
                return None
            parts = [self.word((self.symseq >> (12 * (off + i))) & 0xfff) for i in range(n)]
        else:
            return None
        if any(s is None for s in parts):
            return None
        return '-'.join(parts)

    def string(self, p):
        hi, v = p >> 24, p & 0xffffff
        if hi == 0xF9:
            if v >> 14:
                return None
            parts = [self.cased_word(v)]
        elif hi == 0xFA:
            n, off = v >> 17, v & 0x1ffff
            if n == 0 or 14 * (off + n) > self.strseq_bits:
                return None
            parts = [self.cased_word((self.strseq >> (14 * (off + i))) & 0x3fff)
                     for i in range(n)]
        else:
            return None
        if any(s is None for s in parts):
            return None
        return ' '.join(parts)


def tables(img):
    """Return the decoded tables for img (cached on the image), or None."""
    t = img.__dict__.get('_fepnames_tables', False)
    if t is False:
        try:
            t = _Tables(img)
        except ValueError:
            t = None
        img.__dict__['_fepnames_tables'] = t
    return t


def decode_name(img, pointer, string=False):
    """Decode a compressed pseudo-pointer to its print name, or None.

    pointer is either a data field (int; decoded as a symbol unless string=True)
    or a (tag, data) word, whose type (SYMBOL or STRING-INSTANCE) selects the
    decoding.  Pointers that address loaded memory are not compressed names.
    """
    if isinstance(pointer, tuple):
        t = pointer[0] & 0x3f
        if t == DTP_STRING_INSTANCE:
            string = True
        elif t != DTP_SYMBOL:
            return None
        pointer = pointer[1]
    pointer &= 0xffffffff
    if img[pointer] is not None:
        return None
    tb = tables(img)
    if tb is None:
        return None
    return tb.string(pointer) if string else tb.symbol(pointer)


if __name__ == '__main__':
    import os
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from ivory import Image
    if len(sys.argv) != 2:
        sys.exit('usage: fepnames.py I333-kernel.fep   (a FEP kernel file, e.g. from fepfs.py get)')
    path = sys.argv[1]
    img = Image().load_fep_kernel(path)
    for body, size, name in img.functions(0xF800C000, 0xF8018000):
        print(f"{body:08x}  {name}")
