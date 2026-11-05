#include "ioboard.h"
#include <cstring>

void IoBoard::set_ethernet_address(const uint8_t mac[6]) {
  memset(idprom, 0, sizeof idprom);
  idprom[0] = 0xAA;
  idprom[1] = 0x55;
  memcpy(idprom + 16, mac, 6);
  idprom[29] = 28;
  unsigned sum = 0;
  for (int i = 0; i < idprom[29]; i++) {
    unsigned r = i & 7, b = idprom[i];
    sum += (b << r) | (b >> (8 - r));
  }
  idprom[28] = (uint8_t)sum;
  idprom[30] = 0x00;
  idprom[31] = 0xFF;
}

IoBoard::IoBoard() : buffer(BUFFER_WORDS, 0), video(VIDEO_WORDS, 0), sync_program(4096, 0) {
  static const uint8_t mac[6] = {0x08, 0x00, 0x05, 0x12, 0x00, 0x01};
  set_ethernet_address(mac);
  // SCSI DMA moves bytes through the buffer memory, low byte of each word first.
  scsi.dma_write = [this](uint8_t b) {
    uint32_t w = (dma_byte_addr >> 2) & (BUFFER_WORDS - 1), sh = (dma_byte_addr & 3) * 8;
    buffer[w] = (buffer[w] & ~(0xFFu << sh)) | ((uint32_t)b << sh);
    dma_byte_addr++;
  };
  scsi.dma_read = [this]() {
    uint32_t w = (dma_byte_addr >> 2) & (BUFFER_WORDS - 1), sh = (dma_byte_addr & 3) * 8;
    dma_byte_addr++;
    return (uint8_t)(buffer[w] >> sh);
  };
}

void IoBoard::log(const char* what, uint32_t pa, W w) {
  if (!log_io || logged[pa]++ >= 8) return;
  fprintf(logf, "[iob] %s %08x %02o:%08x\n", what, pa, wtag(w), wdata(w));
}

W IoBoard::read(uint32_t pa) {
  uint32_t off = pa - BASE;
  if (off < BUFFER_WORDS) return mkw(DTP_FIXNUM, buffer[off]);
  if (off >= 0x08000000u && off < 0x08000000u + VIDEO_WORDS) return mkw(DTP_FIXNUM, video[off - 0x08000000u]);
  switch (off) {
  case 0x04015000: return mkw(DTP_FIXNUM, dma_control);
  case 0x04020000: return mkw(DTP_FIXNUM, 0x02);   // DP8466 status: controller ready (no ESDI drives)
  case 0x04024000: return mkw(DTP_FIXNUM, (uint32_t)(frame_counter & 0x3FF));
  case 0x0402C000: {
    uint32_t v = video_control;
    if ((frame_counter & 0x3FF) < 40) v |= 0x80000000u;   // vertical retrace
    return mkw(DTP_FIXNUM, v);
  }
  default: break;
  }
  if (off >= 0x04017000u && off < 0x04018000u) return mkw(DTP_FIXNUM, polled_latch);  // 8-bit devices
  if (off == 0x04016000u) return mkw(DTP_FIXNUM, (uint32_t)idprom[0] << 8 | ether_pins);
  if (off >= 0x04016000u && off < 0x04016020u) return mkw(DTP_FIXNUM, (uint32_t)idprom[off - 0x04016000u] << 8);
  if (off >= 0x01008000u && off < 0x01008006u) return mkw(DTP_FIXNUM, (uint32_t)idprom[16 + off - 0x01008000u] << 8);
  W v = mkw(DTP_FIXNUM, regs.count(off) ? regs[off] : 0);
  log("read ", pa, v);
  return v;
}

void IoBoard::write(uint32_t pa, W w) {
  uint32_t off = pa - BASE, v = wdata(w);
  if (off < BUFFER_WORDS) { buffer[off] = v; return; }
  if (off >= 0x08000000u && off < 0x08000000u + VIDEO_WORDS) { video[off - 0x08000000u] = v; return; }
  if (off >= 0x04017000u && off < 0x04018000u) {
    uint32_t port = off & 0xF00, r = off & 0xFF;
    switch (port) {
    case 0x000: duscc_write(r, (uint8_t)v); break;
    case 0x100: polled_latch = duscc_read(r); break;
    case 0x200: dma_write_reg(r, (uint8_t)v); break;
    case 0x300: polled_latch = dma_read_reg(r); break;
    case 0x800: scsi.write_reg(r & 0x1F, (uint8_t)v); break;
    case 0x900: polled_latch = scsi.read_reg(r & 0x1F); break;
    default: log("write", pa, w); break;
    }
    return;
  }
  switch (off) {
  case 0x04015000:
    // Bit 0 is the WD33C93's reset pin, active low (Genera's
    // %%MERLIN-INHIBIT-WD33C93-RESET; bit 3 resets the SCSI bus).
    if (!(dma_control & 0x01) && (v & 0x01)) scsi.hardware_reset();
    dma_control = v;
    log("write", pa, w);
    return;
  // SCSI DMA: 0x0401A000 holds the buffer window in 4K-word pages (start page in
  // bits 2:0, end page + 1 in bits 5:3); 0x0401B800 the low 12 bits of the
  // starting word address (MERLIN-WD33C93-SCSI-CONTROLLER EXECUTE-SCSI-COMMAND).
  // 0x0401A800/0x0401B000 are the ESDI channel's equivalents.
  case 0x0401A000: dma_regs[0] = v; log("write", pa, w); return;
  case 0x0401A800: dma_regs[1] = v; log("write", pa, w); return;
  case 0x0401B000: dma_regs[2] = v; log("write", pa, w); return;
  case 0x0401B800:
    dma_regs[3] = v;
    dma_byte_addr = (((dma_regs[0] & 7) << 12) | (v & 0xFFF)) * 4;
    if (scsi.trace) fprintf(stderr, "[iob] SCSI DMA window %02x word address %05x\n", dma_regs[0], dma_byte_addr / 4);
    log("write", pa, w);
    return;
  case 0x0402C000: video_control = v; log("write", pa, w); return;
  case 0x04016000: ether_pins = v & 0xE0; ether.control(v); log("write", pa, w); return;
  case 0x0402D000: sync_program[sync_address++ & 0xFFF] = v; return;
  case 0x0402D001: sync_address = v; log("write", pa, w); return;
  default: break;
  }
  regs[off] = v;
  log("write", pa, w);
}

// ---------------------------------------------------------------------------
// DUSCC: only what the console link needs.  The receiver feeds DMA channel 0;
// the transmitter is polled through the general status register.
uint8_t IoBoard::duscc_read(int r) {
  r &= 0x3F;
  if (r == 0x1B) return 0x02;                 // GSR: channel A transmitter ready
  return duscc[r];
}

void IoBoard::duscc_write(int r, uint8_t v) {
  r &= 0x3F;
  duscc[r] = v;
  if (r >= 0x10 && r <= 0x13) {   // channel A transmit FIFO
    if (log_io) fprintf(logf, "[console] <- %02x\n", v);
    console.from_cpu(v);
  }
}

// ---------------------------------------------------------------------------
// AM9517 (8237) DMA controller.
uint8_t IoBoard::dma_read_reg(int r) {
  r &= 0x0F;
  if (r < 8) {
    DmaChannel& c = dma[r >> 1];
    uint16_t v = (r & 1) ? c.count : c.addr;
    uint8_t b = dma_flipflop ? (uint8_t)(v >> 8) : (uint8_t)v;
    dma_flipflop = !dma_flipflop;
    return b;
  }
  if (r == 8) { uint8_t s = dma_status; dma_status &= 0xF0; return s; }
  return 0;
}

void IoBoard::dma_write_reg(int r, uint8_t v) {
  r &= 0x0F;
  if (r < 8) {
    DmaChannel& c = dma[r >> 1];
    uint16_t& base = (r & 1) ? c.base_count : c.base_addr;
    uint16_t& cur = (r & 1) ? c.count : c.addr;
    base = dma_flipflop ? (uint16_t)((base & 0x00FF) | (v << 8)) : (uint16_t)((base & 0xFF00) | v);
    cur = base;
    dma_flipflop = !dma_flipflop;
    return;
  }
  switch (r) {
  case 0x8: dma_command = v; break;
  case 0xA: dma[v & 3].masked = (v & 4) != 0; break;
  case 0xB: dma[v & 3].mode = v; break;
  case 0xC: dma_flipflop = false; break;
  case 0xD: dma_flipflop = false; dma_status = 0; dma_command = 0; for (auto& c : dma) c.masked = true; break;
  case 0xE: for (auto& c : dma) c.masked = false; break;
  case 0xF: for (int i = 0; i < 4; i++) dma[i].masked = (v >> i) & 1; break;
  default: break;
  }
}

// One byte from a device into buffer memory.  Byte address bit 16 is the
// serial control register's DMA bank bit (0x04014800 bit 5, Genera's
// %%MERLIN-SERIAL-CTL-DMAC-BANK; the FEP sets it with 0xA4).
void IoBoard::dma_to_memory(int ch, uint8_t b) {
  DmaChannel& c = dma[ch];
  auto sc = regs.find(0x04014800u);
  uint32_t serial_control = sc == regs.end() ? 0 : sc->second;
  uint32_t a = ((serial_control >> 5) & 1) << 16 | c.addr;
  uint32_t w = (a >> 2) & (BUFFER_WORDS - 1), sh = (a & 3) * 8;
  buffer[w] = (buffer[w] & ~(0xFFu << sh)) | ((uint32_t)b << sh);
  c.addr += (c.mode & 0x20) ? -1 : 1;
  if (c.count-- == 0) {
    dma_status |= 1 << ch;
    if (c.mode & 0x10) { c.addr = c.base_addr; c.count = c.base_count; }
    else c.masked = true;
  }
}

void IoBoard::tick(uint64_t cycles) {
  // The console link runs at about 75 kbit/s: one byte every ~150 us.
  if (cycles >= next_console_byte && console.to_cpu_pending() && !dma[0].masked) {
    uint8_t b = console.to_cpu_next();
    if (log_io) fprintf(logf, "[console] -> %02x (dma addr %04x count %04x)\n", b, dma[0].addr, dma[0].count);
    dma_to_memory(0, b);
    next_console_byte = cycles + 600;
  }
}
