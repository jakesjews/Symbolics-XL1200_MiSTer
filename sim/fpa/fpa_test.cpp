// Checks the FPA's arithmetic (emu/fpa.cpp) against the host's IEEE floating
// point in all four rounding modes, outside the cases where the 3164 differs
// on purpose (denormalized operands and results, NaN payloads).
//   ./fpa_test [N]
#include <cfenv>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include "fpa.h"

#pragma STDC FENV_ACCESS ON

using fpa::Result;
static std::mt19937_64 rng(1);
static long failures = 0, checked = 0;

static const int host_mode[4] = {FE_TONEAREST, FE_TOWARDZERO, FE_UPWARD, FE_DOWNWARD};

static float f32(uint32_t b) { float f; memcpy(&f, &b, 4); return f; }
static uint32_t b32(float f) { uint32_t b; memcpy(&b, &f, 4); return b; }
static double f64(uint64_t b) { double f; memcpy(&f, &b, 8); return f; }
static uint64_t b64(double f) { uint64_t b; memcpy(&b, &f, 8); return b; }

// Random operands: raw bits, values near one, and extreme exponents
static uint64_t operand(bool dbl) {
  uint64_t r = rng();
  int kind = rng() % 4;
  if (dbl) {
    if (kind == 1) r = (r & 0x800FFFFFFFFFFFFFull) | (uint64_t)(1023 + (int)(rng() % 9) - 4) << 52;
    if (kind == 2) r = (r & 0x800FFFFFFFFFFFFFull) | (uint64_t)(rng() % 2 ? 1 + rng() % 60 : 2046 - rng() % 60) << 52;
    if (kind == 3) r = (r & 0x800FFFFFFFFFFFFFull) | (uint64_t)(1023 + (int)(rng() % 120) - 60) << 52;
    return r;
  }
  r &= 0xFFFFFFFF;
  if (kind == 1) r = (r & 0x807FFFFF) | (uint32_t)(127 + (int)(rng() % 9) - 4) << 23;
  if (kind == 2) r = (r & 0x807FFFFF) | (uint32_t)(rng() % 2 ? 1 + rng() % 30 : 254 - rng() % 30) << 23;
  if (kind == 3) r = (r & 0x807FFFFF) | (uint32_t)(127 + (int)(rng() % 60) - 30) << 23;
  return r;
}

static bool is_den(uint64_t b, bool dbl) {
  return dbl ? ((b >> 52) & 0x7FF) == 0 && (b & 0xFFFFFFFFFFFFFull)
             : ((b >> 23) & 0xFF) == 0 && (b & 0x7FFFFF);
}
static bool is_nan(uint64_t b, bool dbl) {
  return dbl ? ((b >> 52) & 0x7FF) == 0x7FF && (b & 0xFFFFFFFFFFFFFull)
             : ((b >> 23) & 0xFF) == 0xFF && (b & 0x7FFFFF);
}

static uint8_t host_flags() {
  int e = fetestexcept(FE_ALL_EXCEPT);
  return (e & FE_INEXACT ? Wtl3164::F_INEXACT : 0) | (e & FE_OVERFLOW ? Wtl3164::F_OVERFLOW : 0) |
         (e & FE_DIVBYZERO ? Wtl3164::F_DIVIDE_BY_ZERO : 0) | (e & FE_INVALID ? Wtl3164::F_INVALID : 0);
}

static const char* names[] = {"add", "sub", "mul", "div", "sqrt"};

static void check_arith(fpa::Op op, bool dbl, int mode) {
  uint64_t x = operand(dbl), y = operand(dbl);
  if (is_den(x, dbl) || is_den(y, dbl) || is_nan(x, dbl) || is_nan(y, dbl)) return;
  fesetround(host_mode[mode]);
  feclearexcept(FE_ALL_EXCEPT);
  uint64_t want;
  if (dbl) {
    volatile double a = f64(x), b = f64(y), r;
    switch (op) {
    case fpa::ADD: r = a + b; break;
    case fpa::SUB: r = a - b; break;
    case fpa::MUL: r = a * b; break;
    case fpa::DIV: r = a / b; break;
    default: r = std::sqrt((double)b); break;
    }
    want = b64(r);
  } else {
    volatile float a = f32((uint32_t)x), b = f32((uint32_t)y), r;
    switch (op) {
    case fpa::ADD: r = a + b; break;
    case fpa::SUB: r = a - b; break;
    case fpa::MUL: r = a * b; break;
    case fpa::DIV: r = a / b; break;
    default: r = std::sqrt((float)b); break;
    }
    want = b32(r);
  }
  uint8_t hf = host_flags();
  fesetround(FE_TONEAREST);
  Result got = fpa::compute(op, dbl, x, y, mode);
  if (got.flags & Wtl3164::F_UNDERFLOW) return;     // wrapped; checked separately
  if (is_den(want, dbl)) return;
  checked++;
  bool same = got.bits == want || (is_nan(got.bits, dbl) && is_nan(want, dbl));
  uint8_t mask = Wtl3164::F_INEXACT | Wtl3164::F_OVERFLOW | Wtl3164::F_DIVIDE_BY_ZERO | Wtl3164::F_INVALID;
  if (!same || (got.flags & mask) != hf) {
    if (failures++ < 20)
      printf("%s %s mode %d: %llx %llx -> %llx flags %02x, want %llx flags %02x\n", names[op],
             dbl ? "double" : "single", mode, (unsigned long long)x, (unsigned long long)y,
             (unsigned long long)got.bits, got.flags, (unsigned long long)want, hf);
  }
}

// Underflowed products of singles: exact in double, so the wrapped,
// truncated result can be checked against it
static void check_unrm() {
  uint32_t x = (uint32_t)operand(false), y = (uint32_t)operand(false);
  x = (x & 0x807FFFFF) | (uint32_t)(1 + rng() % 70) << 23;
  y = (y & 0x807FFFFF) | (uint32_t)(1 + rng() % 70) << 23;
  Result got = fpa::compute(fpa::MUL, false, x, y, 0);
  if (!(got.flags & Wtl3164::F_UNDERFLOW)) return;
  checked++;
  double exact = (double)f32(x) * (double)f32(y);
  int e;
  double frac = std::frexp(std::fabs(exact), &e);            // exact = frac * 2^e, frac in [0.5, 1)
  uint64_t sig = (uint64_t)std::ldexp(frac, 24);             // 24 bits, truncated
  bool inexact = std::ldexp(frac, 24) != (double)sig;
  int E = e - 1 + 127;                                       // biased, below 1
  uint32_t want = (exact < 0 ? 0x80000000u : 0) | ((uint32_t)E & 0xFF) << 23 | (uint32_t)(sig & 0x7FFFFF);
  int status = inexact ? 3 : 2;
  if (got.bits != want || got.status != status || ((got.flags & Wtl3164::F_INEXACT) != 0) != inexact) {
    if (failures++ < 20)
      printf("unrm %08x * %08x -> %08llx status %d, want %08x status %d\n", x, y,
             (unsigned long long)got.bits, got.status, want, status);
  }
}

static void check_convert(int mode) {
  fesetround(host_mode[mode]);
  int32_t i = (int32_t)rng();
  if (rng() % 2) i >>= rng() % 31;
  Result r = fpa::compute(fpa::I2D, true, 0, (uint32_t)i, mode);
  checked++;
  if (r.bits != b64((double)i)) { if (failures++ < 20) printf("i2d %d -> %llx\n", i, (unsigned long long)r.bits); }
  feclearexcept(FE_ALL_EXCEPT);
  volatile float fi = (float)i;
  r = fpa::compute(fpa::I2S, false, 0, (uint32_t)i, mode, false);
  checked++;
  if (r.bits != b32(fi)) { if (failures++ < 20) printf("i2s %d mode %d -> %llx\n", i, mode, (unsigned long long)r.bits); }
  uint64_t d = operand(true);
  if (!is_den(d, true) && !is_nan(d, true)) {
    feclearexcept(FE_ALL_EXCEPT);
    volatile float s = (float)f64(d);
    uint8_t hf = host_flags();
    r = fpa::compute(fpa::D2S, false, 0, d, mode);
    if (!(r.flags & Wtl3164::F_UNDERFLOW) && !is_den(b32(s), false)) {
      checked++;
      if (r.bits != b32(s) || (r.flags & (Wtl3164::F_INEXACT | Wtl3164::F_OVERFLOW)) != (hf & (Wtl3164::F_INEXACT | Wtl3164::F_OVERFLOW)))
        if (failures++ < 20) printf("d2s %llx mode %d -> %llx\n", (unsigned long long)d, mode, (unsigned long long)r.bits);
    }
    double dv = f64(d);
    if (std::fabs(dv) < 2147483647.0) {
      long want = std::lrint(dv);
      r = fpa::compute(fpa::D2I, true, 0, d, mode);
      checked++;
      if ((int32_t)r.bits != want && !(r.flags & Wtl3164::F_INTEGER_OVERFLOW))
        if (failures++ < 20) printf("d2i %.17g mode %d -> %d want %ld\n", dv, mode, (int32_t)r.bits, want);
      r = fpa::compute(fpa::D2I, true, 0, d, mode, true);
      checked++;
      if ((int32_t)r.bits != (long)std::trunc(dv))
        if (failures++ < 20) printf("d2i trunc %.17g -> %d\n", dv, (int32_t)r.bits);
    }
  }
  uint32_t s = (uint32_t)operand(false);
  if (!is_den(s, false) && !is_nan(s, false)) {
    r = fpa::compute(fpa::S2D, true, 0, s, mode);
    checked++;
    if (r.bits != b64((double)f32(s))) if (failures++ < 20) printf("s2d %08x\n", s);
    float sv = f32(s);
    if (std::fabs(sv) < 2147483520.0f) {
      long want = std::lrint(sv);
      r = fpa::compute(fpa::S2I, false, 0, s, mode);
      checked++;
      if ((int32_t)r.bits != want) if (failures++ < 20) printf("s2i %g mode %d -> %d want %ld\n", sv, mode, (int32_t)r.bits, want);
    }
  }
  fesetround(FE_TONEAREST);
}

static void check_compare(bool dbl) {
  uint64_t x = operand(dbl), y = rng() % 4 ? operand(dbl) : x;
  if (rng() % 8 == 0) y = x ^ (dbl ? 1ull << 63 : 1u << 31);
  if (is_den(x, dbl) || is_den(y, dbl) || is_nan(x, dbl) || is_nan(y, dbl)) return;
  double a = dbl ? f64(x) : f32((uint32_t)x), b = dbl ? f64(y) : f32((uint32_t)y);
  struct { fpa::Op op; bool want; } cases[] = {
    {fpa::EQ, a == b}, {fpa::LT, a < b}, {fpa::GT, a > b},
    {fpa::ZEROP, b == 0}, {fpa::MINUSP, b < 0}, {fpa::PLUSP, b > 0}};
  for (auto& c : cases) {
    Result r = fpa::compute(c.op, dbl, x, y, 0);
    checked++;
    if ((r.bits != 0) != c.want && failures++ < 20)
      printf("compare op %d %g %g -> %llu\n", c.op, a, b, (unsigned long long)r.bits);
  }
}

int main(int argc, char** argv) {
  long n = argc > 1 ? atol(argv[1]) : 200000;
  for (long i = 0; i < n; i++) {
    for (int mode = 0; mode < 4; mode++)
      for (int op = fpa::ADD; op <= fpa::SQRT; op++) {
        check_arith((fpa::Op)op, false, mode);
        check_arith((fpa::Op)op, true, mode);
      }
    check_unrm();
    check_convert(i & 3);
    check_compare(i & 1);
  }
  Result r = fpa::compute(fpa::IMUL, false, 0x10000, 0x10000, 0);
  checked++;
  if (!(r.flags & Wtl3164::F_INTEGER_OVERFLOW)) { failures++; printf("imul overflow not flagged\n"); }
  printf("%ld checks, %ld failures\n", checked, failures);
  return failures != 0;
}
