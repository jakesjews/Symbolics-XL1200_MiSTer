#include "fpa.h"
#include <utility>

namespace fpa {
namespace {

struct Fmt { int p, ebits, bias, emax; };   // p: significand bits with the hidden one
const Fmt SGL{24, 8, 127, 254}, DBL{53, 11, 1023, 2046};

enum Cls { ZERO, NORM, INF, NAN_, DEN };
// value = m * 2^(e-62); a NORM has its leading one at bit 62
struct U { bool s; Cls c; int e; uint64_t m; };

U unpack(const Fmt& f, uint64_t bits) {
  int fb = f.p - 1;
  bool s = (bits >> (fb + f.ebits)) & 1;
  int E = (int)((bits >> fb) & ((1u << f.ebits) - 1));
  uint64_t F = bits & ((1ull << fb) - 1);
  if (E == f.emax + 1) return {s, F ? NAN_ : INF, 0, 0};
  if (E == 0) return {s, F ? DEN : ZERO, 0, 0};
  return {s, NORM, E - f.bias, ((1ull << fb) | F) << (62 - fb)};
}

uint64_t pack(const Fmt& f, bool s, uint64_t E, uint64_t F) {
  return ((uint64_t)s << (f.p - 1 + f.ebits)) | (E << (f.p - 1)) | F;
}
uint64_t zero(const Fmt& f, bool s) { return pack(f, s, 0, 0); }
uint64_t inf(const Fmt& f, bool s) { return pack(f, s, f.emax + 1, 0); }
// The 2264's NaN: sign 0, exponent and fraction all ones
uint64_t nan(const Fmt& f) { return pack(f, false, f.emax + 1, (1ull << (f.p - 1)) - 1); }

int base(const Fmt& f) { return f.p == 53 ? 8 : 0; }

// round: 0 nearest, 1 zero, 2 plus, 3 minus; unf_round: status register 2
// bit 2 (UNF CONTROL), underflows come back rounded; dnrm_exc: bit 4 (DNRM
// CONTROL), denormalized operands raise the flag (else count silently as 0)
struct Options { int round; bool unf_round, dnrm_exc; };

// Round m * 2^(e-62) (m's leading one at bit 62; sticky: nonzero bits below
// m) to f.  A result below the normalized range after rounding comes back as
// an UNRM: its exponent wrapped (two's complement in the exponent field) and
// its significand rounded or, without UNF CONTROL, truncated (manual 12.1,
// 19.3.6).  An overflow gives infinity or the largest number by the rounding
// mode (19.5.3).
Result round_pack(const Fmt& f, bool s, int e, uint64_t m, bool sticky, const Options& o) {
  int sh = 63 - f.p;
  uint64_t q = m >> sh, rem = m & ((1ull << sh) - 1), half = 1ull << (sh - 1);
  uint64_t fmask = (1ull << (f.p - 1)) - 1;
  bool inexact = rem || sticky;
  int mode = o.round;
  bool up = mode == 0 ? rem > half || (rem == half && (sticky || (q & 1)))
          : mode == 2 ? inexact && !s
          : mode == 3 ? inexact && s
          : false;
  int E = e + f.bias, Er = E;
  uint64_t qr = q + up;
  if (qr >> f.p) { qr >>= 1; Er++; }
  uint8_t nx = inexact ? Wtl3164::F_INEXACT : 0;
  if (Er < 1) {
    uint64_t emask = (1u << f.ebits) - 1;
    uint64_t bits = o.unf_round ? pack(f, s, (uint64_t)Er & emask, qr & fmask)
                                : pack(f, s, (uint64_t)E & emask, q & fmask);
    return {bits, (uint8_t)(Wtl3164::F_UNDERFLOW | nx), (uint8_t)(base(f) + (inexact ? 3 : 2))};
  }
  if (Er > f.emax) {
    bool to_inf = mode == 0 || (mode == 2 && !s) || (mode == 3 && s);
    return {to_inf ? inf(f, s) : pack(f, s, f.emax, fmask),
            (uint8_t)(Wtl3164::F_OVERFLOW | Wtl3164::F_INEXACT), (uint8_t)(base(f) + 4)};
  }
  return {pack(f, s, Er, qr & fmask), nx, (uint8_t)(base(f) + (inexact ? 1 : 0))};
}

int bitlen(uint64_t v) { return v ? 64 - __builtin_clzll(v) : 0; }

// Shift right by n, folding the bits shifted out into *sticky
uint64_t shr(uint64_t v, int n, bool* sticky) {
  if (n <= 0) return v;
  if (n >= 64) { *sticky |= v != 0; return 0; }
  *sticky |= (v & ((1ull << n) - 1)) != 0;
  return v >> n;
}

// Normalize a nonzero m to its leading one at bit 62
void normalize(int* e, uint64_t* m, bool* sticky) {
  int n = bitlen(*m) - 63;
  if (n > 0) *m = shr(*m, n, sticky);
  else *m <<= -n;
  *e += n;
}

Result special(uint64_t bits, uint8_t flags, const Fmt& f) { return {bits, flags, (uint8_t)base(f)}; }

// Denormalized operands count as zero, raising the flag with DNRM CONTROL
uint8_t flush(U* u, const Options& o) {
  if (u->c != DEN) return 0;
  u->c = ZERO;
  return o.dnrm_exc ? Wtl3164::F_DENORMALIZED : 0;
}

// An operation on a NaN is invalid and gives the default NaN (19.5.1)
const uint8_t NAN_OPERAND = Wtl3164::F_NAN | Wtl3164::F_INVALID;

Result add(const Fmt& f, U a, U b, const Options& o) {
  if (a.c == NAN_ || b.c == NAN_) return special(nan(f), NAN_OPERAND, f);
  uint8_t fl = flush(&a, o) | flush(&b, o);
  if (a.c == INF || b.c == INF) {
    if (a.c == INF && b.c == INF && a.s != b.s) return special(nan(f), fl | Wtl3164::F_INVALID, f);
    return special(inf(f, a.c == INF ? a.s : b.s), fl, f);
  }
  if (a.c == ZERO && b.c == ZERO) return special(zero(f, a.s == b.s ? a.s : o.round == 3), fl, f);
  if (b.c == ZERO) std::swap(a, b);
  if (a.c == ZERO) { Result r = round_pack(f, b.s, b.e, b.m, false, o); r.flags |= fl; return r; }
  if (a.e < b.e || (a.e == b.e && a.m < b.m)) std::swap(a, b);
  bool sticky = false;
  uint64_t mb = shr(b.m, a.e - b.e, &sticky), m;
  if (a.s == b.s) m = a.m + mb;
  else {
    m = a.m - mb - sticky;   // the shifted-out bits borrow one; sticky keeps the rest
    if (!m && !sticky) return special(zero(f, o.round == 3), fl, f);
  }
  int e = a.e;
  normalize(&e, &m, &sticky);
  Result r = round_pack(f, a.s, e, m, sticky, o);
  r.flags |= fl;
  return r;
}

Result mul(const Fmt& f, U a, U b, const Options& o) {
  if (a.c == NAN_ || b.c == NAN_) return special(nan(f), NAN_OPERAND, f);
  uint8_t fl = flush(&a, o) | flush(&b, o);
  bool s = a.s != b.s;
  if ((a.c == INF && b.c == ZERO) || (a.c == ZERO && b.c == INF))
    return special(nan(f), fl | Wtl3164::F_INVALID, f);
  if (a.c == INF || b.c == INF) return special(inf(f, s), fl, f);
  if (a.c == ZERO || b.c == ZERO) return special(zero(f, s), fl, f);
  unsigned __int128 p = (unsigned __int128)a.m * b.m;   // leading one at bit 124 or 125
  bool sticky = (uint64_t)p & ((1ull << 62) - 1);
  uint64_t m = (uint64_t)(p >> 62);
  int e = a.e + b.e;
  normalize(&e, &m, &sticky);
  Result r = round_pack(f, s, e, m, sticky, o);
  r.flags |= fl;
  return r;
}

Result div(const Fmt& f, U a, U b, const Options& o) {
  if (a.c == NAN_ || b.c == NAN_) return special(nan(f), NAN_OPERAND, f);
  uint8_t fl = flush(&a, o) | flush(&b, o);
  bool s = a.s != b.s;
  if ((a.c == INF && b.c == INF) || (a.c == ZERO && b.c == ZERO))
    return special(nan(f), fl | Wtl3164::F_INVALID, f);
  if (a.c == INF) return special(inf(f, s), fl, f);
  if (b.c == INF || a.c == ZERO) return special(zero(f, s), fl, f);
  if (b.c == ZERO) return special(inf(f, s), fl | Wtl3164::F_DIVIDE_BY_ZERO, f);
  unsigned __int128 n = (unsigned __int128)a.m << 64;
  unsigned __int128 q = n / b.m;          // leading one at bit 63 or 64
  bool sticky = (n % b.m) != 0;
  int k = (q >> 64) ? 2 : 1;              // drop to the leading one at bit 62
  sticky |= (q & ((1u << k) - 1)) != 0;
  uint64_t m = (uint64_t)(q >> k);
  int e = a.e - b.e - 2 + k;
  Result r = round_pack(f, s, e, m, sticky, o);
  r.flags |= fl;
  return r;
}

Result sqrt(const Fmt& f, U a, const Options& o) {
  if (a.c == NAN_) return special(nan(f), NAN_OPERAND, f);
  uint8_t fl = flush(&a, o);
  if (a.c == ZERO) return special(zero(f, a.s), fl, f);
  if (a.s) return special(nan(f), fl | Wtl3164::F_INVALID, f);
  if (a.c == INF) return special(inf(f, false), fl, f);
  // root of a.m * 2^(62 + (e odd)) as a 64-bit integer, one bit at a time
  bool odd = a.e & 1;
  unsigned __int128 rad = (unsigned __int128)a.m << (62 + odd), rem = 0;
  uint64_t root = 0;
  for (int i = 63; i >= 0; i--) {
    rem = (rem << 2) | (uint64_t)((rad >> (2 * i)) & 3);
    unsigned __int128 t = ((unsigned __int128)root << 2) | 1;
    root <<= 1;
    if (rem >= t) { rem -= t; root |= 1; }
  }
  bool sticky = rem != 0;
  int e = (a.e - odd) / 2;
  Result r = round_pack(f, false, e, root, sticky, o);
  r.flags |= fl;
  return r;
}

// -1, 0, 1 for ordered operands (zeros of either sign are equal)
int compare(U a, U b) {
  if (a.c == ZERO && b.c == ZERO) return 0;
  auto key = [](U u, uint64_t* hi, uint64_t* lo) {
    *hi = u.c == ZERO ? 0 : u.c == INF ? 0x7FFFFFFF : (uint64_t)(u.e + 0x40000000);
    *lo = u.c == NORM ? u.m : 0;
  };
  uint64_t ah, al, bh, bl;
  key(a, &ah, &al);
  key(b, &bh, &bl);
  int mag = ah != bh ? (ah < bh ? -1 : 1) : al != bl ? (al < bl ? -1 : 1) : 0;
  if (a.c == ZERO) return b.s ? 1 : -1;
  if (b.c == ZERO) return a.s ? -1 : 1;
  if (a.s != b.s) return a.s ? -1 : 1;
  return a.s ? -mag : mag;
}

Result to_int(U a, const Options& o, int base_status) {
  if (a.c == NAN_) return {0, Wtl3164::F_NAN | Wtl3164::F_INTEGER_OVERFLOW, 15};
  if (a.c == INF) return {0, Wtl3164::F_INTEGER_OVERFLOW, 15};
  uint8_t fl = flush(&a, o);
  if (a.c == ZERO) return {0, fl, (uint8_t)base_status};
  if (a.e > 62) return {0, (uint8_t)(fl | Wtl3164::F_INTEGER_OVERFLOW), 15};
  int sh = 62 - a.e;
  uint64_t ip, rem, half;
  bool below = false;   // fraction below one half, without a representable half
  if (sh >= 64) { ip = 0; rem = 1; half = 2; below = true; }
  else {
    ip = a.m >> sh;
    rem = sh ? a.m & ((1ull << sh) - 1) : 0;
    half = sh ? 1ull << (sh - 1) : 1;
  }
  bool inexact = rem != 0;
  bool up = o.round == 0 ? !below && (rem > half || (rem == half && (ip & 1)))
          : o.round == 2 ? inexact && !a.s
          : o.round == 3 ? inexact && a.s
          : false;
  uint64_t mag = ip + up;
  if (mag > (a.s ? 0x80000000ull : 0x7FFFFFFFull))
    return {(uint32_t)(a.s ? -mag : mag), (uint8_t)(fl | Wtl3164::F_INTEGER_OVERFLOW), 15};
  uint8_t nx = inexact ? Wtl3164::F_INEXACT : 0;
  return {(uint32_t)(a.s ? -mag : mag), (uint8_t)(fl | nx), (uint8_t)(base_status + (inexact ? 1 : 0))};
}

Result from_int(const Fmt& f, uint32_t v, const Options& o) {
  if (!v) return special(zero(f, false), 0, f);
  bool s = (int32_t)v < 0;
  uint64_t a = s ? (uint64_t)(0 - (uint64_t)(int32_t)v) : v;
  int n = bitlen(a);
  return round_pack(f, s, n - 1, a << (63 - n), false, o);
}

Result convert(const Fmt& from, const Fmt& to, uint64_t x, const Options& o) {
  U a = unpack(from, x);
  if (a.c == NAN_) return special(nan(to), NAN_OPERAND, to);
  uint8_t fl = flush(&a, o);
  if (a.c == INF) return special(inf(to, a.s), fl, to);
  if (a.c == ZERO) return special(zero(to, a.s), fl, to);
  Result r = round_pack(to, a.s, a.e, a.m, false, o);
  r.flags |= fl;
  if (from.p == 53 && to.p == 24) {
    if (r.status == 4) r.status = 13;                        // overflow-6432
    else if (r.status == 2 || r.status == 3) r.status = 14;  // underflow-6432
  }
  return r;
}

}  // namespace

Result compute(Op op, bool dbl, uint64_t x, uint64_t y, int mode, bool trunc, bool unf_round,
               bool dnrm_exc) {
  Options o{trunc ? 1 : mode, unf_round, dnrm_exc};
  const Fmt& f = dbl ? DBL : SGL;
  switch (op) {
  case ADD: return add(f, unpack(f, x), unpack(f, y), o);
  case SUB: return add(f, unpack(f, x), unpack(f, y ^ (1ull << (f.p - 1 + f.ebits))), o);
  case MUL: return mul(f, unpack(f, x), unpack(f, y), o);
  case DIV: return div(f, unpack(f, x), unpack(f, y), o);
  case SQRT: return sqrt(f, unpack(f, y), o);
  case EQ: case LT: case GT: case ZEROP: case MINUSP: case PLUSP: {
    bool unary = op == ZEROP || op == MINUSP || op == PLUSP;
    U a = unpack(f, unary ? y : x), b = unary ? U{false, ZERO, 0, 0} : unpack(f, y);
    // Unordered: = and zerop are false; the predicates with > or < are also
    // invalid (19.5.1)
    if (a.c == NAN_ || b.c == NAN_)
      return special(0, Wtl3164::F_NAN | (op == EQ || op == ZEROP ? 0 : Wtl3164::F_INVALID), f);
    uint8_t fl = flush(&a, o) | flush(&b, o);
    int c = compare(a, b);
    bool t = op == EQ || op == ZEROP ? c == 0 : op == LT || op == MINUSP ? c < 0 : c > 0;
    return special(t, fl, f);
  }
  case NEG: case ABS: {   // logical operations: no exceptions, NaNs kept (17, 19.3.7)
    uint64_t sign = 1ull << (f.p - 1 + f.ebits);
    return special(op == NEG ? y ^ sign : y & ~sign, 0, f);
  }
  case I2D: return from_int(DBL, (uint32_t)y, o);
  case I2S: return from_int(SGL, (uint32_t)y, o);
  case D2S: return convert(DBL, SGL, y, o);
  case S2D: return convert(SGL, DBL, y, o);
  case D2I: return to_int(unpack(DBL, y), o, 0);
  case S2I: return to_int(unpack(SGL, y), o, 0);
  case IMUL: {
    int64_t p = (int64_t)(int32_t)x * (int32_t)y;
    if (p != (int32_t)p) return {(uint32_t)p, Wtl3164::F_INTEGER_OVERFLOW, 15};
    return {(uint32_t)p, 0, 0};
  }
  }
  return {0, 0, 0};
}

}  // namespace fpa

namespace {
enum Unit { U_ADD, U_MUL, U_DIV };
struct Decoded { fpa::Op op; bool dbl, trunc; Unit unit; };

// Operands and results are 64 bits (R0, R1 high and low) or 32 (high only)
bool in64(const Decoded& d) {
  return d.op == fpa::D2I || d.op == fpa::D2S || (d.dbl && d.op < fpa::I2D);
}
bool out64(const Decoded& d) {
  return d.op == fpa::I2D || d.op == fpa::S2D || (d.dbl && d.op < fpa::I2D);
}

// Operation at an op address (multiple of 4), or false if there is none
bool decode(unsigned op, Decoded* d) {
  using namespace fpa;
  if (op < 0374) {
    bool dbl = op & 0200;
    switch ((op >> 2) & 037) {
    case 000: *d = {ADD, dbl, false, U_ADD}; return true;
    case 001: *d = {SUB, dbl, false, U_ADD}; return true;
    case 002: *d = {MUL, dbl, false, U_MUL}; return true;
    case 003: case 011: *d = {DIV, dbl, false, U_DIV}; return true;
    case 014: *d = {NEG, dbl, false, dbl ? U_MUL : U_ADD}; return true;
    case 020: case 024: *d = {EQ, dbl, false, U_MUL}; return true;
    case 021: case 025: *d = {LT, dbl, false, U_MUL}; return true;
    case 022: case 026: *d = {GT, dbl, false, U_MUL}; return true;
    case 034: *d = {ZEROP, dbl, false, U_MUL}; return true;
    case 035: *d = {MINUSP, dbl, false, U_MUL}; return true;
    case 036: *d = {PLUSP, dbl, false, U_MUL}; return true;
    }
    return false;
  }
  switch (op) {
  case 0374: *d = {IMUL, false, false, U_MUL}; return true;
  case 0400: *d = {D2I, true, false, U_ADD}; return true;
  case 0404: *d = {D2I, true, true, U_ADD}; return true;
  case 0410: *d = {S2I, false, false, U_ADD}; return true;
  case 0414: *d = {S2I, false, true, U_ADD}; return true;
  case 0430: *d = {I2D, true, false, U_ADD}; return true;
  case 0434: *d = {I2S, false, true, U_ADD}; return true;
  case 0440: *d = {D2S, false, false, U_ADD}; return true;
  case 0450: *d = {S2D, true, false, U_ADD}; return true;
  case 0500: *d = {SQRT, true, false, U_DIV}; return true;
  case 0510: *d = {SQRT, false, false, U_DIV}; return true;
  case 0544: *d = {ABS, true, false, U_MUL}; return true;
  case 0554: *d = {ABS, false, false, U_MUL}; return true;
  }
  return false;
}

bool predicate(unsigned a) {
  if (a >= 0400 || (a & 3) != 2) return false;
  unsigned i = (a >> 2) & 037;
  return (i >= 020 && i <= 026 && i != 023) || (i >= 034 && i <= 036);
}
}  // namespace

// A 32-bit integer in a register: bits 52:21 (manual 6.1)
static uint32_t int_of(uint32_t hi, uint32_t lo) { return (hi << 11) | (lo >> 21); }
static void set_int(uint32_t* hi, uint32_t* lo, uint32_t v) { *hi = v >> 11; *lo = v << 21; }

W Wtl3164::read(unsigned a) {
  uint32_t v = 0;
  if (a == 1) v = r1l;
  else if (a == 2) v = r0h;
  else if (a == 3) v = r0l;
  else if (a == 0400) v = int_of(r0h, r0l);
  else if (predicate(a)) v = cond;
  else if (a >= 0600 && a < 0614) v = (uint32_t)sr[a - 0600] << 24;
  return mkw(fpex() ? DTP_FIXNUM : DTP_SINGLE_FLOAT, v);
}

void Wtl3164::write(unsigned a, uint32_t v) {
  switch (a) {
  case 0: r0h = v; return;
  case 2: r0l = v; return;
  case 3: r1l = v; return;
  case 0200: r2h = v; return;
  case 0202: r2l = v; return;
  case 0374: set_int(&r0h, &r0l, v); return;
  case 0624: for (auto& r : sr) r = 0; return;
  }
  if (a >= 0600 && a < 0614) { sr[a - 0600] = (uint8_t)(v >> 24); return; }
  if ((a & 3) == 1 && a < 0600) {
    Decoded d;
    bool integer_in = decode(a & ~3u, &d) && (d.op == fpa::IMUL || d.op == fpa::I2D || d.op == fpa::I2S);
    if (integer_in) set_int(&r1h, &r1l, v);
    else r1h = v;
    execute(a & ~3u);
  }
}

void Wtl3164::execute(unsigned op) {
  Decoded d;
  if (!decode(op, &d)) return;
  operations++;
  int mode = (sr[0] >> 1) & 3;
  bool integer_in = d.op == fpa::IMUL || d.op == fpa::I2D || d.op == fpa::I2S;
  uint64_t x = d.op == fpa::IMUL ? int_of(r0h, r0l) : in64(d) ? ((uint64_t)r0h << 32) | r0l : r0h;
  uint64_t y = integer_in ? int_of(r1h, r1l) : in64(d) ? ((uint64_t)r1h << 32) | r1l : r1h;
  fpa::Result r = fpa::compute(d.op, d.dbl, x, y, mode, d.trunc, sr[2] & F_UNDERFLOW,
                               sr[2] & F_DENORMALIZED);
  bool predicate = false;
  switch (d.op) {
  case fpa::EQ: case fpa::LT: case fpa::GT: case fpa::ZEROP: case fpa::MINUSP: case fpa::PLUSP:
    cond = r.bits & 1;
    sr[11] = (uint8_t)((sr[11] & ~0x20) | (cond ? 0x20 : 0));
    predicate = true;
    break;
  case fpa::D2I: case fpa::S2I: case fpa::IMUL:
    set_int(&r0h, &r0l, (uint32_t)r.bits);
    break;
  default:
    // a single-precision result clears the register's low half (manual 7.2)
    r0h = (uint32_t)(out64(d) ? r.bits >> 32 : r.bits);
    r0l = out64(d) ? (uint32_t)r.bits : 0;
  }
  // compares write no register, so they leave the status alone (but set FPCN)
  if (!predicate) {
    if (d.unit == U_ADD) sr[6] = (uint8_t)((sr[6] & 0x0F) | (r.status << 4));
    else if (d.unit == U_MUL) sr[6] = (uint8_t)((sr[6] & 0xF0) | r.status);
    else sr[11] = (uint8_t)((sr[11] & 0xF0) | r.status);
  }
  sr[3] |= r.flags;
  // FPEX: an exception whose trap is enabled (the underflow bit is UNF
  // CONTROL, but an underflow always raises it), or a denormalized operand
  // under DNRM CONTROL; FPEX-taken stays until software clears it (12.1)
  bool exception = (r.flags & sr[2] & ~F_UNDERFLOW) || (r.flags & F_UNDERFLOW);
  if (exception) sr[11] |= 0x80;
}
