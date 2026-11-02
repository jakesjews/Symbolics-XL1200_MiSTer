// Intel 82C54 programmable interval timer on the Merlin-II main board, at
// physical 0x08000000 (registers 0-2 the counters, 3 the control word),
// clocked at 1 MHz.  Genera (i-sys/interrupts.lisp) uses counter 2 in mode 0
// as its periodic timer and cascades counters 1 and 0 (counter 0 counts
// counter 1's output) as its interval timer; their outputs are bits 0 and 1
// of the main board's interrupt register.  Only what Genera uses: modes 0
// and 2, binary counts, no read-back.
#pragma once
#include <cstdint>

class Pit82C54 {
  friend struct ModelState;   // sim/system: copies state into the RTL
  friend struct Snapshot;     // emu/snapshot.cpp: saves and restores the state
public:
  void write(int reg, uint8_t v);
  void tick(uint64_t clocks);     // advance by n 1 MHz clocks
  bool out(int n) const { return c[n].out; }

private:
  struct Counter {
    uint8_t mode = 0, rw = 3;
    bool msb_next = false;        // rw 3: the next count byte is the MSB
    uint16_t reload = 0;          // count register
    uint32_t value = 0;           // counting element
    bool pending = false;         // a count is written but not yet loaded
    bool counting = false;
    bool out = false;
  } c[3];
  void clock(int n);              // one falling edge on counter n's clock
  void set_out(int n, bool v);
};
