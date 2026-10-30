"""Ivory (Symbolics I-machine) word utilities, image loading and disassembly.

Words are represented as (tag, data) where tag = cdr<7:6> | type<5:0>.
"""
import json, os, struct
from fepfile import read_fep_file
import fepnames

HERE = os.path.dirname(os.path.abspath(__file__))

DTP = """NULL MONITOR-FORWARD HEADER-P HEADER-I EXTERNAL-VALUE-CELL-POINTER ONE-Q-FORWARD
HEADER-FORWARD ELEMENT-FORWARD FIXNUM SMALL-RATIO SINGLE-FLOAT DOUBLE-FLOAT BIGNUM BIG-RATIO
COMPLEX SPARE-NUMBER INSTANCE LIST-INSTANCE ARRAY-INSTANCE STRING-INSTANCE NIL LIST ARRAY
STRING SYMBOL LOCATIVE LEXICAL-CLOSURE DYNAMIC-CLOSURE COMPILED-FUNCTION GENERIC-FUNCTION
SPARE-POINTER-1 SPARE-POINTER-2 PHYSICAL-ADDRESS SPARE-IMMEDIATE-1 BOUND-LOCATION CHARACTER
LOGIC-VARIABLE GC-FORWARD EVEN-PC ODD-PC CALL-COMPILED-EVEN CALL-COMPILED-ODD CALL-INDIRECT
CALL-GENERIC CALL-COMPILED-EVEN-PREFETCH CALL-COMPILED-ODD-PREFETCH CALL-INDIRECT-PREFETCH
CALL-GENERIC-PREFETCH""".split()
DTP += [f"PACKED-{i:o}" for i in range(0o60, 0o100)]
T = {n: i for i, n in enumerate(DTP)}

OPS = {int(k): v for k, v in json.load(open(os.path.join(HERE, 'data/opcodes.json'))).items()}

INTERNAL_REGS = {
    0o0: 'EA', 0o1: 'FP', 0o2: 'LP', 0o3: 'SP', 0o4: 'MacroSP', 0o5: 'StackCacheLowerBound',
    0o6: 'BAR0', 0o206: 'BAR1', 0o406: 'BAR2', 0o606: 'BAR3',
    0o7: 'PHTHash0', 0o207: 'PHTHash1', 0o407: 'PHTHash2', 0o607: 'PHTHash3',
    0o10: 'EPC', 0o11: 'DPC', 0o12: 'Continuation', 0o13: 'AluAndRotateControl',
    0o14: 'ControlRegister', 0o15: 'CRArgumentSize', 0o16: 'EphemeralOldspace',
    0o17: 'ZoneOldspace', 0o20: 'ChipRevision', 0o21: 'FPCoprocessorPresent',
    0o23: 'PreemptRegister', 0o24: 'IcacheControl', 0o25: 'PrefetcherControl',
    0o26: 'MapCacheControl', 0o27: 'MemoryControl', 0o30: 'ECCLog', 0o31: 'ECCLogAddress',
    0o32: 'InvalidateMap0', 0o232: 'InvalidateMap1', 0o432: 'InvalidateMap2', 0o632: 'InvalidateMap3',
    0o33: 'LoadMap0', 0o233: 'LoadMap1', 0o433: 'LoadMap2', 0o633: 'LoadMap3',
    0o34: 'StackCacheOverflowLimit', 0o35: 'UcodeROMContents', 0o37: 'AddressMask',
    0o40: 'EntryMaximumArguments', 0o41: 'LexicalVariable', 0o42: 'Instruction',
    0o44: 'MemoryData', 0o45: 'DataPins', 0o46: 'ExtensionRegister', 0o47: 'MicrosecondClock',
    0o50: 'ArrayHeaderLength', 0o52: 'LoadBAR0', 0o252: 'LoadBAR1', 0o452: 'LoadBAR2', 0o652: 'LoadBAR3',
    0o1000: 'TOS', 0o1001: 'EventCount', 0o1002: 'BindingStackPointer', 0o1003: 'CatchBlockList',
    0o1004: 'ControlStackLimit', 0o1005: 'ControlStackExtraLimit', 0o1006: 'BindingStackLimit',
    0o1007: 'PHTBase', 0o1010: 'PHTMask', 0o1011: 'CountMapReloads', 0o1012: 'ListCacheArea',
    0o1013: 'ListCacheAddress', 0o1014: 'ListCacheLength', 0o1015: 'StructureCacheArea',
    0o1016: 'StructureCacheAddress', 0o1017: 'StructureCacheLength',
    0o1020: 'DynamicBindingCacheBase', 0o1021: 'DynamicBindingCacheMask', 0o1022: 'ChoicePointer',
    0o1023: 'StructureStackChoicePointer', 0o1024: 'FEPModeTrapVectorAddress',
    0o1026: 'MappingTableCache', 0o1027: 'MappingTableLength', 0o1030: 'StackFrameMaximumSize',
    0o1031: 'StackCacheDumpQuantum', 0o1040: 'ConstantNIL', 0o1041: 'ConstantT',
}


def wtype(w):
    return w[0] & 0x3f


def wcdr(w):
    return w[0] >> 6


class Image:
    """Sparse 32-bit word-addressed memory of (tag, data) words."""

    def __init__(self):
        self.mem = {}

    def __getitem__(self, a):
        return self.mem.get(a & 0xffffffff)

    def __setitem__(self, a, w):
        self.mem[a & 0xffffffff] = w

    def load_fep_kernel(self, path):
        ws = read_fep_file(path)
        assert ws[0][1] == 0x00410040, hex(ws[0][1])
        n = ws[1][1]
        for i in range(n):
            vma = ws[8 + i * 3][1]
            lf = ws[8 + i * 3 + 1][1]
            imm = ws[8 + i * 3 + 2]
            length = lf & 0xffffff
            if lf & 0x01000000:
                self[vma] = imm
            else:
                base = imm[1] * 256
                for k in range(length):
                    self[vma + k] = ws[base + k]
        return self

    def load_flod(self, path):
        """Load a FEP overlay (.flod byte stream): records of address, count,
        count 5-byte words (data LE + cdr/tag byte), checksum; a negative count
        ends the file.  The records follow a text header, so find the first
        record by following the chain."""
        import struct
        d = open(path, 'rb').read()
        for off in range(len(d) - 8):
            a, c = struct.unpack_from('<Ii', d, off)
            if (a >> 27) != 31 or not 0 < c < 0x40000:
                continue
            p, recs = off, []
            while p + 8 <= len(d):
                a, c = struct.unpack_from('<Ii', d, p)
                if c < 0:
                    break
                if (a >> 27) != 31 or p + 8 + c * 5 + 4 > len(d):
                    recs = None
                    break
                recs.append((a, c, p + 8))
                p += 8 + c * 5 + 4
            if recs and c < 0:
                for a, c, q in recs:
                    for k in range(c):
                        data = struct.unpack_from('<I', d, q + 5 * k)[0]
                        self[a + k] = (d[q + 5 * k + 4], data)
                return self
        raise ValueError('no FLOD records found in ' + path)

    # --- Lisp object decoding -------------------------------------------------
    def string(self, addr, limit=200):
        h = self[addr]
        if h is None or wtype(h) != T['HEADER-I']:
            return None
        d = h[1]
        if (d >> 23) & 1:  # long prefix
            return None
        n = d & 0x7fff
        atype = (d >> 26) & 0x3f
        if atype not in (0o25, 0o24):  # art-string
            return None
        out = []
        for i in range(min(n, limit)):
            w = self[addr + 1 + i // 4]
            if w is None:
                break
            out.append(chr((w[1] >> (8 * (i % 4))) & 0xff))
        return ''.join(out)

    def symbol_name(self, addr):
        h = self[addr]
        if h is None:
            return fepnames.decode_name(self, addr)  # compressed FEP kernel name
        if wtype(h) != T['HEADER-P']:
            return None
        return self.string(h[1])

    def obj_repr(self, w, depth=2):
        t = wtype(w)
        if t == T['SYMBOL']:
            s = self.symbol_name(w[1])
            return s if s is not None else f"#<sym {w[1]:08x}>"
        if t == T['NIL']:
            return 'NIL'
        if t == T['STRING']:
            s = self.string(w[1])
            return repr(s) if s is not None else f"#<str {w[1]:08x}>"
        if t == T['STRING-INSTANCE']:
            s = fepnames.decode_name(self, w)
            if s is not None:
                return repr(s)
        if t == T['FIXNUM']:
            v = w[1] - (1 << 32) if w[1] & 0x80000000 else w[1]
            return str(v)
        if t == T['LIST'] and depth > 0:
            items = []
            a = w[1]
            for _ in range(8):
                c = self[a]
                if c is None:
                    break
                items.append(self.obj_repr(c, depth - 1))
                if wcdr(c) == 1:
                    break
                if wcdr(c) == 2:
                    nxt = self[a + 1]
                    if nxt is None or wtype(nxt) != T['LIST']:
                        break
                    a = nxt[1]
                else:
                    a += 1
            return '(' + ' '.join(items) + ')'
        if t == T['COMPILED-FUNCTION']:
            return f"#<cfn {self.function_name(w[1]) or hex(w[1])}>"
        if t == T['CHARACTER']:
            return f"#\\{chr(w[1] & 0xff) if 32 <= (w[1] & 0xff) < 127 else hex(w[1])}"
        return f"#<{DTP[t]} {w[1]:08x}>"

    def function_header(self, body):
        h = self[body - 2]
        if h and wtype(h) == T['HEADER-I'] and wcdr(h) == 0:
            return body - 2, h
        return None, None

    def function_name(self, body):
        ha, h = self.function_header(body)
        if ha is None:
            return None
        total = h[1] & 0x3ffff
        suffix = (h[1] >> 18) & 0x3fff
        s0 = self[ha + total - suffix]
        if s0 is None:
            return None
        if wtype(s0) == T['LIST']:
            c = self[s0[1]]
            if c is None:
                return None
            return self.obj_repr(c, 3)
        return self.obj_repr(s0, 1)

    def functions(self, lo, hi):
        """Yield (body_addr, total_size, name) for compiled functions in [lo, hi)."""
        a = lo
        while a < hi:
            w = self[a]
            if w and wtype(w) == T['HEADER-I'] and wcdr(w) == 0:
                total = w[1] & 0x3ffff
                suffix = (w[1] >> 18) & 0x3fff
                nxt = self[a + 2]
                if 2 < total < 0x10000 and suffix < total and nxt and wtype(nxt) >= 0o60:
                    yield a + 2, total, self.function_name(a + 2)
                    a += total
                    continue
            a += 1


def sext(v, bits):
    return v - (1 << bits) if v & (1 << (bits - 1)) else v


def dis_half(h, img=None):
    op = (h >> 10) & 0xff
    operand = h & 0x3ff
    info = OPS.get(op)
    name = info['name'] if info else f"op{op:o}"
    fmt = info['operands'] if info else []
    if 'relative-pc' in fmt:
        return f"{name} {sext(operand, 10):+d}"
    if 'byte' in fmt:
        rot = operand & 0x1f
        size = (operand >> 5) + 1
        return f"{name} size={size} rot={rot}"
    if '10-bit-immediate' in fmt or '12-bit-unsigned-immediate' in fmt:
        if op in (0o154, 0o155):
            return f"{name} {INTERNAL_REGS.get(operand, oct(operand))}"
        if op in (0o156, 0o157):
            return f"{name} #o{operand:o}"
        return f"{name} {operand}"
    if 'entry' in fmt:
        return name
    if not fmt:
        return name
    mode = operand >> 8
    off = operand & 0xff
    if mode == 0:
        return f"{name} FP|{off}"
    if mode == 1:
        return f"{name} LP|{off}"
    if mode == 2:
        return f"{name} SP|{off - 255}" if off else f"{name} SP-pop"
    if 'signed' in fmt:
        return f"{name} #{sext(off, 8)}"
    return f"{name} #{off}"


def disassemble(img, body, total=None, out=print):
    ha, h = img.function_header(body)
    if total is None and h:
        total = h[1] & 0x3ffff
    suffix = (h[1] >> 18) & 0x3fff if h else 0
    end = ha + total - suffix if ha is not None else body + 64
    out(f";; {img.function_name(body)} @ {body:08x}")
    a = body
    while a < end:
        w = img[a]
        if w is None:
            break
        t = wtype(w)
        cdr = wcdr(w)
        if t >= 0o60:
            ins = ((t & 0xf) << 32) | w[1]
            e, o = ins & 0x3ffff, ins >> 18
            eop = (e >> 10) & 0xff
            if eop in (0o176, 0o177):
                req = (e & 0xff) - 2
                tot = ((ins >> 18) & 0xff) - 2
                out(f"{a:08x}  c{cdr}  {OPS[eop]['name']} req={req} req+opt={tot}")
            else:
                out(f"{a:08x}  c{cdr}  {dis_half(e)}")
                out(f"{a:08x}.5    {dis_half(o)}")
        elif T['CALL-COMPILED-EVEN'] <= t <= T['CALL-GENERIC-PREFETCH']:
            tgt = w[1]
            nm = img.function_name(tgt) if t in (0o50, 0o54) else None
            if t in (0o52, 0o56):
                # function cell: find symbol owning it
                nm = img.obj_repr(img[tgt]) if img[tgt] else None
                sym = img.symbol_name(tgt - 2)
                if sym:
                    nm = sym
            out(f"{a:08x}  c{cdr}  {DTP[t]} {tgt:08x} {nm or ''}")
        elif t == T['EXTERNAL-VALUE-CELL-POINTER']:
            sym = img.symbol_name(w[1] - 1)
            out(f"{a:08x}  c{cdr}  push-value {w[1]:08x} {sym or ''}")
        else:
            out(f"{a:08x}  c{cdr}  push-constant {img.obj_repr(w)}")
        a += 1


def load_dump(path, base=0xF8000000):
    """Load a physical-memory dump (uint64 per word) as an Image in VMA=PMA space."""
    import array
    img = Image()
    a = array.array('Q')
    with open(path, 'rb') as f:
        a.frombytes(f.read())
    for i, w in enumerate(a):
        if w:
            img[base + i] = ((w >> 32) & 0xFF, w & 0xFFFFFFFF)
    return img
