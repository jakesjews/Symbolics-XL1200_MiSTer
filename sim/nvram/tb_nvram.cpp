// The calendar clock in rtl/xl/xl_nvram.sv against the host's gmtime.
//   - MiSTer's timestamp (seconds since 1970, UTC) to the MK48T02's BCD
//     registers, with and without the 28 years back, for fixed dates around
//     the leap days and the ends of years and for random dates before 2100
//   - the running clock (the once-a-second pulse) across the ends of days,
//     months and years, including February 29th and 1999 to 2000
//   - a second timestamp is taken; after the machine sets the clock itself
//     (W set, registers written, W cleared) a timestamp is not
// Exit status 0 when everything matches.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <random>
#include "Vxl_nvram.h"

static Vxl_nvram* top;
static uint64_t ticks = 0;
static int failures = 0;

static void tick() {
  top->clk = 0; top->eval();
  top->clk = 1; top->eval();
  ticks++;
}

// one bus access: req until ack (one cycle), the read data registered with it
static uint8_t access(uint16_t addr, bool we, uint8_t wdata = 0) {
  top->req = 1; top->we = we; top->addr = addr; top->wdata = wdata;
  tick();
  uint8_t v = top->rdata;
  top->req = 0; top->we = 0;
  tick();
  return v;
}

struct Clock { int sec, min, hour, wday, mday, mon, year; };   // wday 1 Sunday .. 7 Saturday, year 0-99

static int unbcd(uint8_t v) { return (v >> 4) * 10 + (v & 15); }
static uint8_t bcd(int v) { return (uint8_t)(((v / 10) << 4) | (v % 10)); }

// Read the clock as Genera's driver does, with R set, or live
static Clock read_clock(bool hold) {
  if (hold) access(0x7F8, true, 0x40);
  Clock c;
  c.sec  = unbcd(access(0x7F9, false) & 0x7F);
  c.min  = unbcd(access(0x7FA, false));
  c.hour = unbcd(access(0x7FB, false));
  c.wday = access(0x7FC, false) & 7;
  c.mday = unbcd(access(0x7FD, false));
  c.mon  = unbcd(access(0x7FE, false));
  c.year = unbcd(access(0x7FF, false));
  if (hold) access(0x7F8, true, 0x00);
  return c;
}

static const uint32_t BACK28 = 883612800u;   // 10,227 days

static Clock expect(uint32_t epoch, bool back28) {
  time_t t = (back28 && epoch >= BACK28) ? epoch - BACK28 : epoch;
  struct tm tm;
  gmtime_r(&t, &tm);
  return {tm.tm_sec, tm.tm_min, tm.tm_hour, tm.tm_wday + 1, tm.tm_mday, tm.tm_mon + 1, tm.tm_year % 100};
}

static bool same(const Clock& a, const Clock& b) {
  return a.sec == b.sec && a.min == b.min && a.hour == b.hour && a.wday == b.wday &&
         a.mday == b.mday && a.mon == b.mon && a.year == b.year;
}

static void check(const char* what, uint32_t epoch, bool back28, const Clock& got, const Clock& want) {
  if (same(got, want)) return;
  failures++;
  fprintf(stderr, "%s: epoch %u back28 %d: got %02d-%02d-%02d %02d:%02d:%02d wday %d, want %02d-%02d-%02d %02d:%02d:%02d wday %d\n",
          what, epoch, back28, got.year, got.mon, got.mday, got.hour, got.min, got.sec, got.wday,
          want.year, want.mon, want.mday, want.hour, want.min, want.sec, want.wday);
}

// A new timestamp from the main program: the value, then the toggle; the
// conversion takes one cycle per day, year, month, hour and minute (under
// 50,000 for any 32-bit value).
static void send(uint32_t epoch) {
  top->timestamp = ((top->timestamp ^ (1ull << 32)) & (1ull << 32)) | epoch;
  for (int i = 0; i < 52000; i++) tick();
}

static void pulse_second() {
  top->second = 1; tick();
  top->second = 0; tick();
}

static uint32_t at(int y, int mo, int d, int h, int mi, int s) {
  struct tm tm = {};
  tm.tm_year = y - 1900; tm.tm_mon = mo - 1; tm.tm_mday = d;
  tm.tm_hour = h; tm.tm_min = mi; tm.tm_sec = s;
  return (uint32_t)timegm(&tm);
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  top = new Vxl_nvram;
  top->clk = 0; top->second = 0; top->back28 = 0; top->req = 0; top->we = 0;
  top->timestamp = 0;
  for (int i = 0; i < 4; i++) tick();

  int conversions = 0;

  // 1. Fixed dates, both settings, read with R set and live
  const uint32_t fixed[] = {
    0, 86399, 86400,                                   // 1970-01-01, a Thursday
    at(1972, 2, 29, 12, 0, 0),                         // the first leap day since 1970
    at(1999, 12, 31, 23, 59, 59), at(2000, 1, 1, 0, 0, 0),
    at(2000, 2, 28, 23, 59, 59), at(2000, 2, 29, 0, 0, 0), at(2000, 2, 29, 23, 59, 59), at(2000, 3, 1, 0, 0, 0),
    at(2001, 2, 28, 23, 59, 59), at(2001, 3, 1, 0, 0, 0),
    at(2024, 2, 29, 6, 30, 15),
    at(2026, 11, 9, 20, 47, 20),                       // a Monday
    at(2028, 2, 29, 0, 0, 0),                          // 28 years back: 2000-02-29
    at(2038, 1, 19, 3, 14, 7), at(2038, 1, 19, 3, 14, 8),   // past a signed 32-bit time_t
    at(2069, 12, 31, 23, 59, 59),
    at(2099, 12, 31, 23, 59, 59),
    BACK28 - 1, BACK28, BACK28 + 1,                    // 28 years back: 1970 or not
  };
  for (uint32_t e : fixed)
    for (int b = 0; b < 2; b++) {
      top->back28 = b;
      send(e);
      conversions++;
      check("fixed, held", e, b, read_clock(true), expect(e, b));
      check("fixed, live", e, b, read_clock(false), expect(e, b));
    }

  // 2. Random dates before 2100 (the chip's two-digit year as 1970-2069 or
  //    the 28 years before; 2100 is not a leap year and is out of range)
  std::mt19937 rng(1200);
  std::uniform_int_distribution<uint32_t> dist(0, at(2099, 12, 31, 23, 59, 59));
  for (int i = 0; i < 400; i++) {
    uint32_t e = dist(rng);
    int b = i & 1;
    top->back28 = b;
    send(e);
    conversions++;
    check("random", e, b, read_clock(true), expect(e, b));
  }

  // 3. The running clock across the ends of days, months and years
  top->back28 = 0;
  struct Run { uint32_t from; int seconds; } runs[] = {
    {at(1970, 1, 31, 23, 59, 58), 5},      // January to February
    {at(1999, 12, 31, 23, 59, 55), 10},    // 99 to 00
    {at(2000, 2, 28, 23, 59, 58), 5},      // into February 29th
    {at(2000, 2, 29, 23, 59, 50), 20},     // out of it
    {at(2001, 2, 28, 23, 59, 55), 10},     // no leap day
    {at(2024, 12, 31, 23, 59, 58), 5},     // year end
    {at(2026, 11, 7, 23, 59, 58), 5},      // Saturday to Sunday: weekday 7 to 1
    {at(2026, 4, 30, 23, 59, 58), 5},      // a 30-day month
  };
  for (const Run& r : runs) {
    send(r.from);
    conversions++;
    for (int s = 1; s <= r.seconds; s++) {
      pulse_second();
      check("running", r.from + s, 0, read_clock(true), expect(r.from + s, 0));
    }
  }

  // 4. A second timestamp is taken; after the machine sets the clock, not
  top->back28 = 1;
  send(at(2026, 11, 9, 20, 0, 0));
  send(at(2026, 11, 9, 20, 1, 0));
  conversions += 2;
  check("resend", at(2026, 11, 9, 20, 1, 0), 1, read_clock(true), expect(at(2026, 11, 9, 20, 1, 0), 1));
  {
    // Genera's MERLIN-SET-CALENDAR-CLOCK-INTERNAL: W set, the registers, W cleared
    access(0x7F8, true, 0x80);
    access(0x7F9, true, bcd(56)); access(0x7FA, true, bcd(34)); access(0x7FB, true, bcd(12));
    access(0x7FC, true, 3);                                   // a Tuesday
    access(0x7FD, true, bcd(4)); access(0x7FE, true, bcd(7)); access(0x7FF, true, bcd(95));   // 1995-07-04
    access(0x7F8, true, 0x00);
    Clock set = {56, 34, 12, 3, 4, 7, 95};
    check("set by the machine", 0, 1, read_clock(true), set);
    send(at(2026, 11, 9, 20, 2, 0));
    conversions++;
    check("timestamp after the machine set it", 0, 1, read_clock(true), set);
    pulse_second();
    set.sec = 57;
    check("running after the machine set it", 0, 1, read_clock(true), set);
  }

  if (failures) {
    fprintf(stderr, "%d mismatches in %d conversions\n", failures, conversions);
    return 1;
  }
  printf("calendar clock: %d conversions and the running clock match gmtime (%llu cycles)\n",
         conversions, (unsigned long long)ticks);
  delete top;
  return 0;
}
