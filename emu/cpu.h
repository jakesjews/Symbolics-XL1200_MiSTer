// Ivory CPU model (instruction-level reference for the RTL).
#pragma once
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>
#include "ivory.h"

// The CPU's view of everything outside the chip: physical memory, devices,
// coprocessor registers, and the interrupt pins.
class Bus {
public:
  virtual ~Bus() {}
  virtual W phys_read(uint32_t pa) = 0;
  virtual void phys_write(uint32_t pa, W w) = 0;
  virtual W coproc_read(unsigned reg) = 0;
  virtual void coproc_write(unsigned reg, W w) = 0;
  virtual uint32_t microsecond_clock() = 0;
  virtual bool high_priority_sb() = 0;   // sequence break request pins
  virtual bool low_priority_sb() = 0;
  virtual bool reset_request() = 0;
  // Called when the CPU takes a sequence-break trap, so latched requests can clear.
  virtual void sb_taken(bool high) {}
};

// Thrown by coprocessor register accesses the bus doesn't implement.
struct CoprocError {};

// Thrown by the Bus for a physical address nothing responds to.
struct BusError { uint32_t pa; bool write; };
// Thrown to abandon the current instruction after the trap frame has been built.
struct InstructionAbort {};
// Thrown when the processor halts (processor fault or %halt in FEP with no handler).
struct ProcessorHalt { std::string why; };

// Error-trap condition codes.  The microstate passed to the error handler is
// looked up by Genera in the chip-revision error table; these are mapped to
// microstates by error_microstate().
enum ErrCond {
  E_NONE = 0,
  E_ALLOCATE_TYPE, E_DIVIDE_BIGNUM_STEP, E_INSTANCE_REF_TYPE_BINARY, E_INSTANCE_REF_TYPE_3,
  E_MEMORY_READ_TRANSPORT_FIXNUM, E_P_DPB_TYPE, E_ALOC_NON_OBJECT_ARRAY,
  E_ARRAY_ACCESS_TYPE_BINARY, E_ARRAY_ACCESS_TYPE_3, E_ARRAY_LEADER_TYPE_BINARY,
  E_ARRAY_LEADER_TYPE_3, E_ARRAY_REGISTER_FORMAT, E_ARRAY_REGISTER_FORMAT_OR_BOUNDS,
  E_ASSOC_ELEMENT_NOT_LIST, E_BAD_CDR_CODE, E_BINARY_ARITH_TYPE, E_BINARY_LEXENV_TYPE,
  E_BIND_LOCATIVE_TYPE, E_BINDING_STACK_OVERFLOW, E_BINDING_STACK_UNDERFLOW,
  E_BLOCK_READ_BINARY_TRANSPORT_FIXNUM, E_BLOCK_READ_TEST_TRANSPORT_FIXNUM,
  E_BLOCK_READ_TRANSPORT_FIXNUM, E_BRANCH_DOT, E_BYTE_ARRAY_WORD_TYPE,
  E_CAR_CDR_LIST_TYPE, E_CHAR_DPB_TYPE, E_CHAR_LDB_TYPE, E_CHARACTER_ARRAY_ASET_TYPE,
  E_DIVIDE_BY_ZERO, E_DIVIDE_OVERFLOW, E_FAST_ARRAY_ACCESS_TYPE, E_FIXNUM_ARRAY_ASET_TYPE,
  E_FLAVOR_SEARCH_MASK_NOT_FIXNUM, E_FLAVOR_SEARCH_TABLE_NOT_LOCATIVE, E_FRAME_OVERFLOW,
  E_GENERIC_SEARCH_ENTRY_NOT_PC, E_I_STAGE, E_ILLEGAL_FULL_WORD_INSTRUCTION,
  E_ILLEGAL_INSTANCE_VARIABLE_INDEX, E_INSTANCE_FLAVOR_TABLE_NOT_LOCATIVE,
  E_INTERPRETER_TABLE_NOT_PC, E_LIST_TAIL_NOT_LIST, E_MAPPING_TABLE_INDEX_BOUNDS,
  E_MEMORY_DATA_ERROR, E_NON_16_BIT_CHARACTER, E_NON_8_BIT_CHARACTER,
  E_ONE_OPERAND_FIXNUM_TYPE, E_ONE_OPERAND_LIST_TYPE, E_OPERAND_1_TYPE_LOCATIVE,
  E_OPERAND_LOCATIVE_TYPE, E_RPLACA_RPLACD_LIST_TYPE, E_SELF_MAPPING_TABLE_TYPE,
  E_SELF_TYPE, E_SET_TO_CAR_CDR_LIST_TYPE, E_SETUP_ARRAY_NOT_ARRAY, E_SHALLOW_BINDING_IN_DEEP,
  E_STACK_BLT_TYPE, E_SUBSCRIPT_BOUNDS, E_TAKE_VALUES_TYPE, E_THREE_OPERAND_FIXNUM_TYPE,
  E_TOO_FEW_ARGUMENTS, E_TOO_MANY_ARGUMENTS, E_TRAP_ON_EXIT, E_TWO_OPERAND_FIXNUM_TYPE,
  E_UNARY_ARITH_TYPE, E_UNARY_LEXENV_TYPE, E_UNARY_OPERAND_TYPE_PC, E_UNKNOWN_INTERNAL_REGISTER,
  E_COUNT
};

struct MapEntry {
  uint32_t vpn;       // virtual page number (VMA>>8); 0xFFFFFFFF = invalid
  uint32_t ppn;       // physical page number
  uint32_t access;    // PHT1 access bits <7:0>
  uint32_t pht_addr;  // physical address of the PHT0 word this entry came from
};

class Ivory {
  friend struct Snapshot;   // emu/snapshot.cpp: saves and restores the state
public:
  explicit Ivory(Bus* bus);

  void init();               // INIT pin: PC := init PC, trap mode := FEP
  void step();               // execute one instruction, taking any pending traps
  bool halted = false;
  std::string halt_reason;
  bool pushing_trap_frame = false;
  int fault_log = 0, sclb_log = 0;
  uint32_t last_vma = 0;
  // the last instruction word fetched; a processor write to its address
  // (virtual or physical, by number) forgets it
  bool ib_valid = false;
  uint32_t ib_addr = 0;
  W ib_word = 0;
  void cpu_write(uint32_t a) { if (a == ib_addr) ib_valid = false; }

  // ---- Architectural state ----
  uint64_t pc = 0;           // halfword address: word<<1 | odd
  uint32_t sp = 0, fp = 0, lp = 0;
  W cont = 0;                // continuation register (even/odd pc)
  uint32_t cr = 0;           // control register
  W bar[4] = {0, 0, 0, 0};
  uint32_t alu_control = 0;  // DP Op / alu-and-rotate-control
  uint32_t rotate_latch = 0;
  uint32_t ephemeral_oldspace = 0, zone_oldspace = 0;
  uint32_t fp_coprocessor_present = 0;
  uint32_t preempt_register = 0;
  uint32_t icache_control = 0, prefetcher_control = 0, map_cache_control = 0;
  uint32_t memory_control = 0;
  uint32_t stack_cache_lower_bound = 0, stack_cache_overflow_limit = 0;
  uint32_t entry_max_args = 0;
  W event_count = 0, binding_stack_pointer = 0, catch_block_list = 0;
  W control_stack_limit = 0, control_stack_extra_limit = 0, binding_stack_limit = 0;
  uint32_t pht_base = 0, pht_mask = 0;
  W count_map_reloads = 0;
  W list_cache_area = 0, list_cache_address = 0, list_cache_length = 0;
  W structure_cache_area = 0, structure_cache_address = 0, structure_cache_length = 0;
  W dynamic_binding_cache_base = 0, dynamic_binding_cache_mask = 0;
  W choice_pointer = 0, structure_stack_choice_pointer = 0;
  W fep_mode_trap_vector_address = 0;
  W mapping_table_cache = 0, mapping_table_length = 0;
  W stack_frame_maximum_size = 0, stack_cache_dump_quantum = 0;
  W scratch[01000] = {};     // scratchpad (internal registers 01000..01777 not otherwise named)
  uint32_t chip_revision = 4;

  // ---- Instrumentation ----
  uint64_t icount = 0;
  bool trace = false;
  FILE* tracef = nullptr;
  uint64_t trap_count = 0;
  int last_trap_vector = -1;

  // Memory access for tools/devices (raw, physical or VMA=PMA).
  W debug_read(uint32_t vma);
  bool debug_translate(uint32_t vma, uint32_t& pa);
  bool pht_walk(uint32_t vma, uint32_t& pa);   // the PHT alone, no map cache (error log)

  static const int MAP_SIZE = 4096;
  MapEntry map[MAP_SIZE];
  void flush_map();

private:
  Bus* bus;

  // per-instruction scratch
  uint64_t inst_pc = 0;      // PC of the instruction being executed
  uint64_t next_pc = 0;      // sequential successor
  uint32_t restart_sp = 0;   // SP at start of instruction (for pre-traps)
  int cur_opcode = 0;
  bool pc_changed = false;

  // ---- memory system ----
  uint32_t translate(uint32_t vma, bool write, W* data = nullptr);
  MapEntry* map_lookup(uint32_t vpn);
  MapEntry* map_fill(uint32_t vma);
  uint32_t pht_hash(uint32_t vpn);
  bool oldspace_address(uint32_t a);
  bool page_transport_enabled(uint32_t vma);
  void note_write(MapEntry* e, W data);

  W read_raw(uint32_t vma);
  void write_raw(uint32_t vma, W w);
  W read_addr(W addr);       // raw read where addr is a locative or physical address
  void write_addr(W addr, W w);
  W mem_read(W addr, int cycle, uint32_t* final_vma = nullptr);
  void mem_write(W addr, int cycle, W value, bool preserve_cdr = true);
  W fetch_word(uint32_t vma);  // instruction fetch

  // stack (write-through, held in memory)
  W sread(uint32_t a) { return read_raw(a); }
  void swrite(uint32_t a, W w) { write_raw(a, w); }
  W tos() { return sread(sp); }
  void push(W w) { swrite(sp + 1, setcdr(w, CDR_NEXT)); sp++; }
  void push_raw(W w) { swrite(sp + 1, w); sp++; }
  W pop() { W w = sread(sp); sp--; return w; }
  void set_tos(W w) { swrite(sp, setcdr(w, CDR_NEXT)); }

  // ---- traps ----
  [[noreturn]] void error_trap(int cond, uint32_t vma = 0);
  [[noreturn]] void memory_trap(int vector, W vma);
  [[noreturn]] void post_trap(int vector, int nargs, const W* args, uint64_t ret_pc);
  [[noreturn]] void instruction_exception(int nargs, const W* args);
  [[noreturn]] void arith_exception(int nargs, const W* args);
  void begin_trap_frame(int vector);
  void take_pre_trap(int vector, int nargs, const W* args);
  void take_post_trap(int vector, int nargs, const W* args, uint64_t ret_pc);
  W trap_vector_entry(int vector);
  void enter_trap_frame(int vector, uint32_t old_fp, W handler, uint64_t continuation_pc);
  void check_stack_overflow();
  void halt(const std::string& why);
  int error_microstate(int cond);
  int rev5_microstate(int cond);
  int err_detail = -1;       // data type or memory cycle refining the next error trap
public:
  bool log_errors = false;   // report error traps on stderr
  uint32_t pht_vma = 0;     // XLEMU_PHTVMA: report this page's PHT entry and map entry at flips, traps and the end
  bool pht_vma_on = false;
  void pht_report(const char* when);
  bool map_check = false;   // XLEMU_MAPCHECK: compare the map cache's PHT bits with the PHT on writes
  uint32_t watch_vma = 0;    // XLEMU_WATCH: log every read and write of this virtual address
  bool watch_on = false;
  int iv_phase = 0;          // an instance-variable instruction's memory reference under way (error log)
  W iv_map = 0, iv_self = 0, iv_off = 0;
  int iv_operand = 0;
  uint64_t opstats[258] = {};   // instructions by opcode (256: full-word, 257: entry) since opstats_clear()
  void opstats_clear() { for (auto& n : opstats) n = 0; }
private:

  // ---- calling ----
  void start_call(W fn, int extra_type_hint = -1);
  void finish_call(uint32_t nargs_including_bias, bool tos_form, bool apply, int disposition);
  void do_entry(uint32_t ins);
  void push_apply_args(int max, int nargs);
  bool pull_apply_args(int nargs_to_pull);
  void do_return(int kind, int arg, bool sp_pop);
  bool frame_cleanup();
  void catch_close(bool from_return);
  void unbind_one();
  void restore_binding_stack(uint32_t target);

  // ---- execution ----
  void execute_halfword(uint32_t h, int cdr);
  void execute_fullword(W w);
  void exec_op(int op, int operand);
  void branch_to(int offset);
  void set_pc(uint64_t p) { pc = p; pc_changed = true; }
  W pc_word(uint64_t p) { return mkw((p & 1) ? DTP_ODD_PC : DTP_EVEN_PC, (uint32_t)(p >> 1)); }

  // instruction groups
  void op_list(int op, int mode, int off);
  W car_of(W x, int errc);
  W cdr_of(W x, int errc);
  bool eql(W a, W b);
  void arith_binary(int op, W a, W b);
  void arith_unary(int op, W a);
  bool fpa_enabled() const { return fp_coprocessor_present & 1; }
  W fpa_op(int nargs, W a1, W a2, bool fixnum_multiply);
  W read_internal_register(int r);
  void write_internal_register(int r, W w);
  void op_block_read(int n, int imm, int kind);
  void op_block_write(int n, W v);
  uint32_t alu_compute(uint32_t op1, uint32_t op2, bool& cond, W w1, W w2);

  // operand helpers
  int operand_mode = 0, operand_off = 0;
  uint32_t operand_address();     // address-operand mode
  W operand_value(bool sign_extend_immediate);
  bool operand_popped = false;
};
