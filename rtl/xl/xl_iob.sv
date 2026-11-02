// Merlin I/O board (XL400/XL1200), slot 0 at physical 0x40000000; follows
// emu/ioboard.cpp, which lists the register layout.  Here: the processor's
// accesses, the buffer memory (in DDR3 through xl_mem) shared by the
// processor, SCSI DMA and console DMA, the DUSCC and AM9517 as far as the
// console link needs them, the WD33C93 (xl_scsi), the console (xl_console)
// and the video (xl_video).
//
// Time: device timing counts `tick`s.  The machine ticks once a microsecond,
// or, in lockstep simulation, once per instruction as the reference model
// does (LOCKSTEP: the console byte rate and the video counters then follow
// the model, and dma_busy tells the machine to hold the processor while
// console DMA lands and while the 82586 works).
module xl_iob #(
  parameter int NT = 2,
  parameter bit LOCKSTEP = 1'b0,
  parameter logic [47:0] ETHERNET = 48'h08_00_05_12_00_01
) (
  input  logic        clk,
  input  logic        reset,
  input  logic        tick,
  input  logic [31:0] ticks,        // LOCKSTEP: instructions so far

  // processor
  input  logic        cpu_req,
  input  logic        cpu_we,
  input  logic [27:0] cpu_addr,     // offset in the board's 256M words
  input  logic [31:0] cpu_wdata,
  output logic        cpu_ack,
  output logic [31:0] cpu_rdata,
  output logic        dma_busy,
  output logic        scsi_irq,     // interrupt sources (Merlin-II interrupt register bits 8, 18)
  output logic        ether_irq,

  // buffer memory (xl_mem)
  output logic        buf_req,
  output logic        buf_we,
  output logic [15:0] buf_addr,
  output logic [3:0]  buf_be,
  output logic [31:0] buf_wdata,
  input  logic        buf_ack,
  input  logic [31:0] buf_rdata,

  // the 82586's wire (xl_eth_hps)
  output logic        tx_push,
  output logic        tx_stp,
  output logic [1:0]  tx_be,
  output logic [15:0] tx_d,
  output logic        tx_enp,
  output logic [11:0] tx_len,
  output logic        tx_crcgen,
  output logic        tx_clr,
  input  logic        tx_busy,
  output logic        rx_pop,
  output logic        rx_clr,
  input  logic [15:0] rx_d,
  input  logic        rx_deof,
  input  logic        rx_fifordy,
  input  logic [11:0] rx_len,
  output logic        rx_lpbk,
  output logic        rx_prom,
  output logic [47:0] rx_padr,
  output logic [63:0] rx_ladrf,

  // console
  input  logic        key_strobe,
  input  logic        key_down,
  input  logic [6:0]  key_code,
  input  logic        mouse_strobe,
  input  logic [2:0]  mouse_buttons,
  input  logic signed [9:0] mouse_dx,
  input  logic signed [9:0] mouse_dy,

  // disks
  input  logic [NT-1:0] img_mounted,
  input  logic          img_readonly,
  input  logic [63:0]   img_size,
  output logic [31:0]   sd_lba [NT],
  output logic [5:0]    sd_blk_cnt [NT],
  output logic [NT-1:0] sd_rd,
  output logic [NT-1:0] sd_wr,
  input  logic [NT-1:0] sd_ack,
  input  logic [13:0]   sd_buff_addr,
  input  logic [7:0]    sd_buff_dout,
  output logic [7:0]    sd_buff_din [NT],
  input  logic          sd_buff_wr,
  output logic          disk_busy,

  // display
  input  logic        clk_vid,
  output logic        white,
  output logic        hs,
  output logic        vs,
  output logic        hblank,
  output logic        vblank,
  output logic [7:0]  r_hc,          // the raster, for the color board
  output logic [4:0]  r_px,
  output logic [10:0] r_vc,
  output logic [7:0]  r_h_total,
  output logic [10:0] r_v_visible,
  output logic [10:0] r_v_total,
  output logic        r_run,
  output logic        r_retrace,     // clk domain

  // debug line
  input  logic        debug,
  input  logic [31:0] dbg [8],
  output logic [31:0] dbg_scsi,
  output logic [31:0] dbg_blocks,
  output logic [31:0] dbg_video
);

  // ---------------------------------------------------------------- ID PROM
  // Bytes 0,1 = AA 55, 16-21 = Ethernet address, 28 = checksum of the first
  // byte[29] bytes (each rotated left by its index mod 8), 30 = 00, 31 = FF.
  function automatic logic [255:0] idprom_bytes();
    logic [255:0] v;
    logic [7:0] b, sum;
    v = '0;
    v[7:0] = 8'hAA;
    v[15:8] = 8'h55;
    for (int k = 0; k < 6; k++) v[8 * (16 + k) +: 8] = ETHERNET[47 - 8 * k -: 8];
    v[8 * 29 +: 8] = 8'd28;
    sum = 8'h00;
    for (int k = 0; k < 28; k++) begin
      b = v[8 * k +: 8];
      sum = sum + ((b << (k % 8)) | (b >> (8 - k % 8)));
    end
    v[8 * 28 +: 8] = sum;
    v[8 * 31 +: 8] = 8'hFF;
    return v;
  endfunction
  localparam logic [255:0] IDPROM = idprom_bytes();

  // ---------------------------------------------------------------- devices
  logic        wd_req, wd_we, wd_ack;
  logic [4:0]  wd_addr;
  logic [7:0]  wd_wdata, wd_rdata;
  logic        sdma_req, sdma_we, sdma_ack;
  logic [7:0]  sdma_wdata, sdma_rdata;
  logic        wd_mr;

  xl_scsi #(.NT(NT), .SYNC_IO(LOCKSTEP)) scsi (
    .clk, .reset, .mr(wd_mr),
    .reg_req(wd_req), .reg_we(wd_we), .reg_addr(wd_addr), .reg_wdata(wd_wdata),
    .reg_ack(wd_ack), .reg_rdata(wd_rdata),
    .dma_req(sdma_req), .dma_we(sdma_we), .dma_wdata(sdma_wdata), .dma_ack(sdma_ack), .dma_rdata(sdma_rdata),
    .img_mounted, .img_readonly, .img_size, .sd_lba, .sd_blk_cnt, .sd_rd, .sd_wr, .sd_ack,
    .sd_buff_addr, .sd_buff_dout, .sd_buff_din, .sd_buff_wr,
    .busy(disk_busy), .irq(scsi_irq), .dbg(dbg_scsi), .dbg_blocks
  );

  // ---------------------------------------------------------------- 82586 Ethernet
  // Its pins are a latch at 0x04016000 that reads back in bits 7:5.
  logic        eth_pins_we, eth_busy, eth_req, eth_we, eth_hi, eth_ack;
  logic [7:0]  eth_pins;
  logic [14:0] eth_word;
  logic [1:0]  eth_be;
  logic [15:0] eth_wdata;
  xl_i82586 ether (
    .clk, .reset, .pins_we(eth_pins_we), .pins(eth_pins), .busy(eth_busy), .irq(ether_irq),
    .m_req(eth_req), .m_we(eth_we), .m_word(eth_word), .m_hi(eth_hi), .m_be(eth_be), .m_wdata(eth_wdata),
    .m_ack(eth_ack), .m_rdata(buf_rdata),
    .tx_push, .tx_stp, .tx_be, .tx_d, .tx_enp, .tx_len, .tx_crcgen, .tx_clr, .tx_busy,
    .rx_pop, .rx_clr, .rx_d, .rx_deof, .rx_fifordy, .rx_len, .rx_lpbk, .rx_prom, .rx_padr, .rx_ladrf
  );

  logic       con_rx;          // a byte from the processor to the console
  logic [7:0] con_rx_byte;
  logic       con_pending, con_pop;
  logic [7:0] con_byte;
  xl_console console (
    .clk, .reset,
    .key_strobe, .key_down, .key_code,
    .mouse_strobe, .mouse_buttons, .mouse_dx, .mouse_dy,
    .rx_strobe(con_rx), .rx_byte(con_rx_byte),
    .tx_pending(con_pending), .tx_byte(con_byte), .tx_pop(con_pop)
  );

  logic        vm_req, vm_ack;
  logic [31:0] vm_rdata;
  logic        sync_ir_we, sync_cmd_we;
  logic [7:0]  sync_wdata;
  logic [31:0] video_control;
  logic [9:0]  vid_scanline;
  logic        vid_retrace;
  xl_video video (
    .clk, .reset,
    .vm_req, .vm_we(cpu_we), .vm_addr(cpu_addr[15:0]), .vm_wdata(cpu_wdata), .vm_ack, .vm_rdata,
    .ir_we(sync_ir_we), .cmd_we(sync_cmd_we), .wdata(sync_wdata), .control(video_control),
    .scanline(vid_scanline), .retrace(vid_retrace),
    .debug, .dbg, .dbg_video,
    .clk_vid, .white, .hs, .vs, .hblank, .vblank,
    .r_hc, .r_px, .r_vc, .r_h_total, .r_v_visible, .r_v_total, .r_run
  );
  assign r_retrace = vid_retrace;

  // Video counters as the processor reads them.  The model's: a "frame
  // counter" of instructions / 64, retrace for 40 of each 1024.
  wire [9:0] scanline = LOCKSTEP ? ticks[15:6] : vid_scanline;
  wire       retrace = LOCKSTEP ? ticks[15:6] < 10'd40 : vid_retrace;

  // ---------------------------------------------------------------- DUSCC
  // Its 64 registers live in a RAM (an MLAB), not in flops: the processor
  // writes them and reads them back through the polled latch, and nothing
  // else looks at them. No reset, so the array infers as RAM; the FEP
  // programs every register it uses, and the initial block covers the
  // simulator and the power-up contents. The read lands in duscc_q the
  // cycle after the address is on the bus, so the latch takes it in I_ACK.
  logic [7:0] duscc [64];
  initial for (int i = 0; i < 64; i++) duscc[i] = 8'h00;
  logic [7:0] duscc_q;
  logic       duscc_rd, duscc_gsr;
  wire        duscc_sel = ist == I_IDLE && cpu_req && !reset && !is_buffer && !is_video && is_8bit && cpu_we;
  always_ff @(posedge clk) begin
    if (duscc_sel && port == 4'h0) duscc[r8[5:0]] <= cpu_wdata[7:0];
    duscc_q <= duscc[r8[5:0]];
  end

  // ---------------------------------------------------------------- AM9517
  logic [15:0] dma_base_addr [4], dma_base_count [4], dma_cur_addr [4], dma_count [4];
  logic [7:0]  dma_mode [4];
  logic [3:0]  dma_masked;
  logic        dma_ff;
  logic [7:0]  dma_command, dma_status;

  // ---------------------------------------------------------------- board registers
  logic [31:0] dma_control;      // 0x04015000 (bit 3 holds the WD33C93 in reset)
  logic [31:0] scsi_window;      // 0x0401A000
  logic [17:0] dma_byte_addr;    // SCSI DMA byte address in the buffer
  logic [31:0] reg_4800, reg_5800, reg_28000;
  logic [7:0]  polled_latch;

  // ---------------------------------------------------------------- buffer memory
  // Clients: console DMA, SCSI DMA, the 82586, the processor (in that order).
  typedef enum logic [2:0] { BC_NONE, BC_CON, BC_SCSI, BC_ETH, BC_CPU } bclient_t;
  bclient_t    bc;
  logic        con_dma;          // a console byte to store
  logic [15:0] con_dma_word;
  logic [1:0]  con_dma_lane;
  logic [7:0]  con_dma_byte;
  logic        cpu_buf;          // the processor waits for the buffer
  logic        cpu_buf_done;
  logic [31:0] cpu_buf_data;
  // SCSI DMA reads keep the last word read
  logic        sr_valid;
  logic [15:0] sr_word;
  logic [31:0] sr_data;
  wire  [15:0] s_word = dma_byte_addr[17:2];
  wire         s_hit = !sdma_we && sr_valid && sr_word == s_word;

  always_comb begin
    buf_req = bc != BC_NONE;
    buf_we = 1'b1; buf_addr = s_word; buf_be = 4'b0001 << dma_byte_addr[1:0];
    buf_wdata = {4{sdma_wdata}};
    case (bc)
      BC_CON: begin
        buf_addr = con_dma_word; buf_be = 4'b0001 << con_dma_lane; buf_wdata = {4{con_dma_byte}};
      end
      BC_SCSI: buf_we = sdma_we;
      BC_ETH: begin
        buf_we = eth_we; buf_addr = {1'b0, eth_word}; buf_be = eth_hi ? {eth_be, 2'b00} : {2'b00, eth_be};
        buf_wdata = {eth_wdata, eth_wdata};
      end
      BC_CPU: begin
        buf_we = cpu_we; buf_addr = cpu_addr[15:0]; buf_be = 4'hF; buf_wdata = cpu_wdata;
      end
      default: ;
    endcase
  end
  assign sdma_ack = (bc == BC_SCSI && buf_ack) || (sdma_req && bc == BC_NONE && s_hit);
  assign sdma_rdata = (bc == BC_SCSI) ? buf_rdata[8 * dma_byte_addr[1:0] +: 8] : sr_data[8 * dma_byte_addr[1:0] +: 8];
  assign eth_ack = bc == BC_ETH && buf_ack;
  assign dma_busy = con_dma || bc == BC_CON || eth_busy;

  always_ff @(posedge clk) begin
    if (reset) begin
      bc <= BC_NONE;
      sr_valid <= 1'b0;
      cpu_buf_done <= 1'b0;
    end else begin
      cpu_buf_done <= 1'b0;
      case (bc)
        BC_NONE:
          if (con_dma) bc <= BC_CON;
          else if (sdma_req && !s_hit) bc <= BC_SCSI;
          else if (eth_req && !eth_ack) bc <= BC_ETH;
          else if (cpu_buf && !cpu_buf_done) bc <= BC_CPU;
        default:
          if (buf_ack) begin
            if (bc == BC_SCSI && !sdma_we) begin
              sr_valid <= 1'b1; sr_word <= s_word; sr_data <= buf_rdata;
            end else if (buf_we) sr_valid <= 1'b0;
            if (bc == BC_CPU) begin cpu_buf_done <= 1'b1; cpu_buf_data <= buf_rdata; end
            bc <= BC_NONE;
          end
      endcase
    end
  end

  // ---------------------------------------------------------------- console link timing
  // The link runs at about 75 kbit/s: a byte every ~150 us (600 instructions
  // in the model).
  localparam int CON_GAP = LOCKSTEP ? 600 : 150;
  logic [9:0] con_wait;

  // ---------------------------------------------------------------- processor accesses
  typedef enum logic [2:0] { I_IDLE, I_BUF, I_VID, I_WD, I_ACK } istate_t;
  istate_t ist;
  wire [27:0] off = cpu_addr;
  wire        is_buffer = off < 28'h0010000;
  wire        is_video = off[27:16] == 12'h800;
  wire        is_8bit = off[27:12] == 16'h4017;
  wire [3:0]  port = off[11:8];
  wire [7:0]  r8 = off[7:0];

  assign vm_req = ist == I_VID;
  assign cpu_buf = ist == I_BUF;
  assign wd_req = ist == I_WD;
  assign cpu_ack = ist == I_ACK;

  always_ff @(posedge clk) begin
    wd_mr <= 1'b0;
    con_rx <= 1'b0;
    con_pop <= 1'b0;
    sync_ir_we <= 1'b0;
    sync_cmd_we <= 1'b0;
    eth_pins_we <= 1'b0;
    if (reset) begin
      ist <= I_IDLE;
      duscc_rd <= 1'b0;
      for (int i = 0; i < 4; i++) begin
        dma_base_addr[i] <= '0; dma_base_count[i] <= '0; dma_cur_addr[i] <= '0; dma_count[i] <= '0;
        dma_mode[i] <= '0;
      end
      dma_masked <= 4'hF;
      dma_ff <= 1'b0;
      dma_command <= '0;
      dma_status <= '0;
      dma_control <= 32'hB7;
      scsi_window <= '0;
      dma_byte_addr <= '0;
      {reg_4800, reg_5800, reg_28000} <= '0;
      video_control <= '0;
      eth_pins <= '0;
      polled_latch <= '0;
      con_dma <= 1'b0;
      con_wait <= '0;
    end else begin
      // ---- console bytes into buffer memory (AM9517 channel 0); byte
      // address bit 16 comes from bit 5 of the board control register
      if (con_dma && bc == BC_CON && buf_ack) con_dma <= 1'b0;
      if (tick) begin
        if (con_wait == 10'd0 && con_pending && !dma_masked[0] && !con_dma) begin
          logic [16:0] a;
          a = {dma_control[5], dma_cur_addr[0]};
          con_dma <= 1'b1;
          con_dma_word <= {1'b0, a[16:2]};
          con_dma_lane <= a[1:0];
          con_dma_byte <= con_byte;
          con_pop <= 1'b1;
          dma_cur_addr[0] <= dma_mode[0][5] ? dma_cur_addr[0] - 16'd1 : dma_cur_addr[0] + 16'd1;
          dma_count[0] <= dma_count[0] - 16'd1;
          if (dma_count[0] == 16'd0) begin
            dma_status[0] <= 1'b1;
            if (dma_mode[0][4]) begin   // autoinitialize
              dma_cur_addr[0] <= dma_base_addr[0];
              dma_count[0] <= dma_base_count[0];
            end else dma_masked[0] <= 1'b1;
          end
          con_wait <= 10'(CON_GAP - 1);
        end else if (con_wait != 10'd0) con_wait <= con_wait - 10'd1;
      end

      // ---- SCSI DMA address
      if (sdma_ack) dma_byte_addr <= dma_byte_addr + 18'd1;

      case (ist)
        I_IDLE: if (cpu_req) begin
          cpu_rdata <= 32'd0;
          if (is_buffer) ist <= I_BUF;
          else if (is_video) ist <= I_VID;
          else if (is_8bit && (port == 4'h8 || port == 4'h9)) begin
            // a write to 0x800+r writes WD33C93 register r; to 0x900+r reads
            // it into the latch; reads anywhere return the latch
            wd_we <= port == 4'h8;
            wd_addr <= r8[4:0];
            wd_wdata <= cpu_wdata[7:0];
            ist <= cpu_we ? I_WD : I_ACK;
            if (!cpu_we) cpu_rdata <= {24'd0, polled_latch};
          end else begin
            ist <= I_ACK;
            if (!cpu_we) begin
              // ---- register reads
              if (is_8bit) cpu_rdata <= {24'd0, polled_latch};
              else if (off == 28'h4016000) cpu_rdata <= {16'd0, IDPROM[7:0], eth_pins[7:5], 5'd0};
              else if (off[27:5] == 23'(28'h4016000 >> 5)) cpu_rdata <= {16'd0, IDPROM[8 * off[4:0] +: 8], 8'd0};
              else if (off >= 28'h1008000 && off < 28'h1008006) cpu_rdata <= {16'd0, IDPROM[8 * (5'd16 + 5'(off[2:0])) +: 8], 8'd0};
              else case (off)
                28'h4015000: cpu_rdata <= dma_control;
                28'h4020000: cpu_rdata <= 32'h02;          // DP8466: ready (no ESDI drives)
                28'h4024000: cpu_rdata <= {22'd0, scanline};
                28'h402C000: cpu_rdata <= video_control | {retrace, 31'd0};
                28'h4014800: cpu_rdata <= reg_4800;
                28'h4015800: cpu_rdata <= reg_5800;
                28'h4028000: cpu_rdata <= reg_28000;
                default: ;
              endcase
            end else begin
              // ---- register writes
              if (is_8bit) begin
                case (port)
                  4'h0: begin   // DUSCC write (the RAM above); channel A transmit FIFO goes to the console
                    if (r8[5:0] >= 6'h10 && r8[5:0] <= 6'h13) begin
                      con_rx <= 1'b1; con_rx_byte <= cpu_wdata[7:0];
                    end
                  end
                  4'h1: begin    // DUSCC read into the latch (in I_ACK, from duscc_q); GSR says channel A transmitter ready
                    duscc_rd <= 1'b1;
                    duscc_gsr <= r8[5:0] == 6'h1B;
                  end
                  4'h2: begin   // AM9517 write: a byte of a base register (and its current copy)
                    logic [3:0] r;
                    logic [15:0] nb;
                    r = r8[3:0];
                    nb = r[0] ? dma_base_count[r[2:1]] : dma_base_addr[r[2:1]];
                    if (dma_ff) nb[15:8] = cpu_wdata[7:0]; else nb[7:0] = cpu_wdata[7:0];
                    if (!r[3]) begin
                      if (r[0]) begin dma_base_count[r[2:1]] <= nb; dma_count[r[2:1]] <= nb; end
                      else begin dma_base_addr[r[2:1]] <= nb; dma_cur_addr[r[2:1]] <= nb; end
                      dma_ff <= !dma_ff;
                    end else case (r)
                      4'h8: dma_command <= cpu_wdata[7:0];
                      4'hA: dma_masked[cpu_wdata[1:0]] <= cpu_wdata[2];
                      4'hB: dma_mode[cpu_wdata[1:0]] <= cpu_wdata[7:0];
                      4'hC: dma_ff <= 1'b0;
                      4'hD: begin dma_ff <= 1'b0; dma_status <= 8'h00; dma_command <= 8'h00; dma_masked <= 4'hF; end
                      4'hE: dma_masked <= 4'h0;
                      4'hF: dma_masked <= cpu_wdata[3:0];
                      default: ;
                    endcase
                  end
                  4'h3: begin   // AM9517 read
                    logic [3:0] r;
                    logic [15:0] v;
                    r = r8[3:0];
                    v = r[0] ? dma_count[r[2:1]] : dma_cur_addr[r[2:1]];
                    if (!r[3]) begin
                      polled_latch <= dma_ff ? v[15:8] : v[7:0];
                      dma_ff <= !dma_ff;
                    end else if (r == 4'h8) begin
                      polled_latch <= dma_status;
                      dma_status <= dma_status & 8'hF0;
                    end else polled_latch <= 8'h00;
                  end
                  default: ;
                endcase
              end else case (off)
                28'h4015000: begin
                  if (dma_control[3] && !cpu_wdata[3]) wd_mr <= 1'b1;
                  dma_control <= cpu_wdata;
                end
                // SCSI DMA: 0x0401A000 = buffer window in 4K-word pages (start
                // page bits 2:0), 0x0401B800 = low 12 bits of the word address
                28'h4016000: begin eth_pins <= cpu_wdata[7:0]; eth_pins_we <= 1'b1; end
                28'h401A000: scsi_window <= cpu_wdata;
                28'h401B800: dma_byte_addr <= {1'b0, scsi_window[2:0], cpu_wdata[11:0], 2'b00};
                28'h402C000: video_control <= cpu_wdata;
                28'h402D000: begin sync_ir_we <= 1'b1; sync_wdata <= cpu_wdata[7:0]; end
                28'h402D001: begin sync_cmd_we <= 1'b1; sync_wdata <= cpu_wdata[7:0]; end
                28'h4014800: reg_4800 <= cpu_wdata;
                28'h4015800: reg_5800 <= cpu_wdata;
                28'h4028000: reg_28000 <= cpu_wdata;
                default: ;
              endcase
            end
          end
        end

        I_BUF: if (cpu_buf_done) begin cpu_rdata <= cpu_buf_data; ist <= I_ACK; end
        I_VID: if (vm_ack) begin cpu_rdata <= vm_rdata; ist <= I_ACK; end
        I_WD: if (wd_ack) begin
          if (!wd_we) polled_latch <= wd_rdata;
          ist <= I_ACK;
        end
        I_ACK: begin
          if (duscc_rd) begin
            polled_latch <= duscc_gsr ? 8'h02 : duscc_q;
            duscc_rd <= 1'b0;
          end
          ist <= I_IDLE;
        end
        default: ist <= I_IDLE;
      endcase
    end
  end

endmodule
