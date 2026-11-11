# The Ivory in the core

How the processor is being rebuilt to work the way the real chip does, the
sources for each structure, and the rules chosen where the sources stop.
The C++ model (`emu/`) is a reference for behaviour and instruction counts
only; it never shapes the RTL, and the RTL is verified on the MiSTer (and
with the free-running RTL simulation for a quick FEP boot).

## Sources

- Baker et al., "The Symbolics Ivory processor: a 40 bit tagged
  architecture Lisp microprocessor", ICCD 1987
  (`research/downloads/papers/1987-baker-symbolics-ivory-processor.pdf`).
- I-Machine Architecture Specification rev 2 (`research/downloads/bitsavers/I_Machine/`):
  memory cycles and the stack cache (2.3, pages 89-93), return (4.4, pages
  302-303), stack-group switching (4.8, pages 314-316), revision notes.
- Genera *Internals* (addendum): "Ivory Memory Operations".
- Genera 8.3 sources (`research/media/genera83/cd/sys.sct`): what the
  software expects of the hardware. `sys/istack.lisp` (stack-group switch),
  `gc/igc.lisp`, `storage/wired-esrt.lisp`, `debugger/itrap-dispatch.lisp`.
- Symbolics' VLM (`research/downloads/github/Lord-Nightmare_vlm`): an
  emulator with a 1792-word stack cache; its rules are its own, not the chip's.

## The chip (Baker 1987)

- Four pipeline stages. I: fetch the instruction, decode it, adjust the PC.
  D: fetch the first microinstruction, compute the operand address, adjust
  the stack pointer; branches are resolved here. E: fetch the operands and
  compute the result; any number of cycles. W: store the result, unless a
  fault occurred, in which case restore the state of E.
- Instructions spend one cycle in I and D; push, add and eq execute in one
  cycle.
- A 32-word (up to 64 instructions) direct-mapped instruction cache, filled
  by an autonomous prefetcher.
- A 128-word top-of-stack cache; a 32-word scratchpad holding, among other
  things, a duplicate of the top word of the stack in a fixed location.
- Tag checking in parallel with the ALU; ECC checking of data from memory in
  parallel with the ALU; bypass paths from the top-of-stack cache and the
  scratchpad to the ALU.
- A 16-entry fully associative translation cache, maintained by microcode
  with hardware to search the translation tables and pick the entry to
  replace.
- A pipelined memory bus with up to four outstanding requests; an associative
  queue of outstanding request addresses tells arriving instruction words
  apart for installation in the instruction cache.
- Microcode: 1200 words x 180 bits, reading 8 words in parallel for a late
  1-of-4 select on the ALU condition.
- Integer multiply and divide one bit per cycle.

## Stack cache

### What software expects (Genera 8.3)

- `%register-stack-cache-lower-bound` (5) is the lowest address the cache
  shadows. `sys/istack.lisp` sets it to SP+1 before block-reading the new
  stack group's frame into the cache ("so that the following block-reads
  will neither read from the stack cache nor cause it to overflow") and to FP
  afterwards.
- `%register-stack-cache-overflow-limit` (034): `istack.lisp`: "The stack
  cache overflow check is (= D.SP<6:2> stack-cache-overflow-limit)". Genera
  sets it to FP + `control-stack-max-frame-size` right after setting the
  lower bound to FP, and in between picks a value "that will not cause an
  overflow with either the old or the new stack pointer".
- Writes to memory locations in the cache write through (spec 4.8: that is
  how the stack-group switch dumps the cache: block-read and block-write at
  identical addresses from the lower bound to FP, "after the above function
  calls so that the microcode has a chance to do it for us"). Pushes don't
  write through: otherwise no dump would be needed.
- Memory operations on addresses the cache shadows read and write the cache
  (spec 2.3); DTP-PHYSICAL-ADDRESS accesses never touch it. Shadowing is
  decided from the virtual address alone, in VMA=PMA space too.
- Return makes sure the caller's frame is in the cache, refilling it from
  memory in decreasing address order (spec 4.4).
- The GC scavenges [lower bound, FP) through block reads (`igc.lisp`);
  page-out skips the pages above the lower bound (`wired-esrt.lisp`). Both
  only need the lower bound consistent with memory.
- `%register-stack-cache-dump-quantum` (01031) is read into saved stack-group
  state only. Through a boot and login (model, 3.6G instructions) Genera
  never reads the limit or the quantum; it sets the limit to the lower bound
  + 112 at each of 67,000 stack-group switches; the FEP sets the lower bound
  1.8M instructions after reset, to its own frame, with the limit still 0.
- The stack-group switch writes FP (the new stack's SP + 1) before the
  lower bound, and pushes on the new stack in between; for that stretch it
  picks an overflow limit "that will not cause an overflow with either the
  old or the new stack pointer": the chip checks every push against the
  limit, wherever the stack pointer is.

### What the FEP expects (IFEP 333)

The FEP kernel has no source on the CD; this is its code, disassembled
(`tools/ivory.py`).  Three places write FP or the stack cache's registers:

- `INVOKE-ON-FEP-STACK` (F8015419), which every entry from Lisp goes
  through (`LISP-MODE-%HALT-TRAP-HANDLER` for `Halt Machine`): it saves the
  registers, then moves to the FEP's stack without copying its frame.  With
  the lower bound L and `*boot-stack-base*` B, the distance is D = (B with
  L's low 8 bits) - L, a multiple of 256.  It writes FP + D to FP, a no-op,
  `set-sp-to-address FP|4`, reads the lower bound (a push at the new SP),
  takes D again from its local `FP|4` and writes L + D to the lower bound;
  then the extra-stack limit.  So between the two writes a push, a pop and
  an FP-relative operand at the new addresses have to be the cache's words
  at the same low address bits: the frame never left the cache.  Then three
  loops over the words from the lower bound to its frame: block-read and
  block-write at the same new address (the cache's words into the FEP
  stack's memory, by write-through), block-read at the old addresses into
  an array (the Lisp stack's memory as it was), block-read at the new and
  block-write at the old (the cache into the Lisp stack's memory).  On the
  way back it subtracts D from FP and from the lower bound the same way
  and restores the registers.
- `%HALT` (F80155CC), the way back into the boot PROM: the lower bound and
  FP to F8000000, SP to FP + 1, then a jump to FFFE0040.

### Rules (ours where the sources stop)

- 128 words, direct-mapped by address bits 6:0, in block RAM. The window is
  [lower bound, lower bound + 127]: an address is shadowed when
  `(address - lower bound) < 128` unsigned.
- A memory cycle (`%memory-read`, `%memory-write`, block reads and writes,
  car, rplaca and the rest: everything that takes an address from a
  pointer; also the binding stack, catch blocks and `stack-blt`, whose
  addresses come from registers and locatives) is the cache's inside the
  window: no translation, no page fault, no transport trap, no modified or
  ephemeral bits; a write goes to the cache and to memory. Outside the
  window it is memory's.
- A stack reference (an FP, LP or SP relative operand, a push, a pop, the
  frame header a return reads) is the cache's word at address bits 6:0,
  wherever it points, and writes the cache only: the chip has no other
  place for one, and the FEP's move to its own stack depends on it (above).
  One exception, ours: in the 128 words under the window, [lower bound -
  128, lower bound), it goes to memory. Those are words a dump has taken
  from the frame that is running (the chip's dumps are not known to do
  that; ours can, below) and the values a return leaves under a raised
  bound before its refill. (Until Nov 10 2026 every stack reference
  outside the window went to memory, so the FEP read its locals from the
  boot stack's memory and `Halt Machine` ended in a processor fault.)
- Overflow: after a push to the cache, when SP bits 6:2 equal the overflow
  limit's, the cache is dumped: the `quantum` lowest words, from the lower
  bound up, are written to memory (raw writes through the MMU), and the
  lower bound and the overflow limit both rise by the quantum. The quantum
  is the low bits of the dump-quantum register (01031, in the microcode's
  scratchpad range), which resets to 32 and is 32 if software writes 0 or
  more than 128 there (the chip's value isn't documented; Genera's
  invariant `limit = lower bound + 112` holds for any). A push under the
  window, which is memory's, never dumps. A fault during the dump halts the
  processor: the spec says it cannot happen, because stacks are wired.
- Reset: the lower bound is the reset stack pointer (F8008000) and the
  limit 112 above it, an empty cache where the first push goes (the chip's
  reset values aren't documented; the boot PROM stand-in runs on that
  stack until it sets the bound to the FEP's frame).
- Refill: when a return leaves FP below the lower bound, the words from the
  old lower bound - 1 down to FP are read from memory into the cache, the
  overflow limit falls by the same count, and the lower bound becomes FP.
  It is the last thing the return does (spec 4.4), after the values are on
  the caller's stack: the refill moves the window down to [FP, FP + 127]
  and reuses the slots of the words above it, so values still in the
  callee's frame above FP + 127 would be lost (and read back from memory,
  which never had them) if the refill came first.
  A fault during the refill halts the processor for now (the spec allows a
  trap with the PC at the caller's instruction; add it if Genera ever needs
  it).
- Reading the registers gives their current values; writing them sets them,
  nothing else (as Genera does: it sets the bound and the limit in an order
  that keeps the cache consistent).
- RTL: `sc_data` (one M10K, read combinationally from a registered address),
  `stk_cached` and `m_cached`, the `mem_rd`/`mem_wr` tasks (a `through`
  flag on writes; `fread`/`fwrite` for a stack reference, `sread`/`swrite`
  for an address from a register), `S_PUSH` (one cycle in the cache),
  `S_SC_DUMP*` and `S_SC_FILL*`; a fault during a dump or refill is halt
  code 11 on the debug line.
- The model (`emu/`) keeps the stack in memory and has no cache. It moves
  the lower bound and the limit as the RTL does (a push at the limit, a
  return under the bound), and for the stretch between a write of FP away
  from the window and the next write of the lower bound it answers stack
  references there by slot (`sread`/`swrite` in `emu/cpu.h`): the word
  written since, else the old window's word in memory; the lower bound's
  write then copies the slots to memory under the new window.

### Measured

Two thirds of the old core's cycles were memory waits of ~7 cycles, most of
them stack accesses; a push is now one cycle, a pop or an operand fetch
two. On the MiSTer (build 10, Oct 30 2026) Genera 8.3 boots and `(fib 30)`
takes 9.33 s against 17.50 s before: 15.5 cycles an instruction instead of
29.3, 1.88x. The Gabriel suite runs 1.24x (Div2 recursive) to 2.08x (Ctak)
faster, 1.65x for Triang, and its geometric mean against the 3600 goes from
1.41x to 2.31x; cycles an instruction 13 (Ctak) to 31 (Stak). The
free-running simulation of the FEP boot shows the same (3.1M instructions a
simulated second against 1.7M).

## Instruction cache and prefetcher

### What software expects (Genera 8.3)

- `%register-icache-control` (024): bit 0 enables the cache.
  `%clear-instruction-cache` (`sys/iprim.lisp`) clears the enable bit and
  sets it again, with traps off; Genera does that itself when it creates
  compiled functions, so the chip's cache isn't kept coherent with stores.
- `%register-prefetcher-control` (025): bit 0 enables the prefetcher, bits
  4:1 are the low mark (sign-extended), bits 8:5 the high mark
  (`i-sys/sysdef.lisp`; `sys/wired.lisp` runs the microcode checksum with
  high mark 7, low mark 0, enabled).
- Through a boot and login in the model, neither the FEP nor Genera writes
  the icache control register, and Genera writes the prefetcher control
  only twice: 0xFD (enabled, high mark 7, low mark field 14) for the
  microcode checksum, then the saved old value back. So on the real machine
  both registers hold whatever the boot PROM left (ours is a stand-in): the
  core resets icache control to 1 (enabled; `%clear-instruction-cache`
  would be a no-op otherwise) and prefetcher control to 0xFD, the one value
  Genera itself uses. The model resets them the same way.
- The spec's data-types chapter: the last word of a compiled function has
  cdr code 1 as a fence, "to avoid loading the instruction cache with
  extraneous words from functions other than the one being executed", and
  the prefetcher "faults crossing page boundaries" (rev notes), so it stops
  at the end of a page.

### Rules

- 32 words direct-mapped by word address bits 4:0, tagged by the rest of
  the virtual address, in flops; a hit answers the fetch in a cycle.
  Disabled (bit 0 clear): no hits, no fills, contents dropped; so a write
  of the register with bit 0 clear is the flush.
- A store invalidates the cached word at its address, and a prefetch in
  flight to it. Found the hard way: the FEP rewrites code in place
  (F8013125 during `Hello`) without writing the icache control register,
  and the core executed the old word; so the real chip must invalidate on
  stores, whatever the spec's note about stale words from prefetching past
  the free pointer means. Stores by physical address in VMA=PMA space are
  matched through their virtual alias; other physical stores aren't.
- A prefetch in flight keeps its own address: the processor's fill restarts
  the stream meanwhile (the same bug, found in the free-running bench by
  watching one word: the prefetched word was installed at the restarted
  stream's address).
- Measured with the TLB (build 12, Oct 30 2026): Genera boots on the
  MiSTer and `(fib 30)` takes 6.43 s (9.33 s with the stack cache alone):
  10.7 cycles an instruction, 2.72x the original core.
- The prefetcher fetches the words after the last instruction fetched,
  sequentially, while enabled, until it is high-mark words ahead of the PC,
  resuming once fewer than low-mark words are ahead; it stops at a word
  with cdr code 1 and at the end of the page. It uses physical addresses
  (the page's translation came with the instruction fetch), so it never
  touches the map cache or the PHT.
- It takes the memory port when the processor isn't using it.
- RTL: `ivory_icache` (the data in one M10K read from the processor's PC
  register, tags and valid bits in flops, the prefetch stream and its
  request); `ivory_mmu` exports the physical address of each access
  (`cpu_pa`); `ivory_core` gives the MMU's port to a prefetch from its
  request to its ack and holds the processor's request meanwhile; the
  processor's fetch takes `ic_hit`/`ic_word` or fetches from memory and
  installs the word (`ic_fill`). The instruction buffer that held the last
  fetched word, and its invalidations on stores and coprocessor
  operations, are gone: the cache replaces it.

## Translation cache and memory interface

### What software expects

- The spec's map cache: entries loaded by the PHT search on a miss (age
  cleared in the PHT, `count-map-reloads` incremented), by the load-map
  registers, dropped by the invalidate-map registers and by writes of the
  PHT base, mask or map cache control. Genera reads `count-map-reloads` for
  metering only.
- The chip (Baker 1987): 16 entries, fully associative, replacement chosen
  by hardware.

### Rules

- The 4096-entry direct-mapped map cache (36 block RAMs) becomes the chip's
  16 fully associative entries in flops, compared against the request's
  page in the cycle the request arrives: a hit starts the bus access at
  once (the three lookup cycles go away); a miss runs the existing PHT
  search and fills the entry a round-robin pointer picks. A flush clears
  the 16 valid bits in one cycle instead of sweeping 4096 words.
- The bus to `xl_mem` stays one word a transaction for now; a request a
  cycle, with up to four in flight, comes with the pipeline, which is what
  can use it.
- Measured: see the instruction cache above (build 12 has both); the 4096
  words of map cache RAM are gone (block memory 61% to 54%) and the logic
  is 79% with the instruction cache's flops.

## Pipeline

The sequencer today spends five states on every instruction (fetch, fetch
wait, decode, execute dispatch, retire) and three more on an operand from
the stack cache (operand state, memory wait, done), before the
instruction's own states. The chip does I, D and E for consecutive
instructions in the same cycle. The rebuild, in steps that each boot
Genera:

1. Decode in the fetch cycle: on a cache hit the instruction word is decoded
   combinationally (opcode, operand, next PC), so fetch wait and decode go.
   The cache's data move from block RAM to flops (32 x 40) so the lookup can
   take the next PC straight from the retiring instruction.
2. Retire into fetch: the retiring instruction's last state advances the PC,
   counts, and looks the next instruction up in the same cycle; the retire
   state goes.
3. Operands from the stack cache ahead of execution: the operand address
   (FP, LP or SP relative) is computed in the fetch cycle and the cache read
   started, so the operand is in hand when the instruction's first state
   runs; the three operand states go for the common case.
4. The top of stack in a register (the chip's scratchpad keeps a copy of
   it) with bypass into the ALU, so push and pop and the stack-operand
   instructions don't wait on the cache RAM.
5. The one-cycle instructions (push, add, eq, branches, car/cdr on a hit)
   done in the fetch cycle itself where the operands allow, which is the
   chip's I/D/E overlap in state-machine form; everything else keeps its
   states, as the chip's E stage takes "an arbitrary number of cycles".

Traps mid-instruction keep working as now: an instruction that faults
restarts from its fetch with the architectural state untouched, which is
the chip's W-stage rule.

fib's instruction mix from the model (`XLEMU_OPSTATS`, 30.5M instructions
of `(fib 30)`): push 14%, then the full-word call, entry, finish-call,
return-single, branch-true, zerop and sub at 9% each, add 4%: a third of
the instructions are the call sequence, which is also where the real
chip's 4.2 cycles an instruction go.

Build 13 (steps 1-3) did not fit: 84% of the logic, and the fitter gave
up. SystemVerilog tasks inline at every call, so the stack cache's window
check inside `mem_rd`/`mem_wr` had ~70 copies through `sread`/`swrite`,
and the pipeline steps inlined fetch+decode twice. The cure is the chip's
organisation: one fetch+decode (S_FETCH and S_RETIRE share a case arm) and
one memory-access stage (every request registered into `m_*`, the window
check, cache access and bus issue in S_MEM_W alone, the bus request driven
combinationally from the registered request so memory accesses keep their
timing; the cache data duplicated in a second block RAM read by the
request address, the first keeping the operand pre-read and TOS reload).
With that in, the FEP boot simulation runs 96.0M instructions in the 14 s,
the same as before: the memory accesses kept their timing. Build 14 of it
fits: 80% of the logic, timing met with 0.6 ns of slack. On the MiSTer
(Oct 30 2026) Genera boots and `(fib 30)` takes 3.68 s: 6.1 cycles an
instruction, 4.76x the original core and 10% under the XL1201's 4.10 s.
The Gabriel suite's geometric mean against the 3600 is 4.73x (2.31x with
the stack cache alone; a real Ivory about 6x), unevenly: the stack- and
compute-bound benchmarks are at the real machine's ratio already (Deriv
6.9x, FFT 6.6x, Browse 6.3x, Destructive 6.0x, Stak 5.6x, Tak 5.4x), the
list- and memory-heavy ones lag (Triang 4.5x, Boyer 4.0x, Traverse 4.0x,
Ctak 3.9x, Div2 recursive 3.9x, Puzzle 1.8x): a DDR cache miss costs more
here than the Merlin-II's memory did. So on the broad suite the core is
still slower than the real XL1200 on average, and only fib-like code is
past it; the clock decision waits for step 5 on hardware.

Measured in the free-running simulation of the FEP boot (instructions in
14 simulated seconds; the stack cache, instruction cache and TLB alone:
57.7M, 12.1 cycles an instruction): step 1, 68.6M (10.2); step 2, 75.6M
(9.3); step 3, 86.7M (8.1); step 4, 96.0M (7.3); step 5, 105.3M (6.65).
Step 5 as built: `push_now` (a push into the stack cache in the current
state, S_PUSH otherwise) for push, zerop, the compares, the arithmetic
results and T; `pop_now` (the top-of-stack register popped in the current
state); push and binary arithmetic with their operands at hand done from
S_EXEC; the conditional branches decided in S_EXEC from the top-of-stack
register (`brc`). A trap in the first version: the popping compares did
`sp - 1` and `push` in one cycle, which S_PUSH honoured a cycle later and
`push_now` didn't; they now `write_tos`. Build 15 of that didn't fit
either (82%), so: `push_now` only in the four hot states (push from
S_EXEC, the arithmetic result, zerop, the compares), the `sp + 1` adder
and the overflow trigger as shared wires, and the instruction cache's
words back in block RAM, duplicated so the retire-cycle lookup reads from
`next_pc` and the ordinary one from `pc` (both registers); a word's data
lands a cycle after its tag, so a hit waits for it (a prefetched word can be
fetched that very cycle: found as a trap inside a trap). 103.1M (6.8).
Build 18 of it fits: 81% of the logic, 0.35 ns of slack. On the MiSTer
(Oct 30 2026): Genera boots, compile-file works, `(fib 30)` takes 3.06 s
(5.1 cycles an instruction; 5.7x the original core; the XL1201's 4.10 s),
and Gabriel's geometric mean against the 3600 is 4.97x (a real Ivory ~6x):
Tak 6.7x, FFT 7.4x, Deriv 6.9x, Destructive 6.5x, Browse 6.3x; Boyer 4.1x,
Traverse 4.4x, Ctak 4.2x, Div2 4.0x/3.8x, Puzzle 1.9x. The stack-bound
code is past the real machine by up to a quarter, the list- and
array-bound code still under it, so the processor clock stays at 50 MHz
for now (at 40 MHz the mean would be 4.0x, at 30.75 MHz 3.0x); the next
speed work is the memory path those benchmarks wait on.
The `decode` task runs in the fetch cycle (`fetch` task, called
from `S_FETCH` and from `S_RETIRE`, whose cache lookup uses the next PC
through `fetch_pc`); the operand pre-read sets `sc_ra` in `decode` and
`opval` takes `sc_q` (`opv_pre`), or the immediate, in one cycle.

## Memory path

The free-running bench profiles cycles by state (`PROFILE=1`). Build 18's
core on the FEP boot, 6.79 cycles an instruction: 30% in the memory-wait
state and 26% with the MMU waiting on the bus (a cached data read cost 4
cycles: the request cycle, the MMU's bus request, the DDR cache's lookup
state, the registered ack; the stack cache answers in 2), 15% the
retire/fetch cycle (one an instruction), 12% execute dispatch, 7% the push
state (calls, entries, trap frames), misses under 2%.

So: the DDR cache's RAMs are read from the requester's address, which is
the MMU's registered bus address, and a read hit is acknowledged in the
cycle the request appears with no state change (the write path keeps its
lookup state); the MMU passes that ack, the data and the physical address
straight through instead of registering them (traps and bus errors stay
registered). A cached read is then 2 cycles. FEP boot simulation: 117.3M
instructions in the 14 s, 5.97 cycles an instruction (6.79 before), the
memory-wait share 19% (30%). Then the cycle-typed reads and writes (car,
cdr, aref, rplaca, the block instructions: `mrd`/`mwr`) lost their two
states: the request is registered straight into the memory stage and the
data's check (`cycle_action`: a trap, an indirection or the result) runs
in the cycle the data arrives (`mem_got`). 123.8M instructions, 5.66
cycles an instruction.

Build 19 (two-cycle hits) didn't fit at 81%, the count build 18 fitted
at: that is the margin where placement luck decides, so more logic came
out instead of trying seeds. The processor is 17.8K of the 34K ALMs (the
FPA 2.5K, the I/O board 2.5K, the TLB 1.6K, MiSTer's framework ~7K), and
inside it every inlined call of the rotate, mask and ALU functions was a
barrel shifter of its own. Now there is one rotator, two field-mask
generators and one `%alu` (`rot_q`, `msk_q`, `msk2_q`, `alu_q`), with
their inputs loaded the cycle before: the pops and the memory stage load
the value, the dispatch arms the amounts; `%p-tag-ldb`, `%p-dpb` and
`%block-n-read-test` take a cycle more. Same instruction count in the FEP
boot simulation. Build 23 of all that (the two-cycle hits, the folded
checks, the shared units) on the MiSTer: `(fib 30)` 2.81 s (4.7 cycles an
instruction; the XL1201's 4.10 s), compile-file fine, Gabriel's geometric
mean 6.39x the 3600: Deriv 8.6x, Stak 8.5x, Browse 8.4x, FFT 8.3x, Tak
7.3x, Triang 6.7x, Traverse 6.5x; Boyer 5.3x, Div2 5.2x/5.0x, Ctak 4.8x,
Puzzle 2.4x. The suite's average is now a real Ivory's; the compute-bound
code is past it by up to 40% and the list- and array-bound code under it
by as much, so what is left of the speed work is evening those out (the
memory path), not more peak; the clock decision comes after that.

The array elements were the last inlined shifters: `aref-1`'s and
`fast-aref-1`'s extraction and `aset-1`'s insert go through the rotator
and masks too (`elem_units` arms them from the element's bit position and
width; a packed write takes a cycle more, like `%p-dpb`). The first cut
armed them in `aref-1`'s arm only and left `fast-aref-1`, the form
Genera's compiled code uses, reading the units stale, which blanked the
FEP's screen with no halt: the two array paths share their tail states
and must share their setup. Build 25 (79%, every clock met with 0.29 ns
to spare): `(fib 30)` 2.80 s, Gabriel 6.41x, Puzzle still 2.40x.

Puzzle turned out not to lag at all: the model counts 49M instructions a
call, so 4.60 s is the pipeline's 4.7 cycles an instruction, as fib, Tak
and Ctak; Genera 8.3's Puzzle just does more work than the 1985 one the
3600's time is for. Dividing the model's counts into build 25's times
puts the memory-bound benchmarks at Stak 10.7 cycles an instruction
(special binding: the binding stack and the value cell, three writes and
two reads a bind/unbind pair), Div2 recursive 10.4 (deep recursion: the
stack cache dumping and refilling), FFT 8.6, Boyer 7.9, Traverse 7.1
(list structure across the heap: misses) — the model's opcode histograms
of Boyer and Stak show stores at 7% and 14% of their instructions, and
every store went through to DDR3 one transaction at a time, four cycles
plus the controller's busy time, a stack-cache dump thirty-two of them in
a row.

So two changes to the DDR cache. The miss is answered with the word asked
for as its beat of the burst arrives, the rest of the line landing while
the processor goes on, instead of after the fourth beat and a state more:
build 26, Boyer, Traverse, Deriv and Dderiv 2-4% faster, Div2 recursive
5% slower (the prefetcher takes the port in the window the earlier
acknowledgement opens; to look at), geometric mean 6.45x. And writes are
posted: acknowledged in the cycle they appear, the cached word updated on
a hit, and queued (32 entries) for DDR3, which takes them while the memory
is idle; a read miss waits for the queue to drain so DDR3 has every write
first. A write is then two cycles like a cached read, and a dump streams.
Build 27: Stak 11% faster (9.4 cycles an instruction), Div2 recursive
13.5% (9.5), Div2 iterative 4.5%, Boyer and Browse 2%; Traverse 12.7%
slower (5.26 to 5.93 s), everything else within noise; geometric mean
6.55x. Traverse's graph fits the cache, so its loss is the queue itself:
every miss waited for the whole queue to drain, and a prefetch issued
while a line was still landing held the port. So the prefetcher waits for
the memory's busy signal (build 28), and a miss passes the queue unless a
queued write is to its line, the addresses in flops for the compare, 16
entries (build 29). Builds 28 and 29 both failed to route (the fitter
gives up from congestion at about 80% of the logic, by placement luck),
so the two went into one build with a third change, a valid bit per word
of a cache line so that a write installs its word instead of only
updating a hit (build 30). On the MiSTer (Oct 31 2026): Genera boots,
`(fib 30)` 2.80 s, geometric mean 6.56x, Traverse 5.93 s, every
benchmark within 4% of build 27. The three changes measured nothing, and
the memory-path work ends there; they stay in because they are verified,
and can be reverted if the logic is ever wanted. Build 31 is the same
RTL with the framework's YC/composite encoder and ALSA audio path
compiled out (`MISTER_DISABLE_YC`, `MISTER_DISABLE_ALSA` in the qsf,
540 ALMs): 32,941 ALMs, 79%, 0.25 ns of slack. The trim was for the
FrameThrower's headroom; with that dropped the YC encoder is back in
(the framework stays as shipped until the core is accurate and solid)
and only the ALSA path, which this core has no use for, stays out.

What is left is structural, not the cache. A Boyer profile in the
free-running simulation (6.3 cycles an instruction over 540M
instructions) has the processor in S_MEM_W 37% of the cycles, S_RETIRE
16% and S_EXEC 13%, with the DDR cache idle 81% of the time: the wait is
latency a miss, not bandwidth, and the rest is the state machine's fixed
steps an instruction, which a pipeline would overlap. Neither is touched
by miss-path tuning.

The clock, then. The microsecond clock became a fractional divider (a
million added a cycle, a tick when the sum passes the rate) so the
processor can run at any rate, and 30.77 MHz (1200/39, the closest to
the Merlin-II's 61.5 MHz halved that shares a PLL with the 80 MHz dot
clock) and 35 MHz (fib 2.5% under the XL1201's time) were built. Both
were dropped before measuring: the rule settled on (Oct 31 2026) is no
part of the machine slower than the real one, faster allowed, and at
50 MHz the list-bound benchmarks already sit at or under a real Ivory's
~6x (Boyer 5.5x, Div2 5.2x, Traverse 6.0x) while fib is 2.80 s against
4.10 s. A slower clock scales those down with everything else (a DDR
miss is nanoseconds, so a little less than linearly). So the clock stays
at 50 MHz; what is left of the speed work is lifting the list-bound code
to the real machine (the memory latency: structural), after the
compatibility pass, and the clock is chosen after that.

## Order of work

1. Stack cache, verified by a Genera boot, compile-file and fib on the
   MiSTer.
2. Instruction cache and prefetcher (same check).
3. TLB and the pipelined memory interface.
4. The pipeline.
5. Checks: block-transfer rates from *Internals*, fib and Gabriel against the
   XL1201 and the 3600, then the clock: no part of the machine slower than
   the real one, faster allowed; once the list-bound code is at the real
   machine's pace, a clock that keeps it there, nothing more elaborate.
   The chip's own rate is assumed to be 30.75 MHz: the 61.5 MHz oscillator
   on the Merlin-II divided by two, as inferred for the MacIvory III; fib's
   instruction count against the XL1201's time gives 4.2 cycles an
   instruction at that rate, which fits the chip's pipeline.

## Arrays on physical addresses

An array register's base is a locative, or a physical address when the
array is indirected to a device (spec 3.4, "Representation of Physical
Addresses": "it is here that a fast-aref-1/aset-1 instruction will
encounter a dtp-physical-address"). `fast-aref-1` and `fast-aset-1` make
their element references with the base's type, so a bus array (Genera's
`sys:make-bus-array`, every VMEbus raster of the Color system) is read and
written on the bus; before Nov 2 2026 the core made them locatives and the
access took a page fault on the physical address as a virtual one. Nothing
in a plain Genera 8.3 boot, the console, the disk or the network uses such
arrays (those go through `%memory-read`, `%p-ldb` and block address
registers, which always handled physical addresses).
