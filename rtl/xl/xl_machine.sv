// Symbolics XL1200: the Ivory processor on the Merlin-II main board (memory,
// boot PROM, NVRAM and clock, board registers) with Merlin I/O board 0.
// The physical address map follows emu/machine.cpp (docs/NOTES.md,
// "Physical address map").
//
// Device time: the I/O board and the microsecond clock count microseconds of
// clk (CLK_HZ), or with LOCKSTEP instructions, as the reference model does
// (four instructions a microsecond), so the Verilator testbench can run the
// machine in lockstep with emu/.
module xl_machine #(
  parameter int    NT = 2,                 // SCSI disk targets
  parameter bit    LOCKSTEP = 1'b0,
  parameter bit    MEM_CLEAR = 1'b1,       // clear DDR3 memory at power-up
  parameter int    CLK_HZ = 50_000_000,   // no part slower than the real machine (docs/ivory.md)
  parameter bit    NET_SIMU = 1'b0,       // short network mailbox timers (benches)
  parameter        PROM_FILE = "boot_prom.mem"
) (
  input  logic        clk,
  input  logic        clk_vid,
  input  logic        power_on,            // first reset after configuration
  input  logic        reset,
  input  logic        fw_reset,            // the framework's RESET (a core loading, Main restarting), clk-synchronous

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

  // console
  input  logic        key_strobe,
  input  logic        key_down,
  input  logic [6:0]  key_code,
  input  logic        mouse_strobe,
  input  logic [2:0]  mouse_buttons,
  input  logic signed [9:0] mouse_dx,
  input  logic signed [9:0] mouse_dy,
  input  logic [64:0] rtc,
  input  logic        rtc_back28,
  input  logic        net_ena,             // the OSD's Network is not Off

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

  // display (clk_vid)
  output logic        white,
  output logic        hs,
  output logic        vs,
  output logic        hblank,
  output logic        vblank,
  output logic [23:0] rgb,             // the color board's picture on the same raster
  output logic        video_on,        // the board's video enable (clk)

  // lights and status
  output logic        run_light,
  output logic        disk_light,
  output logic        halted,
  output logic [7:0]  halt_reason,
  output logic        retire,
  output logic [63:0] insn_count,
  input  logic        debug,           // hex status line at the top of the picture
  output logic [31:0] dbg [8]          // the words it shows
);
  import ivory_pkg::*;

  // ---------------------------------------------------------------- processor
  // The processor with its MMU; every bus address is physical.
  logic        mem_req, mem_we, mem_ack, mem_buserr;
  logic [31:0] mem_addr;
  word_t       mem_wdata, mem_rdata;
  logic        cop_req, cop_we, cop_ack;
  logic [9:0]  cop_reg;
  word_t       cop_wdata, cop_rdata;
  logic [31:0] usec /*verilator public_flat_rd*/;
  logic        mem_ready /*verilator public_flat_rd*/, mem_busy;
  logic        retire_counted;
  logic        hp_sb, lp_sb;

  ivory_core core (
    .clk, .reset, .run(mem_ready && vme_ready), .hold(LOCKSTEP && retire),
    .bus_req(mem_req), .bus_we(mem_we), .bus_addr(mem_addr), .bus_wdata(mem_wdata),
    .bus_ack(mem_ack), .bus_rdata(mem_rdata), .bus_buserr(mem_buserr), .bus_busy(mem_busy),
    .cop_req, .cop_we, .cop_reg, .cop_wdata, .cop_ack, .cop_rdata, .cop_err(1'b0),
    .hp_sb, .lp_sb, .reset_req(1'b0), .hp_sb_taken(), .lp_sb_taken(),
    .usec_clock(usec_now),
    .retire, .retire_counted, .halted,
    .trap_mode(trap_mode), .insn_count, .halt_reason, .dbg_pc(cpu_pc)
  );
  logic [1:0]  trap_mode;
  logic [31:0] cpu_pc;

  // ---------------------------------------------------------------- time
  logic [33:0] ticks;           // LOCKSTEP: instructions so far (the microsecond clock is a quarter)
  // A microsecond every CLK_HZ / 1e6 cycles, fractional: the accumulator
  // gains a million a cycle and ticks when it passes the clock rate.
  logic [26:0] usec_acc;
  logic        usec_tick;
  logic [19:0] sec_div;
  logic        second;
  always_ff @(posedge clk) begin
    usec_tick <= 1'b0;
    second <= 1'b0;
    if (LOCKSTEP) begin
      if (retire) begin
        ticks <= ticks + 34'd1;
        if (ticks[1:0] == 2'd3) usec_tick <= 1'b1;
      end
    end else if (usec_acc + 27'd1_000_000 >= 27'(CLK_HZ)) begin
      usec_acc <= usec_acc + 27'd1_000_000 - 27'(CLK_HZ);
      usec_tick <= 1'b1;
    end else usec_acc <= usec_acc + 27'd1_000_000;
    if (usec_tick) begin
      usec <= usec + 32'd1;
      if (sec_div == 20'd999999) begin sec_div <= 20'd0; second <= 1'b1; end
      else sec_div <= sec_div + 20'd1;
    end
    if (power_on) begin
      ticks <= '0; usec_acc <= '0; usec <= '0; sec_div <= '0;
    end
  end
  wire        dev_tick = LOCKSTEP ? retire : usec_tick;
  wire [31:0] usec_now = LOCKSTEP ? ticks[33:2] : usec;

  // ---------------------------------------------------------------- address decode
  logic        iob_dma_busy;
  wire         req = mem_req && !(LOCKSTEP && iob_dma_busy);
  wire  [31:0] pa = mem_addr;
  // Main memory: 4 MW on the main board at 0 and a 4 MW board in each of the
  // three expansion slots the FEP probes, at 0x10000000, 0x20000000 and
  // 0x30000000 (16 MW, the XL1200's most); DDR3 word {slot, offset}.
  wire         sel_ram   = pa[31:30] == 2'd0 && pa[27:22] == 6'd0;
  wire         sel_prom  = pa[31:16] == 16'h07FE;
  wire         sel_pit   = pa[31:2] == 30'(32'h0800_0000 >> 2);
  wire         sel_nvram = pa[31:11] == 21'(32'h0900_0000 >> 11);
  wire         sel_mb    = pa[31:4] == 28'h0A0_0000;
  wire         sel_vme   = pa[31];                 // the VMEbus interface and bus
  wire         sel_iob   = pa[31:28] == 4'h4;
  wire         sel_none  = !(sel_ram || sel_prom || sel_pit || sel_nvram || sel_mb || sel_vme || sel_iob);

  logic        dev_ack;
  logic        buf_req, buf_we, buf_ack;
  logic [15:0] buf_addr;
  logic [3:0]  buf_be;
  logic [31:0] buf_wdata, buf_rdata;

  // main memory
  logic        ram_ack;
  logic [39:0] ram_rdata;
  logic [3:0] mem_state;
  xl_mem #(.CLEAR(MEM_CLEAR), .RAM_AW(24), .RAM_BASE(29'h0600_0000), .BUF_BASE(29'h0700_0000)) mem (
    .clk, .init(power_on), .ready(mem_ready), .busy(mem_busy), .dbg_state(mem_state),
    .cpu_req(req && sel_ram), .cpu_we(mem_we), .cpu_addr({pa[29:28], pa[21:0]}), .cpu_wdata(mem_wdata),
    .cpu_ack(ram_ack), .cpu_rdata(ram_rdata),
    .buf_req, .buf_we, .buf_addr, .buf_be, .buf_wdata, .buf_ack, .buf_rdata,
    .ddr_addr(m0_addr), .ddr_burstcnt(m0_burstcnt), .ddr_rd(m0_rd), .ddr_we(m0_we), .ddr_din(m0_din),
    .ddr_be(m0_be), .ddr_dout(ddr_dout), .ddr_dout_ready(m0_dout_ready), .ddr_busy(m0_busy)
  );

  // The DDR port's masters: the memory, the network (the 82586's frames
  // cross a mailbox in DDR3 to Main_MiSTer's bridge, xl_eth_hps) and the
  // color board, whose line fetches go first so the picture never waits.
  logic        m0_rd, m0_we, m0_dout_ready, m0_busy;
  logic [28:0] m0_addr;
  logic [7:0]  m0_burstcnt, m0_be;
  logic [63:0] m0_din;
  logic        m1_rd, m1_we, m1_dout_ready, m1_busy;
  logic [28:0] m1_addr;
  logic [7:0]  m1_burstcnt, m1_be;
  logic [63:0] m1_din;
  logic        m2_rd, m2_we, m2_dout_ready, m2_busy;
  logic [28:0] m2_addr;
  logic [7:0]  m2_burstcnt, m2_be;
  logic [63:0] m2_din;
  logic        lo_rd, lo_we, lo_dout_ready, lo_busy;
  logic [28:0] lo_addr;
  logic [7:0]  lo_burstcnt, lo_be;
  logic [63:0] lo_din;
  ddram_arb arb_lo (
    .clk, .reset(power_on),
    .m0_waitrequest(m0_busy), .m0_burstcount(m0_burstcnt), .m0_address(m0_addr), .m0_read(m0_rd),
    .m0_write(m0_we), .m0_writedata(m0_din), .m0_byteenable(m0_be), .m0_readdata(), .m0_readdatavalid(m0_dout_ready),
    .m1_waitrequest(m1_busy), .m1_burstcount(m1_burstcnt), .m1_address(m1_addr), .m1_read(m1_rd),
    .m1_write(m1_we), .m1_writedata(m1_din), .m1_byteenable(m1_be), .m1_readdata(), .m1_readdatavalid(m1_dout_ready),
    .s_waitrequest(lo_busy), .s_burstcount(lo_burstcnt), .s_address(lo_addr), .s_read(lo_rd),
    .s_write(lo_we), .s_writedata(lo_din), .s_byteenable(lo_be), .s_readdata(ddr_dout), .s_readdatavalid(lo_dout_ready)
  );
  logic        a_rd, a_we, a_busy;
  logic [28:0] a_addr;
  logic [7:0]  a_burstcnt, a_be;
  logic [63:0] a_din;
  ddram_arb arb_hi (
    .clk, .reset(power_on),
    .m0_waitrequest(m2_busy), .m0_burstcount(m2_burstcnt), .m0_address(m2_addr), .m0_read(m2_rd),
    .m0_write(m2_we), .m0_writedata(m2_din), .m0_byteenable(m2_be), .m0_readdata(), .m0_readdatavalid(m2_dout_ready),
    .m1_waitrequest(lo_busy), .m1_burstcount(lo_burstcnt), .m1_address(lo_addr), .m1_read(lo_rd),
    .m1_write(lo_we), .m1_writedata(lo_din), .m1_byteenable(lo_be), .m1_readdata(), .m1_readdatavalid(lo_dout_ready),
    .s_waitrequest(a_busy), .s_burstcount(a_burstcnt), .s_address(a_addr), .s_read(a_rd),
    .s_write(a_we), .s_writedata(a_din), .s_byteenable(a_be), .s_readdata(ddr_dout), .s_readdatavalid(ddr_dout_ready)
  );

  // The framework's RESET (another core loading, or Main restarting: from
  // the menu the official Main releases it, then restarts as MiSTer_xl1200
  // and raises it again) must not cut a DDR3 transaction: MiSTer's safe
  // terminator completes the one under way.  While RESET is up it forwards
  // nothing else but still passes the port's waitrequest back, so a command
  // started then would look taken and never be answered; the arbiter would
  // then give each later read's data to the master before it (the color
  // board fetches lines whenever the raster runs, so one was always there).
  // So no new command starts while RESET is up or for a while after (the
  // terminator may still be finishing a burst): a command already waiting,
  // or the rest of a write burst, goes on.
  logic        g_pending, g_burst;
  logic [7:0]  g_left;
  logic [9:0]  g_quiet;
  logic        g_rd, g_we, g_busy;
  wire         g_hold = (fw_reset || g_quiet != 10'd0) && !g_pending && !g_burst;
  assign g_rd = a_rd && !g_hold;
  assign g_we = a_we && !g_hold;
  assign a_busy = g_hold || g_busy;
  always_ff @(posedge clk) begin
    g_pending <= (g_rd || g_we) && g_busy;
    if (g_we && !g_busy) begin
      if (!g_burst) begin
        g_burst <= a_burstcnt > 8'd1;
        g_left <= a_burstcnt - 8'd1;
      end else begin
        g_left <= g_left - 8'd1;
        if (g_left == 8'd1) g_burst <= 1'b0;
      end
    end
    g_quiet <= fw_reset ? 10'd1023 : g_quiet - 10'(g_quiet != 10'd0);
    if (power_on) begin g_pending <= 1'b0; g_burst <= 1'b0; g_quiet <= 10'd0; end
  end
  f2sdram_safe_terminator #(.DATA_WIDTH(64), .BURSTCOUNT_WIDTH(8)) ddr_terminator (
    .clk, .rst_req_sync(fw_reset),
    .waitrequest_master(ddr_busy), .burstcount_master(ddr_burstcnt), .address_master(ddr_addr),
    .readdata_master(ddr_dout), .readdatavalid_master(ddr_dout_ready), .read_master(ddr_rd),
    .writedata_master(ddr_din), .byteenable_master(ddr_be), .write_master(ddr_we),
    .waitrequest_slave(g_busy), .burstcount_slave(a_burstcnt), .address_slave(a_addr),
    .readdata_slave(), .readdatavalid_slave(), .read_slave(g_rd),
    .writedata_slave(a_din), .byteenable_slave(a_be), .write_slave(g_we)
  );
  logic        tx_push, tx_stp, tx_enp, tx_crcgen, tx_clr, tx_busy, tx_fifordy;
  logic [1:0]  tx_be;
  logic [15:0] tx_d;
  logic [11:0] tx_len, rx_len;
  logic        rx_pop, rx_clr, rx_deof, rx_fifordy, rx_crcok, rx_eof, rx_lpbk, rx_prom;
  logic [15:0] rx_d;
  logic [47:0] rx_padr;
  logic [63:0] rx_ladrf;
  xl_eth_hps #(.CLK_HZ(CLK_HZ), .SIMU(NET_SIMU)) eth (
    .clk, .rst(reset), .ena(net_ena),
    .tx_push, .tx_stp, .tx_be, .tx_d, .tx_enp, .tx_len, .tx_crcgen, .tx_clr, .tx_fifordy, .tx_busy,
    .rx_pop, .rx_clr, .rx_d, .rx_deof, .rx_fifordy, .rx_len, .rx_crcok, .rx_eof,
    .rx_lpbk, .rx_prom, .rx_padr, .rx_ladrf,
    .avl_waitrequest(m1_busy), .avl_address(m1_addr), .avl_read(m1_rd), .avl_write(m1_we),
    .avl_writedata(m1_din), .avl_byteenable(m1_be), .avl_burstcount(m1_burstcnt),
    .avl_readdata(ddr_dout), .avl_readdatavalid(m1_dout_ready)
  );
  // boot PROM: the stand-in (tools/bootprom.py) in its first 512 words; the
  // rest reads as fixnum 0
  word_t prom [512];
  word_t prom_q;
  logic  prom_hi;
  initial $readmemh(PROM_FILE, prom);
  always_ff @(posedge clk) begin
    prom_q <= prom[pa[8:0]];
    prom_hi <= pa[15:9] != 7'd0;
  end

  // NVRAM and clock
  logic       nv_ack;
  logic [7:0] nv_rdata;
  xl_nvram nvram (
    .clk, .second, .rtc, .back28(rtc_back28),
    .req(req && sel_nvram), .we(mem_we), .addr(pa[10:0]), .wdata(mem_wdata[7:0]),
    .ack(nv_ack), .rdata(nv_rdata)
  );

  // Merlin-II registers (words 0x0A000000 + 0, 4, 8, C): control (bit 1 =
  // run light), cache control, ECO levels (one nibble per slot: main board 1
  // and I/O board 0 5 as the reference XL1201's, the three memory boards 1,
  // F = empty; the FEP and Genera's find-merlin-boards take a memory board's
  // slot from its nibble), interrupts (reads give the pending sources, writes
  // set the mask; i-sys/io-register-definitions)
  localparam logic [31:0] ECO_REGISTER = 32'hFFF5_1111;
  logic [31:0] mb_reg [3];
  logic [31:0] int_mask;

  // 82C54 timer (1 MHz; in lockstep, every 4 instructions as in the model,
  // on the edge the instruction retires so the next one sees its outputs)
  logic [2:0]  pit_out;
  xl_pit pit (
    .clk, .reset,
    .tick(LOCKSTEP ? retire && ticks[1:0] == 2'd3 : usec_tick),
    .we(req && sel_pit && mem_we && !dev_ack), .reg_n(pa[1:0]), .wdata(mem_wdata[7:0]),
    .out(pit_out)
  );

  // Interrupt sources: 0 timer 2 (periodic), 1 timers 1 and 0 (interval; the
  // only low-priority one), 8 SCSI controller, 18 Ethernet
  logic        scsi_irq, ether_irq;
  wire  [31:0] int_pending = {13'd0, ether_irq, 9'd0, scsi_irq, 6'd0, pit_out[0], pit_out[2]};
  wire  [31:0] int_on = int_pending & int_mask;
  assign hp_sb = (int_on & ~32'd2) != 32'd0;
  assign lp_sb = int_on[1];
  // The VMEbus interface, with the color board on the bus (its memory in
  // DDR3 behind the port's third master)
  logic        vme_ack, vme_buserr, vme_ready;
  logic [31:0] vme_rdata;
  logic [7:0]  r_hc, r_h_total;
  logic [4:0]  r_px;
  logic [10:0] r_vc, r_v_visible, r_v_total;
  logic        r_run, r_retrace;
  xl_vme #(.CLEAR(MEM_CLEAR), .MEM_BASE(29'h0710_0000)) vme (
    .clk, .reset, .init(power_on), .ready(vme_ready),
    .cpu_req(req && sel_vme), .cpu_we(mem_we), .cpu_addr(pa), .cpu_wdata(mem_wdata[31:0]),
    .cpu_ack(vme_ack), .cpu_buserr(vme_buserr), .cpu_rdata(vme_rdata),
    .ddr_addr(m2_addr), .ddr_burstcnt(m2_burstcnt), .ddr_rd(m2_rd), .ddr_we(m2_we), .ddr_din(m2_din),
    .ddr_be(m2_be), .ddr_dout(ddr_dout), .ddr_dout_ready(m2_dout_ready), .ddr_busy(m2_busy),
    .clk_vid, .hc(r_hc), .px(r_px), .vc(r_vc), .h_total(r_h_total), .v_visible(r_v_visible), .v_total(r_v_total),
    .run_v(r_run), .retrace(r_retrace), .rgb, .video_on
  );

  // I/O board
  logic        iob_ack;
  logic [31:0] iob_rdata;
  xl_iob #(.NT(NT), .LOCKSTEP(LOCKSTEP)) iob (
    .clk, .reset, .tick(dev_tick), .ticks(ticks[31:0]),
    .cpu_req(req && sel_iob), .cpu_we(mem_we), .cpu_addr(pa[27:0]), .cpu_wdata(mem_wdata[31:0]),
    .cpu_ack(iob_ack), .cpu_rdata(iob_rdata), .dma_busy(iob_dma_busy), .scsi_irq, .ether_irq,
    .buf_req, .buf_we, .buf_addr, .buf_be, .buf_wdata, .buf_ack, .buf_rdata,
    .tx_push, .tx_stp, .tx_be, .tx_d, .tx_enp, .tx_len, .tx_crcgen, .tx_clr, .tx_busy,
    .rx_pop, .rx_clr, .rx_d, .rx_deof, .rx_fifordy, .rx_len, .rx_lpbk, .rx_prom, .rx_padr, .rx_ladrf,
    .key_strobe, .key_down, .key_code, .mouse_strobe, .mouse_buttons, .mouse_dx, .mouse_dy,
    .img_mounted, .img_readonly, .img_size, .sd_lba, .sd_blk_cnt, .sd_rd, .sd_wr, .sd_ack,
    .sd_buff_addr, .sd_buff_dout, .sd_buff_din, .sd_buff_wr, .disk_busy(disk_light),
    .clk_vid, .white, .hs, .vs, .hblank, .vblank,
    .r_hc, .r_px, .r_vc, .r_h_total, .r_v_visible, .r_v_total, .r_run, .r_retrace,
    .debug, .dbg, .dbg_scsi, .dbg_blocks, .dbg_video
  );

  // Debug line: instructions, PC, {halt reason, halted, memory ready and
  // state, trap mode, display frames}, microseconds, SCSI {targets present,
  // engine, ASR, opcode}, target 0's blocks, video {control, display on, IR
  // pointer, image reads}, {image mounts, machine resets, returns to the
  // boot PROM's entry}.
  logic [31:0] dbg_scsi, dbg_blocks, dbg_video;
  logic [15:0] sd_reads;
  logic [7:0]  mounts, resets;
  logic [15:0] prom_entries;
  logic [NT-1:0] sd_rd_q;
  logic        reset_q;
  always_ff @(posedge clk) begin
    sd_rd_q <= sd_rd;
    reset_q <= reset;
    if (|(sd_rd & ~sd_rd_q)) sd_reads <= sd_reads + 16'd1;
    if (|img_mounted) mounts <= mounts + 8'd1;
    if (reset && !reset_q) resets <= resets + 8'd1;
    if (retire && cpu_pc == 32'hFFFE0040) prom_entries <= prom_entries + 16'd1;
    dbg[0] <= insn_count[31:0];
    dbg[1] <= cpu_pc;
    dbg[2] <= {halt_reason, 3'd0, halted, 3'd0, mem_ready, mem_state, 2'd0, trap_mode, dbg_video[15:8]};
    dbg[3] <= usec_now;
    dbg[4] <= dbg_scsi;
    dbg[5] <= dbg_blocks;
    dbg[6] <= {dbg_video[31:16], sd_reads};
    dbg[7] <= {mounts, resets, prom_entries};
  end

  // The simple targets (PROM, timer, main board, nothing) answer a cycle
  // after the request; writes take effect then.
  wire  sel_simple = sel_prom || sel_pit || sel_mb || sel_none;
  always_ff @(posedge clk) begin
    dev_ack <= req && sel_simple && !dev_ack;
    if (reset) begin
      for (int i = 0; i < 3; i++) mb_reg[i] <= 32'd0;
      int_mask <= 32'd0;
    end else if (req && sel_mb && mem_we && !dev_ack && pa[1:0] == 2'd0) begin
      if (pa[3:2] == 2'd3) int_mask <= mem_wdata[31:0];
      else if (pa[3:2] != 2'd2) mb_reg[pa[3:2]] <= mem_wdata[31:0];
    end
  end

  always_comb begin
    mem_ack = ram_ack || nv_ack || iob_ack || dev_ack || vme_ack;
    mem_buserr = (dev_ack && sel_none) || vme_buserr;
    mem_rdata = fixnum(32'd0);
    if (sel_ram) mem_rdata = ram_rdata;
    else if (sel_prom) mem_rdata = prom_hi ? fixnum(32'd0) : prom_q;
    else if (sel_nvram) mem_rdata = fixnum({24'd0, nv_rdata});
    else if (sel_mb) mem_rdata = fixnum(pa[1:0] != 2'd0 ? 32'd0 : pa[3:2] == 2'd3 ? int_pending :
                                        pa[3:2] == 2'd2 ? ECO_REGISTER : mb_reg[pa[3:2]]);
    else if (sel_vme) mem_rdata = fixnum(vme_rdata);
    else if (sel_iob) mem_rdata = fixnum(iob_rdata);
  end

  assign run_light = mb_reg[0][1];

  // ---------------------------------------------------------------- coprocessor
  // 0-0o777 the FPA; above, 0o1002 is the microsecond clock.
  logic   fpa_ack, clk_ack;
  word_t  fpa_rdata, clk_rdata;
  xl_fpa fpa (
    .clk, .reset, .req(cop_req && !cop_reg[9]), .we(cop_we), .addr(cop_reg[8:0]),
    .wdata(cop_wdata[31:0]), .ack(fpa_ack), .rdata(fpa_rdata)
  );
  always_ff @(posedge clk) begin
    clk_ack <= cop_req && cop_reg[9] && !clk_ack;
    clk_rdata <= fixnum(cop_reg == 10'o1002 ? usec_now : 32'd0);
  end
  assign cop_ack = fpa_ack | clk_ack;
  assign cop_rdata = cop_reg[9] ? clk_rdata : fpa_rdata;

`ifdef VERILATOR
  // +memtrace: every memory transaction
  bit trace_mem;
  initial trace_mem = $test$plusargs("memtrace") != 0;
  always_ff @(posedge clk)
    if (trace_mem && mem_ack)
      $display("mem %s %08x %010x%s", mem_we ? "W" : "R", mem_addr,
               mem_we ? mem_wdata : mem_rdata, mem_buserr ? " BUS ERROR" : "");
`endif

endmodule
