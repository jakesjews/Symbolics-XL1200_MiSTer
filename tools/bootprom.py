"""Stand-in for the XL1200 boot PROM (no dump of the Merlin boot PROM exists).

It does what the PROM has to before the FEP runs: find a SCSI disk whose
label names an installed FEP kernel, load the kernel by its load map, note
where it came from in the boot data area, and enter FEP-STARTUP in FEP mode
with a frame on the boot stack (see docs/NOTES.md, "How the FEP kernel is
found on disk").  The boot communication area at the start of the PROM is
data.  The SCSI sequence is the FEP's own (IFEP v333 driver).

    python3 tools/bootprom.py OUT.mem    one line per PROM word from 0:
                                         10 hex digits, {cdr, type, data}
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ivasm import Asm

PROM_VMA = 0xFFFE0000          # VMA=PMA, physical 0x07FE0000
ENTRY_VMA = PROM_VMA + 0o100   # %INIT-PC

FIX, LOC, PHYS, EVEN_PC = 0o10, 0o31, 0o40, 0o46
CYC_RAW = 11

IOB_CTL = 0x44015000           # I/O board control (bit 3 holds the WD33C93 in reset)
WD_WRITE, WD_READ, WD_LATCH = 0x44017800, 0x44017900, 0x44017000
DMA_WINDOW, DMA_ADDRESS = 0x4401A000, 0x4401B800
BUFFER = 0x40004000            # buffer memory page 4 (the FEP's choice too)
MAX_BLOCKS = 12                # 12 x 320 words fit in the 4K-word page
PROM_RAM_WORDS = 512           # the PROM block RAM in the core

STACK_BASE, STACK_SIZE = 0xF8000100, 0xF00
SCRATCH = 0xF8007000           # load map copy (FEP heap, not loaded by the kernel)
FEP_STARTUP = 0xF8041002       # FEP communication area word 2
BOOT_KERNEL_DPN = 0xF8040940 + 0o56 + 7   # boot data area BOOT-FEP-KERNEL-DPN


def comm_area():
    """Boot communication area: the first words of the PROM (sysdf1)."""
    p = {i: (FIX, 0) for i in range(0o100)}        # unprogrammed: fixnum 0 (serial number 0)
    p[0] = (PHYS, 0x07FE0000 + 0o70)               # *boot-emb-communication-area*: none
    p[1] = (FIX, 0o1011)                           # *boot-system-type*: XL1200
    p[2] = (LOC, STACK_BASE)                       # *boot-stack-base*
    p[3] = (FIX, STACK_SIZE)                       # *boot-stack-size*
    p[4] = (FIX, 0)                                # *boot-spy-pc*
    p[7] = (LOC, 0xF8040940)                       # *boot-spy-block-address*
    p[0o10] = (FIX, 1)                             # *boot-prom-version*
    return p


def build():
    a = Asm(ENTRY_VMA)

    def push(v):
        if 0 <= v < 256:
            a.i('push', '#', v)
        else:
            a.const((FIX, v & 0xFFFFFFFF))

    def phys(addr):
        a.const((PHYS, addr))

    def loc(addr):
        a.const((LOC, addr))

    def read():                     # address on the stack -> its contents
        a.i('%memory-read', CYC_RAW << 6)

    def write_imm(addr, v):         # (memory-write addr v) with a small v
        phys(addr)
        a.i('%memory-write', '#', v)

    def wd_write(r, v):
        write_imm(WD_WRITE + r, v)

    def wd_read(r):                 # pushes the register's byte
        write_imm(WD_READ + r, 0)
        phys(WD_LATCH)
        read()

    def finish(nargs, value=True):  # after a.call(fn) and the arguments; the value to the stack
        a.i('finish-call-n', ((1 if value else 0) << 8) | (nargs + 1))

    def ldb(size, pos):             # the field instructions take a left rotation, not a position
        a.i('ldb', 'byte', size, (32 - pos) % 32)

    def wait_interrupt(label):
        a.label(label)
        wd_read(0x1F)
        a.i('logand', '#', 0x80)
        a.i('zerop', 'POP')
        a.i('branch-true', label)

    # ------------------------------------------------------------------ main
    # Locals above the reset stack pointer (%INIT-SP): FP|1 ...
    JUNK, TARGET, HEADER, NENT, I, VMA, LEFT, BLK, NB, J, LIMIT, CNT = range(1, 13)
    for _ in range(12):
        a.i('push', '#', 0)

    # Main-board memory cache on (Merlin-II cache control 0x0A000004, mode
    # field <1:0> = 2, enabled): the FEP never sets it, and Genera warns when
    # it isn't.
    write_imm(0x0A000004, 2)

    # SCSI controller: out of reset, reset command, timeout, source ID, DMA mode
    for v in (0x8F, 0x86, 0xB7):
        write_imm(IOB_CTL, v)
    wd_read(0x1F); a.i('pop', 'FP', JUNK)
    wd_read(0x17); a.i('pop', 'FP', JUNK)
    wd_write(0x00, 0x87)
    wd_write(0x18, 0x00)
    wait_interrupt('reset_wait')
    wd_read(0x17); a.i('pop', 'FP', JUNK)
    wd_write(0x02, 0x40)
    wd_write(0x16, 0x00)
    wd_write(0x01, 0x80)

    # The first target whose label has a kernel (label word 42: its header's DPN)
    a.label('try_target')
    a.call('scsi_read')
    a.i('push', 'FP', TARGET); a.i('push', '#', 0); a.i('push', '#', 1)
    finish(3)
    a.i('equal-number', '#', 0x16)
    a.i('branch-false', 'next_target')
    phys(BUFFER + 5 * (42 >> 2) + 1 + (42 & 3)); read()
    a.i('pop', 'FP', HEADER)
    a.i('push', 'FP', HEADER)
    a.i('zerop', 'POP')
    a.i('branch-false', 'found')
    a.label('next_target')
    a.i('increment', 'FP', TARGET)
    a.i('push', 'FP', TARGET)
    a.i('equal-number', '#', 7)
    a.i('branch-false', 'try_target')
    a.i('%halt')                    # no disk with a kernel

    # The kernel's first data block holds the load map
    a.label('found')
    a.call('scsi_read')
    a.i('push', 'FP', TARGET)
    a.i('push', 'FP', HEADER); a.i('add', '#', 1)
    a.i('push', '#', 1)
    finish(3)
    a.i('equal-number', '#', 0x16)
    a.i('branch-false', 'fail')
    phys(BUFFER + 1); read()        # word 0: magic
    push(0x00410040)
    a.i('equal-number', 'POP')
    a.i('branch-false', 'fail')
    phys(BUFFER + 2); read()        # word 1: entries
    a.i('pop', 'FP', NENT)
    a.i('push', 'FP', NENT); a.i('push', 'FP', NENT); a.i('add', 'POP')
    a.i('add', 'FP', NENT); a.i('pop', 'FP', LIMIT)   # 3 words an entry

    # Copy the entries (from word 8) out of the buffer before it is reused
    a.i('push', '#', 0); a.i('pop', 'FP', I)
    a.label('copy_map')
    a.i('push', 'FP', I); a.i('equal-number', 'FP', LIMIT)
    a.i('branch-true', 'map_copied')
    a.call('fep_store')
    a.i('push', 'FP', I); a.i('add', '#', 8)
    loc(SCRATCH); a.i('%pointer-plus', 'FP', I)
    finish(2, value=False)
    a.i('increment', 'FP', I)
    a.i('branch', 'copy_map')
    a.label('map_copied')

    # Each entry: (vma, length | flags, block or immediate word)
    a.i('push', '#', 0); a.i('pop', 'FP', I)
    a.label('entry')
    a.i('push', 'FP', I); a.i('equal-number', 'FP', LIMIT)
    a.i('branch-true', 'loaded')
    loc(SCRATCH); a.i('%pointer-plus', 'FP', I); read()
    a.i('%set-tag', '#', LOC); a.i('pop', 'FP', VMA)
    loc(SCRATCH + 1); a.i('%pointer-plus', 'FP', I); read()
    a.i('%set-tag', '#', FIX); a.i('pop', 'FP', LEFT)
    loc(SCRATCH + 2); a.i('%pointer-plus', 'FP', I); read()
    a.i('pop', 'FP', BLK)
    a.i('push', 'FP', LEFT); ldb(1, 24)
    a.i('zerop', 'POP')
    a.i('branch-true', 'segment')
    a.i('push', 'FP', VMA)                               # an immediate word, cdr code and all
    loc(SCRATCH + 2); a.i('%pointer-plus', 'FP', I); read()
    a.i('%memory-write', 'POP')
    a.i('branch', 'next_entry')

    a.label('segment')
    a.i('push', 'FP', LEFT); ldb(24, 0); a.i('pop', 'FP', LEFT)
    a.i('push', 'FP', BLK); a.i('%set-tag', '#', FIX); a.i('pop', 'FP', BLK)
    a.label('chunk')
    a.i('push', 'FP', LEFT); a.i('zerop', 'POP')
    a.i('branch-true', 'next_entry')
    a.i('push', 'FP', LEFT); a.i('add', '#', 255); a.i('lsh', '#', -8 & 0xFF)
    a.i('pop', 'FP', NB)
    a.i('push', 'FP', NB); a.i('greaterp', '#', MAX_BLOCKS)
    a.i('branch-false', 'nb_ok')
    a.i('push', '#', MAX_BLOCKS); a.i('pop', 'FP', NB)
    a.label('nb_ok')
    a.call('scsi_read')
    a.i('push', 'FP', TARGET)
    a.i('push', 'FP', HEADER); a.i('add', '#', 1); a.i('add', 'FP', BLK)
    a.i('push', 'FP', NB)
    finish(3)
    a.i('equal-number', '#', 0x16)
    a.i('branch-false', 'fail')
    a.i('push', 'FP', NB); a.i('lsh', '#', 8); a.i('pop', 'FP', CNT)
    a.i('push', 'FP', CNT); a.i('greaterp', 'FP', LEFT)
    a.i('branch-false', 'cnt_ok')
    a.i('push', 'FP', LEFT); a.i('pop', 'FP', CNT)
    a.label('cnt_ok')
    a.i('push', '#', 0); a.i('pop', 'FP', J)
    a.label('word')
    a.i('push', 'FP', J); a.i('equal-number', 'FP', CNT)
    a.i('branch-true', 'chunk_done')
    a.call('fep_store')
    a.i('push', 'FP', J)
    a.i('push', 'FP', VMA); a.i('%pointer-plus', 'FP', J)
    finish(2, value=False)
    a.i('increment', 'FP', J)
    a.i('branch', 'word')
    a.label('chunk_done')
    a.i('push', 'FP', VMA); a.i('%pointer-plus', 'FP', CNT); a.i('pop', 'FP', VMA)
    a.i('push', 'FP', BLK); a.i('add', 'FP', NB); a.i('pop', 'FP', BLK)
    a.i('push', 'FP', LEFT); a.i('sub', 'FP', CNT); a.i('pop', 'FP', LEFT)
    a.i('branch', 'chunk')

    a.label('next_entry')
    a.i('push', 'FP', I); a.i('add', '#', 3); a.i('pop', 'FP', I)
    a.i('branch', 'entry')

    a.label('fail')
    a.i('%halt')

    # Where the kernel came from: FEP unit (SCSI target + 7) in bits 31:27, header DPN
    a.label('loaded')
    loc(BOOT_KERNEL_DPN)
    a.i('push', 'FP', TARGET); a.i('add', '#', 7); a.i('lsh', '#', 27)
    a.i('logior', 'FP', HEADER)
    a.i('%memory-write', 'POP')

    # FEP-STARTUP's frame on the boot stack, as if called from the PROM entry.
    # The stack cache shadows the frame before it is written (spec: after
    # loading a stack, the lower bound is FP; the FEP compares the bound with
    # *boot-stack-base* to tell whether it is running on its own stack), with
    # the overflow limit where Genera puts it, a maximum frame above the bound.
    loc(STACK_BASE + 1); a.i('%write-internal-register', 5)         # stack cache lower bound
    loc(STACK_BASE + 1 + 112); a.i('%write-internal-register', 0o34) # stack cache overflow limit
    loc(STACK_BASE + 1); a.const((EVEN_PC, ENTRY_VMA)); a.i('%set-tag', '#', 0xC0 | EVEN_PC)
    a.i('%memory-write', 'POP')
    loc(STACK_BASE + 2); a.i('%read-internal-register', 0o14); a.i('%set-tag', '#', 0xC0 | FIX)
    a.i('%memory-write', 'POP')
    loc(STACK_BASE + 3)             # the startup PC, where LP|0 will be
    loc(FEP_STARTUP); read(); a.i('%set-tag', '#', EVEN_PC)
    a.i('%memory-write', 'POP')
    loc(STACK_BASE + STACK_SIZE - 0x100); a.i('%write-internal-register', 0o1004)
    loc(STACK_BASE + STACK_SIZE); a.i('%write-internal-register', 0o1005)
    a.const((EVEN_PC, ENTRY_VMA)); a.i('%write-internal-register', 0o12)
    push((3 << 30) | 2 | (1 << 18)); a.i('%write-internal-register', 0o14)
    loc(STACK_BASE + 1); a.i('%write-internal-register', 1)    # FP
    loc(STACK_BASE + 3); a.i('%write-internal-register', 2)    # LP
    loc(STACK_BASE + 2); a.i('%write-internal-register', 3)    # SP
    a.i('%jump', 'LP', 0)

    # ------------------------------------------------- (scsi-read target lba nblocks)
    # READ(10) into the buffer at BUFFER; returns the WD33C93 status (#x16 = done)
    a.label('scsi_read')
    a.entry(3)
    TGT, LBA, N, BYTES = 2, 3, 4, 5
    write_imm(IOB_CTL, 0xB7)
    write_imm(DMA_WINDOW, ((((BUFFER >> 12) & 7) + 1) << 3) | ((BUFFER >> 12) & 7))
    write_imm(DMA_ADDRESS, 0)
    write_imm(IOB_CTL, 0x37)
    phys(WD_WRITE + 0x15); a.i('push', 'FP', TGT); a.i('%memory-write', 'POP')
    wd_write(0x0F, 0)
    a.i('push', 'FP', N); a.i('lsh', '#', 10)
    a.i('push', 'FP', N); a.i('lsh', '#', 8); a.i('add', 'POP')   # FP|5: bytes
    for r, pos in ((0x12, 16), (0x13, 8), (0x14, 0)):
        phys(WD_WRITE + r); a.i('push', 'FP', BYTES); ldb(8, pos)
        a.i('%memory-write', 'POP')
    wd_write(0x03, 0x28)                       # READ(10)
    wd_write(0x04, 0)
    for r, pos in ((0x05, 24), (0x06, 16), (0x07, 8), (0x08, 0)):
        phys(WD_WRITE + r); a.i('push', 'FP', LBA); ldb(8, pos)
        a.i('%memory-write', 'POP')
    wd_write(0x09, 0)
    wd_write(0x0A, 0)
    phys(WD_WRITE + 0x0B); a.i('push', 'FP', N); a.i('%memory-write', 'POP')
    wd_write(0x0C, 0)
    wd_write(0x18, 0x08)                       # select and transfer
    wait_interrupt('xfer_wait')
    wd_read(0x17)
    a.i('push', 'SP', 0); a.i('equal-number', '#', 0x16)
    a.i('branch-false', 'xfer_done')
    wait_interrupt('disconnect_wait')          # then the target disconnects
    wd_read(0x17); a.i('pop', 'FP', BYTES)
    a.label('xfer_done')
    a.i('return-single', 0o1000)

    # ------------------------------------------------- (fep-store j address)
    # Store word j of the blocks in the buffer: groups of 20 bytes, 4 tag bytes
    # then 4 data words, so its data is at 5*(j>>2) + 1 + (j&3) and its tag
    # byte in word 5*(j>>2), byte (j&3).  The word goes to memory from here
    # rather than as the value: a returned value loses its cdr code.
    a.label('fep_store')
    a.entry(2)
    JJ, ADDR, OFF, SHIFT = 2, 3, 4, 5
    a.i('push', 'FP', JJ); a.i('lsh', '#', -2 & 0xFF)
    a.i('push', 'SP', 0); a.i('lsh', '#', 2); a.i('add', 'POP')        # FP|4: 5*(j>>2)
    a.i('push', 'FP', JJ); a.i('logand', '#', 3); a.i('lsh', '#', 3)
    a.i('unary-minus', 'POP')                                           # FP|5: -8*(j&3)
    a.i('push', 'FP', ADDR)
    phys(BUFFER + 1); a.i('%pointer-plus', 'FP', OFF)
    a.i('push', 'FP', JJ); a.i('logand', '#', 3)
    a.i('%pointer-plus', 'POP'); read()                                 # the data
    phys(BUFFER); a.i('%pointer-plus', 'FP', OFF); read()
    a.i('lsh', 'FP', SHIFT); a.i('logand', '#', 0xFF)                   # the tag
    a.i('%set-tag', 'POP')
    a.i('%memory-write', 'POP')
    a.i('return-single', '#', 0)

    return a


def image():
    a = build()
    code = a.assemble()
    words = {i: w for i, w in comm_area().items()}
    for vma, w in code.items():
        words[vma - PROM_VMA] = w
    return words, a


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else 'boot_prom.mem'
    words, _ = image()
    # Padded with fixnum 0 to the size of the core's PROM block RAM (rtl/xl).
    n = max(max(words) + 1, PROM_RAM_WORDS)
    with open(out, 'w') as f:
        for i in range(n):
            tag, data = words.get(i, (FIX, 0))
            f.write(f"{tag:02x}{data:08x}\n")
    print(f"{out}: {n} words, code {min(k for k in words if k >= 0o100):o}-{max(words):o} (octal)")


if __name__ == '__main__':
    main()
