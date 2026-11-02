// Ivory processor: first step of each half-word instruction (exec_op).
// Included inside the S_EXEC state of ivory_cpu_states.svh.

          case (op)
            // lists
            8'o000, 8'o001: opval(1'b1, S_CAR_1);                     // car, cdr
            8'o140, 8'o141, 8'o142: begin                             // set-to-car/cdr, set-to-cdr-push-car
              if (omode == 2'd3) err(E_I_STAGE, inst_pc[32:1]);
              else begin
                addr <= oaddr;
                sread(oaddr, op == 8'o142 ? S_STCPC_1 : S_STC_1);
              end
            end
            8'o200, 8'o201: opval(1'b1, S_RPL_1);                     // rplaca, rplacd
            8'o225, 8'o226, 8'o227: opval(1'b1, S_MEM_1);             // rgetf, member, assoc

            // predicates
            8'o270, 8'o274, 8'o263, 8'o267: opval(1'b1, S_EQ_1);      // eq, eql
            8'o260, 8'o264, 8'o261, 8'o265, 8'o262, 8'o266,
            8'o273, 8'o277: opval(1'b1, S_NUMCMP_1);                  // =, <, >, logtest
            8'o040, 8'o041, 8'o042, 8'o043, 8'o044, 8'o045, 8'o046, 8'o047:
              read_tos(S_TYPEMEM_1);                                 // type-member-n
            8'o002: opval(1'b1, S_ENDP_1);
            8'o034, 8'o035, 8'o036: opval(1'b1, S_ZEROP_1);           // zerop, minusp, plusp

            // numeric
            8'o300, 8'o301, 8'o202, 8'o203, 8'o204, 8'o205, 8'o206, 8'o207,
            8'o210, 8'o211, 8'o212, 8'o213, 8'o215, 8'o216, 8'o217, 8'o232: begin
              // both operands at hand: the top of the stack popped and the
              // operand (an immediate or the pre-read) into a2, to S_ARITH_2
              if (tos_ok && omode == 2'd3) begin
                a2 <= fixnum(!(op == 8'o300 || op == 8'o301) ? {{24{ooff[7]}}, ooff} : {24'd0, ooff});
                pop_now();
                st <= S_ARITH_2;
              end else if (tos_ok && opv_pre && !(omode == 2'd2 && ooff == 8'd0)) begin
                a2 <= sc_q;
                pop_now();
                st <= S_ARITH_2;
              end else opval(!(op == 8'o300 || op == 8'o301), S_ARITH_1);
            end
            8'o114: opval(1'b0, S_UMINUS_1);
            8'o143, 8'o144: begin                                     // increment, decrement
              if (omode == 2'd3) err(E_I_STAGE, inst_pc[32:1]);
              else begin addr <= oaddr; sread(oaddr, S_INC_1); end
            end
            8'o220, 8'o221: opval(1'b1, S_SHIFT_1);                   // rot, lsh
            8'o302, 8'o303: opval(1'b0, S_32BIT_1);                   // %32-bit-plus/difference
            8'o222: opval(1'b1, S_MULD_1);                            // %multiply-double
            8'o304, 8'o305, 8'o307: opval(1'b0, S_BIG3_1);            // bignum steps, 3 args
            8'o223: opval(1'b1, S_BIG3_1);                            // %lshc-bignum-step
            8'o306: opval(1'b0, S_MULD_1);                            // %multiply-bignum-step
            8'o016: opval(1'b0, S_DFLOAT_1);                          // %double-float-op

            // data movement
            8'o100: begin                                             // push
              if (omode == 2'd3) push_now(fixnum({24'd0, ooff}), S_RETIRE);
              else if (opv_pre && !(omode == 2'd2 && ooff == 8'd0)) push_now(sc_q, S_RETIRE);
              else opval(1'b0, S_PUSHI_1);
            end
            8'o340: begin                                             // pop
              if (omode == 2'd3) err(E_I_STAGE, inst_pc[32:1]);
              else begin addr <= oaddr; pop(S_POPI_1); end
            end
            8'o341: begin                                             // movem
              if (omode == 2'd3) err(E_I_STAGE, inst_pc[32:1]);
              else begin addr <= oaddr; read_tos(S_MOVEM_1); end
            end
            8'o101: opval(1'b0, S_PUSHNIL_1);                         // push-n-nils
            8'o150: begin                                             // push-address
              if (omode == 2'd3) err(E_I_STAGE, inst_pc[32:1]);
              else push(mkw(DTP_LOCATIVE, oaddr), S_RETIRE);
            end
            8'o151: begin                                             // set-sp-to-address
              if (omode == 2'd3) err(E_I_STAGE, inst_pc[32:1]);
              else begin sp <= oaddr; st <= S_RETIRE; end
            end
            8'o152: begin                                             // set-sp-to-address-save-tos
              if (omode == 2'd3) err(E_I_STAGE, inst_pc[32:1]);
              else begin addr <= oaddr; read_tos(S_SSTS_1); end
            end
            8'o102: begin                                             // push-address-sp-relative
              x0 <= sp;
              opval(1'b0, S_PASR_1);
            end
            8'o224: opval(1'b1, S_BLT_1);                             // stack-blt
            8'o352: begin                                             // stack-blt-address
              if (omode == 2'd3) err(E_I_STAGE, inst_pc[32:1]);
              else begin x0 <= oaddr; pop(S_BLT_2); end
            end

            // field extraction
            8'o170, 8'o171, 8'o172, 8'o173: begin                     // ldb, char-ldb, %p-ldb, %p-tag-ldb
              rot_n <= operand[4:0]; msk_n <= {1'b0, operand[9:5]} + 6'd1;
              pop(op[1] ? S_PLDB_1 : S_LDB_1);
            end
            8'o370, 8'o371, 8'o372, 8'o373: begin                     // dpb, char-dpb, %p-dpb, %p-tag-dpb
              rot_n <= operand[4:0];
              msk_n <= {1'b0, operand[4:0]} + {1'b0, operand[9:5]} + 6'd1;   // bits pos .. pos+size
              msk2_n <= {1'b0, operand[4:0]};
              pop(op[1] ? S_PDPB_1 : S_DPB_1);
            end

            // arrays
            8'o312, 8'o313, 8'o310: opval(1'b0, S_AREF_1);            // aref-1, aloc-1, aset-1
            8'o003, 8'o004: opval(1'b1, S_SETUP_1);                   // setup-1d-array, -force-
            8'o350, 8'o351: begin                                     // fast-aref-1, fast-aset-1
              if (omode == 2'd3) err(E_I_STAGE, inst_pc[32:1]);
              else begin addr <= oaddr; pop(S_FAST_1); end
            end
            8'o316, 8'o317, 8'o314: opval(1'b0, S_LEADER_1);          // array-leader etc.

            // branches
            8'o174: begin branch(operand); st <= S_RETIRE; end        // branch
            8'o060, 8'o061, 8'o062, 8'o063, 8'o064, 8'o065, 8'o066, 8'o067,
            8'o070, 8'o071, 8'o072, 8'o073, 8'o074, 8'o075, 8'o076, 8'o077:
              if (tos_ok) brc(tos_q); else read_tos(S_BRC_1);
            8'o175: read_tos(S_LOOPDEC_1);                           // loop-decrement-tos
            8'o375: read_tos(S_LOOPINC_1);                           // loop-increment-tos-less-than

            // blocks
            8'o120, 8'o121, 8'o122, 8'o123, 8'o124, 8'o125, 8'o126, 8'o127,
            8'o130, 8'o131, 8'o132, 8'o133: begin
              rot_n <= alu_control[4:0]; msk2_n <= 6'd31 - {1'b0, alu_control[9:5]};
              mrd(bar[op[1:0]], operand[9:6] >= CYC_COUNT ? CYC_RAW : operand[9:6], S_BLK_1);
            end
            8'o160, 8'o161, 8'o162, 8'o163: begin                     // %block-n-read-alu
              if (omode == 2'd3) err(E_I_STAGE, inst_pc[32:1]);
              else begin addr <= oaddr; sread(oaddr, S_BLKALU_1); end
            end
            8'o030, 8'o031, 8'o032, 8'o033: opval(1'b1, S_BLKW_1);    // %block-n-write

            // function calling
            8'o010: opval(1'b1, S_STARTCALL_1);                       // start-call
            8'o134, 8'o135: begin                                     // finish-call-n(-apply)
              x0 <= {24'd0, operand[7:0]};
              st <= S_FC_1;
            end
            8'o136, 8'o137: pop(S_FC_2);                              // finish-call-tos(-apply)
            8'o050: begin                                             // locate-locals
              x0 <= sp;
              push(fixnum({24'd0, cr[7:0]} - 32'd2), S_LOCLOC_1);
            end
            8'o115: begin                                             // return-single
              ret_kind <= 2'd0;
              ret_arg <= operand;
              ret_sppop <= 1'b0;
              st <= S_RET;
            end
            8'o104, 8'o105: begin                                     // return-multiple, -kludge
              ret_sppop <= omode == 2'd2 && ooff == 8'd0;
              opval(1'b0, S_RETM_1);
            end
            8'o106: opval(1'b0, S_TAKEV_1);                           // take-values

            // binding
            8'o236: opval(1'b1, S_BIND_1);                            // bind-locative-to-value
            8'o005: opval(1'b1, S_BIND_2);                            // bind-locative
            8'o107: opval(1'b0, S_UNBINDN_1);                         // unbind-n
            8'o006: opval(1'b1, S_RESTB_1);                           // %restore-binding-stack

            // catch
            8'o376: begin                                             // catch-open
              x0 <= sp;
              push_raw(mkwc({1'b0, operand[0]}, wtype(irw[IRW_BSP]), irw[IRW_BSP][31:0]), S_CATCHO_1);
            end
            8'o051: begin                                             // catch-close
              from_return <= 1'b0;
              call(S_CATCHC, S_RETIRE);
            end

            // lexical variables
            8'o020, 8'o021, 8'o022, 8'o023, 8'o024, 8'o025, 8'o026, 8'o027:
              opval(1'b1, S_LEX_1);
            8'o240, 8'o241, 8'o242, 8'o243, 8'o244, 8'o245, 8'o246, 8'o247,
            8'o250, 8'o251, 8'o252, 8'o253, 8'o254, 8'o255, 8'o256, 8'o257:
              opval(1'b1, S_LEXW_1);

            // instance variables: the index is the operand field's low eight
            // bits whatever the mode bits say (the VLM's :10-bit-immediate
            // format takes the "truncated 8 bit" operand, one entry for all
            // modes); CLOS puts other values in the mode bits, which decoded
            // as an FP-relative operand sent self's address as the index
            8'o110, 8'o320, 8'o321, 8'o111: begin x0 <= {24'd0, operand[7:0]}; sread(fp + 32'd2, S_IVM_2); end   // mapped
            8'o112, 8'o322, 8'o323, 8'o113: begin x0 <= {24'd0, operand[7:0]}; sread(fp + 32'd3, S_IVU_2); end   // unmapped
            8'o324, 8'o325, 8'o326: opval(1'b0, S_IREF_1);            // %instance-ref/set/loc

            // subprimitives
            8'o007: opval(1'b1, S_EPHP_1);                            // %ephemeralp
            8'o331, 8'o335: opval(1'b0, S_ULESS_1);                   // %unsigned-lessp
            8'o214: opval(1'b1, S_ALU_1);                             // %alu
            8'o311, 8'o315: opval(1'b0, S_ALLOC_1);                   // %allocate-list/structure-block
            8'o230, 8'o231: opval(1'b1, S_PPLUS_1);                   // %pointer-plus/difference
            8'o145: begin                                             // %pointer-increment
              if (omode == 2'd3) err(E_I_STAGE, inst_pc[32:1]);
              else begin addr <= oaddr; sread(oaddr, S_PINC_1); end
            end
            8'o154: st <= S_RIR_1;                                    // %read-internal-register
            8'o155: pop(S_WIR_1);                                     // %write-internal-register
            8'o156: begin                                             // %coprocessor-read
              cop_req <= 1'b1; cop_we <= 1'b0; cop_reg <= operand;
              st <= S_COPR_1;
            end
            8'o157: pop(S_COPW_1);                                    // %coprocessor-write
            8'o116, 8'o117: pop(S_MRDI_1);                            // %memory-read(-address)
            8'o012: opval(1'b1, S_TAG_1);                             // %tag
            8'o327: opval(1'b0, S_SETTAG_1);                          // %set-tag
            8'o233: opval(1'b1, S_STORC_1);                           // store-conditional
            8'o234: opval(1'b1, S_MWRI_1);                            // %memory-write
            8'o235: opval(1'b1, S_PSTORE_1);                          // %p-store-contents
            8'o146, 8'o147: begin                                     // %set-cdr-code-1/2
              if (omode == 2'd3) err(E_I_STAGE, inst_pc[32:1]);
              else begin addr <= oaddr; sread(oaddr, S_SETCDR_1); end
            end
            8'o342: begin                                             // %merge-cdr-no-pop
              if (omode == 2'd3) err(E_I_STAGE, inst_pc[32:1]);
              else begin addr <= oaddr; read_tos(S_MERGE_1); end
            end
            8'o052, 8'o053: begin                                     // %generic/%message-dispatch
              if (cr[7:0] < 8'd4) begin
                if (cr[CR_APPLY]) begin
                  restart_sp <= sp;
                  pull_n <= 32'd4 - {24'd0, cr[7:0]};
                  call(S_PULL, S_DISP_RETRY);
                end else err(E_TOO_FEW_ARGUMENTS, 32'd0);
              end else sread(fp + (op == 8'o052 ? 32'd2 : 32'd3), S_DISP_1);
            end
            8'o011: opval(1'b1, S_JUMP_1);                            // %jump
            8'o054: begin                                             // %check-preempt-request
              if (preempt_register[1]) preempt_register[0] <= 1'b1;
              st <= S_RETIRE;
            end
            8'o056: st <= S_RETIRE;                                   // no-op
            8'o057, 8'o015: exc(3'd0, '0, '0, '0);                    // %halt, %proc-breakpoint

            // logic variables (Joshua)
            8'o013: opval(1'b1, S_DEREF_1);                           // dereference
            8'o103: opval(1'b0, S_PLLV_1);                            // push-local-logic-variables
            8'o055: push(mkw(DTP_EXTERNAL_VALUE_CELL_POINTER, bar[2][31:0]), S_PGLV_1);   // push-global-logic-variable
            8'o014: opval(1'b1, S_LTT_1);                             // logic-tail-test
            8'o237: opval(1'b1, S_EXC_POP_1);                         // unify

            default: exc(3'd0, '0, '0, '0);
          endcase
