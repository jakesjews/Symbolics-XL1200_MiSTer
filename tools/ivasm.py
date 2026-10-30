"""Minimal Ivory assembler (for CPU tests and the boot ROM).

Usage:
    a = Asm(0xFFFE0040)
    a.label('top')
    a.i('push', 'FP', 2)          # operand-from-stack: FP|2
    a.i('add', '#', 1)            # immediate
    a.i('pop', 'SP', -1)          # SP|-1 (offset relative to TOS, i.e. SP|0 is TOS)
    a.i('push', 'POP')            # sp-pop mode
    a.i('branch-false', 'top')    # relative branch to label
    a.i('%read-internal-register', 0o1000)   # 10-bit immediate
    a.const(mkw(T['FIXNUM'], 5))  # push a full-word constant
    words = a.assemble()          # {vma: (tag, data)}

Instructions are packed two per word with cdr-next sequencing; a full-word
item that would start on an odd halfword gets a no-op in the odd slot first.
"""
import json, os

HERE = os.path.dirname(os.path.abspath(__file__))
_OPS = {int(k): v for k, v in json.load(open(os.path.join(HERE, 'data/opcodes.json'))).items()}
OPCODES = {v['name']: k for k, v in _OPS.items()}
FORMATS = {v['name']: v['operands'] for v in _OPS.values()}

DTP_FIXNUM = 0o10
DTP_PACKED = 0o60


def word(tag, data):
    return (tag & 0xFF, data & 0xFFFFFFFF)


class Asm:
    def __init__(self, base):
        self.base = base            # word address of the first word
        self.items = []             # ('h', name, args) or ('w', (tag, data), cdr) or ('label', name)

    def label(self, name):
        self.items.append(('label', name))

    def i(self, name, *args):
        if name not in OPCODES:
            raise ValueError('unknown instruction ' + name)
        self.items.append(('h', name, args))

    def const(self, w):
        """Full-word instruction: push constant / call / value cell, given as (tag, data)."""
        self.items.append(('w', w))

    def call(self, target):
        """Start a call to the function whose entry is at label TARGET (dtp-call-compiled-even);
        push the arguments, then finish-call-n."""
        self.items.append(('wlabel', 0o50, target))

    def entry(self, nreq, nopt=0, rest=False):
        """Entry instruction (full word)."""
        self.items.append(('entry', nreq, nopt, rest))

    def data(self, w):
        """A raw data word (not executed)."""
        self.items.append(('data', w))

    # ------------------------------------------------------------------
    def _layout(self):
        """Assign halfword PCs to every item; returns list of (pc, item)."""
        out = []
        hpc = self.base * 2
        for it in self.items:
            if it[0] == 'label':
                out.append((hpc, it))
                continue
            if it[0] == 'h':
                out.append((hpc, it))
                hpc += 1
            else:
                if hpc & 1:
                    out.append((hpc, ('h', 'no-op', ())))
                    hpc += 1
                out.append((hpc, it))
                hpc += 2
        return out, hpc

    def _operand(self, name, args, pc, labels):
        fmt = FORMATS[name]
        if 'relative-pc' in fmt:
            tgt = args[0]
            off = (labels[tgt] if isinstance(tgt, str) else tgt) - (pc if isinstance(tgt, str) else 0)
            if not -512 <= off < 512:
                raise ValueError(f'branch to {tgt} out of range ({off})')
            return off & 0x3FF
        if not args:
            return 0
        if len(args) == 1 and isinstance(args[0], int):
            return args[0] & 0x3FF          # 10-bit immediate / raw operand
        mode, *rest = args
        if mode == 'FP':
            return (0 << 8) | (rest[0] & 0xFF)
        if mode == 'LP':
            return (1 << 8) | (rest[0] & 0xFF)
        if mode == 'SP':                    # SP|n with n <= 0, n = 0 is TOS
            return (2 << 8) | ((255 + rest[0]) & 0xFF)
        if mode == 'POP':
            return (2 << 8) | 0
        if mode == '#':
            return (3 << 8) | (rest[0] & 0xFF)
        if mode == 'byte':                  # field instructions: ('byte', size, rotation): the word is
                                            # rotated left, then masked (a field at bit p is rotation 32-p)
            size, pos = rest
            return ((size - 1) << 5) | (pos & 31)
        raise ValueError(f'bad operand {args} for {name}')

    def assemble(self):
        layout, end = self._layout()
        labels = {it[1]: pc for pc, it in layout if it[0] == 'label'}
        mem = {}
        halves = {}
        for pc, it in layout:
            kind = it[0]
            if kind == 'label':
                continue
            if kind == 'h':
                name, args = it[1], it[2]
                h = (OPCODES[name] << 10) | self._operand(name, args, pc, labels)
                halves[pc] = h
            elif kind in ('w', 'data'):
                tag, d = it[1]
                cdr = 3 if kind == 'w' else 1
                mem[pc >> 1] = word(((cdr << 6) | (tag & 0x3F)), d)
            elif kind == 'wlabel':
                _, tag, target = it
                # the entry is a full word: past the no-op that aligns it if the label is odd
                mem[pc >> 1] = word((3 << 6) | (tag & 0x3F), (labels[target] + 1) >> 1)
            elif kind == 'entry':
                _, nreq, nopt, rest = it
                op = OPCODES['entry-rest-accepted' if rest else 'entry-rest-not-accepted']
                even = (op << 10) | (3 << 8) | ((nreq + 2) & 0xFF)
                ins = (((nreq + nopt + 2) & 0xFF) << 18) | even
                tag = (3 << 6) | DTP_PACKED | ((ins >> 32) & 0xF)
                mem[pc >> 1] = word(tag, ins & 0xFFFFFFFF)
        for pc in sorted(halves):
            w = pc >> 1
            if w in mem:
                continue
            ev = halves.get(w * 2, OPCODES['no-op'] << 10)
            od = halves.get(w * 2 + 1, OPCODES['no-op'] << 10)
            ins = (od << 18) | ev
            tag = (0 << 6) | DTP_PACKED | ((ins >> 32) & 0xF)
            mem[w] = word(tag, ins & 0xFFFFFFFF)
        self.labels = {k: v for k, v in labels.items()}
        return mem
