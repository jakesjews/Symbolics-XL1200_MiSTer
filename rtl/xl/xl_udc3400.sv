// Univision UDC-3400: the VMEbus color display controller Symbolics sold with
// the XL400, as Genera's driver sees it (sys.sct/color/univision.lisp,
// univision-82786.lisp, imach-common-color.lisp).  At VME 0x90000000, 16 MB:
//
//   +0        status: bits 31:16 read as the board ID 0xC000; bit 9 vertical
//             blanking (sticky, cleared by writing 1), bit 8 82786 reset,
//             bit 5 video enable, bit 2 interrupt, bit 1 interrupt enable
//   +4        interrupt vector, +8 control, +0xC plane mask: kept, no effect
//   +0x100    red Bt458 RAMDAC: address, palette data, control, overlay data
//             registers, a byte each on D7:0 of the transfer (the low lane
//             of a longword, the odd one of a 16-bit cycle), the other
//             lanes reading as ones
//   +0x110    green Bt458, +0x120 blue Bt458
//   +0x200    Intel 82786 registers (16-bit): memory here, except that the
//             status register (0x226) always shows the poll bit
//   +0x100000 overlay plane 0: 1 bit a pixel, 256 bytes a line
//   +0x140000 overlay plane 1
//   +0x180000 the 82786's display list
//   +0x800000 frame buffer: 8 bits a pixel, 2048 bytes a line, 1024 lines
//
// All but the registers is memory, in DDR3 (two VME words a DDR word).
//
// The 82786 graphics coprocessor isn't there: Genera draws into the memory
// itself (remote drawing disabled).  The picture is the frame buffer from
// line 0, pixel 0 (the pan, zoom and wraparound the driver programs into the
// 82786 are not followed), through the green Bt458, the one the driver loads
// with the colors in 8-bit mode, with the overlay planes as its command
// register enables them.  It runs on the console's raster: each line is
// fetched into a line buffer while the one before shows.
module xl_udc3400 #(
  parameter bit          CLEAR = 1'b1,
  parameter logic [28:0] BASE = 29'h0680_0000
) (
  input  logic        clk,
  input  logic        reset,
  input  logic        init,
  output logic        ready,

  // VMEbus slave (A31:24 = 0x90 decoded outside)
  input  logic        v_req,
  input  logic        v_we,
  input  logic [21:0] v_addr,      // A23:2
  input  logic [3:0]  v_be,        // lane 0 is D31:24
  input  logic [31:0] v_wdata,
  output logic        v_ack,
  output logic [31:0] v_rdata,

  // DDR3
  output logic [28:0] ddr_addr,
  output logic [7:0]  ddr_burstcnt,
  output logic        ddr_rd,
  output logic        ddr_we,
  output logic [63:0] ddr_din,
  output logic [7:0]  ddr_be,
  input  logic [63:0] ddr_dout,
  input  logic        ddr_dout_ready,
  input  logic        ddr_busy,

  // the console's raster (clk_vid)
  input  logic        clk_vid,
  input  logic [7:0]  hc,
  input  logic [4:0]  px,
  input  logic [10:0] vc,
  input  logic [7:0]  h_total,
  input  logic [10:0] v_visible,
  input  logic [10:0] v_total,
  input  logic        run_v,
  input  logic        retrace,      // clk domain
  output logic [23:0] rgb,
  output logic        video_on
);

  localparam int          CLEAR_BURST = 16;
  localparam int          PIX_BEATS = 144;        // 1152 pixels, 8 a DDR word
  localparam int          OVL_BEATS = 18;         // 1152 overlay bits, 64 a word
  localparam logic [28:0] FB_OFF = 29'h100000;    // VME +0x800000, in DDR words
  localparam logic [28:0] OV0_OFF = 29'h20000;    // VME +0x100000
  localparam logic [28:0] OV1_OFF = 29'h28000;    // VME +0x140000

  // ---------------------------------------------------------------- decode
  wire        a_ctl = v_addr[21:2] == 20'd0;                           // words 0-3
  wire        a_dac = v_addr[21:4] == 18'h4 && v_addr[3:2] != 2'd3;    // words 0x40-0x4B
  wire  [1:0] dac_n = v_addr[3:2];
  wire  [3:0] be4 = {v_be[0], v_be[1], v_be[2], v_be[3]};             // DDR byte j is lane 3-j
  // A byte-wide register takes D7:0 of whatever transfer reaches it: lane 3
  // of a longword, the odd lane of a word or byte transfer (D16 cycles run
  // on D15:0); it answers on D7:0, the rest floating high.
  wire  [7:0] reg_wbyte = v_be[3] ? v_wdata[7:0] : v_be[1] ? v_wdata[23:16] : v_be[2] ? v_wdata[15:8] : v_wdata[31:24];

  // ---------------------------------------------------------------- control words
  logic        int_enb, int_flag, video_enb, reset_bit, vb_flag;
  logic [31:0] int_vector, control, plane_mask;
  logic        retrace_q;
  wire  [31:0] status = {16'hC000, 6'd0, vb_flag, reset_bit, 2'b00, video_enb, 2'b00, int_flag, int_enb, 1'b0};
  assign video_on = video_enb;

  // ---------------------------------------------------------------- RAMDACs
  logic [2:0]  dac_strobe;
  logic [7:0]  dac_rdata [3];
  logic [7:0]  g_cmd, g_rmask;
  logic [23:0] g_ovl [4];
  logic [23:0] pal_q;
  logic [7:0]  pix_addr;
  wire         dac_take = st == D_IDLE && v_req && !v_ack && a_dac;
  always_comb begin
    dac_strobe = 3'd0;
    if (dac_take) dac_strobe[dac_n] = 1'b1;
  end
  bt458 red (
    .clk, .reset, .strobe(dac_strobe[0]), .we(v_we), .port(v_addr[1:0]), .wdata(reg_wbyte), .rdata(dac_rdata[0]),
    .clk_vid, .pix(8'd0), .pix_q(), .ovl(), .cmd(), .rmask()
  );
  bt458 green (
    .clk, .reset, .strobe(dac_strobe[1]), .we(v_we), .port(v_addr[1:0]), .wdata(reg_wbyte), .rdata(dac_rdata[1]),
    .clk_vid, .pix(pix_addr), .pix_q(pal_q), .ovl(g_ovl), .cmd(g_cmd), .rmask(g_rmask)
  );
  bt458 blue (
    .clk, .reset, .strobe(dac_strobe[2]), .we(v_we), .port(v_addr[1:0]), .wdata(reg_wbyte), .rdata(dac_rdata[2]),
    .clk_vid, .pix(8'd0), .pix_q(), .ovl(), .cmd(), .rmask()
  );

  // ---------------------------------------------------------------- memory and readout
  typedef enum logic [2:0] { D_CLEAR, D_IDLE, D_MEM_WR, D_MEM_RD, D_MEM_RD_WAIT, D_FETCH, D_FETCH_WAIT } st_t;
  st_t st /*verilator public_flat_rd*/;

  logic [21:0] clr_addr;          // DDR words cleared (bit 21: all 2M done)
  logic [4:0]  clr_beat;

  // The line being fetched: pixels, then overlay 0, then overlay 1
  logic        f_active;
  logic [9:0]  f_line;
  logic [1:0]  f_part;
  logic [7:0]  f_beat, f_n;
  logic [2:0]  ft_s;
  logic        fetch_tgl_v;
  logic [9:0]  fetch_line_v;
  wire         fetch_new = ft_s[2] != ft_s[1];
  wire  [7:0]  part_beats = f_part == 2'd0 ? 8'(PIX_BEATS) : 8'(OVL_BEATS);
  wire  [7:0]  f_left = part_beats - f_beat;
  wire  [7:0]  f_burst = f_left > 8'd32 ? 8'd32 : f_left;
  wire  [28:0] f_addr = f_part == 2'd0 ? BASE + FB_OFF + {11'd0, f_line, 8'd0} + 29'(f_beat)
                      : (f_part == 2'd1 ? BASE + OV0_OFF : BASE + OV1_OFF) + {14'd0, f_line, 5'd0} + 29'(f_beat);

  always_comb begin
    ddr_rd = 1'b0;
    ddr_we = 1'b0;
    ddr_burstcnt = 8'd1;
    ddr_addr = BASE + {7'd0, v_addr[21:1]};
    ddr_din = {v_wdata, v_wdata};
    ddr_be = v_addr[0] ? {be4, 4'd0} : {4'd0, be4};
    case (st)
      D_CLEAR: begin
        ddr_we = CLEAR && !init && !clr_addr[21];
        ddr_addr = BASE + 29'(clr_addr[20:0] - 21'(clr_beat));   // the burst's first beat
        ddr_burstcnt = 8'(CLEAR_BURST);
        ddr_din = '0;
        ddr_be = 8'hFF;
      end
      D_MEM_WR: ddr_we = 1'b1;
      D_MEM_RD: ddr_rd = 1'b1;
      D_FETCH: begin
        ddr_rd = 1'b1;
        ddr_addr = f_addr;
        ddr_burstcnt = f_burst;
      end
      default: ;
    endcase
  end

  assign ready = st != D_CLEAR;

  always_ff @(posedge clk) begin
    v_ack <= 1'b0;
    ft_s <= {ft_s[1:0], fetch_tgl_v};
    retrace_q <= retrace;
    if (retrace && !retrace_q) vb_flag <= 1'b1;
    if (fetch_new) begin
      f_active <= 1'b1;
      f_line <= fetch_line_v;
      f_part <= 2'd0;
      f_beat <= 8'd0;
    end
    if (reset) begin
      int_enb <= 1'b0; int_flag <= 1'b0; video_enb <= 1'b0; reset_bit <= 1'b0; vb_flag <= 1'b0;
      int_vector <= 32'd0; control <= 32'd0; plane_mask <= 32'd0;
    end
    if (init) begin
      st <= D_CLEAR;
      clr_addr <= '0;
      clr_beat <= '0;
      f_active <= 1'b0;
    end else case (st)
      D_CLEAR:
        if (!CLEAR || clr_addr[21]) st <= D_IDLE;
        else if (!ddr_busy) begin
          clr_beat <= clr_beat == 5'(CLEAR_BURST - 1) ? 5'd0 : clr_beat + 5'd1;
          clr_addr <= clr_addr + 22'd1;
        end

      D_IDLE:
        if (reset) ;
        else if (v_req && !v_ack) begin
          if (a_ctl) begin
            v_ack <= 1'b1;
            case (v_addr[1:0])
              2'd0: begin
                v_rdata <= status;
                if (v_we) begin
                  int_enb <= v_wdata[1];
                  int_flag <= v_wdata[2];
                  video_enb <= v_wdata[5];
                  reset_bit <= v_wdata[8];
                  if (v_wdata[9]) vb_flag <= 1'b0;
                end
              end
              2'd1: begin v_rdata <= int_vector; if (v_we) int_vector <= v_wdata; end
              2'd2: begin v_rdata <= control;    if (v_we) control <= v_wdata; end
              2'd3: begin v_rdata <= plane_mask; if (v_we) plane_mask <= v_wdata; end
            endcase
          end else if (a_dac) begin
            v_ack <= 1'b1;
            v_rdata <= {8'hFF, dac_rdata[dac_n], 8'hFF, dac_rdata[dac_n]};
          end else st <= v_we ? D_MEM_WR : D_MEM_RD;
        end else if (f_active) begin
          f_n <= f_burst;
          st <= D_FETCH;
        end

      D_MEM_WR: if (!ddr_busy) begin v_ack <= 1'b1; st <= D_IDLE; end
      D_MEM_RD: if (!ddr_busy) st <= D_MEM_RD_WAIT;
      D_MEM_RD_WAIT: if (ddr_dout_ready) begin
        v_ack <= 1'b1;
        v_rdata <= v_addr[0] ? ddr_dout[63:32] : ddr_dout[31:0];
        if (v_addr == 22'h89) v_rdata[7] <= 1'b1;    // 82786 status: stopped
        st <= D_IDLE;
      end

      D_FETCH: if (!ddr_busy) st <= D_FETCH_WAIT;
      D_FETCH_WAIT: if (ddr_dout_ready) begin
        f_beat <= f_beat + 8'd1;
        f_n <= f_n - 8'd1;
        if (f_n == 8'd1) begin
          st <= D_IDLE;
          if (f_beat + 8'd1 == part_beats) begin
            f_beat <= 8'd0;
            if (f_part == 2'd2) f_active <= 1'b0;
            else f_part <= f_part + 2'd1;
          end
        end
      end

      default: st <= D_IDLE;
    endcase
  end

  // ---------------------------------------------------------------- line buffers
  // Two lines of each: the pixels (144 beats of 8, in slots of 256) and the
  // overlays (18 beats of 64 bits, in slots of 32).  Written as the beats
  // land, read by the raster a line later.
  logic [63:0] lbp [512];
  logic [63:0] lbo0 [64];
  logic [63:0] lbo1 [64];
  wire         lb_we = st == D_FETCH_WAIT && ddr_dout_ready;
  always_ff @(posedge clk) begin
    if (lb_we && f_part == 2'd0) lbp[{f_line[0], f_beat}] <= ddr_dout;
    if (lb_we && f_part == 2'd1) lbo0[{f_line[0], f_beat[4:0]}] <= ddr_dout;
    if (lb_we && f_part == 2'd2) lbo1[{f_line[0], f_beat[4:0]}] <= ddr_dout;
  end

  // ---------------------------------------------------------------- raster (clk_vid)
  // Pixel p of a beat: VME word p[2] (the even word in bits 31:0), lane
  // p[1:0] (lane 0 is D31:24); an overlay bit p: word p[5], lane p[4:3],
  // bit 7 - p[2:0] of the lane (the leftmost pixel in the top bit).
  function automatic logic [7:0] lane_of(input logic [63:0] beat, input logic [2:0] p);
    logic [31:0] w;
    w = p[2] ? beat[63:32] : beat[31:0];
    case (p[1:0])
      2'd0: return w[31:24];
      2'd1: return w[23:16];
      2'd2: return w[15:8];
      default: return w[7:0];
    endcase
  endfunction
  function automatic logic ov_of(input logic [63:0] beat, input logic [5:0] p);
    logic [7:0] b;
    b = lane_of(beat, p[5:3]);
    return b[3'd7 - p[2:0]];
  endfunction

  // The pixel two dots ahead of the raster is fetched from the line buffer,
  // so its color comes out when the console's dot does (one dot after the
  // raster position); the last two dots of a line look into the next.
  wire  [12:0] x = {hc, px};
  wire  [10:0] next_line = vc == v_total - 11'd1 ? 11'd0 : vc + 11'd1;
  wire         wrap = hc == h_total - 8'd1 && px >= 5'd30;
  wire  [12:0] xa = wrap ? {8'd0, px - 5'd30} : x + 13'd2;
  wire         bank = wrap ? next_line[0] : vc[0];
  logic [63:0] lbp_q, lbo0_q, lbo1_q;
  logic [5:0]  xs;
  logic [1:0]  ov_s;
  assign pix_addr = lane_of(lbp_q, xs[2:0]) & g_rmask;
  always_ff @(posedge clk_vid) begin
    lbp_q <= lbp[{bank, xa[10:3]}];
    lbo0_q <= lbo0[{bank, xa[10:6]}];
    lbo1_q <= lbo1[{bank, xa[10:6]}];
    xs <= xa[5:0];
    ov_s <= {ov_of(lbo1_q, xs), ov_of(lbo0_q, xs)} & g_cmd[1:0];
    rgb <= ov_s != 2'd0 ? g_ovl[ov_s] : g_cmd[6] ? pal_q : g_ovl[0];
    // the next line's fetch starts as this one begins
    if (run_v && hc == 8'd0 && px == 5'd0 && next_line < v_visible && next_line < 11'd1024) begin
      fetch_tgl_v <= ~fetch_tgl_v;
      fetch_line_v <= next_line[9:0];
    end
  end

endmodule


// Brooktree Bt458: 256-entry color palette and 4 overlay colors (red, green,
// blue a byte each, written and read in that order through the data
// registers, the address advancing after the third), the read mask, blink
// mask, command and test registers through the control register at
// addresses 4-7.  The address register reads back with its top nibble set,
// as the undriven lines do (the driver tells a Bt458 from a Bt457 by it).
module bt458 (
  input  logic        clk,
  input  logic        reset,
  input  logic        strobe,
  input  logic        we,
  input  logic [1:0]  port,        // 0 address, 1 palette data, 2 control, 3 overlay data
  input  logic [7:0]  wdata,
  output logic [7:0]  rdata,

  input  logic        clk_vid,
  input  logic [7:0]  pix,
  output logic [23:0] pix_q,       // {r, g, b} of pix, a clock later
  output logic [23:0] ovl [4],
  output logic [7:0]  cmd,         // bit 6 palette enable, bits 1:0 overlay enables
  output logic [7:0]  rmask
);
  logic [7:0]  addr, hr, hg, bmask, test;
  logic [1:0]  seq;
  logic [23:0] pal [256] /*verilator public_flat_rd*/;

  wire pal_we = strobe && we && port == 2'd1 && seq == 2'd2;
  always_ff @(posedge clk) if (pal_we) pal[addr] <= {hr, hg, wdata};
  always_ff @(posedge clk_vid) pix_q <= pal[pix];

  always_comb
    case (port)
      2'd0: rdata = addr;
      2'd2: case (addr[2:0])
              3'd4: rdata = rmask;
              3'd5: rdata = bmask;
              3'd6: rdata = cmd;
              3'd7: rdata = test;
              default: rdata = 8'd0;
            endcase
      default: rdata = 8'd0;
    endcase

  always_ff @(posedge clk) begin
    if (reset) begin
      addr <= 8'd0; seq <= 2'd0; rmask <= 8'hFF; bmask <= 8'd0; cmd <= 8'h40; test <= 8'd0;
      for (int i = 0; i < 4; i++) ovl[i] <= 24'd0;
    end else if (strobe) begin
      case (port)
        2'd0: if (we) begin addr <= wdata; seq <= 2'd0; end
        2'd1, 2'd3: begin
          if (we && seq == 2'd0) hr <= wdata;
          if (we && seq == 2'd1) hg <= wdata;
          if (seq == 2'd2) begin
            seq <= 2'd0;
            addr <= addr + 8'd1;
            if (we && port == 2'd3) ovl[addr[1:0]] <= {hr, hg, wdata};
          end else seq <= seq + 2'd1;
        end
        2'd2: if (we)
          case (addr[2:0])
            3'd4: rmask <= wdata;
            3'd5: bmask <= wdata;
            3'd6: cmd <= wdata;
            3'd7: test <= wdata;
            default: ;
          endcase
      endcase
    end
  end
endmodule
