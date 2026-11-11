// Ivory processor (Symbolics I-machine).
//
// A state machine that executes one instruction at a time.  It follows the
// C++ reference model function by function (emu/cpu_core.cpp,
// emu/cpu_insn.cpp: the comments name the C++ routine each group of states
// implements); the Verilator testbench in sim/ runs both in lockstep.
//
// Memory is one 40-bit word per transaction.  Physical-address accesses
// (DTP-PHYSICAL-ADDRESS) are marked; the others are translated by
// ivory_mmu, which answers with the trap vector to take, if any (page not
// resident, page fault request, write fault), and the page's transport-trap
// bit.  The map-cache internal registers (PHT base and mask, map cache
// control, load and invalidate map) drive the MMU.
//
// Subroutines: states that end by returning use a small return stack
// (call/ret tasks).  Levels: MEM (raw access) < MRD/MWR/PUSH/POP/OPV <
// CARCDR/UNBIND/START-CALL resolution < cleanup loops.  A trap abandons the
// whole stack.
module ivory_cpu
  import ivory_pkg::*;
(
  input  logic        clk,
  input  logic        reset,
  input  logic        run,            // 0 holds the processor before its first instruction
  input  logic        hold,           // 1 holds it before the next instruction (lockstep:
                                      // the devices tick after each instruction)
  input  logic        dbg_we,         // while held: write a starting register
  input  logic [3:0]  dbg_sel,        // 0 pc, 1 sp, 2 fp, 3 lp, 4 cont, 5 cr,
                                      // 7 chip revision, 8 control stack limit, 9 extra limit
  input  word_t       dbg_data,

  output logic        mem_req,        // driven from the registered request (m_*) in S_MEM_W
  output logic        mem_we,
  output logic        mem_phys,       // a physical address (DTP-PHYSICAL-ADDRESS): no translation
  output logic [31:0] mem_addr,
  output word_t       mem_wdata,
  input  logic        mem_ack,
  input  word_t       mem_rdata,
  input  logic [11:0] mem_fault,      // with mem_ack: 0, or the trap vector to take
  input  logic        mem_buserr,     // with mem_ack: nothing at this address
  input  logic [31:0] mem_bus_pa,     // with mem_buserr: the physical address
  input  logic        mem_transport,  // with mem_ack: the page's transport-trap bit
  input  logic [31:0] mem_pa,         // with mem_ack: the physical address accessed

  // instruction cache (ivory_icache): looked up from the PC, filled on a miss
  input  logic        ic_hit,
  input  word_t       ic_word,
  output logic        ic_fill,
  output logic [31:0] ic_fill_va,
  output logic [31:0] ic_fill_pa,
  output word_t       ic_fill_word,
  output logic [31:0] ic_pc_a,        // the cache looks up pc_a (next_pc) when ic_sel_a, else pc_b (pc)
  output logic [31:0] ic_pc_b,
  output logic        ic_sel_a,
  output logic        icache_on,
  output logic        pf_on,
  output logic [3:0]  pf_high,

  output logic [31:0] pht_base_o,     // to the MMU
  output logic [31:0] pht_mask_o,
  output logic        map_flush,
  output logic        map_load,
  output logic        map_inval,
  output logic [23:0] map_vpn,
  output logic [31:0] map_data,
  input  logic        map_reload,

  output logic        cop_req,
  output logic        cop_we,
  output logic        cop_wait,       // a read that waits for a result in progress (FPA instructions)
  output logic [9:0]  cop_reg,
  output word_t       cop_wdata,
  input  logic        cop_ack,
  input  word_t       cop_rdata,
  input  logic        cop_err,        // with cop_ack: no such register

  input  logic        hp_sb,          // sequence break requests
  input  logic        lp_sb,
  input  logic        reset_req,
  output logic        hp_sb_taken,    // one-cycle pulses
  output logic        lp_sb_taken,
  input  logic [31:0] usec_clock,

  output logic        retire,         // one-cycle pulse at the end of each step
  output logic        retire_counted, // with retire: an instruction was executed
  output logic        halted,

  // status for the host
  output logic [1:0]  trap_mode,
  output logic [31:0] eos,            // ephemeral and zone oldspace registers
  output logic [31:0] zos,
  output logic [63:0] insn_count,
  output logic [7:0]  halt_reason,
  output logic [31:0] dbg_pc          // the word of the next instruction (debug display)
);

  // ---------------------------------------------------------------------------
  // Architectural state (public so the testbench can load and compare it)
  // ---------------------------------------------------------------------------
  logic [32:0] pc               /*verilator public_flat_rw*/;   // halfword address
  logic [31:0] sp               /*verilator public_flat_rw*/;
  logic [31:0] fp               /*verilator public_flat_rw*/;
  logic [31:0] lp               /*verilator public_flat_rw*/;
  word_t       cont             /*verilator public_flat_rw*/;
  logic [31:0] cr               /*verilator public_flat_rw*/;
  word_t       bar [4]          /*verilator public_flat_rw*/;
  logic [31:0] alu_control      /*verilator public_flat_rw*/;
  logic [31:0] rotate_latch     /*verilator public_flat_rw*/;
  logic [31:0] ephemeral_oldspace /*verilator public_flat_rw*/;
  logic [31:0] zone_oldspace    /*verilator public_flat_rw*/;
  logic [31:0] fp_coprocessor_present /*verilator public_flat_rw*/;
  logic [31:0] preempt_register /*verilator public_flat_rw*/;
  logic [31:0] icache_control   /*verilator public_flat_rw*/;
  logic [31:0] prefetcher_control /*verilator public_flat_rw*/;
  logic [31:0] map_cache_control /*verilator public_flat_rw*/;
  logic [31:0] memory_control   /*verilator public_flat_rw*/;
  logic [31:0] stack_cache_lower_bound /*verilator public_flat_rw*/;
  logic [31:0] stack_cache_overflow_limit /*verilator public_flat_rw*/;
  logic [31:0] entry_max_args   /*verilator public_flat_rw*/;
  logic [31:0] chip_revision    /*verilator public_flat_rw*/;
  logic [31:0] pht_base         /*verilator public_flat_rw*/;
  logic [31:0] pht_mask         /*verilator public_flat_rw*/;
  // Internal registers 01001-01031 that are whole words (index = register - 01000)
  word_t       irw [32]         /*verilator public_flat_rw*/;
  // Internal registers 01000-01777 not otherwise named (they power up as fixnum 0)
  word_t       scratch [512]    /*verilator public_flat_rw*/;
  initial for (int i = 0; i < 512; i++) scratch[i] = {2'b00, 6'o10, 32'd0};

  localparam int IRW_EVENT_COUNT = 1, IRW_BSP = 2, IRW_CATCH_BLOCK_LIST = 3,
    IRW_CONTROL_STACK_LIMIT = 4, IRW_CONTROL_STACK_EXTRA_LIMIT = 5, IRW_BSL = 6,
    IRW_COUNT_MAP_RELOADS = 9, IRW_LIST_CACHE_AREA = 10, IRW_LIST_CACHE_ADDRESS = 11,
    IRW_LIST_CACHE_LENGTH = 12, IRW_STRUCTURE_CACHE_AREA = 13, IRW_STRUCTURE_CACHE_ADDRESS = 14,
    IRW_STRUCTURE_CACHE_LENGTH = 15, IRW_FEP_MODE_TRAP_VECTOR_ADDRESS = 20,
    IRW_STACK_FRAME_MAXIMUM_SIZE = 24, IRW_STACK_CACHE_DUMP_QUANTUM = 25;
  // Registers in 01001-01031 kept in IRW; the others in that range are scratch.
  function automatic logic irw_reg(logic [9:0] r);
    case (r)
      10'o1001, 10'o1002, 10'o1003, 10'o1004, 10'o1005, 10'o1006, 10'o1011, 10'o1012,
      10'o1013, 10'o1014, 10'o1015, 10'o1016, 10'o1017, 10'o1020, 10'o1021, 10'o1022,
      10'o1023, 10'o1024, 10'o1026, 10'o1027, 10'o1030, 10'o1031: return 1'b1;
      default: return 1'b0;
    endcase
  endfunction

  // Instrumentation
  logic [63:0] icount           /*verilator public_flat_rw*/;
  logic [63:0] trap_count       /*verilator public_flat_rw*/;
  logic [11:0] last_trap_vector /*verilator public_flat_rw*/;
  logic [7:0]  halt_code        /*verilator public_flat_rw*/;

  // ---------------------------------------------------------------------------
  // States
  // ---------------------------------------------------------------------------
`include "ivory_cpu_state_enum.svh"

  state_t st /*verilator public_flat_rw*/;
  state_t rstack [8];
  logic [2:0] rsp;

  // Per-instruction context
  logic [32:0] inst_pc, next_pc;
  logic [31:0] restart_sp;
  logic        pc_changed, trace_insn, count_insn;
  word_t       iw;                    // instruction word
  logic        fetch_mem;            // the instruction word came from memory (not the cache)
  logic [31:0] m_pa;                  // physical address of the last memory access
  logic        m_pa_valid;
  logic [7:0]  op;
  logic [9:0]  operand;
  logic [1:0]  omode;
  logic [7:0]  ooff;
  logic [31:0] oaddr_r;               // the operand address, summed at decode for S_EXEC
  logic        opv_sign;              // OPV: sign-extend an immediate
  word_t       opv;                   // OPV result
  logic        opv_popped;
  logic        opv_pre;               // the operand was read from the stack cache at decode
  word_t       a1, a2, a3, val, t0, t1, t2;
  logic        t0_max;                // loop-increment: t0 is the most positive fixnum
  logic [31:0] addr, cnt, x0, x1;
  logic [63:0] q64;
  logic [10:0] guard;
  logic [15:0] loopn;

  // Stack cache (docs/ivory.md): 128 words shadowing [lower bound, +127],
  // read combinationally from a registered address, written a cycle after
  // the state that asks for it.  A memory cycle (an address from a pointer)
  // is the cache's inside the window.  A stack reference (FP, LP or SP
  // relative, a push, a pop) is the cache's word at address bits 6:0
  // wherever it points, as on the chip, which has no other place for one
  // (the FEP moves FP and SP to its own stack before the lower bound and
  // reads its locals there); only in the 128 words under the window, which
  // a dump has put in memory, does it go to memory.
  // Two copies of the data: one read for the operand pre-read and the TOS
  // reload (sc_ra), one by the memory-access stage from the request's
  // address (m_addr); both written together.
  word_t       sc_data [128]    /*verilator public_flat_rw*/;
  word_t       sc_data2 [128];
  logic [6:0]  sc_ra, sc_wa;
  logic        sc_we;
  word_t       sc_wd, sc_q, sc_q_m;
  logic        sc_busy;               // dumping or refilling: a fault halts
  logic [31:0] sc_a, sc_end;          // dump / refill cursor and end
  assign sc_q = sc_data[sc_ra];
  always_ff @(posedge clk) if (sc_we) begin sc_data[sc_wa] <= sc_wd; sc_data2[sc_wa] <= sc_wd; end

  // a stack reference to a: the cache's, unless a is in [lower bound - 128, lower bound)
  function automatic logic stk_cached(logic [31:0] a);
    logic [31:0] d;
    d = a - stack_cache_lower_bound;
    return !(&d[31:7]);
  endfunction
  // the checks the states share (a task inlines at every call)
  logic        sp_in_window, spm1_in_window, spp1_in_window;
  logic [31:0] sp_p1;
  logic        push_trig;            // a push to sp_p1 overflows the stack cache: SP<6:2> at the limit's
  assign sp_p1 = sp + 32'd1;
  assign sp_in_window = stk_cached(sp);
  assign spm1_in_window = stk_cached(sp - 32'd1);
  assign spp1_in_window = stk_cached(sp_p1);
  assign push_trig = (sp_p1 & 32'h7C) == (stack_cache_overflow_limit & 32'h7C);
  // the dump quantum register (01031): 32 at reset and for values the cache can't dump
  function automatic logic [31:0] sc_quantum();
    logic [31:0] q;
    q = irw[IRW_STACK_CACHE_DUMP_QUANTUM][31:0];
    return (q == 32'd0 || q > 32'd128) ? 32'd32 : q;
  endfunction

  // The top of the stack in a register (the chip keeps a copy of it in its
  // scratchpad): tos is the word at tos_sp; after a pop the new top is read
  // from the cache in the next cycle (tos_reload), when sc_q has it
  word_t       tos;
  logic [31:0] tos_sp;
  logic        tos_valid, tos_reload;
  word_t       tos_q;
  logic        tos_ok;
  assign tos_q = tos_reload ? sc_q : tos;
  assign tos_ok = sp_in_window && (tos_reload || (tos_valid && tos_sp == sp));

  // The memory-access stage (S_MEM_W): the request, registered by the
  // state that makes it; decided and issued there, once for all callers
  logic [31:0] m_addr;
  logic        m_we, m_phys;
  logic        m_through;             // a memory cycle's write: memory as well as the cache
  logic        m_bypass;              // never the cache (dump, refill, a push under the window)
  logic        m_stk;                 // a stack reference: stk_cached decides, not the window
  logic        m_first;               // the request hasn't been looked at yet
  logic        m_wait;                // waiting for the memory
  logic        m_cached;
  logic        m_chk, m_wchk;         // a cycle-typed read's / write's check on the data
  logic        m_trans;               // the page accessed has transport traps enabled
  word_t       m_wd, m_rd;
  assign sc_q_m = sc_data2[m_addr[6:0]];
  // A memory cycle inside the window (offset bits 31:7 all zero), or a
  // stack reference not under it (not all one).  One level of five-bit
  // groups serves both, the kind of access selected inside each (this is
  // ahead of the memory request): a group answers "has a one" for a memory
  // cycle and "has a zero" for a stack reference, and the access is the
  // cache's when any group's answer equals m_stk.
  wire [31:0] m_off = m_addr - stack_cache_lower_bound;
  logic [4:0] m_grp;
  always_comb
    for (int g = 0; g < 5; g++)
      m_grp[g] = m_stk ? !(&m_off[7 + 5 * g +: 5]) : |m_off[7 + 5 * g +: 5];
  assign m_cached = !m_phys && !m_bypass && ((|m_grp) == m_stk);
  assign mem_req = st == S_MEM_W && (m_first ? !m_cached || (m_we && m_through) : m_wait);
  assign mem_we = m_we;
  assign mem_addr = m_addr;
  assign mem_wdata = m_wd;
  assign mem_phys = m_phys;
  // MRD / MWR subroutines
  logic [3:0]  mr_cyc;
  word_t       mr_d;                  // result
  logic [31:0] mr_final;              // address the data came from
  logic        mr_phys;
  logic [16:0] mr_hops;
  word_t       mw_v;
  logic [3:0]  mw_cyc;
  logic        mw_preserve, mw_phys;
  // PUSH / POP
  word_t       p_w, pop_w;
  // CARCDR
  word_t       cc_x, cc_r;
  logic        cc_car, cc_bad;
  // Division: n / d, unsigned, 64-bit quotient
  logic [63:0] dv_n, dv_q;
  logic [31:0] dv_d;
  logic [32:0] dv_r;
  logic [6:0]  dv_i;

  // Traps
  logic [11:0] tr_vec;
  logic [2:0]  tr_nargs, tr_i;
  word_t       tr_args [5];
  logic        tr_post;
  logic [32:0] tr_retpc;
  logic        in_trap;
  word_t       tr_handler;
  logic [31:0] tr_oldfp, tr_cr;
  logic [6:0]  err_cond;
  logic [31:0] err_vma;
  logic [7:0]  err_detail;            // cycle type or data type refining the condition
  logic        err_detail_valid;

  // Returns
  logic [1:0]  ret_kind;              // 0 single, 1 multiple, 2 kludge
  logic [9:0]  ret_arg;
  logic        ret_sppop;
  logic [31:0] ret_nvals, ret_vbase;
  word_t       ret_single;
  logic [1:0]  ret_disp;
  logic [31:0] ret_oldcr;
  // the caller's frame starts below the stack cache: refill it after the
  // values are in place, the last thing a return does (spec 4.4); refilling
  // first moved the window down over values still in the callee's frame
  logic        ret_fill;
  state_t      ret_end;               // where a return goes once its values are placed
  assign ret_end = ret_fill ? S_RET_FILL : S_RETIRE;

  // ---------------------------------------------------------------------------
  // Combinational helpers
  // ---------------------------------------------------------------------------
  wire [1:0] mode = cr[31:30];
  assign trap_mode = mode;
  assign pht_base_o = pht_base;
  assign pht_mask_o = pht_mask;
  assign eos = ephemeral_oldspace;
  assign zos = zone_oldspace;
  assign insn_count = icount;
  assign halt_reason = halt_code;
  assign dbg_pc = pc[32:1];
  // the cache lookup: in the retire cycle, the next instruction's PC
  assign ic_pc_a = next_pc[32:1];
  assign ic_pc_b = pc[32:1];
  assign ic_sel_a = st == S_RETIRE && !pc_changed;
  assign icache_on = icache_control[0];
  assign pf_on = prefetcher_control[0];
  assign pf_high = prefetcher_control[8:5];

  function automatic logic oldspace_address(logic [31:0] a);
    if (a[31:27] == 5'd0) return a[26] == ephemeral_oldspace[a[25:21]];
    return zone_oldspace[a[31:27]];
  endfunction

  function automatic logic [31:0] rotl(logic [31:0] x, logic [4:0] n);
    logic [63:0] d;
    d = {x, x} << n;
    return d[63:32];
  endfunction

  function automatic logic [31:0] low_mask(logic [5:0] size);   // size 1..32 bits
    logic [63:0] m;
    m = ~(64'hFFFFFFFFFFFFFFFF << size);
    return m[31:0];
  endfunction

  // Operand address (operand_address); mode 3 is an error trap, checked by the
  // caller.  Summed at decode into oaddr_r (FP, LP and SP are final by then:
  // the retiring instruction's pushes and pops are done before it decodes
  // the next), so S_EXEC's paths start at a register and not at the adder.
  wire [31:0] oaddr = oaddr_r;

  // %alu, %block-n-read-alu and %block-n-read-test (alu_compute)
  typedef struct packed {
    logic [31:0] result;
    logic        cond;
    logic        rl_we;
    logic [31:0] rl;
    logic [31:0] ac;
  } alu_t;

  function automatic alu_t alu_compute(logic [31:0] o1, logic [31:0] o2, word_t w1, word_t w2);
    alu_t r;
    logic [31:0] ac, bg, mask, rotated;
    logic [4:0] rot, size;
    logic signed [33:0] s, o2s;
    logic [32:0] u;
    logic ovf, borrow, lt, v;
    ac = alu_control;
    r = '0;
    r.ac = ac;
    ovf = 1'b0; borrow = 1'b0; lt = 1'b0;
    case (ac[15:14])
      2'd0: begin
        case (ac[13:10])
          4'd0: r.result = 32'd0;
          4'd1: r.result = o1 & o2;
          4'd2: r.result = ~o1 & o2;
          4'd3: r.result = o2;
          4'd4: r.result = o1 & ~o2;
          4'd5: r.result = o1;
          4'd6: r.result = o1 ^ o2;
          4'd7: r.result = o1 | o2;
          4'd8: r.result = ~(o1 | o2);
          4'd9: r.result = ~(o1 ^ o2);
          4'd10: r.result = ~o1;
          4'd11: r.result = ~o1 | o2;
          4'd12: r.result = ~o2;
          4'd13: r.result = o1 | ~o2;
          4'd14: r.result = ~(o1 & o2);
          default: r.result = 32'hFFFFFFFF;
        endcase
      end
      2'd1: begin
        rot = ac[4:0];
        size = ac[9:5];
        bg = ac[11:10] == 2'd0 ? o1 : ac[11:10] == 2'd1 ? rotate_latch : 32'd0;
        rotated = rotl(o2, rot);
        mask = low_mask({1'b0, size} + 6'd1);
        if (!ac[13]) mask = mask << rot;   // dpb
        r.rl_we = ac[12];
        r.rl = rotated;
        r.result = (rotated & mask) | (bg & ~mask);
      end
      2'd2: begin
        case (ac[12:11])
          2'd0: o2s = {{2{o2[31]}}, o2};
          2'd1: o2s = '0;
          2'd2: o2s = -{{2{o2[31]}}, o2};
          default: o2s = -34'sd1;
        endcase
        s = {{2{o1[31]}}, o1} + o2s + {33'd0, ac[10]};
        r.result = s[31:0];
        ovf = s != {{2{s[31]}}, s[31:0]};
        borrow = o1 < o2;
        lt = $signed(o1) < $signed(o2);
        if (ac[24]) begin
          u = {1'b0, o1} + {1'b0, o2s[31:0]} + {32'd0, ac[10]};
          r.ac[10] = u[32];
        end
      end
      default: r.result = 32'd0;
    endcase
    case (ac[20:16])
      5'd0: v = lt || r.result == 32'd0;
      5'd1: v = lt;
      5'd2: v = r.result[31];
      5'd3: v = ovf;
      5'd4: v = borrow || r.result == 32'd0;
      5'd5: v = borrow;
      5'd6: v = r.result == 32'd0;
      5'd7: v = r.result[31:7] == 25'd0;
      5'd8: v = r.result == 32'd0 && wtype(w1) == wtype(w2);
      5'd9: v = is_pointer_type(wtype(w1)) && w1[31:27] == 5'd0;
      5'd12: v = wtype(w1) == DTP_NIL;
      5'd13: v = wtype(w2) == DTP_FIXNUM;
      5'd15: v = w1[38];
      5'd16: v = cr[26:24] != 3'd0;
      5'd19: v = cr[31:30] != 2'd0;
      5'd20: v = cr[31:30] == 2'd3;
      5'd21: v = fp_coprocessor_present[0];
      5'd22: v = is_pointer_type(wtype(w1)) && oldspace_address(w1[31:0]);
      default: v = 1'b0;
    endcase
    r.cond = ac[21] ? !v : v;
    return r;
  endfunction

  // One rotator, two field masks and one %alu for all the instructions
  // that need them (a function inlines at every call): their inputs are
  // loaded the cycle before (the pops and the memory stage load the value)
  logic [31:0] rot_x, rot_q;
  logic [4:0]  rot_n;
  logic [5:0]  msk_n, msk2_n;
  logic [31:0] msk_q, msk2_q;
  word_t       alu_w1, alu_w2;
  alu_t        alu_q;
  assign rot_q = rotl(rot_x, rot_n);
  assign msk_q = low_mask(msk_n);
  assign msk2_q = low_mask(msk2_n);
  assign alu_q = alu_compute(alu_w1[31:0], alu_w2[31:0], alu_w1, alu_w2);

  // Microstate for the error handler (error_microstate): the rev-5 numbering
  function automatic logic [31:0] error_microstate(logic [6:0] cond, logic dvalid, logic [7:0] detail);
    if (cond <= E_I_STAGE) return {25'd0, cond};
    if (cond == E_ILLEGAL_FULL_WORD_INSTRUCTION) begin
      case (detail[5:0])
        DTP_BOUND_LOCATION: return 32'd39;
        DTP_ELEMENT_FORWARD: return 32'd40;
        DTP_GC_FORWARD: return 32'd41;
        DTP_HEADER_FORWARD: return 32'd42;
        DTP_HEADER_I: return 32'd43;
        DTP_HEADER_P: return 32'd44;
        DTP_LOGIC_VARIABLE: return 32'd45;
        DTP_MONITOR_FORWARD: return 32'd46;
        DTP_NULL: return 32'd47;
        DTP_ONE_Q_FORWARD: return 32'd48;
        default: return 32'd39;
      endcase
    end
    if (cond < E_MEMORY_DATA_ERROR) return {25'd0, cond} + 32'd9;
    if (cond == E_MEMORY_DATA_ERROR) begin
      if (!dvalid) return 32'd57;
      case (detail[3:0])
        CYC_BIND_READ, CYC_BIND_READ_NO_MONITOR: return 32'd54;
        CYC_BIND_WRITE, CYC_BIND_WRITE_NO_MONITOR: return 32'd55;
        CYC_CDR: return 32'd56;
        CYC_DATA_WRITE: return 32'd58;
        CYC_HEADER, CYC_STRUCTURE_OFFSET: return 32'd59;
        CYC_SCAVENGE, CYC_GC_COPY: return 32'd60;
        default: return 32'd57;
      endcase
    end
    return {25'd0, cond} + 32'd15;
  endfunction

  // Rev-5 microstate -> a rev-4 microstate with the same trap descriptor in
  // Genera's DBG:*TRAP-DISPATCH-TABLES* (tools/errortable.py; emu/cpu_core.cpp)
  function automatic logic [10:0] rev4_microstate(logic [31:0] m);
    case (m[6:0])
      7'd0: return 11'd0;
      7'd1: return 11'd1828;
      7'd2: return 11'd1820;
      7'd3: return 11'd1872;
      7'd4: return 11'd1876;
      7'd5: return 11'd71;
      7'd6: return 11'd1288;
      7'd7: return 11'd152;
      7'd8: return 11'd1832;
      7'd9: return 11'd1824;
      7'd10: return 11'd1848;
      7'd11: return 11'd1840;
      7'd12: return 11'd160;
      7'd13: return 11'd159;
      7'd14: return 11'd1466;
      7'd15: return 11'd87;
      7'd16: return 11'd1544;
      7'd17: return 11'd1664;
      7'd18: return 11'd1044;
      7'd19: return 11'd2007;
      7'd20: return 11'd1997;
      7'd21: return 11'd71;
      7'd22: return 11'd71;
      7'd23: return 11'd71;
      7'd24: return 11'd1423;
      7'd25: return 11'd72;
      7'd26: return 11'd1214;
      7'd27: return 11'd2020;
      7'd28: return 11'd1508;
      7'd29: return 11'd69;
      7'd30: return 11'd1369;
      7'd31: return 11'd2043;
      7'd32: return 11'd155;
      7'd33: return 11'd68;
      7'd34: return 11'd1899;
      7'd35: return 11'd1903;
      7'd36: return 11'd181;
      7'd37: return 11'd1035;
      7'd38: return 11'd286;
      7'd39: return 11'd1;
      7'd40: return 11'd1;
      7'd41: return 11'd1;
      7'd42: return 11'd1;
      7'd43: return 11'd1;
      7'd44: return 11'd1;
      7'd45: return 11'd1;
      7'd46: return 11'd1;
      7'd47: return 11'd1;
      7'd48: return 11'd1;
      7'd49: return 11'd143;
      7'd50: return 11'd1782;
      7'd51: return 11'd1982;
      7'd52: return 11'd86;
      7'd53: return 11'd143;
      7'd54: return 11'd71;
      7'd55: return 11'd71;
      7'd56: return 11'd71;
      7'd57: return 11'd71;
      7'd58: return 11'd71;
      7'd59: return 11'd71;
      7'd60: return 11'd71;
      7'd61: return 11'd77;
      7'd62: return 11'd78;
      7'd63: return 11'd1288;
      7'd64: return 11'd1032;
      7'd65: return 11'd1044;
      7'd66: return 11'd1044;
      7'd67: return 11'd1210;
      7'd68: return 11'd1312;
      7'd69: return 11'd1320;
      7'd70: return 11'd1214;
      7'd71: return 11'd1036;
      7'd72: return 11'd122;
      7'd73: return 11'd1616;
      7'd74: return 11'd143;
      7'd75: return 11'd1414;
      7'd76: return 11'd1186;
      7'd77: return 11'd52;
      7'd78: return 11'd1555;
      7'd79: return 11'd1225;
      7'd80: return 11'd1600;
      7'd81: return 11'd1136;
      7'd82: return 11'd1088;
      7'd83: return 11'd1060;
      7'd84: return 11'd143;
      default: return 11'd0;
    endcase
  endfunction

  // The array element of type etype from its bits x (extracted by the
  // rotator and mask) and the word they came from
  function automatic word_t array_element(word_t word, logic [1:0] etype, logic [31:0] x);
    case (etype)
      2'd0: return fixnum(x);
      2'd1: return mkw(DTP_CHARACTER, x);
      2'd2: return boolw(x != 32'd0);
      default: return mkw(wtype(word), x);
    endcase
  endfunction


`include "ivory_cpu_states.svh"

endmodule
