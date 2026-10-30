// MK48T02-style 2K x 8 battery-backed RAM with a time-of-day clock in the
// last eight bytes, at physical 0x09000000 on the Merlin main board; one
// byte per word (emu/nvram.cpp).
//
//   0x7F8 control: bit 7 W (write the clock), bit 6 R (read: hold the
//         registers still)
//   0x7F9 seconds (bit 7 stop), 0x7FA minutes, 0x7FB hours, 0x7FC day of
//         the week 1-7 (bit 6 frequency test), 0x7FD date, 0x7FE month,
//         0x7FF year, all BCD
//
// The clock runs from a once-a-second pulse and starts from MiSTer's RTC.
// Reads of the clock registers show the running clock unless R or W is set;
// setting R or W latches it, and clearing W loads the registers into it.
// The RAM is not kept across power cycles (no battery yet).
module xl_nvram (
  input  logic        clk,
  input  logic        second,      // pulse: one second has passed
  input  logic [64:0] rtc,         // hps_io RTC: BCD sec, min, hour, date, month, year, weekday 0-6
  input  logic        back28,      // start the clock 28 years back (Genera rejects dates after 1999)

  input  logic        req,
  input  logic        we,
  input  logic [10:0] addr,
  input  logic [7:0]  wdata,
  output logic        ack,
  output logic [7:0]  rdata
);

  logic [7:0] clock_q;
  assign rdata = (addr < 11'h7F8) ? ram_q : clock_q;

  logic [7:0] ram [2048];
  logic [7:0] ram_q;
  always_ff @(posedge clk) begin
    if (req && !ack && we && addr < 11'h7F8) ram[addr] <= wdata;
    ram_q <= ram[addr];
  end

  // The running clock and the register copies
  logic [7:0] c_sec, c_min, c_hour, c_day, c_date, c_month, c_year;
  logic [7:0] r [8];           // 0x7F8-0x7FF as last latched or written
  logic       writing = 1'b0, frozen = 1'b0;
  logic       loaded = 1'b0;
  logic       rtc_seen = 1'b0;

  function automatic logic [7:0] bcd_inc(input logic [7:0] v);
    return (v[3:0] == 4'd9) ? {v[7:4] + 4'd1, 4'd0} : {v[7:4], v[3:0] + 4'd1};
  endfunction
  function automatic logic [7:0] days_in_month(input logic [7:0] month, input logic [7:0] year);
    logic leap;
    leap = year[4] ? (year[3:0] == 4'd2 || year[3:0] == 4'd6)
                   : (year[3:0] == 4'd0 || year[3:0] == 4'd4 || year[3:0] == 4'd8);
    case (month)
      8'h02: return leap ? 8'h29 : 8'h28;
      8'h04, 8'h06, 8'h09, 8'h11: return 8'h30;
      default: return 8'h31;
    endcase
  endfunction
  // BCD year minus 28, mod 100
  function automatic logic [7:0] minus28(input logic [7:0] y);
    logic [6:0] b;
    b = 7'(y[7:4]) * 7'd10 + 7'(y[3:0]);
    b = (b >= 7'd28) ? b - 7'd28 : b + 7'd72;
    return {4'(b / 7'd10), 4'(b % 7'd10)};
  endfunction

  // The clock as register i shows it (stop and FT bits from the copies)
  function automatic logic [7:0] live(input logic [2:0] i);
    case (i)
      3'd1: return {r[1][7], c_sec[6:0]};
      3'd2: return c_min;
      3'd3: return c_hour;
      3'd4: return {1'b0, r[4][6], c_day[5:0]};
      3'd5: return c_date;
      3'd6: return c_month;
      3'd7: return c_year;
      default: return r[0];
    endcase
  endfunction

  always_ff @(posedge clk) begin
    ack <= req && !ack;
    rtc_seen <= rtc[64];

    // the clock
    if (!loaded && rtc[64] != rtc_seen) begin
      c_sec <= rtc[7:0]; c_min <= rtc[15:8]; c_hour <= rtc[23:16];
      c_date <= rtc[31:24]; c_month <= rtc[39:32];
      c_year <= back28 ? minus28(rtc[47:40]) : rtc[47:40];
      // 28 years keep the day of the week
      c_day <= {5'd0, rtc[50:48]} + 8'd1;
      loaded <= 1'b1;
    end else if (second) begin
      if (c_sec != 8'h59) c_sec <= bcd_inc(c_sec);
      else begin
        c_sec <= 8'h00;
        if (c_min != 8'h59) c_min <= bcd_inc(c_min);
        else begin
          c_min <= 8'h00;
          if (c_hour != 8'h23) c_hour <= bcd_inc(c_hour);
          else begin
            c_hour <= 8'h00;
            c_day <= (c_day[2:0] == 3'd7) ? 8'd1 : c_day + 8'd1;
            if (c_date != days_in_month(c_month, c_year)) c_date <= bcd_inc(c_date);
            else begin
              c_date <= 8'h01;
              if (c_month != 8'h12) c_month <= bcd_inc(c_month);
              else begin
                c_month <= 8'h01;
                c_year <= (c_year == 8'h99) ? 8'h00 : bcd_inc(c_year);
              end
            end
          end
        end
      end
    end

    // accesses
    if (req && !ack) begin
      if (addr >= 11'h7F8) begin
        logic [2:0] i;
        i = addr[2:0];
        if (we) begin
          if (i == 3'd0) begin
            writing <= wdata[7];
            frozen <= wdata[6];
            if (writing && !wdata[7]) begin   // W cleared: the clock takes the registers
              c_sec <= {1'b0, r[1][6:0]}; c_min <= r[2]; c_hour <= r[3]; c_day <= {2'd0, r[4][5:0]};
              c_date <= r[5]; c_month <= r[6]; c_year <= r[7];
              loaded <= 1'b1;
            end
            // R or W latches the clock (unless this write ends a W)
            if (wdata[7:6] != 2'd0 && !(writing && !wdata[7]))
              for (int k = 1; k < 8; k++) r[k] <= live(3'(k));   // latch
            r[0] <= wdata;
          end else r[i] <= wdata;
        end else begin
          if (i != 3'd0 && !frozen && !writing) begin
            clock_q <= live(i);
            for (int k = 1; k < 8; k++) r[k] <= live(3'(k));
          end else clock_q <= r[i];
        end
      end
    end
  end

endmodule
