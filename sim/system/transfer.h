// Copy the C++ model's machine state into the RTL machine (built with
// --public-flat-rw), so a lockstep run can start anywhere: the model runs
// alone to the starting step, then this loads the RTL from it.  The RTL must
// be out of reset and not have run an instruction.  Both map caches start
// empty (the RTL's MMU is cleared at reset; the model's is flushed here), as
// do both instruction buffers.  Each block names the RTL module it loads.
#pragma once
#include <cstdio>
#include <ctime>
#include <filesystem>
#include <string>
#include "Vxl_machine.h"
#include "Vxl_machine___024root.h"
#include "ddr_model.h"
#include "machine.h"

#define RS(x) top->rootp->xl_machine__DOT__##x

struct ModelState {
  static uint8_t bcd(int v) { return (uint8_t)(((v / 10) << 4) | (v % 10)); }

  // Internal registers 01001-01031 kept in the RTL's IRW array
  static W* irw_field(Ivory& c, int i) {
    switch (i) {
    case 1: return &c.event_count;
    case 2: return &c.binding_stack_pointer;
    case 3: return &c.catch_block_list;
    case 4: return &c.control_stack_limit;
    case 5: return &c.control_stack_extra_limit;
    case 6: return &c.binding_stack_limit;
    case 011: return &c.count_map_reloads;
    case 012: return &c.list_cache_area;
    case 013: return &c.list_cache_address;
    case 014: return &c.list_cache_length;
    case 015: return &c.structure_cache_area;
    case 016: return &c.structure_cache_address;
    case 017: return &c.structure_cache_length;
    case 020: return &c.dynamic_binding_cache_base;
    case 021: return &c.dynamic_binding_cache_mask;
    case 022: return &c.choice_pointer;
    case 023: return &c.structure_stack_choice_pointer;
    case 024: return &c.fep_mode_trap_vector_address;
    case 026: return &c.mapping_table_cache;
    case 027: return &c.mapping_table_length;
    case 030: return &c.stack_frame_maximum_size;
    case 031: return &c.stack_cache_dump_quantum;
    default: return nullptr;
    }
  }

  // The model's 82C54 counters, for mismatch reports
  static void print_pit(Pit82C54& p) {
    for (int n = 0; n < 3; n++) {
      auto& k = p.c[n];
      printf("  ref pit %d: mode %d reload %u value %u pending %d counting %d out %d msb_next %d\n", n,
             k.mode, k.reload, k.value, k.pending, k.counting, k.out, k.msb_next);
    }
  }

  // Whether the RTL's 82C54 counters match the model's
  static bool pit_same(Pit82C54& p, Vxl_machine* top) {
    for (int n = 0; n < 3; n++) {
      auto& k = p.c[n];
      if (RS(pit__DOT__value)[n] != (k.value & 0x1FFFF) || ((RS(pit__DOT__out) >> n) & 1) != k.out ||
          ((RS(pit__DOT__pending) >> n) & 1) != k.pending)
        return false;
    }
    return true;
  }

  static void to_rtl(Ivory& c, Machine& m, Vxl_machine* top, DdrModel& ddr, uint32_t ram_base, uint32_t buf_base,
                     FILE*& rtl_disk, const std::filesystem::path& ref_disk, const std::filesystem::path& rtl_disk_path) {
    c.flush_map();
    c.ib_valid = false;

    // ---- processor (ivory_cpu)
#define CPU(x) RS(core__DOT__cpu__DOT__##x)
    CPU(pc) = c.pc; CPU(sp) = c.sp; CPU(fp) = c.fp; CPU(lp) = c.lp; CPU(cont) = c.cont; CPU(cr) = c.cr;
    for (int i = 0; i < 4; i++) CPU(bar)[i] = c.bar[i];
    CPU(alu_control) = c.alu_control; CPU(rotate_latch) = c.rotate_latch;
    CPU(ephemeral_oldspace) = c.ephemeral_oldspace; CPU(zone_oldspace) = c.zone_oldspace;
    CPU(fp_coprocessor_present) = c.fp_coprocessor_present; CPU(preempt_register) = c.preempt_register;
    CPU(icache_control) = c.icache_control; CPU(prefetcher_control) = c.prefetcher_control;
    CPU(map_cache_control) = c.map_cache_control; CPU(memory_control) = c.memory_control;
    CPU(stack_cache_lower_bound) = c.stack_cache_lower_bound;
    CPU(stack_cache_overflow_limit) = c.stack_cache_overflow_limit;
    CPU(entry_max_args) = c.entry_max_args; CPU(chip_revision) = c.chip_revision;
    CPU(pht_base) = c.pht_base; CPU(pht_mask) = c.pht_mask;
    for (int i = 0; i < 32; i++) CPU(irw)[i] = irw_field(c, i) ? *irw_field(c, i) : 0;
    for (int i = 0; i < 512; i++) CPU(scratch)[i] = c.scratch[i];
    CPU(icount) = c.icount; CPU(trap_count) = c.trap_count;
#undef CPU

    // ---- memory (xl_mem: DDR3; its cache is empty after reset)
    for (uint32_t a = 0; a < m.ram.size(); a++) ddr.flat[a] = m.ram[a];
    for (uint32_t i = 0; i < IoBoard::BUFFER_WORDS; i++) ddr.flat[buf_base - ram_base + i] = m.iob.buffer[i];

    // ---- main board (xl_machine): device time, registers, VME, interrupt mask
    uint64_t usec = m.cycles / 4;
    RS(ticks) = (uint32_t)m.cycles;
    RS(usec) = (uint32_t)usec;
    RS(sec_div) = (uint32_t)(usec % 1000000);
    RS(int_mask) = m.interrupt_mask;
    auto io = [&](uint32_t pa) { auto it = m.io_regs.find(pa); return it == m.io_regs.end() ? 0u : wdata(it->second); };
    RS(mb_reg)[0] = io(0x0A000000u);
    RS(mb_reg)[1] = io(0x0A000004u);
    for (uint32_t i = 0; i < 1024; i++) RS(vme)[i] = io(0x88000000u + i);

    // ---- 82C54 (xl_pit)
    uint8_t msb = 0, pend = 0, cnt = 0, out = 0;
    for (int n = 0; n < 3; n++) {
      auto& k = m.pit.c[n];
      RS(pit__DOT__mode)[n] = k.mode;
      RS(pit__DOT__rw)[n] = k.rw;
      RS(pit__DOT__reload)[n] = k.reload;
      RS(pit__DOT__value)[n] = k.value;
      msb |= k.msb_next << n; pend |= k.pending << n; cnt |= k.counting << n; out |= k.out << n;
    }
    RS(pit__DOT__msb_next) = msb; RS(pit__DOT__pending) = pend; RS(pit__DOT__counting) = cnt;
    RS(pit__DOT__out) = out;   // the register; pit_out is only the port's wire

    // ---- NVRAM and clock (xl_nvram)
    Nvram& nv = m.nvram;
    for (int i = 0; i < 0x7F8; i++) RS(nvram__DOT__ram)[i] = nv.mem[i];
    for (int i = 0; i < 8; i++) RS(nvram__DOT__r)[i] = nv.mem[0x7F8 + i];
    RS(nvram__DOT__writing) = nv.writing;
    RS(nvram__DOT__frozen) = nv.frozen;
    {
      time_t t = nv.now() + nv.offset_seconds;
      struct tm tm;
      gmtime_r(&t, &tm);
      RS(nvram__DOT__c_sec) = bcd(tm.tm_sec);
      RS(nvram__DOT__c_min) = bcd(tm.tm_min);
      RS(nvram__DOT__c_hour) = bcd(tm.tm_hour);
      RS(nvram__DOT__c_day) = (uint8_t)(tm.tm_wday + 1);
      RS(nvram__DOT__c_date) = bcd(tm.tm_mday);
      RS(nvram__DOT__c_month) = bcd(tm.tm_mon + 1);
      RS(nvram__DOT__c_year) = bcd(tm.tm_year % 100);
    }
    RS(nvram__DOT__loaded) = 1;
    RS(nvram__DOT__rtc_seen) = top->rtc[2] & 1;

    // ---- FPA (xl_fpa); its arithmetic unit is idle between instructions
    Wtl3164& f = m.fpa;
    RS(fpa__DOT__r0h) = f.r0h; RS(fpa__DOT__r0l) = f.r0l;
    RS(fpa__DOT__r1h) = f.r1h; RS(fpa__DOT__r1l) = f.r1l;
    RS(fpa__DOT__r2h) = f.r2h; RS(fpa__DOT__r2l) = f.r2l;
    RS(fpa__DOT__ix) = f.ix; RS(fpa__DOT__ir) = f.ir; RS(fpa__DOT__cond) = f.cond;
    for (int i = 0; i < 12; i++) RS(fpa__DOT__sr)[i] = f.sr[i];

    // ---- I/O board registers, DUSCC, AM9517 (xl_iob)
    IoBoard& b = m.iob;
#define IOB(x) RS(iob__DOT__##x)
    IOB(video_control) = b.video_control;
    IOB(eth_pins) = (uint8_t)b.ether_pins;
    IOB(polled_latch) = b.polled_latch;
    for (int i = 0; i < 0x40; i++) IOB(duscc)[i] = b.duscc[i];
    uint8_t masked = 0;
    for (int i = 0; i < 4; i++) {
      IOB(dma_base_addr)[i] = b.dma[i].base_addr;
      IOB(dma_base_count)[i] = b.dma[i].base_count;
      IOB(dma_cur_addr)[i] = b.dma[i].addr;
      IOB(dma_count)[i] = b.dma[i].count;
      IOB(dma_mode)[i] = b.dma[i].mode;
      masked |= b.dma[i].masked << i;
    }
    IOB(dma_masked) = masked;
    IOB(dma_ff) = b.dma_flipflop;
    IOB(dma_command) = b.dma_command;
    IOB(dma_status) = b.dma_status;
    IOB(dma_control) = b.dma_control;
    IOB(scsi_window) = b.dma_regs[0];
    IOB(dma_byte_addr) = b.dma_byte_addr;
    auto reg = [&](uint32_t off) { auto it = b.regs.find(off); return it == b.regs.end() ? 0u : it->second; };
    IOB(reg_4800) = reg(0x04014800u);
    IOB(reg_5800) = reg(0x04015800u);
    IOB(reg_28000) = reg(0x04028000u);
    // the console byte rate: a byte goes out when cycles >= next_console_byte
    int64_t wait = (int64_t)b.next_console_byte - (int64_t)m.cycles - 1;
    IOB(con_wait) = (uint16_t)(wait < 0 ? 0 : wait);

    // ---- video memory (xl_video); the timing registers keep their defaults
    for (uint32_t i = 0; i < IoBoard::VIDEO_WORDS; i++) IOB(video__DOT__vram)[i] = b.video[i];
    IOB(video__DOT__display_on) = 1;

    // ---- console (xl_console): keys down, pending bytes, command state
    Console& con = b.console;
    for (int w = 0; w < 4; w++) IOB(console__DOT__keys_down)[w] = 0;
    for (uint8_t k : con.keys_down) IOB(console__DOT__keys_down)[k >> 5] |= 1u << (k & 31);
    if (con.out.size() > 63) fprintf(stderr, "transfer: %zu console bytes pending\n", con.out.size());
    for (size_t i = 0; i < con.out.size() && i < 63; i++) IOB(console__DOT__fifo)[i] = con.out[i];
    IOB(console__DOT__rd) = 0;
    IOB(console__DOT__wr) = (uint8_t)std::min<size_t>(con.out.size(), 63);
    IOB(console__DOT__brightness) = con.brightness;
    IOB(console__DOT__cmd_held) = !con.cmd.empty();
    IOB(console__DOT__cmd) = con.cmd.empty() ? 0 : con.cmd[0];

    // ---- WD33C93 (xl_scsi)
    WD33C93& s = b.scsi;
    for (int i = 0; i < 0x20; i++) IOB(scsi__DOT__regs)[i] = s.regs[i];
    IOB(scsi__DOT__asr) = s.asr;
    for (size_t i = 0; i < s.pending.size() && i < 4; i++) IOB(scsi__DOT__pend)[i] = s.pending[i];
    IOB(scsi__DOT__npend) = (uint8_t)std::min<size_t>(s.pending.size(), 4);
    IOB(scsi__DOT__own_id) = (uint8_t)s.own_id;
    for (int i = 0; i < 8; i++) {
      IOB(scsi__DOT__sense_key)[i] = s.targets[i].sense_key;
      IOB(scsi__DOT__asc)[i] = s.targets[i].asc;
    }

    // ---- 82586 (xl_i82586)
    I82586& e = b.ether;
    IOB(ether__DOT__in_reset) = e.in_reset;
    IOB(ether__DOT__ca) = e.ca;
    IOB(ether__DOT__need_init) = e.need_init;
    IOB(ether__DOT__stat) = (uint8_t)(e.stat >> 12);
    IOB(ether__DOT__cus) = (uint8_t)e.cus;
    IOB(ether__DOT__rus) = (uint8_t)e.rus;
    IOB(ether__DOT__cbl) = e.cbl;
    IOB(ether__DOT__scb) = e.scb;
    IOB(ether__DOT__scb_base) = e.scb_base;
#undef IOB

    // ---- the disk: the RTL's image becomes a copy of the model's
    for (auto& t : s.targets)
      if (t.f) fflush(t.f);
    fclose(rtl_disk);
    std::filesystem::copy_file(ref_disk, rtl_disk_path, std::filesystem::copy_options::overwrite_existing);
    rtl_disk = fopen(rtl_disk_path.string().c_str(), "r+b");

    top->eval();
  }
};

#undef RS
