// The Symbolics console (keyboard, mouse, monitor controls) at the far end of
// the serial line bus, as emu/console.cpp.  Bytes to the processor have the
// form 1TTTCCCC (sysdef *SLB-CONSOLE-BYTE-TYPES*): 0 mouse switch, 1 mouse
// move, 2 all keys up, 3 status, 4 key down, 5 key up; key and status
// messages carry a data byte.  They wait in a FIFO for the I/O board's
// receiver.
module xl_console #(
  // Switchpack: bits 2:1 are the monitor type; 3 = the 80MHz monitor the
  // reference XL1201 reports ("Black and white 80MHz console").
  parameter logic [7:0] SWITCHPACK = 8'd6
) (
  input  logic       clk,
  input  logic       reset,

  // keys: Symbolics key numbers (emu/keyboard.h)
  input  logic       key_strobe,
  input  logic       key_down,
  input  logic [6:0] key_code,
  // mouse: buttons (left, middle, right) and motion (right, down positive)
  input  logic       mouse_strobe,
  input  logic [2:0] mouse_buttons,
  input  logic signed [9:0] mouse_dx,
  input  logic signed [9:0] mouse_dy,

  // from the processor (DUSCC transmitter)
  input  logic       rx_strobe,
  input  logic [7:0] rx_byte,

  // to the processor (DUSCC receiver)
  output logic       tx_pending,
  output logic [7:0] tx_byte,
  input  logic       tx_pop
);

  // ---------------------------------------------------------------- output FIFO
  logic [7:0] fifo [64];
  logic [5:0] rd, wr;
  logic       push;
  logic [7:0] push_byte;
  wire  [5:0] used = wr - rd;
  assign tx_pending = rd != wr;
  assign tx_byte = fifo[rd];
  always_ff @(posedge clk) begin
    if (reset) begin rd <= '0; wr <= '0; end
    else begin
      if (push) begin fifo[wr] <= push_byte; wr <= wr + 6'd1; end
      if (tx_pop && tx_pending) rd <= rd + 6'd1;
    end
  end

  // ---------------------------------------------------------------- key events
  logic [7:0] kq [8];          // {down, code}
  logic [2:0] kq_rd, kq_wr;
  wire        kq_any = kq_rd != kq_wr;
  logic [127:0] keys_down;

  // ---------------------------------------------------------------- state
  logic [7:0] brightness, volume;
  logic [7:0] cmd;              // first byte of a two-byte command
  logic       cmd_held;
  logic       reply;            // a status message to send
  logic [1:0] reply_sub;
  logic [7:0] reply_val;
  logic [2:0] buttons;
  logic       buttons_new;
  logic signed [15:0] mx, my;   // motion not yet sent
  logic       second;           // the data byte of a message is next
  logic [7:0] second_byte;

  always_ff @(posedge clk) begin
    if (reset) begin
      kq_rd <= '0; kq_wr <= '0;
      keys_down <= '0;
      brightness <= 8'd33; volume <= 8'd0;
      cmd_held <= 1'b0;
      reply <= 1'b0;
      buttons <= 3'd0; buttons_new <= 1'b0;
      mx <= '0; my <= '0;
      second <= 1'b0;
    end else begin
      push <= 1'b0;

      if (key_strobe) begin
        kq[kq_wr] <= {key_down, key_code};
        if (kq_wr + 3'd1 != kq_rd) kq_wr <= kq_wr + 3'd1;
      end
      if (mouse_strobe) begin
        if (mouse_buttons != buttons) begin buttons <= mouse_buttons; buttons_new <= 1'b1; end
        mx <= mx + 16'(mouse_dx);
        my <= my + 16'(mouse_dy);
      end

      // Commands (as the FEP's CONSOLE-SWITCHPACK sends them):
      //   0x80 report the switchpack; 0x90 v set brightness; 0x92 v set volume
      if (rx_strobe) begin
        if (!cmd_held && rx_byte == 8'h80) begin
          reply <= 1'b1; reply_sub <= 2'd2; reply_val <= SWITCHPACK;
        end else if (!cmd_held) begin
          cmd <= rx_byte; cmd_held <= 1'b1;
        end else begin
          cmd_held <= 1'b0;
          if (cmd == 8'h90) begin
            if (rx_byte != 8'd0) brightness <= rx_byte;
            reply <= 1'b1; reply_sub <= 2'd0; reply_val <= (rx_byte != 8'd0) ? rx_byte : brightness;
          end else if (cmd == 8'h92) begin
            volume <= {2'd0, rx_byte[5:0]};
            reply <= 1'b1; reply_sub <= 2'd1; reply_val <= {2'd0, rx_byte[5:0]};
          end
        end
      end

      // One byte into the FIFO per cycle while there is room for a whole
      // message; a message's two bytes go in back to back.
      if (second) begin
        push <= 1'b1; push_byte <= second_byte; second <= 1'b0;
      end else if (!push && used < 6'd60) begin
        if (reply && !rx_strobe) begin
          // status: header 1011SSSD, data 0DDDDDDD
          push <= 1'b1; push_byte <= {4'hB, 1'b0, reply_sub, reply_val[7]};
          second <= 1'b1; second_byte <= {1'b0, reply_val[6:0]};
          reply <= 1'b0;
        end else if (kq_any) begin
          logic dn;
          logic [6:0] k;
          logic [127:0] now_down;
          dn = kq[kq_rd][7];
          k = kq[kq_rd][6:0];
          now_down = keys_down;
          now_down[k] = dn;
          keys_down <= now_down;
          kq_rd <= kq_rd + 3'd1;
          push <= 1'b1;
          second <= 1'b1;
          if (dn) begin push_byte <= 8'hC0; second_byte <= {1'b0, k}; end
          else if (now_down == '0) begin push_byte <= 8'hA0; second_byte <= 8'h00; end
          else begin push_byte <= 8'hD0; second_byte <= {1'b0, k}; end
        end else if (buttons_new && !mouse_strobe) begin
          // 1000 0LMR
          push <= 1'b1; push_byte <= {5'b10000, buttons};
          buttons_new <= 1'b0;
        end else if ((mx != 0 || my != 0) && !mouse_strobe) begin
          // one message per unit of motion: 1001LRUD
          push <= 1'b1;
          push_byte <= {4'h9, mx < 0, mx > 0, my < 0, my > 0};
          mx <= (mx < 0) ? mx + 16'sd1 : (mx > 0) ? mx - 16'sd1 : mx;
          my <= (my < 0) ? my + 16'sd1 : (my > 0) ? my - 16'sd1 : my;
        end
      end
    end
  end

endmodule
