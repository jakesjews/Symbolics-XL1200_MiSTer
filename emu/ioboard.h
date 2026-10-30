// Merlin I/O board (XL400/XL1200), slot 0 at physical 0x40000000.
//
// Layout (offsets from the board base, from the IFEP v333 drivers):
//   0x00000000-0x0000FFFF  buffer memory (SCSI/ESDI DMA, 32-bit)
//   0x04015000             SCSI/DMA control (bit 3 holds the WD33C93 in reset)
//   0x04017000+r / +0x100  DUSCC (SCN68562) register write / read ports (console link)
//   0x04017200+r / +0x300  AM9517 DMA controller register write / read ports
//   0x04017800+r / +0x100  WD33C93 register write / read ports
//                          (8-bit devices: a read port write starts the read; the
//                          byte is then readable anywhere in 0x04017000-0x04017FFF)
//   0x01008000-0x01008005  Ethernet station address, one byte per word in bits 15:8
//   0x04016000-0x0401601F  board ID PROM, one byte per word in bits 15:8 (see idprom)
//   0x04016000             write: 82586 Ethernet pins (bit 5 loopback off, bit 6 CA, bit 7
//                          reset off); they read back in bits 7:5 (Genera sets them with %p-ldb)
//   0x0401A000/0x0401B800  SCSI DMA page window / word address (0x0401A800/0x0401B000 ESDI)
//   0x04020000+r           DP8466 ESDI disk data controller registers
//   0x04024000             video scanline counter
//   0x0402C000             video control/status (bit 0 black-on-white, bit 1 sync running, bit 31 retrace)
//   0x0402D000/0x0402D001  video sync program RAM / address
//   0x08000000-0x0800FFFF  video memory, 2048 x 1024 x 1 bit (32 pixels per word)
#pragma once
#include <cstdint>
#include <cstdio>
#include <map>
#include <vector>
#include "ivory.h"
#include "console.h"
#include "scsi.h"
#include "i82586.h"

class IoBoard {
  friend struct ModelState;   // sim/system: copies state into the RTL
public:
  static const uint32_t BASE = 0x40000000u;
  static const uint32_t BUFFER_WORDS = 0x10000u;
  static const uint32_t VIDEO_WORDS = 0x10000u;   // 2048 x 1024 / 32
  static const uint32_t VIDEO_WIDTH = 2048, VIDEO_HEIGHT = 1024;

  IoBoard();
  bool claims(uint32_t pa) const { return pa >= BASE && pa < BASE + 0x10000000u; }
  W read(uint32_t pa);
  void write(uint32_t pa, W w);

  std::vector<uint32_t> buffer, video;
  I82586 ether{buffer};          // Ethernet
  uint32_t ether_pins = 0;       // bits 7:5 of 0x04016000
  WD33C93 scsi;
  Console console;
  void tick(uint64_t cycles);   // device timing (console line rate)
  uint32_t video_control = 0;
  std::vector<uint32_t> sync_program;
  uint32_t sync_address = 0;
  uint64_t frame_counter = 0;     // advanced by the machine for retrace emulation

  // Board ID PROM as checked by the FEP: bytes 0,1 = AA 55, 16-21 = Ethernet
  // address, 28 = checksum of the first byte[29] bytes (each rotated left by
  // its index mod 8), 30 = 00, 31 = FF.  Serial number and date fields are
  // not decoded yet and left zero.
  uint8_t idprom[32] = {};
  void set_ethernet_address(const uint8_t mac[6]);

  bool log_io = true;
  FILE* logf = stderr;

private:
  uint8_t polled_latch = 0;     // result of the last 8-bit polled read
  // DUSCC channel A/B registers
  uint8_t duscc[0x40] = {};
  uint8_t duscc_read(int r);
  void duscc_write(int r, uint8_t v);
  // AM9517 DMA controller
  struct DmaChannel { uint16_t base_addr, base_count, addr, count; uint8_t mode; bool masked = true; };
  DmaChannel dma[4];
  bool dma_flipflop = false;
  uint8_t dma_command = 0, dma_status = 0;
  uint8_t dma_read_reg(int r);
  void dma_write_reg(int r, uint8_t v);
  void dma_to_memory(int ch, uint8_t b);
  uint64_t next_console_byte = 0;
  uint32_t dma_control = 0xB7;
  uint32_t dma_regs[4] = {0, 0, 0, 0};
  uint32_t dma_byte_addr = 0;
  std::map<uint32_t, uint32_t> regs;   // registers not yet modelled
  std::map<uint32_t, uint64_t> logged;
  void log(const char* what, uint32_t pa, W w);
};
