// Symbolics XL1200: the Ivory processor on the Merlin-II main board (memory,
// boot PROM, NVRAM and clock, board registers) with Merlin I/O board 0.
// The physical address map follows emu/machine.cpp (docs/NOTES.md,
// "Physical address map").
//
// Device time: the I/O board and the microsecond clock count microseconds of
// clk (CLK_MHZ), or with LOCKSTEP instructions, as the reference model does
// (four instructions a microsecond), so the Verilator testbench can run the
// machine in lockstep with emu/.
module xl_machine #(
  parameter int    NT = 2,                 // SCSI disk targets
  parameter bit    LOCKSTEP = 1'b0,
  parameter bit    MEM_CLEAR = 1'b1,       // clear DDR3 memory at power-up
  parameter int    CLK_MHZ = 50,
  parameter        PROM_FILE = "boot_prom.mem"
) (
  input  logic        clk,
  input  logic        clk_vid,
  input  logic        power_on,            // first reset after configuration
  input  logic        reset,

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
  logic [31:0] usec;
  logic        mem_ready /*verilator public_flat_rd*/;
  logic        retire_counted;
  logic        hp_sb, lp_sb;

  ivory_core core (
    .clk, .reset, .run(mem_ready), .hold(LOCKSTEP && retire),
    .bus_req(mem_req), .bus_we(mem_we), .bus_addr(mem_addr), .bus_wdata(mem_wdata),
    .bus_ack(mem_ack), .bus_rdata(mem_rdata), .bus_buserr(mem_buserr),
    .cop_req, .cop_we, .cop_reg, .cop_wdata, .cop_ack, .cop_rdata, .cop_err(1'b0),
    .hp_sb, .lp_sb, .reset_req(1'b0), .hp_sb_taken(), .lp_sb_taken(),
    .usec_clock(usec_now),
    .retire, .retire_counted, .halted,
    .trap_mode(trap_mode), .insn_count, .halt_reason, .dbg_pc(cpu_pc)
  );
  logic [1:0]  trap_mode;
  logic [31:0] cpu_pc;

  // ---------------------------------------------------------------- time
  logic [31:0] ticks;           // LOCKSTEP: instructions so far
  logic [7:0]  usec_div;
  logic        usec_tick;
  logic [19:0] sec_div;
  logic        second;
  always_ff @(posedge clk) begin
    usec_tick <= 1'b0;
    second <= 1'b0;
    if (LOCKSTEP) begin
      if (retire) begin
        ticks <= ticks + 32'd1;
        if (ticks[1:0] == 2'd3) usec_tick <= 1'b1;
      end
    end else if (usec_div == 8'(CLK_MHZ - 1)) begin
      usec_div <= 8'd0;
      usec_tick <= 1'b1;
    end else usec_div <= usec_div + 8'd1;
    if (usec_tick) begin
      usec <= usec + 32'd1;
      if (sec_div == 20'd999999) begin sec_div <= 20'd0; second <= 1'b1; end
      else sec_div <= sec_div + 20'd1;
    end
    if (power_on) begin
      ticks <= '0; usec_div <= '0; usec <= '0; sec_div <= '0;
    end
  end
  wire        dev_tick = LOCKSTEP ? retire : usec_tick;
  wire [31:0] usec_now = LOCKSTEP ? {2'b00, ticks[31:2]} : usec;

  // ---------------------------------------------------------------- address decode
  logic        iob_dma_busy;
  wire         req = mem_req && !(LOCKSTEP && iob_dma_busy);
  wire  [31:0] pa = mem_addr;
  wire         sel_ram   = pa < 32'h0040_0000;
  wire         sel_prom  = pa[31:16] == 16'h07FE;
  wire         sel_pit   = pa[31:2] == 30'(32'h0800_0000 >> 2);
  wire         sel_nvram = pa[31:11] == 21'(32'h0900_0000 >> 11);
  wire         sel_mb    = pa[31:4] == 28'h0A0_0000;
  wire         sel_vme   = pa[31:12] == 20'h88000;
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
  xl_mem #(.CLEAR(MEM_CLEAR)) mem (
    .clk, .init(power_on), .ready(mem_ready), .dbg_state(mem_state),
    .cpu_req(req && sel_ram), .cpu_we(mem_we), .cpu_addr(pa[21:0]), .cpu_wdata(mem_wdata),
    .cpu_ack(ram_ack), .cpu_rdata(ram_rdata),
    .buf_req, .buf_we, .buf_addr, .buf_be, .buf_wdata, .buf_ack, .buf_rdata,
    .ddr_addr, .ddr_burstcnt, .ddr_rd, .ddr_we, .ddr_din, .ddr_be, .ddr_dout, .ddr_dout_ready, .ddr_busy
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
  // run light), cache control, ECO levels (one nibble per slot: main board 1,
  // I/O board 0 5, F = empty; the reference XL1201's), interrupts (reads give
  // the pending sources, writes set the mask; i-sys/io-register-definitions)
  localparam logic [31:0] ECO_REGISTER = 32'hFFF5_FFF1;
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
  // VME interface (VIC068 registers at 0x88000200+n): reads return what was
  // written, in the first 1K words
  logic [31:0] vme [1024];
  logic [31:0] vme_q;
  logic        vme_hi;
  always_ff @(posedge clk) begin
    if (req && sel_vme && mem_we && !dev_ack && pa[11:10] == 2'd0) vme[pa[9:0]] <= mem_wdata[31:0];
    vme_q <= vme[pa[9:0]];
    vme_hi <= pa[11:10] != 2'd0;
  end

  // I/O board
  logic        iob_ack;
  logic [31:0] iob_rdata;
  xl_iob #(.NT(NT), .LOCKSTEP(LOCKSTEP)) iob (
    .clk, .reset, .tick(dev_tick), .ticks,
    .cpu_req(req && sel_iob), .cpu_we(mem_we), .cpu_addr(pa[27:0]), .cpu_wdata(mem_wdata[31:0]),
    .cpu_ack(iob_ack), .cpu_rdata(iob_rdata), .dma_busy(iob_dma_busy), .scsi_irq, .ether_irq,
    .buf_req, .buf_we, .buf_addr, .buf_be, .buf_wdata, .buf_ack, .buf_rdata,
    .key_strobe, .key_down, .key_code, .mouse_strobe, .mouse_buttons, .mouse_dx, .mouse_dy,
    .img_mounted, .img_readonly, .img_size, .sd_lba, .sd_blk_cnt, .sd_rd, .sd_wr, .sd_ack,
    .sd_buff_addr, .sd_buff_dout, .sd_buff_din, .sd_buff_wr, .disk_busy(disk_light),
    .clk_vid, .white, .hs, .vs, .hblank, .vblank,
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

  // The simple targets (PROM, timer, main board, VME, nothing) answer a cycle
  // after the request; writes take effect then.
  wire  sel_simple = sel_prom || sel_pit || sel_mb || sel_vme || sel_none;
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
    mem_ack = ram_ack || nv_ack || iob_ack || dev_ack;
    mem_buserr = dev_ack && sel_none;
    mem_rdata = fixnum(32'd0);
    if (sel_ram) mem_rdata = ram_rdata;
    else if (sel_prom) mem_rdata = prom_hi ? fixnum(32'd0) : prom_q;
    else if (sel_nvram) mem_rdata = fixnum({24'd0, nv_rdata});
    else if (sel_mb) mem_rdata = fixnum(pa[1:0] != 2'd0 ? 32'd0 : pa[3:2] == 2'd3 ? int_pending :
                                        pa[3:2] == 2'd2 ? ECO_REGISTER : mb_reg[pa[3:2]]);
    else if (sel_vme) mem_rdata = fixnum(vme_hi ? 32'd0 : vme_q);
    else if (sel_iob) mem_rdata = fixnum(iob_rdata);
  end

  assign run_light = mb_reg[0][1];

  // ---------------------------------------------------------------- coprocessor
  // 0o1002 is the microsecond clock; nothing else is fitted (no FPA yet).
  always_ff @(posedge clk) begin
    cop_ack <= cop_req && !cop_ack;
    cop_rdata <= fixnum(cop_reg == 10'o1002 ? usec_now : 32'd0);
  end

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
