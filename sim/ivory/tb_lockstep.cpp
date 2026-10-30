// Lockstep test: the RTL Ivory and the C++ model each run the XL1200 (their
// own Machine: boot PROM, memory, NVRAM, I/O board, disk) from reset, and after
// every step their registers and every RAM word either of them wrote must agree.
//   ./obj_dir/Vivory_cpu PROM.mem DISK.dd [STEPS] [TYPE-AT TEXT]
// The disk image is copied twice (one copy per machine); TEXT is typed on both
// consoles from step TYPE-AT ('|' is Return).
#include <cstdio>
#include <cstdlib>
#include <chrono>
#include <deque>
#include <filesystem>
#include <set>
#include <string>
#include <unistd.h>
#include "Vivory_cpu.h"
#include "Vivory_cpu___024root.h"
#include "verilated.h"
#include "machine.h"

const char* ivory_opcode_name(int op);

#define R(x) top->rootp->ivory_cpu__DOT__##x

static Vivory_cpu* top;
static Machine* dbus;            // the RTL's machine
static uint64_t cycles = 0;
static bool mem_acked = false, cop_acked = false;
static const time_t BOOT_TIME = 625000000;   // 1989-10-21, for both NVRAM clocks

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

static void load_rtl(Ivory& c) {
  R(pc) = c.pc; R(sp) = c.sp; R(fp) = c.fp; R(lp) = c.lp; R(cont) = c.cont; R(cr) = c.cr;
  for (int i = 0; i < 4; i++) R(bar)[i] = c.bar[i];
  R(alu_control) = c.alu_control; R(rotate_latch) = c.rotate_latch;
  R(ephemeral_oldspace) = c.ephemeral_oldspace; R(zone_oldspace) = c.zone_oldspace;
  R(fp_coprocessor_present) = c.fp_coprocessor_present; R(preempt_register) = c.preempt_register;
  R(icache_control) = c.icache_control; R(prefetcher_control) = c.prefetcher_control;
  R(map_cache_control) = c.map_cache_control; R(memory_control) = c.memory_control;
  R(stack_cache_lower_bound) = c.stack_cache_lower_bound;
  R(stack_cache_overflow_limit) = c.stack_cache_overflow_limit;
  R(entry_max_args) = c.entry_max_args; R(chip_revision) = c.chip_revision;
  R(pht_base) = c.pht_base; R(pht_mask) = c.pht_mask;
  for (int i = 0; i < 32; i++) R(irw)[i] = irw_field(c, i) ? *irw_field(c, i) : 0;
  for (int i = 0; i < 512; i++) R(scratch)[i] = c.scratch[i];
  R(icount) = c.icount; R(trap_count) = c.trap_count;
}

// The FEP runs in the VMA=PMA zone and on physical addresses; translation of
// other virtual addresses (map cache, PHT) isn't in the RTL yet.
static bool physical(uint32_t vma, bool phys, uint32_t& pa) {
  if (phys) { pa = vma; return true; }
  if (vma >= VMA_PMA_BASE) { pa = vma - VMA_PMA_BASE; return true; }
  return false;
}

static void tick() {
  // Respond to requests made at the last edge; acknowledgements last one cycle.
  if (mem_acked) { top->mem_ack = 0; mem_acked = false; }
  else if (top->mem_req) {
    uint32_t pa;
    bool we = top->mem_we, buserr = false;
    W rd = 0;
    if (!physical(top->mem_addr, top->mem_phys, pa)) {
      printf("RTL used virtual address %08x, which needs translation (pc=%08llx)\n", top->mem_addr,
             (unsigned long long)R(pc));
      exit(1);
    }
    try {
      if (we) dbus->phys_write(pa, top->mem_wdata);
      else rd = dbus->phys_read(pa);
    } catch (BusError&) { buserr = true; }
    top->mem_rdata = rd; top->mem_fault = 0; top->mem_buserr = buserr;
    top->mem_ack = 1; mem_acked = true;
  }
  if (cop_acked) { top->cop_ack = 0; cop_acked = false; }
  else if (top->cop_req) {
    bool e = false;
    W rd = 0;
    try {
      if (top->cop_we) dbus->coproc_write(top->cop_reg, top->cop_wdata);
      else rd = dbus->coproc_read(top->cop_reg);
    } catch (CoprocError&) { e = true; }
    top->cop_rdata = rd; top->cop_err = e;
    top->cop_ack = 1; cop_acked = true;
  }
  top->hp_sb = dbus->high_priority_sb();
  top->lp_sb = dbus->low_priority_sb();
  top->reset_req = dbus->reset_request();
  top->usec_clock = dbus->microsecond_clock();
  top->clk = 1; top->eval();
  if (top->hp_sb_taken) dbus->sb_taken(true);
  if (top->lp_sb_taken) dbus->sb_taken(false);
  top->clk = 0; top->eval();
  cycles++;
}

// The machine's NVRAM clock counts from BOOT_TIME by its own device time
static void set_up(Machine& m, const std::string& prom, const std::string& disk) {
  m.log_io = false;
  m.iob.log_io = false;
  m.nvram.set_time_source([&m] { return BOOT_TIME + (time_t)(m.microsecond_clock() / 1000000); });
  m.load_prom(prom);
  m.attach_disk(0, disk, 1280, 1536);
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  if (argc < 3) {
    fprintf(stderr, "usage: %s PROM.mem DISK.dd [STEPS] [TYPE-AT TEXT]\n", argv[0]);
    return 1;
  }
  uint64_t steps = argc > 3 ? strtoull(argv[3], nullptr, 0) : 1000000;
  uint64_t type_at = argc > 5 ? strtoull(argv[4], nullptr, 0) : ~0ull;
  std::string text = argc > 5 ? argv[5] : "";

  // one copy of the disk per machine
  namespace fs = std::filesystem;
  fs::path dir = fs::temp_directory_path() / ("lockstep-" + std::to_string(getpid()));
  fs::create_directories(dir);
  fs::copy_file(argv[2], dir / "ref.dd");
  fs::copy_file(argv[2], dir / "rtl.dd");

  Machine rbus(4u << 20, ""), dmachine(4u << 20, "");
  dbus = &dmachine;
  Ivory ref(&rbus);
  set_up(rbus, argv[1], (dir / "ref.dd").string());
  set_up(*dbus, argv[1], (dir / "rtl.dd").string());
  ref.init();   // reset: PC at the PROM entry, FEP mode

  top = new Vivory_cpu;
  top->reset = 1; top->clk = 0; top->eval();
  tick();
  top->reset = 0;
  load_rtl(ref);   // after reset, which sets the registers to their power-up values
  top->run = 1;

  std::vector<uint32_t> rlog, dlog;
  rbus.write_log = &rlog;
  dbus->write_log = &dlog;
  std::deque<std::pair<uint64_t, uint64_t>> history;   // (step, pc) of recent steps
  uint64_t opcount[257] = {};                          // coverage; [256] = full-word instructions
  std::set<uint32_t> pcs;
  size_t typed = 0;
  uint64_t next_key = type_at;
  auto t0 = std::chrono::steady_clock::now();
  int status = 0;

  for (uint64_t n = 0; n < steps; n++) {
    uint64_t pc0 = ref.pc;
    rlog.clear();
    dlog.clear();
    // the same keys reach both consoles before the same step
    if (n >= next_key && typed < text.size()) {
      char c[2] = {text[typed] == '|' ? '\r' : text[typed], 0};
      rbus.iob.console.type(c);
      dbus->iob.console.type(c);
      next_key = n + (text[typed] == '|' ? 3000000 : 200000);
      typed++;
    }
    try {
      ref.step();
    } catch (ProcessorHalt& h) {
      printf("reference halted: %s\n", h.why.c_str());
      status = 1;
      break;
    }
    rbus.tick(1);

    uint64_t c0 = cycles;
    do {
      tick();
      if (top->halted) {
        printf("RTL halted (code %d) at step %llu pc=%08x.%d\n", R(halt_code), (unsigned long long)n,
               (uint32_t)(pc0 >> 1), (int)(pc0 & 1));
        return 1;
      }
      if (cycles - c0 > 2000000) {
        printf("RTL hung at step %llu: state %d pc=%08llx\n", (unsigned long long)n, (int)R(st),
               (unsigned long long)R(pc));
        return 1;
      }
    } while (!top->retire);
    dbus->tick(1);

    history.emplace_back(n, pc0);
    {
      uint32_t pa;
      W w = physical((uint32_t)(pc0 >> 1), false, pa) ? rbus.phys_read(pa) : 0;
      uint32_t half = (pc0 & 1) ? (uint32_t)((((w >> 32) & 0xF) << 14) | (wdata(w) >> 18))
                                : (uint32_t)(wdata(w) & 0x3FFFF);
      opcount[wtype(w) >= 060 ? (half >> 10) & 0xFF : 256]++;
      pcs.insert((uint32_t)pc0);
    }
    if (history.size() > 24) history.pop_front();

    // Compare
    std::string bad;
    auto chk = [&](const char* name, uint64_t a, uint64_t b) {
      if (a != b) {
        char buf[160];
        snprintf(buf, sizeof buf, "  %-14s ref %010llx  rtl %010llx\n", name, (unsigned long long)a,
                 (unsigned long long)b);
        bad += buf;
      }
    };
    chk("pc", ref.pc, R(pc));
    chk("sp", ref.sp, R(sp));
    chk("fp", ref.fp, R(fp));
    chk("lp", ref.lp, R(lp));
    chk("cr", ref.cr, R(cr));
    chk("cont", ref.cont, R(cont));
    chk("icount", ref.icount, R(icount));
    for (int i = 0; i < 4; i++) chk("bar", ref.bar[i], R(bar)[i]);
    chk("alu_control", ref.alu_control, R(alu_control));
    chk("rotate_latch", ref.rotate_latch, R(rotate_latch));
    chk("preempt", ref.preempt_register, R(preempt_register));
    for (int i = 0; i < 32; i++)
      if (W* f = irw_field(ref, i)) {
        char name[16];
        snprintf(name, sizeof name, "irw[%o]", i);
        chk(name, *f, R(irw)[i]);
      }
    std::set<uint32_t> addrs(rlog.begin(), rlog.end());
    addrs.insert(dlog.begin(), dlog.end());
    for (uint32_t a : addrs)
      if (rbus.ram[a] != dbus->ram[a]) {
        char name[32];
        snprintf(name, sizeof name, "mem %08x", a);
        chk(name, rbus.ram[a], dbus->ram[a]);
      }
    if (!bad.empty()) {
      printf("MISMATCH at step %llu (icount %llu), instruction at %08x.%d:\n%s",
             (unsigned long long)n, (unsigned long long)ref.icount, (uint32_t)(pc0 >> 1), (int)(pc0 & 1),
             bad.c_str());
      printf("recent steps:\n");
      for (auto& h : history) {
        uint32_t pa;
        W w = physical((uint32_t)(h.second >> 1), false, pa) ? rbus.phys_read(pa) : 0;
        uint32_t half = (h.second & 1) ? (uint32_t)((((w >> 32) & 0xF) << 14) | (wdata(w) >> 18))
                                       : (uint32_t)(wdata(w) & 0x3FFFF);
        printf("  %8llu %08x.%d  %s\n", (unsigned long long)h.first, (uint32_t)(h.second >> 1),
               (int)(h.second & 1), wtype(w) >= 060 ? ivory_opcode_name((half >> 10) & 0xFF) : "(full word)");
      }
      status = 1;
      break;
    }
    if ((n + 1) % 1000000 == 0) {
      double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
      printf("%llu steps ok (%.0f steps/s, %.1f cycles/step)\n", (unsigned long long)(n + 1), (n + 1) / s,
             (double)cycles / (n + 1));
      fflush(stdout);
    }
  }
  if (status == 0) {
    printf("%llu steps in lockstep, %llu cycles, %zu distinct PCs, %llu traps\n", (unsigned long long)steps,
           (unsigned long long)cycles, pcs.size(), (unsigned long long)(ref.trap_count));
    int used = 0;
    for (int i = 0; i < 257; i++) used += opcount[i] != 0;
    printf("%d opcodes used:", used);
    for (int i = 0; i < 256; i++)
      if (opcount[i]) printf(" %s:%llu", ivory_opcode_name(i), (unsigned long long)opcount[i]);
    printf(" fullword:%llu\n", (unsigned long long)opcount[256]);
  }
  delete top;
  fs::remove_all(dir);
  return status;
}
