// Symbolics Ivory (I-machine) architectural definitions.  The C++ reference
// model (emu/ivory.h, emu/cpu.h) uses the same names and numbering.
//
// A word is 40 bits: cdr<39:38> type<37:32> data<31:0>.
package ivory_pkg;

  typedef logic [39:0] word_t;

  // Data types
  localparam logic [5:0] DTP_NULL = 6'o00, DTP_MONITOR_FORWARD = 6'o01, DTP_HEADER_P = 6'o02,
    DTP_HEADER_I = 6'o03, DTP_EXTERNAL_VALUE_CELL_POINTER = 6'o04, DTP_ONE_Q_FORWARD = 6'o05,
    DTP_HEADER_FORWARD = 6'o06, DTP_ELEMENT_FORWARD = 6'o07, DTP_FIXNUM = 6'o10,
    DTP_SMALL_RATIO = 6'o11, DTP_SINGLE_FLOAT = 6'o12, DTP_DOUBLE_FLOAT = 6'o13, DTP_BIGNUM = 6'o14,
    DTP_BIG_RATIO = 6'o15, DTP_COMPLEX = 6'o16, DTP_SPARE_NUMBER = 6'o17, DTP_INSTANCE = 6'o20,
    DTP_LIST_INSTANCE = 6'o21, DTP_ARRAY_INSTANCE = 6'o22, DTP_STRING_INSTANCE = 6'o23,
    DTP_NIL = 6'o24, DTP_LIST = 6'o25, DTP_ARRAY = 6'o26, DTP_STRING = 6'o27, DTP_SYMBOL = 6'o30,
    DTP_LOCATIVE = 6'o31, DTP_LEXICAL_CLOSURE = 6'o32, DTP_DYNAMIC_CLOSURE = 6'o33,
    DTP_COMPILED_FUNCTION = 6'o34, DTP_GENERIC_FUNCTION = 6'o35, DTP_SPARE_POINTER_1 = 6'o36,
    DTP_SPARE_POINTER_2 = 6'o37, DTP_PHYSICAL_ADDRESS = 6'o40, DTP_SPARE_IMMEDIATE_1 = 6'o41,
    DTP_BOUND_LOCATION = 6'o42, DTP_CHARACTER = 6'o43, DTP_LOGIC_VARIABLE = 6'o44,
    DTP_GC_FORWARD = 6'o45, DTP_EVEN_PC = 6'o46, DTP_ODD_PC = 6'o47,
    DTP_CALL_COMPILED_EVEN = 6'o50, DTP_CALL_COMPILED_ODD = 6'o51, DTP_CALL_INDIRECT = 6'o52,
    DTP_CALL_GENERIC = 6'o53, DTP_CALL_COMPILED_EVEN_PREFETCH = 6'o54,
    DTP_CALL_COMPILED_ODD_PREFETCH = 6'o55, DTP_CALL_INDIRECT_PREFETCH = 6'o56,
    DTP_CALL_GENERIC_PREFETCH = 6'o57, DTP_PACKED_INSTRUCTION_60 = 6'o60;

  localparam logic [1:0] CDR_NEXT = 2'd0, CDR_NIL = 2'd1, CDR_NORMAL = 2'd2;

  // Memory cycle types
  localparam logic [3:0] CYC_DATA_READ = 4'd0, CYC_DATA_WRITE = 4'd1, CYC_BIND_READ = 4'd2,
    CYC_BIND_WRITE = 4'd3, CYC_BIND_READ_NO_MONITOR = 4'd4, CYC_BIND_WRITE_NO_MONITOR = 4'd5,
    CYC_HEADER = 4'd6, CYC_STRUCTURE_OFFSET = 4'd7, CYC_SCAVENGE = 4'd8, CYC_CDR = 4'd9,
    CYC_GC_COPY = 4'd10, CYC_RAW = 4'd11, CYC_RAW_TRANSLATE = 4'd12, CYC_COUNT = 4'd13;

  // Control register
  localparam int CR_EXTRA_ARGUMENT = 8, CR_CALLER_FRAME_SIZE = 9, CR_APPLY = 17,
    CR_VALUE_DISPOSITION = 18, CR_CALL_STARTED = 22, CR_CLEANUP_IN_PROGRESS = 23,
    CR_TRAP_ON_EXIT = 24, CR_CLEANUP_BINDINGS = 25, CR_CLEANUP_CATCH = 26, CR_TRACE_PENDING = 27,
    CR_CALL_TRACE = 28, CR_INSTRUCTION_TRACE = 29, CR_TRAP_MODE = 30;

  localparam logic [1:0] VD_EFFECT = 2'd0, VD_VALUE = 2'd1, VD_RETURN = 2'd2, VD_MULTIPLE = 2'd3;
  localparam logic [1:0] TM_EMULATOR = 2'd0, TM_EXTRA_STACK = 2'd1, TM_IO = 2'd2, TM_FEP = 2'd3;

  // Trap vector offsets
  localparam logic [11:0] TV_ARITHMETIC = 12'o0000, TV_INSTRUCTION_EXCEPTION = 12'o4000,
    TV_INTERPRETER = 12'o4400, TV_GENERIC_DISPATCH = 12'o5000, TV_ERROR = 12'o5100,
    TV_RESET = 12'o5101, TV_PULL_APPLY_ARGS = 12'o5102, TV_STACK_OVERFLOW = 12'o5103,
    TV_TRACE = 12'o5104, TV_PREEMPT_REQUEST = 12'o5105, TV_TRANSPORT = 12'o5106,
    TV_FEP_MODE = 12'o5107, TV_LOW_PRIORITY_SB = 12'o5110, TV_HIGH_PRIORITY_SB = 12'o5111,
    TV_MONITOR = 12'o5112, TV_GENERIC_DISPATCH_TRAP = 12'o5114, TV_MESSAGE_DISPATCH_TRAP = 12'o5116,
    TV_PAGE_NOT_RESIDENT = 12'o5120, TV_PAGE_FAULT_REQUEST = 12'o5121,
    TV_PAGE_WRITE_FAULT = 12'o5122, TV_MEMORY_BUS_ERROR = 12'o5124;

  localparam logic [31:0] TRAP_VECTOR_BASE = 32'hF8040000, NIL_ADDRESS = 32'hF8041200,
    T_ADDRESS = 32'hF8041208, INIT_PC_VMA = 32'hFFFE0040;

  localparam word_t NIL_W = {2'b00, DTP_NIL, NIL_ADDRESS};
  localparam word_t T_W = {2'b00, DTP_SYMBOL, T_ADDRESS};

  // Error-trap conditions (emu/cpu.h ErrCond, same order)
  localparam logic [6:0] E_NONE                                   = 7'd0;
  localparam logic [6:0] E_ALLOCATE_TYPE                          = 7'd1;
  localparam logic [6:0] E_DIVIDE_BIGNUM_STEP                     = 7'd2;
  localparam logic [6:0] E_INSTANCE_REF_TYPE_BINARY               = 7'd3;
  localparam logic [6:0] E_INSTANCE_REF_TYPE_3                    = 7'd4;
  localparam logic [6:0] E_MEMORY_READ_TRANSPORT_FIXNUM           = 7'd5;
  localparam logic [6:0] E_P_DPB_TYPE                             = 7'd6;
  localparam logic [6:0] E_ALOC_NON_OBJECT_ARRAY                  = 7'd7;
  localparam logic [6:0] E_ARRAY_ACCESS_TYPE_BINARY               = 7'd8;
  localparam logic [6:0] E_ARRAY_ACCESS_TYPE_3                    = 7'd9;
  localparam logic [6:0] E_ARRAY_LEADER_TYPE_BINARY               = 7'd10;
  localparam logic [6:0] E_ARRAY_LEADER_TYPE_3                    = 7'd11;
  localparam logic [6:0] E_ARRAY_REGISTER_FORMAT                  = 7'd12;
  localparam logic [6:0] E_ARRAY_REGISTER_FORMAT_OR_BOUNDS        = 7'd13;
  localparam logic [6:0] E_ASSOC_ELEMENT_NOT_LIST                 = 7'd14;
  localparam logic [6:0] E_BAD_CDR_CODE                           = 7'd15;
  localparam logic [6:0] E_BINARY_ARITH_TYPE                      = 7'd16;
  localparam logic [6:0] E_BINARY_LEXENV_TYPE                     = 7'd17;
  localparam logic [6:0] E_BIND_LOCATIVE_TYPE                     = 7'd18;
  localparam logic [6:0] E_BINDING_STACK_OVERFLOW                 = 7'd19;
  localparam logic [6:0] E_BINDING_STACK_UNDERFLOW                = 7'd20;
  localparam logic [6:0] E_BLOCK_READ_BINARY_TRANSPORT_FIXNUM     = 7'd21;
  localparam logic [6:0] E_BLOCK_READ_TEST_TRANSPORT_FIXNUM       = 7'd22;
  localparam logic [6:0] E_BLOCK_READ_TRANSPORT_FIXNUM            = 7'd23;
  localparam logic [6:0] E_BRANCH_DOT                             = 7'd24;
  localparam logic [6:0] E_BYTE_ARRAY_WORD_TYPE                   = 7'd25;
  localparam logic [6:0] E_CAR_CDR_LIST_TYPE                      = 7'd26;
  localparam logic [6:0] E_CHAR_DPB_TYPE                          = 7'd27;
  localparam logic [6:0] E_CHAR_LDB_TYPE                          = 7'd28;
  localparam logic [6:0] E_CHARACTER_ARRAY_ASET_TYPE              = 7'd29;
  localparam logic [6:0] E_DIVIDE_BY_ZERO                         = 7'd30;
  localparam logic [6:0] E_DIVIDE_OVERFLOW                        = 7'd31;
  localparam logic [6:0] E_FAST_ARRAY_ACCESS_TYPE                 = 7'd32;
  localparam logic [6:0] E_FIXNUM_ARRAY_ASET_TYPE                 = 7'd33;
  localparam logic [6:0] E_FLAVOR_SEARCH_MASK_NOT_FIXNUM          = 7'd34;
  localparam logic [6:0] E_FLAVOR_SEARCH_TABLE_NOT_LOCATIVE       = 7'd35;
  localparam logic [6:0] E_FRAME_OVERFLOW                         = 7'd36;
  localparam logic [6:0] E_GENERIC_SEARCH_ENTRY_NOT_PC            = 7'd37;
  localparam logic [6:0] E_I_STAGE                                = 7'd38;
  localparam logic [6:0] E_ILLEGAL_FULL_WORD_INSTRUCTION          = 7'd39;
  localparam logic [6:0] E_ILLEGAL_INSTANCE_VARIABLE_INDEX        = 7'd40;
  localparam logic [6:0] E_INSTANCE_FLAVOR_TABLE_NOT_LOCATIVE     = 7'd41;
  localparam logic [6:0] E_INTERPRETER_TABLE_NOT_PC               = 7'd42;
  localparam logic [6:0] E_LIST_TAIL_NOT_LIST                     = 7'd43;
  localparam logic [6:0] E_MAPPING_TABLE_INDEX_BOUNDS             = 7'd44;
  localparam logic [6:0] E_MEMORY_DATA_ERROR                      = 7'd45;
  localparam logic [6:0] E_NON_16_BIT_CHARACTER                   = 7'd46;
  localparam logic [6:0] E_NON_8_BIT_CHARACTER                    = 7'd47;
  localparam logic [6:0] E_ONE_OPERAND_FIXNUM_TYPE                = 7'd48;
  localparam logic [6:0] E_ONE_OPERAND_LIST_TYPE                  = 7'd49;
  localparam logic [6:0] E_OPERAND_1_TYPE_LOCATIVE                = 7'd50;
  localparam logic [6:0] E_OPERAND_LOCATIVE_TYPE                  = 7'd51;
  localparam logic [6:0] E_RPLACA_RPLACD_LIST_TYPE                = 7'd52;
  localparam logic [6:0] E_SELF_MAPPING_TABLE_TYPE                = 7'd53;
  localparam logic [6:0] E_SELF_TYPE                              = 7'd54;
  localparam logic [6:0] E_SET_TO_CAR_CDR_LIST_TYPE               = 7'd55;
  localparam logic [6:0] E_SETUP_ARRAY_NOT_ARRAY                  = 7'd56;
  localparam logic [6:0] E_SHALLOW_BINDING_IN_DEEP                = 7'd57;
  localparam logic [6:0] E_STACK_BLT_TYPE                         = 7'd58;
  localparam logic [6:0] E_SUBSCRIPT_BOUNDS                       = 7'd59;
  localparam logic [6:0] E_TAKE_VALUES_TYPE                       = 7'd60;
  localparam logic [6:0] E_THREE_OPERAND_FIXNUM_TYPE              = 7'd61;
  localparam logic [6:0] E_TOO_FEW_ARGUMENTS                      = 7'd62;
  localparam logic [6:0] E_TOO_MANY_ARGUMENTS                     = 7'd63;
  localparam logic [6:0] E_TRAP_ON_EXIT                           = 7'd64;
  localparam logic [6:0] E_TWO_OPERAND_FIXNUM_TYPE                = 7'd65;
  localparam logic [6:0] E_UNARY_ARITH_TYPE                       = 7'd66;
  localparam logic [6:0] E_UNARY_LEXENV_TYPE                      = 7'd67;
  localparam logic [6:0] E_UNARY_OPERAND_TYPE_PC                  = 7'd68;
  localparam logic [6:0] E_UNKNOWN_INTERNAL_REGISTER              = 7'd69;
  localparam logic [6:0] E_COUNT                                  = 7'd70;

  function automatic logic [5:0] wtype(word_t w); return w[37:32]; endfunction
  function automatic logic [1:0] wcdr(word_t w); return w[39:38]; endfunction
  function automatic logic [31:0] wdata(word_t w); return w[31:0]; endfunction
  function automatic word_t mkw(logic [5:0] t, logic [31:0] d); return {2'b00, t, d}; endfunction
  function automatic word_t mkwc(logic [1:0] c, logic [5:0] t, logic [31:0] d);
    return {c, t, d};
  endfunction
  function automatic word_t setcdr(word_t w, logic [1:0] c); return {c, w[37:0]}; endfunction
  function automatic word_t stripcdr(word_t w); return {2'b00, w[37:0]}; endfunction
  function automatic word_t setdata(word_t w, logic [31:0] d); return {w[39:32], d}; endfunction
  function automatic word_t fixnum(logic [31:0] d); return {2'b00, DTP_FIXNUM, d}; endfunction
  function automatic word_t boolw(logic b); return b ? T_W : NIL_W; endfunction
  function automatic logic is_fixnum(word_t w); return w[37:32] == DTP_FIXNUM; endfunction
  function automatic logic fix2(word_t a, word_t b);
    return a[37:32] == DTP_FIXNUM && b[37:32] == DTP_FIXNUM;
  endfunction
  function automatic logic is_numeric_type(logic [5:0] t);
    return t >= DTP_FIXNUM && t <= DTP_SPARE_NUMBER;
  endfunction
  function automatic logic is_pc_type(logic [5:0] t);
    return t == DTP_EVEN_PC || t == DTP_ODD_PC;
  endfunction
  function automatic logic is_instance_type(logic [5:0] t);
    return t >= DTP_INSTANCE && t <= DTP_STRING_INSTANCE;
  endfunction
  // Unboxed numbers that the hardware never compares by value
  function automatic logic is_boxed_number(logic [5:0] t);
    return t == DTP_DOUBLE_FLOAT || t == DTP_BIGNUM || t == DTP_BIG_RATIO || t == DTP_COMPLEX ||
           t == DTP_SPARE_NUMBER;
  endfunction

  // Pointer data types (spec 1.1.4)
  function automatic logic is_pointer_type(logic [5:0] t);
    case (t)
      DTP_HEADER_I, DTP_FIXNUM, DTP_SMALL_RATIO, DTP_SINGLE_FLOAT, DTP_PHYSICAL_ADDRESS,
      DTP_SPARE_IMMEDIATE_1, DTP_CHARACTER: return 1'b0;
      default: return t < DTP_PACKED_INSTRUCTION_60;
    endcase
  endfunction

  // PC (halfword address) from an even/odd PC word
  function automatic logic [32:0] cont_to_pc(word_t c);
    return {c[31:0], c[37:32] == DTP_ODD_PC};
  endfunction
  function automatic word_t pc_word(logic [32:0] p);
    return mkw(p[0] ? DTP_ODD_PC : DTP_EVEN_PC, p[32:1]);
  endfunction

  // Memory-cycle actions (spec Table 13): columns are
  // data null header hfwd efwd 1fwd evcp gc monitor, plus "pointer transports",
  // and the logic-variable column Table 13 predates: a data-read or
  // raw-translate of a dtp-logic-variable word returns it as an EVCP, cdr
  // code kept (A_XFRM; the Symbolics table in the VLM's memoryem.lisp)
  localparam logic [2:0] A_NONE = 3'd0, A_IND = 3'd1, A_TRAP = 3'd2, A_MTRAP = 3'd3, A_XFRM = 3'd4;

  function automatic logic [3:0] action_column(logic [5:0] t);
    case (t)
      DTP_NULL: return 4'd1;
      DTP_HEADER_P, DTP_HEADER_I: return 4'd2;
      DTP_HEADER_FORWARD: return 4'd3;
      DTP_ELEMENT_FORWARD: return 4'd4;
      DTP_ONE_Q_FORWARD: return 4'd5;
      DTP_EXTERNAL_VALUE_CELL_POINTER: return 4'd6;
      DTP_GC_FORWARD: return 4'd7;
      DTP_MONITOR_FORWARD: return 4'd8;
      DTP_LOGIC_VARIABLE: return 4'd9;
      default: return 4'd0;
    endcase
  endfunction

  function automatic logic [2:0] cycle_action(logic [3:0] cycle, logic [3:0] col);
    logic [29:0] row;   // 10 columns x 3 bits, column 0 in the low bits
    case (cycle)
      CYC_DATA_READ:  row = {A_XFRM, A_MTRAP, A_TRAP, A_IND, A_IND, A_IND, A_IND, A_TRAP, A_TRAP, A_NONE};
      CYC_DATA_WRITE: row = {A_NONE, A_MTRAP, A_TRAP, A_IND, A_IND, A_IND, A_IND, A_TRAP, A_NONE, A_NONE};
      CYC_BIND_READ:  row = {A_NONE, A_MTRAP, A_TRAP, A_NONE, A_IND, A_IND, A_IND, A_TRAP, A_NONE, A_NONE};
      CYC_BIND_WRITE: row = {A_NONE, A_MTRAP, A_TRAP, A_NONE, A_IND, A_IND, A_IND, A_TRAP, A_NONE, A_NONE};
      CYC_BIND_READ_NO_MONITOR, CYC_BIND_WRITE_NO_MONITOR:
                      row = {A_NONE, A_IND, A_TRAP, A_NONE, A_IND, A_IND, A_IND, A_TRAP, A_NONE, A_NONE};
      CYC_HEADER:     row = {A_TRAP, A_TRAP, A_TRAP, A_TRAP, A_TRAP, A_TRAP, A_IND, A_NONE, A_TRAP, A_TRAP};
      CYC_STRUCTURE_OFFSET:
                      row = {A_NONE, A_NONE, A_TRAP, A_NONE, A_NONE, A_NONE, A_IND, A_NONE, A_NONE, A_NONE};
      CYC_SCAVENGE, CYC_GC_COPY:
                      row = {A_NONE, A_NONE, A_TRAP, A_NONE, A_NONE, A_NONE, A_NONE, A_NONE, A_NONE, A_NONE};
      CYC_CDR:        row = {A_NONE, A_NONE, A_TRAP, A_NONE, A_NONE, A_IND, A_IND, A_TRAP, A_NONE, A_NONE};
      CYC_RAW_TRANSLATE:
                      row = {A_XFRM, 27'd0};
      default:        row = '0;
    endcase
    return row[col*3 +: 3];
  endfunction

  // Table 13's last column: cycle types whose pointer data is checked for
  // oldspace (the transport trap)
  function automatic logic cycle_transport(logic [3:0] cycle);
    return cycle == CYC_DATA_READ || cycle == CYC_BIND_READ || cycle == CYC_BIND_READ_NO_MONITOR ||
           cycle == CYC_HEADER || cycle == CYC_SCAVENGE;
  endfunction

  // PHT hash box (spec 2.3.2): %read-internal-register PHT-HASH and the MMU's
  // first probe.  The result is a word offset (bucket number << 3).
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

endpackage
