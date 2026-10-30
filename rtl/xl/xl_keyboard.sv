// PS/2 keyboard (scan code set 2, as hps_io delivers it) to Symbolics key
// numbers (the :symbolics layout, sys.sct/embedding/keyboards/keyboards.lisp).
// The mapping is docs/keyboard.md.
module xl_keyboard (
  input  logic        clk,
  input  logic [10:0] ps2_key,     // [10] toggles per event, [9] pressed, [8] E0 prefix, [7:0] code
  output logic        key_strobe,
  output logic        key_down,
  output logic [6:0]  key_code
);

  // 7'h7F: no Symbolics key
  function automatic logic [6:0] symbolics_key(input logic ext, input logic [7:0] sc);
    if (!ext) case (sc)
      8'h1C: return 7'o051;  8'h32: return 7'o022;  8'h21: return 7'o021;  8'h23: return 7'o052;  // A B C D
      8'h24: return 7'o072;  8'h2B: return 7'o042;  8'h34: return 7'o053;  8'h33: return 7'o043;  // E F G H
      8'h43: return 7'o064;  8'h3B: return 7'o054;  8'h42: return 7'o044;  8'h4B: return 7'o055;  // I J K L
      8'h3A: return 7'o023;  8'h31: return 7'o033;  8'h44: return 7'o075;  8'h4D: return 7'o065;  // M N O P
      8'h15: return 7'o071;  8'h2D: return 7'o062;  8'h1B: return 7'o041;  8'h2C: return 7'o073;  // Q R S T
      8'h3C: return 7'o074;  8'h2A: return 7'o032;  8'h1D: return 7'o061;  8'h22: return 7'o031;  // U V W X
      8'h35: return 7'o063;  8'h1A: return 7'o020;                                                // Y Z
      8'h16: return 7'o110;  8'h1E: return 7'o101;  8'h26: return 7'o111;  8'h25: return 7'o102;  // 1 2 3 4
      8'h2E: return 7'o112;  8'h36: return 7'o103;  8'h3D: return 7'o113;  8'h3E: return 7'o104;  // 5 6 7 8
      8'h46: return 7'o114;  8'h45: return 7'o105;                                                // 9 0
      8'h4E: return 7'o115;  8'h55: return 7'o106;  8'h0E: return 7'o116;  8'h5D: return 7'o107;  // - = ` \
      8'h54: return 7'o076;  8'h5B: return 7'o066;                         // [ ] -> the ( and ) keys
      8'h4C: return 7'o045;  8'h52: return 7'o056;  8'h41: return 7'o034;  8'h49: return 7'o024;  // ; ' , .
      8'h4A: return 7'o035;                                                                       // /
      8'h29: return 7'o014;  8'h0D: return 7'o070;  8'h5A: return 7'o046;  // Space Tab Return
      8'h66: return 7'o040;                                                // Backspace: Rubout
      8'h76: return 7'o120;                                                // Esc: Escape
      8'h12: return 7'o030;  8'h59: return 7'o025;                         // Shifts
      8'h14: return 7'o013;                                                // Left Control
      8'h11: return 7'o003;                                                // Left Alt: Meta
      8'h77: return 7'o011;                                                // Num Lock: Symbol
      8'h58: return 7'o001;                                                // Caps Lock
      8'h7E: return 7'o007;                                                // Scroll Lock: Mode Lock
      8'h05: return 7'o010;  8'h06: return 7'o050;  8'h04: return 7'o060;  // F1 Select, F2 Network, F3 Function
      8'h0C: return 7'o126;  8'h03: return 7'o127;  8'h0B: return 7'o027;  // F4 Suspend, F5 Resume, F6 Abort
      8'h83: return 7'o125;  8'h0A: return 7'o047;  8'h01: return 7'o037;  // F7 Clear Input, F8 Complete, F9 Help
      8'h09: return 7'o057;  8'h78: return 7'o067;                         // F10 Line, F11 Page
      default: return 7'h7F;
    endcase
    else case (sc)
      8'h14: return 7'o004;                                                // Right Control
      8'h11: return 7'o036;                                                // Right Alt: Symbol
      8'h1F: return 7'o012;  8'h27: return 7'o005;  8'h2F: return 7'o002;  // Windows: Super, Menu: Hyper
      8'h71: return 7'o040;                                                // Delete: Rubout
      8'h5A: return 7'o017;  8'h69: return 7'o017;                         // keypad Enter, End: End
      8'h6C: return 7'o121;                                                // Home: Refresh
      8'h7D: return 7'o122;  8'h7A: return 7'o006;  8'h7C: return 7'o124;  // Page Up Square, Page Down Scroll, Print Screen Triangle
      8'h70: return 7'o117;                                                // Insert: |
      default: return 7'h7F;
    endcase
  endfunction

  // The Symbolics keyboard sends a key once (repeating is the REPEAT key's
  // job), so the PC keyboard's typematic repeats are dropped.
  logic         seen = 1'b0;
  logic [127:0] down = '0;
  always_ff @(posedge clk) begin
    logic [6:0] k;
    key_strobe <= 1'b0;
    seen <= ps2_key[10];
    k = symbolics_key(ps2_key[8], ps2_key[7:0]);
    if (ps2_key[10] != seen && k != 7'h7F && down[k] != ps2_key[9]) begin
      down[k] <= ps2_key[9];
      key_strobe <= 1'b1;
      key_down <= ps2_key[9];
      key_code <= k;
    end
  end

endmodule
