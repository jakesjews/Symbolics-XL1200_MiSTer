// XL1200 memory in DDR3: the main board's memory (behind a cache) and the
// I/O board's buffer memory, through MiSTer's DDRAM port (64-bit Avalon-MM,
// one word per 64-bit DDR word).
//
// Ports follow one protocol: the requester holds req (and its address and
// data) until ack, a one-cycle pulse; a port is sampled only while the
// memory is idle, so the requester may present its next request from the
// cycle after ack.
//
// The cache is direct-mapped with four-word lines, write-through, with a
// valid bit per word: a read miss fills the line, a write installs its word
// (allocating the line if need be), so a freshly written word is read back
// from the cache and consing never reads DDR3.  Only the processor reaches
// main memory (the I/O board's DMA stays in its buffer memory), so nothing
// else can make a line stale.  Its RAMs are read from the requester's address, which is a
// register on its side, so a read hit is answered in the cycle the request
// appears, with no state change.  A miss is answered with the word asked
// for as its beat of the line's burst arrives; the rest of the line lands
// while the processor goes on (the port is sampled again once it has).
// Writes are posted: acknowledged in the cycle they appear (the cached
// word updated on a hit) and queued for DDR3, which takes them while the
// memory is idle; a miss to a line with a write queued waits for the queue
// to drain, so DDR3 has the write before the read; one to any other line
// goes ahead of the queue.
//
// Power-up: DDR3 holds whatever the last core left there; while `init` is
// high the memory clears main and buffer memory to zero words (as the
// reference model starts) and invalidates the cache, then raises `ready`.
module xl_mem #(
  parameter int          RAM_AW  = 24,              // 16 MW of main memory, the XL1200's most
  parameter int          LINE_AW = 11,              // 2048 cache lines of 4 words
  parameter logic [28:0] RAM_BASE = 29'h0600_0000,  // DDR word addresses (byte 0x30000000)
  parameter logic [28:0] BUF_BASE = 29'h0700_0000,
  parameter bit          CLEAR = 1'b1               // 0: assume DDR3 already zero (simulation)
) (
  input  logic              clk,
  input  logic              init,       // power-up: clear, then ready
  output logic              ready,
  output logic              busy,       // a line is being fetched (or clearing): a request now would wait

  // processor: main memory
  input  logic              cpu_req,
  input  logic              cpu_we,
  input  logic [RAM_AW-1:0] cpu_addr,
  input  logic [39:0]       cpu_wdata,
  output logic              cpu_ack,
  output logic [39:0]       cpu_rdata,

  // I/O board: buffer memory (64K 32-bit words)
  input  logic              buf_req,
  input  logic              buf_we,
  input  logic [15:0]       buf_addr,
  input  logic [3:0]        buf_be,
  input  logic [31:0]       buf_wdata,
  output logic              buf_ack,
  output logic [31:0]       buf_rdata,

  // DDR3
  output logic [28:0]       ddr_addr,
  output logic [7:0]        ddr_burstcnt,
  output logic              ddr_rd,
  output logic              ddr_we,
  output logic [63:0]       ddr_din,
  output logic [7:0]        ddr_be,
  input  logic [63:0]       ddr_dout,
  input  logic              ddr_dout_ready,
  input  logic              ddr_busy,

  output logic [3:0]        dbg_state
);

  localparam int TAG_W = RAM_AW - LINE_AW - 2;
  localparam int CLEAR_BURST = 16;

  typedef enum logic [3:0] {
    M_CLEAR, M_IDLE, M_MISS, M_FILL, M_BUF_RD, M_BUF_WAIT, M_BUF_WR
  } mstate_t;
  mstate_t st /*verilator public_flat_rd*/ = M_CLEAR;

  // ---------------------------------------------------------------- cache RAMs
  logic [39:0]      cdata [1 << (LINE_AW + 2)];
  logic [TAG_W+3:0] ctag  [1 << LINE_AW];     // {valid[3:0], tag}
  logic [39:0]      cdata_q;
  logic [TAG_W+3:0] ctag_q;
  logic [LINE_AW+1:0] cdata_ra, cdata_wa;
  logic [LINE_AW-1:0] ctag_ra, ctag_wa;
  logic           cdata_we, ctag_we;
  logic [39:0]      cdata_wd;
  logic [TAG_W+3:0] ctag_wd;

  always_ff @(posedge clk) if (cdata_we) cdata[cdata_wa] <= cdata_wd;
  always_ff @(posedge clk) if (ctag_we) ctag[ctag_wa] <= ctag_wd;
  assign cdata_q = cdata[cdata_ra];
  assign ctag_q = ctag[ctag_ra];

  // The read miss being served
  logic [RAM_AW-1:0] a_addr;
  logic [1:0]        beat;

  // The write queue: the words in a RAM read from the registered pointer,
  // the addresses in flops (every queued line is compared with a miss)
  localparam int WQ_AW = 4;
  logic [39:0]        wq_d [1 << WQ_AW];
  logic [RAM_AW-1:0]  wq_a [1 << WQ_AW];
  logic [(1 << WQ_AW)-1:0] wq_v;
  logic [WQ_AW:0]     wq_wp, wq_rp;
  wire                wq_empty = wq_wp == wq_rp;
  wire                wq_full = wq_wp == {~wq_rp[WQ_AW], wq_rp[WQ_AW-1:0]};
  wire [39:0]         wq_head_d = wq_d[wq_rp[WQ_AW-1:0]];
  wire [RAM_AW-1:0]   wq_head_a = wq_a[wq_rp[WQ_AW-1:0]];
  wire                wq_push = st == M_IDLE && cpu_req && cpu_we && !buf_req && !wq_full;
  wire                wq_pop = st == M_IDLE && !wq_empty && !ddr_busy;
  always_ff @(posedge clk) if (wq_push) wq_d[wq_wp[WQ_AW-1:0]] <= cpu_wdata;
  logic               wq_same;        // a queued write is to the line on the port
  always_comb begin
    wq_same = 1'b0;
    for (int k = 0; k < (1 << WQ_AW); k++)
      if (wq_v[k] && wq_a[k][RAM_AW-1:2] == cpu_addr[RAM_AW-1:2]) wq_same = 1'b1;
  end
  logic              b_we;
  logic [15:0]       b_addr;
  logic [3:0]        b_be;
  logic [31:0]       b_wd;

  wire [TAG_W-1:0]   a_tag = a_addr[RAM_AW-1 -: TAG_W];
  wire [TAG_W-1:0]   c_tag = cpu_addr[RAM_AW-1 -: TAG_W];
  // the line and the word for the request on the port (read from cpu_addr)
  wire               line_match = ctag_q[TAG_W-1:0] == c_tag;
  wire [3:0]         line_valid = ctag_q[TAG_W+3:TAG_W];
  wire               hit = line_match && line_valid[cpu_addr[1:0]];
  wire [3:0]         word_bit = 4'b0001 << cpu_addr[1:0];

  // Clearing
  logic [RAM_AW:0]   clr_addr;     // DDR words from RAM_BASE, then buffer words
  logic [6:0]        clr_beat;
  logic              clr_buf;
  logic [LINE_AW:0]  clr_tag;      // tag entries invalidated (MSB = done)

  // Read addresses: the request on the processor port
  always_comb begin
    cdata_ra = cpu_addr[LINE_AW+1:0];
    ctag_ra  = cpu_addr[LINE_AW+1:2];
  end

  // Writes into the cache
  always_comb begin
    cdata_we = 1'b0; cdata_wa = cpu_addr[LINE_AW+1:0]; cdata_wd = cpu_wdata;
    ctag_we = 1'b0; ctag_wa = a_addr[LINE_AW+1:2]; ctag_wd = {4'b1111, a_tag};
    case (st)
      M_CLEAR: begin
        ctag_we = !clr_tag[LINE_AW];
        ctag_wa = clr_tag[LINE_AW-1:0];
        ctag_wd = '0;
      end
      M_IDLE: begin
        // a write installs its word: in its line if that is the one
        // cached, else in a fresh line holding that word alone
        cdata_we = wq_push;
        ctag_we = wq_push;
        ctag_wa = cpu_addr[LINE_AW+1:2];
        ctag_wd = line_match ? {line_valid | word_bit, c_tag} : {word_bit, c_tag};
      end
      M_FILL: begin
        cdata_we = ddr_dout_ready;
        cdata_wa = {a_addr[LINE_AW+1:2], beat};
        cdata_wd = ddr_dout[39:0];
        ctag_we = ddr_dout_ready && beat == 2'd3;
      end
      default: ;
    endcase
  end

  // DDR3 commands
  always_comb begin
    ddr_rd = 1'b0; ddr_we = 1'b0;
    ddr_addr = RAM_BASE + 29'(wq_head_a);
    ddr_burstcnt = 8'd1;
    ddr_din = {24'd0, wq_head_d};
    ddr_be = 8'hFF;
    case (st)
      M_IDLE: ddr_we = !wq_empty;                 // drain the write queue
      M_CLEAR: begin
        ddr_we = CLEAR && !init && !(clr_buf && clr_addr[16]);
        ddr_addr = (clr_buf ? BUF_BASE : RAM_BASE) + 29'(clr_addr) - 29'(clr_beat);
        ddr_burstcnt = 8'(CLEAR_BURST);
        ddr_din = '0;
      end
      M_MISS: begin
        ddr_rd = 1'b1;
        ddr_addr = RAM_BASE + 29'({a_addr[RAM_AW-1:2], 2'b00});
        ddr_burstcnt = 8'd4;
      end
      M_BUF_RD: begin
        ddr_rd = 1'b1;
        ddr_addr = BUF_BASE + 29'(b_addr);
      end
      M_BUF_WR: begin
        ddr_we = 1'b1;
        ddr_addr = BUF_BASE + 29'(b_addr);
        ddr_din = {32'd0, b_wd};
        ddr_be = {4'd0, b_be};
      end
      default: ;
    endcase
  end

  // Acknowledgements
  always_comb begin
    cpu_ack = 1'b0;
    cpu_rdata = cdata_q;
    buf_ack = 1'b0;
    buf_rdata = ddr_dout[31:0];
    case (st)
      M_IDLE: cpu_ack = cpu_req && !buf_req && (cpu_we ? !wq_full : hit);   // a read hit or a posted write
      M_FILL: begin cpu_ack = ddr_dout_ready && beat == a_addr[1:0]; cpu_rdata = ddr_dout[39:0]; end
      M_BUF_WAIT: buf_ack = ddr_dout_ready;
      M_BUF_WR: buf_ack = !ddr_busy;
      default: ;
    endcase
  end

  assign ready = st != M_CLEAR;
  assign busy = st != M_IDLE;
  assign dbg_state = st;

  always_ff @(posedge clk) begin
    if (init) begin
      st <= M_CLEAR;
      clr_addr <= '0;
      clr_beat <= '0;
      clr_buf <= 1'b0;
      clr_tag <= '0;
      wq_wp <= '0;
      wq_rp <= '0;
      wq_v <= '0;
    end else begin
      if (wq_push) begin
        wq_wp <= wq_wp + 1'd1;
        wq_a[wq_wp[WQ_AW-1:0]] <= cpu_addr;
        wq_v[wq_wp[WQ_AW-1:0]] <= 1'b1;
      end
      if (wq_pop) begin
        wq_rp <= wq_rp + 1'd1;
        wq_v[wq_rp[WQ_AW-1:0]] <= 1'b0;
      end
      case (st)
        M_CLEAR: begin
          if (!clr_tag[LINE_AW]) clr_tag <= clr_tag + 1'd1;
          if (!CLEAR || (clr_buf && clr_addr[16])) begin
            if (clr_tag[LINE_AW]) st <= M_IDLE;
          end else if (!ddr_busy) begin
            // One beat of a CLEAR_BURST-word burst; the burst's address is
            // the address of its first beat.
            clr_beat <= (clr_beat == 7'(CLEAR_BURST - 1)) ? 7'd0 : clr_beat + 7'd1;
            if (!clr_buf && clr_addr == {1'b0, {RAM_AW{1'b1}}}) begin
              clr_buf <= 1'b1;
              clr_addr <= '0;
            end else clr_addr <= clr_addr + 1'b1;
          end
        end

        M_IDLE:
          if (buf_req) begin
            b_we <= buf_we; b_addr <= buf_addr; b_be <= buf_be; b_wd <= buf_wdata;
            st <= buf_we ? M_BUF_WR : M_BUF_RD;
          end else if (cpu_req && !cpu_we && !hit && !wq_same) begin
            a_addr <= cpu_addr;
            st <= M_MISS;
          end

        M_MISS: if (!ddr_busy) begin beat <= 2'd0; st <= M_FILL; end

        M_FILL: if (ddr_dout_ready) begin
          beat <= beat + 2'd1;
          if (beat == 2'd3) st <= M_IDLE;
        end

        M_BUF_RD: if (!ddr_busy) st <= M_BUF_WAIT;
        M_BUF_WAIT: if (ddr_dout_ready) st <= M_IDLE;
        M_BUF_WR: if (!ddr_busy) st <= M_IDLE;

        default: st <= M_IDLE;
      endcase
    end
  end

endmodule
