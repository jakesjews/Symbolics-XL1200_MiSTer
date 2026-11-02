// Arithmetic of the WTL3164 model (rtl/xl/xl_fpa.sv), step for step the C++
// in emu/fpa.cpp: unpack, the operation, normalize, round (or wrap an
// underflow), pack.  Multiplies take four 64x16 steps, divides 56 restoring
// steps, square roots 64 steps; the rest a few cycles.  sim/fpa checks it
// against the C++ with random operands.
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
  input  logic              dbl,     // double precision (the result's format for conversions)
  input  logic [1:0]        mode,    // 0 nearest, 1 zero, 2 plus, 3 minus
  input  logic              trunc,   // conversions: round to zero
  input  logic              unf_round, // SR2 UNF CONTROL: underflows come back rounded
  input  logic              dnrm_exc,  // SR2 DNRM CONTROL: denormalized operands raise their flag
  input  logic [63:0]       x, y,
  output logic              busy,
  output logic              done,    // one cycle, with the results
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

  typedef enum logic [3:0] {
    S_IDLE, S_UNPACK, S_ADD, S_MUL, S_MULF, S_DIV, S_DIVF, S_SQRT, S_SQRTF, S_NORM, S_ROUND,
    S_TOINT
  } st_t;
  st_t st;

  fop_t        op_r;
  logic        d_r, src_d, s_r, diff, sticky_r, unfr_r, dexc_r;
  logic [1:0]  md_r;
  logic [63:0] x_r, y_r, am, bm, m_r;
  logic signed [13:0] e_r;
  logic [7:0]  fl;
  unp_t        ua_r;
  logic [127:0] acc;
  logic [64:0] rr;
  logic [55:0] q_r;
  logic [67:0] rem;
  logic [6:0]  cnt;

  assign busy = st != S_IDLE || done;

  task automatic finish(input logic [63:0] b, input logic [7:0] f, input logic [3:0] s);
    bits <= b; flags <= f; status <= s;
    done <= 1'b1;
    st <= S_IDLE;
  endtask
  task automatic to_round(input logic s, input logic signed [13:0] e, input logic [63:0] m,
                          input logic stk, input st_t next);
    s_r <= s; e_r <= e; m_r <= m; sticky_r <= stk;
    st <= next;
  endtask

  // The operands unpacked (S_UNPACK) and an add's alignment, outside the
  // state machine so that one 64-bit right shifter and one mask serve the
  // alignment and the integer conversions (S_TOINT): never the same cycle.
  unp_t        a_c, b_c;
  logic        unary_c, swap_c;
  logic [13:0] span_c, toint_sh;
  logic [63:0] shr_in, shr_out, shr_low;
  logic [5:0]  shr_n;
  always_comb begin
    unary_c = op_r == F_SQRT || op_r == F_ZEROP || op_r == F_MINUSP || op_r == F_PLUSP ||
              op_r == F_NEG || op_r == F_ABS || op_r >= F_I2D;
    a_c = unpack(src_d, unary_c ? y_r : x_r);
    b_c = op_r == F_ZEROP || op_r == F_MINUSP || op_r == F_PLUSP ? '0
        : unpack(src_d, op_r == F_SUB ? y_r ^ (src_d ? 64'h8000_0000_0000_0000 : 64'h8000_0000) : y_r);
    swap_c = $signed(a_c.e) < $signed(b_c.e) || (a_c.e == b_c.e && a_c.m < b_c.m);
    span_c = (swap_c ? b_c.e : a_c.e) - (swap_c ? a_c.e : b_c.e);
    toint_sh = 14'sd62 - ua_r.e;
    shr_in = st == S_TOINT ? ua_r.m : swap_c ? a_c.m : b_c.m;
    shr_n = st == S_TOINT ? toint_sh[5:0] : span_c[5:0];
    shr_out = shr_in >> shr_n;
    shr_low = ~({64{1'b1}} << shr_n);   // the bits shifted out
  end

  always_ff @(posedge clk) begin
    done <= 1'b0;
    if (reset) st <= S_IDLE;
    else case (st)
      S_IDLE: if (start) begin
        op_r <= op; d_r <= dbl; md_r <= trunc ? 2'd1 : mode; x_r <= x; y_r <= y;
        unfr_r <= unf_round; dexc_r <= dnrm_exc;
        src_d <= op == F_D2I || op == F_D2S ? 1'b1 : op == F_S2I || op == F_S2D ? 1'b0 : dbl;
        fl <= '0;
        st <= S_UNPACK;
      end

      S_UNPACK: begin
        unp_t a, b;
        logic unary;
        logic [7:0] f;
        logic [1:0] c;
        logic [63:0] sign;
        unary = unary_c;
        a = a_c;
        b = b_c;
        sign = d_r ? 64'h8000_0000_0000_0000 : 64'h8000_0000;
        f = '0;
        if (op_r != F_I2D && op_r != F_I2S && op_r != F_IMUL) begin   // float operands
          if (a.c == C_DEN) begin a.c = C_ZERO; f = dexc_r ? FL_DEN : 8'd0; end
          if (b.c == C_DEN) begin b.c = C_ZERO; f = dexc_r ? FL_DEN : 8'd0; end
        end
        fl <= f;
        ua_r <= a;
        case (op_r)
          F_ADD, F_SUB: begin
            if (a.c == C_NAN || b.c == C_NAN) finish(nan_v(d_r), FL_NAN | FL_INV, base(d_r));
            else if (a.c == C_INF || b.c == C_INF) begin
              if (a.c == C_INF && b.c == C_INF && a.s != b.s) finish(nan_v(d_r), f | FL_INV, base(d_r));
              else finish(inf_v(d_r, a.c == C_INF ? a.s : b.s), f, base(d_r));
            end else if (a.c == C_ZERO && b.c == C_ZERO)
              finish(zero_v(d_r, a.s == b.s ? a.s : md_r == 2'd3), f, base(d_r));
            else if (b.c == C_ZERO) to_round(a.s, a.e, a.m, 1'b0, S_ROUND);
            else if (a.c == C_ZERO) to_round(b.s, b.e, b.m, 1'b0, S_ROUND);
            else begin
              unp_t ub, us;
              logic [63:0] sm;
              logic stk;
              ub = swap_c ? b : a;
              us = swap_c ? a : b;
              if (span_c >= 14'd64) begin sm = '0; stk = us.m != 64'd0; end
              else begin
                sm = shr_out;                        // us.m >> span
                stk = (us.m & shr_low) != 64'd0;     // the bits shifted out
              end
              am <= ub.m; bm <= sm; diff <= ub.s != us.s;
              to_round(ub.s, ub.e, '0, stk, S_ADD);
            end
          end
          F_MUL: begin
            if (a.c == C_NAN || b.c == C_NAN) finish(nan_v(d_r), FL_NAN | FL_INV, base(d_r));
            else if ((a.c == C_INF && b.c == C_ZERO) || (a.c == C_ZERO && b.c == C_INF))
              finish(nan_v(d_r), f | FL_INV, base(d_r));
            else if (a.c == C_INF || b.c == C_INF) finish(inf_v(d_r, a.s ^ b.s), f, base(d_r));
            else if (a.c == C_ZERO || b.c == C_ZERO) finish(zero_v(d_r, a.s ^ b.s), f, base(d_r));
            else begin
              am <= a.m; bm <= b.m; acc <= '0; cnt <= 7'd4;
              to_round(a.s ^ b.s, a.e + b.e, '0, 1'b0, S_MUL);
            end
          end
          F_DIV: begin
            if (a.c == C_NAN || b.c == C_NAN) finish(nan_v(d_r), FL_NAN | FL_INV, base(d_r));
            else if ((a.c == C_INF && b.c == C_INF) || (a.c == C_ZERO && b.c == C_ZERO))
              finish(nan_v(d_r), f | FL_INV, base(d_r));
            else if (a.c == C_INF) finish(inf_v(d_r, a.s ^ b.s), f, base(d_r));
            else if (b.c == C_INF || a.c == C_ZERO) finish(zero_v(d_r, a.s ^ b.s), f, base(d_r));
            else if (b.c == C_ZERO) finish(inf_v(d_r, a.s ^ b.s), f | FL_DVZ, base(d_r));
            else begin
              rr <= {1'b0, a.m}; bm <= b.m; q_r <= '0; cnt <= 7'd56;
              to_round(a.s ^ b.s, a.e - b.e, '0, 1'b0, S_DIV);
            end
          end
          F_SQRT: begin
            if (a.c == C_NAN) finish(nan_v(d_r), FL_NAN | FL_INV, base(d_r));
            else if (a.c == C_ZERO) finish(zero_v(d_r, a.s), f, base(d_r));
            else if (a.s) finish(nan_v(d_r), f | FL_INV, base(d_r));
            else if (a.c == C_INF) finish(inf_v(d_r, 1'b0), f, base(d_r));
            else begin
              logic signed [13:0] ev;
              acc <= a.e[0] ? {1'b0, a.m, 63'd0} : {2'b00, a.m, 62'd0};
              rem <= '0; bm <= '0; cnt <= 7'd64;
              ev = $signed(a.e) - $signed({13'd0, a.e[0]});
              to_round(1'b0, ev >>> 1, '0, 1'b0, S_SQRT);
            end
          end
          F_EQ, F_LT, F_GT, F_ZEROP, F_MINUSP, F_PLUSP: begin
            logic t;
            // unordered: = and zerop are false, the predicates with > or < invalid too
            if (a.c == C_NAN || b.c == C_NAN)
              finish(64'd0, FL_NAN | (op_r == F_EQ || op_r == F_ZEROP ? 8'd0 : FL_INV), base(d_r));
            else begin
              c = compare(a, b);
              t = op_r == F_EQ || op_r == F_ZEROP ? c == 2'b00 :
                  op_r == F_LT || op_r == F_MINUSP ? c[1] : c[0];
              finish({63'd0, t}, f, base(d_r));
            end
          end
          F_NEG, F_ABS: finish(op_r == F_NEG ? y_r ^ sign : y_r & ~sign, 8'd0, base(d_r));   // logical
          F_I2D, F_I2S: begin
            if (y_r[31:0] == 32'd0) finish(zero_v(d_r, 1'b0), 8'd0, base(d_r));
            else to_round(y_r[31], 14'sd62, {32'd0, y_r[31] ? -y_r[31:0] : y_r[31:0]}, 1'b0, S_NORM);
          end
          F_D2S, F_S2D: begin
            if (a.c == C_NAN) finish(nan_v(d_r), FL_NAN | FL_INV, base(d_r));
            else if (a.c == C_INF) finish(inf_v(d_r, a.s), f, base(d_r));
            else if (a.c == C_ZERO) finish(zero_v(d_r, a.s), f, base(d_r));
            else to_round(a.s, a.e, a.m, 1'b0, S_ROUND);
          end
          F_D2I, F_S2I: begin
            if (a.c == C_NAN) finish(64'd0, FL_NAN | FL_IOV, 4'd15);
            else if (a.c == C_INF) finish(64'd0, FL_IOV, 4'd15);
            else if (a.c == C_ZERO) finish(64'd0, f, 4'd0);
            else if ($signed(a.e) > 14'sd62) finish(64'd0, f | FL_IOV, 4'd15);
            else st <= S_TOINT;
          end
          default: begin   // F_IMUL
            logic signed [63:0] p;
            p = $signed(x_r[31:0]) * $signed(y_r[31:0]);
            if (p != {{32{p[31]}}, p[31:0]}) finish({32'd0, p[31:0]}, FL_IOV, 4'd15);
            else finish({32'd0, p[31:0]}, 8'd0, 4'd0);
          end
        endcase
      end

      S_ADD: begin
        logic [63:0] m;
        m = diff ? am - bm - {63'd0, sticky_r} : am + bm;
        if (diff && m == 64'd0 && !sticky_r) finish(zero_v(d_r, md_r == 2'd3), fl, base(d_r));
        else begin m_r <= m; st <= S_NORM; end
      end

      S_MUL: begin
        logic [79:0] pp;
        pp = am * bm[63:48];
        acc <= {acc[111:0], 16'd0} + {48'd0, pp};
        bm <= {bm[47:0], 16'd0};
        cnt <= cnt - 7'd1;
        if (cnt == 7'd1) st <= S_MULF;
      end
      S_MULF: begin
        m_r <= acc[125:62];
        sticky_r <= acc[61:0] != 62'd0;
        st <= S_NORM;
      end

      S_DIV: begin
        logic ge;
        logic [64:0] r;
        ge = rr >= {1'b0, bm};
        r = ge ? rr - {1'b0, bm} : rr;
        rr <= {r[63:0], 1'b0};
        q_r <= {q_r[54:0], ge};
        cnt <= cnt - 7'd1;
        if (cnt == 7'd1) st <= S_DIVF;
      end
      S_DIVF: begin
        m_r <= {1'b0, q_r, 7'd0};
        sticky_r <= rr != 65'd0;
        st <= S_NORM;
      end

      S_SQRT: begin
        logic [67:0] r2, t;
        r2 = {rem[65:0], acc[127:126]};
        t = {2'b00, bm, 2'b01};
        acc <= {acc[125:0], 2'b00};
        if (r2 >= t) begin rem <= r2 - t; bm <= {bm[62:0], 1'b1}; end
        else begin rem <= r2; bm <= {bm[62:0], 1'b0}; end
        cnt <= cnt - 7'd1;
        if (cnt == 7'd1) st <= S_SQRTF;
      end
      S_SQRTF: begin
        m_r <= bm;
        sticky_r <= rem != 68'd0;
        st <= S_ROUND;
      end

      S_NORM: begin
        if (m_r[63]) begin
          m_r <= m_r >> 1;
          sticky_r <= sticky_r | m_r[0];
          e_r <= e_r + 14'sd1;
        end else begin
          logic [6:0] n;
          n = lzc(m_r) - 7'd1;
          m_r <= m_r << n[5:0];
          e_r <= e_r - $signed({7'd0, n});
        end
        st <= S_ROUND;
      end

      S_ROUND: begin
        res_t r;
        r = round_pack(d_r, s_r, e_r, m_r, sticky_r, md_r, unfr_r);
        if (op_r == F_D2S) begin
          if (r.status == 4'd4) r.status = 4'd13;
          else if (r.status == 4'd2 || r.status == 4'd3) r.status = 4'd14;
        end
        finish(r.bits, fl | r.flags, r.status);
      end

      S_TOINT: begin
        logic [13:0] sh;
        logic [63:0] ip, mag;
        logic below, g, lower, inexact, up;
        sh = toint_sh;
        if (sh >= 14'd64) begin ip = '0; below = 1'b1; g = 1'b0; lower = 1'b1; end
        else begin
          ip = shr_out;                                   // ua_r.m >> sh
          below = 1'b0;
          g = sh != 14'd0 && ua_r.m[sh[5:0] - 6'd1];
          lower = (ua_r.m & (shr_low >> 1)) != 64'd0;     // the bits below sh-1
        end
        inexact = g | lower;
        case (md_r)
          2'd0: up = !below & g & (lower | ip[0]);
          2'd2: up = inexact & !ua_r.s;
          2'd3: up = inexact & ua_r.s;
          default: up = 1'b0;
        endcase
        mag = ip + {63'd0, up};
        if (mag > (ua_r.s ? 64'h8000_0000 : 64'h7FFF_FFFF))
          finish({32'd0, ua_r.s ? -mag[31:0] : mag[31:0]}, fl | FL_IOV, 4'd15);
        else finish({32'd0, ua_r.s ? -mag[31:0] : mag[31:0]}, fl | (inexact ? FL_NX : 8'd0),
                    {3'd0, inexact});
      end

      default: st <= S_IDLE;
    endcase
  end

endmodule
