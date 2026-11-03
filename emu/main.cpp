// xlemu: Symbolics XL1200 reference emulator.
#include <csignal>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <string>
#include <vector>
#include "machine.h"
#include "snapshot.h"
#include "keyboard.h"

// A string array's characters (art-string, short prefix), or "".
static std::string lisp_string(Ivory& cpu, uint32_t a) {
  W h = cpu.debug_read(a);
  uint32_t d = wdata(h);
  if (wtype(h) != DTP_HEADER_I || ((d >> 23) & 1) || (((d >> 26) & 077) != 025 && ((d >> 26) & 077) != 024))
    return "";
  std::string s;
  for (uint32_t i = 0; i < (d & 0x7FFF) && i < 100; i++)
    s += (char)((wdata(cpu.debug_read(a + 1 + i / 4)) >> (8 * (i % 4))) & 0xFF);
  return s;
}

// The name of the compiled function holding word PC (its header, then the
// name in its debugging info), or "".
static std::string function_name(Ivory& cpu, uint32_t pc) {
  for (uint32_t back = 0; back < 0x4000; back++) {
    W h = cpu.debug_read(pc - back);
    if (wtype(h) != DTP_HEADER_I || wcdr(h) != 0) continue;
    uint32_t total = wdata(h) & 0x3FFFF, suffix = (wdata(h) >> 18) & 0x3FFF;
    if (total <= back || suffix >= total) return "";
    W n = cpu.debug_read(pc - back + total - suffix);
    if (wtype(n) == DTP_LIST) n = cpu.debug_read(wdata(n));
    if (wtype(n) == DTP_LIST) n = cpu.debug_read(wdata(n) + 1);   // (:internal f n) etc.: the next element
    if (wtype(n) != DTP_SYMBOL) return "";
    return lisp_string(cpu, wdata(cpu.debug_read(wdata(n))));
  }
  return "";
}

// Print the control stack: each frame's PC, function and first few arguments.
static void backtrace(Ivory& cpu, Bus& m) {
  auto rd = [&](uint32_t vma) { return cpu.debug_read(vma); };
  uint32_t fp = cpu.fp, cr = cpu.cr, sp = cpu.sp;
  W pc = mkw(cpu.pc & 1 ? DTP_ODD_PC : DTP_EVEN_PC, (uint32_t)(cpu.pc >> 1)), ret = cpu.cont;
  for (int depth = 0; depth < 60 && fp > 0x1000u && fp != 0xF8000100u; depth++) {
    fprintf(stderr, "  #%-2d %08x %-40s", depth, wdata(pc), function_name(cpu, wdata(pc)).c_str());
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
    if (((cr >> CR_CALLER_FRAME_SIZE_SHIFT) & 0xFF) == 0) break;
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
  fprintf(stderr, "usage: xlemu [-t tracefile] [-n insns] [-P prom.mem | -k kernel.fep] [-d disk.dd]\n"
                  "             [-W snapshot] (write the machine's state when the run stops, and disk.dd to snapshot.disk)\n"
                  "             [-R snapshot] (resume from it; -d must be a copy of its .disk; -Kat counts from the resume)\n");
  exit(1);
}

const char* ivory_opcode_name(int op);   // emu/cpu_insn.cpp

// SIGUSR1 stops the run as its limit would (the screen and the -W snapshot
// are written), so a run that waits at a prompt can be resumed with input.
static volatile sig_atomic_t stop_requested = 0;
static void on_sigusr1(int) { stop_requested = 1; }

// The screen as a PGM: video memory is 2048 x 1024 x 1 bit, bit 0 of each word
// the leftmost pixel.  Written to a temporary name and renamed, so a reader
// never sees half a picture.
static void write_screen(Machine& m, const char* path) {
  std::string tmp = std::string(path) + ".tmp";
  FILE* f = fopen(tmp.c_str(), "wb");
  if (!f) return;
  fprintf(f, "P5\n%u %u\n255\n", IoBoard::VIDEO_WIDTH, IoBoard::VIDEO_HEIGHT);
  for (uint32_t y = 0; y < IoBoard::VIDEO_HEIGHT; y++)
    for (uint32_t x = 0; x < IoBoard::VIDEO_WIDTH; x++) {
      uint32_t wd = m.iob.video[(y * IoBoard::VIDEO_WIDTH + x) / 32];
      fputc(((wd >> (x & 31)) & 1) ? 255 : 0, f);
    }
  fclose(f);
  rename(tmp.c_str(), path);
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
  const char* snap_write = nullptr;  // -W: the snapshot to write when the run stops
  const char* snap_read = nullptr;   // -R: the snapshot to resume from
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
    else if (!strcmp(argv[i], "-W") && i + 1 < argc) snap_write = argv[++i];
    else if (!strcmp(argv[i], "-R") && i + 1 < argc) snap_read = argv[++i];
    else if (!strcmp(argv[i], "-x") && i + 1 < argc) stop_hpc = strtoull(argv[++i], nullptr, 0);
    else if (!strcmp(argv[i], "-Ts") && i + 1 < argc) trace_from = strtoull(argv[++i], nullptr, 0);
    else if (!strcmp(argv[i], "-S") && i + 1 < argc) disk_stride = strtoul(argv[++i], nullptr, 0);
    else if (!strcmp(argv[i], "-K") && i + 1 < argc) typed = argv[++i];
    else if (!strcmp(argv[i], "-Kat") && i + 1 < argc) type_at = strtoull(argv[++i], nullptr, 0);
    else if (!strcmp(argv[i], "-Kgap") && i + 1 < argc) type_gap = strtoull(argv[++i], nullptr, 0);
    else if (!strcmp(argv[i], "-b") && i + 1 < argc) bt_pcs.push_back(strtoull(argv[++i], nullptr, 16));
    else usage();
  }

  Machine m(16u << 20);  // 16 MW, the XL1200's most
  // The calendar clock runs 28 years behind (same weekdays), as the core does
  // by default: Genera 8.3 doesn't accept a two-digit year past 1999.
  // XLEMU_EPOCH=N: the calendar clock starts at Unix time N and runs on the
  // machine's own cycles, so two runs execute the same instructions (a
  // reproducible instruction count for traces).
  if (const char* ep = getenv("XLEMU_EPOCH")) {
    time_t epoch = (time_t)strtoull(ep, nullptr, 0);
    m.nvram.set_time_source([epoch, &m] { return epoch + (time_t)(m.microsecond_clock() / 1000000u); });
  } else if (!getenv("XLEMU_CLOCK_TODAY"))
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
  // XLEMU_STOP_ON=TEXT: stop 50M instructions after the disk is written with
  // TEXT (build it at run time in the typed form, so the typed text itself
  // can't be paged out and trip it)
  if (const char* so = getenv("XLEMU_STOP_ON")) m.iob.scsi.targets[0].watch = so;
  uint64_t stop_at = 0;
  signal(SIGUSR1, on_sigusr1);
  // XLEMU_SHOT_EVERY=N: rewrite the -V screen every N million instructions,
  // to watch a long run from outside
  uint64_t shot_every = getenv("XLEMU_SHOT_EVERY") ? strtoull(getenv("XLEMU_SHOT_EVERY"), nullptr, 0) * 1000000 : 0;
  cpu.log_errors = getenv("XLEMU_ERRLOG") != nullptr;
  if (const char* wv = getenv("XLEMU_WATCH")) { cpu.watch_vma = (uint32_t)strtoul(wv, nullptr, 16); cpu.watch_on = true; }
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
  if (getenv("XLEMU_MAPCHECK")) cpu.map_check = true;
  if (const char* v = getenv("XLEMU_PHTVMA")) { cpu.pht_vma = strtoul(v, nullptr, 16); cpu.pht_vma_on = true; }
  if (snap_read) {
    if (!Snapshot::load(snap_read, cpu, m)) return 1;
    fprintf(stderr, "resumed from %s at instruction %llu\n", snap_read, (unsigned long long)cpu.icount);
    type_at += cpu.icount;   // -Kat counts from here
  }

  if (tracefile) {
    cpu.tracef = fopen(tracefile, "w");
    cpu.trace = trace_from == 0;
  }
  bool in_fep = false;
  const bool progress = getenv("XLEMU_PROGRESS") != nullptr;
  try {
    while (cpu.icount < limit && !cpu.halted) {
      cpu.step();
      m.tick(1);
      if (progress && cpu.icount % 1000000000 == 0)
        fprintf(stderr, "[progress] %llu instructions\n", (unsigned long long)cpu.icount);
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
          if (*typed == '|') {
            wait = type_gap;
            // XLEMU_OPSTATS: the opcode histogram covers the last command typed
            if (getenv("XLEMU_OPSTATS")) {
              cpu.opstats_clear();
              fprintf(stderr, "[opstats] cleared at instruction %llu\n", (unsigned long long)cpu.icount);
            }
          }
          typed++;
        }
        type_at = cpu.icount + wait;
      }
      if (m.iob.scsi.targets[0].watch_seen && !stop_at) {
        stop_at = cpu.icount + 50000000;
        fprintf(stderr, "stop marker written at instruction %llu\n", (unsigned long long)cpu.icount);
      }
      if (stop_at && cpu.icount >= stop_at) break;
      if (stop_requested) { fprintf(stderr, "stopped on request\n"); break; }
      if (shot_every && videofile && cpu.icount % shot_every == 0) write_screen(m, videofile);
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
  if (getenv("XLEMU_OPSTATS")) {
    std::vector<std::pair<uint64_t, int>> v;
    uint64_t total = 0;
    for (int i = 0; i < 258; i++) { v.emplace_back(cpu.opstats[i], i); total += cpu.opstats[i]; }
    std::sort(v.rbegin(), v.rend());
    fprintf(stderr, "[opstats] %llu instructions since the last Return\n", (unsigned long long)total);
    for (int i = 0; i < 40 && v[i].first; i++)
      fprintf(stderr, "[opstats] %6.2f%%  %s\n", 100.0 * v[i].first / total,
              v[i].second == 256 ? "full-word" : v[i].second == 257 ? "entry" : ivory_opcode_name(v[i].second));
  }
  if (cpu.tracef) fclose(cpu.tracef);
  if (videofile) write_screen(m, videofile);
  if (const char* syncfile = getenv("XLEMU_SYNC")) {
    // The video sync program the FEP loaded (I/O board 0x0402D000), one word per line
    FILE* f = fopen(syncfile, "w");
    fprintf(f, "# video control %08x, sync address %u\n", m.iob.video_control, m.iob.sync_address);
    for (size_t i = 0; i < m.iob.sync_program.size(); i++) fprintf(f, "%04zx %08x\n", i, m.iob.sync_program[i]);
    fclose(f);
  }
  if (cpu.pht_vma_on) cpu.pht_report("end");
  if (snap_write) {
    if (Snapshot::save(snap_write, cpu, m)) {
      std::error_code ec;
      std::filesystem::copy_file(disk0, std::string(snap_write) + ".disk", std::filesystem::copy_options::overwrite_existing, ec);
      fprintf(stderr, "snapshot %s at instruction %llu%s\n", snap_write, (unsigned long long)cpu.icount,
              ec ? " (disk copy failed)" : " with its disk");
    }
  }
  if (dumpfile) {
    // Dump physical memory as 64-bit words.
    FILE* f = fopen(dumpfile, "wb");
    fwrite(m.ram.data(), sizeof(W), m.ram.size(), f);
    fclose(f);
  }
  return 0;
}
