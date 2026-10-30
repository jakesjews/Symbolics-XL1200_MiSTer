// Ivory processor states (included in ivory_cpu.sv).

  // Extra per-instruction registers used by the states below
  word_t       ub_old, ub_loc;        // unbind_one
  word_t       sc_target, sc_extra;   // start-call resolution
  logic        sc_hx, sc_odd;
  logic [31:0] pull_n;
  logic [7:0]  e_min, e_max;          // entry instruction (biased counts)
  logic [31:0] e_index;
  logic        e_apply;
  word_t       e_tos;
  logic [31:0] cb, ka, desc;
  logic        uwp, from_return;
  logic [2:0]  bp;
  logic [1:0]  etype;
  logic [31:0] idx, base, len;
  logic [2:0]  pops;
  logic        cond_r;
  alu_t        alu_r;
  logic [8:0]  scratch_rd_ix;
  word_t       scratch_rd;

  // ---------------------------------------------------------------------------
  // Subroutine and trap helpers
  // ---------------------------------------------------------------------------
  task automatic call(input state_t target, input state_t r);
    rstack[rsp] <= r;
    rsp <= rsp + 3'd1;
    st <= target;
  endtask

  task automatic ret();
    st <= rstack[rsp - 3'd1];
    rsp <= rsp - 3'd1;
  endtask

  // Start a memory access now; S_MEM_W waits for it.  (S_MEM starts one from
  // m_addr, m_we, m_wd and m_phys a cycle later.)
  task automatic mem_rd(input logic [31:0] a, input logic phys);
    m_addr <= a; m_we <= 1'b0; m_phys <= phys;
    mem_req <= 1'b1; mem_we <= 1'b0; mem_addr <= a; mem_phys <= phys;
  endtask
  task automatic mem_wr(input logic [31:0] a, input word_t w, input logic phys);
    m_addr <= a; m_we <= 1'b1; m_wd <= w; m_phys <= phys;
    mem_req <= 1'b1; mem_we <= 1'b1; mem_addr <= a; mem_wdata <= w; mem_phys <= phys;
  endtask
  // read_raw / write_raw: virtual address, page attributes checked outside the stack window
  task automatic sread(input logic [31:0] a, input state_t r);
    mem_rd(a, 1'b0);
    call(S_MEM_W, r);
  endtask
  task automatic swrite(input logic [31:0] a, input word_t w, input state_t r);
    mem_wr(a, w, 1'b0);
    call(S_MEM_W, r);
  endtask
  // read_addr / write_addr: a locative-like word or a dtp-physical-address
  task automatic read_addr(input word_t a, input state_t r);
    mem_rd(a[31:0], wtype(a) == DTP_PHYSICAL_ADDRESS);
    call(S_MEM_W, r);
  endtask
  task automatic write_addr(input word_t a, input word_t w, input state_t r);
    mem_wr(a[31:0], w, wtype(a) == DTP_PHYSICAL_ADDRESS);
    call(S_MEM_W, r);
  endtask
  task automatic mrd(input word_t a, input logic [3:0] cyc, input state_t r);
    mr_a <= a; mr_cyc <= cyc;
    call(S_MRD, r);
  endtask
  task automatic mwr(input word_t a, input logic [3:0] cyc, input word_t v, input logic pres,
                     input state_t r);
    mw_a <= a; mw_cyc <= cyc; mw_v <= v; mw_preserve <= pres;
    call(S_MWR, r);
  endtask
  task automatic push(input word_t w, input state_t r);
    p_w <= setcdr(w, CDR_NEXT);
    call(S_PUSH, r);
  endtask
  task automatic push_raw(input word_t w, input state_t r);
    p_w <= w;
    call(S_PUSH, r);
  endtask
  task automatic pop(input state_t r);
    call(S_POP, r);
  endtask
  task automatic opval(input logic sgn, input state_t r);
    opv_sign <= sgn;
    call(S_OPV, r);
  endtask
  task automatic carcdr(input word_t x, input logic car, input state_t r);
    cc_x <= x; cc_car <= car;
    call(S_CC, r);
  endtask
  task automatic set_pc(input logic [32:0] p);
    pc <= p;
    pc_changed <= 1'b1;
  endtask
  task automatic branch(input logic [9:0] off);
    set_pc(inst_pc + {{23{off[9]}}, off});
  endtask

  // error_trap: a pre-trap to the error vector
  // A trap while a trap frame is being built halts the processor.
  task automatic err(input logic [6:0] c, input logic [31:0] vma);
    err_cond <= c; err_vma <= vma; err_detail_valid <= 1'b0;
    rsp <= '0;
    st <= in_trap ? S_HALT : S_ERR;
  endtask
  task automatic err_d(input logic [6:0] c, input logic [31:0] vma, input logic [7:0] d);
    err_cond <= c; err_vma <= vma; err_detail <= d; err_detail_valid <= 1'b1;
    rsp <= '0;
    st <= in_trap ? S_HALT : S_ERR;
  endtask
  task automatic pre_trap(input logic [11:0] vec, input logic [2:0] n);
    tr_vec <= vec; tr_nargs <= n; tr_post <= 1'b0;
    rsp <= '0;
    st <= in_trap ? S_HALT : S_TRAP;
  endtask
  task automatic post_trap(input logic [11:0] vec, input logic [2:0] n, input logic [32:0] rpc);
    tr_vec <= vec; tr_nargs <= n; tr_post <= 1'b1; tr_retpc <= rpc;
    rsp <= '0;
    st <= in_trap ? S_HALT : S_TRAP;
  endtask
  // instruction_exception (arguments already popped)
  task automatic exc(input logic [2:0] n, input word_t x, input word_t y, input word_t z);
    tr_args[0] <= x; tr_args[1] <= y; tr_args[2] <= z;
    post_trap(TV_INSTRUCTION_EXCEPTION + {4'd0, op}, n, next_pc);
  endtask
  // arith_exception
  task automatic arith_exc(input logic [2:0] n, input word_t x, input word_t y);
    tr_args[0] <= x; tr_args[1] <= y;
    post_trap(TV_ARITHMETIC + {1'b0, op[4:0], x[34:32], n > 3'd1 ? y[34:32] : 3'd0}, n, next_pc);
  endtask
  task automatic halt(input logic [7:0] code);
    halt_code <= code;
    st <= S_HALT;
  endtask

  // aset type checks for an array element type and byte packing; E_NONE if OK
  function automatic logic [6:0] aset_check(word_t v, logic [1:0] et, logic [2:0] b);
    case (et)
      2'd1: begin
        if (wtype(v) != DTP_CHARACTER) return E_CHARACTER_ARRAY_ASET_TYPE;
        if (b == 3'd2 && v[31:8] != 24'd0) return E_NON_8_BIT_CHARACTER;
        if (b == 3'd1 && v[31:16] != 16'd0) return E_NON_16_BIT_CHARACTER;
        return E_NONE;
      end
      2'd0: return is_fixnum(v) ? E_NONE : E_FIXNUM_ARRAY_ASET_TYPE;
      default: return E_NONE;
    endcase
  endfunction

  // Byte-array element value for aset (etype checks are done by the caller)
  function automatic logic [31:0] aset_value(word_t v, logic [1:0] et);
    case (et)
      2'd0, 2'd1: return v[31:0];
      2'd2: return {31'd0, wtype(v) != DTP_NIL};
      default: return 32'd0;
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // The state machine
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    retire <= 1'b0;
    retire_counted <= 1'b0;
    hp_sb_taken <= 1'b0;
    lp_sb_taken <= 1'b0;
    map_flush <= 1'b0;
    map_load <= 1'b0;
    map_inval <= 1'b0;
    // a PHT search loaded the map cache (MMU)
    if (map_reload) irw[IRW_COUNT_MAP_RELOADS] <= fixnum(irw[IRW_COUNT_MAP_RELOADS][31:0] + 32'd1);
    scratch_rd <= scratch[scratch_rd_ix];
    // a write to the buffered instruction word forgets it (before the next fetch can use it)
    if (mem_req && mem_we && mem_addr == ib_addr) ib_valid <= 1'b0;

    if (reset) begin
      st <= S_RESET;
      rsp <= '0;
      mem_req <= 1'b0;
      cop_req <= 1'b0;
      ib_valid <= 1'b0;
      halted <= 1'b0;
      halt_code <= '0;
      in_trap <= 1'b0;
      // Ivory::Ivory and Ivory::init: internal registers hold fixnum 0
      for (int i = 0; i < 32; i++) irw[i] <= fixnum(32'd0);
      for (int i = 0; i < 4; i++) bar[i] <= fixnum(32'd0);
      pc <= {INIT_PC_VMA, 1'b0};
      cr <= {TM_FEP, 30'd0};
      sp <= 32'hF8008000; fp <= 32'hF8008000; lp <= 32'hF8008000;
      cont <= '0;
      {alu_control, rotate_latch, ephemeral_oldspace, zone_oldspace, fp_coprocessor_present} <= '0;
      {preempt_register, icache_control, prefetcher_control, map_cache_control, memory_control} <= '0;
      {stack_cache_lower_bound, stack_cache_overflow_limit, entry_max_args, pht_base, pht_mask} <= '0;
      chip_revision <= 32'd4;
      icount <= '0;
      trap_count <= '0;
    end else begin
      case (st)
        S_RESET: begin
          ib_valid <= 1'b0;
          if (dbg_we) begin
            case (dbg_sel)
              4'd0: pc <= dbg_data[32:0];
              4'd1: sp <= dbg_data[31:0];
              4'd2: fp <= dbg_data[31:0];
              4'd3: lp <= dbg_data[31:0];
              4'd4: cont <= dbg_data;
              4'd5: cr <= dbg_data[31:0];
              4'd7: chip_revision <= dbg_data[31:0];
              4'd8: irw[IRW_CONTROL_STACK_LIMIT] <= dbg_data;
              4'd9: irw[IRW_CONTROL_STACK_EXTRA_LIMIT] <= dbg_data;
              default: ;
            endcase
          end
          if (run) st <= S_FETCH;
        end

        S_HALT: halted <= 1'b1;

        // ---------------------------------------------------------------- step()
        S_FETCH: if (!hold) begin
          inst_pc <= pc;
          restart_sp <= sp;
          pc_changed <= 1'b0;
          in_trap <= 1'b0;
          count_insn <= 1'b0;
          rsp <= '0;
          if (reset_req) begin
            pre_trap(TV_RESET, 3'd0);
          end else if (mode <= TM_EXTRA_STACK && hp_sb) begin
            hp_sb_taken <= 1'b1;
            pre_trap(TV_HIGH_PRIORITY_SB, 3'd0);
          end else if (mode == TM_EMULATOR && lp_sb) begin
            lp_sb_taken <= 1'b1;
            pre_trap(TV_LOW_PRIORITY_SB, 3'd0);
          end else if (mode == TM_EMULATOR && preempt_register[0]) begin
            pre_trap(TV_PREEMPT_REQUEST, 3'd0);
          end else if (cr[CR_TRACE_PENDING]) begin
            cr[CR_TRACE_PENDING] <= 1'b0;
            pre_trap(TV_TRACE, 3'd0);
          end else begin
            count_insn <= 1'b1;
            trace_insn <= cr[CR_INSTRUCTION_TRACE];
            if (ib_valid && ib_addr == pc[32:1]) begin
              m_rd <= ib_word;
              st <= S_FETCH_W;
            end else begin
              mem_rd(pc[32:1], 1'b0);
              rstack[0] <= S_FETCH_W;
              rsp <= 3'd1;
              st <= S_MEM_W;
            end
          end
        end

        S_FETCH_W: begin
          iw <= m_rd;
          ib_valid <= 1'b1; ib_addr <= inst_pc[32:1]; ib_word <= m_rd;
          case (wcdr(m_rd))
            2'd0: next_pc <= inst_pc + 33'd1;
            2'd2: next_pc <= inst_pc - 33'd1;
            2'd3: next_pc <= inst_pc + (inst_pc[0] ? 33'd3 : 33'd2);
            default: next_pc <= inst_pc;
          endcase
          st <= S_DECODE;
        end

        S_DECODE: begin
          if (wcdr(iw) == CDR_NIL) begin
            err(E_I_STAGE, inst_pc[32:1]);
          end else if (wtype(iw) >= DTP_PACKED_INSTRUCTION_60) begin
            if (!inst_pc[0] && (iw[17:11] == 7'b0111111)) begin   // entry: opcode 0176/0177
              op <= iw[17:10];
              loopn <= '0;
              e_min <= iw[7:0];
              e_max <= iw[25:18];
              st <= S_ENTRY;
            end else begin
              logic [17:0] h;
              h = inst_pc[0] ? {iw[35:32], iw[31:18]} : iw[17:0];
              op <= h[17:10];
              operand <= h[9:0];
              omode <= h[9:8];
              ooff <= h[7:0];
              st <= S_EXEC;
            end
          end else if (inst_pc[0]) begin
            err(E_I_STAGE, inst_pc[32:1]);
          end else begin
            // execute_fullword
            case (wtype(iw))
              DTP_CALL_COMPILED_EVEN, DTP_CALL_COMPILED_EVEN_PREFETCH: begin
                a1 <= mkw(DTP_COMPILED_FUNCTION, iw[31:0]);
                sc_odd <= 1'b0;
                call(S_SC, S_FW_CALLDONE);
              end
              DTP_CALL_COMPILED_ODD, DTP_CALL_COMPILED_ODD_PREFETCH: begin
                a1 <= mkw(DTP_COMPILED_FUNCTION, iw[31:0]);
                sc_odd <= 1'b1;
                call(S_SC, S_FW_CALLDONE);
              end
              DTP_CALL_INDIRECT, DTP_CALL_INDIRECT_PREFETCH: begin
                sc_odd <= 1'b0;
                mrd(mkw(DTP_LOCATIVE, iw[31:0]), CYC_DATA_READ, S_FW_IND);
              end
              DTP_CALL_GENERIC, DTP_CALL_GENERIC_PREFETCH: begin
                a1 <= mkw(DTP_GENERIC_FUNCTION, iw[31:0]);
                sc_odd <= 1'b0;
                call(S_SC, S_FW_CALLDONE);
              end
              DTP_EXTERNAL_VALUE_CELL_POINTER:
                mrd(mkw(DTP_LOCATIVE, iw[31:0]), CYC_DATA_READ, S_FW_EVCP);
              DTP_NULL, DTP_MONITOR_FORWARD, DTP_HEADER_P, DTP_HEADER_I, DTP_ONE_Q_FORWARD,
              DTP_HEADER_FORWARD, DTP_ELEMENT_FORWARD, DTP_GC_FORWARD, DTP_BOUND_LOCATION,
              DTP_LOGIC_VARIABLE:
                err_d(E_ILLEGAL_FULL_WORD_INSTRUCTION, inst_pc[32:1], {2'b00, wtype(iw)});
              default: push(stripcdr(iw), S_RETIRE);
            endcase
          end
        end

        S_FW_IND: begin
          a1 <= mr_d;
          call(S_SC, S_FW_CALLDONE);
        end
        S_FW_CALLDONE: begin
          if (sc_odd) cont <= mkw(DTP_ODD_PC, iw[31:0]);
          st <= S_RETIRE;
        end
        S_FW_EVCP: push(mr_d, S_RETIRE);

        S_RETIRE: begin
          if (!pc_changed) pc <= next_pc;
          if (trace_insn) cr[CR_TRACE_PENDING] <= 1'b1;
          icount <= icount + 64'd1;
          retire <= 1'b1;
          retire_counted <= 1'b1;
          st <= S_FETCH;
        end

        // A trap ended the step (InstructionAbort)
        S_ABORT: begin
          icount <= icount + {63'd0, count_insn};
          retire <= 1'b1;
          retire_counted <= count_insn;
          st <= S_FETCH;
        end

        S_RETURN: ret();

        // ---------------------------------------------------------------- MEM
        S_MEM: begin
          mem_req <= 1'b1;
          mem_we <= m_we;
          mem_addr <= m_addr;
          mem_wdata <= m_wd;
          mem_phys <= m_phys;
          st <= S_MEM_W;
        end
        S_MEM_W: if (mem_ack) begin
          mem_req <= 1'b0;
          m_trans <= mem_transport;
          if (mem_buserr) begin
            if (in_trap) halt(8'd1);
            else begin
              tr_args[0] <= mkw(DTP_PHYSICAL_ADDRESS, mem_bus_pa);
              pre_trap(TV_MEMORY_BUS_ERROR, 3'd1);
            end
          end else if (mem_fault == 12'hFFF) halt(8'd5);   // PHT search did not terminate
          else if (mem_fault != 12'd0) begin
            if (in_trap) halt(8'd2);
            else begin
              tr_args[0] <= mkw(DTP_LOCATIVE, m_addr);
              pre_trap(mem_fault, 3'd1);
            end
          end else begin
            m_rd <= mem_rdata;
            ret();
          end
        end

        // ---------------------------------------------------------------- mem_read
        S_MRD: begin
          mr_phys <= wtype(mr_a) == DTP_PHYSICAL_ADDRESS;
          mr_final <= mr_a[31:0];
          mr_hops <= '0;
          mem_rd(mr_a[31:0], wtype(mr_a) == DTP_PHYSICAL_ADDRESS);
          call(S_MEM_W, S_MRD_CHK);
        end
        S_MRD_CHK: begin
          logic [2:0] act;
          act = cycle_action(mr_cyc, action_column(wtype(m_rd)));
          if (act == A_TRAP) begin
            err_d(E_MEMORY_DATA_ERROR, mr_final, {4'd0, mr_cyc});
          end else if ((act == A_IND || act == A_MTRAP ||
                        (cycle_transport(mr_cyc) && is_pointer_type(wtype(m_rd)) && wtype(m_rd) != DTP_NULL)) &&
                       m_trans && oldspace_address(m_rd[31:0])) begin
            // the transport trap takes precedence over the monitor trap
            tr_args[0] <= mkw(DTP_LOCATIVE, mr_final);
            pre_trap(TV_TRANSPORT, 3'd1);
          end else if (act == A_MTRAP) begin
            tr_args[0] <= mkw(DTP_LOCATIVE, mr_final);
            pre_trap(TV_MONITOR, 3'd1);
          end else if (act == A_IND) begin
            if (mr_hops > 17'd100000) halt(8'd3);
            mr_hops <= mr_hops + 17'd1;
            mr_final <= m_rd[31:0];
            mr_phys <= 1'b0;
            mem_rd(m_rd[31:0], 1'b0);
            call(S_MEM_W, S_MRD_CHK);
          end else begin
            mr_d <= m_rd;
            ret();
          end
        end

        // ---------------------------------------------------------------- mem_write
        S_MWR: begin
          mw_phys <= wtype(mw_a) == DTP_PHYSICAL_ADDRESS;
          mr_final <= mw_a[31:0];
          mr_hops <= '0;
          mem_rd(mw_a[31:0], wtype(mw_a) == DTP_PHYSICAL_ADDRESS);
          call(S_MEM_W, S_MWR_CHK);
        end
        S_MWR_CHK: begin
          logic [2:0] act;
          act = cycle_action(mw_cyc, action_column(wtype(m_rd)));
          if (act == A_TRAP) begin
            err_d(E_MEMORY_DATA_ERROR, mr_final, {4'd0, mw_cyc});
          end else if ((act == A_IND || act == A_MTRAP) && m_trans && oldspace_address(m_rd[31:0])) begin
            // forwarding and monitor pointers are checked before indirection
            tr_args[0] <= mkw(DTP_LOCATIVE, mr_final);
            pre_trap(TV_TRANSPORT, 3'd1);
          end else if (act == A_MTRAP) begin
            tr_args[0] <= mkw(DTP_LOCATIVE, mr_final);
            pre_trap(TV_MONITOR, 3'd1);
          end else if (act == A_IND) begin
            if (mr_hops > 17'd100000) halt(8'd4);
            mr_hops <= mr_hops + 17'd1;
            mr_final <= m_rd[31:0];
            mw_phys <= 1'b0;
            mem_rd(m_rd[31:0], 1'b0);
            call(S_MEM_W, S_MWR_CHK);
          end else begin
            mem_wr(mr_final, mw_preserve ? {m_rd[39:38], mw_v[37:0]} : mw_v, mw_phys);
            st <= S_MEM_W;   // tail call: S_MEM_W returns to our caller
          end
        end

        // ---------------------------------------------------------------- push / pop
        S_PUSH: begin
          mem_wr(sp + 32'd1, p_w, 1'b0);
          call(S_MEM_W, S_PUSH_DONE);
        end
        S_PUSH_DONE: begin
          sp <= sp + 32'd1;
          ret();
        end
        S_POP: begin
          mem_rd(sp, 1'b0);
          call(S_MEM_W, S_POP_DONE);
        end
        S_POP_DONE: begin
          pop_w <= m_rd;
          sp <= sp - 32'd1;
          ret();
        end

        // ---------------------------------------------------------------- operand_value
        S_OPV: begin
          opv_popped <= 1'b0;
          case (omode)
            2'd0: begin mem_rd(fp + {24'd0, ooff}, 1'b0); st <= S_MEM_W; end
            2'd1: begin mem_rd(lp + {24'd0, ooff}, 1'b0); st <= S_MEM_W; end
            2'd2: begin
              mem_rd(ooff == 8'd0 ? sp : sp + {24'd0, ooff} - 32'd255, 1'b0);
              st <= S_MEM_W;
            end
            default: begin
              opv <= fixnum(opv_sign ? {{24{ooff[7]}}, ooff} : {24'd0, ooff});
              ret();
            end
          endcase
          // S_MEM_W returns to S_OPV_DONE, which then returns to our caller
          if (omode != 2'd3) begin
            rstack[rsp] <= S_OPV_DONE;
            rsp <= rsp + 3'd1;
          end
        end
        S_OPV_DONE: begin
          opv <= m_rd;
          if (omode == 2'd2 && ooff == 8'd0) begin
            sp <= sp - 32'd1;
            opv_popped <= 1'b1;
          end
          ret();
        end

        // ---------------------------------------------------------------- car_of / cdr_of
        S_CC: begin
          cc_bad <= 1'b0;
          case (wtype(cc_x))
            DTP_NIL: begin cc_r <= NIL_W; ret(); end
            DTP_LOCATIVE: begin
              mr_a <= mkw(DTP_LOCATIVE, cc_x[31:0]); mr_cyc <= CYC_DATA_READ;
              st <= S_MRD;
              rstack[rsp] <= S_CC_DONE; rsp <= rsp + 3'd1;
            end
            DTP_LIST: begin
              mr_a <= mkw(DTP_LOCATIVE, cc_x[31:0]);
              mr_cyc <= cc_car ? CYC_DATA_READ : CYC_CDR;
              st <= S_MRD;
              rstack[rsp] <= cc_car ? S_CC_DONE : S_CC_CDR; rsp <= rsp + 3'd1;
            end
            default: begin cc_bad <= 1'b1; ret(); end
          endcase
        end
        S_CC_CDR: begin
          case (wcdr(mr_d))
            CDR_NEXT: begin cc_r <= mkw(DTP_LIST, mr_final + 32'd1); ret(); end
            CDR_NIL: begin cc_r <= NIL_W; ret(); end
            CDR_NORMAL: mrd(mkw(DTP_LOCATIVE, mr_final + 32'd1), CYC_DATA_READ, S_CC_CDR2);
            default: err(E_BAD_CDR_CODE, mr_final);
          endcase
        end
        S_CC_CDR2: begin cc_r <= mr_d; ret(); end
        S_CC_DONE: begin cc_r <= mr_d; ret(); end

        // ---------------------------------------------------------------- unbind_one
        S_UNBIND: begin
          if (!cr[CR_CLEANUP_BINDINGS]) err(E_BINDING_STACK_UNDERFLOW, 32'd0);
          else mrd(mkw(DTP_LOCATIVE, irw[IRW_BSP][31:0]), CYC_BIND_READ, S_UNBIND_1);
        end
        S_UNBIND_1: begin
          ub_old <= mr_d;
          mrd(mkw(DTP_LOCATIVE, irw[IRW_BSP][31:0] - 32'd1), CYC_BIND_READ, S_UNBIND_2);
        end
        S_UNBIND_2: begin
          ub_loc <= mr_d;
          mwr(stripcdr(mr_d), CYC_BIND_WRITE, ub_old, 1'b1, S_UNBIND_3);
        end
        S_UNBIND_3: begin
          cr[CR_CLEANUP_BINDINGS] <= ub_loc[38];
          irw[IRW_BSP] <= setdata(irw[IRW_BSP], irw[IRW_BSP][31:0] - 32'd2);
          ret();
        end

        // ---------------------------------------------------------------- unsigned divide
        S_DIV: begin
          dv_q <= dv_n;
          dv_r <= '0;
          dv_i <= 7'd64;
          st <= S_DIV_LOOP;
        end
        S_DIV_LOOP: begin
          if (dv_i == 7'd0) ret();
          else begin
            logic [32:0] r2;
            r2 = {dv_r[31:0], dv_q[63]};
            if (r2 >= {1'b0, dv_d}) begin
              dv_r <= r2 - {1'b0, dv_d};
              dv_q <= {dv_q[62:0], 1'b1};
            end else begin
              dv_r <= r2;
              dv_q <= {dv_q[62:0], 1'b0};
            end
            dv_i <= dv_i - 7'd1;
          end
        end

        // ---------------------------------------------------------------- traps
        S_ERR: begin
          tr_args[0] <= fixnum(chip_revision == 32'd4
                               ? {21'd0, rev4_microstate(error_microstate(err_cond, err_detail_valid, err_detail))}
                               : error_microstate(err_cond, err_detail_valid, err_detail));
          tr_args[1] <= mkw(DTP_LOCATIVE, err_vma);
          pre_trap(TV_ERROR, 3'd2);
        end

        S_TRAP: begin
          in_trap <= 1'b1;
          if (!tr_post) sp <= restart_sp;
          mrd(mkw(DTP_LOCATIVE, mode == TM_FEP ? irw[IRW_FEP_MODE_TRAP_VECTOR_ADDRESS][31:0]
                                               : TRAP_VECTOR_BASE + {20'd0, tr_vec}),
              CYC_DATA_READ, S_TRAP_V);
        end
        S_TRAP_V: begin
          if (!is_pc_type(wtype(mr_d))) halt(8'd5);
          else begin
            tr_handler <= mr_d;
            tr_oldfp <= fp;
            tr_cr <= (tr_post && cr[CR_INSTRUCTION_TRACE]) ? cr | (32'd1 << CR_TRACE_PENDING) : cr;
            push_raw(setcdr(cont, 2'd3), S_TRAP_2);
          end
        end
        S_TRAP_2: push_raw(mkwc(2'd3, DTP_FIXNUM, tr_cr), S_TRAP_3);
        S_TRAP_3: begin
          fp <= sp - 32'd1;
          push(fixnum({20'd0, tr_vec}), S_TRAP_4);
        end
        S_TRAP_4: begin
          tr_i <= '0;
          push(pc_word(inst_pc), S_TRAP_ARGS);
        end
        S_TRAP_ARGS: begin
          if (tr_i < tr_nargs) begin
            tr_i <= tr_i + 3'd1;
            push(tr_args[tr_i], S_TRAP_ARGS);
          end else st <= S_TRAP_ENTER;
        end
        S_TRAP_ENTER: begin   // enter_trap_frame + check_stack_overflow
          logic [1:0] m;
          logic [31:0] ncr, limit;
          logic [32:0] hpc;
          m = mode;
          if (wcdr(tr_handler) > m) m = wcdr(tr_handler);
          ncr = cr & ~32'h074FFFFF & ~(32'd7 << 27);
          ncr[31:30] = m;
          ncr[19:18] = VD_VALUE;
          ncr[7:0] = (sp + 32'd1 - fp);
          ncr[16:9] = fp - tr_oldfp;
          cr <= ncr;
          lp <= sp + 32'd1;
          cont <= pc_word(tr_post ? tr_retpc : inst_pc);
          hpc = cont_to_pc(tr_handler);
          pc <= hpc;
          pc_changed <= 1'b1;
          trap_count <= trap_count + 64'd1;
          last_trap_vector <= tr_vec;
          limit = m == TM_EMULATOR ? irw[IRW_CONTROL_STACK_LIMIT][31:0]
                                   : irw[IRW_CONTROL_STACK_EXTRA_LIMIT][31:0];
          if (sp >= limit && limit != 32'd0) begin
            if (m == TM_EMULATOR) begin
              restart_sp <= sp;
              inst_pc <= hpc;
              tr_vec <= TV_STACK_OVERFLOW; tr_nargs <= 3'd0; tr_post <= 1'b0;
              st <= S_TRAP;
            end else halt(8'd6);
          end else begin
            in_trap <= 1'b0;
            st <= S_ABORT;
          end
        end

        // ---------------------------------------------------------------- dispatch
        S_EXEC: begin
`include "ivory_cpu_exec.svh"
        end

`include "ivory_cpu_insns.svh"

        default: halt(8'd255);
      endcase
    end
  end
