// Intel 82C54 interval timer on the Merlin-II main board (physical
// 0x08000000, registers 0-2 the counters, 3 the control word); follows
// emu/pit.cpp, which notes what Genera uses: modes 0 and 2, binary counts,
// counter 0 clocked by OUT1's falling edges, counters 1 and 2 by `tick`
// (1 MHz).
module xl_pit (
  input  logic       clk,
  input  logic       reset,
  input  logic       tick,
  input  logic       we,
  input  logic [1:0] reg_n,
  input  logic [7:0] wdata,
  output logic [2:0] out
);

  logic [2:0]  mode [3];
  logic [1:0]  rw [3];
  logic [2:0]  msb_next, pending, counting;
  logic [15:0] reload [3];
  logic [16:0] value [3];
  logic        tick_late;     // a tick that came with a write, taken the next cycle

  // One clock of counter n given its state; returns the new OUT.
  // (Pit82C54::clock)
  task automatic clock_n(input int n, input logic out_now, output logic out_new);
    logic [16:0] full;
    full = reload[n] == 16'd0 ? 17'h10000 : {1'b0, reload[n]};
    out_new = out_now;
    if (pending[n]) begin
      pending[n] <= 1'b0;
      value[n] <= full;
      counting[n] <= 1'b1;
    end else if (counting[n]) begin
      case (mode[n])
        3'd0: begin
          value[n] <= {1'b0, value[n][15:0] - 16'd1};
          if (value[n][15:0] == 16'd1) out_new = 1'b1;
        end
        3'd2:
          if (value[n] == 17'd1) begin
            out_new = 1'b0;
            value[n] <= full;
          end else begin
            out_new = 1'b1;
            value[n] <= value[n] - 17'd1;
          end
        default: value[n] <= {1'b0, value[n][15:0] - 16'd1};
      endcase
    end
  endtask

  always_ff @(posedge clk) begin
    tick_late <= 1'b0;
    if (reset) begin
      for (int i = 0; i < 3; i++) begin
        mode[i] <= 3'd0; rw[i] <= 2'd3; reload[i] <= '0; value[i] <= '0;
      end
      msb_next <= '0; pending <= '0; counting <= '0; out <= '0;
    end else if (we) begin
      // Pit82C54::write; a tick in the same cycle counts after it, as in the model
      tick_late <= tick;
      if (reg_n == 2'd3) begin
        logic [1:0] n;
        logic [2:0] m;
        n = wdata[7:6];
        m = wdata[3:1] > 3'd5 ? wdata[3:1] - 3'd4 : wdata[3:1];
        if (n != 2'd3 && wdata[5:4] != 2'd0) begin
          mode[n] <= m;
          rw[n] <= wdata[5:4];
          msb_next[n] <= 1'b0;
          pending[n] <= 1'b0;
          counting[n] <= 1'b0;
          // a control word sets OUT low in mode 0 and high in the others; OUT1
          // falling clocks counter 0
          out[n] <= m != 3'd0;
          if (n == 2'd1 && out[1] && m == 3'd0) begin
            logic o0;
            clock_n(0, out[0], o0);
            out[0] <= o0;
          end
        end
      end else begin
        logic loaded;
        loaded = 1'b1;
        case (rw[reg_n])
          2'd1: reload[reg_n] <= {8'd0, wdata};
          2'd2: reload[reg_n] <= {wdata, 8'd0};
          2'd3:
            if (!msb_next[reg_n]) begin
              reload[reg_n][7:0] <= wdata;
              msb_next[reg_n] <= 1'b1;
              loaded = 1'b0;
            end else begin
              reload[reg_n][15:8] <= wdata;
              msb_next[reg_n] <= 1'b0;
            end
          default: ;
        endcase
        if (loaded) begin
          // the count is loaded at the next clock; in mode 0 OUT goes low
          pending[reg_n] <= 1'b1;
          if (mode[reg_n] == 3'd0) begin
            out[reg_n] <= 1'b0;
            if (reg_n == 2'd1 && out[1]) begin
              logic o0;
              clock_n(0, out[0], o0);
              out[0] <= o0;
            end
          end
        end
      end
    end else if (tick || tick_late) begin
      // Pit82C54::tick: counter 1, then counter 2; OUT1 falling clocks counter 0
      logic o1, o2, o0;
      clock_n(1, out[1], o1);
      clock_n(2, out[2], o2);
      out[1] <= o1;
      out[2] <= o2;
      if (out[1] && !o1) begin
        clock_n(0, out[0], o0);
        out[0] <= o0;
      end
    end
  end

endmodule
