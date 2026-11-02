"""CPU regression tests: small assembled programs run in emu/xlemu -p.

Each test assembles code at VMA 0xF8010000, runs it until the PC reaches the
'done' label, and checks the resulting stack (words above the initial SP).
"""
import os, subprocess, sys, tempfile
from ivasm import Asm

HERE = os.path.dirname(os.path.abspath(__file__))
XLEMU = os.path.join(HERE, '..', 'emu', 'xlemu')
BASE = 0xF8010000

FIX, NIL, SYM, LOC, LIST, EVENPC = 0o10, 0o24, 0o30, 0o31, 0o25, 0o46
EVCP, LV = 0o04, 0o44
NILW = (NIL, 0xF8041200)
TW = (SYM, 0xF8041208)


def fix(v):
    return (FIX, v & 0xFFFFFFFF)


def run(build, max_insns=10000):
    a = Asm(BASE)
    build(a)
    a.label('done')
    a.i('branch', 'done')
    mem = a.assemble()
    done = a.labels['done']
    with tempfile.NamedTemporaryFile('w', suffix='.prog', delete=False) as f:
        for vma in sorted(mem):
            tag, data = mem[vma]
            f.write(f"{vma:08x} {tag:02x} {data:08x}\n")
        path = f.name
    out = subprocess.run([XLEMU, '-p', path, '-x', hex(done), '-n', str(max_insns)],
                         capture_output=True, text=True).stdout
    os.unlink(path)
    stack, status = [], None
    for line in out.splitlines():
        p = line.split()
        if p[0] == 'S':
            stack.append((int(p[2], 8) & 0x3F, int(p[3], 16)))
        elif p[0] == 'PC':
            status = line
        elif p[0] == 'HALT':
            status = line
    return stack, status, out


TESTS = []


def test(expect):
    def deco(fn):
        TESTS.append((fn.__name__, fn, expect))
        return fn
    return deco


@test([fix(7)])
def add_immediate(a):
    a.i('push', '#', 3)
    a.i('add', '#', 4)


@test([fix(-1)])
def sub_pop(a):
    a.i('push', '#', 3)
    a.i('push', '#', 4)
    a.i('sub', 'POP')


@test([fix(2), fix(1)])
def floor_neg(a):
    # (floor 7 3) => 2, 1
    a.i('push', '#', 7)
    a.i('floor', '#', 3)


@test([fix(-3), fix(2)])
def floor_negative_dividend(a):
    # (floor -7 3) => -3, 2 (push immediates are unsigned: -7 is a full-word constant)
    a.const(fix(-7))
    a.i('floor', '#', 3)


@test([fix(0x50)])
def ldb_dpb(a):
    # (dpb 5 (byte 4 4) 0) => #x50
    a.i('push', '#', 5)
    a.i('push', '#', 0)
    a.i('dpb', 'byte', 4, 4)


@test([fix(0xA)])
def ldb(a):
    # (ldb (byte 4 4) #xA5) => #xA: rotate field = (32 - 4) mod 32
    a.i('push', '#', 0xA5 - 256)     # immediate is signed: use push-constant instead
    a.items.pop()
    a.const(fix(0xA5))
    a.i('ldb', 'byte', 4, 28)


@test([TW])
def branch_taken(a):
    a.i('push', '#', 1)
    a.i('zerop', 'POP')               # NIL
    a.i('branch-false', 'yes')
    a.i('push', '#', 99)
    a.i('branch', 'done')
    a.label('yes')
    a.i('plusp', '#', 1)              # T


@test([fix(10)])
def loop_sum(a):
    # sum 1..4 with loop-decrement-tos
    a.i('push', '#', 0)
    a.i('push', '#', 4)
    a.label('top')
    a.i('push', 'SP', 0)              # copy counter
    a.i('add', 'SP', -2)              # sum + counter
    a.i('pop', 'SP', -2)              # store into sum slot (SP|-2 measured before pop)
    a.i('loop-decrement-tos', 'top')
    a.i('set-sp-to-address', 'SP', -1)


@test([fix(42)])
def call_return(a):
    # call a local function that returns its argument + 40
    a.call('fn')
    a.i('push', '#', 2)
    a.i('finish-call-n', 0o402)       # 1 arg, value disposition 1
    a.i('branch', 'done')
    a.label('fn')
    a.entry(1)
    a.i('push', 'FP', 2)
    a.i('add', '#', 40)
    a.i('return-single', 0o1000)      # SP|pop: return the top of the stack


# Logic variables (Joshua).  The first push lands at 0xF8001001.  An unbound
# variable is a cell holding a logic-variable pointer to itself; a reference
# to a variable is an EVCP to its cell, and a data-read of a logic-variable
# pointer returns it as that EVCP.
S1 = 0xF8001001


@test([(LV, S1), (LV, S1 + 1), (LV, S1 + 2)])
def push_local_logic_variables(a):
    a.i('push-local-logic-variables', '#', 3)


@test([(EVCP, S1)])
def dereference_unbound(a):
    a.i('push-local-logic-variables', '#', 1)
    a.i('dereference', 'POP')


@test([fix(42), fix(42)])
def dereference_bound(a):
    # a reference to a cell holding 42 reads the 42
    a.i('push', '#', 42)
    a.i('push-address', 'SP', 0)
    a.i('%set-tag', '#', EVCP)
    a.i('dereference', 'POP')


@test([fix(42), (EVCP, S1), fix(42)])
def dereference_chain(a):
    # a reference to a cell holding a reference to 42
    a.i('push', '#', 42)
    a.i('push-address', 'SP', 0)
    a.i('%set-tag', '#', EVCP)
    a.i('push-address', 'SP', 0)
    a.i('%set-tag', '#', EVCP)
    a.i('dereference', 'POP')


@test([(LV, S1), (EVCP, S1)])
def dereference_reference_to_unbound(a):
    a.i('push-local-logic-variables', '#', 1)
    a.i('push-address', 'SP', 0)
    a.i('%set-tag', '#', EVCP)
    a.i('dereference', 'POP')


@test([fix(5)])
def dereference_constant(a):
    a.i('dereference', '#', 5)


@test([(LV, S1), (EVCP, S1)])
def data_read_of_logic_variable(a):
    # car of a locative to an unbound cell: the reference, not the pointer
    a.i('push-local-logic-variables', '#', 1)
    a.i('push-address', 'SP', 0)
    a.i('car', 'POP')


@test([(LV, S1), TW, NILW])
def logic_tail_test(a):
    a.i('push-local-logic-variables', '#', 1)
    a.i('push-address', 'SP', 0)
    a.i('%set-tag', '#', EVCP)
    a.i('logic-tail-test', 'POP')         # a variable: T
    a.const((LIST, 0xF8002000))
    a.i('logic-tail-test', 'POP')         # a list: NIL


@test([(EVCP, 0xF8002000), (LOC, 0xF8002001), (EVCP, 0xF8002000)])
def push_global_logic_variable(a):
    # a new unbound cell at BAR-2, which advances
    a.const((LOC, 0xF8002000))
    a.i('%write-internal-register', 0o406)    # BAR-2
    a.i('push-global-logic-variable')
    a.i('%read-internal-register', 0o406)
    a.const((LOC, 0xF8002000))
    a.i('car', 'POP')                         # the cell, read: unbound


def main():
    if not os.path.exists(XLEMU):
        print('build emu/xlemu first'); return 1
    failures = 0
    for name, fn, expect in TESTS:
        stack, status, out = run(fn)
        ok = stack == expect
        failures += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {name}")
        if not ok:
            print('   expected', [(oct(t), hex(d)) for t, d in expect])
            print('   got     ', [(oct(t), hex(d)) for t, d in stack], status)
    print(f"{len(TESTS) - failures}/{len(TESTS)} passed")
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
