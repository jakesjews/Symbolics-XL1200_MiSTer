// Symbolics XL1200 (Merlin-II) machine model: physical address space and devices.
#pragma once
#include <cstdint>
#include <map>
#include <string>
#include <vector>
#include "cpu.h"
#include "fpa.h"
#include "ioboard.h"
#include "nvram.h"
#include "pit.h"

class Machine : public Bus {
public:
  // nvram_path: where the NVRAM persists ("" for nowhere)
  explicit Machine(uint32_t ram_words, const std::string& nvram_path = "xl1200.nvram");

  // Bus interface
  W phys_read(uint32_t pa) override;
  void phys_write(uint32_t pa, W w) override;
  W coproc_read(unsigned reg) override;
  void coproc_write(unsigned reg, W w) override;
  uint32_t microsecond_clock() override;
  bool high_priority_sb() override { return hp_sb; }
  bool low_priority_sb() override { return lp_sb; }
  bool reset_request() override { return false; }

  // Main-board memory at physical 0 (4 MW on the reference XL1201: two 2 MW banks).
  std::vector<W> ram;
  Nvram nvram;
  std::vector<W> prom;            // boot PROM, physical 0x07FE0000, 64K words
  static const uint32_t PROM_BASE = 0x07FE0000u;
  static const uint32_t PROM_SIZE = 0x10000u;
  IoBoard iob;                    // I/O board slot 0 at 0x40000000
  Pit82C54 pit;                   // interval timer, 0x08000000 (1 MHz)
  Wtl3164 fpa;                    // floating-point accelerator, coprocessor 0-0o777
  bool fpa_fitted = true;         // false: as a machine without the FPA option

  // Interrupt register (0x0A00000C; Genera i-sys/io-register-definitions):
  // reads give the pending sources, writes set the mask.  Bit 0 timer 2,
  // 1 timers 1&0 (the only low-priority source), 8 SCSI controller,
  // 16 serial controller, 17 serial DMA, 18 Ethernet.
  uint32_t interrupt_mask = 0;
  uint32_t interrupts_pending() const;

  // Merlin-II ECO register (0x0A000008): one 4-bit ECO level per board slot.
  // Nibble 0 = main board, 1-3 = memory boards, 4-6 = I/O boards; F = absent.
  // Values match the reference XL1201 (main board ECO 1, I/O board ECO 5).
  static const uint32_t ECO_REGISTER = 0xFFF5FFF1u;

  void attach_disk(int scsi_id, const std::string& path, uint32_t block_size = 1280, uint32_t stride = 1536);
  void load_fep_file(const std::string& path);  // FEP kernel load format
  void load_prom(const std::string& path);      // boot PROM image (tools/bootprom.py)
  void tick(uint64_t n);                        // advance device time by n CPU cycles
  void boot_fep(Ivory& cpu);                    // do what the boot PROM does, start the FEP

  // When set, the physical address of every RAM write is appended here.
  std::vector<uint32_t>* write_log = nullptr;

  bool hp_sb = false, lp_sb = false;
  uint64_t cycles = 0;            // advanced by the run loop
  uint32_t pit_usec = 0;          // microsecond clock value the timer has counted to

  // Accesses to not-yet-modelled registers are logged (a few per address).
  bool log_io = true;
  FILE* logf = stderr;
  std::map<uint32_t, W> io_regs;
  std::map<uint32_t, uint64_t> io_count;
};
