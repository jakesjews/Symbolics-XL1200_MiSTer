// Arithmetic of the WTL3164 model (rtl/xl/xl_fpa.sv): the results of the C++
// in emu/fpa.cpp (sim/fpa checks every bit, flag and status code against
// it), at the latencies of Genera's XL1200 table (xl_fpa's decode).  An
// operation is taken with its operands in cycle t (start); its result comes
// out in cycle t + lat - 1 (done) and is readable from t + lat.
//
// Cycle t registers the operands and what comes straight from them: the
// add's exponent difference, the multiplier's significands, an integer's
// magnitude and leading zeros, a conversion's shift.  Then
//   add, subtract   S_ADD (unpack, align, add)                    S_FINAL
//   multiply        S_MUL (unpack, the 53 x 53 product)           S_FINAL
//   divide          S_UNPACK, S_DIV (two bits a cycle), S_DIVF    S_FINAL
//   square root     S_UNPACK, S_SQRT (a bit a cycle), S_SQRTF     S_FINAL
//   the rest        S_UNPACK                                      S_FINAL
// with S_HOLD waiting out the latency before S_FINAL where the work is
// quicker.  S_FINAL rounds: a difference that cancelled two or more leading
// bits is exact and is only shifted into place (the near path); every other
// result moves at most one bit and is rounded (the far path).
package xl_fpa_pkg;
  typedef enum logic [4:0] {
    F_ADD, F_SUB, F_MUL, F_DIV, F_SQRT, F_EQ, F_LT, F_GT, F_ZEROP, F_MINUSP, F_PLUSP, F_NEG, F_ABS,
    F_I2D, F_I2S, F_D2S, F_S2D, F_D2I, F_S2I, F_IMUL
  } fop_t;
  // Exception flags (status registers 2 and 3)
  localparam logic [7:0] FL_IOV = 8'h01, FL_NX = 8'h02, FL_UNF = 8'h04, FL_OVF = 8'h08,
    FL_DEN = 8'h10, FL_DVZ = 8'h20, FL_INV = 8'h40, FL_NAN = 8'h80;
endpackage

module xl_fpa_unit (
  input  logic              clk,
  input  logic              reset,
  input  logic              start,
  input  xl_fpa_pkg::fop_t  op,
  input  logic              dbl,       // double precision (the result's format for conversions)
  input  logic [1:0]        mode,      // 0 nearest, 1 zero, 2 plus, 3 minus
  input  logic              trunc,     // conversions: round to zero
  input  logic              unf_round, // SR2 UNF CONTROL: underflows come back rounded
  input  logic              dnrm_exc,  // SR2 DNRM CONTROL: denormalized operands raise their flag
  input  logic [63:0]       x, y,
  input  logic [5:0]        lat,       // cycles from start until the result is readable (3 or more)
  output logic              busy,      // from the cycle after start through done
  output logic              done,      // the result, this cycle
  output logic [63:0]       bits,
  output logic [7:0]        flags,
  output logic [3:0]        status
);
  import xl_fpa_pkg::*;

  localparam logic [2:0] C_ZERO = 3'd0, C_NORM = 3'd1, C_INF = 3'd2, C_NAN = 3'd3, C_DEN = 3'd4;
  // value = m * 2^(e-62); a NORM has its leading one at bit 62
  typedef struct packed { logic s; logic [2:0] c; logic signed [13:0] e; logic [63:0] m; } unp_t;
  typedef struct packed { logic [63:0] bits; logic [7:0] flags; logic [3:0] status; } res_t;

  function automatic unp_t unpack(logic d, logic [63:0] b);
    unp_t u;
    u = '0;
    if (d) begin
      u.s = b[63];
      if (b[62:52] == 11'h7FF) u.c = b[51:0] != 52'd0 ? C_NAN : C_INF;
      else if (b[62:52] == 11'd0) u.c = b[51:0] != 52'd0 ? C_DEN : C_ZERO;
      else begin
        u.c = C_NORM;
        u.e = $signed({3'd0, b[62:52]}) - 14'sd1023;
        u.m = {2'b01, b[51:0], 10'd0};
      end
    end else begin
      u.s = b[31];
      if (b[30:23] == 8'hFF) u.c = b[22:0] != 23'd0 ? C_NAN : C_INF;
      else if (b[30:23] == 8'd0) u.c = b[22:0] != 23'd0 ? C_DEN : C_ZERO;
      else begin
        u.c = C_NORM;
        u.e = $signed({6'd0, b[30:23]}) - 14'sd127;
        u.m = {2'b01, b[22:0], 39'd0};
      end
    end
    return u;
  endfunction

  function automatic logic [63:0] pack(logic d, logic s, logic [10:0] e, logic [51:0] f);
    return d ? {s, e, f} : {32'd0, s, e[7:0], f[22:0]};
  endfunction
  function automatic logic [63:0] zero_v(logic d, logic s); return pack(d, s, 11'd0, 52'd0); endfunction
  function automatic logic [63:0] inf_v(logic d, logic s);
    return pack(d, s, d ? 11'h7FF : 11'hFF, 52'd0);
  endfunction
  function automatic logic [63:0] nan_v(logic d);
    return pack(d, 1'b0, d ? 11'h7FF : 11'hFF, {52{1'b1}});
  endfunction
  function automatic logic [3:0] base(logic d); return d ? 4'd8 : 4'd0; endfunction
  function automatic logic [63:0] sign_bit(logic d);
    return d ? 64'h8000_0000_0000_0000 : 64'h8000_0000;
  endfunction

  // round_pack in emu/fpa.cpp
  function automatic res_t round_pack(logic d, logic s, logic signed [13:0] e, logic [63:0] m,
                                      logic sticky, logic [1:0] md, logic unfr);
    res_t r;
    logic [52:0] q;
    logic [53:0] qr;
    logic g, rest, inexact, up, carry;
    logic signed [13:0] E, Er;
    if (d) begin q = m[62:10]; g = m[9]; rest = m[8:0] != 9'd0; end
    else begin q = {29'd0, m[62:39]}; g = m[38]; rest = m[37:0] != 38'd0; end
    rest = rest | sticky;
    inexact = g | rest;
    case (md)
      2'd0: up = g & (rest | q[0]);
      2'd2: up = inexact & !s;
      2'd3: up = inexact & s;
      default: up = 1'b0;
    endcase
    E = e + (d ? 14'sd1023 : 14'sd127);
    qr = {1'b0, q} + {53'd0, up};
    carry = d ? qr[53] : qr[24];
    Er = carry ? E + 14'sd1 : E;
    if (Er < 14'sd1) begin
      r.bits = unfr ? pack(d, s, Er[10:0], qr[51:0]) : pack(d, s, E[10:0], q[51:0]);
      r.flags = FL_UNF | (inexact ? FL_NX : 8'd0);
      r.status = base(d) + (inexact ? 4'd3 : 4'd2);
    end else if (Er > (d ? 14'sd2046 : 14'sd254)) begin
      r.bits = (md == 2'd0 || (md == 2'd2 && !s) || (md == 2'd3 && s)) ? inf_v(d, s)
             : pack(d, s, d ? 11'd2046 : 11'd254, {52{1'b1}});
      r.flags = FL_OVF | FL_NX;
      r.status = base(d) + 4'd4;
    end else begin
      r.bits = pack(d, s, Er[10:0], qr[51:0]);
      r.flags = inexact ? FL_NX : 8'd0;
      r.status = base(d) + {3'd0, inexact};
    end
    return r;
  endfunction

  // {a<b, a>b} for ordered operands; zeros of either sign are equal
  function automatic logic [1:0] compare(unp_t a, unp_t b);
    logic lt, gt;
    if (a.c == C_ZERO && b.c == C_ZERO) return 2'b00;
    if (a.c == C_ZERO) return b.s ? 2'b01 : 2'b10;
    if (b.c == C_ZERO) return a.s ? 2'b10 : 2'b01;
    if (a.s != b.s) return a.s ? 2'b10 : 2'b01;
    if (a.c == C_INF || b.c == C_INF) begin
      lt = b.c == C_INF && a.c != C_INF;
      gt = a.c == C_INF && b.c != C_INF;
    end else begin
      lt = $signed(a.e) < $signed(b.e) || (a.e == b.e && a.m < b.m);
      gt = $signed(a.e) > $signed(b.e) || (a.e == b.e && a.m > b.m);
    end
    return a.s ? {gt, lt} : {lt, gt};
  endfunction

  function automatic logic [6:0] lzc(logic [63:0] v);
    logic [6:0] n;
    n = 7'd64;
    for (int i = 0; i < 64; i++) if (v[i]) n = 7'(63 - i);
    return n;
  endfunction
  function automatic logic [5:0] lzc32(logic [31:0] v);
    logic [5:0] n;
    n = 6'd32;
    for (int i = 0; i < 32; i++) if (v[i]) n = 6'(31 - i);
    return n;
  endfunction

  typedef enum logic [3:0] {
    S_IDLE, S_ADD, S_MUL, S_UNPACK, S_DIV, S_DIVF, S_SQRT, S_SQRTF, S_HOLD, S_FINAL
  } st_t;
  st_t st;
  // what S_FINAL puts out: a result made earlier (m_r, sp_flags, sp_status),
  // a significand to round (m_r, e_r, s_r, sticky_r), a fixnum product
  localparam logic [1:0] K_SPEC = 2'd0, K_ARITH = 2'd1, K_IMUL = 2'd2;
  logic [1:0]  kind;
  logic [5:0]  lat_cnt;     // S_FINAL comes in the cycle this reaches 0

  fop_t        op_r;
  logic        d_r, src_d, s_r, sticky_r, unfr_r, dexc_r;
  logic [1:0]  md_r;
  logic [63:0] x_r, y_r, m_r, bm;
  logic signed [13:0] e_r, sh_r;
  logic signed [11:0] diff_r, ndiff_r;
  logic [7:0]  fl, sp_flags;
  logic [3:0]  sp_status;
  logic [52:0] mul_a, mul_b;
  logic [5:0]  nz_r, cnt;
  logic [64:0] rr;
  logic [55:0] q_r;
  logic [67:0] rem;
  logic [65:0] rad;

  assign busy = st != S_IDLE;
  assign done = st == S_FINAL;

  // ---------------------------------------------------------------- cycle t
  logic [11:0] ex0, ey0;
  logic [31:0] yabs0;
  always_comb begin
    ex0 = dbl ? {1'b0, x[62:52]} : {4'd0, x[30:23]};
    ey0 = dbl ? {1'b0, y[62:52]} : {4'd0, y[30:23]};
    yabs0 = y[31] ? -y[31:0] : y[31:0];
  end

  // ---------------------------------------------------------------- the operands unpacked
  // From the registered operands in the first state after t.  One 64-bit
  // right shifter and mask serve the add's alignment (S_ADD) and the
  // integer conversions (S_UNPACK); one left shifter the integer's
  // normalization (S_UNPACK) and the near path (S_FINAL).
  unp_t        a_c, b_c, a_f, b_f, big_c, small_c;
  logic [7:0]  f_c;
  logic        unary_c, swap_c;
  logic [11:0] span_c;
  logic [63:0] shr_in, shr_out, shr_low, shl_in, shl_out;
  logic [5:0]  shr_n, shl_n;
  logic [6:0]  lz_m;
  always_comb begin
    unary_c = op_r == F_SQRT || op_r == F_ZEROP || op_r == F_MINUSP || op_r == F_PLUSP ||
              op_r == F_NEG || op_r == F_ABS || op_r >= F_I2D;
    a_c = unpack(src_d, unary_c ? y_r : x_r);
    b_c = op_r == F_ZEROP || op_r == F_MINUSP || op_r == F_PLUSP ? '0
        : unpack(src_d, op_r == F_SUB ? y_r ^ sign_bit(src_d) : y_r);
    // denormalized operands count as zero (raising the flag with DNRM CONTROL)
    a_f = a_c; b_f = b_c; f_c = '0;
    if (op_r != F_I2D && op_r != F_I2S && op_r != F_IMUL) begin   // float operands
      if (a_c.c == C_DEN) begin a_f.c = C_ZERO; f_c = dexc_r ? FL_DEN : 8'd0; end
      if (b_c.c == C_DEN) begin b_f.c = C_ZERO; f_c = dexc_r ? FL_DEN : 8'd0; end
    end
    swap_c = diff_r < 12'sd0;
    span_c = swap_c ? ndiff_r : diff_r;
    big_c = swap_c ? b_c : a_c;
    small_c = swap_c ? a_c : b_c;
    shr_in = st == S_ADD ? small_c.m : a_c.m;
    shr_n = st == S_ADD ? span_c[5:0] : sh_r[5:0];
    shr_out = shr_in >> shr_n;
    shr_low = ~({64{1'b1}} << shr_n);   // the bits shifted out
    lz_m = lzc(m_r);
    shl_in = st == S_UNPACK ? {11'd0, mul_b} : m_r;
    shl_n = st == S_UNPACK ? nz_r : 6'(lz_m - 7'd1);
    shl_out = shl_in << shl_n;
  end

  logic [105:0] prod;
  assign prod = mul_a * mul_b;

  // ---------------------------------------------------------------- S_FINAL
  res_t fin_c;
  always_comb begin
    logic [63:0] fm, iv;
    logic signed [13:0] fe, ne, nE;
    logic fs, iovf, unf;
    res_t r;
    // far: the leading one at bit 63, 62 or 61, to 62
    if (m_r[63]) begin fm = m_r >> 1; fs = sticky_r | m_r[0]; fe = e_r + 14'sd1; end
    else if (m_r[62]) begin fm = m_r; fs = sticky_r; fe = e_r; end
    else begin fm = m_r << 1; fs = sticky_r; fe = e_r - 14'sd1; end
    r = round_pack(d_r, s_r, fe, fm, fs, md_r, unfr_r);
    if (op_r == F_D2S) begin
      if (r.status == 4'd4) r.status = 4'd13;
      else if (r.status == 4'd2 || r.status == 4'd3) r.status = 4'd14;
    end
    r.flags = fl | r.flags;
    // near: an exact difference with its leading one below bit 61
    if (m_r[63:61] == 3'd0) begin
      ne = e_r - $signed({7'd0, lz_m}) + 14'sd1;
      nE = ne + (d_r ? 14'sd1023 : 14'sd127);
      unf = nE < 14'sd1;
      r.bits = pack(d_r, s_r, nE[10:0], d_r ? shl_out[61:10] : {29'd0, shl_out[61:39]});
      r.flags = fl | (unf ? FL_UNF : 8'd0);
      r.status = base(d_r) + (unf ? 4'd2 : 4'd0);
    end
    // the fixnum product's magnitude in m_r, its sign in s_r
    iv = {32'd0, s_r ? -m_r[31:0] : m_r[31:0]};
    iovf = m_r[63:32] != 32'd0 || (m_r[31] && (!s_r || m_r[30:0] != 31'd0));
    case (kind)
      K_SPEC: fin_c = '{m_r, sp_flags, sp_status};
      K_IMUL: fin_c = '{iv, iovf ? FL_IOV : 8'd0, iovf ? 4'd15 : 4'd0};
      default: fin_c = r;
    endcase
  end
  assign bits = fin_c.bits;
  assign flags = fin_c.flags;
  assign status = fin_c.status;

  // ---------------------------------------------------------------- the states
  // A result made already (S_FINAL puts it out as it is), or a significand
  // for S_FINAL to round
  task automatic spec(input logic [63:0] b, input logic [7:0] f, input logic [3:0] s);
    m_r <= b; sp_flags <= f; sp_status <= s; kind <= K_SPEC;
  endtask
  task automatic arith(input logic s, input logic signed [13:0] e, input logic [63:0] m, input logic stk);
    s_r <= s; e_r <= e; m_r <= m; sticky_r <= stk; kind <= K_ARITH;
  endtask

  // S_FINAL as soon as the latency allows: next cycle if it is up by then
  function automatic st_t to_final(logic [5:0] c); return c <= 6'd1 ? S_FINAL : S_HOLD; endfunction

  always_ff @(posedge clk) begin
    if (st != S_IDLE && lat_cnt != 6'd0) lat_cnt <= lat_cnt - 6'd1;
    if (reset) st <= S_IDLE;
    else case (st)
      S_IDLE: if (start) begin
        op_r <= op; d_r <= dbl; md_r <= trunc ? 2'd1 : mode; x_r <= x; y_r <= y;
        unfr_r <= unf_round; dexc_r <= dnrm_exc;
        src_d <= op == F_D2I || op == F_D2S ? 1'b1 : op == F_S2I || op == F_S2D ? 1'b0 : dbl;
        lat_cnt <= lat - 6'd2;
        sticky_r <= 1'b0;
        diff_r <= $signed(ex0 - ey0);
        ndiff_r <= $signed(ey0 - ex0);
        mul_a <= op == F_IMUL ? {21'd0, x[31] ? -x[31:0] : x[31:0]}
               : dbl ? {1'b1, x[51:0]} : {1'b1, x[22:0], 29'd0};
        mul_b <= op == F_IMUL || op == F_I2D || op == F_I2S ? {21'd0, yabs0}
               : dbl ? {1'b1, y[51:0]} : {1'b1, y[22:0], 29'd0};
        // an integer to float: shifted up to bit 62, its exponent (emu from_int)
        nz_r <= 6'd31 + lzc32(yabs0);
        e_r <= 14'sd31 - $signed({8'd0, lzc32(yabs0)});
        // a float to integer: 62 - e, the right shift to the units bit
        sh_r <= op == F_D2I ? 14'sd1085 - $signed({3'd0, y[62:52]}) : 14'sd189 - $signed({6'd0, y[30:23]});
        st <= op == F_ADD || op == F_SUB ? S_ADD : op == F_MUL || op == F_IMUL ? S_MUL : S_UNPACK;
      end

      S_ADD: begin
        unp_t a, b;
        logic [63:0] sm, sum, alt;
        logic stk, eff, neg;
        a = a_f; b = b_f;
        fl <= f_c;
        st <= to_final(lat_cnt);
        if (a.c == C_NAN || b.c == C_NAN) spec(nan_v(d_r), FL_NAN | FL_INV, base(d_r));
        else if (a.c == C_INF || b.c == C_INF) begin
          if (a.c == C_INF && b.c == C_INF && a.s != b.s) spec(nan_v(d_r), f_c | FL_INV, base(d_r));
          else spec(inf_v(d_r, a.c == C_INF ? a.s : b.s), f_c, base(d_r));
        end else if (a.c == C_ZERO && b.c == C_ZERO)
          spec(zero_v(d_r, a.s == b.s ? a.s : md_r == 2'd3), f_c, base(d_r));
        else if (b.c == C_ZERO) arith(a.s, a.e, a.m, 1'b0);
        else if (a.c == C_ZERO) arith(b.s, b.e, b.m, 1'b0);
        else begin
          // the larger exponent first; with equal exponents a smaller
          // first significand makes the difference negative, and the
          // second subtraction gives its magnitude
          if (span_c >= 12'd64) begin sm = '0; stk = small_c.m != 64'd0; end
          else begin
            sm = shr_out;                          // small_c.m >> span
            stk = (small_c.m & shr_low) != 64'd0;  // the bits shifted out
          end
          eff = big_c.s != small_c.s;
          sum = eff ? big_c.m - sm - {63'd0, stk} : big_c.m + sm;
          alt = b.m - a.m;
          neg = eff && diff_r == 12'sd0 && a.m < b.m;
          if (eff && diff_r == 12'sd0 && a.m == b.m) spec(zero_v(d_r, md_r == 2'd3), f_c, base(d_r));
          else if (neg) arith(b.s, b.e, alt, 1'b0);
          else arith(big_c.s, big_c.e, sum, stk);
        end
      end

      S_MUL: begin
        unp_t a, b;
        a = a_f; b = b_f;
        fl <= f_c;
        st <= to_final(lat_cnt);
        if (op_r == F_IMUL) begin
          m_r <= prod[63:0];
          s_r <= x_r[31] ^ y_r[31];
          kind <= K_IMUL;
        end
        else if (a.c == C_NAN || b.c == C_NAN) spec(nan_v(d_r), FL_NAN | FL_INV, base(d_r));
        else if ((a.c == C_INF && b.c == C_ZERO) || (a.c == C_ZERO && b.c == C_INF))
          spec(nan_v(d_r), f_c | FL_INV, base(d_r));
        else if (a.c == C_INF || b.c == C_INF) spec(inf_v(d_r, a.s ^ b.s), f_c, base(d_r));
        else if (a.c == C_ZERO || b.c == C_ZERO) spec(zero_v(d_r, a.s ^ b.s), f_c, base(d_r));
        // the significands' product (a.m * b.m >> 62, emu mul)
        else arith(a.s ^ b.s, a.e + b.e, prod[105:42], prod[41:0] != 42'd0);
      end

      S_UNPACK: begin
        unp_t a, b;
        logic [1:0] c;
        logic [63:0] sign;
        a = a_f; b = b_f;
        sign = sign_bit(d_r);
        fl <= f_c;
        st <= to_final(lat_cnt);
        case (op_r)
          F_DIV: begin
            if (a.c == C_NAN || b.c == C_NAN) spec(nan_v(d_r), FL_NAN | FL_INV, base(d_r));
            else if ((a.c == C_INF && b.c == C_INF) || (a.c == C_ZERO && b.c == C_ZERO))
              spec(nan_v(d_r), f_c | FL_INV, base(d_r));
            else if (a.c == C_INF) spec(inf_v(d_r, a.s ^ b.s), f_c, base(d_r));
            else if (b.c == C_INF || a.c == C_ZERO) spec(zero_v(d_r, a.s ^ b.s), f_c, base(d_r));
            else if (b.c == C_ZERO) spec(inf_v(d_r, a.s ^ b.s), f_c | FL_DVZ, base(d_r));
            else begin
              // the quotient's 2^0 bit down to its guard bit and one more,
              // two a cycle (26 bits single, 56 double)
              rr <= {1'b0, a.m}; bm <= b.m; q_r <= '0; cnt <= d_r ? 6'd28 : 6'd13;
              s_r <= a.s ^ b.s; e_r <= a.e - b.e;
              st <= S_DIV;
            end
          end
          F_SQRT: begin
            if (a.c == C_NAN) spec(nan_v(d_r), FL_NAN | FL_INV, base(d_r));
            else if (a.c == C_ZERO) spec(zero_v(d_r, a.s), f_c, base(d_r));
            else if (a.s) spec(nan_v(d_r), f_c | FL_INV, base(d_r));
            else if (a.c == C_INF) spec(inf_v(d_r, 1'b0), f_c, base(d_r));
            else begin
              // the radicand a.m << (62 + odd) two bits at a time; its top
              // two bits are zero and so is the root's first bit (2^1), so
              // that step is skipped: 25 bits single, 54 double
              logic signed [13:0] ev;
              rad <= a.e[0] ? {a.m[62:0], 3'b000} : {a.m, 2'b00};
              rem <= '0; bm <= '0; cnt <= d_r ? 6'd54 : 6'd25;
              ev = $signed(a.e) - $signed({13'd0, a.e[0]});
              s_r <= 1'b0; e_r <= ev >>> 1;
              st <= S_SQRT;
            end
          end
          F_EQ, F_LT, F_GT, F_ZEROP, F_MINUSP, F_PLUSP: begin
            logic t;
            // unordered: = and zerop are false, the predicates with > or < invalid too
            if (a.c == C_NAN || b.c == C_NAN)
              spec(64'd0, FL_NAN | (op_r == F_EQ || op_r == F_ZEROP ? 8'd0 : FL_INV), base(d_r));
            else begin
              c = compare(a, b);
              t = op_r == F_EQ || op_r == F_ZEROP ? c == 2'b00 :
                  op_r == F_LT || op_r == F_MINUSP ? c[1] : c[0];
              spec({63'd0, t}, f_c, base(d_r));
            end
          end
          F_NEG, F_ABS: spec(op_r == F_NEG ? y_r ^ sign : y_r & ~sign, 8'd0, base(d_r));   // logical
          F_I2D, F_I2S: begin
            // the magnitude (in mul_b) up to bit 62; e_r was set with nz_r
            if (y_r[31:0] == 32'd0) spec(zero_v(d_r, 1'b0), 8'd0, base(d_r));
            else begin m_r <= shl_out; s_r <= y_r[31]; sticky_r <= 1'b0; kind <= K_ARITH; end
          end
          F_D2S, F_S2D: begin
            if (a.c == C_NAN) spec(nan_v(d_r), FL_NAN | FL_INV, base(d_r));
            else if (a.c == C_INF) spec(inf_v(d_r, a.s), f_c, base(d_r));
            else if (a.c == C_ZERO) spec(zero_v(d_r, a.s), f_c, base(d_r));
            else arith(a.s, a.e, a.m, 1'b0);
          end
          F_D2I, F_S2I: begin
            logic [63:0] ip, mag;
            logic below, g, lower, inexact, up;
            if (a.c == C_NAN) spec(64'd0, FL_NAN | FL_IOV, 4'd15);
            else if (a.c == C_INF) spec(64'd0, FL_IOV, 4'd15);
            else if (a.c == C_ZERO) spec(64'd0, f_c, 4'd0);
            else if (sh_r < 14'sd0) spec(64'd0, f_c | FL_IOV, 4'd15);   // e > 62
            else begin
              if (sh_r >= 14'sd64) begin ip = '0; below = 1'b1; g = 1'b0; lower = 1'b1; end
              else begin
                ip = shr_out;                                   // a.m >> sh
                below = 1'b0;
                g = sh_r != 14'sd0 && a.m[sh_r[5:0] - 6'd1];
                lower = (a.m & (shr_low >> 1)) != 64'd0;        // the bits below sh-1
              end
              inexact = g | lower;
              case (md_r)
                2'd0: up = !below & g & (lower | ip[0]);
                2'd2: up = inexact & !a.s;
                2'd3: up = inexact & a.s;
                default: up = 1'b0;
              endcase
              mag = ip + {63'd0, up};
              if (mag > (a.s ? 64'h8000_0000 : 64'h7FFF_FFFF))
                spec({32'd0, a.s ? -mag[31:0] : mag[31:0]}, f_c | FL_IOV, 4'd15);
              else spec({32'd0, a.s ? -mag[31:0] : mag[31:0]}, f_c | (inexact ? FL_NX : 8'd0),
                        {3'd0, inexact});
            end
          end
          default: st <= S_IDLE;
        endcase
      end

      S_DIV: begin
        // two restoring steps
        logic ge1, ge2;
        logic [64:0] r1, r2;
        ge1 = rr >= {1'b0, bm};
        r1 = ge1 ? rr - {1'b0, bm} : rr;
        r1 = {r1[63:0], 1'b0};
        ge2 = r1 >= {1'b0, bm};
        r2 = ge2 ? r1 - {1'b0, bm} : r1;
        rr <= {r2[63:0], 1'b0};
        q_r <= {q_r[53:0], ge1, ge2};
        cnt <= cnt - 6'd1;
        if (cnt == 6'd1) st <= S_DIVF;
      end
      S_DIVF: begin
        // the quotient's 2^0 bit at 62
        m_r <= d_r ? {1'b0, q_r, 7'd0} : {1'b0, q_r[25:0], 37'd0};
        sticky_r <= rr != 65'd0;
        kind <= K_ARITH;
        st <= to_final(lat_cnt);
      end

      S_SQRT: begin
        logic [67:0] r2, t;
        r2 = {rem[65:0], rad[65:64]};
        t = {2'b00, bm, 2'b01};
        rad <= {rad[63:0], 2'b00};
        if (r2 >= t) begin rem <= r2 - t; bm <= {bm[62:0], 1'b1}; end
        else begin rem <= r2; bm <= {bm[62:0], 1'b0}; end
        cnt <= cnt - 6'd1;
        if (cnt == 6'd1) st <= S_SQRTF;
      end
      S_SQRTF: begin
        // the root's 2^0 bit at 62
        m_r <= d_r ? {bm[54:0], 9'd0} : {bm[25:0], 38'd0};
        sticky_r <= rem != 68'd0;
        kind <= K_ARITH;
        st <= to_final(lat_cnt);
      end

      S_HOLD: if (lat_cnt <= 6'd1) st <= S_FINAL;
      S_FINAL: st <= S_IDLE;
      default: st <= S_IDLE;
    endcase
  end

endmodule
