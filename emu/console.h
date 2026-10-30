// The Symbolics console (keyboard, mouse, monitor) as seen over the serial
// line bus.  Bytes from the console have the form 1TTTCCCC (sysdef
// *SLB-CONSOLE-BYTE-TYPES*): 0 mouse switch, 1 mouse move, 2 all keys up,
// 3 status, 4 key down, 5 key up; key and status messages carry a data byte.
#pragma once
#include <cstdint>
#include <deque>
#include <vector>

class Console {
  friend struct ModelState;   // sim/system: copies state into the RTL
public:
  // Switchpack status.  Bits 2:1 are the monitor type (index into the FEP's
  // B&W monitor table, see STREAM-MONITOR-ID): 1 = Moniterm, 3 = the 80MHz
  // monitor Douglas Fields' XL1201 reports ("Black and white 80MHz console").
  // Bits 0 and 4 are returned as two further flags.
  uint8_t switchpack = 3 << 1;
  uint8_t brightness = 33, volume = 0;

  void from_cpu(uint8_t b);              // a byte the CPU sent to the console
  bool to_cpu_pending() const { return !out.empty(); }
  uint8_t to_cpu_next() { uint8_t b = out.front(); out.pop_front(); return b; }

  void key(uint8_t code, bool down);     // Symbolics key number (keyboard.h)
  void type(const char* text);           // press and release keys for ASCII text
  void mouse_buttons(bool l, bool m, bool r);
  void mouse_move(int dx, int dy);

private:
  std::deque<uint8_t> out;
  std::vector<uint8_t> cmd;
  std::vector<uint8_t> keys_down;
  void status(int subtype, uint8_t value);
};
