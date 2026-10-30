// xlemu: Symbolics XL1200 reference emulator.
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <string>
#include <vector>
#include "machine.h"
#include "keyboard.h"

// Print the control stack: each frame's PC and its first few arguments.
static void backtrace(Ivory& cpu, Bus& m) {
  auto rd = [&](uint32_t vma) { return cpu.debug_read(vma); };
  uint32_t fp = cpu.fp, cr = cpu.cr, sp = cpu.sp;
  W pc = mkw(cpu.pc & 1 ? DTP_ODD_PC : DTP_EVEN_PC, (uint32_t)(cpu.pc >> 1)), ret = cpu.cont;
  for (int depth = 0; depth < 60 && fp > 0xF8000101u && fp != 0xF8000100u; depth++) {
    fprintf(stderr, "  #%-2d %08x", depth, wdata(pc));
    uint32_t nargs = cr & CR_ARG_SIZE_MASK;
    for (uint32_t i = 2; i < nargs && i < 8 && fp + i <= sp; i++) {
      W a = rd(fp + i);
      fprintf(stderr, " %02o:%08x", wtype(a), wdata(a));
    }
    fputc('\n', stderr);
    pc = ret;
    ret = rd(fp);
    uint32_t ncr = wdata(rd(fp + 1));
    sp = fp - 1;
    fp -= (cr >> CR_CALLER_FRAME_SIZE_SHIFT) & 0xFF;
    cr = ncr;
  }
}

// One {...} escape in scripted console input; returns instructions to wait.
//   m DX DY    move the mouse          b [L][M][R]  set the mouse buttons
//   k NAME     tap a special key       w N          wait N million instructions
static uint64_t console_script(Console& console, const std::string& cmd) {
  static const struct { const char* name; uint8_t key; } keys[] = {
      {"Select", K_SELECT}, {"Function", K_FUNCTION}, {"Help", K_HELP}, {"Abort", K_ABORT},
      {"Suspend", K_SUSPEND}, {"Resume", K_RESUME}, {"Return", K_RETURN}, {"End", K_END},
      {"Escape", K_ESCAPE}, {"Refresh", K_REFRESH}, {"Rubout", K_RUBOUT}, {"Complete", K_COMPLETE},
      {"Line", K_LINE}, {"Page", K_PAGE}, {"Tab", K_TAB}, {"Clear", K_CLEAR_INPUT},
  };
  char op = cmd.empty() ? 0 : cmd[0];
  std::string arg = cmd.size() > 1 ? cmd.substr(2) : "";
  switch (op) {
  case 'm': {
    int dx = 0, dy = 0;
    sscanf(arg.c_str(), "%d %d", &dx, &dy);
    console.mouse_move(dx, dy);
    return 2000000;
  }
  case 'b':
    console.mouse_buttons(arg.find('L') != std::string::npos, arg.find('M') != std::string::npos,
                          arg.find('R') != std::string::npos);
    return 2000000;
  case 'k':
    for (auto& k : keys)
      if (arg == k.name) { console.key(k.key, true); console.key(k.key, false); }
    return 2000000;
  case 'w':
    return strtoull(arg.c_str(), nullptr, 0) * 1000000;
  default:
    fprintf(stderr, "unknown console script command {%s}\n", cmd.c_str());
    return 0;
  }
}

static void usage() {
  fprintf(stderr, "usage: xlemu [-t tracefile] [-n insns] [-P prom.mem | -k kernel.fep] [-d disk.dd]\n");
  exit(1);
}

int main(int argc, char** argv) {
  // Boot from reset through the boot PROM stand-in (tools/bootprom.py), which
  // loads the FEP kernel from the disk; -k loads a kernel file directly instead.
  std::string prom = "../rtl/xl/boot_prom.mem";
  std::string kernel;
  const char* tracefile = nullptr;
  const char* dumpfile = nullptr;
  const char* progfile = nullptr;
  const char* videofile = nullptr;   // write video memory as a PGM image at exit
  // The FEP disk: a working copy, made from the original the first time, so
  // nothing the emulated machine writes reaches the original image.
  std::string disk0 = "../research/media/disks/fepfs-lmfs-kernel.dd";
  const std::string disk0_original = "/Users/jacob/Downloads/Symbolics-XL1200-ROMs-and-Disks/disks/fepfs-lmfs-kernel.dd";
  uint64_t stop_hpc = (uint64_t)0xFFFE0040u << 1;   // halfword PC
  uint64_t limit = 10000000;
  uint32_t disk_stride = 1536;   // SCSI2SD card layout; 1280 for packed block images
  std::vector<uint64_t> bt_pcs;   // word PCs at which to print a backtrace
  uint64_t trace_from = 0;        // with -t, start tracing at this instruction count
  const char* typed = nullptr;    // text to type on the console once the FEP is up
  uint64_t type_at = 20000000;    // first keystroke
  uint64_t type_gap = 60000000;   // pause after each Return ('|' in the text)
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "-t") && i + 1 < argc) tracefile = argv[++i];
    else if (!strcmp(argv[i], "-n") && i + 1 < argc) limit = strtoull(argv[++i], nullptr, 0);
    else if (!strcmp(argv[i], "-k") && i + 1 < argc) kernel = argv[++i];
    else if (!strcmp(argv[i], "-P") && i + 1 < argc) prom = argv[++i];
    else if (!strcmp(argv[i], "-D") && i + 1 < argc) dumpfile = argv[++i];
    else if (!strcmp(argv[i], "-p") && i + 1 < argc) progfile = argv[++i];
    else if (!strcmp(argv[i], "-d") && i + 1 < argc) disk0 = argv[++i];
    else if (!strcmp(argv[i], "-V") && i + 1 < argc) videofile = argv[++i];
    else if (!strcmp(argv[i], "-x") && i + 1 < argc) stop_hpc = strtoull(argv[++i], nullptr, 0);
    else if (!strcmp(argv[i], "-Ts") && i + 1 < argc) trace_from = strtoull(argv[++i], nullptr, 0);
    else if (!strcmp(argv[i], "-S") && i + 1 < argc) disk_stride = strtoul(argv[++i], nullptr, 0);
    else if (!strcmp(argv[i], "-K") && i + 1 < argc) typed = argv[++i];
    else if (!strcmp(argv[i], "-Kat") && i + 1 < argc) type_at = strtoull(argv[++i], nullptr, 0);
    else if (!strcmp(argv[i], "-Kgap") && i + 1 < argc) type_gap = strtoull(argv[++i], nullptr, 0);
    else if (!strcmp(argv[i], "-b") && i + 1 < argc) bt_pcs.push_back(strtoull(argv[++i], nullptr, 16));
    else usage();
  }

  Machine m(4u << 20);   // 4 MW, like the reference XL1201
  // The calendar clock runs 28 years behind (same weekdays), as the core does
  // by default: Genera 8.3 doesn't accept a two-digit year past 1999.
  if (!getenv("XLEMU_CLOCK_TODAY"))
    m.nvram.set_time_source([] {
      time_t t = time(nullptr);
      struct tm tm;
      gmtime_r(&t, &tm);
      tm.tm_year -= 28;
      return timegm(&tm);
    });
  Ivory cpu(&m);
  if (progfile) {
    // Unit-test mode: load a program into VMA=PMA memory and run it in FEP mode
    // from its first word until the PC reaches the stop address.
    FILE* f = fopen(progfile, "r");
    if (!f) { perror(progfile); return 1; }
    unsigned vma, tag, data, first = 0;
    bool have_first = false;
    while (fscanf(f, "%x %x %x", &vma, &tag, &data) == 3) {
      m.phys_write(vma - VMA_PMA_BASE, mktag(tag, data));
      if (!have_first) { first = vma; have_first = true; }
    }
    fclose(f);
    cpu.init();
    cpu.pc = (uint64_t)first << 1;
    cpu.sp = 0xF8001000u;
    cpu.fp = cpu.sp + 1;
    cpu.lp = cpu.fp + 2;
    cpu.control_stack_limit = mkw(DTP_LOCATIVE, 0xF8003000u);
    cpu.control_stack_extra_limit = mkw(DTP_LOCATIVE, 0xF8003800u);
    uint64_t n = 0;
    try {
      while (n++ < limit && cpu.pc != stop_hpc) cpu.step();
    } catch (ProcessorHalt& h) {
      printf("HALT %s\n", h.why.c_str());
    }
    printf("PC %08x.%d SP %08x FP %08x LP %08x CR %08x N %llu\n", (uint32_t)(cpu.pc >> 1),
           (int)(cpu.pc & 1), cpu.sp, cpu.fp, cpu.lp, cpu.cr, (unsigned long long)cpu.icount);
    for (uint32_t a = 0xF8001001u; a <= cpu.sp && a < 0xF8001100u; a++) {
      W w = m.phys_read(a - VMA_PMA_BASE);
      printf("S %08x %03o %08x\n", a, wtag(w), wdata(w));
    }
    return 0;
  }
  if (disk0 == "../research/media/disks/fepfs-lmfs-kernel.dd" && !std::filesystem::exists(disk0)) {
    std::filesystem::create_directories(std::filesystem::path(disk0).parent_path());
    std::filesystem::copy_file(disk0_original, disk0);
  }
  m.attach_disk(0, disk0, 1280, disk_stride);
  cpu.log_errors = getenv("XLEMU_ERRLOG") != nullptr;
  m.fpa_fitted = getenv("XLEMU_NO_FPA") == nullptr;
  m.iob.scsi.trace = getenv("SCSI_TRACE") ? atoi(getenv("SCSI_TRACE")) : 0;
  m.iob.ether.trace = getenv("ETHER_TRACE") != nullptr;

  if (!kernel.empty()) {
    m.load_fep_file(kernel);
    m.boot_fep(cpu);
  } else {
    m.load_prom(prom);
    cpu.init();
  }

  if (tracefile) {
    cpu.tracef = fopen(tracefile, "w");
    cpu.trace = trace_from == 0;
  }
  bool in_fep = false;
  try {
    while (cpu.icount < limit && !cpu.halted) {
      cpu.step();
      m.tick(1);
      if (cpu.tracef && !cpu.trace && cpu.icount >= trace_from) cpu.trace = true;
      if (typed && *typed && cpu.icount >= type_at) {
        // One key every 200k instructions; '|' types Return and then waits;
        // {...} is a console_script escape (mouse, buttons, special keys).
        uint64_t wait = 200000;
        if (*typed == '{') {
          const char* end = strchr(typed, '}');
          std::string cmd(typed + 1, end ? end - typed - 1 : strlen(typed + 1));
          wait = console_script(m.iob.console, cmd);
          typed = end ? end + 1 : typed + strlen(typed);
        } else {
          char c[2] = {*typed == '|' ? '\r' : *typed, 0};
          m.iob.console.type(c);
          if (*typed == '|') wait = type_gap;
          typed++;
        }
        type_at = cpu.icount + wait;
      }
      for (uint64_t b : bt_pcs)
        if ((cpu.pc >> 1) == b) {
          fprintf(stderr, "backtrace at %08x (insn %llu):\n", (uint32_t)b, (unsigned long long)cpu.icount);
          backtrace(cpu, m);
        }
      // Back at the PROM entry once the FEP has run: the FEP returned to it
      uint32_t wpc = (uint32_t)(cpu.pc >> 1);
      if (wpc < 0xFFFE0000u) in_fep = true;
      else if (in_fep && wpc == 0xFFFE0040u) {
        fprintf(stderr, "returned to boot PROM\n");
        break;
      }
    }
  } catch (ProcessorHalt& h) {
    fprintf(stderr, "HALT: %s\n", h.why.c_str());
  }
  fprintf(stderr, "stopped after %llu instructions at pc=%08x.%d sp=%08x fp=%08x traps=%llu last_trap=%o\n",
          (unsigned long long)cpu.icount, (uint32_t)(cpu.pc >> 1), (int)(cpu.pc & 1), cpu.sp, cpu.fp,
          (unsigned long long)cpu.trap_count, cpu.last_trap_vector);
  fprintf(stderr, "FPA %s, %llu operations\n", (cpu.fp_coprocessor_present & 1) ? "enabled" : "disabled",
          (unsigned long long)m.fpa.operations);
  if (getenv("XLEMU_BT")) backtrace(cpu, m);
  if (cpu.tracef) fclose(cpu.tracef);
  if (videofile) {
    // Video memory is 2048 x 1024 x 1 bit; bit 0 of each word is the leftmost pixel.
    FILE* f = fopen(videofile, "wb");
    fprintf(f, "P5\n%u %u\n255\n", IoBoard::VIDEO_WIDTH, IoBoard::VIDEO_HEIGHT);
    for (uint32_t y = 0; y < IoBoard::VIDEO_HEIGHT; y++)
      for (uint32_t x = 0; x < IoBoard::VIDEO_WIDTH; x++) {
        uint32_t wd = m.iob.video[(y * IoBoard::VIDEO_WIDTH + x) / 32];
        fputc(((wd >> (x & 31)) & 1) ? 255 : 0, f);
      }
    fclose(f);
  }
  if (const char* syncfile = getenv("XLEMU_SYNC")) {
    // The video sync program the FEP loaded (I/O board 0x0402D000), one word per line
    FILE* f = fopen(syncfile, "w");
    fprintf(f, "# video control %08x, sync address %u\n", m.iob.video_control, m.iob.sync_address);
    for (size_t i = 0; i < m.iob.sync_program.size(); i++) fprintf(f, "%04zx %08x\n", i, m.iob.sync_program[i]);
    fclose(f);
  }
  if (dumpfile) {
    // Dump physical memory as 64-bit words.
    FILE* f = fopen(dumpfile, "wb");
    fwrite(m.ram.data(), sizeof(W), m.ram.size(), f);
    fclose(f);
  }
  return 0;
}
