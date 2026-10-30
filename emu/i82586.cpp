#include "i82586.h"
#include <cstdio>

// SCB status and command words
static const uint16_t CX = 0x8000, CNA = 0x2000;
enum { CU_IDLE = 0, CU_SUSPENDED = 1, CU_ACTIVE = 2 };
enum { RU_IDLE = 0, RU_SUSPENDED = 1, RU_READY = 4 };
enum { UC_START = 1, UC_RESUME = 2, UC_SUSPEND = 3, UC_ABORT = 4 };
// Command blocks: status C B OK A in <15:12>; command EL S I in <15:13>, CMD <2:0>
enum { CMD_TDR = 5, CMD_DUMP = 6 };

uint16_t I82586::rd16(uint32_t b) const {
  uint32_t w = mem[((b & 0x1FFFF) >> 2)];
  return (uint16_t)(b & 2 ? w >> 16 : w);
}

void I82586::wr16(uint32_t b, uint16_t v) {
  uint32_t& w = mem[((b & 0x1FFFF) >> 2)];
  w = b & 2 ? (w & 0x0000FFFFu) | (uint32_t)v << 16 : (w & 0xFFFF0000u) | v;
}

void I82586::control(uint32_t v) {
  bool rst = !(v & 0x80), ca_new = (v >> 6) & 1;
  if (rst) {
    in_reset = need_init = true;
    stat = cus = rus = 0;
  } else {
    in_reset = false;
  }
  if (!in_reset && ca && !ca_new) attention();
  ca = ca_new;
}

void I82586::write_status() {
  wr16(scb, (uint16_t)(stat | cus << 8 | rus << 4));
}

void I82586::attention() {
  if (need_init) {
    // SCP -> ISCP -> SCB; clearing the ISCP's busy byte tells the CPU it's done.
    uint32_t iscp = rd24(0xFFFFFC);
    scb_base = rd24(iscp + 4);
    scb = scb_base + rd16(iscp + 2);
    wr16(iscp, rd16(iscp) & 0xFF00);
    need_init = false;
    stat = CX | CNA;
    cus = CU_IDLE;
    rus = RU_IDLE;
    write_status();
    if (trace) fprintf(stderr, "[82586] init: ISCP %06x SCB %06x\n", iscp, scb);
    return;
  }
  uint16_t cmd = rd16(scb + 2);
  if (trace) fprintf(stderr, "[82586] CA: command %04x\n", cmd);
  stat &= ~(cmd & 0xF000);
  wr16(scb + 2, 0);
  if (cmd & 0x80) {             // software reset: like RESET, set up again at the next CA
    need_init = true;
    stat = cus = rus = 0;
    return;
  }
  switch ((cmd >> 4) & 7) {
  case UC_START: rus = RU_READY; break;
  case UC_RESUME: if (rus == RU_SUSPENDED) rus = RU_READY; break;
  case UC_SUSPEND: if (rus == RU_READY) rus = RU_SUSPENDED; break;
  case UC_ABORT: rus = RU_IDLE; break;
  }
  switch ((cmd >> 8) & 7) {
  case UC_START: cbl = rd16(scb + 4); cus = CU_ACTIVE; break;
  case UC_RESUME: if (cus == CU_SUSPENDED) cus = CU_ACTIVE; break;
  case UC_SUSPEND: if (cus == CU_ACTIVE) { cus = CU_SUSPENDED; stat |= CNA; } break;
  case UC_ABORT: if (cus != CU_IDLE) { cus = CU_IDLE; stat |= CNA; } break;
  }
  run_command_unit();
  write_status();
}

void I82586::run_command_unit() {
  for (int n = 0; cus == CU_ACTIVE && n < 4096; n++) {
    if (cbl == 0xFFFF) {
      cus = CU_IDLE;
      stat |= CNA;
      break;
    }
    uint32_t cb = scb_base + cbl;
    uint16_t c = rd16(cb + 2);
    if (trace) fprintf(stderr, "[82586] CB %04x: command %04x\n", cbl, c);
    switch (c & 7) {
    case CMD_TDR: wr16(cb + 6, 0x8000 | 0x7FF); break;   // link OK, no reflection
    case CMD_DUMP: {
      uint32_t d = scb_base + rd16(cb + 6);
      for (int i = 0; i < 170; i += 2) wr16(d + i, 0);
      break;
    }
    default: break;             // NOP, IA-SETUP, CONFIGURE, MC-SETUP, TRANSMIT, DIAGNOSE
    }
    wr16(cb, 0xA000);           // C, OK
    if (c & 0x2000) stat |= CX;
    uint16_t link = rd16(cb + 4);
    if (c & 0x8000) {
      cus = CU_IDLE;
      stat |= CNA;
    } else if (c & 0x4000) {
      cus = CU_SUSPENDED;
      stat |= CNA;
    }
    cbl = link;
  }
}
