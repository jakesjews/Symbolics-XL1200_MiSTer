// Weitek WTL3164 floating-point accelerator on the Merlin-II, at coprocessor
// addresses 0-0o777.  The arithmetic follows the chip's manual (3164/3364,
// November 1989, research/downloads/weitek); the Symbolics interface around it
// is undocumented and follows how Genera drives it (i-sys/float.lisp):
//
//   writes  0 R0 high, 2 R0 low, 3 R1 low, 0o200/0o202 R2 high/low,
//           0o374 the fixnum multiplicand (an integer into R0), op+1 R1 high
//           (an integer into R1 for the integer operations) and start op,
//           0o600+n status register n (bits 31:24), 0o624 reset
//   reads   1 R1 low, 2 R0 high (the result), 3 R0 low, op+2 a predicate's
//           result (bit 0), 0o400 R0 as an integer, 0o600+n status register n
//
// Operations take X from R0 and Y from R1 (a unary operation's operand is Y)
// and leave the result in R0.  Their addresses are the Ivory instruction's
// opcode<4:0> shifted left two, plus 0o200 for double precision, so the Ivory
// can issue them straight from an instruction.  Every read is tagged
// dtp-single-float, or dtp-fixnum while FPEX (status register 11 bit 31) is
// set; FPEX is raised by an exception whose trap is enabled and by every
// underflow (whose result is an UNRM Lisp has to finish).  The arithmetic is
// IEEE 754 with the four rounding modes; denormalized operands count as zero
// (raising the denormalized-input flag under DNRM CONTROL).  Results are
// ready at once, so reads never see the busy tag (dtp-null).
#pragma once
#include <cstdint>
#include "ivory.h"

class Wtl3164 {
  friend struct ModelState;   // sim/system: copies state into the RTL
  friend struct Snapshot;     // emu/snapshot.cpp: saves and restores the state
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
  // R0-R2 as 32-bit halves; a 32-bit integer sits in bits 52:21 of a register,
  // the rest zero (manual 6.1), so the fixnum multiplicand (0o374) and integer
  // results (0o400) are in R0, which Genera saves across interrupts
  uint32_t r0h = 0, r0l = 0, r1h = 0, r1l = 0, r2h = 0, r2l = 0;
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
  uint8_t status;   // the 3164 status code (*w3x64-status-codes*)
};
enum Op { ADD, SUB, MUL, DIV, SQRT, EQ, LT, GT, ZEROP, MINUSP, PLUSP, NEG, ABS,
          I2D, I2S, D2S, S2D, D2I, S2I, IMUL };
// mode: 0 nearest, 1 zero, 2 plus, 3 minus.  dbl selects double precision for
// the arithmetic and predicate operations; trunc forces round-to-zero for the
// conversions.  unf_round and dnrm_exc are status register 2's UNF CONTROL
// (underflows come back rounded) and DNRM CONTROL (denormalized operands
// raise their flag).  Predicates return 0 or 1 in bits.
Result compute(Op op, bool dbl, uint64_t x, uint64_t y, int mode, bool trunc = false,
               bool unf_round = false, bool dnrm_exc = true);
}
