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
// The clock runs from a once-a-second pulse and starts from MiSTer's
// timestamp (hps_io TIMESTAMP, seconds since 1970). Genera reads the chip as
// GMT and applies the site's time zone, so the timestamp has to be UTC:
// MiSTer_xl1200 sends it that way, as the main program does for the NeXT and
// HP 9000 cores (the stock main program sends local time). Every timestamp
// sent is taken until the machine sets the clock itself (W cleared), as the
// NeXT core does: Main sends one when the core loads and one a minute after
// that, so a core loaded before the MiSTer had its time from the network gets
// it when it arrives.
// Reads of the clock registers show the running clock unless R or W is set;
// setting R or W latches it, and clearing W loads the registers into it.
// The RAM is not kept across power cycles (no battery yet).
module xl_nvram (
  input  logic        clk,
  input  logic        second,      // pulse: one second has passed
  input  logic [32:0] timestamp,   // hps_io TIMESTAMP: seconds since 1970; bit 32 toggles with each new value
  input  logic        back28,      // run the clock 28 years back (Genera 8.3 rejects dates after 1999)

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
  logic       guest_set = 1'b0;   // the machine has set the clock: timestamps no longer apply

  function automatic logic [7:0] bcd_inc(input logic [7:0] v);
    return (v[3:0] == 4'd9) ? {v[7:4] + 4'd1, 4'd0} : {v[7:4], v[3:0] + 4'd1};
  endfunction
  // BCD year 00-99 as 1970-2069: a leap year when divisible by 4 (2000 is one)
  function automatic logic leap(input logic [7:0] year);
    return year[4] ? (year[3:0] == 4'd2 || year[3:0] == 4'd6)
                   : (year[3:0] == 4'd0 || year[3:0] == 4'd4 || year[3:0] == 4'd8);
  endfunction
  function automatic logic [7:0] days_in_month(input logic [7:0] month, input logic [7:0] year);
    case (month)
      8'h02: return leap(year) ? 8'h29 : 8'h28;
      8'h04, 8'h06, 8'h09, 8'h11: return 8'h30;
      default: return 8'h31;
    endcase
  endfunction
  function automatic logic [15:0] days_in_month_bin(input logic [7:0] month, input logic [7:0] year);
    case (month)
      8'h02: return leap(year) ? 16'd29 : 16'd28;
      8'h04, 8'h06, 8'h09, 8'h11: return 16'd30;
      default: return 16'd31;
    endcase
  endfunction
  // 0-59 to BCD
  function automatic logic [7:0] to_bcd(input logic [5:0] v);
    logic [3:0] tens;
    tens = (v >= 6'd50) ? 4'd5 : (v >= 6'd40) ? 4'd4 : (v >= 6'd30) ? 4'd3 :
           (v >= 6'd20) ? 4'd2 : (v >= 6'd10) ? 4'd1 : 4'd0;
    return {tens, 4'(v - 6'(tens) * 6'd10)};
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

  // Seconds since 1970 to the clock's registers: one subtraction a cycle
  // through a single subtractor, taking a day, a year, a month, an hour or a
  // minute off what is left each time; about 21,000 cycles for a date in the
  // 2020s. 28 years back is 10,227 days: seven leap days in any 28 years this
  // side of 2100, and 1461 weeks exactly, so the day of the week keeps.
  localparam [31:0] DAY    = 32'd86400;
  localparam [31:0] BACK28 = 32'd883612800;
  typedef enum logic [2:0] {C_IDLE, C_BACK, C_DAYS, C_YEARS, C_MONTHS, C_HOURS, C_MINUTES, C_DONE} cstate_t;
  cstate_t     cstate = C_IDLE;
  logic        ts_seen = 1'b0, ts_pend = 1'b0;
  logic [31:0] t;              // seconds still to place
  logic [15:0] d;              // days still to place
  logic [7:0]  n_sec, n_min, n_hour, n_day, n_date, n_month, n_year;   // the registers being built
  logic [31:0] k;              // what this state takes off t
  logic [15:0] dk;             // or off d
  logic [32:0] tdiff;          // t - k, bit 32 set when t < k
  logic [16:0] ddiff;          // d - dk, bit 16 set when d < dk
  always_comb begin
    case (cstate)
      C_BACK:  k = BACK28;
      C_DAYS:  k = DAY;
      C_HOURS: k = 32'd3600;
      default: k = 32'd60;
    endcase
    dk = (cstate == C_YEARS) ? (leap(n_year) ? 16'd366 : 16'd365) : days_in_month_bin(n_month, n_year);
    tdiff = {1'b0, t} - {1'b0, k};
    ddiff = {1'b0, d} - {1'b0, dk};
  end

  always_ff @(posedge clk) begin
    ack <= req && !ack;

    // a new timestamp
    ts_seen <= timestamp[32];
    if (timestamp[32] != ts_seen) ts_pend <= 1'b1;
    case (cstate)
      C_IDLE: if (ts_pend && !guest_set) begin
        ts_pend <= 1'b0;
        t <= timestamp[31:0];
        d <= 16'd0;
        n_sec <= 8'h00; n_min <= 8'h00; n_hour <= 8'h00;
        n_day <= 8'd5;                                   // 1970-01-01 was a Thursday (1 Sunday .. 7 Saturday)
        n_date <= 8'h01; n_month <= 8'h01; n_year <= 8'h70;
        cstate <= C_BACK;
      end
      C_BACK: begin                                      // the 28 years, when asked and when there are 28 to take
        if (back28 && !tdiff[32]) t <= tdiff[31:0];
        cstate <= C_DAYS;
      end
      C_DAYS: if (!tdiff[32]) begin
        t <= tdiff[31:0];
        d <= d + 16'd1;
        n_day <= (n_day == 8'd7) ? 8'd1 : n_day + 8'd1;
      end else cstate <= C_YEARS;
      C_YEARS: if (!ddiff[16]) begin
        d <= ddiff[15:0];
        n_year <= (n_year == 8'h99) ? 8'h00 : bcd_inc(n_year);
      end else cstate <= C_MONTHS;
      C_MONTHS: if (!ddiff[16]) begin
        d <= ddiff[15:0];
        n_month <= bcd_inc(n_month);
      end else begin
        n_date <= to_bcd(d[5:0] + 6'd1);
        cstate <= C_HOURS;
      end
      C_HOURS: if (!tdiff[32]) begin
        t <= tdiff[31:0];
        n_hour <= bcd_inc(n_hour);
      end else cstate <= C_MINUTES;
      C_MINUTES: if (!tdiff[32]) begin
        t <= tdiff[31:0];
        n_min <= bcd_inc(n_min);
      end else begin
        n_sec <= to_bcd(t[5:0]);
        cstate <= C_DONE;
      end
      C_DONE: cstate <= C_IDLE;                          // the clock takes it below
      default: cstate <= C_IDLE;
    endcase

    // the clock
    if (cstate == C_DONE && !guest_set) begin
      c_sec <= n_sec; c_min <= n_min; c_hour <= n_hour; c_day <= n_day;
      c_date <= n_date; c_month <= n_month; c_year <= n_year;
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
              guest_set <= 1'b1;
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
