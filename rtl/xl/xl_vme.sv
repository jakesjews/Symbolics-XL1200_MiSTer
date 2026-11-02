// The Merlin-II's VMEbus interface, with the one board on the bus: a Univision
// UDC-3400 color display controller (xl_udc3400).
//
// Genera reaches the VMEbus two ways (i-sys/vme-defs.lisp, vme-bus.lisp,
// sys/istack.lisp):
//
// - The direct window: a physical address with bits 31:30 set is VME word
//   address A29:2 in bits 27:0 (A31:30 come from the direct access register
//   at 0x88000040), a full 32-bit transfer, the data shuffled on the way as
//   bits 29:28 say: 0 as is, 1 bytes reversed, 2 nibbles, 3 bits.  Lisp
//   arrays are little-endian (element 0 in the low bits) and VME bytes
//   big-endian, so an 8-bit raster is mapped with the byte shuffle and a
//   1-bit one with the bit shuffle.
// - Polled access, for odd sizes and for probing: the data register at
//   0x88000080 (read or written at the shuffle in bits 29:28), the size in
//   the access modifier register at 0x88000140, a VME address written to
//   0x88000100 to read or 0x880000C0 to write; the VIC068's bus error status
//   register (0x88000200 + 0xBB/4) then says whether anything answered.
//
// The other interface and VIC068 registers are kept as written and read
// back, as the FEP and Genera expect.  The slave buffer at 0x80000000 is
// not there: bus error, like anything else nobody answers.
module xl_vme #(
  parameter bit          CLEAR = 1'b1,
  parameter logic [28:0] MEM_BASE = 29'h0710_0000   // DDR word address of the board's memory
) (
  input  logic        clk,
  input  logic        reset,
  input  logic        init,            // power-up: the board clears its memory
  output logic        ready,

  // processor: physical addresses with bit 31 set
  input  logic        cpu_req,
  input  logic        cpu_we,
  input  logic [31:0] cpu_addr,
  input  logic [31:0] cpu_wdata,
  output logic        cpu_ack,
  output logic        cpu_buserr,
  output logic [31:0] cpu_rdata,

  // DDR3: the board's memory
  output logic [28:0] ddr_addr,
  output logic [7:0]  ddr_burstcnt,
  output logic        ddr_rd,
  output logic        ddr_we,
  output logic [63:0] ddr_din,
  output logic [7:0]  ddr_be,
  input  logic [63:0] ddr_dout,
  input  logic        ddr_dout_ready,
  input  logic        ddr_busy,

  // display: the console's raster (clk_vid) and what the board shows on it
  input  logic        clk_vid,
  input  logic [7:0]  hc,
  input  logic [4:0]  px,
  input  logic [10:0] vc,
  input  logic [7:0]  h_total,
  input  logic [10:0] v_visible,
  input  logic [10:0] v_total,
  input  logic        run_v,
  input  logic        retrace,         // clk domain: the raster is in vertical blanking
  output logic [23:0] rgb,
  output logic        video_on
);

  // ---------------------------------------------------------------- shuffles
  function automatic logic [31:0] shuffle(input logic [1:0] mode, input logic [31:0] d);
    logic [31:0] r;
    case (mode)
      2'd0: r = d;
      2'd1: r = {d[7:0], d[15:8], d[23:16], d[31:24]};
      2'd2: for (int i = 0; i < 8; i++) r[4*i +: 4] = d[4*(7-i) +: 4];
      default: for (int i = 0; i < 32; i++) r[i] = d[31-i];
    endcase
    return r;
  endfunction

  // The lanes of a polled access: lane 0 is D31:24 (VME byte 0); size 0
  // means a longword, else 1-3 bytes from the offset.
  function automatic logic [3:0] lanes(input logic [1:0] off, input logic [1:0] siz);
    logic [3:0] r;
    int n;
    n = siz == 2'd0 ? 4 : int'(siz);
    r = '0;
    for (int k = 0; k < 4; k++) if (k >= int'(off) && k < int'(off) + n) r[k] = 1'b1;
    return r;
  endfunction

  // ---------------------------------------------------------------- the bus
  logic        b_req, b_we;
  logic [29:0] b_addr;          // A31:2
  logic [3:0]  b_be;
  logic [31:0] b_wdata, b_rdata;
  logic        bd_ack, nb_ack;
  wire         b_sel = b_addr[29:22] == 8'h90;   // the board, at 0x90000000
  always_ff @(posedge clk) nb_ack <= b_req && !b_sel && !nb_ack;
  wire         b_ack = bd_ack || nb_ack;
  wire         b_err = nb_ack;

  xl_udc3400 #(.CLEAR(CLEAR), .BASE(MEM_BASE)) board (
    .clk, .reset, .init, .ready,
    .v_req(b_req && b_sel), .v_we(b_we), .v_addr(b_addr[21:0]), .v_be(b_be), .v_wdata(b_wdata),
    .v_ack(bd_ack), .v_rdata(b_rdata),
    .ddr_addr, .ddr_burstcnt, .ddr_rd, .ddr_we, .ddr_din, .ddr_be, .ddr_dout, .ddr_dout_ready, .ddr_busy,
    .clk_vid, .hc, .px, .vc, .h_total, .v_visible, .v_total, .run_v, .retrace,
    .rgb, .video_on
  );

  // ---------------------------------------------------------------- registers
  localparam logic [9:0] R_AM = 10'h040, R_PDATA = 10'h080, R_PWRITE = 10'h0C0, R_PREAD = 10'h100,
                         R_PAM = 10'h140, R_BERR = 10'h22E;
  logic [31:0] regs [1024];     // the interface's and the VIC068's, as written
  logic [31:0] regs_q;
  logic [1:0]  am_window;       // the direct window's A31:30
  logic [31:0] pdata;           // polled data, in VME order
  logic [1:0]  psiz;            // polled size
  logic [7:0]  berr;            // VIC068 bus error status
  logic        p_busy;          // a polled access is on the bus

  wire         is_reg    = cpu_addr[31:30] == 2'b10 && cpu_addr[27:12] == 16'h8000;
  wire         is_direct = cpu_addr[31:30] == 2'b11;
  wire  [9:0]  ri        = cpu_addr[9:0];
  wire         ri_hi     = cpu_addr[11:10] != 2'd0;
  wire  [1:0]  sh        = cpu_addr[29:28];

  typedef enum logic [1:0] { S_IDLE, S_REG, S_DIRECT, S_ERR } st_t;
  st_t st;

  wire reg_we = st == S_IDLE && !p_busy && cpu_req && !cpu_ack && is_reg && cpu_we && !ri_hi;
  always_ff @(posedge clk) begin
    if (reg_we) regs[ri] <= cpu_wdata;
    regs_q <= regs[ri];
  end

  always_ff @(posedge clk) begin
    cpu_ack <= 1'b0;
    cpu_buserr <= 1'b0;
    if (reset) begin
      st <= S_IDLE;
      b_req <= 1'b0;
      p_busy <= 1'b0;
      berr <= 8'd0;
      am_window <= 2'd0;
      psiz <= 2'd0;
    end else begin
      // a polled access completing (the processor was answered when it asked)
      if (p_busy && b_ack) begin
        p_busy <= 1'b0;
        b_req <= 1'b0;
        if (!b_we) pdata <= b_rdata;
        if (b_err) berr <= berr | 8'h30;      // VME timeout, BERR
      end
      case (st)
        S_IDLE: if (!p_busy && cpu_req && !cpu_ack) begin
          if (is_direct) begin
            b_req <= 1'b1;
            b_we <= cpu_we;
            b_addr <= {am_window, cpu_addr[27:0]};
            b_be <= 4'hF;
            b_wdata <= shuffle(sh, cpu_wdata);
            st <= S_DIRECT;
          end else if (is_reg) begin
            st <= S_REG;
            if (cpu_we && !ri_hi)
              case (ri)
                R_AM:    am_window <= cpu_wdata[1:0];
                R_PDATA: pdata <= shuffle(sh, cpu_wdata);
                R_PAM:   psiz <= cpu_wdata[15:14];
                R_BERR:  berr <= cpu_wdata[7:0];
                R_PREAD, R_PWRITE: begin
                  b_req <= 1'b1;
                  b_we <= ri == R_PWRITE;
                  b_addr <= cpu_wdata[31:2];
                  b_be <= lanes(cpu_wdata[1:0], psiz);
                  b_wdata <= pdata;
                  p_busy <= 1'b1;
                end
                default: ;
              endcase
          end else st <= S_ERR;
        end
        S_REG: begin
          cpu_ack <= 1'b1;
          cpu_rdata <= ri_hi ? 32'd0 : ri == R_PDATA ? shuffle(sh, pdata) :
                       ri == R_BERR ? {24'd0, berr} : regs_q;
          st <= S_IDLE;
        end
        S_DIRECT: if (b_ack) begin
          cpu_ack <= 1'b1;
          cpu_buserr <= b_err;
          cpu_rdata <= shuffle(sh, b_rdata);
          b_req <= 1'b0;
          st <= S_IDLE;
        end
        S_ERR: begin
          cpu_ack <= 1'b1;
          cpu_buserr <= 1'b1;
          st <= S_IDLE;
        end
        default: st <= S_IDLE;
      endcase
    end
  end

endmodule
