// Intel 82586 Ethernet coprocessor on the Merlin I/O board, with no network
// attached: Genera's driver (network/82586-ethernet-driver.lisp) resets it,
// configures it and starts both units at boot, and halts if it doesn't answer.
//
// The chip shares the board's buffer memory: its 24-bit byte address b is
// buffer byte b<16:0> (low byte of each 32-bit word first), so its SCP at
// 0xFFFFF6 is buffer word 0x7FFD.  Its pins are a latch the board decodes at
// 0x44016000 (the ID PROM's first word): bit 7 releases RESET, a falling edge
// on bit 6 is channel attention (CA), bit 5 releases loopback.  INT is bit 18
// of the Merlin-II interrupt register.
//
// Commands complete as CA is taken.  Transmits complete OK (the frame goes
// nowhere); the receive unit goes ready and never receives a frame.
#pragma once
#include <cstdint>
#include <vector>

class I82586 {
public:
  explicit I82586(std::vector<uint32_t>& buffer) : mem(buffer) {}
  void control(uint32_t v);     // write to the pins register (bits 7:5)
  bool irq() const { return !in_reset && stat != 0; }

  bool trace = false;

private:
  std::vector<uint32_t>& mem;
  bool in_reset = true, ca = false, need_init = true;
  uint32_t scb = 0;             // SCB byte address
  uint16_t stat = 0;            // SCB status <15:12>: CX FR CNA RNR
  uint16_t cus = 0, rus = 0;    // command and receive unit states
  uint16_t cbl = 0xFFFF;        // next command block (offset from the SCB base)

  uint16_t rd16(uint32_t b) const;
  void wr16(uint32_t b, uint16_t v);
  uint32_t rd24(uint32_t b) const { return rd16(b) | (uint32_t)(rd16(b + 2) & 0xFF) << 16; }
  uint32_t scb_base = 0;        // base of all 16-bit offsets
  void attention();
  void run_command_unit();
  void write_status();
};
