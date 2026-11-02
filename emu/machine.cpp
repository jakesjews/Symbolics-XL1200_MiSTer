#include "machine.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdexcept>

Machine::Machine(uint32_t ram_words, const std::string& nvram_path)
    : ram(ram_words, 0), nvram(nvram_path), prom(PROM_SIZE, 0) {}

void Machine::attach_disk(int id, const std::string& path, uint32_t bs, uint32_t stride) {
  if (!iob.scsi.targets[id].open(path, bs, stride))
    fprintf(stderr, "cannot open disk image %s\n", path.c_str());
  else
    fprintf(stderr, "SCSI %d: %s, %llu blocks of %u bytes (stride %u)\n", id, path.c_str(),
            (unsigned long long)iob.scsi.targets[id].blocks, bs, iob.scsi.targets[id].stride);
}

void Machine::tick(uint64_t n) {
  cycles += n;
  iob.frame_counter = cycles / 64;
  iob.tick(cycles);
  // The microsecond clock is 32 bits and wraps (71.6 minutes); count the
  // difference in 32 bits too
  uint32_t usec = microsecond_clock();
  if (usec != pit_usec) {
    pit.tick(usec - pit_usec);
    pit_usec = usec;
  }
  uint32_t on = interrupts_pending() & interrupt_mask;
  hp_sb = (on & ~2u) != 0;
  lp_sb = (on & 2u) != 0;
}

uint32_t Machine::interrupts_pending() const {
  return (pit.out(2) ? 1u : 0u) | (pit.out(0) ? 2u : 0u) | (iob.scsi.irq() ? 1u << 8 : 0u) |
         (iob.ether.irq() ? 1u << 18 : 0u);
}

// Main-board registers (Merlin-II).
static bool main_board_register(uint32_t pa) {
  return (pa >= 0x0A000000u && pa < 0x0A000010u) ||   // control, cache, ECO, status
         (pa >= 0x88000000u && pa < 0x88001000u);     // VME interface (VIC068 at +0x200)
}

W Machine::phys_read(uint32_t pa) {
  uint32_t ri = ram_index(pa);
  if (ri < ram.size()) return ram[ri];
  if (pa >= PROM_BASE && pa < PROM_BASE + PROM_SIZE) return prom[pa - PROM_BASE];
  if (pa >= 0x09000000u && pa < 0x09000800u) return nvram.read(pa - 0x09000000u);
  if (iob.claims(pa)) return iob.read(pa);
  if (pa == 0x0A000008u) return mkw(DTP_FIXNUM, ECO_REGISTER);
  if (pa == 0x0A00000Cu) return mkw(DTP_FIXNUM, interrupts_pending());
  if (pa >= 0x08000000u && pa < 0x08000004u) return mkw(DTP_FIXNUM, 0);   // timer: not read
  if (main_board_register(pa)) {
    W v = io_regs.count(pa) ? io_regs[pa] : mkw(DTP_FIXNUM, 0);
    if (log_io && io_count[pa]++ < 8) fprintf(logf, "[io] read  %08x -> %02o:%08x\n", pa, wtag(v), wdata(v));
    return v;
  }
  if (log_io) fprintf(logf, "[io] read  %08x -> BUS ERROR\n", pa);
  throw BusError{pa, false};
}

void Machine::phys_write(uint32_t pa, W w) {
  uint32_t ri = ram_index(pa);
  if (ri < ram.size()) {
    ram[ri] = w;
    if (write_log) write_log->push_back(ri);
    return;
  }
  if (pa >= PROM_BASE && pa < PROM_BASE + PROM_SIZE) return;
  if (pa >= 0x09000000u && pa < 0x09000800u) { nvram.write(pa - 0x09000000u, w); return; }
  if (iob.claims(pa)) { iob.write(pa, w); return; }
  if (pa == 0x0A00000Cu) { interrupt_mask = wdata(w); return; }
  if (pa >= 0x08000000u && pa < 0x08000004u) { pit.write(pa & 3, (uint8_t)wdata(w)); return; }
  if (main_board_register(pa)) {
    if (log_io && io_count[pa]++ < 8) fprintf(logf, "[io] write %08x <- %02o:%08x\n", pa, wtag(w), wdata(w));
    io_regs[pa] = w;
    return;
  }
  if (log_io) fprintf(logf, "[io] write %08x <- %02o:%08x BUS ERROR\n", pa, wtag(w), wdata(w));
  throw BusError{pa, true};
}

W Machine::coproc_read(unsigned reg) {
  if (reg < 01000 && fpa_fitted) return fpa.read(reg);
  if (reg == 01002) return mkw(DTP_FIXNUM, microsecond_clock());
  if (log_io) fprintf(logf, "[cp] read  %o\n", reg);
  return mkw(DTP_FIXNUM, 0);
}

void Machine::coproc_write(unsigned reg, W w) {
  if (reg < 01000 && fpa_fitted) { fpa.write(reg, wdata(w)); return; }
  if (log_io) fprintf(logf, "[cp] write %o <- %02o:%08x\n", reg, wtag(w), wdata(w));
}

uint32_t Machine::microsecond_clock() { return (uint32_t)(cycles / 4); }

// FEP kernel file: 1280-byte blocks of 256 words (20-byte groups of 4 tag
// bytes + 4 little-endian data words).  Block 0 holds a load map of
// (vma, length|flags, block-or-immediate) triples starting at word 8.
void Machine::load_fep_file(const std::string& path) {
  FILE* f = fopen(path.c_str(), "rb");
  if (!f) throw std::runtime_error("cannot open " + path);
  std::vector<uint8_t> bytes;
  uint8_t buf[65536];
  size_t n;
  while ((n = fread(buf, 1, sizeof buf, f)) > 0) bytes.insert(bytes.end(), buf, buf + n);
  fclose(f);
  std::vector<W> words;
  for (size_t q = 0; q + 20 <= bytes.size(); q += 20)
    for (int k = 0; k < 4; k++) {
      uint32_t d;
      memcpy(&d, &bytes[q + 4 + 4 * k], 4);
      words.push_back(mktag(bytes[q + k], d));
    }
  if (wdata(words[0]) != 0x00410040) throw std::runtime_error("bad FEP file magic");
  uint32_t nent = wdata(words[1]);
  for (uint32_t i = 0; i < nent; i++) {
    uint32_t vma = wdata(words[8 + i * 3]);
    uint32_t lf = wdata(words[8 + i * 3 + 1]);
    W imm = words[8 + i * 3 + 2];
    uint32_t len = lf & 0xFFFFFF;
    uint32_t pa = vma - VMA_PMA_BASE;
    if (lf & 0x01000000) {
      phys_write(pa, imm);
    } else {
      uint32_t base = wdata(imm) * 256;
      for (uint32_t k = 0; k < len; k++) phys_write(pa + k, words[base + k]);
    }
  }
}

// Boot PROM image: one word per line from PROM word 0, 10 hex digits
// {cdr, type, data}; words not in the file read as fixnum 0.
void Machine::load_prom(const std::string& path) {
  FILE* f = fopen(path.c_str(), "r");
  if (!f) throw std::runtime_error("cannot open " + path);
  std::fill(prom.begin(), prom.end(), mkw(DTP_FIXNUM, 0));
  char line[64];
  for (uint32_t i = 0; i < PROM_SIZE && fgets(line, sizeof line, f); i++) {
    uint64_t v = strtoull(line, nullptr, 16);
    prom[i] = mktag((uint8_t)(v >> 32), (uint32_t)v);
  }
  fclose(f);
}

// What the boot PROM does before the FEP runs (no dump of the Merlin boot PROM
// exists): fill in the boot communication and data areas, then enter
// FEP-STARTUP in FEP mode with a frame on the boot stack.  The FEP kernel must
// already be in memory (load_fep_file).
void Machine::boot_fep(Ivory& cpu) {
  // Boot communication area (normally filled in by the boot PROM).
  auto& p = prom;
  // No dump of the Merlin boot PROM exists; unprogrammed words read as fixnum 0,
  // which also makes the serial number (one byte per word at 0o40 and 0o60) 0.
  std::fill(p.begin(), p.end(), fixnum(0));
  p[0] = mkw(DTP_PHYSICAL_ADDRESS, Machine::PROM_BASE + 070);  // *boot-emb-communication-area*: none (no magic)
  p[070] = fixnum(0);
  p[1] = fixnum(01011);                            // *boot-system-type*: XL1200
  // The boot stack sits below the FEP overlay area (0xF8001000-0xF80066FF);
  // same place the VLM's life support puts it.
  const uint32_t stack_base = 0xF8000100u, stack_size = 0xF00;
  p[2] = mkw(DTP_LOCATIVE, stack_base);            // *boot-stack-base*
  p[3] = fixnum(stack_size);                       // *boot-stack-size*
  p[4] = fixnum(0);                                // *boot-spy-pc*
  p[7] = mkw(DTP_LOCATIVE, 0xF8040940u);           // *boot-spy-block-address*
  p[10] = fixnum(1);                               // *boot-prom-version*
  // Boot data area (at the spy block, sysdf1 BOOT-DATA-AREA, offsets octal 56+n):
  // BOOT-FEP-KERNEL-DPN tells the FEP which unit it came from (bits 31:27), which
  // becomes the default FEPn: device.  SCSI target 0 is FEP unit 7.
  phys_write(0x40940 + (056 + 7), fixnum((int32_t)((7u << 27) | 20151u)));

  // Enter FEP-STARTUP as the boot PROM would: FEP mode, a frame on the boot stack.
  cpu.init();
  W startup = phys_read(0x41002);
  fprintf(stderr, "FEP-STARTUP = %02o:%08x, FEP version %u\n", wtag(startup), wdata(startup),
          wdata(phys_read(0x41000)));
  cpu.sp = stack_base;
  phys_write(cpu.sp + 1 - VMA_PMA_BASE, mkwc(3, DTP_EVEN_PC, 0xFFFE0040u));
  phys_write(cpu.sp + 2 - VMA_PMA_BASE, mkwc(3, DTP_FIXNUM, cpu.cr));
  cpu.sp += 2;
  cpu.fp = cpu.sp - 1;
  cpu.lp = cpu.sp + 1;
  cpu.cr = (3u << 30) | (2 /*argsize*/) | (1u << 18);
  cpu.cont = mkw(DTP_EVEN_PC, 0xFFFE0040u);
  cpu.pc = (uint64_t)wdata(startup) << 1;
  cpu.control_stack_limit = mkw(DTP_LOCATIVE, stack_base + stack_size - 0x100);
  cpu.control_stack_extra_limit = mkw(DTP_LOCATIVE, stack_base + stack_size);

}
