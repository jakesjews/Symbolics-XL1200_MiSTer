// Ivory processor (Symbolics I-machine).
//
// A state machine that executes one instruction at a time.  It follows the
// C++ reference model function by function (emu/cpu_core.cpp,
// emu/cpu_insn.cpp: the comments name the C++ routine each group of states
// implements); the Verilator testbench in sim/ runs both in lockstep.
//
// Memory is one 40-bit word per transaction.  Physical-address accesses
// (DTP-PHYSICAL-ADDRESS) are marked; for the others the memory system answers
// with the trap vector to take, if any (page not resident, write fault,
// transport, ...).
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
  input  logic        dbg_we,         // while held: write a starting register
  input  logic [3:0]  dbg_sel,        // 0 pc, 1 sp, 2 fp, 3 lp, 4 cont, 5 cr,
                                      // 7 chip revision, 8 control stack limit, 9 extra limit
  input  word_t       dbg_data,

  output logic        mem_req,
  output logic        mem_we,
  output logic        mem_phys,       // a physical address (DTP-PHYSICAL-ADDRESS): no translation
  output logic [31:0] mem_addr,
  output word_t       mem_wdata,
  input  logic        mem_ack,
  input  word_t       mem_rdata,
  input  logic [11:0] mem_fault,      // with mem_ack: 0, or the trap vector to take
  input  logic        mem_buserr,     // with mem_ack: nothing at this address

  output logic        cop_req,
  output logic        cop_we,
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
    IRW_STACK_FRAME_MAXIMUM_SIZE = 24;
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
  // The last instruction word fetched: the second halfword instruction in a
  // word needn't fetch it again.  Forgotten when the processor writes that
  // word, and at every coprocessor operation (life support may change memory
  // or page attributes then).
  logic        ib_valid;
  logic [31:0] ib_addr;
  word_t       ib_word;
  logic [7:0]  op;
  logic [9:0]  operand;
  logic [1:0]  omode;
  logic [7:0]  ooff;
  logic        opv_sign;              // OPV: sign-extend an immediate
  word_t       opv;                   // OPV result
  logic        opv_popped;
  word_t       a1, a2, a3, val, t0, t1, t2;
  logic [31:0] addr, cnt, x0, x1;
  logic [63:0] q64;
  logic [10:0] guard;
  logic [15:0] loopn;

  // MEM subroutine
  logic [31:0] m_addr;
  logic        m_we, m_phys;
  word_t       m_wd, m_rd;
  // MRD / MWR subroutines
  word_t       mr_a;                  // address word (locative-like or physical)
  logic [3:0]  mr_cyc;
  word_t       mr_d;                  // result
  logic [31:0] mr_final;              // address the data came from
  logic        mr_phys;
  logic [16:0] mr_hops;
  word_t       mw_a, mw_v;
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

  // ---------------------------------------------------------------------------
  // Combinational helpers
  // ---------------------------------------------------------------------------
  wire [1:0] mode = cr[31:30];
  assign trap_mode = mode;
  assign eos = ephemeral_oldspace;
  assign zos = zone_oldspace;
  assign insn_count = icount;
  assign halt_reason = halt_code;
  assign dbg_pc = pc[32:1];

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

  // Operand address (operand_address); mode 3 is an error trap, checked by the caller
  wire [31:0] oaddr = omode == 2'd0 ? fp + {24'd0, ooff} :
                      omode == 2'd1 ? lp + {24'd0, ooff} :
                                      sp + {24'd0, ooff} - 32'd255;

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

  // PHT hash box (spec 2.3.2), for %read-internal-register PHT-HASH
  function automatic logic [31:0] pht_hash(logic [31:0] vma);
    logic [31:0] h;
    h = '0;
    h[3]  = vma[12] ^ vma[27]; h[4]  = vma[11] ^ vma[28]; h[5]  = vma[10] ^ vma[29];
    h[6]  = vma[9]  ^ vma[30]; h[7]  = vma[8]  ^ vma[31]; h[8]  = vma[13] ^ vma[20];
    h[9]  = vma[14] ^ vma[22]; h[10] = vma[15] ^ vma[21]; h[11] = vma[16] ^ vma[26];
    h[12] = vma[17] ^ vma[25]; h[13] = vma[18] ^ vma[24]; h[14] = vma[19] ^ vma[23];
    h[15] = vma[12] ^ vma[16]; h[16] = vma[11] ^ vma[17]; h[17] = vma[10] ^ vma[18];
    h[18] = vma[9]  ^ vma[19]; h[19] = vma[8]  ^ vma[20]; h[20] = vma[13] ^ vma[25];
    h[21] = vma[14] ^ vma[26]; h[22] = vma[15] ^ vma[27]; h[23] = vma[21] ^ vma[31];
    h[24] = vma[22] ^ vma[30]; h[25] = vma[23] ^ vma[29];
    return h;
  endfunction

  // Array element extraction for aref (byte-packed or not)
  function automatic word_t array_element(word_t word, logic [2:0] bp, logic [1:0] etype,
                                          logic [31:0] idx);
    logic [31:0] x;
    logic [5:0] bits;
    logic [4:0] sub;
    x = word[31:0];
    if (bp != 3'd0) begin
      bits = 6'd32 >> bp;
      sub = idx[4:0] & ((5'd1 << bp) - 5'd1);
      x = (x >> (sub * bits)) & low_mask(bits);
    end
    case (etype)
      2'd0: return fixnum(x);
      2'd1: return mkw(DTP_CHARACTER, x);
      2'd2: return boolw(x != 32'd0);
      default: return mkw(wtype(word), x);
    endcase
  endfunction

  function automatic logic [31:0] array_insert(logic [31:0] x, logic [31:0] v, logic [2:0] bp,
                                               logic [31:0] idx);
    logic [5:0] bits;
    logic [4:0] sub;
    logic [31:0] m;
    if (bp == 3'd0) return v;
    bits = 6'd32 >> bp;
    sub = idx[4:0] & ((5'd1 << bp) - 5'd1);
    m = low_mask(bits) << (sub * bits);
    return (x & ~m) | ((v << (sub * bits)) & m);
  endfunction

`include "ivory_cpu_states.svh"

endmodule
