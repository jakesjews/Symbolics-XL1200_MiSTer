// The 82586 and its wire (xl_i82586 + xl_eth_hps) on a buffer memory and a
// DDR3 holding the mailbox, for tb_ether.cpp: the bench fills the chip's
// control structures as Genera's driver does and plays Main's side of the
// mailbox.
module tb_ether (
  input  logic       clk,
  input  logic       reset,
  input  logic       ena,
  input  logic       pins_we,
  input  logic [7:0] pins,
  output logic       busy,
  output logic       irq,
  output logic       tx_busy,
  output logic       rx_fifordy
);

  // ---------------------------------------------------------------- buffer memory
  // The I/O board's 32K words of 32 bits; a 16-bit access answers the cycle after
  logic [31:0] bufmem [32768] /*verilator public_flat_rw*/;
  logic        m_req, m_we, m_hi, m_ack;
  logic [14:0] m_word;
  logic [1:0]  m_be;
  logic [15:0] m_wdata;
  logic [31:0] m_rdata;
  logic        m_wait;
  always_ff @(posedge clk) begin
    m_ack <= 1'b0;
    if (m_req && !m_ack && !m_wait) begin
      m_wait <= 1'b1;
    end else if (m_req && m_wait) begin
      m_wait <= 1'b0;
      m_ack <= 1'b1;
      m_rdata <= bufmem[m_word];
      if (m_we) begin
        if (m_hi) begin
          if (m_be[0]) bufmem[m_word][23:16] <= m_wdata[7:0];
          if (m_be[1]) bufmem[m_word][31:24] <= m_wdata[15:8];
        end else begin
          if (m_be[0]) bufmem[m_word][7:0] <= m_wdata[7:0];
          if (m_be[1]) bufmem[m_word][15:8] <= m_wdata[15:8];
        end
      end
    end
    if (reset) begin m_wait <= 1'b0; m_ack <= 1'b0; end
  end

  // ---------------------------------------------------------------- the wire
  logic        tx_push, tx_stp, tx_enp, tx_crcgen, tx_clr, tx_fifordy;
  logic [1:0]  tx_be;
  logic [15:0] tx_d;
  logic [11:0] tx_len, rx_len;
  logic        rx_pop, rx_clr, rx_deof, rx_crcok, rx_eof, rx_lpbk, rx_prom;
  logic [15:0] rx_d;
  logic [47:0] rx_padr;
  logic [63:0] rx_ladrf;

  xl_i82586 ether (
    .clk, .reset, .pins_we, .pins, .busy, .irq,
    .m_req, .m_we, .m_word, .m_hi, .m_be, .m_wdata, .m_ack, .m_rdata,
    .tx_push, .tx_stp, .tx_be, .tx_d, .tx_enp, .tx_len, .tx_crcgen, .tx_clr, .tx_busy,
    .rx_pop, .rx_clr, .rx_d, .rx_deof, .rx_fifordy, .rx_len, .rx_lpbk, .rx_prom, .rx_padr, .rx_ladrf
  );

  // ---------------------------------------------------------------- the mailbox's DDR
  // 64 KB at DDR word 0x03FE_0000; waitrequest two cycles in five, read data
  // three cycles after the command
  logic [63:0] mbox [8192] /*verilator public_flat_rw*/;
  logic        avl_waitrequest, avl_read, avl_write, avl_readdatavalid;
  logic [28:0] avl_address;
  logic [63:0] avl_writedata, avl_readdata;
  logic [7:0]  avl_byteenable, avl_burstcount;
  logic [2:0]  wcnt;
  logic [63:0] rpipe [3];
  logic [2:0]  rvalid;
  assign avl_waitrequest = wcnt < 3'd2;
  always_ff @(posedge clk) begin
    wcnt <= wcnt == 3'd4 ? 3'd0 : wcnt + 3'd1;
    rvalid <= {rvalid[1:0], 1'b0};
    rpipe[1] <= rpipe[0]; rpipe[2] <= rpipe[1];
    if (!avl_waitrequest && avl_write) begin
      if (avl_address[28:13] == 16'(29'h03FE_0000 >> 13)) mbox[avl_address[12:0]] <= avl_writedata;
    end
    if (!avl_waitrequest && avl_read) begin
      rpipe[0] <= mbox[avl_address[12:0]];
      rvalid[0] <= 1'b1;
    end
    if (reset) begin wcnt <= '0; rvalid <= '0; end
  end
  assign avl_readdatavalid = rvalid[2];
  assign avl_readdata = rpipe[2];

  xl_eth_hps #(.CLK_HZ(50_000_000), .SIMU(1'b1)) hps (
    .clk, .rst(reset), .ena,
    .tx_push, .tx_stp, .tx_be, .tx_d, .tx_enp, .tx_len, .tx_crcgen, .tx_clr, .tx_fifordy, .tx_busy,
    .rx_pop, .rx_clr, .rx_d, .rx_deof, .rx_fifordy, .rx_len, .rx_crcok, .rx_eof,
    .rx_lpbk, .rx_prom, .rx_padr, .rx_ladrf,
    .avl_waitrequest, .avl_address, .avl_read, .avl_write, .avl_writedata, .avl_byteenable, .avl_burstcount,
    .avl_readdata, .avl_readdatavalid
  );

endmodule
