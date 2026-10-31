// System lockstep test: the RTL XL1200 (rtl/xl: processor, boards, memory in
// a DDR3 model, disks on a model of MiSTer's SD block interface) and the C++
// model (emu/) each run from reset; the RTL keeps the model's device time
// (LOCKSTEP).  After every instruction their registers and every RAM word
// either wrote must agree.  At the end the video memories are compared, and
// the RTL's display output is captured for two frames.
//   ./obj_dir/Vxl_machine DISK.dd [STEPS] [TYPE-AT TEXT] [SCREEN.pgm]
// The disk image is copied twice (one copy per machine); TEXT is typed on both
// consoles from step TYPE-AT ('|' is Return, {w N} waits N million steps).
// LOCKSTEP_FROM=N: the model runs alone for the first N steps, then its state
// is copied into the RTL (transfer.h) and the lockstep starts there.
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <deque>
#include <filesystem>
#include <fstream>
#include <map>
#include <set>
#include <string>
#include <unistd.h>
#include <vector>
#include "Vxl_machine.h"
#include "Vxl_machine___024root.h"
#include "verilated.h"
#include "ddr_model.h"
#include "sd_model.h"
#include "keyboard.h"
#include "machine.h"
#include "transfer.h"

const char* ivory_opcode_name(int op);

#define R(x) top->rootp->xl_machine__DOT__core__DOT__cpu__DOT__##x
#define M(x) top->rootp->xl_machine__DOT__##x
#ifndef PROM_PATH
#error PROM_PATH
#endif

static Vxl_machine* top;
static DdrModel ddr;
static uint64_t cycles = 0;
static std::map<int, uint64_t> prof_cpu;   // PROFILE: cycles by processor state
static uint64_t prof_mmu[16], prof_mem[16];
static const time_t BOOT_TIME = 625000000;   // 1989-10-21, for both NVRAM clocks
static const uint32_t RAM_BASE = 0x06000000, BUF_BASE = 0x06400000;

static SdModel<Vxl_machine> sd;

// ---------------------------------------------------------------- console input
static std::deque<std::pair<bool, uint8_t>> keys;   // (down, key) for the RTL console

static void type_rtl(char c) {
  uint8_t k;
  bool shift;
  if (!ascii_to_key(c, k, shift)) return;
  if (shift) keys.emplace_back(true, K_LEFT_SHIFT);
  keys.emplace_back(true, k);
  keys.emplace_back(false, k);
  if (shift) keys.emplace_back(false, K_LEFT_SHIFT);
}

static void tick() {
  top->key_strobe = 0;
  if (!keys.empty()) {
    top->key_strobe = 1;
    top->key_down = keys.front().first;
    top->key_code = keys.front().second;
    keys.pop_front();
  }
  sd.step(top);
  top->clk = 0; top->eval();
  ddr.sample(top);
  top->clk = 1; top->eval();
  ddr.update(top);
  top->eval();
  cycles++;
}

static void set_rtc() {
  struct tm tm;
  time_t t = BOOT_TIME;
  gmtime_r(&t, &tm);
  auto bcd = [](int v) { return (uint32_t)(((v / 10) << 4) | (v % 10)); };
  top->rtc[0] = bcd(tm.tm_sec) | bcd(tm.tm_min) << 8 | bcd(tm.tm_hour) << 16 | bcd(tm.tm_mday) << 24;
  top->rtc[1] = bcd(tm.tm_mon + 1) | bcd(tm.tm_year % 100) << 8 | (uint32_t)tm.tm_wday << 16 | 0x40u << 24;
  top->rtc[2] ^= 1;   // RTC[64] toggles: new time
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  if (argc < 2) {
    fprintf(stderr, "usage: %s DISK.dd [STEPS] [TYPE-AT TEXT] [SCREEN.pgm]\n", argv[0]);
    return 1;
  }
  uint64_t steps = argc > 2 ? strtoull(argv[2], nullptr, 0) : 1000000;
  uint64_t type_at = argc > 4 ? strtoull(argv[3], nullptr, 0) : ~0ull;
  std::string text = argc > 4 ? argv[4] : "";
  const char* screen = argc > 5 ? argv[5] : nullptr;

  namespace fs = std::filesystem;
  fs::path dir = fs::temp_directory_path() / ("xlsys-" + std::to_string(getpid()));
  fs::create_directories(dir);
  fs::copy_file(argv[1], dir / "ref.dd");
  fs::copy_file(argv[1], dir / "rtl.dd");

  // the reference
  Machine rbus(4u << 20, "");
  Ivory ref(&rbus);
  rbus.log_io = false;
  rbus.iob.log_io = false;
  rbus.nvram.set_time_source([&rbus] { return BOOT_TIME + (time_t)(rbus.microsecond_clock() / 1000000); });
  rbus.load_prom(PROM_PATH);
  rbus.attach_disk(0, (dir / "ref.dd").string(), 1280, 1536);
  ref.init();

  // the RTL
  ddr.flat_base = RAM_BASE;
  ddr.flat.assign(BUF_BASE + 0x10000 - RAM_BASE, 0);
  // Lockstep compares instructions, not timing: no wait states, one-cycle
  // reads (obj_free keeps the random ones).
  // PROFILE=1 keeps the random ones and counts cycles by state (see the end).
  bool profile = getenv("PROFILE") != nullptr;
  if (!profile) {
    ddr.busy_pct = 0;
    ddr.min_latency = ddr.max_latency = 1;
  }
  sd.f[0] = fopen((dir / "rtl.dd").string().c_str(), "r+b");
  top = new Vxl_machine;
  top->power_on = 1;
  top->reset = 1;
  top->rtc_back28 = 0;
  top->net_ena = 0;
  set_rtc();
  for (int i = 0; i < 4; i++) tick();
  // mount the image (hps_io: img_size, then a one-cycle img_mounted)
  top->img_size = fs::file_size(dir / "rtl.dd");
  top->img_readonly = 0;
  top->img_mounted = 1;
  tick();
  top->img_mounted = 0;
  top->power_on = 0;
  for (int i = 0; i < 100; i++) tick();     // memory ready (no clearing), block count
  top->reset = 0;

  size_t typed = 0;
  uint64_t next_key = type_at;
  // the same keys reach both consoles before the same step (only the model's
  // while it runs alone)
  auto type_keys = [&](uint64_t n, bool rtl) {
    if (n >= next_key && typed < text.size()) {
      if (text[typed] == '{') {   // {w N}: wait N million steps
        size_t end = text.find('}', typed);
        next_key = n + strtoull(text.c_str() + typed + 2, nullptr, 0) * 1000000;
        typed = end == std::string::npos ? text.size() : end + 1;
      } else {
        char c[2] = {text[typed] == '|' ? '\r' : text[typed], 0};
        rbus.iob.console.type(c);
        if (rtl) type_rtl(c[0]);
        next_key = n + (text[typed] == '|' ? 3000000 : 200000);
        typed++;
      }
    }
  };
  uint64_t from = getenv("LOCKSTEP_FROM") ? strtoull(getenv("LOCKSTEP_FROM"), nullptr, 0) : 0;
  if (from) {
    auto f0 = std::chrono::steady_clock::now();
    for (uint64_t n = 0; n < from; n++) {
      type_keys(n, false);
      try {
        ref.step();
      } catch (ProcessorHalt& h) {
        printf("reference halted at step %llu: %s\n", (unsigned long long)n, h.why.c_str());
        return 1;
      }
      rbus.tick(1);
    }
    ModelState::to_rtl(ref, rbus, top, ddr, RAM_BASE, BUF_BASE, sd.f[0], dir / "ref.dd", dir / "rtl.dd");
    printf("model ran %llu steps alone (%.0f s); the RTL starts from its state\n", (unsigned long long)from,
           std::chrono::duration<double>(std::chrono::steady_clock::now() - f0).count());
  }

  std::vector<uint32_t> rlog, dlog;
  rbus.write_log = &rlog;
  ddr.write_log = &dlog;
  std::deque<std::pair<uint64_t, uint64_t>> history;
  uint64_t opcount[257] = {};
  std::set<uint32_t> pcs;
  auto t0 = std::chrono::steady_clock::now();
  int status = 0;
  auto ram_word = [](uint32_t pa) { return (W)(ddr.flat[pa] & 0xFFFFFFFFFFull); };

  uint64_t n;
  bool pit_checked = true;   // report the first step after which the 82C54s differ
  for (n = from; n < steps; n++) {
    uint64_t pc0 = ref.pc;
    rlog.clear();
    dlog.clear();
    type_keys(n, true);
    try {
      ref.step();
    } catch (ProcessorHalt& h) {
      printf("reference halted: %s\n", h.why.c_str());
      status = 1;
      break;
    }
    Pit82C54 pit_before = rbus.pit;   // the RTL's 82C54 ticks on the edge after the retire
    rbus.tick(1);

    uint64_t c0 = cycles;
    do {
      if (profile) {
        prof_cpu[R(st)]++;
        prof_mmu[M(core__DOT__mmu__DOT__st) & 15]++;
        prof_mem[M(mem__DOT__st) & 15]++;
      }
      tick();
      if (top->halted) {
        printf("RTL halted (code %d) at step %llu pc=%08x.%d\n", top->halt_reason, (unsigned long long)n,
               (uint32_t)(pc0 >> 1), (int)(pc0 & 1));
        return 1;
      }
      if (cycles - c0 > 4000000) {
        printf("RTL hung at step %llu: state %d pc=%08llx\n", (unsigned long long)n, (int)R(st),
               (unsigned long long)R(pc));
        return 1;
      }
    } while (!top->retire);

    if (pit_checked && !ModelState::pit_same(pit_before, top)) {
      printf("82C54 differs after step %llu, instruction at %08x.%d\n", (unsigned long long)n,
             (uint32_t)(pc0 >> 1), (int)(pc0 & 1));
      ModelState::print_pit(pit_before);
      for (int k = 0; k < 3; k++)
        printf("  rtl pit %d: value %u pending %d out %d\n", k, M(pit__DOT__value)[k],
               (M(pit__DOT__pending) >> k) & 1, (M(pit__DOT__out) >> k) & 1);
      pit_checked = false;
    }
    history.emplace_back(n, pc0);
    {
      W w = (pc0 >> 1) >= VMA_PMA_BASE ? rbus.phys_read((uint32_t)(pc0 >> 1) - VMA_PMA_BASE) : 0;
      uint32_t half = (pc0 & 1) ? (uint32_t)((((w >> 32) & 0xF) << 14) | (wdata(w) >> 18))
                                : (uint32_t)(wdata(w) & 0x3FFFF);
      opcount[wtype(w) >= 060 ? (half >> 10) & 0xFF : 256]++;
      pcs.insert((uint32_t)pc0);
    }
    if (history.size() > 24) history.pop_front();

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
    std::set<uint32_t> addrs(rlog.begin(), rlog.end());
    for (uint32_t a : dlog)
      if (a >= RAM_BASE && a < RAM_BASE + (4u << 20)) addrs.insert(a - RAM_BASE);
    for (uint32_t a : addrs)
      if (rbus.ram[a] != ram_word(a)) {
        char name[32];
        snprintf(name, sizeof name, "mem %08x", a);
        chk(name, rbus.ram[a], ram_word(a));
      }
    if (!bad.empty()) {
      printf("MISMATCH at step %llu (icount %llu), instruction at %08x.%d:\n%s", (unsigned long long)n,
             (unsigned long long)ref.icount, (uint32_t)(pc0 >> 1), (int)(pc0 & 1), bad.c_str());
      printf("  ref interrupts %08x mask %08x hp %d lp %d cycles %llu; rtl pending %08x mask %08x "
             "hp %d lp %d ticks %u pit_out %x\n",
             rbus.interrupts_pending(), rbus.interrupt_mask, rbus.hp_sb, rbus.lp_sb,
             (unsigned long long)rbus.cycles, M(int_pending), M(int_mask), M(hp_sb), M(lp_sb),
             M(ticks), M(pit_out));
      ModelState::print_pit(rbus.pit);
      for (int k = 0; k < 3; k++)
        printf("  rtl pit %d: mode %d reload %u value %u pending %d counting %d out %d msb_next %d\n", k,
               M(pit__DOT__mode)[k], M(pit__DOT__reload)[k], M(pit__DOT__value)[k], (M(pit__DOT__pending) >> k) & 1,
               (M(pit__DOT__counting) >> k) & 1, (M(pit_out) >> k) & 1, (M(pit__DOT__msb_next) >> k) & 1);
      printf("recent steps:\n");
      for (auto& h : history) {
        uint32_t pa;
        W w = ref.debug_translate((uint32_t)(h.second >> 1), pa) ? rbus.phys_read(pa) : 0;
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
      printf("%llu steps ok (%.0f steps/s, %.1f cycles/step)\n", (unsigned long long)(n + 1), (n + 1 - from) / s,
             (double)cycles / (n + 1 - from));
      fflush(stdout);
    }
  }

  if (profile) {
    // CPU state names, in the order tools/gen_ivory_states.py numbers them
    std::vector<std::string> names;
    std::ifstream en(std::string(PROM_PATH).substr(0, std::string(PROM_PATH).rfind("/xl/")) +
                     "/ivory/ivory_cpu_state_enum.svh");
    for (std::string line; std::getline(en, line);)
      for (size_t i = 0; (i = line.find("S_", i)) != std::string::npos;) {
        size_t j = line.find_first_of(", \n", i);
        names.push_back(line.substr(i, j - i));
        i = j;
      }
    uint64_t total = 0;
    for (auto& [k, v] : prof_cpu) total += v;
    std::vector<std::pair<uint64_t, int>> top_states;
    for (auto& [k, v] : prof_cpu) top_states.emplace_back(v, k);
    std::sort(top_states.rbegin(), top_states.rend());
    printf("profile: %llu cycles, %llu instructions, %.2f cycles/instruction\n", (unsigned long long)total,
           (unsigned long long)(n - from), (double)total / (n - from));
    for (size_t i = 0; i < top_states.size() && i < 25; i++)
      printf("  cpu %-16s %5.1f%%\n", top_states[i].second < (int)names.size() ? names[top_states[i].second].c_str() : "?",
             100.0 * top_states[i].first / total);
    const char* mmu_names[] = {"IDLE", "W0", "W1", "AGE", "FILL", "HIT", "N1", "N2", "ACCESS",
                               "?", "?", "?", "?", "?", "?", "?"};
    const char* mem_names[] = {"CLEAR", "IDLE", "MISS", "FILL", "BUF_RD",
                               "BUF_WAIT", "BUF_WR", "?", "?", "?", "?", "?", "?", "?", "?", "?"};
    for (int i = 0; i < 16; i++)
      if (prof_mmu[i]) printf("  mmu %-8s %5.1f%%\n", mmu_names[i], 100.0 * prof_mmu[i] / total);
    for (int i = 0; i < 16; i++)
      if (prof_mem[i]) printf("  mem %-8s %5.1f%%\n", mem_names[i], 100.0 * prof_mem[i] / total);
  }

  // Video memory
  auto& vram = top->rootp->xl_machine__DOT__iob__DOT__video__DOT__vram;
  uint32_t vdiff = 0;
  for (uint32_t i = 0; i < 0x10000; i++) vdiff += rbus.iob.video[i] != vram[i];
  printf("video memory: %u of 65536 words differ\n", vdiff);
  if (vdiff) status = 1;

  if (status == 0) {
    printf("%llu steps in lockstep, %llu cycles, %zu distinct PCs, %llu traps\n", (unsigned long long)n,
           (unsigned long long)cycles, pcs.size(), (unsigned long long)ref.trap_count);
    int used = 0;
    for (int i = 0; i < 257; i++) used += opcount[i] != 0;
    printf("%d opcodes used\n", used);
  }

  // Two frames of the display (dot clock only), the second written as a PGM
  if (screen) {
    std::vector<uint8_t> img;
    int x = 0, y = 0, frames = 0, w = 0, h = 0;
    bool was_vs = false, was_hs = false, line_had = false;
    std::vector<uint8_t> line;
    for (uint64_t c = 0; c < 6000000 && frames < 3; c++) {
      top->clk_vid = 0; top->eval();
      top->clk_vid = 1; top->eval();
      bool de = !top->hblank && !top->vblank;
      if (de) { line.push_back(top->white ? 255 : 0); line_had = true; }
      if (top->hs && !was_hs && line_had) {
        if (frames == 2) { w = (int)line.size(); img.insert(img.end(), line.begin(), line.end()); h++; }
        line.clear();
        line_had = false;
      }
      if (top->vs && !was_vs) frames++;
      was_vs = top->vs;
      was_hs = top->hs;
    }
    (void)x; (void)y;
    if (h > 0) {
      FILE* f = fopen(screen, "wb");
      fprintf(f, "P5\n%d %d\n255\n", w, h);
      fwrite(img.data(), 1, img.size(), f);
      fclose(f);
      printf("display: %d x %d written to %s\n", w, h, screen);
    } else printf("display: no picture\n");
  }

  delete top;
  fs::remove_all(dir);
  return status;
}
