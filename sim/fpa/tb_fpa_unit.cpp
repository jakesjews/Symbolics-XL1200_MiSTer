// The RTL FPA arithmetic (rtl/xl/xl_fpa_unit.sv) against the C++ model
// (emu/fpa.cpp): random operations and operands, every result bit, flag and
// status code compared.
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

int main(int argc, char** argv) {
  long n = argc > 1 ? atol(argv[1]) : 200000;
  Vxl_fpa_unit top;
  uint64_t t = 0;
  auto tick = [&] { top.clk = 0; top.eval(); top.clk = 1; top.eval(); t++; };
  top.reset = 1; tick(); tick(); top.reset = 0;
  long failures = 0;
  long counts[20] = {};
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
    bool trunc = rng() % 4 == 0, wrap = rng() % 2;
    fpa::Result want = fpa::compute(op, dbl, x, y, mode, trunc, wrap);
    top.op = op; top.dbl = dbl; top.mode = mode; top.trunc = trunc; top.wrap_ovf = wrap; top.x = x; top.y = y;
    top.start = 1;
    tick();
    top.start = 0;
    int guard = 0;
    while (!top.done && guard++ < 200) tick();
    counts[op]++;
    if (!top.done || top.bits != want.bits || top.flags != want.flags || top.status != want.status) {
      if (failures++ < 30)
        printf("op %d dbl %d mode %d trunc %d: %016llx %016llx -> %016llx %02x %d, want %016llx %02x %d%s\n",
               op, dbl, mode, trunc, (unsigned long long)x, (unsigned long long)y,
               (unsigned long long)top.bits, top.flags, top.status, (unsigned long long)want.bits,
               want.flags, want.status, top.done ? "" : " (no done)");
    }
    tick();
  }
  printf("%ld operations, %ld failures, %llu cycles\n", n, failures, (unsigned long long)t);
  return failures != 0;
}
