// Weitek WTL3164 floating-point accelerator on the Merlin-II, at coprocessor
// addresses 0-0o777.  No 3164 datasheet survives; this models the interface as
// Genera drives it (i-sys/float.lisp) and the arithmetic of its documented
// relatives (WTL 2264/2265, research/downloads/weitek):
//
//   writes  0 R0 high, 2 R0 low, 3 R1 low, 0o200/0o202 R2 high/low,
//           0o374 the fixnum multiplicand, op+1 R1 high and start operation op,
//           0o600+n status register n (bits 31:24), 0o624 reset
//   reads   1 R1 low, 2 R0 high (the result), 3 R0 low, op+2 a predicate's
//           result (bit 0), 0o400 an integer result, 0o600+n status register n
//
// Operations take X from R0 and Y from R1 (a unary operation's operand is Y)
// and leave the result in R0.  Their addresses are the Ivory instruction's
// opcode<4:0> shifted left two, plus 0o200 for double precision, so the Ivory
// can issue them straight from an instruction.  Every read is tagged
// dtp-single-float, or dtp-fixnum while FPEX (status register 11 bit 31) is
// set; FPEX is raised by an exception whose trap is enabled and by results
// Lisp has to finish (underflows, which come back wrapped and unrounded, as
// the 2264's UNRM).  The arithmetic is IEEE 754 with the four rounding modes;
// denormalized operands raise the denormalized-input flag and count as zero.
// Results are ready at once, so reads never see the busy tag (dtp-null).
#pragma once
#include <cstdint>
#include "ivory.h"

class Wtl3164 {
  friend struct ModelState;   // sim/system: copies state into the RTL
public:
  W read(unsigned a);
  void write(unsigned a, uint32_t v);
  bool fpex() const { return sr[11] & 0x80; }
  uint64_t operations = 0;   // for xlemu's summary

  // Exception flags (status register 3, and the trap enables in register 2)
  enum : uint8_t {
    F_INTEGER_OVERFLOW = 1, F_INEXACT = 2, F_UNDERFLOW = 4, F_OVERFLOW = 8,
    F_DENORMALIZED = 16, F_DIVIDE_BY_ZERO = 32, F_INVALID = 64, F_NAN = 128,
  };

private:
  uint32_t r0h = 0, r0l = 0, r1h = 0, r1l = 0, r2h = 0, r2l = 0;
  uint32_t ix = 0;          // fixnum multiplicand (0o374)
  uint32_t ir = 0;          // integer result (0o400)
  bool cond = false;        // the last predicate's result
  uint8_t sr[12] = {};      // status registers, bits 31:24 of the word

  void execute(unsigned op);
};

// IEEE arithmetic behind the FPA, shared with the RTL's test bench.  Values
// are raw bits (single precision in the low 32); flags are Wtl3164::F_*.
namespace fpa {
struct Result {
  uint64_t bits;
  uint8_t flags;
  uint8_t status;     // the 3164 status code (*w3x64-status-codes*)
  uint64_t wrapped;   // an overflow with its exponent wrapped
};
enum Op { ADD, SUB, MUL, DIV, SQRT, EQ, LT, GT, ZEROP, MINUSP, PLUSP, NEG, ABS,
          I2D, I2S, D2S, S2D, D2I, S2I, IMUL };
// mode: 0 nearest, 1 zero, 2 plus, 3 minus.  dbl selects double precision for
// the arithmetic and predicate operations; trunc forces round-to-zero for the
// conversions.  Predicates return 0 or 1 in bits.  With wrap_ovf (the
// overflow trap enabled) an overflow comes back as the rounded result with
// its biased exponent less 255 (2047), which is how Genera's trap handlers
// read it; otherwise as infinity or the largest number, by the rounding mode.
Result compute(Op op, bool dbl, uint64_t x, uint64_t y, int mode, bool trunc = false,
               bool wrap_ovf = false);
}
