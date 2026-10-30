#include "nvram.h"
#include <cstdio>
#include <cstring>
#include <ctime>

static uint8_t bcd(int v) { return (uint8_t)(((v / 10) << 4) | (v % 10)); }
static int unbcd(uint8_t v) { return (v >> 4) * 10 + (v & 15); }

Nvram::Nvram(const std::string& p) : path(p) {
  memset(mem, 0, sizeof mem);
  if (!path.empty()) {
    if (FILE* f = fopen(path.c_str(), "rb")) {
      fread(mem, 1, SIZE, f);
      fclose(f);
    }
  }
  latch_clock();
}

Nvram::~Nvram() { save(); }

void Nvram::save() {
  if (!dirty || path.empty()) return;
  if (FILE* f = fopen(path.c_str(), "wb")) {
    fwrite(mem, 1, SIZE, f);
    fclose(f);
  }
  dirty = false;
}

void Nvram::latch_clock() {
  time_t t = now() + offset_seconds;
  struct tm tm;
  gmtime_r(&t, &tm);
  mem[0x7F9] = (mem[0x7F9] & 0x80) | bcd(tm.tm_sec);
  mem[0x7FA] = bcd(tm.tm_min);
  mem[0x7FB] = bcd(tm.tm_hour);
  mem[0x7FC] = (mem[0x7FC] & 0x40) | (uint8_t)(tm.tm_wday + 1);
  mem[0x7FD] = bcd(tm.tm_mday);
  mem[0x7FE] = bcd(tm.tm_mon + 1);
  mem[0x7FF] = bcd(tm.tm_year % 100);
}

W Nvram::read(uint32_t off) {
  off &= SIZE - 1;
  if (off >= 0x7F9 && !frozen && !writing) latch_clock();
  return mkw(DTP_FIXNUM, mem[off]);
}

void Nvram::write(uint32_t off, W w) {
  off &= SIZE - 1;
  uint8_t v = (uint8_t)wdata(w);
  if (off == 0x7F8) {
    bool was_writing = writing;
    writing = v & 0x80;
    frozen = v & 0x40;
    if (was_writing && !writing) {
      // Transfer the new time to the clock: compute an offset from host time.
      struct tm tm;
      memset(&tm, 0, sizeof tm);
      tm.tm_sec = unbcd(mem[0x7F9] & 0x7F);
      tm.tm_min = unbcd(mem[0x7FA]);
      tm.tm_hour = unbcd(mem[0x7FB]);
      tm.tm_mday = unbcd(mem[0x7FD]);
      tm.tm_mon = unbcd(mem[0x7FE]) - 1;
      int y = unbcd(mem[0x7FF]);
      tm.tm_year = y < 70 ? y + 100 : y;
      offset_seconds = (int64_t)timegm(&tm) - (int64_t)now();
    }
    if (frozen || writing) latch_clock();
    mem[off] = v;
  } else {
    mem[off] = v;
  }
  dirty = true;
  if (off < 0x7F8) save();
}
