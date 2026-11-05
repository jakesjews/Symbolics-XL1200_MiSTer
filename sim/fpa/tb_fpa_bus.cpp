// The RTL FPA on its bus (rtl/xl/xl_fpa.sv) against the C++ model
// (Wtl3164, emu/fpa.cpp): random register writes, operations started as
// Genera starts them, and reads at random times after the start.  A read
// from the operation's latency on (Genera's XL1200 table) must agree with
// the model, tag and value; one before it must see the register as it was,
// tagged dtp-null, except that a divide or square root shows its in-progress
// bit (SR11 bit 30) instead from the third cycle until its last.  A read
// with `hold` (the processor's FPA instructions) must wait for the result.
//   ./obj_dir/Vxl_fpa [N]
#include <cstdio>
#include <cstdlib>
#include <random>
#include <vector>
#include "Vxl_fpa.h"
#include "fpa.h"

static std::mt19937_64 rng(3);
static Vxl_fpa* top;
static uint64_t cyc = 0;   // posedges so far; inputs set now are taken in cycle `cyc`
static long failures = 0;

static void tick() { top->clk = 0; top->eval(); top->clk = 1; top->eval(); cyc++; }



// One access; returns the cycle it was taken in and the word read
struct Taken { uint64_t at; uint64_t word; };
static Taken access(bool we, bool hold, unsigned addr, uint32_t wdata) {
  top->req = 1; top->we = we; top->hold = hold; top->addr = addr; top->wdata = wdata;
  for (int guard = 0; guard < 200; guard++) {
    tick();
    if (top->ack) {
      Taken t{cyc - 1, top->rdata};
      top->req = 0;
      return t;
    }
  }
  printf("no ack for %s %o\n", we ? "write" : "read", addr);
  exit(1);
}

static uint64_t model_word(Wtl3164& m, unsigned a) { return m.read(a); }

static void fail(const char* what, unsigned a, uint64_t got, uint64_t want, long op_i, const char* name) {
  if (failures++ < 30)
    printf("op %ld (%s): %s read %o: %010llx, want %010llx\n", op_i, name, what, a,
           (unsigned long long)got, (unsigned long long)want);
}

// Raw bits, values near one, extreme exponents, and the special classes (as tb_fpa_unit)
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
  case 4: r = mk(0); break;
  case 5: r = s | (rng() % 2 ? emax << fb : 0); break;
  case 6: r = mk(emax); break;
  case 7: r = mk(emax / 2 + rng() % 9 - 4) & ~(fmask >> (rng() % fb)); break;
  }
  return dbl ? r : r & 0xFFFFFFFF;
}

struct OpInfo { unsigned addr; const char* name; int x, y; int lat; bool dsr; };   // x, y: 0 none, 32, 64, 'i'nteger
static const std::vector<OpInfo> OPS = {
  {0000, "single-add", 32, 32, 3, false}, {0004, "single-sub", 32, 32, 3, false},
  {0010, "single-multiply", 32, 32, 3, false}, {0014, "single-quotient", 32, 32, 18, true},
  {0044, "single-rational-quotient", 32, 32, 18, true}, {0060, "single-unary-minus", 0, 32, 3, false},
  {0100, "single-=", 32, 32, 3, false}, {0104, "single-<", 32, 32, 3, false}, {0110, "single->", 32, 32, 3, false},
  {0120, "single-=-no-pop", 32, 32, 3, false}, {0160, "single-zerop", 0, 32, 3, false},
  {0164, "single-minusp", 0, 32, 3, false}, {0170, "single-plusp", 0, 32, 3, false},
  {0200, "double-add", 64, 64, 4, false}, {0204, "double-sub", 64, 64, 4, false},
  {0210, "double-multiply", 64, 64, 3, false}, {0214, "double-quotient", 64, 64, 32, true},
  {0244, "double-rational-quotient", 64, 64, 32, true}, {0260, "double-unary-minus", 0, 64, 3, false},
  {0300, "double-=", 64, 64, 3, false}, {0304, "double-<", 64, 64, 3, false}, {0330, "double->-no-pop", 64, 64, 3, false},
  {0360, "double-zerop", 0, 64, 3, false}, {0364, "double-minusp", 0, 64, 3, false}, {0370, "double-plusp", 0, 64, 3, false},
  {0374, "fixnum-multiply", 'i', 'i', 3, false},
  {0400, "double-to-fixnum-rounding", 0, 64, 3, false}, {0404, "double-to-fixnum-truncating", 0, 64, 3, false},
  {0410, "single-to-fixnum-rounding", 0, 32, 3, false}, {0414, "single-to-fixnum-truncating", 0, 32, 3, false},
  {0430, "fixnum-to-double", 0, 'i', 3, false}, {0434, "fixnum-to-single", 0, 'i', 3, false},
  {0440, "double-to-single", 0, 64, 3, false}, {0450, "single-to-double", 0, 32, 3, false},
  {0500, "double-sqrt", 0, 64, 59, true}, {0510, "single-sqrt", 0, 32, 29, true},
  {0544, "double-abs", 0, 64, 3, false}, {0554, "single-abs", 0, 32, 3, false},
};

// Every register a read can name
static std::vector<unsigned> readable(const OpInfo& o) {
  std::vector<unsigned> v = {1, 2, 3, 0400};
  for (unsigned a = 0600; a < 0614; a++) v.push_back(a);
  if (o.addr < 0374 && ((o.addr >> 2 & 037) >= 020)) v.push_back(o.addr + 2);
  return v;
}

int main(int argc, char** argv) {
  long n = argc > 1 ? atol(argv[1]) : 100000;
  top = new Vxl_fpa;
  Wtl3164 model;
  top->reset = 1; tick(); tick(); top->reset = 0; tick();
  long early_null = 0, early_dsr = 0, held = 0;
  for (long i = 0; i < n; i++) {
    // now and then the modes, trap enables, sticky bits or the status registers
    if (rng() % 8 == 0) {
      static const unsigned SRS[] = {0600, 0602, 0603, 0604, 0605, 0606, 0607, 0610, 0611, 0612, 0613};
      unsigned a = SRS[rng() % 11];
      uint32_t v = (uint32_t)rng() & 0xFF000000;
      if (a == 0600) v &= 0x86000000;   // rounding mode and FPEX sticky
      access(true, false, a, v); model.write(a, v);
    }
    if (rng() % 64 == 0) { access(true, false, 0624, 0); model.write(0624, 0); }
    const OpInfo& o = OPS[rng() % OPS.size()];
    // the operands, as %FPA-START writes them
    auto put = [&](unsigned a, uint32_t v) { access(true, false, a, v); model.write(a, v); };
    if (o.x == 32) put(0, (uint32_t)operand(false));
    if (o.x == 64) { uint64_t x = operand(true); put(0, (uint32_t)(x >> 32)); put(2, (uint32_t)x); }
    if (o.x == 'i') put(0374, (uint32_t)rng() >> (rng() % 32));
    uint32_t yhi;
    if (o.y == 64) { uint64_t y = operand(true); put(3, (uint32_t)y); yhi = (uint32_t)(y >> 32); }
    else if (o.y == 'i') yhi = (uint32_t)((int32_t)rng() >> (rng() % 32));
    else {
      yhi = (uint32_t)operand(false);
      if (o.addr >= 0400 && o.addr < 0420 && rng() % 2)   // conversions to fixnums: mostly in range
        yhi = (yhi & 0x807FFFFF) | (uint32_t)(127 + rng() % 36 - 4) << 23;
    }
    Wtl3164 before = model;
    Taken s = access(true, false, o.addr + 1, yhi);
    model.write(o.addr + 1, yhi);
    uint64_t t = s.at;
    // reads now and then before the result: busy, or the divider's progress
    std::vector<unsigned> regs = readable(o);
    bool hold = rng() % 4 == 0;
    if (hold) {
      unsigned a = o.addr < 0374 && (o.addr >> 2 & 037) >= 020 ? o.addr + 2 : o.addr == 0374 || (o.addr >= 0400 && o.addr < 0420) ? 0400 : 2;
      Taken r = access(false, true, a, 0);
      held++;
      if (r.at < t + o.lat) fail("held read early", a, r.at - t, o.lat, i, o.name);
      if (r.at > t + o.lat && r.at > s.at + 2) fail("held read late", a, r.at - t, o.lat, i, o.name);
      if (r.word != model_word(model, a)) fail("held", a, r.word, model_word(model, a), i, o.name);
    } else {
      int wait = rng() % (o.lat + 3);
      for (int k = 0; k < wait; k++) tick();
      while (cyc - 1 < t + o.lat + 1) {
        unsigned a = regs[rng() % regs.size()];
        Taken r = access(false, false, a, 0);
        if (r.at >= t + o.lat) {
          if (r.word != model_word(model, a)) fail("late", a, r.word, model_word(model, a), i, o.name);
          break;
        }
        uint64_t old = model_word(before, a);
        // the starting write has loaded R1 at once (an integer: its low half from bit 21)
        if (a == 1 && o.y == 'i') old = (old & ~0xFFFFFFFFull) | (uint32_t)(yhi << 21);
        uint64_t want;
        if (o.dsr && r.at - t >= 3) {
          want = old;
          if (a == 0613 && r.at < t + o.lat - 1) want |= 0x40000000;
          early_dsr++;
        } else {
          want = (uint64_t)DTP_NULL << 32 | (uint32_t)old;
          early_null++;
        }
        if (r.word != want) fail("early", a, r.word, want, i, o.name);
        if (rng() % 2) { for (int k = rng() % 4; k > 0; k--) tick(); }
      }
    }
    // then everything as the model has it
    for (unsigned a : regs) {
      Taken r = access(false, false, a, 0);
      if (r.word != model_word(model, a)) fail("after", a, r.word, model_word(model, a), i, o.name);
    }
  }
  printf("%ld operations, %ld failures; %ld reads before a result (%ld busy, %ld with the divider "
         "running), %ld held reads, %llu cycles\n",
         n, failures, early_null + early_dsr, early_null, early_dsr, held, (unsigned long long)cyc);
  return failures != 0;
}
