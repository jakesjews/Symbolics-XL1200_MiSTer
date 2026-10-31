#include <algorithm>
#include <vector>
#include <fstream>
#include <map>
// The RTL XL1200 as it runs on the MiSTer: device time in microseconds of the
// 30.77 MHz clock, SCSI commands running while the processor polls, memory
// cleared at power-up (DDR3 starts with junk), the display clock running.
// No reference model; it prints what the console shows by saving the screen.
//   ./obj_free/Vxl_machine DISK.dd SECONDS [AT-SECONDS TEXT] [SCREEN.pgm]
// TEXT is typed from AT-SECONDS of simulated time ('|' is Return, a key
// every 50 ms, 3 s after a Return, '~' waits 10 s); the screen (the 1152 x
// 880 raster from video memory) is saved every simulated second and at the end.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <deque>
#include <filesystem>
#include <string>
#include <unistd.h>
#include "Vxl_machine.h"
#include "Vxl_machine___024root.h"
#include "verilated.h"
#include "ddr_model.h"
#include "keyboard.h"
#include "sd_model.h"

static Vxl_machine* top;
static DdrModel ddr;
static SdModel<Vxl_machine> sd;
static const double CLK_HZ = 30769231.0; // the machine's clock, as XL1200.sv sets it
static uint64_t cycles = 0;            // clock cycles
static const uint32_t RAM_BASE = 0x06000000, BUF_BASE = 0x06400000;
static std::deque<std::pair<bool, uint8_t>> keys;

static void tick() {
  top->key_strobe = 0;
  if (!keys.empty() && cycles % 4 == 0) {
    top->key_strobe = 1;
    top->key_down = keys.front().first;
    top->key_code = keys.front().second;
    keys.pop_front();
  }
  sd.step(top);
  // the dot clock runs at the processor clock's rate here (80 MHz on the
  // MiSTer): a slower display, the same picture
  top->clk = 0; top->clk_vid = 0; top->eval();
  ddr.sample(top);
  top->clk = 1; top->clk_vid = 1; top->eval();
  ddr.update(top);
  top->eval();
  cycles++;
}

static void save_screen(const char* path) {
  auto& vram = top->rootp->xl_machine__DOT__iob__DOT__video__DOT__vram;
  FILE* f = fopen(path, "wb");
  fprintf(f, "P5\n1152 880\n255\n");
  for (int y = 0; y < 880; y++)
    for (int x = 0; x < 1152; x++) fputc((vram[y * 64 + x / 32] >> (x & 31) & 1) ? 0 : 255, f);
  fclose(f);
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  if (argc < 3) {
    fprintf(stderr, "usage: %s DISK.dd SECONDS [AT-SECONDS TEXT] [SCREEN.pgm]\n", argv[0]);
    return 1;
  }
  uint64_t end = (uint64_t)(atof(argv[2]) * CLK_HZ);
  uint64_t type_at = argc > 4 ? (uint64_t)(atof(argv[3]) * CLK_HZ) : ~0ull;
  std::string text = argc > 4 ? argv[4] : "";
  std::string screen = argc > 5 ? argv[5] : "screen.pgm";

  namespace fs = std::filesystem;
  fs::path dir = fs::temp_directory_path() / ("xlfree-" + std::to_string(getpid()));
  fs::create_directories(dir);
  fs::copy_file(argv[1], dir / "disk.dd");

  // DDR3 with junk in it
  ddr.flat_base = RAM_BASE;
  ddr.flat.resize(BUF_BASE + 0x10000 - RAM_BASE);
  for (auto& w : ddr.flat) w = ((uint64_t)rand() << 33) ^ ((uint64_t)rand() << 11) ^ rand();
  sd.f[0] = fopen((dir / "disk.dd").string().c_str(), "r+b");

  top = new Vxl_machine;
  top->power_on = 1;
  top->reset = 1;
  top->rtc_back28 = 1;
  {
    time_t t = time(nullptr);
    struct tm tm;
    localtime_r(&t, &tm);
    auto bcd = [](int v) { return (uint32_t)(((v / 10) << 4) | (v % 10)); };
    top->rtc[0] = bcd(tm.tm_sec) | bcd(tm.tm_min) << 8 | bcd(tm.tm_hour) << 16 | bcd(tm.tm_mday) << 24;
    top->rtc[1] = bcd(tm.tm_mon + 1) | bcd(tm.tm_year % 100) << 8 | (uint32_t)tm.tm_wday << 16 | 0x40u << 24;
    top->rtc[2] = 1;
  }
  for (int i = 0; i < 300; i++) tick();
  top->power_on = 0;
  top->img_size = fs::file_size(dir / "disk.dd");
  top->img_readonly = 0;
  top->img_mounted = 1;
  tick();
  top->img_mounted = 0;
  for (int i = 0; i < 10; i++) tick();
  top->reset = 0;

  size_t typed = 0;
  uint64_t next_key = type_at, next_shot = (uint64_t)CLK_HZ;
  int shot = 0;
  const char* tr = getenv("XLTRACE");
  uint64_t trace_n = tr ? strtoull(tr, nullptr, 0) : 0;
  // XLTRACE_FROM=N: the trace starts at the Nth instruction
  uint64_t trace_from = getenv("XLTRACE_FROM") ? strtoull(getenv("XLTRACE_FROM"), nullptr, 0) : 0;
  // the processor's state names, from the generated enum (as sim/system/tb_system.cpp)
  std::vector<std::string> names;
  {
    std::ifstream en("../../rtl/ivory/ivory_cpu_state_enum.svh");
    for (std::string line; std::getline(en, line);)
      for (size_t k = 0; (k = line.find("S_", k)) != std::string::npos;) {
        size_t e = line.find_first_of(", \n", k);
        names.push_back(line.substr(k, e - k));
        k = e;
      }
  }
  // The instruction cache isn't kept coherent with stores (the chip's isn't):
  // report a hit in VMA=PMA space whose word differs from memory
  const int S_FETCH = (int)(std::find(names.begin(), names.end(), "S_FETCH") - names.begin());
  uint64_t stale = 0;
  // PROFILE=1: cycles by processor, MMU and memory state
  bool profile = getenv("PROFILE") != nullptr;
  // PROFILE_FROM=N: count from the Nth instruction on (a benchmark after a
  // boot); PROFILE_FROM=typed: from the last key of TEXT
  bool profile_typed = getenv("PROFILE_FROM") && !strcmp(getenv("PROFILE_FROM"), "typed");
  uint64_t profile_from = getenv("PROFILE_FROM") && !profile_typed ? strtoull(getenv("PROFILE_FROM"), nullptr, 0) : 0;
  std::vector<uint64_t> prof_cpu(1024);
  uint64_t prof_mmu[16] = {}, prof_mem[16] = {}, prof_insns0 = 0;
  // XLWATCH=va (hex, VMA=PMA space): report what happens to that instruction word
  uint32_t watch = getenv("XLWATCH") ? (uint32_t)strtoul(getenv("XLWATCH"), nullptr, 16) : 0;
  uint64_t watch_mem = watch ? ddr.at(RAM_BASE + (watch & 0x07FFFFFFu)) : 0;
  bool watch_wr = false;
  while (cycles < end) {
    tick();
    if (profile && (profile_typed ? typed >= text.size() && keys.empty()
                                  : top->rootp->xl_machine__DOT__core__DOT__cpu__DOT__icount >= profile_from)) {
      if (!prof_insns0) prof_insns0 = top->rootp->xl_machine__DOT__core__DOT__cpu__DOT__icount;
      prof_cpu[top->rootp->xl_machine__DOT__core__DOT__cpu__DOT__st]++;
      prof_mmu[top->rootp->xl_machine__DOT__core__DOT__mmu__DOT__st & 15]++;
      prof_mem[top->rootp->xl_machine__DOT__mem__DOT__st & 15]++;
    }
    if (watch) {
      auto& r = *top->rootp;
      static double t_from = getenv("XLFROM") ? atof(getenv("XLFROM")) : 0, t_to = getenv("XLTO") ? atof(getenv("XLTO")) : 0;
      double t = cycles / CLK_HZ;
      if (t >= t_from && t < t_to)
        printf("%.7f cpu st %3d mem_req %d we %d addr %08x | port_ack %d rdata %010llx | pf busy %d req %d addr %08x | mmu st %d bus req %d ack %d addr %08x | ic we %d wix %2d wd %010llx fill %d s_va %08x\n",
               t, (int)r.xl_machine__DOT__core__DOT__cpu__DOT__st, (int)r.xl_machine__DOT__core__DOT__mem_req,
               (int)r.xl_machine__DOT__core__DOT__mem_we, r.xl_machine__DOT__core__DOT__mem_addr,
               (int)r.xl_machine__DOT__core__DOT__port_ack, (unsigned long long)r.xl_machine__DOT__core__DOT__mem_rdata,
               (int)r.xl_machine__DOT__core__DOT__icache__DOT__pf_busy, (int)r.xl_machine__DOT__core__DOT__pf_req,
               r.xl_machine__DOT__core__DOT__pf_addr, (int)r.xl_machine__DOT__core__DOT__mmu__DOT__st,
               (int)r.xl_machine__DOT__core__DOT__bus_req, (int)r.xl_machine__DOT__core__DOT__bus_ack,
               r.xl_machine__DOT__core__DOT__bus_addr, 0, 0, 0ull,
               (int)r.xl_machine__DOT__core__DOT__icache__DOT__fill, r.xl_machine__DOT__core__DOT__icache__DOT__s_va);
      uint64_t m = ddr.at(RAM_BASE + (watch & 0x07FFFFFFu));
      if (m != watch_mem) {
        printf("%.6f s: memory[%08x] = %010llx\n", cycles / CLK_HZ, watch, (unsigned long long)m);
        watch_mem = m;
      }
      bool wr = r.xl_machine__DOT__core__DOT__mem_req && r.xl_machine__DOT__core__DOT__mem_we &&
                (r.xl_machine__DOT__core__DOT__mem_phys ? (r.xl_machine__DOT__core__DOT__mem_addr | 0xF8000000u) == watch
                                                        : r.xl_machine__DOT__core__DOT__mem_addr == watch);
      if (wr && !watch_wr)
        printf("%.6f s: processor writes %08x (phys %d)\n", cycles / CLK_HZ, watch, (int)r.xl_machine__DOT__core__DOT__mem_phys);
      watch_wr = wr;
      {
        static uint64_t last_d = ~0ull; static uint32_t last_t = ~0u; static int last_v = -1;
        uint64_t d = r.xl_machine__DOT__core__DOT__icache__DOT__data_a[watch & 31];
        uint32_t t = r.xl_machine__DOT__core__DOT__icache__DOT__tag[watch & 31];
        int v = (r.xl_machine__DOT__core__DOT__icache__DOT__valid >> (watch & 31)) & 1;
        if (d != last_d || t != last_t || v != last_v) {
          if (cycles / CLK_HZ > 0.58)
            printf("%.6f s: slot %d tag %08x valid %d data %010llx  (fill %d pend %d pf_busy %d s_va %08x s_pa %08x)\n",
                   cycles / CLK_HZ, (int)(watch & 31), t << 5, v, (unsigned long long)d,
                   (int)r.xl_machine__DOT__core__DOT__icache__DOT__fill, (int)r.xl_machine__DOT__core__DOT__icache__DOT__pend,
                   (int)r.xl_machine__DOT__core__DOT__icache__DOT__pf_busy, r.xl_machine__DOT__core__DOT__icache__DOT__s_va,
                   r.xl_machine__DOT__core__DOT__icache__DOT__s_pa);
          last_d = d; last_t = t; last_v = v;
        }
      }
      if (r.xl_machine__DOT__core__DOT__cpu__DOT__st == S_FETCH && (uint32_t)(r.xl_machine__DOT__core__DOT__cpu__DOT__pc >> 1) == watch)
        printf("%.6f s: fetch %08x hit %d valid %d\n", cycles / CLK_HZ, watch,
               (int)r.xl_machine__DOT__core__DOT__icache__DOT__hit, (int)((r.xl_machine__DOT__core__DOT__icache__DOT__valid >> (watch & 31)) & 1));
    }
    if (top->rootp->xl_machine__DOT__core__DOT__cpu__DOT__st == S_FETCH &&
        top->rootp->xl_machine__DOT__core__DOT__icache__DOT__hit) {
      uint32_t va = (uint32_t)(top->rootp->xl_machine__DOT__core__DOT__cpu__DOT__pc >> 1);
      if (va >= 0xF8000000u && (va & 0x07FFFFFFu) < 0x400000u) {
        uint64_t mem = ddr.at(RAM_BASE + (va & 0x07FFFFFFu)) & 0xFFFFFFFFFFull;
        uint64_t got = top->rootp->xl_machine__DOT__core__DOT__icache__DOT__word;
        if (mem != got && stale++ < 10) {
          printf("stale instruction cache hit at %08x: cache %010llx memory %010llx (%.3f s)\n", va,
                 (unsigned long long)got, (unsigned long long)mem, cycles / CLK_HZ);
          if (stale == 1)
            for (int k = -4; k <= 3; k++)
              printf("  memory[%08x] = %010llx\n", va + k,
                     (unsigned long long)(ddr.at(RAM_BASE + ((va + k) & 0x07FFFFFFu)) & 0xFFFFFFFFFFull));
        }
      }
    }
    if (trace_n && top->retire && top->rootp->xl_machine__DOT__core__DOT__cpu__DOT__icount >= trace_from) {
      trace_n--;
      printf("%10llu  pc %08x.%d  sp %08x\n", (unsigned long long)cycles,
             (uint32_t)(top->rootp->xl_machine__DOT__core__DOT__cpu__DOT__pc >> 1),
             (int)(top->rootp->xl_machine__DOT__core__DOT__cpu__DOT__pc & 1), top->rootp->xl_machine__DOT__core__DOT__cpu__DOT__sp);
    }
    if (top->halted) {
      printf("halted (code %d) after %.3f s\n", top->halt_reason, cycles / CLK_HZ);
      if (getenv("XLTRACE"))
        printf("ddr[RAM+800c..f] = %010llx %010llx %010llx %010llx, wleft %d\n",
               (unsigned long long)ddr.at(RAM_BASE + 0x800c), (unsigned long long)ddr.at(RAM_BASE + 0x800d),
               (unsigned long long)ddr.at(RAM_BASE + 0x800e), (unsigned long long)ddr.at(RAM_BASE + 0x800f), ddr.wleft);
      break;
    }
    if (cycles >= next_key && typed < text.size()) {
      char c = text[typed] == '|' ? '\r' : text[typed];
      uint8_t k;
      bool shift;
      if (c == '~') next_key = cycles + 10 * (uint64_t)CLK_HZ;
      else {
        if (ascii_to_key(c, k, shift)) {
          if (shift) keys.emplace_back(true, K_LEFT_SHIFT);
          keys.emplace_back(true, k);
          keys.emplace_back(false, k);
          if (shift) keys.emplace_back(false, K_LEFT_SHIFT);
        }
        next_key = cycles + (c == '\r' ? 3 * (uint64_t)CLK_HZ : (uint64_t)(CLK_HZ / 20));
      }
      typed++;
    }
    if (cycles >= next_shot) {
      next_shot += (uint64_t)CLK_HZ;
      shot++;
      printf("%d s: %llu instructions, memory %s\n", shot, (unsigned long long)top->insn_count,
             top->rootp->xl_machine__DOT__mem_ready ? "ready" : "clearing");
      fflush(stdout);
      save_screen(screen.c_str());
    }
  }
  save_screen(screen.c_str());
  if (profile) {
    uint64_t total = 0;
    for (auto v : prof_cpu) total += v;
    std::vector<std::pair<uint64_t, int>> tops;
    for (size_t k = 0; k < prof_cpu.size(); k++) if (prof_cpu[k]) tops.emplace_back(prof_cpu[k], (int)k);
    std::sort(tops.rbegin(), tops.rend());
    uint64_t insns = top->rootp->xl_machine__DOT__core__DOT__cpu__DOT__icount - (prof_insns0 ? prof_insns0 - 1 : 0);
    printf("profile: %llu cycles, %llu instructions, %.2f cycles/instruction\n", (unsigned long long)total,
           (unsigned long long)insns, (double)total / insns);
    for (size_t k = 0; k < tops.size() && k < 30; k++)
      printf("  cpu %-18s %5.1f%%\n", tops[k].second < (int)names.size() ? names[tops[k].second].c_str() : "?",
             100.0 * tops[k].first / total);
    const char* mmu_names[] = {"IDLE", "W0", "W1", "AGE", "FILL", "HIT", "N1", "N2", "ACCESS", "?", "?", "?", "?", "?", "?", "?"};
    const char* mem_names[] = {"CLEAR", "IDLE", "MISS", "FILL", "BUF_RD", "BUF_WAIT", "BUF_WR", "?", "?", "?", "?", "?", "?", "?", "?", "?"};
    for (int k = 0; k < 16; k++) if (prof_mmu[k]) printf("  mmu %-8s %5.1f%%\n", mmu_names[k], 100.0 * prof_mmu[k] / total);
    for (int k = 0; k < 16; k++) if (prof_mem[k]) printf("  mem %-8s %5.1f%%\n", mem_names[k], 100.0 * prof_mem[k] / total);
  }
  printf("%.2f s simulated, %llu instructions; screen in %s\n", cycles / CLK_HZ, (unsigned long long)top->insn_count,
         screen.c_str());
  printf("machine clock %u us, the bench's %.0f\n", (unsigned)top->rootp->xl_machine__DOT__usec, cycles / CLK_HZ * 1e6);
  delete top;
  fs::remove_all(dir);
  return 0;
}
