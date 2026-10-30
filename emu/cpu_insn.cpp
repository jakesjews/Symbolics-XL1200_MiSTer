// Ivory CPU model: instruction decode and execution.
#include "cpu.h"
#include <cstring>

struct OpInfo { const char* name; int fmt; int sgn; };
static const OpInfo opinfo[256] = {
#include "opcodes.inc"
};
const char* ivory_opcode_name(int op) { return opinfo[op & 0xFF].name; }

enum { F_STACK = 0, F_IMM10 = 1, F_FIELD = 2, F_BRANCH = 3, F_ENTRY = 4, F_NONE = 5, F_ADDR = 6 };

static inline W NILW() { return mkw(DTP_NIL, NIL_ADDRESS); }
static inline W TW() { return mkw(DTP_SYMBOL, T_ADDRESS); }
static inline W boolw(bool b) { return b ? TW() : NILW(); }
static inline uint64_t cont_to_pc(W c) {
  return ((uint64_t)wdata(c) << 1) | (wtype(c) == DTP_ODD_PC ? 1 : 0);
}

// ---------------------------------------------------------------------------
// Main loop
// ---------------------------------------------------------------------------

void Ivory::step() {
  if (halted) return;
  try {
    inst_pc = pc;
    restart_sp = sp;
    pc_changed = false;
    int mode = cr >> CR_TRAP_MODE_SHIFT;

    // Asynchronous traps, in priority order.
    if (bus->reset_request()) {
      take_pre_trap(TV_RESET, 0, nullptr);
      return;
    }
    if (mode <= TM_EXTRA_STACK && bus->high_priority_sb()) {
      bus->sb_taken(true);
      take_pre_trap(TV_HIGH_PRIORITY_SB, 0, nullptr);
      return;
    }
    if (mode == TM_EMULATOR && bus->low_priority_sb()) {
      bus->sb_taken(false);
      take_pre_trap(TV_LOW_PRIORITY_SB, 0, nullptr);
      return;
    }
    if (mode == TM_EMULATOR && (preempt_register & 1)) {
      take_pre_trap(TV_PREEMPT_REQUEST, 0, nullptr);
      return;
    }
    if (cr & CR_TRACE_PENDING) {
      cr &= ~CR_TRACE_PENDING;
      take_pre_trap(TV_TRACE, 0, nullptr);
      return;
    }

    uint32_t waddr = (uint32_t)(pc >> 1);
    bool odd = pc & 1;
    W w = fetch_word(waddr);
    int t = wtype(w), cdr = wcdr(w);
    // sequential successor per the cdr-code sequencing rules
    switch (cdr) {
    case 0: next_pc = pc + 1; break;
    case 2: next_pc = odd ? pc - 1 : pc - 1; break;
    case 3: next_pc = odd ? pc + 3 : pc + 2; break;
    default: next_pc = pc; break;
    }
    if (cdr == CDR_NIL) error_trap(E_I_STAGE, waddr);
    bool trace_insn = (cr & CR_INSTRUCTION_TRACE) != 0;

    if (t >= DTP_PACKED_INSTRUCTION_60) {
      uint64_t ins = ((uint64_t)(t & 0xF) << 32) | wdata(w);
      uint32_t even = ins & 0x3FFFF;
      int eop = (even >> 10) & 0xFF;
      if (!odd && (eop == 0176 || eop == 0177)) {
        // entry instruction occupies the whole word
        cur_opcode = eop;
        operand_off = even & 0xFF;                  // min args + 2
        operand_mode = (int)((ins >> 18) & 0xFF);   // max args + 2
        if (trace && tracef)
          fprintf(tracef, "%010llx %08x.%d  %s min=%d max=%d  sp=%08x fp=%08x\n",
                  (unsigned long long)icount, waddr, odd, opinfo[eop].name, operand_off - 2,
                  operand_mode - 2, sp, fp);
        do_entry((uint32_t)ins);
      } else {
        uint32_t h = odd ? (uint32_t)(ins >> 18) : even;
        execute_halfword(h, cdr);
      }
    } else {
      if (odd) error_trap(E_I_STAGE, waddr);
      execute_fullword(w);
    }
    if (!pc_changed) pc = next_pc;
    if (trace_insn) cr |= CR_TRACE_PENDING;
    icount++;
  } catch (InstructionAbort&) {
    icount++;
  } catch (BusError& be) {
    // A bus error is a pre-trap taking the physical address.
    try {
      W a = mkw(DTP_PHYSICAL_ADDRESS, be.pa);
      if (trace && tracef) fprintf(tracef, "  BUS ERROR pa=%08x %s\n", be.pa, be.write ? "write" : "read");
      take_pre_trap(TV_MEMORY_BUS_ERROR, 1, &a);
    } catch (InstructionAbort&) {
    } catch (BusError& be2) {
      char buf[80];
      snprintf(buf, sizeof buf, "bus error %08x while taking bus error trap", be2.pa);
      halted = true;
      halt_reason = buf;
      throw ProcessorHalt{buf};
    }
    icount++;
  }
}

// ---------------------------------------------------------------------------
// Operands
// ---------------------------------------------------------------------------

uint32_t Ivory::operand_address() {
  switch (operand_mode) {
  case 0: return fp + operand_off;
  case 1: return lp + operand_off;
  case 2: return sp + operand_off - 255;
  default: error_trap(E_I_STAGE, (uint32_t)(inst_pc >> 1));
  }
}

W Ivory::operand_value(bool sign_extend) {
  operand_popped = false;
  switch (operand_mode) {
  case 0: return sread(fp + operand_off);
  case 1: return sread(lp + operand_off);
  case 2:
    if (operand_off == 0) {
      W w = sread(sp);
      sp--;
      operand_popped = true;
      return w;
    }
    return sread(sp + operand_off - 255);
  default:
    return fixnum(sign_extend ? (int32_t)(int8_t)operand_off : operand_off);
  }
}

// ---------------------------------------------------------------------------
// Full-word instructions
// ---------------------------------------------------------------------------

void Ivory::execute_fullword(W w) {
  int t = wtype(w);
  cur_opcode = -1;
  if (trace && tracef)
    fprintf(tracef, "%010llx %08x    fullword %02o %08x  sp=%08x fp=%08x\n",
            (unsigned long long)icount, (uint32_t)(inst_pc >> 1), t, wdata(w), sp, fp);
  switch (t) {
  case DTP_CALL_COMPILED_EVEN: case DTP_CALL_COMPILED_EVEN_PREFETCH:
    start_call(mkw(DTP_COMPILED_FUNCTION, wdata(w)));
    return;
  case DTP_CALL_COMPILED_ODD: case DTP_CALL_COMPILED_ODD_PREFETCH: {
    start_call(mkw(DTP_COMPILED_FUNCTION, wdata(w)));
    cont = mkw(DTP_ODD_PC, wdata(w));
    return;
  }
  case DTP_CALL_INDIRECT: case DTP_CALL_INDIRECT_PREFETCH: {
    W f = mem_read(mkw(DTP_LOCATIVE, wdata(w)), CYC_DATA_READ);
    start_call(f);
    return;
  }
  case DTP_CALL_GENERIC: case DTP_CALL_GENERIC_PREFETCH:
    start_call(mkw(DTP_GENERIC_FUNCTION, wdata(w)));
    return;
  case DTP_EXTERNAL_VALUE_CELL_POINTER:
    push(mem_read(mkw(DTP_LOCATIVE, wdata(w)), CYC_DATA_READ));
    return;
  case DTP_NULL: case DTP_MONITOR_FORWARD: case DTP_HEADER_P: case DTP_HEADER_I:
  case DTP_ONE_Q_FORWARD: case DTP_HEADER_FORWARD: case DTP_ELEMENT_FORWARD:
  case DTP_GC_FORWARD: case DTP_BOUND_LOCATION: case DTP_LOGIC_VARIABLE:
    err_detail = wtype(w);
    error_trap(E_ILLEGAL_FULL_WORD_INSTRUCTION, (uint32_t)(inst_pc >> 1));
  default:
    push(stripcdr(w));   // constant
    return;
  }
}

// ---------------------------------------------------------------------------
// Half-word instructions
// ---------------------------------------------------------------------------

void Ivory::branch_to(int offset) {
  set_pc(inst_pc + offset);
}

void Ivory::execute_halfword(uint32_t h, int) {
  int op = (h >> 10) & 0xFF;
  int operand = h & 0x3FF;
  cur_opcode = op;
  operand_mode = operand >> 8;
  operand_off = operand & 0xFF;
  if (trace && tracef)
    fprintf(tracef, "%010llx %08x.%d  %s %o  sp=%08x fp=%08x tos=%02o:%08x\n",
            (unsigned long long)icount, (uint32_t)(inst_pc >> 1), (int)(inst_pc & 1),
            opinfo[op].name, operand, sp, fp, wtag(sread(sp)), wdata(sread(sp)));
  exec_op(op, operand);
}

W Ivory::car_of(W x, int errc) {
  switch (wtype(x)) {
  case DTP_LIST: case DTP_LOCATIVE:
    return mem_read(mkw(DTP_LOCATIVE, wdata(x)), CYC_DATA_READ);
  case DTP_NIL: return NILW();
  default: (void)errc; return 0xFFFFFFFFFFull;   // caller handles
  }
}

W Ivory::cdr_of(W x, int errc) {
  switch (wtype(x)) {
  case DTP_LOCATIVE:
    return mem_read(mkw(DTP_LOCATIVE, wdata(x)), CYC_DATA_READ);
  case DTP_NIL: return NILW();
  case DTP_LIST: {
    uint32_t a;
    W c = mem_read(mkw(DTP_LOCATIVE, wdata(x)), CYC_CDR, &a);
    switch (wcdr(c)) {
    case CDR_NEXT: return mkw(DTP_LIST, a + 1);
    case CDR_NIL: return NILW();
    case CDR_NORMAL: return mem_read(mkw(DTP_LOCATIVE, a + 1), CYC_DATA_READ);
    default: error_trap(E_BAD_CDR_CODE, a);
    }
  }
  default: (void)errc; return 0xFFFFFFFFFFull;
  }
}

static const W BADW = 0xFFFFFFFFFFull;

bool Ivory::eql(W a, W b) {
  return stripcdr(a) == stripcdr(b);
}

// %alu and %block-n-read-alu/test support.  Returns the 32-bit result and
// computes the selected condition.
uint32_t Ivory::alu_compute(uint32_t op1, uint32_t op2, bool& cond, W w1, W w2) {
  uint32_t a = alu_control;
  int cls = (a >> 14) & 3;
  uint32_t result = 0;
  bool overflow = false, borrow = false, lessthan = false;
  switch (cls) {
  case 0: {  // boolean
    switch ((a >> 10) & 0xF) {
    case 0: result = 0; break;
    case 1: result = op1 & op2; break;
    case 2: result = ~op1 & op2; break;
    case 3: result = op2; break;
    case 4: result = op1 & ~op2; break;
    case 5: result = op1; break;
    case 6: result = op1 ^ op2; break;
    case 7: result = op1 | op2; break;
    case 8: result = ~(op1 | op2); break;
    case 9: result = ~(op1 ^ op2); break;
    case 10: result = ~op1; break;
    case 11: result = ~op1 | op2; break;
    case 12: result = ~op2; break;
    case 13: result = op1 | ~op2; break;
    case 14: result = ~(op1 & op2); break;
    case 15: result = 0xFFFFFFFF; break;
    }
    break;
  }
  case 1: {  // byte
    int rot = a & 31, size = (a >> 5) & 31;
    uint32_t bg = ((a >> 10) & 3) == 0 ? op1 : ((a >> 10) & 3) == 1 ? rotate_latch : 0;
    uint32_t mask, rotated;
    if (((a >> 13) & 1) == 0) {  // dpb
      rotated = (op2 << rot) | (rot ? (op2 >> (32 - rot)) : 0);
      mask = (uint32_t)(~(0xFFFFFFFEull << size)) << rot;
      if ((a >> 12) & 1) rotate_latch = rotated;
    } else {                     // ldb
      rotated = rot ? ((op2 >> (32 - rot)) | (op2 << rot)) : op2;
      mask = (uint32_t)~(0xFFFFFFFEull << size);
      if ((a >> 12) & 1) rotate_latch = rotated;
    }
    result = (rotated & mask) | (bg & ~mask);
    break;
  }
  case 2: {  // adder
    int64_t o2;
    switch ((a >> 11) & 3) {
    case 0: o2 = (int32_t)op2; break;
    case 1: o2 = 0; break;
    case 2: o2 = -(int64_t)(int32_t)op2; break;
    default: o2 = -1; break;
    }
    int64_t s = (int64_t)(int32_t)op1 + o2 + ((a >> 10) & 1);
    result = (uint32_t)s;
    overflow = s != (int64_t)(int32_t)result;
    borrow = op1 < op2;
    lessthan = (int32_t)op1 < (int32_t)op2;
    if ((a >> 24) & 1) {   // load-carry-in: carry-out becomes the next carry-in
      uint64_t u = (uint64_t)op1 + (uint32_t)o2 + ((a >> 10) & 1);
      alu_control = (alu_control & ~(1u << 10)) | ((uint32_t)(u >> 32) & 1) << 10;
    }
    break;
  }
  default:
    result = 0;
    break;
  }
  int c = (a >> 16) & 31;
  bool v;
  switch (c) {
  case 0: v = lessthan || result == 0; break;
  case 1: v = lessthan; break;
  case 2: v = (int32_t)result < 0; break;
  case 3: v = overflow; break;
  case 4: v = borrow || result == 0; break;
  case 5: v = borrow; break;
  case 6: v = result == 0; break;
  case 7: v = (result >> 7) == 0; break;
  case 8: v = result == 0 && wtype(w1) == wtype(w2); break;   // ALU zero and same type
  case 9: v = is_pointer_type(wtype(w1)) && (wdata(w1) >> 27) == 0; break;
  case 12: v = wtype(w1) == DTP_NIL; break;
  case 13: v = wtype(w2) == DTP_FIXNUM; break;
  case 14: v = false; break;
  case 15: v = (wcdr(w1) & 1) != 0; break;
  case 16: v = (cr & CR_CLEANUP_BITS) != 0; break;
  case 19: v = (cr >> CR_TRAP_MODE_SHIFT) != 0; break;
  case 20: v = (cr >> CR_TRAP_MODE_SHIFT) == 3; break;
  case 21: v = (fp_coprocessor_present & 1) != 0; break;
  case 22: v = is_pointer_type(wtype(w1)) && oldspace_address(wdata(w1)); break;
  default: v = false; break;
  }
  if (!((a >> 21) & 1)) cond = v; else cond = !v;
  return result;
}

static inline bool fix2(W a, W b) { return wtype(a) == DTP_FIXNUM && wtype(b) == DTP_FIXNUM; }

void Ivory::exec_op(int op, int operand) {
  W a1, a2, a3, r;
  uint32_t addr;
  switch (op) {
  // ---------------------------------------------------------------- lists
  case 0: case 1: {  // car, cdr
    a1 = operand_value(true);
    r = (op == 0) ? car_of(a1, 0) : cdr_of(a1, 0);
    if (r == BADW) {
      if (wtype(a1) == DTP_LIST_INSTANCE) instruction_exception(1, &a1);
      sp = restart_sp;
      error_trap(E_CAR_CDR_LIST_TYPE, 0);
    }
    push(r);
    return;
  }
  case 0140: case 0141: {  // set-to-car, set-to-cdr
    addr = operand_address();
    a1 = sread(addr);
    r = (op == 0140) ? car_of(a1, 0) : cdr_of(a1, 0);
    if (r == BADW) {
      if (wtype(a1) == DTP_LIST_INSTANCE) { W l = mkw(DTP_LOCATIVE, addr); instruction_exception(1, &l); }
      error_trap(E_SET_TO_CAR_CDR_LIST_TYPE, 0);
    }
    swrite(addr, stripcdr(r) | (a1 & ((W)3 << 38)));
    return;
  }
  case 0142: {  // set-to-cdr-push-car
    addr = operand_address();
    a1 = sread(addr);
    W c = car_of(a1, 0);
    if (c == BADW) {
      if (wtype(a1) == DTP_LIST_INSTANCE) { W l = mkw(DTP_LOCATIVE, addr); instruction_exception(1, &l); }
      error_trap(E_SET_TO_CAR_CDR_LIST_TYPE, 0);
    }
    W d = cdr_of(a1, 0);
    swrite(addr, stripcdr(d) | (a1 & ((W)3 << 38)));
    push(c);
    return;
  }
  case 0200: case 0201: {  // rplaca, rplacd
    a2 = operand_value(true);
    a1 = pop();
    int t = wtype(a1);
    if (t == DTP_LIST_INSTANCE) { W args[2] = {a1, a2}; instruction_exception(2, args); }
    if (t != DTP_LIST && t != DTP_LOCATIVE) { sp = restart_sp; error_trap(E_RPLACA_RPLACD_LIST_TYPE, 0); }
    if (op == 0200 || t == DTP_LOCATIVE) {
      mem_write(mkw(DTP_LOCATIVE, wdata(a1)), CYC_DATA_WRITE, a2, true);
    } else {
      uint32_t a;
      W c = mem_read(mkw(DTP_LOCATIVE, wdata(a1)), CYC_CDR, &a);
      if (wcdr(c) != CDR_NORMAL) { W args[2] = {a1, a2}; instruction_exception(2, args); }
      mem_write(mkw(DTP_LOCATIVE, a + 1), CYC_DATA_WRITE, a2, true);
    }
    return;
  }
  case 0225: case 0226: case 0227: {  // rgetf, member, assoc
    a2 = operand_value(true);
    a1 = sread(sp);
    int t1 = wtype(a1);
    if (t1 == DTP_DOUBLE_FLOAT || t1 == DTP_BIGNUM || t1 == DTP_BIG_RATIO || t1 == DTP_COMPLEX ||
        t1 == DTP_SPARE_NUMBER) {
      sp--;
      W args[2] = {a1, a2};
      instruction_exception(2, args);
    }
    W lst = a2;
    for (uint64_t n = 0;; n++) {
      if (n > 1000 && (bus->high_priority_sb() || bus->low_priority_sb())) {
        // interruptible: abort and retry later
        sp = restart_sp;
        set_pc(inst_pc);
        return;
      }
      if (wtype(lst) == DTP_NIL) {
        sp--;
        if (op == 0225) { push(NILW()); push(NILW()); }
        else push(NILW());
        return;
      }
      if (wtype(lst) != DTP_LIST) {
        sp--;
        W args[2] = {a1, a2};
        if (wtype(lst) == DTP_LIST_INSTANCE) instruction_exception(2, args);
        sp = restart_sp;
        error_trap(E_LIST_TAIL_NOT_LIST, 0);
      }
      W e = car_of(lst, 0);
      if (op == 0227) {  // assoc
        if (wtype(e) == DTP_LIST) {
          W k = car_of(e, 0);
          if (eql(k, a1)) { sp--; push(e); return; }
        } else if (wtype(e) != DTP_NIL) {
          sp--;
          W args[2] = {a1, a2};
          if (wtype(e) == DTP_LIST_INSTANCE) instruction_exception(2, args);
          sp = restart_sp;
          error_trap(E_ASSOC_ELEMENT_NOT_LIST, wdata(lst));
        }
        lst = cdr_of(lst, 0);
      } else if (op == 0226) {  // member
        if (eql(e, a1)) { sp--; push(lst); return; }
        lst = cdr_of(lst, 0);
      } else {  // rgetf
        W rest = cdr_of(lst, 0);
        if (eql(e, a1)) {
          if (wtype(rest) == DTP_NIL) { sp--; W args[2] = {a1, a2}; instruction_exception(2, args); }
          if (wtype(rest) != DTP_LIST) {
            sp--; W args[2] = {a1, a2};
            if (wtype(rest) == DTP_LIST_INSTANCE) instruction_exception(2, args);
            sp = restart_sp; error_trap(E_LIST_TAIL_NOT_LIST, 0);
          }
          sp--;
          push(car_of(rest, 0));
          push(rest);
          return;
        }
        if (wtype(rest) == DTP_NIL) { lst = rest; continue; }
        if (wtype(rest) != DTP_LIST) {
          sp--; W args[2] = {a1, a2};
          if (wtype(rest) == DTP_LIST_INSTANCE) instruction_exception(2, args);
          sp = restart_sp; error_trap(E_LIST_TAIL_NOT_LIST, 0);
        }
        lst = cdr_of(rest, 0);
      }
    }
  }

  // ---------------------------------------------------------------- predicates
  case 0270: case 0274:  // eq, eq-no-pop
    a2 = operand_value(true);
    a1 = sread(sp);
    if (op == 0270) sp--;
    push(boolw(eql(a1, a2)));
    return;
  case 0263: case 0267: {  // eql
    a2 = operand_value(true);
    a1 = sread(sp);
    bool same = eql(a1, a2);
    if (!same && wtype(a1) == wtype(a2)) {
      int t = wtype(a1);
      if (t == DTP_DOUBLE_FLOAT || t == DTP_BIGNUM || t == DTP_BIG_RATIO || t == DTP_COMPLEX ||
          t == DTP_SPARE_NUMBER) {
        sp--;
        W args[2] = {a1, a2};
        arith_exception(2, args);
      }
    }
    if (op == 0263) sp--;
    push(boolw(same));
    return;
  }
  case 0260: case 0264: case 0261: case 0265: case 0262: case 0266: {
    a2 = operand_value(true);
    a1 = sread(sp);
    if (!is_numeric_type(wtype(a1)) || !is_numeric_type(wtype(a2))) {
      sp = restart_sp;
      error_trap(E_BINARY_ARITH_TYPE, 0);
    }
    if (!fix2(a1, a2)) {
      sp--;
      W args[2] = {a1, a2};
      arith_exception(2, args);
    }
    int32_t x = wsdata(a1), y = wsdata(a2);
    bool res = (op == 0260 || op == 0264) ? x == y : (op == 0261 || op == 0265) ? x < y : x > y;
    if (op < 0264) sp--;
    push(boolw(res));
    return;
  }
  case 0273: case 0277: {  // logtest
    a2 = operand_value(true);
    a1 = sread(sp);
    if (!is_numeric_type(wtype(a1)) || !is_numeric_type(wtype(a2))) {
      sp = restart_sp;
      error_trap(E_BINARY_ARITH_TYPE, 0);
    }
    if (!fix2(a1, a2)) { sp--; W args[2] = {a1, a2}; arith_exception(2, args); }
    if (op == 0273) sp--;
    push(boolw((wdata(a1) & wdata(a2)) != 0));
    return;
  }
  case 040: case 041: case 042: case 043: case 044: case 045: case 046: case 047: {
    // type-member-n: n = op<1:0>:operand<9:8>
    int n = ((op & 3) << 2) | (operand >> 8);
    uint64_t mask = (uint64_t)(operand & 0xFF) << (4 * n);
    a1 = sread(sp);
    bool res = (mask >> wtype(a1)) & 1;
    if (op < 044) sp--;
    push(boolw(res));
    return;
  }
  case 2: {  // endp
    a1 = operand_value(true);
    int t = wtype(a1);
    if (t == DTP_NIL) { push(TW()); return; }
    if (t == DTP_LIST || t == DTP_LIST_INSTANCE) { push(NILW()); return; }
    sp = restart_sp;
    error_trap(E_ONE_OPERAND_LIST_TYPE, 0);
  }
  case 034: case 035: case 036: {  // zerop, minusp, plusp
    a1 = operand_value(true);
    if (!is_numeric_type(wtype(a1))) { sp = restart_sp; error_trap(E_UNARY_ARITH_TYPE, 0); }
    if (wtype(a1) != DTP_FIXNUM) arith_exception(1, &a1);
    int32_t x = wsdata(a1);
    push(boolw(op == 034 ? x == 0 : op == 035 ? x < 0 : x > 0));
    return;
  }

  // ---------------------------------------------------------------- numeric
  case 0300: case 0301: case 0202: case 0203: case 0204: case 0205: case 0206: case 0207:
  case 0210: case 0211: case 0212: case 0213: case 0215: case 0216: case 0217: case 0232: {
    a2 = operand_value(op == 0300 || op == 0301 ? false : true);
    a1 = pop();
    arith_binary(op, a1, a2);
    return;
  }
  case 0114: {  // unary-minus
    a1 = operand_value(false);
    arith_unary(op, a1);
    return;
  }
  case 0143: case 0144: {  // increment, decrement
    addr = operand_address();
    a1 = sread(addr);
    if (!is_numeric_type(wtype(a1))) error_trap(E_UNARY_ARITH_TYPE, 0);
    if (wtype(a1) == DTP_FIXNUM) {
      int64_t v = (int64_t)wsdata(a1) + (op == 0143 ? 1 : -1);
      if (v == (int32_t)v) {
        swrite(addr, mkw(DTP_FIXNUM, (uint32_t)v) | (a1 & ((W)3 << 38)));
        return;
      }
    }
    W l = mkw(DTP_LOCATIVE, addr);
    instruction_exception(1, &l);
  }
  case 0220: case 0221: {  // rot, lsh
    a2 = operand_value(true);
    a1 = pop();
    if (!fix2(a1, a2)) { sp = restart_sp; error_trap(E_TWO_OPERAND_FIXNUM_TYPE, 0); }
    uint32_t x = wdata(a1);
    int32_t n = wsdata(a2);
    uint32_t res;
    if (op == 0220) {
      int k = n & 31;
      res = k ? ((x << k) | (x >> (32 - k))) : x;
    } else {
      if (n >= 32 || n <= -32) res = 0;
      else if (n >= 0) res = x << n;
      else res = x >> (-n);
    }
    push(fixnum((int32_t)res));
    return;
  }
  case 0302: case 0303: {  // %32-bit-plus, %32-bit-difference
    a2 = operand_value(false);
    a1 = pop();
    if (!fix2(a1, a2)) { sp = restart_sp; error_trap(E_TWO_OPERAND_FIXNUM_TYPE, 0); }
    push(fixnum((int32_t)(op == 0302 ? wdata(a1) + wdata(a2) : wdata(a1) - wdata(a2))));
    return;
  }
  case 0222: {  // %multiply-double (signed)
    a2 = operand_value(true);
    a1 = pop();
    if (!fix2(a1, a2)) { sp = restart_sp; error_trap(E_TWO_OPERAND_FIXNUM_TYPE, 0); }
    int64_t p = (int64_t)wsdata(a1) * wsdata(a2);
    push(fixnum((int32_t)(uint32_t)p));
    push(fixnum((int32_t)(uint32_t)((uint64_t)p >> 32)));
    return;
  }
  case 0304: case 0305: {  // %add-bignum-step, %sub-bignum-step
    a3 = operand_value(false);
    a2 = pop();
    a1 = pop();
    if (!fix2(a1, a2) || !is_fixnum(a3)) { sp = restart_sp; error_trap(E_THREE_OPERAND_FIXNUM_TYPE, 0); }
    uint64_t x = wdata(a1), y = wdata(a2), z = wdata(a3);
    if (op == 0304) {
      uint64_t s = x + y + z;
      push(fixnum((int32_t)(uint32_t)s));
      push(fixnum((int32_t)(s >> 32)));
    } else {
      int borrow = 0;
      uint32_t d = (uint32_t)x - (uint32_t)y;
      if (x < y) borrow++;
      uint32_t d2 = d - (uint32_t)z;
      if (d < z) borrow++;
      push(fixnum((int32_t)d2));
      push(fixnum(borrow));
    }
    return;
  }
  case 0306: {  // %multiply-bignum-step (unsigned)
    a2 = operand_value(false);
    a1 = pop();
    if (!fix2(a1, a2)) { sp = restart_sp; error_trap(E_TWO_OPERAND_FIXNUM_TYPE, 0); }
    uint64_t p = (uint64_t)wdata(a1) * wdata(a2);
    push(fixnum((int32_t)(uint32_t)p));
    push(fixnum((int32_t)(uint32_t)(p >> 32)));
    return;
  }
  case 0307: {  // %divide-bignum-step
    a3 = operand_value(false);
    a2 = pop();
    a1 = pop();
    if (!fix2(a1, a2) || !is_fixnum(a3) || wdata(a3) == 0) {
      sp = restart_sp;
      error_trap(E_DIVIDE_BIGNUM_STEP, 0);
    }
    uint64_t num = (uint64_t)wdata(a1) | ((uint64_t)wdata(a2) << 32);
    uint64_t q = num / wdata(a3), rem = num % wdata(a3);
    push(fixnum((int32_t)(uint32_t)q));
    push(fixnum((int32_t)(uint32_t)rem));
    return;
  }
  case 0223: {  // %lshc-bignum-step
    a3 = operand_value(true);
    a2 = pop();
    a1 = pop();
    if (!fix2(a1, a2) || !is_fixnum(a3)) { sp = restart_sp; error_trap(E_THREE_OPERAND_FIXNUM_TYPE, 0); }
    uint64_t v = (uint64_t)wdata(a1) | ((uint64_t)wdata(a2) << 32);
    int n = wsdata(a3) & 63;
    push(fixnum((int32_t)(uint32_t)((v << n) >> 32)));
    return;
  }
  case 016: {  // %double-float-op: no FPA; always an instruction exception
    a1 = operand_value(false);
    W args[5];
    args[4] = a1;
    for (int i = 3; i >= 0; i--) args[i] = pop();
    instruction_exception(5, args);
  }

  // ---------------------------------------------------------------- data movement
  case 0100:  // push
    a1 = operand_value(false);
    push(a1);
    return;
  case 0340:  // pop
    addr = operand_address();
    a1 = pop();
    swrite(addr, a1);
    return;
  case 0341:  // movem
    addr = operand_address();
    swrite(addr, sread(sp));
    return;
  case 0101: {  // push-n-nils
    a1 = operand_value(false);
    if (!is_fixnum(a1)) { sp = restart_sp; error_trap(E_ONE_OPERAND_FIXNUM_TYPE, 0); }
    for (uint32_t i = 0; i < wdata(a1); i++) push(NILW());
    return;
  }
  case 0150:  // push-address
    push(mkw(DTP_LOCATIVE, operand_address()));
    return;
  case 0151:  // set-sp-to-address
    sp = operand_address();
    return;
  case 0152: {  // set-sp-to-address-save-tos
    W t = sread(sp);
    sp = operand_address();
    swrite(sp, t);
    return;
  }
  case 0102: {  // push-address-sp-relative
    uint32_t osp = sp;
    a1 = operand_value(false);
    if (!is_fixnum(a1)) { sp = restart_sp; error_trap(E_ONE_OPERAND_FIXNUM_TYPE, 0); }
    push(mkw(DTP_LOCATIVE, osp - wdata(a1) - 1));
    return;
  }
  case 0224: case 0352: {  // stack-blt, stack-blt-address
    uint32_t from;
    if (op == 0224) {
      a2 = operand_value(true);
      from = wdata(a2);   // VLM does not type-check either argument
    } else {
      from = operand_address();
    }
    a1 = pop();
    uint32_t to = wdata(a1);
    uint32_t top = sp;
    while (from <= top) swrite(to++, sread(from++));
    sp = to - 1;
    return;
  }

  // ---------------------------------------------------------------- field extraction
  case 0170: case 0171: {  // ldb, char-ldb
    int size = ((operand >> 5) & 31) + 1, rot = operand & 31;
    a1 = pop();
    if (op == 0170) {
      if (!is_numeric_type(wtype(a1))) { sp = restart_sp; error_trap(E_UNARY_ARITH_TYPE, 0); }
      if (wtype(a1) != DTP_FIXNUM) instruction_exception(1, &a1);
    } else if (wtype(a1) != DTP_CHARACTER) {
      sp = restart_sp; error_trap(E_CHAR_LDB_TYPE, 0);
    }
    uint32_t x = wdata(a1);
    // rotate left by the position field, then mask (the compiler emits ldb for constant rot)
    uint32_t v = rot ? ((x << rot) | (x >> (32 - rot))) : x;
    v &= (uint32_t)~(0xFFFFFFFFFFFFFFFFull << size);
    push(fixnum((int32_t)v));
    return;
  }
  case 0370: case 0371: {  // dpb, char-dpb
    int size = ((operand >> 5) & 31) + 1, pos = operand & 31;
    a2 = pop();
    a1 = pop();
    if (op == 0370) {
      W bad = !is_fixnum(a2) ? a2 : a1;
      if (!fix2(a1, a2)) {
        if (!is_numeric_type(wtype(bad))) { sp = restart_sp; error_trap(E_BINARY_ARITH_TYPE, 0); }
        W args[2] = {a1, a2};
        instruction_exception(2, args);
      }
    } else if (wtype(a1) != DTP_FIXNUM || wtype(a2) != DTP_CHARACTER) {
      sp = restart_sp; error_trap(E_CHAR_DPB_TYPE, 0);
    }
    uint32_t mask = (uint32_t)((~(0xFFFFFFFFFFFFFFFFull << size)) << pos);
    uint32_t v = (wdata(a2) & ~mask) | ((wdata(a1) << pos) & mask);
    push(mkw(op == 0370 ? DTP_FIXNUM : DTP_CHARACTER, v));
    return;
  }
  case 0172: case 0173: {  // %p-ldb, %p-tag-ldb
    int size = ((operand >> 5) & 31) + 1, rot = operand & 31;
    a1 = pop();
    W m = mem_read(a1, CYC_RAW);
    uint32_t x = (op == 0172) ? wdata(m) : (uint32_t)wtag(m);
    uint32_t v = rot ? ((x << rot) | (x >> (32 - rot))) : x;
    v &= (uint32_t)~(0xFFFFFFFFFFFFFFFFull << size);
    push(fixnum((int32_t)v));
    return;
  }
  case 0372: case 0373: {  // %p-dpb, %p-tag-dpb
    int size = ((operand >> 5) & 31) + 1, pos = operand & 31;
    a2 = pop();
    a1 = pop();
    if (wtype(a1) != DTP_FIXNUM) { sp = restart_sp; error_trap(E_P_DPB_TYPE, 0); }
    W m = mem_read(a2, CYC_RAW);
    uint32_t mask = (uint32_t)((~(0xFFFFFFFFFFFFFFFFull << size)) << pos);
    if (op == 0372) {
      uint32_t v = (wdata(m) & ~mask) | ((wdata(a1) << pos) & mask);
      write_addr(a2, setdata(m, v));
    } else {
      uint32_t t = ((uint32_t)wtag(m) & ~mask) | ((wdata(a1) << pos) & mask);
      write_addr(a2, mktag(t & 0xFF, wdata(m)));
    }
    return;
  }

  // ---------------------------------------------------------------- arrays
  case 0312: case 0313: case 0310: {  // aref-1, aloc-1, aset-1
    a2 = operand_value(false);           // index
    a1 = pop();                          // array
    W val = 0;
    if (op == 0310) val = pop();
    int t = wtype(a1);
    auto exc = [&]() {
      if (op == 0310) { W args[3] = {val, a1, a2}; instruction_exception(3, args); }
      W args[2] = {a1, a2};
      instruction_exception(2, args);
    };
    int errc = op == 0310 ? E_ARRAY_ACCESS_TYPE_3 : E_ARRAY_ACCESS_TYPE_BINARY;
    if (!is_fixnum(a2)) error_trap(errc, 0);   // index is checked first
    if (t == DTP_ARRAY_INSTANCE || t == DTP_STRING_INSTANCE) exc();
    if (t != DTP_ARRAY && t != DTP_STRING) error_trap(errc, 0);
    uint32_t haddr;
    W hdr = mem_read(mkw(DTP_LOCATIVE, wdata(a1)), CYC_HEADER, &haddr);
    if ((wdata(hdr) >> 23) & 1) exc();   // long prefix
    uint32_t len = wdata(hdr) & 0x7FFF;
    uint32_t idx = wdata(a2);
    if (idx >= len) { sp = restart_sp; error_trap(E_SUBSCRIPT_BOUNDS, 0); }
    int bp = (wdata(hdr) >> 27) & 7;
    int etype = (wdata(hdr) >> 30) & 3;
    uint32_t base = haddr + 1;
    if (op == 0313) {
      if (etype != 3) { sp = restart_sp; error_trap(E_ALOC_NON_OBJECT_ARRAY, 0); }
      push(mkw(DTP_LOCATIVE, base + idx));
      return;
    }
    if (op == 0312) {
      if (bp == 0 && etype == 3) { push(mem_read(mkw(DTP_LOCATIVE, base + idx), CYC_DATA_READ)); return; }
      uint32_t wa;
      W word = mem_read(mkw(DTP_LOCATIVE, base + (idx >> bp)), CYC_DATA_READ, &wa);
      if (bp && wtype(word) != DTP_FIXNUM) error_trap(E_BYTE_ARRAY_WORD_TYPE, wa);
      uint32_t x = wdata(word);
      if (bp) {
        int bits = 32 >> bp;
        int sub = idx & ((1 << bp) - 1);
        x = (x >> (sub * bits)) & (uint32_t)((1ull << bits) - 1);
      }
      switch (etype) {
      case 0: push(fixnum((int32_t)x)); break;
      case 1: push(mkw(DTP_CHARACTER, x)); break;
      case 2: push(boolw(x != 0)); break;
      default: push(mkw(wtype(word), x)); break;
      }
      return;
    }
    // aset-1
    uint32_t v;
    switch (etype) {
    case 1:
      if (wtype(val) != DTP_CHARACTER) { sp = restart_sp; error_trap(E_CHARACTER_ARRAY_ASET_TYPE, 0); }
      v = wdata(val);
      if (bp == 2 && (v >> 8)) { sp = restart_sp; error_trap(E_NON_8_BIT_CHARACTER, 0); }
      if (bp == 1 && (v >> 16)) { sp = restart_sp; error_trap(E_NON_16_BIT_CHARACTER, 0); }
      break;
    case 0:
      if (wtype(val) != DTP_FIXNUM) { sp = restart_sp; error_trap(E_FIXNUM_ARRAY_ASET_TYPE, 0); }
      v = wdata(val);
      break;
    case 2: v = wtype(val) != DTP_NIL ? 1 : 0; break;
    default: v = 0; break;
    }
    if (bp == 0 && etype == 3) {
      mem_write(mkw(DTP_LOCATIVE, base + idx), CYC_DATA_WRITE, val, true);
      return;
    }
    uint32_t wa;
    W word = mem_read(mkw(DTP_LOCATIVE, base + (idx >> bp)), CYC_DATA_READ, &wa);
    if (wtype(word) != DTP_FIXNUM) { sp = restart_sp; error_trap(E_BYTE_ARRAY_WORD_TYPE, wa); }
    uint32_t x = wdata(word);
    if (bp) {
      int bits = 32 >> bp;
      int sub = idx & ((1 << bp) - 1);
      uint32_t m = (uint32_t)((1ull << bits) - 1) << (sub * bits);
      x = (x & ~m) | ((v << (sub * bits)) & m);
    } else {
      x = v;
    }
    write_raw(wa, setdata(word, x));
    return;
  }
  case 03: case 04: {  // setup-1d-array, setup-force-1d-array
    a1 = operand_value(true);
    int t = wtype(a1);
    if (t == DTP_ARRAY_INSTANCE || t == DTP_STRING_INSTANCE) instruction_exception(1, &a1);
    if (t != DTP_ARRAY && t != DTP_STRING) { sp = restart_sp; error_trap(E_SETUP_ARRAY_NOT_ARRAY, 0); }
    uint32_t haddr;
    W hdr = mem_read(mkw(DTP_LOCATIVE, wdata(a1)), CYC_HEADER, &haddr);
    if (wtype(hdr) != DTP_HEADER_I) { sp = restart_sp; error_trap(E_SETUP_ARRAY_NOT_ARRAY, 0); }
    if ((wdata(hdr) >> 23) & 1) instruction_exception(1, &a1);
    push(a1);
    push(fixnum((int32_t)((wdata(hdr) & 0xF8000000u) | (wdata(event_count) & 0x3FFFFF))));
    push(mkw(DTP_LOCATIVE, haddr + 1));
    push(fixnum(wdata(hdr) & 0x7FFF));
    return;
  }
  case 0350: case 0351: {  // fast-aref-1, fast-aset-1
    addr = operand_address();   // control word of the array register
    a2 = pop();                 // index
    W val = 0;
    if (op == 0351) val = pop();
    W ctl = sread(addr), base = sread(addr + 1), lenw = sread(addr + 2);
    if (!is_fixnum(a2)) { sp = restart_sp; error_trap(E_FAST_ARRAY_ACCESS_TYPE, 0); }
    uint32_t idx = wdata(a2);
    if (idx >= wdata(lenw)) { sp = restart_sp; error_trap(E_ARRAY_REGISTER_FORMAT_OR_BOUNDS, 0); }
    if ((wdata(ctl) & 0x3FFFFF) != (wdata(event_count) & 0x3FFFFF)) {
      // Stale array register: the hardware rebuilds it from a short-prefix
      // array's header; anything else takes the instruction exception.
      W l = mkw(DTP_LOCATIVE, addr);
      auto exc = [&]() {
        if (op == 0350) { W args[2] = {a2, l}; instruction_exception(2, args); }
        W args[3] = {val, a2, l};
        instruction_exception(3, args);
      };
      W arr = sread(addr - 1);
      int at = wtype(arr);
      if (at != DTP_ARRAY && at != DTP_STRING) {
        if (at == DTP_ARRAY_INSTANCE || at == DTP_STRING_INSTANCE || at == DTP_SPARE_POINTER_1 ||
            at == DTP_SPARE_POINTER_2)
          exc();
        sp = restart_sp;
        error_trap(E_ARRAY_REGISTER_FORMAT_OR_BOUNDS, 0);
      }
      uint32_t haddr;
      W hdr = mem_read(mkw(DTP_LOCATIVE, wdata(arr)), CYC_HEADER, &haddr);
      if (wtype(hdr) != DTP_HEADER_I) { sp = restart_sp; error_trap(E_ARRAY_REGISTER_FORMAT_OR_BOUNDS, 0); }
      if ((wdata(hdr) >> 23) & 1) exc();
      ctl = setdata(ctl, (wdata(hdr) & 0xF8000000u) | (wdata(event_count) & 0x3FFFFF));
      base = setdata(base, haddr + 1);
      lenw = setdata(lenw, wdata(hdr) & 0x7FFF);
      swrite(addr, ctl);
      swrite(addr + 1, base);
      swrite(addr + 2, lenw);
      if (idx >= wdata(lenw)) { sp = restart_sp; error_trap(E_ARRAY_REGISTER_FORMAT_OR_BOUNDS, 0); }
    }
    int bp = (wdata(ctl) >> 27) & 7, etype = (wdata(ctl) >> 30) & 3;
    uint32_t boff = (wdata(ctl) >> 22) & 31;
    uint32_t i2 = idx + boff;
    uint32_t wa0 = wdata(base) + (i2 >> bp);
    if (op == 0350) {
      if (bp == 0 && etype == 3) { push(mem_read(mkw(DTP_LOCATIVE, wa0), CYC_DATA_READ)); return; }
      uint32_t wa;
      W word = mem_read(mkw(DTP_LOCATIVE, wa0), CYC_DATA_READ, &wa);
      if (bp && wtype(word) != DTP_FIXNUM) error_trap(E_BYTE_ARRAY_WORD_TYPE, wa);
      uint32_t x = wdata(word);
      if (bp) { int bits = 32 >> bp; int sub = i2 & ((1 << bp) - 1); x = (x >> (sub * bits)) & (uint32_t)((1ull << bits) - 1); }
      switch (etype) {
      case 0: push(fixnum((int32_t)x)); break;
      case 1: push(mkw(DTP_CHARACTER, x)); break;
      case 2: push(boolw(x != 0)); break;
      default: push(mkw(wtype(word), x)); break;
      }
      return;
    }
    uint32_t v;
    switch (etype) {
    case 1:
      if (wtype(val) != DTP_CHARACTER) { sp = restart_sp; error_trap(E_CHARACTER_ARRAY_ASET_TYPE, 0); }
      v = wdata(val);
      if (bp == 2 && (v >> 8)) { sp = restart_sp; error_trap(E_NON_8_BIT_CHARACTER, 0); }
      if (bp == 1 && (v >> 16)) { sp = restart_sp; error_trap(E_NON_16_BIT_CHARACTER, 0); }
      break;
    case 0:
      if (wtype(val) != DTP_FIXNUM) { sp = restart_sp; error_trap(E_FIXNUM_ARRAY_ASET_TYPE, 0); }
      v = wdata(val);
      break;
    case 2: v = wtype(val) != DTP_NIL ? 1 : 0; break;
    default: v = 0; break;
    }
    if (bp == 0 && etype == 3) { mem_write(mkw(DTP_LOCATIVE, wa0), CYC_DATA_WRITE, val, true); return; }
    uint32_t wa;
    W word = mem_read(mkw(DTP_LOCATIVE, wa0), CYC_DATA_READ, &wa);
    if (wtype(word) != DTP_FIXNUM) { sp = restart_sp; error_trap(E_BYTE_ARRAY_WORD_TYPE, wa); }
    uint32_t x = wdata(word);
    if (bp) {
      int bits = 32 >> bp; int sub = i2 & ((1 << bp) - 1);
      uint32_t m = (uint32_t)((1ull << bits) - 1) << (sub * bits);
      x = (x & ~m) | ((v << (sub * bits)) & m);
    } else x = v;
    write_raw(wa, setdata(word, x));
    return;
  }
  case 0316: case 0317: case 0314: {  // array-leader, aloc-leader, store-array-leader
    a2 = operand_value(false);
    a1 = pop();
    W val = 0;
    if (op == 0314) val = pop();
    int t = wtype(a1);
    int errc = op == 0314 ? E_ARRAY_LEADER_TYPE_3 : E_ARRAY_LEADER_TYPE_BINARY;
    if (!is_fixnum(a2)) error_trap(errc, 0);   // index is checked first
    if (t == DTP_ARRAY_INSTANCE || t == DTP_STRING_INSTANCE) {
      if (op == 0314) { W args[3] = {val, a1, a2}; instruction_exception(3, args); }
      W args[2] = {a1, a2}; instruction_exception(2, args);
    }
    if (t != DTP_ARRAY && t != DTP_STRING) error_trap(errc, 0);
    uint32_t haddr;
    W hdr = mem_read(mkw(DTP_LOCATIVE, wdata(a1)), CYC_HEADER, &haddr);
    uint32_t llen = (wdata(hdr) >> 15) & 0xFF;
    if (wdata(a2) >= llen) { sp = restart_sp; error_trap(E_SUBSCRIPT_BOUNDS, 0); }
    uint32_t ea = haddr - 1 - wdata(a2);
    if (op == 0316) push(mem_read(mkw(DTP_LOCATIVE, ea), CYC_DATA_READ));
    else if (op == 0317) push(mkw(DTP_LOCATIVE, ea));
    else mem_write(mkw(DTP_LOCATIVE, ea), CYC_DATA_WRITE, val, true);
    return;
  }

  // ---------------------------------------------------------------- branches
  case 0174: {  // branch
    int off = (operand & 0x200) ? operand - 0x400 : operand;
    branch_to(off);
    return;
  }
  case 060: case 061: case 062: case 063: case 064: case 065: case 066: case 067:
  case 070: case 071: case 072: case 073: case 074: case 075: case 076: case 077: {
    int off = (operand & 0x200) ? operand - 0x400 : operand;
    bool invert = op >= 070;
    int variant = op & 7;
    W t = sread(sp);
    bool cond = (wtype(t) != DTP_NIL) != invert;
    int pops;
    switch (variant) {
    case 0: pops = 1; break;
    case 1: pops = cond ? 1 : 2; break;
    case 2: pops = cond ? 2 : 1; break;
    case 3: pops = 2; break;
    case 4: pops = 0; break;
    case 5: pops = cond ? 0 : 1; break;
    case 6: pops = cond ? 1 : 0; break;
    default: pops = 1; break;
    }
    if (cond && off == 0) error_trap(E_BRANCH_DOT, 0);
    sp -= pops;
    if (cond) branch_to(off);
    return;
  }
  case 0175: {  // loop-decrement-tos
    int off = (operand & 0x200) ? operand - 0x400 : operand;
    W t = sread(sp);
    if (wtype(t) == DTP_FIXNUM && wsdata(t) != INT32_MIN) {
      int32_t v = wsdata(t) - 1;
      set_tos(fixnum(v));
      if (v > 0) branch_to(off);
      return;
    }
    if (!is_numeric_type(wtype(t))) error_trap(E_UNARY_ARITH_TYPE, 0);
    sp--;
    post_trap(TV_INSTRUCTION_EXCEPTION + op, 1, &t, inst_pc + off);
  }
  case 0375: {  // loop-increment-tos-less-than
    int off = (operand & 0x200) ? operand - 0x400 : operand;
    W t = sread(sp), n = sread(sp - 1);
    if (fix2(t, n) && wsdata(t) != INT32_MAX) {
      bool take = wsdata(t) < wsdata(n);
      set_tos(fixnum(wsdata(t) + 1));
      if (take) branch_to(off);
      return;
    }
    if (!is_numeric_type(wtype(t)) || !is_numeric_type(wtype(n))) error_trap(E_BINARY_ARITH_TYPE, 0);
    sp -= 2;
    W args[2] = {n, t};
    post_trap(TV_INSTRUCTION_EXCEPTION + op, 2, args, inst_pc + off);
  }

  // ---------------------------------------------------------------- blocks
  case 0120: case 0121: case 0122: case 0123:
    op_block_read(op & 3, operand, 0); return;
  case 0124: case 0125: case 0126: case 0127:
    op_block_read(op & 3, operand, 1); return;
  case 0130: case 0131: case 0132: case 0133:
    op_block_read(op & 3, operand, 2); return;
  case 0160: case 0161: case 0162: case 0163: {  // %block-n-read-alu
    // As VLM: op1 = memory word, op2 = the operand; both must be fixnums
    // (error trap); the result replaces the operand's data, keeping its tag/cdr.
    int n = op & 3;
    addr = operand_address();
    W arg = sread(addr);
    if (!is_fixnum(arg)) error_trap(E_BLOCK_READ_BINARY_TRANSPORT_FIXNUM, addr);
    uint32_t fa;
    W m = mem_read(bar[n], CYC_DATA_READ, &fa);
    if (!is_fixnum(m)) error_trap(E_BLOCK_READ_BINARY_TRANSPORT_FIXNUM, fa);
    bar[n] = setdata(bar[n], fa + 1);
    bool c;
    uint32_t res = alu_compute(wdata(m), wdata(arg), c, m, arg);
    swrite(addr, setdata(arg, res));
    return;
  }
  case 030: case 031: case 032: case 033:  // %block-n-write
    a1 = operand_value(true);
    op_block_write(op & 3, a1);
    return;

  // ---------------------------------------------------------------- function calling
  case 010:  // start-call
    a1 = operand_value(true);
    start_call(a1);
    return;
  case 0134: case 0135: {  // finish-call-n, finish-call-n-apply
    finish_call(operand & 0xFF, false, op == 0135, operand >> 8);
    return;
  }
  case 0136: case 0137: {  // finish-call-tos, finish-call-tos-apply
    W n = pop();
    finish_call(wdata(n) + 1, true, op == 0137, operand >> 8);
    return;
  }
  case 050: {  // locate-locals
    uint32_t argsize = cr & 0xFF;
    uint32_t osp = sp;
    push(fixnum((int32_t)argsize - 2));
    lp = osp;
    cr = (cr & ~0xFFu) | ((lp - fp) & 0xFF);
    return;
  }
  case 0115:  // return-single
    do_return(0, operand, false);
    return;
  case 0104: case 0105: {  // return-multiple, return-kludge
    bool spop = (operand_mode == 2 && operand_off == 0);
    a1 = operand_value(false);
    if (!is_fixnum(a1)) { sp = restart_sp; error_trap(E_ONE_OPERAND_FIXNUM_TYPE, 0); }
    do_return(op == 0104 ? 1 : 2, (int)wdata(a1), spop);
    return;
  }
  case 0106: {  // take-values
    a1 = operand_value(false);
    uint32_t want = wdata(a1);
    W cnt = pop();   // VLM does not type-check the count
    uint32_t have = wdata(cnt);
    uint32_t base = sp - have + 1;
    if (have >= want) {
      sp = base + want - 1;
    } else {
      for (uint32_t i = have; i < want; i++) push(NILW());
    }
    return;
  }

  // ---------------------------------------------------------------- binding
  case 0236: case 05: {  // bind-locative-to-value, bind-locative
    W val = 0;
    if (op == 0236) { val = operand_value(true); a1 = pop(); }
    else a1 = operand_value(true);
    if (wtype(a1) != DTP_LOCATIVE) { sp = restart_sp; error_trap(E_BIND_LOCATIVE_TYPE, 0); }
    uint32_t bsp = wdata(binding_stack_pointer);
    if (bsp + 2 > wdata(binding_stack_limit)) { sp = restart_sp; error_trap(E_BINDING_STACK_OVERFLOW, 0); }
    W old = mem_read(mkw(DTP_LOCATIVE, wdata(a1)), CYC_BIND_READ);
    int chain = (cr & CR_CLEANUP_BINDINGS) ? 1 : 0;
    write_raw(bsp + 1, mkwc(chain, DTP_LOCATIVE, wdata(a1)));
    write_raw(bsp + 2, old);
    binding_stack_pointer = setdata(binding_stack_pointer, bsp + 2);
    cr |= CR_CLEANUP_BINDINGS;
    if (op == 0236) mem_write(mkw(DTP_LOCATIVE, wdata(a1)), CYC_BIND_WRITE, val, true);
    return;
  }
  case 0107: {  // unbind-n
    a1 = operand_value(false);
    if (!is_fixnum(a1)) { sp = restart_sp; error_trap(E_ONE_OPERAND_FIXNUM_TYPE, 0); }
    for (uint32_t i = 0; i < wdata(a1); i++) unbind_one();
    if (preempt_register & 2) preempt_register |= 1;
    return;
  }
  case 06: {  // %restore-binding-stack
    a1 = operand_value(true);
    if (wtype(a1) != DTP_LOCATIVE) { sp = restart_sp; error_trap(E_OPERAND_LOCATIVE_TYPE, 0); }
    while (wdata(binding_stack_pointer) > wdata(a1)) unbind_one();
    if (preempt_register & 2) preempt_register |= 1;
    return;
  }

  // ---------------------------------------------------------------- catch
  case 0376: {  // catch-open
    uint32_t osp = sp;
    bool uwp = operand & 1;
    push_raw(mkwc(uwp ? 1 : 0, wtype(binding_stack_pointer), wdata(binding_stack_pointer)));
    int cbits = ((cr & CR_EXTRA_ARGUMENT) ? 2 : 0) | ((cr & CR_CLEANUP_CATCH) ? 1 : 0);
    push_raw(setcdr(catch_block_list, cbits));
    if (!uwp) push_raw(setcdr(cont, (operand >> 6) & 3));
    catch_block_list = mkw(DTP_LOCATIVE, osp);
    cr |= CR_CLEANUP_CATCH;
    return;
  }
  case 051:  // catch-close
    catch_close(false);
    return;

  // ---------------------------------------------------------------- lexical variables
  case 020: case 021: case 022: case 023: case 024: case 025: case 026: case 027: {
    a1 = operand_value(true);
    if (wtype(a1) != DTP_LIST && wtype(a1) != DTP_LOCATIVE) { sp = restart_sp; error_trap(E_UNARY_LEXENV_TYPE, 0); }
    push(mem_read(mkw(DTP_LOCATIVE, wdata(a1) + (op & 7)), CYC_DATA_READ));
    return;
  }
  case 0240: case 0241: case 0242: case 0243: case 0244: case 0245: case 0246: case 0247:
  case 0250: case 0251: case 0252: case 0253: case 0254: case 0255: case 0256: case 0257: {
    a2 = operand_value(true);
    W v = sread(sp);
    if (wtype(a2) != DTP_LIST && wtype(a2) != DTP_LOCATIVE) { sp = restart_sp; error_trap(E_BINARY_LEXENV_TYPE, 0); }
    mem_write(mkw(DTP_LOCATIVE, wdata(a2) + (op & 7)), CYC_DATA_WRITE, v, true);
    if (op < 0250) sp--;
    return;
  }

  // ---------------------------------------------------------------- instance variables
  case 0110: case 0320: case 0321: case 0111: {  // mapped access to self
    uint32_t n = operand & 0xFF;
    if (operand_mode != 3) n = wdata(operand_value(false));
    W map = sread(fp + 2);
    if (wtype(map) != DTP_ARRAY) { sp = restart_sp; error_trap(E_SELF_MAPPING_TABLE_TYPE, 0); }
    uint32_t maddr;
    W mh = mem_read(mkw(DTP_LOCATIVE, wdata(map)), CYC_HEADER, &maddr);
    if (n >= (wdata(mh) & 0x7FFF)) { sp = restart_sp; error_trap(E_MAPPING_TABLE_INDEX_BOUNDS, 0); }
    W off = mem_read(mkw(DTP_LOCATIVE, maddr + 1 + n), CYC_DATA_READ);
    if (wtype(off) != DTP_FIXNUM) { sp = restart_sp; error_trap(E_ILLEGAL_INSTANCE_VARIABLE_INDEX, 0); }
    W self = sread(fp + 3);
    int st = wtype(self);
    if (st < DTP_INSTANCE || st > DTP_STRING_INSTANCE) { sp = restart_sp; error_trap(E_SELF_TYPE, 0); }
    uint32_t base = wdata(self);
    if (wcdr(self) != 1) {
      uint32_t ha;
      mem_read(mkw(DTP_LOCATIVE, base), CYC_HEADER, &ha);
      if (ha == base) swrite(fp + 3, setcdr(self, 1));
      base = ha;
    }
    uint32_t ea = base + wdata(off);
    if (op == 0110) push(mem_read(mkw(DTP_LOCATIVE, ea), CYC_DATA_READ));
    else if (op == 0111) push(mkw(DTP_LOCATIVE, ea));
    else {
      W v = sread(sp);
      mem_write(mkw(DTP_LOCATIVE, ea), CYC_DATA_WRITE, v, true);
      if (op == 0320) sp--;
    }
    return;
  }
  case 0112: case 0322: case 0323: case 0113: {  // ordered (unmapped) access to self
    uint32_t n = operand & 0xFF;
    if (operand_mode != 3) n = wdata(operand_value(false));
    W self = sread(fp + 3);
    int st = wtype(self);
    if (st < DTP_INSTANCE || st > DTP_STRING_INSTANCE) { sp = restart_sp; error_trap(E_SELF_TYPE, 0); }
    uint32_t ea = wdata(self) + n;
    if (op == 0112) push(mem_read(mkw(DTP_LOCATIVE, ea), CYC_DATA_READ));
    else if (op == 0113) push(mkw(DTP_LOCATIVE, ea));
    else {
      W v = sread(sp);
      mem_write(mkw(DTP_LOCATIVE, ea), CYC_DATA_WRITE, v, true);
      if (op == 0322) sp--;
    }
    return;
  }
  case 0324: case 0325: case 0326: {  // %instance-ref, %instance-set, %instance-loc
    a2 = operand_value(false);
    a1 = pop();
    W val = 0;
    if (op == 0325) val = pop();
    int it = wtype(a1);
    if (it < DTP_INSTANCE || it > DTP_STRING_INSTANCE || !is_fixnum(a2)) {
      sp = restart_sp;
      error_trap(op == 0325 ? E_INSTANCE_REF_TYPE_3 : E_INSTANCE_REF_TYPE_BINARY, 0);
    }
    uint32_t ha;
    W hdr = mem_read(mkw(DTP_LOCATIVE, wdata(a1)), CYC_HEADER, &ha);
    W size = mem_read(mkw(DTP_LOCATIVE, wdata(hdr) - 1), CYC_DATA_READ);
    if (!is_fixnum(size) || wdata(a2) >= wdata(size)) {
      sp = restart_sp;
      error_trap(E_ILLEGAL_INSTANCE_VARIABLE_INDEX, 0);
    }
    uint32_t ea = ha + wdata(a2);
    if (op == 0324) push(mem_read(mkw(DTP_LOCATIVE, ea), CYC_DATA_READ));
    else if (op == 0326) push(mkw(DTP_LOCATIVE, ea));
    else mem_write(mkw(DTP_LOCATIVE, ea), CYC_DATA_WRITE, val, true);
    return;
  }

  // ---------------------------------------------------------------- subprimitives
  case 07:  // %ephemeralp
    a1 = operand_value(true);
    push(boolw(is_pointer_type(wtype(a1)) && (wdata(a1) >> 27) == 0));
    return;
  case 0331: case 0335: {  // %unsigned-lessp
    a2 = operand_value(false);
    a1 = sread(sp);
    // Like the hardware, no type check: compares the data fields (used on pointers).
    if (op == 0331) sp--;
    push(boolw(wdata(a1) < wdata(a2)));
    return;
  }
  case 0214: {  // %alu
    a2 = operand_value(true);
    a1 = pop();
    if (!fix2(a1, a2)) { sp = restart_sp; error_trap(E_TWO_OPERAND_FIXNUM_TYPE, 0); }
    bool c;
    uint32_t res = alu_compute(wdata(a1), wdata(a2), c, a1, a2);
    push(fixnum((int32_t)res));
    return;
  }
  case 0311: case 0315: {  // %allocate-list-block, %allocate-structure-block
    a2 = operand_value(false);
    a1 = pop();
    bool list = op == 0311;
    W& area = list ? list_cache_area : structure_cache_area;
    W& address = list ? list_cache_address : structure_cache_address;
    W& length = list ? list_cache_length : structure_cache_length;
    if (!is_fixnum(a2)) { sp = restart_sp; error_trap(E_ALLOCATE_TYPE, 0); }
    if (stripcdr(a1) != stripcdr(area) || wdata(a2) > wdata(length)) {
      W args[2] = {a1, a2};
      instruction_exception(2, args);
    }
    length = setdata(length, wdata(length) - wdata(a2));
    W ad = address;
    push(ad);
    bar[1] = stripcdr(ad);
    address = setdata(address, wdata(address) + wdata(a2));
    if ((cr >> CR_TRAP_MODE_SHIFT) == 0) cr |= 1u << CR_TRAP_MODE_SHIFT;
    return;
  }
  case 0230: {  // %pointer-plus
    a2 = operand_value(true);
    a1 = pop();
    push(setdata(a1, wdata(a1) + wdata(a2)));
    return;
  }
  case 0231: {  // %pointer-difference
    a2 = operand_value(true);
    a1 = pop();
    push(fixnum((int32_t)(wdata(a1) - wdata(a2))));
    return;
  }
  case 0145: {  // %pointer-increment
    addr = operand_address();
    W w = sread(addr);
    swrite(addr, setdata(w, wdata(w) + 1));
    return;
  }
  case 0154:  // %read-internal-register
    push(read_internal_register(operand));
    return;
  case 0155:  // %write-internal-register
    a1 = pop();
    write_internal_register(operand, a1);
    return;
  case 0156:  // %coprocessor-read
    try {
      push(bus->coproc_read(operand));
    } catch (CoprocError&) {
      sp = restart_sp;
      error_trap(E_UNKNOWN_INTERNAL_REGISTER, 0);
    }
    return;
  case 0157:  // %coprocessor-write
    a1 = pop();
    try {
      bus->coproc_write(operand, a1);
    } catch (CoprocError&) {
      sp = restart_sp;
      error_trap(E_UNKNOWN_INTERNAL_REGISTER, 0);
    }
    return;
  case 0116: case 0117: {  // %memory-read, %memory-read-address
    a1 = pop();
    int cycle = (operand >> 6) & 15;
    bool fixnum_only = (operand >> 5) & 1, set_cdr_next = (operand >> 4) & 1;
    uint32_t fa;
    W m;
    if (cycle >= CYC_COUNT) cycle = CYC_RAW;
    m = mem_read(a1, cycle, &fa);
    if (fixnum_only && wtype(m) != DTP_FIXNUM) { sp = restart_sp; error_trap(E_MEMORY_READ_TRANSPORT_FIXNUM, fa); }
    if (op == 0116) {
      push_raw(set_cdr_next ? setcdr(m, 0) : m);
    } else {
      W res = (wtype(a1) == DTP_PHYSICAL_ADDRESS && fa == wdata(a1)) ? a1 : mkw(wtype(a1), fa);
      push_raw(set_cdr_next ? setcdr(res, 0) : setcdr(res, wcdr(m)));
    }
    return;
  }
  case 012:  // %tag
    a1 = operand_value(true);
    push(fixnum(wtag(a1)));
    return;
  case 0327: {  // %set-tag
    a2 = operand_value(false);
    a1 = pop();
    if (!is_fixnum(a2)) { sp = restart_sp; error_trap(E_ONE_OPERAND_FIXNUM_TYPE, 0); }
    push_raw(mktag(wdata(a2) & 0xFF, wdata(a1)));
    return;
  }
  case 0233: {  // store-conditional
    a3 = operand_value(true);
    a2 = pop();
    a1 = pop();
    if (wtype(a1) != DTP_LOCATIVE && wtype(a1) != DTP_PHYSICAL_ADDRESS) {
      sp = restart_sp; error_trap(E_OPERAND_1_TYPE_LOCATIVE, 0);
    }
    uint32_t fa;
    W m = mem_read(a1, CYC_DATA_READ, &fa);
    if (stripcdr(m) == stripcdr(a2)) {
      W nw = stripcdr(a3) | (m & ((W)3 << 38));
      if (wtype(a1) == DTP_PHYSICAL_ADDRESS && fa == wdata(a1)) bus->phys_write(fa, nw);
      else write_raw(fa, nw);
      push(TW());
    } else {
      push(NILW());
    }
    return;
  }
  case 0234: {  // %memory-write
    a2 = operand_value(true);
    a1 = pop();
    write_addr(a1, a2);
    return;
  }
  case 0235: {  // %p-store-contents
    a2 = operand_value(true);
    a1 = pop();
    W m = read_addr(a1);
    write_addr(a1, stripcdr(a2) | (m & ((W)3 << 38)));
    return;
  }
  case 0146: case 0147: {  // %set-cdr-code-1/2
    addr = operand_address();
    swrite(addr, setcdr(sread(addr), op & 3 ? (op == 0146 ? 1 : 2) : 0));
    return;
  }
  case 0342: {  // %merge-cdr-no-pop
    addr = operand_address();
    W t = sread(sp);
    swrite(addr, setcdr(sread(addr), wcdr(t)));
    return;
  }
  case 052: case 053: {  // %generic-dispatch, %message-dispatch
    if ((cr & 0xFF) < 4) {
      if (cr & CR_APPLY) {
        restart_sp = sp;
        pull_apply_args(4 - (cr & 0xFF));
        set_pc(inst_pc);
        return;
      }
      error_trap(E_TOO_FEW_ARGUMENTS);
    }
    W g = stripcdr(sread(fp + (op == 052 ? 2 : 3)));
    W inst = stripcdr(sread(fp + (op == 052 ? 3 : 2)));
    int it = wtype(inst);
    uint32_t desc;
    if (it >= DTP_INSTANCE && it <= DTP_STRING_INSTANCE) {
      W hdr = mem_read(mkw(DTP_LOCATIVE, wdata(inst)), CYC_HEADER);
      desc = wdata(hdr);
    } else {
      W e = mem_read(mkw(DTP_LOCATIVE, TRAP_VECTOR_BASE + TV_GENERIC_DISPATCH + it), CYC_DATA_READ);
      desc = wdata(e);
    }
    W mask = mem_read(mkw(DTP_LOCATIVE, desc), CYC_DATA_READ);
    if (!is_fixnum(mask)) error_trap(E_FLAVOR_SEARCH_MASK_NOT_FIXNUM, desc);
    W table = mem_read(mkw(DTP_LOCATIVE, desc + 1), CYC_DATA_READ);
    if (wtype(table) != DTP_LOCATIVE) error_trap(E_FLAVOR_SEARCH_TABLE_NOT_LOCATIVE, desc + 1);
    uint32_t off = (wdata(mask) & wdata(g)) * 3;
    uint32_t ka;
    for (int guard = 0;; guard++, off += 3) {
      ka = wdata(table) + off;
      W key = mem_read(mkw(DTP_LOCATIVE, ka), CYC_DATA_READ);
      if (wtype(key) == DTP_NIL) break;
      if (wtype(key) == wtype(g) && wdata(key) == wdata(g)) break;
      if (guard > 100000) halt("handler table search loop");
    }
    W method = mem_read(mkw(DTP_LOCATIVE, ka + 1), CYC_DATA_READ);
    W param = mem_read(mkw(DTP_LOCATIVE, ka + 2), CYC_DATA_READ);
    if (wtype(method) != DTP_EVEN_PC && wtype(method) != DTP_ODD_PC)
      error_trap(E_GENERIC_SEARCH_ENTRY_NOT_PC, ka + 1);
    if (op == 052) {
      if (wtype(param) != DTP_NIL) swrite(fp + 2, param);
    } else {
      W instw = sread(fp + 2);
      if (wtype(param) != DTP_NIL) swrite(fp + 2, param);
      else swrite(fp + 2, sread(fp + 3));
      swrite(fp + 3, instw);
    }
    set_pc(cont_to_pc(method));
    return;
  }
  case 011: {  // %jump
    a1 = operand_value(true);
    if (wtype(a1) != DTP_EVEN_PC && wtype(a1) != DTP_ODD_PC) {
      sp = restart_sp; error_trap(E_UNARY_OPERAND_TYPE_PC, 0);
    }
    if ((a1 >> 39) & 1) {
      if ((a1 >> 38) & 1) cr |= CR_CLEANUP_IN_PROGRESS; else cr &= ~CR_CLEANUP_IN_PROGRESS;
    }
    set_pc(cont_to_pc(a1));
    return;
  }
  case 054:  // %check-preempt-request
    if (preempt_register & 2) preempt_register |= 1;
    return;
  case 056:  // no-op
    return;
  case 057:  // %halt
    if ((cr >> CR_TRAP_MODE_SHIFT) == TM_FEP && trace && tracef) fprintf(tracef, "  %%HALT in FEP mode\n");
    instruction_exception(0, nullptr);
  case 015:  // %proc-breakpoint
    instruction_exception(0, nullptr);

  // ---------------------------------------------------------------- logic variables (Joshua)
  case 013: case 0237: case 0103: case 055: case 014: {
    // Not implemented in this model: let Lisp emulate.
    int nargs = (op == 0237) ? 2 : (op == 055) ? 0 : 1;
    W args[2];
    if (nargs == 2) { args[1] = operand_value(true); args[0] = pop(); }
    else if (nargs == 1) args[0] = operand_value(true);
    instruction_exception(nargs, args);
  }

  default: {
    // undefined instruction: exception with no arguments
    instruction_exception(0, nullptr);
  }
  }
}

// ---------------------------------------------------------------------------
// Arithmetic
// ---------------------------------------------------------------------------

void Ivory::arith_binary(int op, W a1, W a2) {
  if (!is_numeric_type(wtype(a1)) || !is_numeric_type(wtype(a2))) {
    sp = restart_sp;
    error_trap(E_BINARY_ARITH_TYPE, 0);
  }
  W args[2] = {a1, a2};
  if (!fix2(a1, a2)) arith_exception(2, args);
  int64_t x = wsdata(a1), y = wsdata(a2);
  int64_t r = 0;
  switch (op) {
  case 0300: r = x + y; break;
  case 0301: r = x - y; break;
  case 0202: r = x * y; break;
  case 0203: case 0204: case 0205: case 0206: case 0207: case 0210: case 0211: {
    if (y == 0) { sp = restart_sp; error_trap(E_DIVIDE_BY_ZERO, 0); }
    if (x == INT32_MIN && y == -1) arith_exception(2, args);
    int64_t q = x / y, rem = x % y;
    if (op == 0203) { push(fixnum((int32_t)q)); return; }
    if (op == 0210) { push(fixnum((int32_t)rem)); return; }
    if (op == 0211) {
      if (rem != 0) arith_exception(2, args);
      push(fixnum((int32_t)q));
      return;
    }
    if (rem != 0) {
      switch (op) {
      case 0204: if ((rem > 0) == (y > 0)) { q++; rem -= y; } break;            // ceiling
      case 0205: if ((rem > 0) != (y > 0)) { q--; rem += y; } break;            // floor
      case 0206: break;                                                         // truncate
      case 0207: {                                                              // round
        int64_t twice = 2 * (rem < 0 ? -rem : rem), ay = y < 0 ? -y : y;
        bool up = twice > ay || (twice == ay && (q & 1));
        if (up) {
          if ((rem > 0) == (y > 0)) { q++; rem -= y; } else { q--; rem += y; }
        }
        break;
      }
      }
    }
    push(fixnum((int32_t)q));
    push(fixnum((int32_t)rem));
    return;
  }
  case 0212: r = x < y ? x : y; break;
  case 0213: r = x > y ? x : y; break;
  case 0215: r = x & y; break;
  case 0216: r = x ^ y; break;
  case 0217: r = x | y; break;
  case 0232: {  // ash
    if (y >= 0) {
      if (y >= 32) { if (x == 0) { push(fixnum(0)); return; } arith_exception(2, args); }
      r = x << y;
    } else {
      r = (y <= -32) ? (x < 0 ? -1 : 0) : (x >> (-y));
    }
    break;
  }
  }
  if (r != (int32_t)r) arith_exception(2, args);
  push(fixnum((int32_t)r));
}

void Ivory::arith_unary(int op, W a1) {
  (void)op;
  if (!is_numeric_type(wtype(a1))) { sp = restart_sp; error_trap(E_UNARY_ARITH_TYPE, 0); }
  if (wtype(a1) != DTP_FIXNUM || wsdata(a1) == INT32_MIN) arith_exception(1, &a1);
  push(fixnum(-wsdata(a1)));
}

// ---------------------------------------------------------------------------
// Block reads/writes
// ---------------------------------------------------------------------------

// kind: 0 = %block-n-read, 1 = -shift, 2 = -test
void Ivory::op_block_read(int n, int imm, int kind) {
  int cycle = (imm >> 6) & 15;
  bool fixnum_only = (imm >> 5) & 1, set_cdr_next = (imm >> 4) & 1, no_increment = (imm >> 2) & 1;
  if (cycle >= CYC_COUNT) cycle = CYC_RAW;
  uint32_t fa;
  W m = mem_read(bar[n], cycle, &fa);
  if (fixnum_only && wtype(m) != DTP_FIXNUM) {
    error_trap(kind == 2 ? E_BLOCK_READ_TEST_TRANSPORT_FIXNUM : E_BLOCK_READ_TRANSPORT_FIXNUM, fa);
  }
  if (wtype(bar[n]) != DTP_PHYSICAL_ADDRESS || fa != wdata(bar[n])) bar[n] = setdata(bar[n], fa);
  if (kind == 0) {
    push_raw(set_cdr_next ? setcdr(m, 0) : m);
    if (!no_increment) bar[n] = setdata(bar[n], wdata(bar[n]) + 1);
    return;
  }
  if (kind == 1) {
    int rot = alu_control & 31, size = (alu_control >> 5) & 31;
    uint32_t x = wdata(m);
    uint32_t rotated = rot ? ((x << rot) | (x >> (32 - rot))) : x;
    // The top byte-s+1 bits come from the rotated word and the rest from the
    // rotate latch (I-Machine Architecture Specification, %block-n-read-shift).
    // The VLM puts the field at byte-r instead, which only agrees when
    // byte-r + byte-s = 31; Genera's one-word glyph routines (idraw.lisp
    // %DRAW-NARROW-CHARACTER-1-1/1-2) use byte-s = 31 with any rotation.
    uint32_t mask = (uint32_t)(0xFFFFFFFF00000000ull >> (size + 1));
    uint32_t res = (rotated & mask) | (rotate_latch & ~mask);
    rotate_latch = rotated;
    push_raw(mkwc(set_cdr_next ? 0 : wcdr(m), wtype(m), res));
    if (!no_increment) bar[n] = setdata(bar[n], wdata(bar[n]) + 1);
    return;
  }
  // test: condition on memory word (op1) and TOS (op2); on success jump to
  // the PC that is next on the stack.
  W t = sread(sp);
  if (fixnum_only && !is_fixnum(t)) error_trap(E_BLOCK_READ_TEST_TRANSPORT_FIXNUM, sp);
  if (set_cdr_next) m = setcdr(m, CDR_NEXT);   // affects the result-cdr-low condition
  bool c;
  alu_compute(wdata(m), wdata(t), c, m, t);
  if (c) {
    W target = sread(sp - 1);
    set_pc(cont_to_pc(target));
  } else if (!no_increment) {
    bar[n] = setdata(bar[n], wdata(bar[n]) + 1);
  }
}

void Ivory::op_block_write(int n, W v) {
  write_addr(bar[n], v);
  bar[n] = setdata(bar[n], wdata(bar[n]) + 1);
}

// ---------------------------------------------------------------------------
// Internal registers
// ---------------------------------------------------------------------------

W Ivory::read_internal_register(int r) {
  int barn = (r >> 7) & 3;
  // Registers 0-0777 are per-BAR (bits 8:7 select the BAR); 01000 up are not.
  if (r < 01000) switch (r & 0177) {
  case IR_FP: if (r < 0200) return mkw(DTP_LOCATIVE, fp); break;
  case IR_LP: if (r < 0200) return mkw(DTP_LOCATIVE, lp); break;
  case IR_SP: if (r < 0200) return mkw(DTP_LOCATIVE, sp); break;
  case IR_BAR0: return stripcdr(bar[barn]);
  case IR_PHT_HASH0: return fixnum((int32_t)pht_hash(wdata(bar[barn]) >> 8));
  default: break;
  }
  if (r >= 01000) {
    switch (r) {
    case IR_TOS: return stripcdr(sread(sp));
    case IR_EVENT_COUNT: return event_count;
    case IR_BINDING_STACK_POINTER: return binding_stack_pointer;
    case IR_CATCH_BLOCK_LIST: return catch_block_list;
    case IR_CONTROL_STACK_LIMIT: return control_stack_limit;
    case IR_CONTROL_STACK_EXTRA_LIMIT: return control_stack_extra_limit;
    case IR_BINDING_STACK_LIMIT: return binding_stack_limit;
    case IR_PHT_BASE: return mkw(DTP_PHYSICAL_ADDRESS, pht_base);
    case IR_PHT_MASK: return fixnum((int32_t)pht_mask);
    case IR_COUNT_MAP_RELOADS: return count_map_reloads;
    case IR_LIST_CACHE_AREA: return list_cache_area;
    case IR_LIST_CACHE_ADDRESS: return list_cache_address;
    case IR_LIST_CACHE_LENGTH: return list_cache_length;
    case IR_STRUCTURE_CACHE_AREA: return structure_cache_area;
    case IR_STRUCTURE_CACHE_ADDRESS: return structure_cache_address;
    case IR_STRUCTURE_CACHE_LENGTH: return structure_cache_length;
    case IR_DYNAMIC_BINDING_CACHE_BASE: return dynamic_binding_cache_base;
    case IR_DYNAMIC_BINDING_CACHE_MASK: return dynamic_binding_cache_mask;
    case IR_CHOICE_POINTER: return choice_pointer;
    case IR_STRUCTURE_STACK_CHOICE_POINTER: return structure_stack_choice_pointer;
    case IR_FEP_MODE_TRAP_VECTOR_ADDRESS: return fep_mode_trap_vector_address;
    case IR_MAPPING_TABLE_CACHE: return mapping_table_cache;
    case IR_MAPPING_TABLE_LENGTH: return mapping_table_length;
    case IR_STACK_FRAME_MAXIMUM_SIZE: return stack_frame_maximum_size;
    case IR_STACK_CACHE_DUMP_QUANTUM: return stack_cache_dump_quantum;
    case IR_CONSTANT_NIL: return NILW();
    case IR_CONSTANT_T: return TW();
    default: return stripcdr(scratch[r & 0777]);
    }
  }
  switch (r) {
  case IR_EA: case IR_MACRO_SP: return mkw(DTP_LOCATIVE, sp);
  case IR_STACK_CACHE_LOWER_BOUND: return mkw(DTP_LOCATIVE, stack_cache_lower_bound);
  case IR_EPC: case IR_DPC: return pc_word(inst_pc);
  case IR_CONTINUATION: return stripcdr(cont);
  case IR_ALU_AND_ROTATE_CONTROL: return fixnum((int32_t)alu_control);
  case IR_CONTROL_REGISTER: return fixnum((int32_t)cr);
  case IR_CR_ARGUMENT_SIZE: return fixnum(cr & 0xFF);
  case IR_EPHEMERAL_OLDSPACE: return fixnum((int32_t)ephemeral_oldspace);
  case IR_ZONE_OLDSPACE: return fixnum((int32_t)zone_oldspace);
  case IR_CHIP_REVISION: return fixnum((int32_t)chip_revision);
  case IR_FP_COPROCESSOR_PRESENT: return fixnum((int32_t)fp_coprocessor_present);
  case IR_PREEMPT_REGISTER: return fixnum((int32_t)preempt_register);
  case IR_ICACHE_CONTROL: return fixnum((int32_t)icache_control);
  case IR_PREFETCHER_CONTROL: return fixnum((int32_t)prefetcher_control);
  case IR_MAP_CACHE_CONTROL: return fixnum((int32_t)map_cache_control);
  case IR_MEMORY_CONTROL: return fixnum((int32_t)memory_control);
  case IR_ECC_LOG: case IR_ECC_LOG_ADDRESS: return fixnum(0);
  case IR_STACK_CACHE_OVERFLOW_LIMIT: return mkw(DTP_LOCATIVE, stack_cache_overflow_limit);
  case IR_ENTRY_MAXIMUM_ARGUMENTS: return fixnum((int32_t)entry_max_args);
  case IR_MICROSECOND_CLOCK: return fixnum((int32_t)bus->microsecond_clock());
  case IR_ARRAY_HEADER_LENGTH: return fixnum(0);
  default:
    if (trace && tracef) fprintf(tracef, "  read unknown internal register %o\n", r);
    return fixnum(0);
  }
}

void Ivory::write_internal_register(int r, W w) {
  int barn = (r >> 7) & 3;
  if (r < 01000) switch (r & 0177) {
  case IR_BAR0: bar[barn] = stripcdr(w); return;
  case IR_LOAD_BAR0: bar[barn] = stripcdr(w); return;
  case IR_INVALIDATE_MAP0: {
    uint32_t vpn = wdata(bar[barn]) >> 8;
    MapEntry* e = map_lookup(vpn);
    if (e) e->vpn = 0xFFFFFFFFu;
    return;
  }
  case IR_LOAD_MAP0: {
    // Load the map entry for the VMA in BARn from W (PHT1 format).
    uint32_t vpn = wdata(bar[barn]) >> 8;
    MapEntry* e = &map[vpn & (MAP_SIZE - 1)];
    e->vpn = vpn;
    e->ppn = wdata(w) >> 8;
    e->access = wdata(w) & 0xFF;
    e->pht_addr = 0;
    return;
  }
  default: break;
  }
  if (r >= 01000) {
    switch (r) {
    case IR_TOS: swrite(sp, w); return;
    case IR_EVENT_COUNT: event_count = w; return;
    case IR_BINDING_STACK_POINTER: binding_stack_pointer = w; return;
    case IR_CATCH_BLOCK_LIST: catch_block_list = w; return;
    case IR_CONTROL_STACK_LIMIT: control_stack_limit = w; return;
    case IR_CONTROL_STACK_EXTRA_LIMIT: control_stack_extra_limit = w; return;
    case IR_BINDING_STACK_LIMIT: binding_stack_limit = w; return;
    case IR_PHT_BASE:
      if (log_errors) fprintf(stderr, "[cpu] PHT base := %08x at insn %llu\n", wdata(w), (unsigned long long)icount);
      pht_base = wdata(w); flush_map(); return;
    case IR_PHT_MASK:
      if (log_errors) fprintf(stderr, "[cpu] PHT mask := %08x at insn %llu\n", wdata(w), (unsigned long long)icount);
      pht_mask = wdata(w); flush_map(); return;
    case IR_COUNT_MAP_RELOADS: count_map_reloads = w; return;
    case IR_LIST_CACHE_AREA: list_cache_area = w; return;
    case IR_LIST_CACHE_ADDRESS: list_cache_address = w; return;
    case IR_LIST_CACHE_LENGTH: list_cache_length = w; return;
    case IR_STRUCTURE_CACHE_AREA: structure_cache_area = w; return;
    case IR_STRUCTURE_CACHE_ADDRESS: structure_cache_address = w; return;
    case IR_STRUCTURE_CACHE_LENGTH: structure_cache_length = w; return;
    case IR_DYNAMIC_BINDING_CACHE_BASE: dynamic_binding_cache_base = w; return;
    case IR_DYNAMIC_BINDING_CACHE_MASK: dynamic_binding_cache_mask = w; return;
    case IR_CHOICE_POINTER: choice_pointer = w; return;
    case IR_STRUCTURE_STACK_CHOICE_POINTER: structure_stack_choice_pointer = w; return;
    case IR_FEP_MODE_TRAP_VECTOR_ADDRESS: fep_mode_trap_vector_address = w; return;
    case IR_MAPPING_TABLE_CACHE: mapping_table_cache = w; return;
    case IR_MAPPING_TABLE_LENGTH: mapping_table_length = w; return;
    case IR_STACK_FRAME_MAXIMUM_SIZE: stack_frame_maximum_size = w; return;
    case IR_STACK_CACHE_DUMP_QUANTUM: stack_cache_dump_quantum = w; return;
    default: scratch[r & 0777] = w; return;
    }
  }
  switch (r) {
  case IR_FP: fp = wdata(w); return;
  case IR_LP: lp = wdata(w); return;
  case IR_SP: sp = wdata(w); return;
  case IR_STACK_CACHE_LOWER_BOUND: stack_cache_lower_bound = wdata(w); return;
  case IR_CONTINUATION: cont = stripcdr(w); return;
  case IR_ALU_AND_ROTATE_CONTROL: alu_control = wdata(w); return;
  case IR_CONTROL_REGISTER: cr = wdata(w); return;
  case IR_EPHEMERAL_OLDSPACE: ephemeral_oldspace = wdata(w); return;
  case IR_ZONE_OLDSPACE: zone_oldspace = wdata(w); return;
  case IR_FP_COPROCESSOR_PRESENT: fp_coprocessor_present = wdata(w); return;
  case IR_PREEMPT_REGISTER: preempt_register = wdata(w); return;
  case IR_ICACHE_CONTROL: icache_control = wdata(w); return;
  case IR_PREFETCHER_CONTROL: prefetcher_control = wdata(w); return;
  case IR_MAP_CACHE_CONTROL: map_cache_control = wdata(w); flush_map(); return;
  case IR_MEMORY_CONTROL: memory_control = wdata(w); return;
  case IR_STACK_CACHE_OVERFLOW_LIMIT: stack_cache_overflow_limit = wdata(w); return;
  case IR_ENTRY_MAXIMUM_ARGUMENTS: entry_max_args = wdata(w); return;
  default:
    if (trace && tracef) fprintf(tracef, "  write unknown internal register %o\n", r);
    return;
  }
}

