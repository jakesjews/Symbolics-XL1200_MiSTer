// Ivory CPU model: memory system, traps, function calling.
#include "cpu.h"
#include <cstdio>
#include <cstring>
#include <cstdlib>

Ivory::Ivory(Bus* b) : bus(b) {
  flush_map();
  // Internal registers come up holding fixnum zero.
  for (W* r : {&event_count, &binding_stack_pointer, &catch_block_list, &control_stack_limit,
               &control_stack_extra_limit, &binding_stack_limit, &count_map_reloads,
               &list_cache_area, &list_cache_address, &list_cache_length, &structure_cache_area,
               &structure_cache_address, &structure_cache_length, &dynamic_binding_cache_base,
               &dynamic_binding_cache_mask, &choice_pointer, &structure_stack_choice_pointer,
               &fep_mode_trap_vector_address, &mapping_table_cache, &mapping_table_length,
               &stack_frame_maximum_size, &stack_cache_dump_quantum, &bar[0], &bar[1], &bar[2], &bar[3]})
    *r = fixnum(0);
  for (W& r : scratch) r = fixnum(0);
}

void Ivory::flush_map() {
  for (auto& e : map) e.vpn = 0xFFFFFFFFu;
}

void Ivory::init() {
  pc = (uint64_t)INIT_PC_VMA << 1;
  cr = (uint32_t)TM_FEP << CR_TRAP_MODE_SHIFT;
  sp = 0xF8000000u + 0100000;   // %INIT-SP (VMA=PMA 10000 octal); the boot code sets its own
  fp = lp = sp;
  cont = 0;
  preempt_register = 0;
  ib_valid = false;
  flush_map();
  halted = false;
}

void Ivory::halt(const std::string& why) {
  halted = true;
  halt_reason = why;
  throw ProcessorHalt{why};
}

// ---------------------------------------------------------------------------
// Address translation
// ---------------------------------------------------------------------------

// PHT hash box (I-Machine Architecture Specification, 2.3.2).  Output is a
// word offset (bucket number << 3).
uint32_t Ivory::pht_hash(uint32_t vpn) {
  uint32_t vma = vpn << 8;
  auto b = [&](int n) { return (vma >> n) & 1u; };
  static const int pairs[][2] = {
    {12, 27}, {11, 28}, {10, 29}, {9, 30}, {8, 31}, {13, 20}, {14, 22}, {15, 21},
    {16, 26}, {17, 25}, {18, 24}, {19, 23}, {12, 16}, {11, 17}, {10, 18}, {9, 19},
    {8, 20}, {13, 25}, {14, 26}, {15, 27}, {21, 31}, {22, 30}, {23, 29}};
  uint32_t h = 0;
  for (int i = 0; i < 23; i++) h |= (b(pairs[i][0]) ^ b(pairs[i][1])) << (3 + i);
  return h;
}

MapEntry* Ivory::map_lookup(uint32_t vpn) {
  MapEntry* e = &map[vpn & (MAP_SIZE - 1)];
  return e->vpn == vpn ? e : nullptr;
}

// Search the PHT for VMA's page and load the map cache.  Takes the
// page-not-resident or page-fault-request trap if it is not there.
MapEntry* Ivory::map_fill(uint32_t vma) {
  uint32_t vpn = vma >> 8;
  auto search = [&](uint32_t off, MapEntry*& out) -> bool {
    uint32_t a = pht_base + off;
    W e0 = 0;
    for (int i = 0; i < 4; i++, a += 2) {
      e0 = bus->phys_read(a);
      if ((wdata(e0) >> 8) == vpn) {
        if (wdata(e0) & 0x80) memory_trap(TV_PAGE_FAULT_REQUEST, mkw(DTP_LOCATIVE, vma));
        W e1 = bus->phys_read(a + 1);
        if (wdata(e0) & 0xF) bus->phys_write(a, e0 & ~(W)0xF);   // clear age
        MapEntry* m = &map[vpn & (MAP_SIZE - 1)];
        m->vpn = vpn;
        m->ppn = wdata(e1) >> 8;
        m->access = wdata(e1) & 0xFF;
        m->pht_addr = a;
        if (log_errors && m->ppn >= 0x4000)
          fprintf(stderr, "[cpu] PHT maps vma %08x to ppn %06x: PHT0 %02o:%08x PHT1 %02o:%08x at %08x insn %llu\n",
                  vma, m->ppn, wtag(e0), wdata(e0), wtag(e1), wdata(e1), a, (unsigned long long)icount);
        count_map_reloads = fixnum(wdata(count_map_reloads) + 1);
        out = m;
        return true;
      }
    }
    if ((e0 >> 38) & 1) memory_trap(TV_PAGE_NOT_RESIDENT, mkw(DTP_LOCATIVE, vma));
    return false;
  };
  MapEntry* out = nullptr;
  if (search(pht_hash(vpn) & pht_mask, out)) return out;
  uint32_t state = vpn;
  for (int guard = 0; guard < (1 << 24); guard++) {
    state = (state << 4) + state + 1;        // 17x + 1
    // The next bucket is state<24:0>: the mask's top four bits are don't-cares
    // (storage/i-storage-defs.lisp, SEARCH-PHT).
    if (search(((state & 0x1FFFFFF) << 3) & pht_mask, out)) return out;
  }
  char why[96];
  snprintf(why, sizeof why, "PHT search did not terminate (vma %08x, PHT base %08x mask %08x)", vma, pht_base,
           pht_mask);
  halt(why);
}

// Record the effects of a write on the page's PHT entry (modified and
// ephemeral-reference bits are maintained write-through).
void Ivory::note_write(MapEntry* e, W data) {
  uint32_t need = 0x80;   // modified
  int t = wtype(data);
  if (is_pointer_type(t) && (wdata(data) >> 27) == 0)
    need |= 1u << ((wdata(data) >> 24) & 3);   // ephemeral group
  if ((e->access & need) != need) {
    e->access |= need;
    W e1 = bus->phys_read(e->pht_addr + 1);
    bus->phys_write(e->pht_addr + 1, e1 | need);
  }
}

uint32_t Ivory::translate(uint32_t vma, bool write, W* data) {
  last_vma = vma;
  if (vma >= VMA_PMA_BASE) return vma - VMA_PMA_BASE;
  uint32_t vpn = vma >> 8;
  MapEntry* e = map_lookup(vpn);
  if (!e) e = map_fill(vma);
  if (write) {
    if (e->access & 0x40) memory_trap(TV_PAGE_WRITE_FAULT, mkw(DTP_LOCATIVE, vma));
    note_write(e, data ? *data : 0);
  }
  return (e->ppn << 8) | (vma & 0xFF);
}

bool Ivory::debug_translate(uint32_t vma, uint32_t& pa) {
  if (vma >= VMA_PMA_BASE) { pa = vma - VMA_PMA_BASE; return true; }
  MapEntry* e = map_lookup(vma >> 8);
  if (e) { pa = (e->ppn << 8) | (vma & 0xFF); return true; }
  if (!pht_mask) return false;
  // walk the PHT without side effects
  uint32_t vpn = vma >> 8;
  auto search = [&](uint32_t off) -> int {
    uint32_t a = pht_base + off;
    W e0 = 0;
    for (int i = 0; i < 4; i++, a += 2) {
      e0 = bus->phys_read(a);
      if ((wdata(e0) >> 8) == vpn) { pa = ((wdata(bus->phys_read(a + 1)) >> 8) << 8) | (vma & 0xFF); return 1; }
    }
    return ((e0 >> 38) & 1) ? -1 : 0;
  };
  int r = search(pht_hash(vpn) & pht_mask);
  uint32_t state = vpn;
  for (int g = 0; r == 0 && g < 100000; g++) { state = (state << 4) + state + 1; r = search(((state & 0x1FFFFFF) << 3) & pht_mask); }
  return r == 1;
}

W Ivory::debug_read(uint32_t vma) {
  uint32_t pa;
  if (!debug_translate(vma, pa)) return 0;
  return bus->phys_read(pa);
}

bool Ivory::oldspace_address(uint32_t a) {
  int zone = a >> 27;
  if (zone == 0) {
    int level = (a >> 21) & 31, half = (a >> 26) & 1;
    return half == (int)((ephemeral_oldspace >> level) & 1);
  }
  return (zone_oldspace >> zone) & 1;
}

bool Ivory::page_transport_enabled(uint32_t vma) {
  if (vma >= VMA_PMA_BASE) return false;
  MapEntry* e = map_lookup(vma >> 8);
  if (!e) e = map_fill(vma);
  return (e->access & 0x10) != 0;
}

W Ivory::read_raw(uint32_t vma) { return bus->phys_read(translate(vma, false)); }
void Ivory::write_raw(uint32_t vma, W w) {
  cpu_write(vma);
  bus->phys_write(translate(vma, true, &w), w);
}

W Ivory::read_addr(W addr) {
  if (wtype(addr) == DTP_PHYSICAL_ADDRESS) return bus->phys_read(wdata(addr));
  return read_raw(wdata(addr));
}
void Ivory::write_addr(W addr, W w) {
  if (wtype(addr) == DTP_PHYSICAL_ADDRESS) { cpu_write(wdata(addr)); bus->phys_write(wdata(addr), w); return; }
  write_raw(wdata(addr), w);
}

W Ivory::fetch_word(uint32_t vma) { return read_raw(vma); }

// Memory-cycle actions (I-Machine Architecture Specification, Table 13).
enum { A_NONE = 0, A_IND = 1, A_TRAP = 2, A_MTRAP = 3, A_TRANS = 4 };
// columns: data null header hfwd efwd 1fwd evcp gc monitor pointer(transport enable)
static const uint8_t cycle_actions[CYC_COUNT][10] = {
  /* data-read      */ {0, A_TRAP, A_TRAP, A_IND, A_IND, A_IND, A_IND, A_TRAP, A_MTRAP, A_TRANS},
  /* data-write     */ {0, 0,      A_TRAP, A_IND, A_IND, A_IND, A_IND, A_TRAP, A_MTRAP, 0},
  /* bind-read      */ {0, 0,      A_TRAP, A_IND, A_IND, A_IND, 0,     A_TRAP, A_MTRAP, A_TRANS},
  /* bind-write     */ {0, 0,      A_TRAP, A_IND, A_IND, A_IND, 0,     A_TRAP, A_MTRAP, 0},
  /* bind-read-nm   */ {0, 0,      A_TRAP, A_IND, A_IND, A_IND, 0,     A_TRAP, A_IND,   A_TRANS},
  /* bind-write-nm  */ {0, 0,      A_TRAP, A_IND, A_IND, A_IND, 0,     A_TRAP, A_IND,   0},
  /* header         */ {A_TRAP, A_TRAP, 0, A_IND, A_TRAP, A_TRAP, A_TRAP, A_TRAP, A_TRAP, A_TRANS},
  /* struct-offset  */ {0, 0,      0,      A_IND, 0,     0,     0,     A_TRAP, 0,       0},
  /* scavenge       */ {0, 0,      0,      0,     0,     0,     0,     A_TRAP, 0,       A_TRANS},
  /* cdr            */ {0, 0,      A_TRAP, A_IND, A_IND, 0,     0,     A_TRAP, 0,       0},
  /* gc-copy        */ {0, 0,      0,      0,     0,     0,     0,     A_TRAP, 0,       0},
  /* raw            */ {0, 0,      0,      0,     0,     0,     0,     0,      0,       0},
  /* raw-translate  */ {0, 0,      0,      0,     0,     0,     0,     0,      0,       0},
};

static int action_column(int t) {
  switch (t) {
  case DTP_NULL: return 1;
  case DTP_HEADER_P: case DTP_HEADER_I: return 2;
  case DTP_HEADER_FORWARD: return 3;
  case DTP_ELEMENT_FORWARD: return 4;
  case DTP_ONE_Q_FORWARD: return 5;
  case DTP_EXTERNAL_VALUE_CELL_POINTER: return 6;
  case DTP_GC_FORWARD: return 7;
  case DTP_MONITOR_FORWARD: return 8;
  default: return 0;
  }
}

// Memory read with the forwarding/trapping behavior of the given cycle type.
// ADDR is a locative-like word (any pointer type) or a dtp-physical-address.
W Ivory::mem_read(W addr, int cycle, uint32_t* final_vma) {
  bool physical = wtype(addr) == DTP_PHYSICAL_ADDRESS;
  uint32_t a = wdata(addr);
  for (int hops = 0;; hops++) {
    W w = physical ? bus->phys_read(a) : read_raw(a);
    int t = wtype(w);
    int act = cycle_actions[cycle][action_column(t)];
    if (act == A_TRAP) {
      if (final_vma) *final_vma = a;
      err_detail = cycle;
      error_trap(E_MEMORY_DATA_ERROR, a);
    }
    // ind and mtrp enable the transport check in every cycle type (Table 13);
    // the transport trap takes precedence over the monitor trap.
    bool can_transport = act == A_IND || act == A_MTRAP ||
        (cycle_actions[cycle][9] == A_TRANS && is_pointer_type(t) && t != DTP_NULL);
    if (can_transport && !physical && oldspace_address(wdata(w)) && page_transport_enabled(a))
      memory_trap(TV_TRANSPORT, mkw(DTP_LOCATIVE, a));
    if (act == A_MTRAP) memory_trap(TV_MONITOR, mkw(DTP_LOCATIVE, a));
    if (act == A_IND) {
      a = wdata(w);
      physical = false;
      if (hops > 100000) halt("forwarding loop");
      continue;
    }
    if (final_vma) *final_vma = a;
    return w;
  }
}

// Memory write: follows forwarding per the cycle type, then stores VALUE,
// preserving the destination cdr code unless told otherwise.
void Ivory::mem_write(W addr, int cycle, W value, bool preserve_cdr) {
  bool physical = wtype(addr) == DTP_PHYSICAL_ADDRESS;
  uint32_t a = wdata(addr);
  for (int hops = 0;; hops++) {
    W old = physical ? bus->phys_read(a) : read_raw(a);
    int t = wtype(old);
    int act = cycle_actions[cycle][action_column(t)];
    if (act == A_TRAP) { err_detail = cycle; error_trap(E_MEMORY_DATA_ERROR, a); }
    // Forwarding/monitor pointers are checked for oldspace before indirection;
    // the final location being replaced is not transported.
    if ((act == A_IND || act == A_MTRAP) && !physical && oldspace_address(wdata(old)) &&
        page_transport_enabled(a))
      memory_trap(TV_TRANSPORT, mkw(DTP_LOCATIVE, a));
    if (act == A_MTRAP) memory_trap(TV_MONITOR, mkw(DTP_LOCATIVE, a));
    if (act == A_IND) {
      a = wdata(old);
      physical = false;
      if (hops > 100000) halt("forwarding loop");
      continue;
    }
    W nw = preserve_cdr ? ((stripcdr(value)) | (old & ((W)3 << 38))) : value;
    if (physical) { cpu_write(a); bus->phys_write(a, nw); } else write_raw(a, nw);
    return;
  }
}

// ---------------------------------------------------------------------------
// Traps
// ---------------------------------------------------------------------------

// Rev-5 microstate -> a rev-4 microstate with the same trap descriptor in
// Genera's DBG:*TRAP-DISPATCH-TABLES* (tools/errortable.py).
static const uint16_t rev4_microstate[85] = {
    0, 1828, 1820, 1872, 1876, 71, 1288, 152, 1832, 1824, 1848, 1840,
    160, 159, 1466, 87, 1544, 1664, 1044, 2007, 1997, 71, 71, 71,
    1423, 72, 1214, 2020, 1508, 69, 1369, 2043, 155, 68, 1899, 1903,
    181, 1035, 286, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 143, 1782, 1982, 86, 143, 71, 71, 71, 71, 71, 71,
    71, 77, 78, 1288, 1032, 1044, 1044, 1210, 1312, 1320, 1214, 1036,
    122, 1616, 143, 1414, 1186, 52, 1555, 1225, 1600, 1136, 1088, 1060,
    143,
};

int Ivory::error_microstate(int cond) {
  int m = rev5_microstate(cond);
  return chip_revision == 4 ? rev4_microstate[m] : m;
}

int Ivory::rev5_microstate(int cond) {
  // Genera looks the microstate up in the chip-revision error table.  This is
  // the rev-5 (VLM) numbering, (1+ (position condition *all-conditions*)) from
  // vlm emulator/errortbl.lisp (= SYS:I-SYS;REV5-ERROR-TABLE).  Our condition
  // list matches it except that the table splits two conditions by detail.
  int detail = err_detail;
  err_detail = -1;
  if (cond <= E_I_STAGE) return cond;
  if (cond == E_ILLEGAL_FULL_WORD_INSTRUCTION) {
    static const int types[] = {DTP_BOUND_LOCATION, DTP_ELEMENT_FORWARD, DTP_GC_FORWARD, DTP_HEADER_FORWARD,
                                DTP_HEADER_I, DTP_HEADER_P, DTP_LOGIC_VARIABLE, DTP_MONITOR_FORWARD,
                                DTP_NULL, DTP_ONE_Q_FORWARD};
    for (int i = 0; i < 10; i++) if (types[i] == detail) return 39 + i;
    return 39;
  }
  if (cond < E_MEMORY_DATA_ERROR) return cond + 9;
  if (cond == E_MEMORY_DATA_ERROR) {
    switch (detail) {   // bind-read, bind-write, cdr-read, data-read, data-write, header-read, scavenge
    case CYC_BIND_READ: case CYC_BIND_READ_NO_MONITOR: return 54;
    case CYC_BIND_WRITE: case CYC_BIND_WRITE_NO_MONITOR: return 55;
    case CYC_CDR: return 56;
    case CYC_DATA_WRITE: return 58;
    case CYC_HEADER: case CYC_STRUCTURE_OFFSET: return 59;
    case CYC_SCAVENGE: case CYC_GC_COPY: return 60;
    default: return 57;   // data-read
    }
  }
  return cond + 15;
}

W Ivory::trap_vector_entry(int vector) {
  static int depth = 0;
  if (depth > 0) {
    char buf[80];
    snprintf(buf, sizeof buf, "recursive trap (vector %o) while fetching trap vector", vector);
    depth = 0;
    halt(buf);
  }
  struct Guard { int& d; Guard(int& x) : d(x) { d++; } ~Guard() { d--; } } guard(depth);
  int mode = cr >> CR_TRAP_MODE_SHIFT;
  uint32_t a = (mode == TM_FEP) ? wdata(fep_mode_trap_vector_address) : TRAP_VECTOR_BASE + vector;
  uint32_t savecr = cr;
  cr |= 3u << CR_TRAP_MODE_SHIFT;
  W e = mem_read(mkw(DTP_LOCATIVE, a), CYC_DATA_READ);
  cr = savecr;
  if (wtype(e) != DTP_EVEN_PC && wtype(e) != DTP_ODD_PC) {
    char buf[96];
    snprintf(buf, sizeof buf, "bad trap vector entry %o @%08x (vector %o)", wtag(e), a, vector);
    halt(buf);
  }
  return e;
}

void Ivory::check_stack_overflow() {
  int mode = cr >> CR_TRAP_MODE_SHIFT;
  uint32_t limit = mode == TM_EMULATOR ? wdata(control_stack_limit) : wdata(control_stack_extra_limit);
  if (sp >= limit && limit != 0) {   // VLM: overflow unless SP < limit
    if (mode == TM_EMULATOR) {
      // Taken after the finish-call: a pre-trap in the first instruction of the callee.
      restart_sp = sp;
      inst_pc = pc;
      take_pre_trap(TV_STACK_OVERFLOW, 0, nullptr);
      throw InstructionAbort{};
    }
    halt("stack overflow in extra-stack mode");
  }
}

// Finish building a trap frame whose header starts at FP (already pushed),
// and transfer to HANDLER.
void Ivory::enter_trap_frame(int vector, uint32_t old_fp, W handler, uint64_t continuation_pc) {
  (void)vector;
  lp = sp + 1;
  uint32_t argsize = lp - fp;
  uint32_t mode = cr >> CR_TRAP_MODE_SHIFT;
  uint32_t hmode = wcdr(handler);
  if (hmode > mode) mode = hmode;
  uint32_t ncr = cr & ~0x074FFFFFu & ~(7u << 27);   // fccrtrapmask
  ncr &= ~(3u << CR_TRAP_MODE_SHIFT);
  ncr |= mode << CR_TRAP_MODE_SHIFT;
  ncr |= (uint32_t)VD_VALUE << CR_VALUE_DISPOSITION_SHIFT;
  ncr |= argsize & 0xFF;
  ncr |= ((fp - old_fp) & 0xFF) << CR_CALLER_FRAME_SIZE_SHIFT;
  cr = ncr;
  cont = pc_word(continuation_pc);
  pc = ((uint64_t)wdata(handler) << 1) | (wtype(handler) == DTP_ODD_PC ? 1 : 0);
  pc_changed = true;
  trap_count++;
  last_trap_vector = vector;
  check_stack_overflow();
}

// A trap taken while pushing another trap's frame (e.g. the stack page isn't
// mapped) would recurse forever; the processor halts.
void Ivory::begin_trap_frame(int vector) {
  if (pushing_trap_frame) {
    char why[64];
    snprintf(why, sizeof why, "trap %o while pushing a trap frame", vector);
    halt(why);
  }
  pushing_trap_frame = true;
}

void Ivory::take_pre_trap(int vector, int nargs, const W* args) {
  begin_trap_frame(vector);
  W handler = trap_vector_entry(vector);
  sp = restart_sp;
  uint32_t old_fp = fp;
  push_raw(setcdr(cont, 3));
  push_raw(mkwc(3, DTP_FIXNUM, cr));
  fp = sp - 1;
  push(fixnum(vector));
  push(pc_word(inst_pc));
  for (int i = 0; i < nargs; i++) push(args[i]);
  pushing_trap_frame = false;
  enter_trap_frame(vector, old_fp, handler, inst_pc);
}

void Ivory::take_post_trap(int vector, int nargs, const W* args, uint64_t ret_pc) {
  begin_trap_frame(vector);
  W handler = trap_vector_entry(vector);
  uint32_t old_fp = fp;
  uint32_t savedcr = cr;
  if (cr & CR_INSTRUCTION_TRACE) savedcr |= CR_TRACE_PENDING;
  push_raw(setcdr(cont, 3));
  push_raw(mkwc(3, DTP_FIXNUM, savedcr));
  fp = sp - 1;
  push(fixnum(vector));
  push(pc_word(inst_pc));
  for (int i = 0; i < nargs; i++) push(args[i]);
  pushing_trap_frame = false;
  enter_trap_frame(vector, old_fp, handler, ret_pc);
}

void Ivory::error_trap(int cond, uint32_t vma) {
  W args[2] = {fixnum(error_microstate(cond)), mkw(DTP_LOCATIVE, vma)};
  if (trace && tracef) fprintf(tracef, "  ERROR TRAP cond=%d vma=%08x\n", cond, vma);
  if (log_errors)
    fprintf(stderr, "[cpu] error trap cond=%d vma=%08x pc=%08x.%d insn=%llu bsp=%02o:%08x bsl=%02o:%08x\n", cond,
            vma, (uint32_t)(pc >> 1), (int)(pc & 1), (unsigned long long)icount, wtype(binding_stack_pointer),
            wdata(binding_stack_pointer), wtype(binding_stack_limit), wdata(binding_stack_limit));
  take_pre_trap(TV_ERROR, 2, args);
  throw InstructionAbort{};
}

void Ivory::memory_trap(int vector, W vma) {
  if (trace && tracef) fprintf(tracef, "  MEMORY TRAP %o vma=%08x\n", vector, wdata(vma));
  if (log_errors && vector == TV_PAGE_NOT_RESIDENT && fault_log++ < 2000)
    fprintf(stderr, "[cpu] page not resident %08x at pc %08x.%d insn %llu sp %08x\n", wdata(vma),
            (uint32_t)(pc >> 1), (int)(pc & 1), (unsigned long long)icount, sp);
  take_pre_trap(vector, 1, &vma);
  throw InstructionAbort{};
}

void Ivory::post_trap(int vector, int nargs, const W* args, uint64_t ret_pc) {
  take_post_trap(vector, nargs, args, ret_pc);
  throw InstructionAbort{};
}

// Instruction exception: arguments have already been popped by the caller.
void Ivory::instruction_exception(int nargs, const W* args) {
  if (trace && tracef) fprintf(tracef, "  INSN EXCEPTION op=%o\n", cur_opcode);
  post_trap(TV_INSTRUCTION_EXCEPTION + cur_opcode, nargs, args, next_pc);
}

// Arithmetic dispatch exception.
void Ivory::arith_exception(int nargs, const W* args) {
  int t1 = wtype(args[0]) & 7;
  int t2 = nargs > 1 ? (wtype(args[1]) & 7) : 0;
  int index = ((cur_opcode & 037) << 6) | (t1 << 3) | t2;
  if (trace && tracef) fprintf(tracef, "  ARITH EXCEPTION op=%o idx=%o\n", cur_opcode, index);
  post_trap(TV_ARITHMETIC + index, nargs, args, next_pc);
}

// ---------------------------------------------------------------------------
// Function calling
// ---------------------------------------------------------------------------

// start-call with function object FN.
void Ivory::start_call(W fn, int) {
  W extra = 0;
  bool has_extra = false;
  W target = 0;
  W f = stripcdr(fn);
  for (int guard = 0;; guard++) {
    if (guard > 1000) halt("start-call loop");
    int t = wtype(f);
    if (t == DTP_COMPILED_FUNCTION) {
      target = mkw(DTP_EVEN_PC, wdata(f));
      break;
    }
    if (t == DTP_SYMBOL) {
      f = stripcdr(mem_read(mkw(DTP_LOCATIVE, wdata(f) + 2), CYC_DATA_READ));
      continue;
    }
    if (t == DTP_GENERIC_FUNCTION) {
      extra = f; has_extra = true;
      target = mkw(DTP_EVEN_PC, TRAP_VECTOR_BASE + TV_GENERIC_DISPATCH_TRAP);
      break;
    }
    if (t == DTP_INSTANCE) {
      extra = f; has_extra = true;
      target = mkw(DTP_EVEN_PC, TRAP_VECTOR_BASE + TV_MESSAGE_DISPATCH_TRAP);
      break;
    }
    if (t == DTP_LEXICAL_CLOSURE) {
      W env = stripcdr(mem_read(mkw(DTP_LOCATIVE, wdata(f)), CYC_DATA_READ));
      W fun = stripcdr(mem_read(mkw(DTP_LOCATIVE, wdata(f) + 1), CYC_DATA_READ));
      if (wtype(fun) == DTP_COMPILED_FUNCTION) {
        extra = env; has_extra = true;
        target = mkw(DTP_EVEN_PC, wdata(fun));
        break;
      }
      // Not compiled: call the interpreter entry for lexical closures.
    }
    extra = f; has_extra = true;
    W e = mem_read(mkw(DTP_LOCATIVE, TRAP_VECTOR_BASE + TV_INTERPRETER + t), CYC_DATA_READ);
    if (wtype(e) != DTP_EVEN_PC && wtype(e) != DTP_ODD_PC)
      error_trap(E_INTERPRETER_TABLE_NOT_PC, TRAP_VECTOR_BASE + TV_INTERPRETER + t);
    target = stripcdr(e);
    break;
  }
  push_raw(setcdr(cont, 3));
  push_raw(mkwc(3, DTP_FIXNUM, cr));
  cr |= CR_CALL_STARTED;
  if (has_extra) {
    cr |= CR_EXTRA_ARGUMENT;
    push(extra);
  } else {
    cr &= ~CR_EXTRA_ARGUMENT;
  }
  cont = target;
}

// N is the frame size measured from the new FP (finish-call-n's biased count,
// or finish-call-tos's count + 1 after popping it).
void Ivory::finish_call(uint32_t n, bool, bool apply, int disposition) {
  uint32_t extra = (cr & CR_EXTRA_ARGUMENT) ? 1 : 0;
  uint32_t nfp = sp - n - extra;
  uint32_t nlp = apply ? sp : sp + 1;
  uint32_t argsize = nlp - nfp;
  uint32_t callerfs = nfp - fp;
  uint32_t ncr = cr & ~0x074FFFFFu;
  ncr |= (uint32_t)disposition << CR_VALUE_DISPOSITION_SHIFT;
  ncr |= argsize & 0xFF;
  ncr |= (callerfs & 0xFF) << CR_CALLER_FRAME_SIZE_SHIFT;
  if (apply) ncr |= CR_APPLY;
  if (ncr & CR_CALL_TRACE) ncr |= CR_TRACE_PENDING;
  W target = cont;
  cont = pc_word(next_pc);
  cr = ncr;
  fp = nfp;
  lp = nlp;
  set_pc(((uint64_t)wdata(target) << 1) | (wtype(target) == DTP_ODD_PC ? 1 : 0));
  check_stack_overflow();
}

// Pull N arguments out of the apply argument on top of the stack.  Returns
// true if the entry instruction should be retried.
bool Ivory::pull_apply_args(int n) {
  W rest = tos();
  if (wtype(rest) == DTP_NIL) {
    sp--;
    cr &= ~CR_APPLY;
    return true;
  }
  if (wtype(rest) != DTP_LIST) {
    sp--;
    W args[2] = {fixnum(n), stripcdr(rest)};
    restart_sp = sp;
    take_pre_trap(TV_PULL_APPLY_ARGS, 2, args);
    throw InstructionAbort{};
  }
  // Pull a single argument and let the caller retry (as VLM's slow path).
  // Both memory reads happen before the stack is touched, so a fault leaves
  // the frame (rest arg on top) intact for the restart.
  W car = mem_read(mkw(DTP_LOCATIVE, wdata(rest)), CYC_DATA_READ);
  W cdr = cdr_of(rest, E_CAR_CDR_LIST_TYPE);
  swrite(sp, setcdr(car, CDR_NEXT));
  push(cdr);
  cr = (cr & ~0xFFu) | (((cr & 0xFF) + 1) & 0xFF);
  lp += 1;
  (void)n;
  return true;
}

void Ivory::push_apply_args(int max, int) {
  swrite(sp, setcdr(sread(sp), CDR_NIL));
  bool apply = (cr & CR_APPLY) != 0;
  if (apply && wtype(tos()) == DTP_NIL) {
    // nil apply argument: pop it and treat as not supplied
    sp--;
    cr &= ~CR_APPLY;
    apply = false;
    swrite(sp, setcdr(sread(sp), CDR_NIL));
  }
  if (!apply) {
    push(mkw(DTP_LIST, fp + max));
  } else {
    swrite(sp - 1, setcdr(sread(sp - 1), CDR_NORMAL));
    push(mkw(DTP_LIST, fp + max));
    lp += 1;
    cr = (cr & ~0xFFu) | (((cr & 0xFF) + 1) & 0xFF);
  }
}

// Entry instruction.  INS is the full 36-bit entry word.
void Ivory::do_entry(uint32_t) {
  // decoded by the caller into operand_mode/operand_off conventions:
  // min (biased) in operand_off, max (biased) in operand_mode
  int min = operand_off, max = operand_mode;
  bool rest = (cur_opcode == 0176);
  for (int retry = 0; retry < 1024; retry++) {   // one retry per pulled apply arg
    if (cr & CR_TRACE_PENDING) {
      cr &= ~CR_TRACE_PENDING;
      restart_sp = sp;
      take_pre_trap(TV_TRACE, 0, nullptr);
      throw InstructionAbort{};
    }
    int supplied = cr & 0xFF;
    bool apply = (cr & CR_APPLY) != 0;
    if (apply && wtype(tos()) == DTP_NIL) {
      sp--;
      cr &= ~CR_APPLY;
      apply = false;
    }
    int index;
    if (!apply) {
      if (supplied < min) error_trap(E_TOO_FEW_ARGUMENTS);
      if (supplied > max) {
        if (!rest) error_trap(E_TOO_MANY_ARGUMENTS);
        push_apply_args(max, supplied);
        index = max - min + 1;
      } else {
        index = supplied - min;
      }
    } else {
      int need = max - supplied;
      if (!rest) {
        if (need <= 0) error_trap(E_TOO_MANY_ARGUMENTS);
        restart_sp = sp;
        pull_apply_args(need);
        continue;
      }
      if (need > 0) {
        restart_sp = sp;
        pull_apply_args(need);
        continue;
      }
      if (need < 0) {
        push_apply_args(max, supplied);
        index = max - min + 1;
      } else {
        swrite(sp, setcdr(sread(sp), CDR_NIL));
        index = supplied - min + 1;
      }
    }
    // enter at entry-vector element INDEX
    set_pc((next_pc + 2 * (uint64_t)index) & ~(uint64_t)1);
    if (index == 0) set_pc(next_pc);
    return;
  }
  halt("entry retry loop");
}

// Unbind the top binding-stack entry.
void Ivory::unbind_one() {
  if (!(cr & CR_CLEANUP_BINDINGS)) error_trap(E_BINDING_STACK_UNDERFLOW);
  uint32_t bsp = wdata(binding_stack_pointer);
  W old = mem_read(mkw(DTP_LOCATIVE, bsp), CYC_BIND_READ);
  W loc = mem_read(mkw(DTP_LOCATIVE, bsp - 1), CYC_BIND_READ);
  mem_write(stripcdr(loc), CYC_BIND_WRITE, old, true);
  cr = (cr & ~CR_CLEANUP_BINDINGS) | ((loc >> 38) & 1 ? CR_CLEANUP_BINDINGS : 0);
  binding_stack_pointer = setdata(binding_stack_pointer, bsp - 2);
}

void Ivory::restore_binding_stack(uint32_t target) {
  while (wdata(binding_stack_pointer) > target) unbind_one();
  if (cur_opcode != 051) {
    if (preempt_register & 2) preempt_register |= 1;
  }
}

// catch-close; when FROM_RETURN the PC pushed for an unwind-protect is the
// current (return) instruction so it is retried after the cleanup.
void Ivory::catch_close(bool from_return) {
  uint32_t cb = wdata(catch_block_list);
  W bspw = sread(cb + 1);
  W prev = sread(cb + 2);
  if (wdata(binding_stack_pointer) != wdata(bspw)) {
    while (wdata(binding_stack_pointer) > wdata(bspw)) unbind_one();
    if (preempt_register & 2) preempt_register |= 1;
  }
  uint32_t ncr = cr & ~(CR_CLEANUP_CATCH | CR_EXTRA_ARGUMENT);
  if ((prev >> 38) & 1) ncr |= CR_CLEANUP_CATCH;
  if ((prev >> 39) & 1) ncr |= CR_EXTRA_ARGUMENT;
  bool uwp = (bspw >> 38) & 1;
  catch_block_list = stripcdr(prev);
  if (uwp) {
    W cbpc = sread(cb);
    uint64_t retpc = from_return ? inst_pc : next_pc;
    int cdr = 2 | ((cr & CR_CLEANUP_IN_PROGRESS) ? 1 : 0);
    push_raw(mkwc(cdr, (retpc & 1) ? DTP_ODD_PC : DTP_EVEN_PC, (uint32_t)(retpc >> 1)));
    ncr |= CR_CLEANUP_IN_PROGRESS;
    cr = ncr;
    set_pc(((uint64_t)wdata(cbpc) << 1) | (wtype(cbpc) == DTP_ODD_PC ? 1 : 0));
  } else {
    cr = ncr;
  }
}

// Perform the cleanups indicated by the control register.  Returns true if
// control was diverted (an unwind-protect handler was started), in which case
// the return instruction will be retried later.
bool Ivory::frame_cleanup() {
  while (cr & CR_CLEANUP_BITS) {
    if (cr & CR_CLEANUP_CATCH) {
      uint32_t cb = wdata(catch_block_list);
      W bspw = sread(cb + 1);
      if ((bspw >> 38) & 1) {
        sp = restart_sp;
        catch_close(true);
        return true;
      }
      W prev = sread(cb + 2);
      cr = (cr & ~CR_CLEANUP_CATCH) | (((prev >> 38) & 1) ? CR_CLEANUP_CATCH : 0);
      catch_block_list = stripcdr(prev);
      continue;
    }
    if (cr & CR_CLEANUP_BINDINGS) {
      while (cr & CR_CLEANUP_BINDINGS) unbind_one();
      if (preempt_register & 2) preempt_register |= 1;
      continue;
    }
    if (cr & CR_TRAP_ON_EXIT) {
      sp = restart_sp;
      error_trap(E_TRAP_ON_EXIT, 0);
    }
  }
  return false;
}

// Remove the current frame.  Returns the old value disposition.
// RESTORE_PC: whether the PC is loaded from the continuation.
static inline uint64_t cont_pc(W c) {
  return ((uint64_t)wdata(c) << 1) | (wtype(c) == DTP_ODD_PC ? 1 : 0);
}

// kind: 0 = return-single, 1 = return-multiple, 2 = return-kludge
// For return-single ARG is the 8-bit kludge operand; for the others it is the
// number of values (already popped if sp-pop).
void Ivory::do_return(int kind, int arg, bool sp_pop) {
  if (cr & CR_CLEANUP_BITS) {
    if (frame_cleanup()) return;   // unwind-protect handler started; retry later
  }
  int disp = (cr >> CR_VALUE_DISPOSITION_SHIFT) & 3;
  // gather values
  W single = 0;
  uint32_t nvals = 0, vbase = 0;
  if (kind == 0) {
    if ((arg & 0xFF) == 0) single = stripcdr(tos());
    else single = mkw(DTP_NIL, NIL_ADDRESS);
    if ((arg & 0xFF) != 0 && (arg & 1)) single = mkw(DTP_SYMBOL, T_ADDRESS);
    nvals = 1;
  } else {
    nvals = arg;
    vbase = sp - nvals + 1;
    if (kind == 1 && nvals + ((cr >> CR_CALLER_FRAME_SIZE_SHIFT) & 0xFF) > wdata(stack_frame_maximum_size) &&
        wdata(stack_frame_maximum_size) != 0 && disp == VD_MULTIPLE) {
      error_trap(E_FRAME_OVERFLOW);
    }
  }
  // abandon frame
  W saved_cont = sread(fp);
  W saved_cr = sread(fp + 1);
  uint32_t oldcr = cr;
  bool restore_pc = (kind == 2) || disp != VD_RETURN;
  if (restore_pc) set_pc(cont_pc(cont));
  cont = mkw(wtype(saved_cont), wdata(saved_cont));
  uint32_t oldfp = fp;
  sp = fp - 1;
  fp = fp - ((oldcr >> CR_CALLER_FRAME_SIZE_SHIFT) & 0xFF);
  cr = wdata(saved_cr) | (oldcr & CR_TRACE_PENDING);
  lp = fp + (cr & 0xFF);
  (void)oldfp;
  // The caller's frame is reloaded into the stack cache (spec: the return
  // instruction makes sure the frame returned to is in the cache), so the
  // cache now starts no higher than its FP.
  if (fp < stack_cache_lower_bound) stack_cache_lower_bound = fp;
  if (kind == 2) {
    // return-kludge: copy values to the top of the caller's stack
    for (uint32_t i = 0; i < nvals; i++) swrite(sp + 1 + i, sread(vbase + i));
    sp += nvals;
    return;
  }
  if (kind == 0) {
    switch (disp) {
    case VD_EFFECT: break;
    case VD_VALUE: push(single); break;
    case VD_MULTIPLE: push(single); push(fixnum(1)); break;
    case VD_RETURN:
      if ((arg & 0xFF) == 0) push(single);
      // re-execute the return-single in the caller's frame
      set_pc(inst_pc);
      break;
    }
    return;
  }
  // return-multiple
  switch (disp) {
  case VD_EFFECT: break;
  case VD_VALUE:
    push(nvals ? stripcdr(sread(vbase)) : mkw(DTP_NIL, NIL_ADDRESS));
    break;
  case VD_MULTIPLE:
    for (uint32_t i = 0; i < nvals; i++) swrite(sp + 1 + i, setcdr(sread(vbase + i), CDR_NEXT));
    sp += nvals;
    push(fixnum(nvals));
    break;
  case VD_RETURN:
    // VLM's stack-block-copy strips the cdr codes here too
    for (uint32_t i = 0; i < nvals; i++) swrite(sp + 1 + i, setcdr(sread(vbase + i), CDR_NEXT));
    sp += nvals;
    if (sp_pop) push(fixnum(nvals));
    set_pc(inst_pc);
    break;
  }
}
