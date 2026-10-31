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

### Rules (ours where the sources stop)

- 128 words, direct-mapped by address bits 6:0, in block RAM. The window is
  [lower bound, lower bound + 127]: an address is shadowed when
  `(address - lower bound) < 128` unsigned.
- Accesses to shadowed virtual addresses go to the cache: no translation,
  no page fault, no transport trap, no modified or ephemeral bits. Pushes and
  operand references (FP, LP and SP relative) write the cache only. Memory
  cycles (`%memory-write`, block writes, rplaca and the rest: everything
  that takes an address from a pointer) write the cache and memory. Accesses
  outside the window go to memory as before, pushes included (so a stack
  that software hasn't mapped into the cache still works).
- Overflow: after a push, when SP bits 6:2 equal the overflow limit's, the
  cache is dumped: the `quantum` lowest words, from the lower bound up, are
  written to memory (raw writes through the MMU), and the lower bound and
  the overflow limit both rise by the quantum. The quantum is the low bits
  of the dump-quantum register (01031, in the microcode's scratchpad range),
  which resets to 32 and is 32 if software writes 0 or more than 128 there
  (the chip's value isn't documented; Genera's invariant `limit = lower
  bound + 112` holds for any). A push outside the window never dumps. A
  fault during the dump halts the processor: the spec says it cannot
  happen, because stacks are wired.
- Refill: when a return leaves FP below the lower bound, the words from the
  old lower bound - 1 down to FP are read from memory into the cache, the
  overflow limit falls by the same count, and the lower bound becomes FP.
  A fault during the refill halts the processor for now (the spec allows a
  trap with the PC at the caller's instruction; add it if Genera ever needs
  it).
- Reading the registers gives their current values; writing them sets them,
  nothing else (as Genera does: it sets the bound and the limit in an order
  that keeps the cache consistent).
- RTL: `sc_data` (one M10K, read combinationally from a registered address),
  `in_window`, the `mem_rd`/`mem_wr` tasks (a `through` flag on writes),
  `S_PUSH` (one cycle in the window), `S_SC_DUMP*` and `S_SC_FILL*`; a
  fault during a dump or refill is halt code 11 on the debug line.

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
past it; the clock decision waits for step 5 on hardware and the
FrameThrower.

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
The `decode` task runs in the fetch cycle (`fetch` task, called
from `S_FETCH` and from `S_RETIRE`, whose cache lookup uses the next PC
through `fetch_pc`); the operand pre-read sets `sc_ra` in `decode` and
`opval` takes `sc_q` (`opv_pre`), or the immediate, in one cycle.

## Order of work

1. Stack cache, verified by a Genera boot, compile-file and fib on the
   MiSTer.
2. Instruction cache and prefetcher (same check).
3. TLB and the pipelined memory interface.
4. The pipeline.
5. Checks: block-transfer rates from *Internals*, fib and Gabriel against the
   XL1201 and the 3600, then the clock: the core should land near the real
   machine, not well past it; if it comes out clearly faster, the processor
   runs at the machine cycle instead of 50 MHz, nothing more elaborate. The
   working assumption (Oct 2026) is 30.75 MHz: the 61.5 MHz oscillator on the
   Merlin-II divided by two, as inferred for the MacIvory III; fib's
   instruction count against the XL1201's time gives 4.2 cycles an
   instruction at that rate, which fits the chip's pipeline.
