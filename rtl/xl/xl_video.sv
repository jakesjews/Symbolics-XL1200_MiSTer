// The I/O board's console video: video memory (2048 x 1024 x 1 bit, 32
// pixels a word, bit 0 leftmost) and its timing, which a Signetics SCN2674
// display controller generates from what the FEP loads into its
// initialization registers (docs/NOTES.md, "Console video"; formulas as
// MAME's scn2674.cpp).  A character is one video word, so the character
// clock is the 80 MHz dot clock / 32.  Raster line y shows video memory line
// y from word 0.
//
// The registers start with the 80 MHz monitor's values and the sync runs from
// power-up, so a MiSTer display keeps its signal while the FEP reprograms the
// controller; the picture stays blank until the FEP turns it on (control bit
// 1 and the controller's display-on command).
//
// With `debug`, the top 16 lines show the eight dbg words in hex, the timing
// stays at the 80 MHz monitor's whatever the FEP loads, and video memory is
// always shown.
module xl_video (
  input  logic        clk,          // processor side
  input  logic        reset,

  // video memory, processor side (64K words)
  input  logic        vm_req,
  input  logic        vm_we,
  input  logic [15:0] vm_addr,
  input  logic [31:0] vm_wdata,
  output logic        vm_ack,
  output logic [31:0] vm_rdata,

  // SCN2674 initialization register port and command register; the board's
  // video control register (bit 0 inverts, bit 1 runs the sync)
  input  logic        ir_we,
  input  logic        cmd_we,
  input  logic [7:0]  wdata,
  input  logic [31:0] control,

  // timing as the processor sees it
  output logic [9:0]  scanline,
  output logic        retrace,

  input  logic        debug,
  input  logic [31:0] dbg [8],
  output logic [31:0] dbg_video,   // control bits, display on, IR pointer

  // display
  input  logic        clk_vid,      // 80 MHz dot clock
  output logic        white,
  output logic        hs,
  output logic        vs,
  output logic        hblank,
  output logic        vblank
);

  // ---------------------------------------------------------------- video memory
  logic [31:0] vram [65536] /*verilator public_flat_rw*/;
  logic [15:0] scan_a;
  logic [31:0] scan_q;
  always_ff @(posedge clk) begin
    if (vm_req && !vm_ack && vm_we) begin
      vram[vm_addr] <= vm_wdata;
      vm_rdata <= vm_wdata;
    end else vm_rdata <= vram[vm_addr];
  end
  always_ff @(posedge clk_vid) scan_q <= vram[scan_a];
  always_ff @(posedge clk) vm_ack <= vm_req && !vm_ack;

  // ---------------------------------------------------------------- SCN2674 registers
  logic [7:0] ir [15];
  logic [3:0] ir_ptr;
  logic       display_on;
  always_ff @(posedge clk) begin
    if (reset) begin
      ir_ptr <= 4'd0;
      display_on <= 1'b0;
      for (int i = 0; i < 15; i++) ir[i] <= 8'd0;
      // the FEP's PRECALCULATED-SCN2674-SYNC-PROGRAM for :80MHZ
      ir[0] <= 8'd56; ir[1] <= 8'd14; ir[2] <= 8'd9; ir[3] <= 8'd2;
      ir[4] <= 8'd109; ir[5] <= 8'd35; ir[6] <= 8'd0; ir[7] <= 8'd192;
    end else if (ir_we) begin
      ir[ir_ptr] <= wdata;
      if (ir_ptr != 4'd14) ir_ptr <= ir_ptr + 4'd1;
    end else if (cmd_we) begin
      case (wdata[7:5])
        3'b000:
          if (!wdata[4]) begin ir_ptr <= 4'd0; display_on <= 1'b0; end   // master reset
          else ir_ptr <= wdata[3:0];                                      // set IR pointer
        3'b001: if (wdata[3]) display_on <= wdata[0];                     // display on/off
        default: ;
      endcase
    end
  end

  // Timing in character clocks and lines.
  logic [7:0]  h_total, h_visible, hs_begin, hs_width;
  logic [10:0] v_visible, v_total, vs_begin;
  logic [2:0]  v_sync_width;
  always_ff @(posedge clk) begin
    logic [7:0] eq, hsw, hbp;
    logic [4:0] lines_per_row;
    logic [7:0] rows;
    logic [5:0] vfp, vbp;
    logic [7:0] r0, r1, r2, r3, r4, r5, r7;
    {r0, r1, r2, r3, r4, r5, r7} = debug ? {8'd56, 8'd14, 8'd9, 8'd2, 8'd109, 8'd35, 8'd192}
                                         : {ir[0], ir[1], ir[2], ir[3], ir[4], ir[5], ir[7]};
    eq = {1'b0, r1[6:0]} + 8'd1;
    hsw = {3'd0, r2[6:3], 1'b0} + 8'd2;
    hbp = {3'd0, r2[2:0], 2'b00} - 8'd1;
    lines_per_row = {1'b0, r0[6:3]} + 5'd1;
    rows = {1'b0, r4[6:0]} + 8'd1;
    vfp = {1'b0, r3[7:5], 2'b00} + 6'd4;
    vbp = {r3[4:0], 1'b0} + 6'd4;
    case (r7[7:6])
      2'd0: v_sync_width <= 3'd3;
      2'd1: v_sync_width <= 3'd1;
      2'd2: v_sync_width <= 3'd5;
      default: v_sync_width <= 3'd7;
    endcase
    h_total <= (eq + {hsw[6:0], 1'b0}) << 1;
    h_visible <= r5 + 8'd1;
    hs_begin <= ((eq + {hsw[6:0], 1'b0}) << 1) - hsw - hbp;
    hs_width <= hsw;
    v_visible <= 11'(lines_per_row) * 11'(rows);
    vs_begin <= 11'(lines_per_row) * 11'(rows) + 11'(vfp);
    v_total <= 11'(lines_per_row) * 11'(rows) + 11'(vfp) + 11'(vbp) + 11'(v_sync_width);
  end

  // ---------------------------------------------------------------- raster (clk_vid)
  // The settings above change only while the FEP programs the controller;
  // the dot clock domain takes them as they are (false paths).
  logic       run_v, on_v, inv_v;
  logic [2:0] run_s, on_s, inv_s;
  always_ff @(posedge clk_vid) begin
    run_s <= {run_s[1:0], control[1]};
    on_s <= {on_s[1:0], display_on};
    inv_s <= {inv_s[1:0], control[0]};
    run_v <= h_total > h_visible && v_total > v_visible;
    on_v <= (on_s[2] && run_s[2]) || debug;
    inv_v <= inv_s[2];
  end

  logic [4:0]  px;      // pixel within the character
  logic [7:0]  hc;      // character
  logic [10:0] vc;      // line
  logic [31:0] shift;
  wire         last_char = hc == h_total - 8'd1;
  wire  [10:0] next_line = (vc == v_total - 11'd1) ? 11'd0 : vc + 11'd1;

  always_ff @(posedge clk_vid) begin
    if (!run_v) begin
      px <= '0; hc <= '0; vc <= '0;
      hs <= 1'b0; vs <= 1'b0; hblank <= 1'b1; vblank <= 1'b1; white <= 1'b0;
    end else begin
      px <= px + 5'd1;
      if (px == 5'd31) begin
        hc <= last_char ? 8'd0 : hc + 8'd1;
        if (last_char) vc <= next_line;
        shift <= scan_q;
      end
      // fetch the next character's word (BRAM: address now, data two dots on)
      if (px == 5'd29)
        scan_a <= last_char ? {next_line[9:0], 6'd0} : {vc[9:0], 6'(hc + 8'd1)};

      hblank <= hc >= h_visible;
      vblank <= vc >= v_visible;
      hs <= hc >= hs_begin && hc < hs_begin + hs_width;
      vs <= vc >= vs_begin && vc < vs_begin + 11'(v_sync_width);
      // a 1 bit is black unless control bit 0 inverts
      white <= on_v && hc < h_visible && vc < v_visible && (shift[px] == inv_v);
      if (debug && vc < 11'd16) white <= !dbg_pixel;
    end
  end

  // ---------------------------------------------------------------- debug line
  // 16 x 16 cells (an 8 x 8 font doubled): eight words of eight hex digits
  // and a space.  The words cross clock domains unsynchronized; a digit may
  // flicker while it changes.
  function automatic logic [7:0] hex_font(input logic [3:0] d, input logic [2:0] row);
    logic [63:0] g;
    case (d)
      4'h0: g = 64'h3C666E7666663C00; 4'h1: g = 64'h1838181818187E00;
      4'h2: g = 64'h3C66060C30607E00; 4'h3: g = 64'h3C66061C06663C00;
      4'h4: g = 64'h0C1C3C6C7E0C0C00; 4'h5: g = 64'h7E607C0606663C00;
      4'h6: g = 64'h3C66607C66663C00; 4'h7: g = 64'h7E060C1830303000;
      4'h8: g = 64'h3C66663C66663C00; 4'h9: g = 64'h3C66663E06663C00;
      4'hA: g = 64'h183C66667E666600; 4'hB: g = 64'h7C66667C66667C00;
      4'hC: g = 64'h3C66606060663C00; 4'hD: g = 64'h786C6666666C7800;
      4'hE: g = 64'h7E60607C60607E00; default: g = 64'h7E60607C60606000;
    endcase
    return g[63 - 8 * row -: 8];
  endfunction

  logic [2:0] dbg_field;
  logic [3:0] dbg_digit;
  logic       dbg_pixel;
  always_comb begin
    logic [31:0] w;
    logic [3:0]  nib;
    logic [7:0]  bits;
    w = dbg[dbg_field];
    nib = w[4 * (7 - dbg_digit[2:0]) +: 4];
    bits = hex_font(nib, vc[3:1]);
    dbg_pixel = dbg_digit != 4'd8 && hc < h_visible && bits[7 - px[3:1]];
  end
  always_ff @(posedge clk_vid) begin
    if (!run_v || (px == 5'd31 && last_char)) begin
      dbg_field <= 3'd0; dbg_digit <= 4'd0;
    end else if (px[3:0] == 4'd15) begin
      if (dbg_digit == 4'd8) begin dbg_digit <= 4'd0; dbg_field <= dbg_field + 3'd1; end
      else dbg_digit <= dbg_digit + 4'd1;
    end
  end
  // frames shown (counted on the dot clock; read unsynchronized)
  logic [7:0] frames;
  logic       vs_q;
  always_ff @(posedge clk_vid) begin
    vs_q <= vs;
    if (vs && !vs_q) frames <= frames + 8'd1;
  end
  assign dbg_video = {control[7:0], 3'd0, display_on, ir_ptr, frames, 8'd0};

  // ---------------------------------------------------------------- back to the processor
  // Line number as Gray code across the clock domains.
  logic [9:0] line_gray, line_s1, line_s2;
  logic       vb_v;
  logic [1:0] vb_s;
  always_ff @(posedge clk_vid) begin
    line_gray <= vc[9:0] ^ (vc[9:0] >> 1);
    vb_v <= run_v && vc >= v_visible;
  end
  always_ff @(posedge clk) begin
    line_s1 <= line_gray;
    line_s2 <= line_s1;
    vb_s <= {vb_s[0], vb_v};
    scanline[9] <= line_s2[9];
    for (int i = 8; i >= 0; i--) scanline[i] <= ^(line_s2 >> i);
    retrace <= vb_s[1];
  end

endmodule
