// The RTL XL1200 as it runs on the MiSTer: device time in microseconds of the
// 50 MHz clock, SCSI commands running while the processor polls, memory
// cleared at power-up (DDR3 starts with junk), the display clock running.
// No reference model; it prints what the console shows by saving the screen.
//   ./obj_free/Vxl_machine DISK.dd SECONDS [AT-SECONDS TEXT] [SCREEN.pgm]
// TEXT is typed from AT-SECONDS of simulated time ('|' is Return, a key
// every 50 ms, 3 s after a Return); the screen (the 1152 x 880 raster from
// video memory) is saved every simulated second and at the end.
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
static uint64_t cycles = 0;            // 50 MHz cycles
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
  uint64_t end = (uint64_t)(atof(argv[2]) * 50e6);
  uint64_t type_at = argc > 4 ? (uint64_t)(atof(argv[3]) * 50e6) : ~0ull;
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
  uint64_t next_key = type_at, next_shot = 50000000;
  int shot = 0;
  const char* tr = getenv("XLTRACE");
  uint64_t trace_n = tr ? strtoull(tr, nullptr, 0) : 0;
  while (cycles < end) {
    tick();
    if (trace_n && top->retire) {
      trace_n--;
      printf("%10llu  pc %08x.%d  sp %08x\n", (unsigned long long)cycles,
             (uint32_t)(top->rootp->xl_machine__DOT__cpu__DOT__pc >> 1),
             (int)(top->rootp->xl_machine__DOT__cpu__DOT__pc & 1), top->rootp->xl_machine__DOT__cpu__DOT__sp);
    }
    if (top->halted) {
      printf("halted (code %d) after %.3f s\n", top->halt_reason, cycles / 50e6);
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
      if (ascii_to_key(c, k, shift)) {
        if (shift) keys.emplace_back(true, K_LEFT_SHIFT);
        keys.emplace_back(true, k);
        keys.emplace_back(false, k);
        if (shift) keys.emplace_back(false, K_LEFT_SHIFT);
      }
      next_key = cycles + (text[typed] == '|' ? 150000000 : 2500000);
      typed++;
    }
    if (cycles >= next_shot) {
      next_shot += 50000000;
      shot++;
      printf("%d s: %llu instructions, memory %s\n", shot, (unsigned long long)top->insn_count,
             top->rootp->xl_machine__DOT__mem_ready ? "ready" : "clearing");
      fflush(stdout);
      save_screen(screen.c_str());
    }
  }
  save_screen(screen.c_str());
  printf("%.2f s simulated, %llu instructions; screen in %s\n", cycles / 50e6, (unsigned long long)top->insn_count,
         screen.c_str());
  delete top;
  fs::remove_all(dir);
  return 0;
}
