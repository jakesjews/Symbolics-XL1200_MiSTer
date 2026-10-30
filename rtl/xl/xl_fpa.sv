// Weitek WTL3164 floating-point accelerator on the Merlin-II (coprocessor
// addresses 0-0o777).  Follows emu/fpa.h and emu/fpa.cpp, which explain the
// interface (inferred from Genera's i-sys/float.lisp) and the arithmetic.
// The arithmetic runs in xl_fpa_unit over several cycles; the bus holds off
// every access until it has finished, so software sees results at once, as
// with the C++ model.
module xl_fpa (
  input  logic        clk,
  input  logic        reset,
  input  logic        req,
  input  logic        we,
  input  logic [8:0]  addr,
  input  logic [31:0] wdata,
  output logic        ack,
  output ivory_pkg::word_t rdata
);
  import ivory_pkg::*;
  import xl_fpa_pkg::*;

  logic [31:0] r0h, r0l, r1h, r1l, r2h, r2l, ix, ir;
  logic        cond;
  logic [7:0]  sr [12];      // status registers, bits 31:24 of the word

  // ---------------------------------------------------------------- decode
  typedef struct packed { logic valid; fop_t op; logic dbl, trunc; logic [1:0] unit; } dec_t;
  localparam logic [1:0] U_ADD = 2'd0, U_MUL = 2'd1, U_DIV = 2'd2;

  function automatic dec_t decode(logic [8:0] a);   // a: the op address (multiple of 4)
    dec_t d;
    logic dbl;
    d = '0;
    dbl = a[7];
    if (a < 9'o374) begin
      d.valid = 1'b1; d.dbl = dbl;
      case (a[6:2])
        5'o00: begin d.op = F_ADD; d.unit = U_ADD; end
        5'o01: begin d.op = F_SUB; d.unit = U_ADD; end
        5'o02: begin d.op = F_MUL; d.unit = U_MUL; end
        5'o03, 5'o11: begin d.op = F_DIV; d.unit = U_DIV; end
        5'o14: begin d.op = F_NEG; d.unit = dbl ? U_MUL : U_ADD; end
        5'o20, 5'o24: begin d.op = F_EQ; d.unit = U_MUL; end
        5'o21, 5'o25: begin d.op = F_LT; d.unit = U_MUL; end
        5'o22, 5'o26: begin d.op = F_GT; d.unit = U_MUL; end
        5'o34: begin d.op = F_ZEROP; d.unit = U_MUL; end
        5'o35: begin d.op = F_MINUSP; d.unit = U_MUL; end
        5'o36: begin d.op = F_PLUSP; d.unit = U_MUL; end
        default: d.valid = 1'b0;
      endcase
    end else begin
      d.valid = 1'b1;
      case (a)
        9'o374: begin d.op = F_IMUL; d.unit = U_MUL; end
        9'o400: begin d.op = F_D2I; d.dbl = 1'b1; d.unit = U_ADD; end
        9'o404: begin d.op = F_D2I; d.dbl = 1'b1; d.trunc = 1'b1; d.unit = U_ADD; end
        9'o410: begin d.op = F_S2I; d.unit = U_ADD; end
        9'o414: begin d.op = F_S2I; d.trunc = 1'b1; d.unit = U_ADD; end
        9'o430: begin d.op = F_I2D; d.dbl = 1'b1; d.unit = U_ADD; end
        9'o434: begin d.op = F_I2S; d.trunc = 1'b1; d.unit = U_ADD; end
        9'o440: begin d.op = F_D2S; d.unit = U_ADD; end
        9'o450: begin d.op = F_S2D; d.dbl = 1'b1; d.unit = U_ADD; end
        9'o500: begin d.op = F_SQRT; d.dbl = 1'b1; d.unit = U_DIV; end
        9'o510: begin d.op = F_SQRT; d.unit = U_DIV; end
        9'o544: begin d.op = F_ABS; d.dbl = 1'b1; d.unit = U_MUL; end
        9'o554: begin d.op = F_ABS; d.unit = U_MUL; end
        default: d.valid = 1'b0;
      endcase
    end
    return d;
  endfunction

  function automatic logic in64(dec_t d);
    return d.op == F_D2I || d.op == F_D2S || (d.dbl && d.op < F_I2D);
  endfunction
  function automatic logic out64(dec_t d);
    return d.op == F_I2D || d.op == F_S2D || (d.dbl && d.op < F_I2D);
  endfunction
  function automatic logic is_pred(fop_t op);
    return op == F_EQ || op == F_LT || op == F_GT || op == F_ZEROP || op == F_MINUSP || op == F_PLUSP;
  endfunction
  // Reads at op+2 return a predicate's result
  function automatic logic pred_addr(logic [8:0] a);
    return !a[8] && a[1:0] == 2'd2 &&
           ((a[6:2] >= 5'o20 && a[6:2] <= 5'o26 && a[6:2] != 5'o23) || (a[6:2] >= 5'o34 && a[6:2] <= 5'o36));
  endfunction

  // ---------------------------------------------------------------- arithmetic unit
  logic        u_start, u_busy, u_done;
  dec_t        u_d, run_d;
  logic [63:0] u_x, u_y, u_bits;
  logic [7:0]  u_flags;
  logic [3:0]  u_status;

  xl_fpa_unit unit (
    .clk, .reset, .start(u_start), .op(u_d.op), .dbl(u_d.dbl), .mode(sr[0][2:1]), .trunc(u_d.trunc),
    .wrap_ovf(sr[2][3]),
    .x(u_x), .y(u_y), .busy(u_busy), .done(u_done), .bits(u_bits), .flags(u_flags), .status(u_status)
  );

  // ---------------------------------------------------------------- bus
  logic act;
  assign act = req && !ack && !u_busy && !u_start;

  always_ff @(posedge clk) begin
    ack <= act;
    u_start <= 1'b0;
    if (reset) begin
      for (int i = 0; i < 12; i++) sr[i] <= '0;
      ack <= 1'b0;
    end else begin
      if (act && !we) begin
        logic [31:0] v;
        v = addr == 9'd1 ? r1l : addr == 9'd2 ? r0h : addr == 9'd3 ? r0l : addr == 9'o400 ? ir :
            pred_addr(addr) ? {31'd0, cond} :
            addr >= 9'o600 && addr < 9'o614 ? {sr[addr - 9'o600], 24'd0} : 32'd0;
        rdata <= mkw(sr[11][7] ? DTP_FIXNUM : DTP_SINGLE_FLOAT, v);
      end
      if (act && we) begin
        case (addr)
          9'd0: r0h <= wdata;
          9'd2: r0l <= wdata;
          9'd3: r1l <= wdata;
          9'o200: r2h <= wdata;
          9'o202: r2l <= wdata;
          9'o374: ix <= wdata;
          9'o624: for (int i = 0; i < 12; i++) sr[i] <= '0;
          default:
            if (addr >= 9'o600 && addr < 9'o614) sr[addr - 9'o600] <= wdata[31:24];
            else if (addr[1:0] == 2'd1 && addr < 9'o600) begin
              dec_t d;
              r1h <= wdata;
              d = decode({addr[8:2], 2'b00});
              if (d.valid) begin
                u_d <= d;
                u_start <= 1'b1;
                u_x <= d.op == F_IMUL ? {32'd0, ix} : in64(d) ? {r0h, r0l} : {32'd0, r0h};
                u_y <= in64(d) ? {wdata, r1l} : {32'd0, wdata};
              end
            end
        endcase
      end
      if (u_start) run_d <= u_d;

      // Results (Wtl3164::execute)
      if (u_done) begin
        logic exception;
        logic [7:0] s11;
        s11 = sr[11];
        if (is_pred(run_d.op)) begin
          cond <= u_bits[0];
          s11[5] = u_bits[0];
        end else if (run_d.op == F_D2I || run_d.op == F_S2I || run_d.op == F_IMUL) ir <= u_bits[31:0];
        else begin
          r0h <= out64(run_d) ? u_bits[63:32] : u_bits[31:0];
          if (out64(run_d)) r0l <= u_bits[31:0];
        end
        if (run_d.unit == U_ADD) sr[6][7:4] <= u_status;
        else if (run_d.unit == U_MUL) sr[6][3:0] <= u_status;
        else s11[3:0] = u_status;
        sr[3] <= sr[3] | u_flags;
        exception = (u_flags & sr[2]) != 8'd0 || u_status == 4'd2 || u_status == 4'd3 ||
                    u_status == 4'd10 || u_status == 4'd11 || u_status == 4'd14;
        if (exception) s11[7] = 1'b1;
        else if (!sr[0][6]) s11[7] = 1'b0;
        sr[11] <= s11;
      end
    end
  end

endmodule
