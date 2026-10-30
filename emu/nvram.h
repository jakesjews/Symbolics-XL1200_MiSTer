// MK48T02-style 2K x 8 battery-backed RAM with time-of-day clock in the last
// eight bytes, at physical 0x09000000 on the Merlin main board.  Each byte
// appears as one word; only the low eight bits are significant.
#pragma once
#include <cstdint>
#include <ctime>
#include <functional>
#include <string>
#include "ivory.h"

class Nvram {
  friend struct ModelState;   // sim/system: copies state into the RTL
public:
  static const uint32_t SIZE = 2048;
  explicit Nvram(const std::string& path = "");
  ~Nvram();
  W read(uint32_t offset);
  void write(uint32_t offset, W w);
  // Where the clock's time comes from (the host's clock unless replaced, e.g.
  // by a simulation that needs every run to see the same time).
  void set_time_source(std::function<time_t()> f) { now = std::move(f); latch_clock(); }

private:
  uint8_t mem[SIZE];
  std::string path;
  bool dirty = false;
  bool frozen = false;      // control register R bit: clock registers latched
  bool writing = false;     // control register W bit
  int64_t offset_seconds = 0;   // set-time offset from the time source
  std::function<time_t()> now = [] { return time(nullptr); };
  void latch_clock();
  void save();
};
