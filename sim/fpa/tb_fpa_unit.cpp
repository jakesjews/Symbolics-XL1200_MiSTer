// The RTL FPA arithmetic (rtl/xl/xl_fpa_unit.sv) against the C++ model
// (emu/fpa.cpp): random operations and operands, every result bit, flag and
// status code compared, each result at the latency of Genera's XL1200 table
// (xl_fpa's decode).  Then the same with the shortest latency the unit
// takes, which shows what the arithmetic itself needs: never more.
//   ./obj_dir/Vxl_fpa_unit [N]
#include <cstdio>
#include <cstdlib>
#include <random>
#include "Vxl_fpa_unit.h"
#include "fpa.h"

static std::mt19937_64 rng(2);

// Raw bits, values near one, extreme exponents, and the special classes
static uint64_t operand(bool dbl) {
  uint64_t r = rng();
  int kind = rng() % 8;
  int eb = dbl ? 11 : 8, fb = dbl ? 52 : 23;
  uint64_t emax = (1ull << eb) - 1, fmask = (1ull << fb) - 1, sign = 1ull << (eb + fb);
  uint64_t s = r & sign, f = r & fmask;
  auto mk = [&](uint64_t e) { return s | (e << fb) | f; };
  switch (kind) {
  case 1: r = mk(emax / 2 + rng() % 9 - 4); break;
  case 2: r = mk(rng() % 2 ? 1 + rng() % 40 : emax - 1 - rng() % 40); break;
  case 3: r = mk(emax / 2 + rng() % 120 - 60); break;
  case 4: r = mk(0); break;                                   // denormal (or zero)
  case 5: r = s | (rng() % 2 ? emax << fb : 0); break;        // infinity or zero
  case 6: r = mk(emax); break;                                // NaN (or infinity)
  case 7: r = mk(emax / 2 + rng() % 9 - 4) & ~(fmask >> (rng() % fb)); break;   // short fractions
  }
  return dbl ? r : r & 0xFFFFFFFF;
}

// *FPA-OPERATIONS* (i-sys/float.lisp), in cycles from the start to the first read of the result
static int table_latency(fpa::Op op, bool dbl) {
  if (op == fpa::DIV) return dbl ? 32 : 18;
  if (op == fpa::SQRT) return dbl ? 59 : 29;
  if (dbl && (op == fpa::ADD || op == fpa::SUB)) return 4;
  return 3;
}

static const char* NAMES[20] = {"add", "sub", "mul", "div", "sqrt", "eq", "lt", "gt", "zerop", "minusp",
                                "plusp", "neg", "abs", "i2d", "i2s", "d2s", "s2d", "d2i", "s2i", "imul"};

static long run(Vxl_fpa_unit& top, long n, bool shortest, int work[20][2]) {
  uint64_t t = 0;
  auto tick = [&] { top.clk = 0; top.eval(); top.clk = 1; top.eval(); t++; };
  top.reset = 1; tick(); tick(); top.reset = 0;
  long failures = 0;
  for (long i = 0; i < n; i++) {
    fpa::Op op = (fpa::Op)(rng() % 20);
    bool dbl = rng() % 2;
    bool in64 = op == fpa::D2I || op == fpa::D2S || (dbl && op < fpa::I2D);
    if (op == fpa::I2D || op == fpa::S2D || op == fpa::D2I) dbl = true;
    if (op == fpa::I2S || op == fpa::D2S || op == fpa::S2I || op == fpa::IMUL) dbl = false;
    in64 = op == fpa::D2I || op == fpa::D2S || (dbl && op < fpa::I2D);
    uint64_t x = operand(in64), y = operand(in64);
    if (op == fpa::I2D || op == fpa::I2S || op == fpa::IMUL) {
      x = (uint32_t)rng(); y = (uint32_t)rng();
      if (rng() % 2) { x = (uint32_t)((int32_t)x >> (rng() % 31)); y = (uint32_t)((int32_t)y >> (rng() % 31)); }
    }
    if (op == fpa::S2I || op == fpa::D2I) {   // mostly in range
      int e = (int)(rng() % 40) - 4;
      if (in64) y = (y & 0x800FFFFFFFFFFFFFull) | (uint64_t)(1023 + e) << 52;
      else y = (y & 0x807FFFFF) | (uint32_t)(127 + e) << 23;
    }
    int mode = rng() % 4;
    bool trunc = rng() % 4 == 0, unfr = rng() % 2, dexc = rng() % 4 != 0;
    fpa::Result want = fpa::compute(op, dbl, x, y, mode, trunc, unfr, dexc);
    top.op = op; top.dbl = dbl; top.mode = mode; top.trunc = trunc; top.unf_round = unfr;
    top.dnrm_exc = dexc; top.x = x; top.y = y;
    int lat = table_latency(op, dbl);
    top.lat = shortest ? 3 : lat;
    top.start = 1;
    tick();
    top.start = 0;
    // done in the cycle lat - 1 after the start, the result readable at lat
    int k = 1;
    while (!top.done && k < 200) { tick(); k++; }
    bool late = shortest ? k + 1 > lat : k + 1 != lat;
    if (k + 1 > work[op][dbl]) work[op][dbl] = k + 1;
    if (!top.done || late || top.bits != want.bits || top.flags != want.flags || top.status != want.status) {
      if (failures++ < 30)
        printf("%s dbl %d mode %d trunc %d: %016llx %016llx -> %016llx %02x %d, want %016llx %02x %d; "
               "readable at %d, latency %d%s\n",
               NAMES[op], dbl, mode, trunc, (unsigned long long)x, (unsigned long long)y,
               (unsigned long long)top.bits, top.flags, top.status, (unsigned long long)want.bits,
               want.flags, want.status, k + 1, lat, top.done ? "" : " (no done)");
    }
    tick();
    if (top.busy) { if (failures++ < 30) printf("busy after done\n"); }
  }
  printf("%ld operations%s, %ld failures, %llu cycles\n", n, shortest ? " at the shortest latency" : "",
         failures, (unsigned long long)t);
  return failures;
}

int main(int argc, char** argv) {
  long n = argc > 1 ? atol(argv[1]) : 200000;
  Vxl_fpa_unit top;
  int at_table[20][2] = {}, shortest[20][2] = {};
  long failures = run(top, n, false, at_table);
  failures += run(top, n, true, shortest);
  printf("cycles from the start to a readable result, single/double: the arithmetic's own (the table's)\n");
  for (int op = 0; op < 20; op++)
    printf("  %-6s %2d/%-2d (%d/%d)\n", NAMES[op], shortest[op][0], shortest[op][1],
           table_latency((fpa::Op)op, false), table_latency((fpa::Op)op, true));
  return failures != 0;
}
