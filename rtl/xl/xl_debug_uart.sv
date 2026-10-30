// Prints eight 32-bit words in hex on a serial line, a line every half
// second, for bring-up on the MiSTer: the core's UART TX reaches the ARM as
// /dev/ttyS1 (8N1, BAUD).
module xl_debug_uart #(
  parameter int CLK_HZ = 50_000_000,
  parameter int BAUD = 115_200
) (
  input  logic        clk,
  input  logic        enable,
  input  logic [31:0] words [8],
  output logic        txd
);

  localparam int DIV = CLK_HZ / BAUD;
  localparam int LINE = 8 * 9 + 1;          // "XXXXXXXX " x 8, "\r\n" shares the last space

  logic [31:0] snap [8];
  logic [6:0]  ch;                          // character in the line
  logic        busy = 1'b0;
  logic [25:0] wait_cnt;
  logic [15:0] baud_cnt;
  logic [3:0]  bit_n;
  logic [9:0]  shifter = '1;

  function automatic logic [7:0] hex(input logic [3:0] d);
    return d < 4'd10 ? 8'h30 + 8'(d) : 8'h41 + 8'(d) - 8'd10;
  endfunction

  // character number c of the line
  function automatic logic [7:0] char_at(input logic [6:0] c);
    logic [2:0] w;
    logic [3:0] d;
    w = 3'(c / 7'd9);
    d = 4'(c % 7'd9);
    if (c == 7'(LINE - 1)) return 8'h0A;
    if (c == 7'(LINE - 2)) return 8'h0D;
    if (d == 4'd8) return 8'h20;
    return hex(snap[w][4 * (7 - d[2:0]) +: 4]);
  endfunction

  assign txd = shifter[0];

  always_ff @(posedge clk) begin
    if (!busy) begin
      shifter <= '1;
      if (wait_cnt == 26'(CLK_HZ / 2)) begin
        wait_cnt <= '0;
        if (enable) begin
          snap <= words;
          busy <= 1'b1;
          ch <= '0;
          bit_n <= 4'd10;     // load a character next
        end
      end else wait_cnt <= wait_cnt + 26'd1;
    end else if (bit_n == 4'd10) begin
      shifter <= {1'b1, char_at(ch), 1'b0};
      bit_n <= '0;
      baud_cnt <= '0;
    end else if (baud_cnt == 16'(DIV - 1)) begin
      baud_cnt <= '0;
      shifter <= {1'b1, shifter[9:1]};
      if (bit_n == 4'd9) begin
        bit_n <= 4'd10;
        if (ch == 7'(LINE - 1)) busy <= 1'b0;
        else ch <= ch + 7'd1;
      end else bit_n <= bit_n + 4'd1;
    end else baud_cnt <= baud_cnt + 16'd1;
  end

endmodule
