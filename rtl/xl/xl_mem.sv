// XL1200 memory in DDR3: the main board's memory (behind a cache) and the
// I/O board's buffer memory, through MiSTer's DDRAM port (64-bit Avalon-MM,
// one word per 64-bit DDR word).
//
// Ports follow one protocol: the requester holds req (and its address and
// data) until ack, a one-cycle pulse; a port is sampled only while the
// memory is idle, so the requester may present its next request from the
// cycle after ack.
//
// The cache is direct-mapped with four-word lines, write-through, allocating
// on read misses only.  Only the processor reaches main memory (the I/O
// board's DMA stays in its buffer memory), so nothing else can make a line
// stale.  Its RAMs are read from the requester's address, which is a
// register on its side, so a read hit is answered in the cycle the request
// appears, with no state change.  A miss is answered with the word asked
// for as its beat of the line's burst arrives; the rest of the line lands
// while the processor goes on (the port is sampled again once it has).
//
// Power-up: DDR3 holds whatever the last core left there; while `init` is
// high the memory clears main and buffer memory to zero words (as the
// reference model starts) and invalidates the cache, then raises `ready`.
module xl_mem #(
  parameter int          RAM_AW  = 22,              // 4 MW of main memory
  parameter int          LINE_AW = 11,              // 2048 cache lines of 4 words
  parameter logic [28:0] RAM_BASE = 29'h0600_0000,  // DDR word addresses (byte 0x30000000)
  parameter logic [28:0] BUF_BASE = 29'h0640_0000,
  parameter bit          CLEAR = 1'b1               // 0: assume DDR3 already zero (simulation)
) (
  input  logic              clk,
  input  logic              init,       // power-up: clear, then ready
  output logic              ready,

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
    M_CLEAR, M_IDLE, M_LOOKUP, M_MISS, M_FILL, M_WRITE, M_BUF_RD, M_BUF_WAIT, M_BUF_WR
  } mstate_t;
  mstate_t st /*verilator public_flat_rd*/ = M_CLEAR;

  // ---------------------------------------------------------------- cache RAMs
  logic [39:0]    cdata [1 << (LINE_AW + 2)];
  logic [TAG_W:0] ctag  [1 << LINE_AW];       // {valid, tag}
  logic [39:0]    cdata_q;
  logic [TAG_W:0] ctag_q;
  logic [LINE_AW+1:0] cdata_ra, cdata_wa;
  logic [LINE_AW-1:0] ctag_ra, ctag_wa;
  logic           cdata_we, ctag_we;
  logic [39:0]    cdata_wd;
  logic [TAG_W:0] ctag_wd;

  always_ff @(posedge clk) if (cdata_we) cdata[cdata_wa] <= cdata_wd;
  always_ff @(posedge clk) if (ctag_we) ctag[ctag_wa] <= ctag_wd;
  assign cdata_q = cdata[cdata_ra];
  assign ctag_q = ctag[ctag_ra];

  // The request being served
  logic              a_we;
  logic [RAM_AW-1:0] a_addr;
  logic [39:0]       a_wd;
  logic [1:0]        beat;
  logic              b_we;
  logic [15:0]       b_addr;
  logic [3:0]        b_be;
  logic [31:0]       b_wd;

  wire [TAG_W-1:0]   a_tag = a_addr[RAM_AW-1 -: TAG_W];
  wire [TAG_W-1:0]   c_tag = cpu_addr[RAM_AW-1 -: TAG_W];
  // the hit for the request on the port (read from cpu_addr); the write
  // path's (M_LOOKUP) is the same request, still held on the port
  wire               hit = ctag_q[TAG_W] && ctag_q[TAG_W-1:0] == c_tag;

  // Clearing
  logic [22:0]       clr_addr;     // DDR words from RAM_BASE, then buffer words
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
    cdata_we = 1'b0; cdata_wa = a_addr[LINE_AW+1:0]; cdata_wd = a_wd;
    ctag_we = 1'b0; ctag_wa = a_addr[LINE_AW+1:2]; ctag_wd = {1'b1, a_tag};
    case (st)
      M_CLEAR: begin
        ctag_we = !clr_tag[LINE_AW];
        ctag_wa = clr_tag[LINE_AW-1:0];
        ctag_wd = '0;
      end
      M_LOOKUP: cdata_we = a_we && hit;           // write hit: update the word
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
    ddr_addr = RAM_BASE + 29'(a_addr);
    ddr_burstcnt = 8'd1;
    ddr_din = {24'd0, a_wd};
    ddr_be = 8'hFF;
    case (st)
      M_CLEAR: begin
        ddr_we = CLEAR && !init && !(clr_buf && clr_addr[16]);
        ddr_addr = (clr_buf ? BUF_BASE : RAM_BASE) + 29'(clr_addr - 23'(clr_beat));
        ddr_burstcnt = 8'(CLEAR_BURST);
        ddr_din = '0;
      end
      M_MISS: begin
        ddr_rd = 1'b1;
        ddr_addr = RAM_BASE + 29'({a_addr[RAM_AW-1:2], 2'b00});
        ddr_burstcnt = 8'd4;
      end
      M_WRITE: ddr_we = 1'b1;
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
      M_IDLE: cpu_ack = cpu_req && !buf_req && !cpu_we && hit;   // a read hit, answered now
      M_FILL: begin cpu_ack = ddr_dout_ready && beat == a_addr[1:0]; cpu_rdata = ddr_dout[39:0]; end
      M_WRITE:  cpu_ack = !ddr_busy;
      M_BUF_WAIT: buf_ack = ddr_dout_ready;
      M_BUF_WR: buf_ack = !ddr_busy;
      default: ;
    endcase
  end

  assign ready = st != M_CLEAR;
  assign dbg_state = st;

  always_ff @(posedge clk) begin
    if (init) begin
      st <= M_CLEAR;
      clr_addr <= '0;
      clr_beat <= '0;
      clr_buf <= 1'b0;
      clr_tag <= '0;
    end else begin
      case (st)
        M_CLEAR: begin
          if (!clr_tag[LINE_AW]) clr_tag <= clr_tag + 1'd1;
          if (!CLEAR || (clr_buf && clr_addr[16])) begin
            if (clr_tag[LINE_AW]) st <= M_IDLE;
          end else if (!ddr_busy) begin
            // One beat of a CLEAR_BURST-word burst; the burst's address is
            // the address of its first beat.
            clr_beat <= (clr_beat == 7'(CLEAR_BURST - 1)) ? 7'd0 : clr_beat + 7'd1;
            if (!clr_buf && clr_addr == 23'((1 << RAM_AW) - 1)) begin
              clr_buf <= 1'b1;
              clr_addr <= '0;
            end else clr_addr <= clr_addr + 23'd1;
          end
        end

        M_IDLE:
          if (buf_req) begin
            b_we <= buf_we; b_addr <= buf_addr; b_be <= buf_be; b_wd <= buf_wdata;
            st <= buf_we ? M_BUF_WR : M_BUF_RD;
          end else if (cpu_req && (cpu_we || !hit)) begin
            a_we <= cpu_we; a_addr <= cpu_addr; a_wd <= cpu_wdata;
            st <= cpu_we ? M_LOOKUP : M_MISS;
          end

        M_LOOKUP: st <= M_WRITE;   // a write: the cache word updated on a hit, then memory

        M_MISS: if (!ddr_busy) begin beat <= 2'd0; st <= M_FILL; end

        M_FILL: if (ddr_dout_ready) begin
          beat <= beat + 2'd1;
          if (beat == 2'd3) st <= M_IDLE;
        end

        M_WRITE: if (!ddr_busy) st <= M_IDLE;

        M_BUF_RD: if (!ddr_busy) st <= M_BUF_WAIT;
        M_BUF_WAIT: if (ddr_dout_ready) st <= M_IDLE;
        M_BUF_WR: if (!ddr_busy) st <= M_IDLE;

        default: st <= M_IDLE;
      endcase
    end
  end

endmodule
