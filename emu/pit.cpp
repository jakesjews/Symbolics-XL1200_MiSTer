#include "pit.h"

// Counter 0's clock is counter 1's output: each falling edge of OUT1 clocks it.
void Pit82C54::set_out(int n, bool v) {
  bool was = c[n].out;
  c[n].out = v;
  if (n == 1 && was && !v) clock(0);
}

void Pit82C54::write(int reg, uint8_t v) {
  reg &= 3;
  if (reg == 3) {
    int n = v >> 6;
    if (n == 3) return;                  // read-back command
    int rw = (v >> 4) & 3;
    if (rw == 0) return;                 // counter latch command
    Counter& k = c[n];
    k.mode = (v >> 1) & 7;
    if (k.mode > 5) k.mode -= 4;         // 6 and 7 are modes 2 and 3
    k.rw = rw;
    k.msb_next = false;
    k.pending = false;
    k.counting = false;
    // A control word sets OUT low in mode 0 and high in the other modes.
    set_out(n, k.mode != 0);
    return;
  }
  Counter& k = c[reg];
  switch (k.rw) {
  case 1: k.reload = v; break;
  case 2: k.reload = (uint16_t)(v << 8); break;
  case 3:
    if (!k.msb_next) { k.reload = (k.reload & 0xFF00) | v; k.msb_next = true; return; }
    k.reload = (uint16_t)((k.reload & 0x00FF) | (v << 8));
    k.msb_next = false;
    break;
  }
  // The count is loaded at the next clock; in mode 0 writing it sets OUT low.
  k.pending = true;
  if (k.mode == 0) set_out(reg, false);
}

void Pit82C54::clock(int n) {
  Counter& k = c[n];
  uint32_t full = k.reload ? k.reload : 0x10000u;
  if (k.pending) {
    k.pending = false;
    k.value = full;
    k.counting = true;
    return;
  }
  if (!k.counting) return;
  switch (k.mode) {
  case 0:   // interrupt on terminal count: OUT rises at 0 and stays high
    k.value = (k.value - 1) & 0xFFFF;
    if (k.value == 0) set_out(n, true);
    break;
  case 2:   // rate generator: OUT low for the clock at which the count is 1
    if (k.value == 1) {
      set_out(n, false);
      k.value = full;
    } else {
      if (!k.out) set_out(n, true);
      k.value--;
    }
    break;
  default:
    k.value = (k.value - 1) & 0xFFFF;
    break;
  }
}

void Pit82C54::tick(uint64_t clocks) {
  while (clocks--) {
    clock(1);
    clock(2);
  }
}
