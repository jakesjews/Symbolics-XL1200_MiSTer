// The Ivory's instruction cache and prefetcher (docs/ivory.md): 32 words
// direct-mapped by word address, tagged by the rest of the virtual address,
// and a prefetcher that reads the words after the last instruction fetched
// from memory, within its page, with physical addresses (the page's
// translation came with that fetch), while it is fewer than the high mark
// words ahead of the PC.  A word with cdr code 1 fences the stream: the end
// of a compiled function.  A store invalidates the word it hits (the FEP
// rewrites code in place and never writes the icache control register, so
// the chip must do this too) and a prefetch in flight to that address.
//
// The processor looks the next instruction's word up from its PC register
// (the words are in flops, read from that register, so a hit answers in the
// fetch cycle) and installs the word it fetched on a miss (fill).  The prefetcher
// takes the memory port when the processor isn't asking for it (cpu_req)
// and the memory isn't finishing a line (mem_busy: the miss was answered
// with its word early, and a prefetch queued now would hold the port while
// the processor's next request waits behind it); ivory_core arbitrates
// with pf_busy.
module ivory_icache
  import ivory_pkg::*;
(
  input  logic        clk,
  input  logic        reset,
  input  logic        enable,       // icache control bit 0; clear: no hits, no fills, contents dropped
  input  logic        pf_enable,    // prefetcher control bit 0
  input  logic [3:0]  pf_high,      // prefetcher control bits 8:5: words to run ahead of the PC

  // the lookup: pc_b is the processor's PC, pc_a the next instruction's in
  // the retire cycle (sel_a); both are registers, so the words can live in
  // block RAM read from them
  input  logic [31:0] pc_a,
  input  logic [31:0] pc_b,
  input  logic        sel_a,
  output logic        hit            /*verilator public_flat_rd*/,
  output word_t       word           /*verilator public_flat_rd*/,

  input  logic        fill          /*verilator public_flat_rd*/,   // the processor fetched fill_word at fill_va (physical fill_pa)
  input  logic [31:0] fill_va,
  input  logic [31:0] fill_pa,
  input  word_t       fill_word,

  input  logic        snoop,        // the processor is writing snoop_va (virtual word address)
  input  logic [31:0] snoop_va,

  input  logic        cpu_req,      // the processor wants the memory port
  input  logic        mem_busy,     // the memory is finishing a line: a prefetch would only queue ahead of the processor
  output logic        pf_busy       /*verilator public_flat_rd*/,   // a prefetch owns the port until its ack
  output logic        pf_req,
  output logic [31:0] pf_addr,      // physical
  input  logic        pf_ack,
  input  word_t       pf_rdata,
  input  logic        pf_err
);

  word_t       data_a [32] /*verilator public_flat_rd*/;   // two copies: one a read port each
  word_t       data_b [32];
  logic [26:0] tag  [32] /*verilator public_flat_rd*/;
  logic [31:0] valid /*verilator public_flat_rd*/;

  wire [31:0] fetch_pc = sel_a ? pc_a : pc_b;
  wire [4:0] ix = fetch_pc[4:0];
  assign word = sel_a ? data_a[pc_a[4:0]] : data_b[pc_b[4:0]];
  logic        d_we;
  logic [4:0]  d_ix;
  word_t       d_w;
  // no hit on a word whose data is still landing (d_we: written at the end
  // of this cycle), which the retire-cycle lookup of a prefetched word can
  // reach
  assign hit = enable && valid[ix] && tag[ix] == fetch_pc[31:5] && !(d_we && d_ix == ix);
  always_ff @(posedge clk) if (d_we) begin data_a[d_ix] <= d_w; data_b[d_ix] <= d_w; end

  // A prefetched word that arrives in the processor's fill cycle waits a cycle
  logic        pend /*verilator public_flat_rd*/;
  logic [31:0] pend_va;
  word_t       pend_word;

  // The stream: the next word to prefetch; the prefetch in flight keeps its
  // own address (pf_va), since a fill restarts the stream meanwhile
  logic        stream, killed;      // killed: the word being prefetched was written
  logic [31:0] s_va /*verilator public_flat_rd*/, s_pa /*verilator public_flat_rd*/, pf_va;
  wire [31:0] ahead = s_va - fetch_pc;
  wire        fence = wcdr(pf_rdata) == CDR_NIL;

  // the word lands a cycle after its tag and valid bit (hit waits for it)
  task automatic install(input logic [31:0] va, input word_t w);
    d_we <= 1'b1; d_ix <= va[4:0]; d_w <= w;
    tag[va[4:0]] <= va[31:5];
    valid[va[4:0]] <= 1'b1;
  endtask

  always_ff @(posedge clk) begin
    d_we <= 1'b0;
    if (reset) begin
      valid <= '0;
      stream <= 1'b0;
      pf_busy <= 1'b0;
      pf_req <= 1'b0;
      pend <= 1'b0;
      killed <= 1'b0;
    end else begin
      if (!enable) valid <= '0;
      if (snoop) begin
        if (tag[snoop_va[4:0]] == snoop_va[31:5]) valid[snoop_va[4:0]] <= 1'b0;
        if (pend_va == snoop_va) pend <= 1'b0;
        if (pf_busy && pf_va == snoop_va) killed <= 1'b1;
      end

      if (fill && enable) install(fill_va, fill_word);
      else if (pend && enable) begin
        install(pend_va, pend_word);
        pend <= 1'b0;
      end else if (pend) pend <= 1'b0;

      // the stream restarts at each fetch from memory
      if (fill) begin
        s_va <= fill_va + 32'd1;
        s_pa <= fill_pa + 32'd1;
        stream <= enable && fill_va[7:0] != 8'hFF && wcdr(fill_word) != CDR_NIL;
      end

      if (pf_busy) begin
        if (pf_ack) begin
          pf_busy <= 1'b0;
          pf_req <= 1'b0;
          killed <= 1'b0;
          if (!pf_err && !fence && !killed && enable) begin
            if (fill) begin pend <= 1'b1; pend_va <= pf_va; pend_word <= pf_rdata; end
            else install(pf_va, pf_rdata);
          end
          if (!fill && s_va == pf_va) begin   // the stream wasn't restarted meanwhile
            s_va <= s_va + 32'd1;
            s_pa <= s_pa + 32'd1;
            if (pf_err || fence || pf_va[7:0] == 8'hFF) stream <= 1'b0;
          end
        end
      end else if (stream && pf_enable && enable && !cpu_req && !mem_busy && !fill && ahead < {28'd0, pf_high}) begin
        pf_busy <= 1'b1;
        pf_req <= 1'b1;
        pf_addr <= s_pa;
        pf_va <= s_va;
        killed <= 1'b0;
      end
    end
  end

endmodule
