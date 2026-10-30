// Ivory processor: instruction states after the first step (exec_op and the
// routines it calls).  Included in the case statement of ivory_cpu_states.svh.

        // ---------------------------------------------------------------- car, cdr
        S_CAR_1: begin a1 <= opv; carcdr(opv, op == 8'o000, S_CAR_2); end
        S_CAR_2: begin
          if (cc_bad) begin
            if (wtype(a1) == DTP_LIST_INSTANCE) exc(3'd1, a1, '0, '0);
            else err(E_CAR_CDR_LIST_TYPE, 32'd0);
          end else push(cc_r, S_RETIRE);
        end

        // set-to-car, set-to-cdr
        S_STC_1: begin a1 <= m_rd; carcdr(m_rd, op == 8'o140, S_STC_2); end
        S_STC_2: begin
          if (cc_bad) begin
            if (wtype(a1) == DTP_LIST_INSTANCE) exc(3'd1, mkw(DTP_LOCATIVE, addr), '0, '0);
            else err(E_SET_TO_CAR_CDR_LIST_TYPE, 32'd0);
          end else swrite(addr, {a1[39:38], cc_r[37:0]}, S_RETIRE);
        end

        // set-to-cdr-push-car
        S_STCPC_1: begin a1 <= m_rd; carcdr(m_rd, 1'b1, S_STCPC_2); end
        S_STCPC_2: begin
          if (cc_bad) begin
            if (wtype(a1) == DTP_LIST_INSTANCE) exc(3'd1, mkw(DTP_LOCATIVE, addr), '0, '0);
            else err(E_SET_TO_CAR_CDR_LIST_TYPE, 32'd0);
          end else begin
            t0 <= cc_r;
            carcdr(a1, 1'b0, S_STCPC_3);
          end
        end
        S_STCPC_3: swrite(addr, {a1[39:38], cc_r[37:0]}, S_STCPC_4);
        S_STCPC_4: push(t0, S_RETIRE);

        // rplaca, rplacd
        S_RPL_1: begin a2 <= opv; pop(S_RPL_2); end
        S_RPL_2: begin
          a1 <= pop_w;
          if (wtype(pop_w) == DTP_LIST_INSTANCE) exc(3'd2, pop_w, a2, '0);
          else if (wtype(pop_w) != DTP_LIST && wtype(pop_w) != DTP_LOCATIVE)
            err(E_RPLACA_RPLACD_LIST_TYPE, 32'd0);
          else if (op == 8'o200 || wtype(pop_w) == DTP_LOCATIVE)
            mwr(mkw(DTP_LOCATIVE, pop_w[31:0]), CYC_DATA_WRITE, a2, 1'b1, S_RETIRE);
          else mrd(mkw(DTP_LOCATIVE, pop_w[31:0]), CYC_CDR, S_RPL_3);
        end
        S_RPL_3: begin
          if (wcdr(mr_d) != CDR_NORMAL) exc(3'd2, a1, a2, '0);
          else mwr(mkw(DTP_LOCATIVE, mr_final + 32'd1), CYC_DATA_WRITE, a2, 1'b1, S_RETIRE);
        end

        // rgetf, member, assoc
        S_MEM_1: begin a2 <= opv; t0 <= opv; sread(sp, S_MEM_2); end
        S_MEM_2: begin
          a1 <= m_rd;
          if (is_boxed_number(wtype(m_rd))) begin
            sp <= sp - 32'd1;
            exc(3'd2, m_rd, a2, '0);
          end else begin
            loopn <= '0;
            st <= S_MEM_LOOP;
          end
        end
        S_MEM_LOOP: begin   // list in t0
          if (loopn != 16'hFFFF) loopn <= loopn + 16'd1;
          if (loopn > 16'd1000 && (hp_sb || lp_sb)) begin   // interruptible: retry later
            sp <= restart_sp;
            set_pc(inst_pc);
            st <= S_RETIRE;
          end else if (wtype(t0) == DTP_NIL) begin
            sp <= sp - 32'd1;
            push(NIL_W, op == 8'o225 ? S_PUSH_NIL : S_RETIRE);
          end else if (wtype(t0) != DTP_LIST) begin
            sp <= sp - 32'd1;
            if (wtype(t0) == DTP_LIST_INSTANCE) exc(3'd2, a1, a2, '0);
            else err(E_LIST_TAIL_NOT_LIST, 32'd0);
          end else carcdr(t0, 1'b1, S_MEM_CAR);
        end
        S_MEM_CAR: begin   // element in cc_r
          t1 <= cc_r;
          case (op)
            8'o227: begin   // assoc
              if (wtype(cc_r) == DTP_LIST) carcdr(cc_r, 1'b1, S_MEM_ASSOC_K);
              else if (wtype(cc_r) != DTP_NIL) begin
                sp <= sp - 32'd1;
                if (wtype(cc_r) == DTP_LIST_INSTANCE) exc(3'd2, a1, a2, '0);
                else err(E_ASSOC_ELEMENT_NOT_LIST, t0[31:0]);
              end else carcdr(t0, 1'b0, S_MEM_CDR);
            end
            8'o226: begin   // member
              if (stripcdr(cc_r) == stripcdr(a1)) begin
                sp <= sp - 32'd1;
                push(t0, S_RETIRE);
              end else carcdr(t0, 1'b0, S_MEM_CDR);
            end
            default: carcdr(t0, 1'b0, S_MEM_RGETF_REST);   // rgetf
          endcase
        end
        S_MEM_ASSOC_K: begin
          if (stripcdr(cc_r) == stripcdr(a1)) begin
            sp <= sp - 32'd1;
            push(t1, S_RETIRE);
          end else carcdr(t0, 1'b0, S_MEM_CDR);
        end
        S_MEM_CDR: begin t0 <= cc_r; st <= S_MEM_LOOP; end
        S_MEM_RGETF_REST: begin   // element in t1, rest in cc_r
          t2 <= cc_r;
          if (stripcdr(t1) == stripcdr(a1)) begin
            if (wtype(cc_r) == DTP_NIL) begin
              sp <= sp - 32'd1;
              exc(3'd2, a1, a2, '0);
            end else if (wtype(cc_r) != DTP_LIST) begin
              sp <= sp - 32'd1;
              if (wtype(cc_r) == DTP_LIST_INSTANCE) exc(3'd2, a1, a2, '0);
              else err(E_LIST_TAIL_NOT_LIST, 32'd0);
            end else begin
              sp <= sp - 32'd1;
              carcdr(cc_r, 1'b1, S_MEM_RGETF_CAR);
            end
          end else if (wtype(cc_r) == DTP_NIL) begin
            t0 <= cc_r;
            st <= S_MEM_LOOP;
          end else if (wtype(cc_r) != DTP_LIST) begin
            sp <= sp - 32'd1;
            if (wtype(cc_r) == DTP_LIST_INSTANCE) exc(3'd2, a1, a2, '0);
            else err(E_LIST_TAIL_NOT_LIST, 32'd0);
          end else carcdr(cc_r, 1'b0, S_MEM_CDR);
        end
        S_MEM_RGETF_CAR: push(cc_r, S_MEM_RGETF_PUSH);
        S_MEM_RGETF_PUSH: push(t2, S_RETIRE);
        S_PUSH_NIL: push(NIL_W, S_RETIRE);
        S_PUSH_T: push(T_W, S_RETIRE);

        // ---------------------------------------------------------------- predicates
        S_EQ_1: begin a2 <= opv; sread(sp, S_EQ_2); end
        S_EQ_2: begin
          logic same;
          same = stripcdr(m_rd) == stripcdr(a2);
          if ((op == 8'o263 || op == 8'o267) && !same && wtype(m_rd) == wtype(a2) &&
              is_boxed_number(wtype(m_rd))) begin
            sp <= sp - 32'd1;
            arith_exc(3'd2, m_rd, a2);
          end else begin
            if (op == 8'o270 || op == 8'o263) sp <= sp - 32'd1;
            push(boolw(same), S_RETIRE);
          end
        end

        S_NUMCMP_1: begin a2 <= opv; sread(sp, S_NUMCMP_2); end
        S_NUMCMP_2: begin
          logic res;
          if (!is_numeric_type(wtype(m_rd)) || !is_numeric_type(wtype(a2))) err(E_BINARY_ARITH_TYPE, 32'd0);
          else if (!fix2(m_rd, a2)) begin
            sp <= sp - 32'd1;
            arith_exc(3'd2, m_rd, a2);
          end else begin
            case (op)
              8'o260, 8'o264: res = m_rd[31:0] == a2[31:0];
              8'o261, 8'o265: res = $signed(m_rd[31:0]) < $signed(a2[31:0]);
              8'o262, 8'o266: res = $signed(m_rd[31:0]) > $signed(a2[31:0]);
              default: res = (m_rd[31:0] & a2[31:0]) != 32'd0;   // logtest
            endcase
            if (op == 8'o260 || op == 8'o261 || op == 8'o262 || op == 8'o273) sp <= sp - 32'd1;
            push(boolw(res), S_RETIRE);
          end
        end

        S_TYPEMEM_1: begin
          logic [63:0] mask;
          mask = {56'd0, operand[7:0]} << {op[1:0], operand[9:8], 2'b00};
          if (op < 8'o044) sp <= sp - 32'd1;
          push(boolw(mask[wtype(m_rd)]), S_RETIRE);
        end

        S_ENDP_1: begin
          case (wtype(opv))
            DTP_NIL: push(T_W, S_RETIRE);
            DTP_LIST, DTP_LIST_INSTANCE: push(NIL_W, S_RETIRE);
            default: err(E_ONE_OPERAND_LIST_TYPE, 32'd0);
          endcase
        end

        S_ZEROP_1: begin
          if (!is_numeric_type(wtype(opv))) err(E_UNARY_ARITH_TYPE, 32'd0);
          else if (!is_fixnum(opv)) arith_exc(3'd1, opv, '0);
          else push(boolw(op == 8'o034 ? opv[31:0] == 32'd0 :
                          op == 8'o035 ? opv[31] : !opv[31] && opv[31:0] != 32'd0), S_RETIRE);
        end

        // ---------------------------------------------------------------- arith_binary
        S_ARITH_1: begin a2 <= opv; pop(S_ARITH_2); end
        S_ARITH_2: begin
          logic signed [63:0] x, y, r;
          logic ovf;
          a1 <= pop_w;
          x = {{32{pop_w[31]}}, pop_w[31:0]};
          y = {{32{a2[31]}}, a2[31:0]};
          r = '0;
          ovf = 1'b0;
          if (!is_numeric_type(wtype(pop_w)) || !is_numeric_type(wtype(a2))) err(E_BINARY_ARITH_TYPE, 32'd0);
          else if (!fix2(pop_w, a2)) arith_exc(3'd2, pop_w, a2);
          else begin
            case (op)
              8'o203, 8'o204, 8'o205, 8'o206, 8'o207, 8'o210, 8'o211: begin
                if (y == 64'sd0) err(E_DIVIDE_BY_ZERO, 32'd0);
                else if (pop_w[31:0] == 32'h80000000 && a2[31:0] == 32'hFFFFFFFF)
                  arith_exc(3'd2, pop_w, a2);
                else begin
                  dv_n <= {32'd0, x < 0 ? -pop_w[31:0] : pop_w[31:0]};
                  dv_d <= y < 0 ? -a2[31:0] : a2[31:0];
                  call(S_DIV, S_ARITH_DIV);
                end
              end
              8'o232: begin   // ash
                if (y >= 0) begin
                  if (y >= 32) begin
                    if (x == 0) push(fixnum(32'd0), S_RETIRE);
                    else arith_exc(3'd2, pop_w, a2);
                  end else begin
                    r = x <<< y[4:0];
                    if (r != {{32{r[31]}}, r[31:0]}) arith_exc(3'd2, pop_w, a2);
                    else push(fixnum(r[31:0]), S_RETIRE);
                  end
                end else begin
                  if (y <= -32) r = x < 0 ? -64'sd1 : 64'sd0;
                  else r = x >>> (-y);
                  push(fixnum(r[31:0]), S_RETIRE);
                end
              end
              default: begin
                case (op)
                  8'o300: r = x + y;
                  8'o301: r = x - y;
                  8'o202: r = x * y;
                  8'o212: r = x < y ? x : y;
                  8'o213: r = x > y ? x : y;
                  8'o215: r = x & y;
                  8'o216: r = x ^ y;
                  default: r = x | y;   // 0217
                endcase
                ovf = r != {{32{r[31]}}, r[31:0]};
                if (ovf) arith_exc(3'd2, pop_w, a2);
                else push(fixnum(r[31:0]), S_RETIRE);
              end
            endcase
          end
        end
        S_ARITH_DIV: begin
          logic signed [33:0] q, rem, y, twice, ay;
          logic up;
          y = {{2{a2[31]}}, a2[31:0]};
          q = (a1[31] != a2[31]) ? -{2'b00, dv_q[31:0]} : {2'b00, dv_q[31:0]};
          rem = a1[31] ? -{2'b00, dv_r[31:0]} : {2'b00, dv_r[31:0]};
          if (op == 8'o203) push(fixnum(q[31:0]), S_RETIRE);
          else if (op == 8'o210) push(fixnum(rem[31:0]), S_RETIRE);
          else if (op == 8'o211) begin
            if (rem != 0) arith_exc(3'd2, a1, a2);
            else push(fixnum(q[31:0]), S_RETIRE);
          end else begin
            if (rem != 0) begin
              case (op)
                8'o204: if ((rem > 0) == (y > 0)) begin q = q + 1; rem = rem - y; end
                8'o205: if ((rem > 0) != (y > 0)) begin q = q - 1; rem = rem + y; end
                8'o207: begin
                  twice = rem < 0 ? -(rem * 2) : rem * 2;
                  ay = y < 0 ? -y : y;
                  up = twice > ay || (twice == ay && q[0]);
                  if (up) begin
                    if ((rem > 0) == (y > 0)) begin q = q + 1; rem = rem - y; end
                    else begin q = q - 1; rem = rem + y; end
                  end
                end
                default: ;
              endcase
            end
            t0 <= fixnum(rem[31:0]);
            push(fixnum(q[31:0]), S_PUSH2);
          end
        end
        S_PUSH2: push(t0, S_RETIRE);

        S_UMINUS_1: begin
          if (!is_numeric_type(wtype(opv))) err(E_UNARY_ARITH_TYPE, 32'd0);
          else if (!is_fixnum(opv) || opv[31:0] == 32'h80000000) arith_exc(3'd1, opv, '0);
          else push(fixnum(-opv[31:0]), S_RETIRE);
        end

        S_INC_1: begin   // increment, decrement
          logic [31:0] v;
          v = op == 8'o143 ? m_rd[31:0] + 32'd1 : m_rd[31:0] - 32'd1;
          if (!is_numeric_type(wtype(m_rd))) err(E_UNARY_ARITH_TYPE, 32'd0);
          else if (is_fixnum(m_rd) && !(op == 8'o143 ? m_rd[31:0] == 32'h7FFFFFFF
                                                     : m_rd[31:0] == 32'h80000000))
            swrite(addr, {m_rd[39:38], DTP_FIXNUM, v}, S_RETIRE);
          else exc(3'd1, mkw(DTP_LOCATIVE, addr), '0, '0);
        end

        // rot, lsh
        S_SHIFT_1: begin a2 <= opv; pop(S_SHIFT_2); end
        S_SHIFT_2: begin
          logic [31:0] res;
          logic signed [31:0] n;
          n = a2[31:0];
          if (op == 8'o220) res = rotl(pop_w[31:0], n[4:0]);
          else if (n >= 32 || n <= -32) res = 32'd0;
          else if (n >= 0) res = pop_w[31:0] << n[4:0];
          else res = pop_w[31:0] >> (-n);
          if (!fix2(pop_w, a2)) err(E_TWO_OPERAND_FIXNUM_TYPE, 32'd0);
          else push(fixnum(res), S_RETIRE);
        end

        // %32-bit-plus, %32-bit-difference
        S_32BIT_1: begin a2 <= opv; pop(S_32BIT_2); end
        S_32BIT_2: begin
          if (!fix2(pop_w, a2)) err(E_TWO_OPERAND_FIXNUM_TYPE, 32'd0);
          else push(fixnum(op == 8'o302 ? pop_w[31:0] + a2[31:0] : pop_w[31:0] - a2[31:0]), S_RETIRE);
        end

        // %multiply-double (signed), %multiply-bignum-step (unsigned)
        S_MULD_1: begin a2 <= opv; pop(S_MULD_2); end
        S_MULD_2: begin
          logic [63:0] p;
          if (op == 8'o222) p = $signed({{32{pop_w[31]}}, pop_w[31:0]}) * $signed({{32{a2[31]}}, a2[31:0]});
          else p = {32'd0, pop_w[31:0]} * {32'd0, a2[31:0]};
          if (!fix2(pop_w, a2)) err(E_TWO_OPERAND_FIXNUM_TYPE, 32'd0);
          else begin
            q64 <= p;
            push(fixnum(p[31:0]), S_MULD_3);
          end
        end
        S_MULD_3: push(fixnum(q64[63:32]), S_RETIRE);

        // %add-bignum-step, %sub-bignum-step, %divide-bignum-step, %lshc-bignum-step
        S_BIG3_1: begin a3 <= opv; pop(S_BIG3_2); end
        S_BIG3_2: begin a2 <= pop_w; pop(S_BIG3_3); end
        S_BIG3_3: begin
          logic [63:0] s, v;
          logic [31:0] d, d2;
          logic [1:0] borrow;
          a1 <= pop_w;
          if (op == 8'o307) begin
            if (!fix2(pop_w, a2) || !is_fixnum(a3) || a3[31:0] == 32'd0) err(E_DIVIDE_BIGNUM_STEP, 32'd0);
            else begin
              dv_n <= {a2[31:0], pop_w[31:0]};
              dv_d <= a3[31:0];
              call(S_DIV, S_BIGDIV_1);
            end
          end else if (!fix2(pop_w, a2) || !is_fixnum(a3)) err(E_THREE_OPERAND_FIXNUM_TYPE, 32'd0);
          else begin
            case (op)
              8'o304: begin
                s = {32'd0, pop_w[31:0]} + {32'd0, a2[31:0]} + {32'd0, a3[31:0]};
                t0 <= fixnum(s[63:32]);
                push(fixnum(s[31:0]), S_PUSH2);
              end
              8'o305: begin
                d = pop_w[31:0] - a2[31:0];
                borrow = {1'b0, pop_w[31:0] < a2[31:0]};
                d2 = d - a3[31:0];
                borrow = borrow + {1'b0, d < a3[31:0]};
                t0 <= fixnum({30'd0, borrow});
                push(fixnum(d2), S_PUSH2);
              end
              default: begin   // 0223 %lshc-bignum-step
                v = {a2[31:0], pop_w[31:0]} << a3[5:0];
                push(fixnum(v[63:32]), S_RETIRE);
              end
            endcase
          end
        end
        S_BIGDIV_1: begin
          t0 <= fixnum(dv_r[31:0]);
          push(fixnum(dv_q[31:0]), S_PUSH2);
        end

        // %double-float-op: always an instruction exception (no FPA)
        S_DFLOAT_1: begin
          tr_args[4] <= opv;
          cnt <= 32'd3;
          pop(S_DFLOAT_2);
        end
        S_DFLOAT_2: begin
          tr_args[cnt[2:0]] <= pop_w;
          if (cnt == 32'd0) post_trap(TV_INSTRUCTION_EXCEPTION + {4'd0, op}, 3'd5, next_pc);
          else begin
            cnt <= cnt - 32'd1;
            pop(S_DFLOAT_2);
          end
        end

        // ---------------------------------------------------------------- data movement
        S_PUSHI_1: push(opv, S_RETIRE);
        S_POPI_1: swrite(addr, pop_w, S_RETIRE);
        S_MOVEM_1: swrite(addr, m_rd, S_RETIRE);
        S_PUSHNIL_1: begin
          if (!is_fixnum(opv)) err(E_ONE_OPERAND_FIXNUM_TYPE, 32'd0);
          else begin cnt <= opv[31:0]; st <= S_PUSHNIL_2; end
        end
        S_PUSHNIL_2: begin
          if (cnt == 32'd0) st <= S_RETIRE;
          else begin
            cnt <= cnt - 32'd1;
            push(NIL_W, S_PUSHNIL_2);
          end
        end
        S_SSTS_1: begin
          sp <= addr;
          swrite(addr, m_rd, S_RETIRE);
        end
        S_PASR_1: begin
          if (!is_fixnum(opv)) err(E_ONE_OPERAND_FIXNUM_TYPE, 32'd0);
          else push(mkw(DTP_LOCATIVE, x0 - opv[31:0] - 32'd1), S_RETIRE);
        end
        // stack-blt: from in x0, to in x1, top in cnt
        S_BLT_1: begin x0 <= opv[31:0]; pop(S_BLT_2); end
        S_BLT_2: begin
          x1 <= pop_w[31:0];
          cnt <= sp;
          st <= S_BLT_3;
        end
        S_BLT_3: begin
          if (x0 <= cnt) sread(x0, S_BLT_4);
          else begin
            sp <= x1 - 32'd1;
            st <= S_RETIRE;
          end
        end
        S_BLT_4: begin
          x0 <= x0 + 32'd1;
          x1 <= x1 + 32'd1;
          swrite(x1, m_rd, S_BLT_3);
        end

        // ---------------------------------------------------------------- field extraction
        S_LDB_1: begin
          logic [31:0] v;
          v = rotl(pop_w[31:0], operand[4:0]) & low_mask({1'b0, operand[9:5]} + 6'd1);
          if (op == 8'o170) begin
            if (!is_numeric_type(wtype(pop_w))) err(E_UNARY_ARITH_TYPE, 32'd0);
            else if (!is_fixnum(pop_w)) exc(3'd1, pop_w, '0, '0);
            else push(fixnum(v), S_RETIRE);
          end else begin
            if (wtype(pop_w) != DTP_CHARACTER) err(E_CHAR_LDB_TYPE, 32'd0);
            else push(fixnum(v), S_RETIRE);
          end
        end
        S_DPB_1: begin a2 <= pop_w; pop(S_DPB_2); end
        S_DPB_2: begin
          logic [31:0] mask, v;
          word_t bad;
          mask = low_mask({1'b0, operand[9:5]} + 6'd1) << operand[4:0];
          v = (a2[31:0] & ~mask) | ((pop_w[31:0] << operand[4:0]) & mask);
          bad = !is_fixnum(a2) ? a2 : pop_w;
          if (op == 8'o370) begin
            if (!fix2(pop_w, a2)) begin
              if (!is_numeric_type(wtype(bad))) err(E_BINARY_ARITH_TYPE, 32'd0);
              else exc(3'd2, pop_w, a2, '0);
            end else push(fixnum(v), S_RETIRE);
          end else begin
            if (!is_fixnum(pop_w) || wtype(a2) != DTP_CHARACTER) err(E_CHAR_DPB_TYPE, 32'd0);
            else push(mkw(DTP_CHARACTER, v), S_RETIRE);
          end
        end
        S_PLDB_1: begin a1 <= pop_w; mrd(pop_w, CYC_RAW, S_PLDB_2); end
        S_PLDB_2: begin
          logic [31:0] x;
          x = op == 8'o172 ? mr_d[31:0] : {24'd0, mr_d[39:32]};
          push(fixnum(rotl(x, operand[4:0]) & low_mask({1'b0, operand[9:5]} + 6'd1)), S_RETIRE);
        end
        S_PDPB_1: begin a2 <= pop_w; pop(S_PDPB_2); end
        S_PDPB_2: begin
          a1 <= pop_w;
          if (!is_fixnum(pop_w)) err(E_P_DPB_TYPE, 32'd0);
          else mrd(a2, CYC_RAW, S_PDPB_3);
        end
        S_PDPB_3: begin
          logic [31:0] mask, v;
          mask = low_mask({1'b0, operand[9:5]} + 6'd1) << operand[4:0];
          if (op == 8'o372) begin
            v = (mr_d[31:0] & ~mask) | ((a1[31:0] << operand[4:0]) & mask);
            write_addr(a2, setdata(mr_d, v), S_RETIRE);
          end else begin
            v = ({24'd0, mr_d[39:32]} & ~mask) | ((a1[31:0] << operand[4:0]) & mask);
            write_addr(a2, {v[7:0], mr_d[31:0]}, S_RETIRE);
          end
        end

        // ---------------------------------------------------------------- aref-1, aloc-1, aset-1
        S_AREF_1: begin a2 <= opv; pop(S_AREF_2); end
        S_AREF_2: begin
          a1 <= pop_w;
          if (op == 8'o310) pop(S_AREF_3);
          else st <= S_AREF_4;
        end
        S_AREF_3: begin val <= pop_w; st <= S_AREF_4; end
        S_AREF_4: begin
          logic [6:0] errc;
          errc = op == 8'o310 ? E_ARRAY_ACCESS_TYPE_3 : E_ARRAY_ACCESS_TYPE_BINARY;
          if (!is_fixnum(a2)) err(errc, 32'd0);
          else if (wtype(a1) == DTP_ARRAY_INSTANCE || wtype(a1) == DTP_STRING_INSTANCE) begin
            if (op == 8'o310) exc(3'd3, val, a1, a2);
            else exc(3'd2, a1, a2, '0);
          end else if (wtype(a1) != DTP_ARRAY && wtype(a1) != DTP_STRING) err(errc, 32'd0);
          else mrd(mkw(DTP_LOCATIVE, a1[31:0]), CYC_HEADER, S_AREF_5);
        end
        S_AREF_5: begin
          logic [2:0] hbp;
          logic [1:0] het;
          logic [31:0] hbase, hidx;
          logic [6:0] ec;
          hbp = mr_d[29:27];
          het = mr_d[31:30];
          hbase = mr_final + 32'd1;
          hidx = a2[31:0];
          bp <= hbp; etype <= het; base <= hbase; idx <= hidx;
          ec = aset_check(val, het, hbp);
          if (mr_d[23]) begin
            if (op == 8'o310) exc(3'd3, val, a1, a2);
            else exc(3'd2, a1, a2, '0);
          end else if (hidx >= {17'd0, mr_d[14:0]}) err(E_SUBSCRIPT_BOUNDS, 32'd0);
          else begin
            case (op)
              8'o313: begin
                if (het != 2'd3) err(E_ALOC_NON_OBJECT_ARRAY, 32'd0);
                else push(mkw(DTP_LOCATIVE, hbase + hidx), S_RETIRE);
              end
              8'o312: begin
                if (hbp == 3'd0 && het == 2'd3)
                  mrd(mkw(DTP_LOCATIVE, hbase + hidx), CYC_DATA_READ, S_PUSH_MRD);
                else mrd(mkw(DTP_LOCATIVE, hbase + (hidx >> hbp)), CYC_DATA_READ, S_AREF_6);
              end
              default: begin   // aset-1
                if (ec != E_NONE) err(ec, 32'd0);
                else if (hbp == 3'd0 && het == 2'd3)
                  mwr(mkw(DTP_LOCATIVE, hbase + hidx), CYC_DATA_WRITE, val, 1'b1, S_RETIRE);
                else mrd(mkw(DTP_LOCATIVE, hbase + (hidx >> hbp)), CYC_DATA_READ, S_AREF_7);
              end
            endcase
          end
        end
        S_PUSH_MRD: push(mr_d, S_RETIRE);
        S_AREF_6: begin
          if (bp != 3'd0 && !is_fixnum(mr_d)) err(E_BYTE_ARRAY_WORD_TYPE, mr_final);
          else push(array_element(mr_d, bp, etype, idx), S_RETIRE);
        end
        S_AREF_7: begin
          if (!is_fixnum(mr_d)) err(E_BYTE_ARRAY_WORD_TYPE, mr_final);
          else swrite(mr_final, setdata(mr_d, array_insert(mr_d[31:0], aset_value(val, etype), bp, idx)),
                      S_RETIRE);
        end

        // setup-1d-array, setup-force-1d-array
        S_SETUP_1: begin
          a1 <= opv;
          if (wtype(opv) == DTP_ARRAY_INSTANCE || wtype(opv) == DTP_STRING_INSTANCE) exc(3'd1, opv, '0, '0);
          else if (wtype(opv) != DTP_ARRAY && wtype(opv) != DTP_STRING) err(E_SETUP_ARRAY_NOT_ARRAY, 32'd0);
          else mrd(mkw(DTP_LOCATIVE, opv[31:0]), CYC_HEADER, S_SETUP_2);
        end
        S_SETUP_2: begin
          if (wtype(mr_d) != DTP_HEADER_I) err(E_SETUP_ARRAY_NOT_ARRAY, 32'd0);
          else if (mr_d[23]) exc(3'd1, a1, '0, '0);
          else begin
            t0 <= mr_d;
            base <= mr_final + 32'd1;
            push(a1, S_SETUP_3);
          end
        end
        S_SETUP_3: push(fixnum((t0[31:0] & 32'hF8000000) | (irw[IRW_EVENT_COUNT][31:0] & 32'h3FFFFF)),
                        S_SETUP_4);
        S_SETUP_4: push(mkw(DTP_LOCATIVE, base), S_SETUP_5);
        S_SETUP_5: push(fixnum({17'd0, t0[14:0]}), S_RETIRE);

        // fast-aref-1, fast-aset-1: array register at addr (control, base, length)
        S_FAST_1: begin
          a2 <= pop_w;
          if (op == 8'o351) pop(S_FAST_2);
          else sread(addr, S_FAST_4);
        end
        S_FAST_2: begin val <= pop_w; sread(addr, S_FAST_4); end
        S_FAST_4: begin t0 <= m_rd; sread(addr + 32'd1, S_FAST_5); end
        S_FAST_5: begin t1 <= m_rd; sread(addr + 32'd2, S_FAST_6); end
        S_FAST_6: begin
          t2 <= m_rd;
          if (!is_fixnum(a2)) err(E_FAST_ARRAY_ACCESS_TYPE, 32'd0);
          else if (a2[31:0] >= m_rd[31:0]) err(E_ARRAY_REGISTER_FORMAT_OR_BOUNDS, 32'd0);
          else if (t0[21:0] != irw[IRW_EVENT_COUNT][21:0]) sread(addr - 32'd1, S_FAST_7);   // stale
          else st <= S_FAST_ACCESS;
        end
        S_FAST_7: begin
          if (wtype(m_rd) != DTP_ARRAY && wtype(m_rd) != DTP_STRING) begin
            if (wtype(m_rd) == DTP_ARRAY_INSTANCE || wtype(m_rd) == DTP_STRING_INSTANCE ||
                wtype(m_rd) == DTP_SPARE_POINTER_1 || wtype(m_rd) == DTP_SPARE_POINTER_2) begin
              if (op == 8'o350) exc(3'd2, a2, mkw(DTP_LOCATIVE, addr), '0);
              else exc(3'd3, val, a2, mkw(DTP_LOCATIVE, addr));
            end else err(E_ARRAY_REGISTER_FORMAT_OR_BOUNDS, 32'd0);
          end else mrd(mkw(DTP_LOCATIVE, m_rd[31:0]), CYC_HEADER, S_FAST_8);
        end
        S_FAST_8: begin
          if (wtype(mr_d) != DTP_HEADER_I) err(E_ARRAY_REGISTER_FORMAT_OR_BOUNDS, 32'd0);
          else if (mr_d[23]) begin
            if (op == 8'o350) exc(3'd2, a2, mkw(DTP_LOCATIVE, addr), '0);
            else exc(3'd3, val, a2, mkw(DTP_LOCATIVE, addr));
          end else begin
            word_t nctl;
            nctl = setdata(t0, (mr_d[31:0] & 32'hF8000000) | (irw[IRW_EVENT_COUNT][31:0] & 32'h3FFFFF));
            t0 <= nctl;
            t1 <= setdata(t1, mr_final + 32'd1);
            t2 <= setdata(t2, {17'd0, mr_d[14:0]});
            swrite(addr, nctl, S_FAST_9);
          end
        end
        S_FAST_9: swrite(addr + 32'd1, t1, S_FAST_10);
        S_FAST_10: swrite(addr + 32'd2, t2, S_FAST_11);
        S_FAST_11: begin
          if (a2[31:0] >= t2[31:0]) err(E_ARRAY_REGISTER_FORMAT_OR_BOUNDS, 32'd0);
          else st <= S_FAST_ACCESS;
        end
        S_FAST_ACCESS: begin
          logic [2:0] fbp;
          logic [1:0] fet;
          logic [31:0] i2, wa0;
          logic [6:0] ec;
          fbp = t0[29:27];
          fet = t0[31:30];
          i2 = a2[31:0] + {27'd0, t0[26:22]};
          wa0 = t1[31:0] + (i2 >> fbp);
          bp <= fbp; etype <= fet; idx <= i2;
          ec = aset_check(val, fet, fbp);
          if (op == 8'o350) begin
            if (fbp == 3'd0 && fet == 2'd3) mrd(mkw(DTP_LOCATIVE, wa0), CYC_DATA_READ, S_PUSH_MRD);
            else mrd(mkw(DTP_LOCATIVE, wa0), CYC_DATA_READ, S_AREF_6);
          end else begin
            if (ec != E_NONE) err(ec, 32'd0);
            else if (fbp == 3'd0 && fet == 2'd3) mwr(mkw(DTP_LOCATIVE, wa0), CYC_DATA_WRITE, val, 1'b1, S_RETIRE);
            else mrd(mkw(DTP_LOCATIVE, wa0), CYC_DATA_READ, S_AREF_7);
          end
        end

        // array-leader, aloc-leader, store-array-leader
        S_LEADER_1: begin a2 <= opv; pop(S_LEADER_2); end
        S_LEADER_2: begin
          a1 <= pop_w;
          if (op == 8'o314) pop(S_LEADER_3);
          else st <= S_LEADER_4;
        end
        S_LEADER_3: begin val <= pop_w; st <= S_LEADER_4; end
        S_LEADER_4: begin
          logic [6:0] errc;
          errc = op == 8'o314 ? E_ARRAY_LEADER_TYPE_3 : E_ARRAY_LEADER_TYPE_BINARY;
          if (!is_fixnum(a2)) err(errc, 32'd0);
          else if (wtype(a1) == DTP_ARRAY_INSTANCE || wtype(a1) == DTP_STRING_INSTANCE) begin
            if (op == 8'o314) exc(3'd3, val, a1, a2);
            else exc(3'd2, a1, a2, '0);
          end else if (wtype(a1) != DTP_ARRAY && wtype(a1) != DTP_STRING) err(errc, 32'd0);
          else mrd(mkw(DTP_LOCATIVE, a1[31:0]), CYC_HEADER, S_LEADER_5);
        end
        S_LEADER_5: begin
          logic [31:0] ea;
          ea = mr_final - 32'd1 - a2[31:0];
          if (a2[31:0] >= {24'd0, mr_d[22:15]}) err(E_SUBSCRIPT_BOUNDS, 32'd0);
          else if (op == 8'o316) mrd(mkw(DTP_LOCATIVE, ea), CYC_DATA_READ, S_PUSH_MRD);
          else if (op == 8'o317) push(mkw(DTP_LOCATIVE, ea), S_RETIRE);
          else mwr(mkw(DTP_LOCATIVE, ea), CYC_DATA_WRITE, val, 1'b1, S_RETIRE);
        end

        // ---------------------------------------------------------------- branches
        S_BRC_1: begin
          logic c;
          logic [31:0] n;
          c = (wtype(m_rd) != DTP_NIL) != op[3];
          case (op[2:0])
            3'd0: n = 32'd1;
            3'd1: n = c ? 32'd1 : 32'd2;
            3'd2: n = c ? 32'd2 : 32'd1;
            3'd3: n = 32'd2;
            3'd4: n = 32'd0;
            3'd5: n = c ? 32'd0 : 32'd1;
            3'd6: n = c ? 32'd1 : 32'd0;
            default: n = 32'd1;
          endcase
          if (c && operand == 10'd0) err(E_BRANCH_DOT, 32'd0);
          else begin
            sp <= sp - n;
            if (c) branch(operand);
            st <= S_RETIRE;
          end
        end
        S_LOOPDEC_1: begin
          if (is_fixnum(m_rd) && m_rd[31:0] != 32'h80000000) begin
            if ($signed(m_rd[31:0] - 32'd1) > 0) branch(operand);
            swrite(sp, fixnum(m_rd[31:0] - 32'd1), S_RETIRE);
          end else if (!is_numeric_type(wtype(m_rd))) err(E_UNARY_ARITH_TYPE, 32'd0);
          else begin
            sp <= sp - 32'd1;
            tr_args[0] <= m_rd;
            post_trap(TV_INSTRUCTION_EXCEPTION + {4'd0, op}, 3'd1, inst_pc + {{23{operand[9]}}, operand});
          end
        end
        S_LOOPINC_1: begin t0 <= m_rd; sread(sp - 32'd1, S_LOOPINC_2); end
        S_LOOPINC_2: begin
          if (fix2(t0, m_rd) && t0[31:0] != 32'h7FFFFFFF) begin
            if ($signed(t0[31:0]) < $signed(m_rd[31:0])) branch(operand);
            swrite(sp, fixnum(t0[31:0] + 32'd1), S_RETIRE);
          end else if (!is_numeric_type(wtype(t0)) || !is_numeric_type(wtype(m_rd)))
            err(E_BINARY_ARITH_TYPE, 32'd0);
          else begin
            sp <= sp - 32'd2;
            tr_args[0] <= m_rd;
            tr_args[1] <= t0;
            post_trap(TV_INSTRUCTION_EXCEPTION + {4'd0, op}, 3'd2, inst_pc + {{23{operand[9]}}, operand});
          end
        end

        // ---------------------------------------------------------------- op_block_read
        S_BLK_1: begin
          logic [1:0] kind;
          logic [31:0] rotated, mask, res;
          kind = op[3:2];
          rotated = rotl(mr_d[31:0], alu_control[4:0]);
          mask = 32'hFFFFFFFF << (6'd31 - {1'b0, alu_control[9:5]});   // top byte-s+1 bits
          res = (rotated & mask) | (rotate_latch & ~mask);
          if (operand[5] && !is_fixnum(mr_d))
            err(kind == 2'd2 ? E_BLOCK_READ_TEST_TRANSPORT_FIXNUM : E_BLOCK_READ_TRANSPORT_FIXNUM, mr_final);
          else begin
            bar[op[1:0]] <= setdata(bar[op[1:0]], mr_final + {31'd0, kind != 2'd2 && !operand[2]});
            case (kind)
              2'd0: push_raw(operand[4] ? setcdr(mr_d, 2'd0) : mr_d, S_RETIRE);
              2'd1: begin
                rotate_latch <= rotated;
                push_raw(mkwc(operand[4] ? 2'd0 : wcdr(mr_d), wtype(mr_d), res), S_RETIRE);
              end
              default: begin
                t1 <= operand[4] ? setcdr(mr_d, CDR_NEXT) : mr_d;
                x0 <= mr_final;
                sread(sp, S_BLKTEST_1);
              end
            endcase
          end
        end
        S_BLKTEST_1: begin
          alu_t r;
          r = alu_compute(t1[31:0], m_rd[31:0], t1, m_rd);
          if (operand[5] && !is_fixnum(m_rd)) err(E_BLOCK_READ_TEST_TRANSPORT_FIXNUM, sp);
          else begin
            if (r.rl_we) rotate_latch <= r.rl;
            alu_control <= r.ac;
            if (r.cond) sread(sp - 32'd1, S_BLKTEST_2);
            else begin
              if (!operand[2]) bar[op[1:0]] <= setdata(bar[op[1:0]], x0 + 32'd1);
              st <= S_RETIRE;
            end
          end
        end
        S_BLKTEST_2: begin set_pc(cont_to_pc(m_rd)); st <= S_RETIRE; end

        // %block-n-read-alu
        S_BLKALU_1: begin
          if (!is_fixnum(m_rd)) err(E_BLOCK_READ_BINARY_TRANSPORT_FIXNUM, addr);
          else begin
            t0 <= m_rd;
            mrd(bar[op[1:0]], CYC_DATA_READ, S_BLKALU_2);
          end
        end
        S_BLKALU_2: begin
          alu_t r;
          r = alu_compute(mr_d[31:0], t0[31:0], mr_d, t0);
          if (!is_fixnum(mr_d)) err(E_BLOCK_READ_BINARY_TRANSPORT_FIXNUM, mr_final);
          else begin
            bar[op[1:0]] <= setdata(bar[op[1:0]], mr_final + 32'd1);
            if (r.rl_we) rotate_latch <= r.rl;
            alu_control <= r.ac;
            swrite(addr, setdata(t0, r.result), S_RETIRE);
          end
        end

        // %block-n-write
        S_BLKW_1: write_addr(bar[op[1:0]], opv, S_BLKW_2);
        S_BLKW_2: begin
          bar[op[1:0]] <= setdata(bar[op[1:0]], bar[op[1:0]][31:0] + 32'd1);
          st <= S_RETIRE;
        end

        // ---------------------------------------------------------------- start_call
        S_STARTCALL_1: begin a1 <= opv; call(S_SC, S_RETIRE); end
        S_SC: begin
          t0 <= stripcdr(a1);
          guard <= '0;
          st <= S_SC_LOOP;
        end
        S_SC_LOOP: begin
          case (wtype(t0))
            DTP_COMPILED_FUNCTION: begin
              sc_target <= mkw(DTP_EVEN_PC, t0[31:0]);
              sc_hx <= 1'b0;
              st <= S_SC_PUSH1;
            end
            DTP_SYMBOL: mrd(mkw(DTP_LOCATIVE, t0[31:0] + 32'd2), CYC_DATA_READ, S_SC_SYM);
            DTP_GENERIC_FUNCTION: begin
              sc_extra <= t0; sc_hx <= 1'b1;
              sc_target <= mkw(DTP_EVEN_PC, TRAP_VECTOR_BASE + {20'd0, TV_GENERIC_DISPATCH_TRAP});
              st <= S_SC_PUSH1;
            end
            DTP_INSTANCE: begin
              sc_extra <= t0; sc_hx <= 1'b1;
              sc_target <= mkw(DTP_EVEN_PC, TRAP_VECTOR_BASE + {20'd0, TV_MESSAGE_DISPATCH_TRAP});
              st <= S_SC_PUSH1;
            end
            DTP_LEXICAL_CLOSURE: mrd(mkw(DTP_LOCATIVE, t0[31:0]), CYC_DATA_READ, S_SC_CLOS1);
            default: st <= S_SC_INTERP;
          endcase
        end
        S_SC_SYM: begin
          if (guard > 11'd1000) halt(8'd7);
          guard <= guard + 11'd1;
          t0 <= stripcdr(mr_d);
          st <= S_SC_LOOP;
        end
        S_SC_CLOS1: begin
          t1 <= stripcdr(mr_d);
          mrd(mkw(DTP_LOCATIVE, t0[31:0] + 32'd1), CYC_DATA_READ, S_SC_CLOS2);
        end
        S_SC_CLOS2: begin
          if (wtype(mr_d) == DTP_COMPILED_FUNCTION) begin
            sc_extra <= t1; sc_hx <= 1'b1;
            sc_target <= mkw(DTP_EVEN_PC, mr_d[31:0]);
            st <= S_SC_PUSH1;
          end else st <= S_SC_INTERP;
        end
        S_SC_INTERP: begin
          sc_extra <= t0; sc_hx <= 1'b1;
          x0 <= TRAP_VECTOR_BASE + {20'd0, TV_INTERPRETER} + {26'd0, wtype(t0)};
          mrd(mkw(DTP_LOCATIVE, TRAP_VECTOR_BASE + {20'd0, TV_INTERPRETER} + {26'd0, wtype(t0)}),
              CYC_DATA_READ, S_SC_INTERP2);
        end
        S_SC_INTERP2: begin
          if (!is_pc_type(wtype(mr_d))) err(E_INTERPRETER_TABLE_NOT_PC, x0);
          else begin
            sc_target <= stripcdr(mr_d);
            st <= S_SC_PUSH1;
          end
        end
        S_SC_PUSH1: push_raw(setcdr(cont, 2'd3), S_SC_PUSH2);
        S_SC_PUSH2: push_raw(mkwc(2'd3, DTP_FIXNUM, cr), S_SC_PUSH3);
        S_SC_PUSH3: begin
          cr[CR_CALL_STARTED] <= 1'b1;
          cr[CR_EXTRA_ARGUMENT] <= sc_hx;
          if (sc_hx) push(sc_extra, S_SC_DONE);
          else st <= S_SC_DONE;
        end
        S_SC_DONE: begin
          cont <= sc_target;
          ret();
        end

        // ---------------------------------------------------------------- finish_call
        S_FC_2: begin x0 <= pop_w[31:0] + 32'd1; st <= S_FC_1; end
        S_FC_1: begin
          logic [31:0] nfp, nlp, ncr, limit;
          logic [32:0] npc;
          logic apply;
          apply = op[0];
          nfp = sp - x0 - {31'd0, cr[CR_EXTRA_ARGUMENT]};
          nlp = apply ? sp : sp + 32'd1;
          ncr = cr & ~32'h074FFFFF;
          ncr[19:18] = operand[9:8];
          ncr[7:0] = nlp - nfp;
          ncr[16:9] = nfp - fp;
          ncr[CR_APPLY] = apply;
          if (ncr[CR_CALL_TRACE]) ncr[CR_TRACE_PENDING] = 1'b1;
          npc = cont_to_pc(cont);
          cont <= pc_word(next_pc);
          cr <= ncr;
          fp <= nfp;
          lp <= nlp;
          set_pc(npc);
          limit = mode == TM_EMULATOR ? irw[IRW_CONTROL_STACK_LIMIT][31:0]
                                      : irw[IRW_CONTROL_STACK_EXTRA_LIMIT][31:0];
          if (sp >= limit && limit != 32'd0) begin
            if (mode == TM_EMULATOR) begin
              restart_sp <= sp;
              inst_pc <= npc;
              pre_trap(TV_STACK_OVERFLOW, 3'd0);
            end else halt(8'd8);
          end else st <= S_RETIRE;
        end

        S_LOCLOC_1: begin
          lp <= x0;
          cr[7:0] <= x0[7:0] - fp[7:0];
          st <= S_RETIRE;
        end

        // ---------------------------------------------------------------- do_entry
        S_ENTRY: begin
          if (loopn > 16'd1023 && loopn != 16'hFFFF) halt(8'd9);
          if (cr[CR_TRACE_PENDING]) begin
            cr[CR_TRACE_PENDING] <= 1'b0;
            restart_sp <= sp;
            pre_trap(TV_TRACE, 3'd0);
          end else if (cr[CR_APPLY]) sread(sp, S_ENTRY_1);
          else st <= S_ENTRY_NA;
        end
        S_ENTRY_1: begin
          if (wtype(m_rd) == DTP_NIL) begin
            sp <= sp - 32'd1;
            cr[CR_APPLY] <= 1'b0;
            st <= S_ENTRY_NA;
          end else begin
            e_tos <= m_rd;
            st <= S_ENTRY_AP;
          end
        end
        S_ENTRY_NA: begin
          if (cr[7:0] < e_min) err(E_TOO_FEW_ARGUMENTS, 32'd0);
          else if (cr[7:0] > e_max) begin
            if (op != 8'o176) err(E_TOO_MANY_ARGUMENTS, 32'd0);
            else begin
              e_index <= {24'd0, e_max - e_min} + 32'd1;
              call(S_PAA, S_ENTRY_GO);
            end
          end else begin
            e_index <= {24'd0, cr[7:0] - e_min};
            st <= S_ENTRY_GO;
          end
        end
        S_ENTRY_AP: begin
          logic signed [9:0] need;
          need = $signed({2'b00, e_max}) - $signed({2'b00, cr[7:0]});
          loopn <= loopn + 16'd1;
          if (op != 8'o176) begin
            if (need <= 0) err(E_TOO_MANY_ARGUMENTS, 32'd0);
            else begin
              restart_sp <= sp;
              pull_n <= {{22{need[9]}}, need};
              call(S_PULL, S_ENTRY);
            end
          end else if (need > 0) begin
            restart_sp <= sp;
            pull_n <= {{22{need[9]}}, need};
            call(S_PULL, S_ENTRY);
          end else if (need < 0) begin
            e_index <= {24'd0, e_max - e_min} + 32'd1;
            call(S_PAA, S_ENTRY_GO);
          end else begin
            e_index <= {24'd0, cr[7:0] - e_min} + 32'd1;
            swrite(sp, setcdr(e_tos, CDR_NIL), S_ENTRY_GO);
          end
        end
        S_ENTRY_GO: begin
          if (e_index == 32'd0) set_pc(next_pc);
          else set_pc((next_pc + {e_index, 1'b0}) & ~33'd1);
          st <= S_RETIRE;
        end

        // pull_apply_args: pull one argument out of the apply list on the stack
        S_PULL: sread(sp, S_PULL_1);
        S_PULL_1: begin
          if (wtype(m_rd) == DTP_NIL) begin
            sp <= sp - 32'd1;
            cr[CR_APPLY] <= 1'b0;
            ret();
          end else if (wtype(m_rd) != DTP_LIST) begin
            sp <= sp - 32'd1;
            restart_sp <= sp - 32'd1;
            tr_args[0] <= fixnum(pull_n);
            tr_args[1] <= stripcdr(m_rd);
            pre_trap(TV_PULL_APPLY_ARGS, 3'd2);
          end else begin
            t0 <= m_rd;
            mrd(mkw(DTP_LOCATIVE, m_rd[31:0]), CYC_DATA_READ, S_PULL_2);
          end
        end
        S_PULL_2: begin t1 <= mr_d; carcdr(t0, 1'b0, S_PULL_3); end
        S_PULL_3: begin t2 <= cc_r; swrite(sp, setcdr(t1, CDR_NEXT), S_PULL_4); end
        S_PULL_4: push(t2, S_PULL_5);
        S_PULL_5: begin
          cr[7:0] <= cr[7:0] + 8'd1;
          lp <= lp + 32'd1;
          ret();
        end

        // push_apply_args: make the rest argument list
        S_PAA: sread(sp, S_PAA_1);
        S_PAA_1: begin t0 <= m_rd; swrite(sp, setcdr(m_rd, CDR_NIL), S_PAA_2); end
        S_PAA_2: begin
          if (cr[CR_APPLY] && wtype(t0) == DTP_NIL) begin
            sp <= sp - 32'd1;
            cr[CR_APPLY] <= 1'b0;
            sread(sp - 32'd1, S_PAA_3);
          end else if (!cr[CR_APPLY]) push(mkw(DTP_LIST, fp + {24'd0, e_max}), S_RETURN);
          else sread(sp - 32'd1, S_PAA_4);
        end
        S_PAA_3: swrite(sp, setcdr(m_rd, CDR_NIL), S_PAA_5);
        S_PAA_5: push(mkw(DTP_LIST, fp + {24'd0, e_max}), S_RETURN);
        S_PAA_4: swrite(sp - 32'd1, setcdr(m_rd, CDR_NORMAL), S_PAA_6);
        S_PAA_6: push(mkw(DTP_LIST, fp + {24'd0, e_max}), S_PAA_7);
        S_PAA_7: begin
          lp <= lp + 32'd1;
          cr[7:0] <= cr[7:0] + 8'd1;
          ret();
        end

        // ---------------------------------------------------------------- do_return
        S_RETM_1: begin
          if (!is_fixnum(opv)) err(E_ONE_OPERAND_FIXNUM_TYPE, 32'd0);
          else begin
            ret_kind <= op == 8'o104 ? 2'd1 : 2'd2;
            ret_nvals <= opv[31:0];
            st <= S_RET;
          end
        end
        S_RET: begin
          if (cr[26:24] != 3'd0) call(S_CLEANUP, S_RET_GATHER);
          else st <= S_RET_GATHER;
        end
        S_RET_GATHER: begin
          ret_disp <= cr[19:18];
          if (ret_kind == 2'd0) begin
            ret_nvals <= 32'd1;
            if (ret_arg[7:0] == 8'd0) sread(sp, S_RET_SINGLE);
            else begin
              ret_single <= ret_arg[0] ? T_W : NIL_W;
              st <= S_RET_FRAME1;
            end
          end else begin
            ret_vbase <= sp - ret_nvals + 32'd1;
            if (ret_kind == 2'd1 && ret_nvals + {24'd0, cr[16:9]} > irw[IRW_STACK_FRAME_MAXIMUM_SIZE][31:0] &&
                irw[IRW_STACK_FRAME_MAXIMUM_SIZE][31:0] != 32'd0 && cr[19:18] == VD_MULTIPLE)
              err(E_FRAME_OVERFLOW, 32'd0);
            else st <= S_RET_FRAME1;
          end
        end
        S_RET_SINGLE: begin ret_single <= stripcdr(m_rd); st <= S_RET_FRAME1; end
        S_RET_FRAME1: sread(fp, S_RET_FRAME2);
        S_RET_FRAME2: begin t0 <= m_rd; sread(fp + 32'd1, S_RET_FRAME3); end
        S_RET_FRAME3: begin
          logic [31:0] nfp, ncr;
          if (ret_kind == 2'd2 || ret_disp != VD_RETURN) set_pc(cont_to_pc(cont));
          cont <= mkw(wtype(t0), t0[31:0]);
          sp <= fp - 32'd1;
          nfp = fp - {24'd0, cr[16:9]};
          ncr = m_rd[31:0] | (cr & (32'd1 << CR_TRACE_PENDING));
          fp <= nfp;
          cr <= ncr;
          lp <= nfp + {24'd0, ncr[7:0]};
          // the caller's frame is reloaded into the stack cache
          if (nfp < stack_cache_lower_bound) stack_cache_lower_bound <= nfp;
          cnt <= '0;
          st <= S_RET_VALUES;
        end
        S_RET_VALUES: begin
          if (ret_kind == 2'd2) st <= S_RET_COPY;
          else if (ret_kind == 2'd0) begin
            case (ret_disp)
              VD_EFFECT: st <= S_RETIRE;
              VD_VALUE: push(ret_single, S_RETIRE);
              VD_MULTIPLE: push(ret_single, S_RET_PUSH1);
              default: begin
                if (ret_arg[7:0] == 8'd0) push(ret_single, S_RET_REEXEC);
                else st <= S_RET_REEXEC;
              end
            endcase
          end else begin
            case (ret_disp)
              VD_EFFECT: st <= S_RETIRE;
              VD_VALUE: begin
                if (ret_nvals != 32'd0) sread(ret_vbase, S_RET_V1);
                else push(NIL_W, S_RETIRE);
              end
              default: st <= S_RET_COPY;
            endcase
          end
        end
        S_RET_PUSH1: push(fixnum(32'd1), S_RETIRE);
        S_RET_V1: push(stripcdr(m_rd), S_RETIRE);
        S_RET_COPY: begin
          if (cnt < ret_nvals) sread(ret_vbase + cnt, S_RET_COPY1);
          else begin
            sp <= sp + ret_nvals;
            st <= S_RET_AFTERCOPY;
          end
        end
        S_RET_COPY1: begin
          cnt <= cnt + 32'd1;
          swrite(sp + 32'd1 + cnt, ret_kind == 2'd2 ? m_rd : setcdr(m_rd, CDR_NEXT), S_RET_COPY);
        end
        S_RET_AFTERCOPY: begin
          if (ret_kind == 2'd2) st <= S_RETIRE;
          else if (ret_disp == VD_MULTIPLE) push(fixnum(ret_nvals), S_RETIRE);
          else if (ret_sppop) push(fixnum(ret_nvals), S_RET_REEXEC);
          else st <= S_RET_REEXEC;
        end
        S_RET_REEXEC: begin set_pc(inst_pc); st <= S_RETIRE; end

        // frame_cleanup (subroutine; if an unwind-protect is started the instruction ends)
        S_CLEANUP: begin
          if (cr[CR_CLEANUP_CATCH]) begin
            cb <= irw[IRW_CATCH_BLOCK_LIST][31:0];
            sread(irw[IRW_CATCH_BLOCK_LIST][31:0] + 32'd1, S_CLEAN_C1);
          end else if (cr[CR_CLEANUP_BINDINGS]) call(S_UNBIND, S_CLEAN_B);
          else if (cr[CR_TRAP_ON_EXIT]) begin
            sp <= restart_sp;
            err(E_TRAP_ON_EXIT, 32'd0);
          end else ret();
        end
        S_CLEAN_C1: begin
          if (m_rd[38]) begin
            sp <= restart_sp;
            from_return <= 1'b1;
            rstack[0] <= S_RETIRE;
            rsp <= 3'd1;
            st <= S_CATCHC;
          end else sread(cb + 32'd2, S_CLEAN_C2);
        end
        S_CLEAN_C2: begin
          cr[CR_CLEANUP_CATCH] <= m_rd[38];
          irw[IRW_CATCH_BLOCK_LIST] <= stripcdr(m_rd);
          st <= S_CLEANUP;
        end
        S_CLEAN_B: begin
          if (cr[CR_CLEANUP_BINDINGS]) call(S_UNBIND, S_CLEAN_B);
          else begin
            if (preempt_register[1]) preempt_register[0] <= 1'b1;
            st <= S_CLEANUP;
          end
        end

        // take-values
        S_TAKEV_1: begin t0 <= opv; pop(S_TAKEV_2); end
        S_TAKEV_2: begin
          if (pop_w[31:0] >= t0[31:0]) begin
            sp <= sp - pop_w[31:0] + t0[31:0];
            st <= S_RETIRE;
          end else begin
            cnt <= t0[31:0] - pop_w[31:0];
            st <= S_TAKEV_3;
          end
        end
        S_TAKEV_3: begin
          if (cnt == 32'd0) st <= S_RETIRE;
          else begin
            cnt <= cnt - 32'd1;
            push(NIL_W, S_TAKEV_3);
          end
        end

        // ---------------------------------------------------------------- binding
        S_BIND_1: begin val <= opv; pop(S_BIND_1B); end
        S_BIND_1B: begin a1 <= pop_w; st <= S_BIND_3; end
        S_BIND_2: begin a1 <= opv; st <= S_BIND_3; end
        S_BIND_3: begin
          if (wtype(a1) != DTP_LOCATIVE) err(E_BIND_LOCATIVE_TYPE, 32'd0);
          else if (irw[IRW_BSP][31:0] + 32'd2 > irw[IRW_BSL][31:0]) err(E_BINDING_STACK_OVERFLOW, 32'd0);
          else mrd(mkw(DTP_LOCATIVE, a1[31:0]), CYC_BIND_READ, S_BIND_4);
        end
        S_BIND_4: begin
          t0 <= mr_d;
          swrite(irw[IRW_BSP][31:0] + 32'd1, mkwc({1'b0, cr[CR_CLEANUP_BINDINGS]}, DTP_LOCATIVE, a1[31:0]),
                 S_BIND_5);
        end
        S_BIND_5: swrite(irw[IRW_BSP][31:0] + 32'd2, t0, S_BIND_6);
        S_BIND_6: begin
          irw[IRW_BSP] <= setdata(irw[IRW_BSP], irw[IRW_BSP][31:0] + 32'd2);
          cr[CR_CLEANUP_BINDINGS] <= 1'b1;
          if (op == 8'o236) mwr(mkw(DTP_LOCATIVE, a1[31:0]), CYC_BIND_WRITE, val, 1'b1, S_RETIRE);
          else st <= S_RETIRE;
        end

        S_UNBINDN_1: begin
          if (!is_fixnum(opv)) err(E_ONE_OPERAND_FIXNUM_TYPE, 32'd0);
          else begin cnt <= opv[31:0]; st <= S_UNBINDN_2; end
        end
        S_UNBINDN_2: begin
          if (cnt == 32'd0) begin
            if (preempt_register[1]) preempt_register[0] <= 1'b1;
            st <= S_RETIRE;
          end else begin
            cnt <= cnt - 32'd1;
            call(S_UNBIND, S_UNBINDN_2);
          end
        end
        S_RESTB_1: begin
          if (wtype(opv) != DTP_LOCATIVE) err(E_OPERAND_LOCATIVE_TYPE, 32'd0);
          else begin a1 <= opv; st <= S_RESTB_2; end
        end
        S_RESTB_2: begin
          if (irw[IRW_BSP][31:0] > a1[31:0]) call(S_UNBIND, S_RESTB_2);
          else begin
            if (preempt_register[1]) preempt_register[0] <= 1'b1;
            st <= S_RETIRE;
          end
        end

        // ---------------------------------------------------------------- catch
        S_CATCHO_1: push_raw(setcdr(irw[IRW_CATCH_BLOCK_LIST], {cr[CR_EXTRA_ARGUMENT], cr[CR_CLEANUP_CATCH]}),
                             S_CATCHO_2);
        S_CATCHO_2: begin
          if (!operand[0]) push_raw(setcdr(cont, operand[7:6]), S_CATCHO_3);
          else st <= S_CATCHO_3;
        end
        S_CATCHO_3: begin
          irw[IRW_CATCH_BLOCK_LIST] <= mkw(DTP_LOCATIVE, x0);
          cr[CR_CLEANUP_CATCH] <= 1'b1;
          st <= S_RETIRE;
        end

        // catch_close (subroutine)
        S_CATCHC: begin
          cb <= irw[IRW_CATCH_BLOCK_LIST][31:0];
          sread(irw[IRW_CATCH_BLOCK_LIST][31:0] + 32'd1, S_CATCHC_1);
        end
        S_CATCHC_1: begin t0 <= m_rd; sread(cb + 32'd2, S_CATCHC_2); end
        S_CATCHC_2: begin
          t1 <= m_rd;
          if (irw[IRW_BSP][31:0] != t0[31:0]) st <= S_CATCHC_3;
          else st <= S_CATCHC_4;
        end
        S_CATCHC_3: begin
          if (irw[IRW_BSP][31:0] > t0[31:0]) call(S_UNBIND, S_CATCHC_3);
          else begin
            if (preempt_register[1]) preempt_register[0] <= 1'b1;
            st <= S_CATCHC_4;
          end
        end
        S_CATCHC_4: begin
          logic [31:0] ncr;
          ncr = cr & ~((32'd1 << CR_CLEANUP_CATCH) | (32'd1 << CR_EXTRA_ARGUMENT));
          ncr[CR_CLEANUP_CATCH] = t1[38];
          ncr[CR_EXTRA_ARGUMENT] = t1[39];
          irw[IRW_CATCH_BLOCK_LIST] <= stripcdr(t1);
          if (t0[38]) begin   // unwind-protect: run the cleanup handler
            x0 <= ncr | (32'd1 << CR_CLEANUP_IN_PROGRESS);
            sread(cb, S_CATCHC_5);
          end else begin
            cr <= ncr;
            ret();
          end
        end
        S_CATCHC_5: begin
          logic [32:0] rpc;
          rpc = from_return ? inst_pc : next_pc;
          t2 <= m_rd;
          push_raw(mkwc({1'b1, cr[CR_CLEANUP_IN_PROGRESS]}, rpc[0] ? DTP_ODD_PC : DTP_EVEN_PC, rpc[32:1]),
                   S_CATCHC_6);
        end
        S_CATCHC_6: begin
          cr <= x0;
          set_pc(cont_to_pc(t2));
          ret();
        end

        // ---------------------------------------------------------------- lexical variables
        S_LEX_1: begin
          if (wtype(opv) != DTP_LIST && wtype(opv) != DTP_LOCATIVE) err(E_UNARY_LEXENV_TYPE, 32'd0);
          else mrd(mkw(DTP_LOCATIVE, opv[31:0] + {29'd0, op[2:0]}), CYC_DATA_READ, S_PUSH_MRD);
        end
        S_LEXW_1: begin a2 <= opv; sread(sp, S_LEXW_2); end
        S_LEXW_2: begin
          if (wtype(a2) != DTP_LIST && wtype(a2) != DTP_LOCATIVE) err(E_BINARY_LEXENV_TYPE, 32'd0);
          else mwr(mkw(DTP_LOCATIVE, a2[31:0] + {29'd0, op[2:0]}), CYC_DATA_WRITE, m_rd, 1'b1, S_LEXW_3);
        end
        S_LEXW_3: begin
          if (op < 8'o250) sp <= sp - 32'd1;
          st <= S_RETIRE;
        end

        // ---------------------------------------------------------------- instance variables
        S_IVM_1: begin x0 <= opv[31:0]; sread(fp + 32'd2, S_IVM_2); end
        S_IVM_2: begin
          if (wtype(m_rd) != DTP_ARRAY) err(E_SELF_MAPPING_TABLE_TYPE, 32'd0);
          else mrd(mkw(DTP_LOCATIVE, m_rd[31:0]), CYC_HEADER, S_IVM_3);
        end
        S_IVM_3: begin
          if (x0 >= {17'd0, mr_d[14:0]}) err(E_MAPPING_TABLE_INDEX_BOUNDS, 32'd0);
          else mrd(mkw(DTP_LOCATIVE, mr_final + 32'd1 + x0), CYC_DATA_READ, S_IVM_4);
        end
        S_IVM_4: begin
          if (!is_fixnum(mr_d)) err(E_ILLEGAL_INSTANCE_VARIABLE_INDEX, 32'd0);
          else begin
            t0 <= mr_d;
            sread(fp + 32'd3, S_IVM_5);
          end
        end
        S_IVM_5: begin
          if (!is_instance_type(wtype(m_rd))) err(E_SELF_TYPE, 32'd0);
          else begin
            t1 <= m_rd;
            x1 <= m_rd[31:0];
            if (wcdr(m_rd) != 2'd1) mrd(mkw(DTP_LOCATIVE, m_rd[31:0]), CYC_HEADER, S_IVM_6);
            else st <= S_IVM_ACCESS;
          end
        end
        S_IVM_6: begin
          x1 <= mr_final;
          if (mr_final == x1) swrite(fp + 32'd3, setcdr(t1, 2'd1), S_IVM_ACCESS);
          else st <= S_IVM_ACCESS;
        end
        S_IVM_ACCESS: begin
          logic [31:0] ea;
          ea = x1 + t0[31:0];
          addr <= ea;
          case (op)
            8'o110, 8'o112: mrd(mkw(DTP_LOCATIVE, ea), CYC_DATA_READ, S_PUSH_MRD);
            8'o111, 8'o113: push(mkw(DTP_LOCATIVE, ea), S_RETIRE);
            default: sread(sp, S_IVM_7);
          endcase
        end
        S_IVM_7: mwr(mkw(DTP_LOCATIVE, addr), CYC_DATA_WRITE, m_rd, 1'b1, S_IVM_8);
        S_IVM_8: begin
          if (op == 8'o320 || op == 8'o322) sp <= sp - 32'd1;
          st <= S_RETIRE;
        end
        S_IVU_1: begin x0 <= opv[31:0]; sread(fp + 32'd3, S_IVU_2); end
        S_IVU_2: begin
          if (!is_instance_type(wtype(m_rd))) err(E_SELF_TYPE, 32'd0);
          else begin
            x1 <= m_rd[31:0];
            t0 <= fixnum(x0);
            st <= S_IVM_ACCESS;
          end
        end

        // %instance-ref, %instance-set, %instance-loc
        S_IREF_1: begin a2 <= opv; pop(S_IREF_2); end
        S_IREF_2: begin
          a1 <= pop_w;
          if (op == 8'o325) pop(S_IREF_3);
          else st <= S_IREF_4;
        end
        S_IREF_3: begin val <= pop_w; st <= S_IREF_4; end
        S_IREF_4: begin
          if (!is_instance_type(wtype(a1)) || !is_fixnum(a2))
            err(op == 8'o325 ? E_INSTANCE_REF_TYPE_3 : E_INSTANCE_REF_TYPE_BINARY, 32'd0);
          else mrd(mkw(DTP_LOCATIVE, a1[31:0]), CYC_HEADER, S_IREF_5);
        end
        S_IREF_5: begin
          x1 <= mr_final;
          mrd(mkw(DTP_LOCATIVE, mr_d[31:0] - 32'd1), CYC_DATA_READ, S_IREF_6);
        end
        S_IREF_6: begin
          logic [31:0] ea;
          ea = x1 + a2[31:0];
          if (!is_fixnum(mr_d) || a2[31:0] >= mr_d[31:0]) err(E_ILLEGAL_INSTANCE_VARIABLE_INDEX, 32'd0);
          else if (op == 8'o324) mrd(mkw(DTP_LOCATIVE, ea), CYC_DATA_READ, S_PUSH_MRD);
          else if (op == 8'o326) push(mkw(DTP_LOCATIVE, ea), S_RETIRE);
          else mwr(mkw(DTP_LOCATIVE, ea), CYC_DATA_WRITE, val, 1'b1, S_RETIRE);
        end

        // ---------------------------------------------------------------- subprimitives
        S_EPHP_1: push(boolw(is_pointer_type(wtype(opv)) && opv[31:27] == 5'd0), S_RETIRE);
        S_ULESS_1: begin a2 <= opv; sread(sp, S_ULESS_2); end
        S_ULESS_2: begin
          if (op == 8'o331) sp <= sp - 32'd1;
          push(boolw(m_rd[31:0] < a2[31:0]), S_RETIRE);
        end
        S_ALU_1: begin a2 <= opv; pop(S_ALU_2); end
        S_ALU_2: begin
          alu_t r;
          r = alu_compute(pop_w[31:0], a2[31:0], pop_w, a2);
          if (!fix2(pop_w, a2)) err(E_TWO_OPERAND_FIXNUM_TYPE, 32'd0);
          else begin
            if (r.rl_we) rotate_latch <= r.rl;
            alu_control <= r.ac;
            push(fixnum(r.result), S_RETIRE);
          end
        end
        S_ALLOC_1: begin a2 <= opv; pop(S_ALLOC_2); end
        S_ALLOC_2: begin
          int ia, iad, il;
          ia = op == 8'o311 ? IRW_LIST_CACHE_AREA : IRW_STRUCTURE_CACHE_AREA;
          iad = op == 8'o311 ? IRW_LIST_CACHE_ADDRESS : IRW_STRUCTURE_CACHE_ADDRESS;
          il = op == 8'o311 ? IRW_LIST_CACHE_LENGTH : IRW_STRUCTURE_CACHE_LENGTH;
          if (!is_fixnum(a2)) err(E_ALLOCATE_TYPE, 32'd0);
          else if (stripcdr(pop_w) != stripcdr(irw[ia]) || a2[31:0] > irw[il][31:0])
            exc(3'd2, pop_w, a2, '0);
          else begin
            irw[il] <= setdata(irw[il], irw[il][31:0] - a2[31:0]);
            bar[1] <= stripcdr(irw[iad]);
            irw[iad] <= setdata(irw[iad], irw[iad][31:0] + a2[31:0]);
            if (mode == TM_EMULATOR) cr[CR_TRAP_MODE] <= 1'b1;
            push(irw[iad], S_RETIRE);
          end
        end
        S_PPLUS_1: begin a2 <= opv; pop(S_PPLUS_2); end
        S_PPLUS_2: begin
          if (op == 8'o230) push(setdata(pop_w, pop_w[31:0] + a2[31:0]), S_RETIRE);
          else push(fixnum(pop_w[31:0] - a2[31:0]), S_RETIRE);
        end
        S_PINC_1: swrite(addr, setdata(m_rd, m_rd[31:0] + 32'd1), S_RETIRE);

        // ---------------------------------------------------------------- internal registers
        S_RIR_1: begin
          logic [9:0] r;
          r = operand;
          if (r < 10'o1000 && r[6:0] == 7'o006) push(stripcdr(bar[r[8:7]]), S_RETIRE);
          else if (r < 10'o1000 && r[6:0] == 7'o007)
            push(fixnum(pht_hash(bar[r[8:7]][31:0] & 32'hFFFFFF00)), S_RETIRE);
          else if (r == 10'o001) push(mkw(DTP_LOCATIVE, fp), S_RETIRE);
          else if (r == 10'o002) push(mkw(DTP_LOCATIVE, lp), S_RETIRE);
          else if (r == 10'o003) push(mkw(DTP_LOCATIVE, sp), S_RETIRE);
          else if (r >= 10'o1000) begin
            if (r == 10'o1000) sread(sp, S_RIR_TOS);
            else if (r == 10'o1007) push(mkw(DTP_PHYSICAL_ADDRESS, pht_base), S_RETIRE);
            else if (r == 10'o1010) push(fixnum(pht_mask), S_RETIRE);
            else if (r == 10'o1040) push(NIL_W, S_RETIRE);
            else if (r == 10'o1041) push(T_W, S_RETIRE);
            else if (irw_reg(r)) push(irw[r[4:0]], S_RETIRE);
            else begin
              scratch_rd_ix <= r[8:0];
              st <= S_RIR_SCR;
            end
          end else begin
            case (r)
              10'o000, 10'o004: push(mkw(DTP_LOCATIVE, sp), S_RETIRE);
              10'o005: push(mkw(DTP_LOCATIVE, stack_cache_lower_bound), S_RETIRE);
              10'o010, 10'o011: push(pc_word(inst_pc), S_RETIRE);
              10'o012: push(stripcdr(cont), S_RETIRE);
              10'o013: push(fixnum(alu_control), S_RETIRE);
              10'o014: push(fixnum(cr), S_RETIRE);
              10'o015: push(fixnum({24'd0, cr[7:0]}), S_RETIRE);
              10'o016: push(fixnum(ephemeral_oldspace), S_RETIRE);
              10'o017: push(fixnum(zone_oldspace), S_RETIRE);
              10'o020: push(fixnum(chip_revision), S_RETIRE);
              10'o021: push(fixnum(fp_coprocessor_present), S_RETIRE);
              10'o023: push(fixnum(preempt_register), S_RETIRE);
              10'o024: push(fixnum(icache_control), S_RETIRE);
              10'o025: push(fixnum(prefetcher_control), S_RETIRE);
              10'o026: push(fixnum(map_cache_control), S_RETIRE);
              10'o027: push(fixnum(memory_control), S_RETIRE);
              10'o034: push(mkw(DTP_LOCATIVE, stack_cache_overflow_limit), S_RETIRE);
              10'o040: push(fixnum(entry_max_args), S_RETIRE);
              10'o047: push(fixnum(usec_clock), S_RETIRE);
              default: push(fixnum(32'd0), S_RETIRE);
            endcase
          end
        end
        S_RIR_TOS: push(stripcdr(m_rd), S_RETIRE);
        S_RIR_SCR: st <= S_RIR_SCR2;   // scratch is read one cycle after its index is set
        S_RIR_SCR2: push(stripcdr(scratch_rd), S_RETIRE);

        S_WIR_1: begin
          logic [9:0] r;
          r = operand;
          if (r < 10'o1000 && (r[6:0] == 7'o006 || r[6:0] == 7'o052)) begin
            bar[r[8:7]] <= stripcdr(pop_w);
            st <= S_RETIRE;
          end else if (r < 10'o1000 && (r[6:0] == 7'o032 || r[6:0] == 7'o033)) begin
            // invalidate-map / load-map n: the entry for BARn's page
            map_vpn <= bar[r[8:7]][31:8];
            map_data <= pop_w[31:0];
            if (r[6:0] == 7'o032) map_inval <= 1'b1; else map_load <= 1'b1;
            st <= S_RETIRE;
          end
          else if (r >= 10'o1000) begin
            if (r == 10'o1000) swrite(sp, pop_w, S_RETIRE);
            else begin
              if (r == 10'o1007) begin pht_base <= pop_w[31:0]; map_flush <= 1'b1; end
              else if (r == 10'o1010) begin pht_mask <= pop_w[31:0]; map_flush <= 1'b1; end
              else if (irw_reg(r)) irw[r[4:0]] <= pop_w;
              else scratch[r[8:0]] <= pop_w;
              st <= S_RETIRE;
            end
          end else begin
            case (r)
              10'o001: fp <= pop_w[31:0];
              10'o002: lp <= pop_w[31:0];
              10'o003: sp <= pop_w[31:0];
              10'o005: stack_cache_lower_bound <= pop_w[31:0];
              10'o012: cont <= stripcdr(pop_w);
              10'o013: alu_control <= pop_w[31:0];
              10'o014: cr <= pop_w[31:0];
              10'o016: ephemeral_oldspace <= pop_w[31:0];
              10'o017: zone_oldspace <= pop_w[31:0];
              10'o021: fp_coprocessor_present <= pop_w[31:0];
              10'o023: preempt_register <= pop_w[31:0];
              10'o024: icache_control <= pop_w[31:0];
              10'o025: prefetcher_control <= pop_w[31:0];
              10'o026: begin map_cache_control <= pop_w[31:0]; map_flush <= 1'b1; end
              10'o027: memory_control <= pop_w[31:0];
              10'o034: stack_cache_overflow_limit <= pop_w[31:0];
              10'o040: entry_max_args <= pop_w[31:0];
              default: ;
            endcase
            st <= S_RETIRE;
          end
        end

        // ---------------------------------------------------------------- coprocessor
        S_COPR_1: if (cop_ack) begin
          cop_req <= 1'b0;
          if (cop_err) err(E_UNKNOWN_INTERNAL_REGISTER, 32'd0);
          else push(cop_rdata, S_RETIRE);
        end
        S_COPW_1: begin
          a1 <= pop_w;
          cop_req <= 1'b1;
          cop_we <= 1'b1;
          cop_reg <= operand;
          cop_wdata <= pop_w;
          ib_valid <= 1'b0;
          st <= S_COP_W;
        end
        S_COP_W: if (cop_ack) begin
          cop_req <= 1'b0;
          if (cop_err) err(E_UNKNOWN_INTERNAL_REGISTER, 32'd0);
          else st <= S_RETIRE;
        end

        // ---------------------------------------------------------------- memory subprimitives
        S_MRDI_1: begin
          a1 <= pop_w;
          mrd(pop_w, operand[9:6] >= CYC_COUNT ? CYC_RAW : operand[9:6], S_MRDI_2);
        end
        S_MRDI_2: begin
          word_t res;
          res = (wtype(a1) == DTP_PHYSICAL_ADDRESS && mr_final == a1[31:0]) ? a1 : mkw(wtype(a1), mr_final);
          if (operand[5] && !is_fixnum(mr_d)) err(E_MEMORY_READ_TRANSPORT_FIXNUM, mr_final);
          else if (op == 8'o116) push_raw(operand[4] ? setcdr(mr_d, 2'd0) : mr_d, S_RETIRE);
          else push_raw(operand[4] ? setcdr(res, 2'd0) : setcdr(res, wcdr(mr_d)), S_RETIRE);
        end
        S_TAG_1: push(fixnum({24'd0, opv[39:32]}), S_RETIRE);
        S_SETTAG_1: begin a2 <= opv; pop(S_SETTAG_2); end
        S_SETTAG_2: begin
          if (!is_fixnum(a2)) err(E_ONE_OPERAND_FIXNUM_TYPE, 32'd0);
          else push_raw({a2[7:0], pop_w[31:0]}, S_RETIRE);
        end
        S_STORC_1: begin a3 <= opv; pop(S_STORC_2); end
        S_STORC_2: begin a2 <= pop_w; pop(S_STORC_3); end
        S_STORC_3: begin
          a1 <= pop_w;
          if (wtype(pop_w) != DTP_LOCATIVE && wtype(pop_w) != DTP_PHYSICAL_ADDRESS)
            err(E_OPERAND_1_TYPE_LOCATIVE, 32'd0);
          else mrd(pop_w, CYC_DATA_READ, S_STORC_4);
        end
        S_STORC_4: begin
          if (stripcdr(mr_d) == stripcdr(a2)) begin
            m_addr <= mr_final; m_we <= 1'b1; m_wd <= {mr_d[39:38], a3[37:0]};
            m_phys <= wtype(a1) == DTP_PHYSICAL_ADDRESS && mr_final == a1[31:0];
            call(S_MEM, S_PUSH_T);
          end else push(NIL_W, S_RETIRE);
        end
        S_MWRI_1: begin a2 <= opv; pop(S_MWRI_2); end
        S_MWRI_2: write_addr(pop_w, a2, S_RETIRE);
        S_PSTORE_1: begin a2 <= opv; pop(S_PSTORE_2); end
        S_PSTORE_2: begin a1 <= pop_w; read_addr(pop_w, S_PSTORE_3); end
        S_PSTORE_3: write_addr(a1, {m_rd[39:38], a2[37:0]}, S_RETIRE);
        S_SETCDR_1: swrite(addr, setcdr(m_rd, op == 8'o146 ? 2'd1 : 2'd2), S_RETIRE);
        S_MERGE_1: begin t0 <= m_rd; sread(addr, S_MERGE_2); end
        S_MERGE_2: swrite(addr, setcdr(m_rd, wcdr(t0)), S_RETIRE);

        // ---------------------------------------------------------------- %generic/%message-dispatch
        S_DISP_RETRY: begin set_pc(inst_pc); st <= S_RETIRE; end
        S_DISP_1: begin
          t0 <= stripcdr(m_rd);   // generic function
          sread(fp + (op == 8'o052 ? 32'd3 : 32'd2), S_DISP_2);
        end
        S_DISP_2: begin
          t1 <= stripcdr(m_rd);   // instance
          if (is_instance_type(wtype(m_rd))) mrd(mkw(DTP_LOCATIVE, m_rd[31:0]), CYC_HEADER, S_DISP_3);
          else mrd(mkw(DTP_LOCATIVE, TRAP_VECTOR_BASE + {20'd0, TV_GENERIC_DISPATCH} + {26'd0, wtype(m_rd)}),
                   CYC_DATA_READ, S_DISP_3);
        end
        S_DISP_3: begin
          desc <= mr_d[31:0];
          mrd(mkw(DTP_LOCATIVE, mr_d[31:0]), CYC_DATA_READ, S_DISP_4);
        end
        S_DISP_4: begin
          if (!is_fixnum(mr_d)) err(E_FLAVOR_SEARCH_MASK_NOT_FIXNUM, desc);
          else begin
            x0 <= mr_d[31:0];
            mrd(mkw(DTP_LOCATIVE, desc + 32'd1), CYC_DATA_READ, S_DISP_5);
          end
        end
        S_DISP_5: begin
          logic [31:0] m;
          m = x0 & t0[31:0];
          if (wtype(mr_d) != DTP_LOCATIVE) err(E_FLAVOR_SEARCH_TABLE_NOT_LOCATIVE, desc + 32'd1);
          else begin
            x1 <= mr_d[31:0];
            cnt <= (m << 1) + m;
            loopn <= '0;
            st <= S_DISP_6;
          end
        end
        S_DISP_6: begin
          ka <= x1 + cnt;
          mrd(mkw(DTP_LOCATIVE, x1 + cnt), CYC_DATA_READ, S_DISP_7);
        end
        S_DISP_7: begin
          if (wtype(mr_d) == DTP_NIL || (wtype(mr_d) == wtype(t0) && mr_d[31:0] == t0[31:0]))
            mrd(mkw(DTP_LOCATIVE, ka + 32'd1), CYC_DATA_READ, S_DISP_8);
          else begin
            if (loopn == 16'hFFFF) halt(8'd10);
            loopn <= loopn + 16'd1;
            cnt <= cnt + 32'd3;
            st <= S_DISP_6;
          end
        end
        S_DISP_8: begin
          t2 <= mr_d;   // method
          mrd(mkw(DTP_LOCATIVE, ka + 32'd2), CYC_DATA_READ, S_DISP_9);
        end
        S_DISP_9: begin
          a3 <= mr_d;   // parameter
          if (!is_pc_type(wtype(t2))) err(E_GENERIC_SEARCH_ENTRY_NOT_PC, ka + 32'd1);
          else if (op == 8'o052) begin
            if (wtype(mr_d) != DTP_NIL) swrite(fp + 32'd2, mr_d, S_DISP_JUMP);
            else st <= S_DISP_JUMP;
          end else sread(fp + 32'd2, S_DISP_10);
        end
        S_DISP_10: begin
          a1 <= m_rd;
          if (wtype(a3) != DTP_NIL) swrite(fp + 32'd2, a3, S_DISP_12);
          else sread(fp + 32'd3, S_DISP_11);
        end
        S_DISP_11: swrite(fp + 32'd2, m_rd, S_DISP_12);
        S_DISP_12: swrite(fp + 32'd3, a1, S_DISP_JUMP);
        S_DISP_JUMP: begin set_pc(cont_to_pc(t2)); st <= S_RETIRE; end

        S_JUMP_1: begin
          if (!is_pc_type(wtype(opv))) err(E_UNARY_OPERAND_TYPE_PC, 32'd0);
          else begin
            if (opv[39]) cr[CR_CLEANUP_IN_PROGRESS] <= opv[38];
            set_pc(cont_to_pc(opv));
            st <= S_RETIRE;
          end
        end

        // logic-variable instructions: emulated by Lisp
        S_EXC_POP_1: begin a2 <= opv; pop(S_EXC_POP_1B); end
        S_EXC_POP_1B: exc(3'd2, pop_w, a2, '0);
        S_EXC_POP_2: exc(3'd1, opv, '0, '0);
