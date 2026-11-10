// The WD33C93 and its targets in rtl/xl/xl_scsi.sv, driven as Genera's driver
// (SYS:I-SYS;MERLIN-SCSI-HARDWARE) drives them: a Select-and-Transfer with the
// CDB and a transfer count, the interrupt, the Command Phase and status
// registers read, a resume from phase 0x45 when the count ran out.  The images
// are generated: every byte of every block is a function of its place.
//   - the CD-ROM drive at target 2: INQUIRY, UNIT ATTENTION after a reset and
//     for a new disc, NOT READY with no disc, READ CAPACITY, MODE SENSE, reads
//     past the end and writes refused
//   - a 64 KB read through a 32 KB count (status 0x49, phase 0x46, the count
//     registers at zero, then phase 0x45), counts that run out mid-block and
//     twice, a resume at a phase that expects no data, a short data phase
//   - the chip's reset pin and its Reset command while a target waits
//   - a disk: reads across the 10-block window, a write split by the count
//     (status 0x48) and read back, a write to a read-only image
// Exit status 0 when everything matches.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <vector>
#include "Vxl_scsi.h"
#include "sd_model.h"

static Vxl_scsi* top;
static SdModel<Vxl_scsi> sd;
static uint64_t ticks = 0;
static int failures = 0, checks = 0;
static std::mt19937 rng(1);

// The board's DMA port: bytes the chip writes (data in) and reads (data out)
static std::vector<uint8_t> dma_in, dma_out;
static size_t dma_out_pos = 0;
static int dma_wait = 0;

static void tick() {
  top->clk = 0;
  top->eval();
  top->dma_ack = 0;
  if (top->dma_req) {
    if (dma_wait == 0) {
      top->dma_ack = 1;
      if (top->dma_we) dma_in.push_back(top->dma_wdata);
      else top->dma_rdata = dma_out_pos < dma_out.size() ? dma_out[dma_out_pos++] : 0xEE;
      dma_wait = (int)(rng() % 3);
    } else dma_wait--;
  }
  sd.step(top);
  top->eval();
  top->clk = 1;
  top->eval();
  ticks++;
}

static void check(bool ok, const char* what, long got = 0, long want = 0) {
  checks++;
  if (ok) return;
  failures++;
  printf("FAIL %s (got 0x%lx, expected 0x%lx)\n", what, got, want);
}
static void expect(long got, long want, const char* what) { check(got == want, what, got, want); }
#define EXPECT(got, want, what) expect((long)(got), (long)(want), what)

// One register access: taken in the cycle it is accepted, acknowledged in the next
static uint8_t reg(uint8_t addr, bool we, uint8_t v = 0) {
  top->reg_req = 1; top->reg_we = we; top->reg_addr = addr; top->reg_wdata = v;
  int n = 0;
  do { tick(); } while (!top->reg_ack && ++n < 100000);
  uint8_t r = top->reg_rdata;
  tick();
  top->reg_req = 0; top->reg_we = 0;
  return r;
}
static uint8_t rd(uint8_t a) { return reg(a, false); }
static void wr(uint8_t a, uint8_t v) { reg(a, true, v); }

enum { R_CDB1 = 0x03, R_LUN = 0x0F, R_PHASE = 0x10, R_CNT = 0x12, R_DEST = 0x15, R_STATUS = 0x17, R_CMD = 0x18, R_ASR = 0x1F };

static uint32_t count_regs() { return (rd(R_CNT) << 16) | (rd(R_CNT + 1) << 8) | rd(R_CNT + 2); }
static void set_count(uint32_t n) { wr(R_CNT, n >> 16); wr(R_CNT + 1, n >> 8); wr(R_CNT + 2, n); }

// The interrupt: wait for INT, read the status register (which clears it)
static uint8_t interrupt() {
  for (int n = 0; n < 3000000; n++) {
    if (top->irq) return rd(R_STATUS);
    tick();
  }
  failures++;
  printf("FAIL no interrupt (state %x, auxiliary status %02x, opcode %02x)\n", (top->dbg >> 16) & 15, (top->dbg >> 8) & 0xFF,
         top->dbg & 0xFF);
  return 0xFF;
}

// Select-and-Transfer of a new command; the chip's status at the interrupt
static uint8_t command(int id, std::vector<uint8_t> cdb, uint32_t count, bool in = true) {
  cdb.resize(12, 0);
  wr(R_DEST, (in ? 0x40 : 0x00) | id);
  set_count(count);
  for (int i = 0; i < 12; i++) wr(R_CDB1 + i, cdb[i]);
  wr(R_LUN, 0);
  wr(R_PHASE, 0x00);
  wr(R_CMD, 0x08);
  return interrupt();
}
// The same command again while connected: resumed at this phase
static uint8_t resume(uint32_t count, uint8_t phase = 0x45) {
  set_count(count);
  wr(R_PHASE, phase);
  wr(R_CMD, 0x09);
  return interrupt();
}
// A command that completes: 0x16, Command Phase 0x60, then the disconnect;
// returns the target's status byte
static int complete(uint8_t st, const char* what) {
  EXPECT(st, 0x16, what);
  EXPECT(rd(R_PHASE), 0x60, "Command Phase after completion");
  uint8_t lun = rd(R_LUN);
  EXPECT(interrupt(), 0x85, "disconnect after completion");
  EXPECT(top->irq, 0, "no interrupt left");
  return lun;
}
static int run(int id, std::vector<uint8_t> cdb, uint32_t count, const char* what, bool in = true) {
  return complete(command(id, cdb, count, in), what);
}
// REQUEST SENSE: {sense key, additional sense code}
static std::pair<int, int> sense(int id) {
  dma_in.clear();
  EXPECT(run(id, {0x03, 0, 0, 0, 18}, 18, "REQUEST SENSE"), 0, "REQUEST SENSE status");
  if (dma_in.size() != 18) { check(false, "REQUEST SENSE length", (long)dma_in.size(), 18); return {-1, -1}; }
  EXPECT(dma_in[0], 0x70, "sense data format");
  return {dma_in[2], dma_in[12]};
}
static void expect_sense(int id, int key, int code, const char* what) {
  auto s = sense(id);
  check(s.first == key && s.second == code, what, (s.first << 8) | s.second, (key << 8) | code);
}

// ---- images: disk block n at byte n*1536 (1280 bytes), disc block n at n*2048
static uint8_t disk_byte(uint32_t n, uint32_t i) { return (uint8_t)(n * 7 + i * 13 + (i >> 8) + 1); }
static uint8_t disc_byte(uint32_t n, uint32_t i) { return (uint8_t)(n * 31 + i * 5 + (i >> 7) + 3); }
static const uint32_t DISK_BLOCKS = 64, DISC_BLOCKS = 100;

static FILE* make_image(uint32_t blocks, uint32_t size, uint32_t stride, uint8_t (*f)(uint32_t, uint32_t)) {
  FILE* fp = tmpfile();
  std::vector<uint8_t> b(stride, 'D');
  for (uint32_t n = 0; n < blocks; n++) {
    for (uint32_t i = 0; i < size; i++) b[i] = f(n, i);
    fwrite(b.data(), 1, stride, fp);
  }
  fflush(fp);
  return fp;
}
static void mount(int i, FILE* fp, uint64_t size, bool readonly = false) {
  sd.f[i] = fp;
  top->img_size = size;
  top->img_readonly = readonly;
  top->img_mounted = 1u << i;
  tick();
  top->img_mounted = 0;
  for (int n = 0; n < 64; n++) tick();
}
static void expect_data(const std::vector<uint8_t>& d, uint32_t lba, size_t bytes, uint32_t size,
                        uint8_t (*f)(uint32_t, uint32_t), const char* what) {
  if (d.size() != bytes) { check(false, what, (long)d.size(), (long)bytes); return; }
  for (size_t k = 0; k < bytes; k++)
    if (d[k] != f(lba + (uint32_t)(k / size), (uint32_t)(k % size))) { check(false, what, (long)k, -1); return; }
  check(true, what);
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  top = new Vxl_scsi;
  sd.targets = 3;
  top->reset = 1;
  for (int i = 0; i < 4; i++) tick();
  top->reset = 0;
  // as the driver initialises the chip: its reset pin, then the Reset command
  top->mr = 1; tick(); top->mr = 0;
  EXPECT(interrupt(), 0x00, "reset pin interrupt");
  wr(0x00, 0x0F);
  wr(R_CMD, 0x00);
  EXPECT(interrupt(), 0x00, "Reset command interrupt (no advanced features: a WD33C93)");
  wr(0x01, 0x85);

  // ---- nothing at 5, no image at 0: timeouts
  EXPECT(command(5, {0x12, 0, 0, 0, 36}, 36), 0x42, "selection timeout, no target");
  EXPECT(command(0, {0x12, 0, 0, 0, 36}, 36), 0x42, "selection timeout, no disk image");

  // ---- the CD-ROM drive with no disc
  dma_in.clear();
  EXPECT(run(2, {0x12, 0, 0, 0, 36}, 36, "INQUIRY, empty drive"), 0, "INQUIRY status");
  check(dma_in.size() == 36 && dma_in[0] == 0x05 && dma_in[1] == 0x80 && dma_in[4] == 31 &&
        !memcmp(&dma_in[8], "SYMBOLICXL1200 CD-ROM   0001", 28), "INQUIRY: a removable CD-ROM");
  dma_in.clear();
  EXPECT(run(2, {0x12, 0, 0, 0, 64}, 64, "INQUIRY, 64 bytes asked"), 0, "INQUIRY status");
  EXPECT(dma_in.size(), 36, "INQUIRY: 36 bytes sent of 64 asked");
  EXPECT(count_regs(), 28, "INQUIRY: the count left");
  EXPECT(run(2, {0x00}, 0, "TEST UNIT READY after reset"), 2, "CHECK CONDITION after reset");
  expect_sense(2, 6, 0x29, "UNIT ATTENTION, reset");
  EXPECT(run(2, {0x00}, 0, "TEST UNIT READY, no disc"), 2, "CHECK CONDITION, no disc");
  expect_sense(2, 2, 0x3A, "NOT READY, medium not present");
  EXPECT(run(2, {0x25}, 8, "READ CAPACITY, no disc"), 2, "READ CAPACITY refused, no disc");
  expect_sense(2, 2, 0x3A, "NOT READY, medium not present");
  expect_sense(2, 0, 0x00, "sense cleared once read");

  // ---- a disc
  FILE* disc = make_image(DISC_BLOCKS, 2048, 2048, disc_byte);
  mount(2, disc, (uint64_t)DISC_BLOCKS * 2048 + 700);   // a ragged end doesn't count
  EXPECT(run(2, {0x00}, 0, "TEST UNIT READY, new disc"), 2, "CHECK CONDITION, new disc");
  expect_sense(2, 6, 0x28, "UNIT ATTENTION, medium changed");
  EXPECT(run(2, {0x00}, 0, "TEST UNIT READY"), 0, "ready");
  dma_in.clear();
  EXPECT(run(2, {0x25}, 8, "READ CAPACITY"), 0, "READ CAPACITY status");
  check(dma_in.size() == 8 && dma_in[3] == DISC_BLOCKS - 1 && dma_in[2] == 0 && dma_in[6] == 0x08 && dma_in[7] == 0x00,
        "READ CAPACITY: 100 blocks of 2048 bytes");
  dma_in.clear();
  EXPECT(run(2, {0x1A, 0, 0, 0, 12}, 12, "MODE SENSE"), 0, "MODE SENSE status");
  check(dma_in.size() == 12 && dma_in[7] == DISC_BLOCKS && dma_in[10] == 0x08 && dma_in[11] == 0x00, "MODE SENSE: 2048-byte blocks");

  // one block, the count exact
  dma_in.clear();
  EXPECT(run(2, {0x08, 0, 0, 16, 1}, 2048, "READ(6), one block"), 0, "READ status");
  expect_data(dma_in, 16, 2048, 2048, disc_byte, "READ(6): block 16");
  EXPECT(count_regs(), 0, "count after an exact read");

  // 64 KB through a 32 KB count, as Genera's ISO 9660 streams read
  dma_in.clear();
  EXPECT(command(2, {0x08, 0, 0, 3, 32}, 32768), 0x49, "count ran out: unexpected data-in phase");
  EXPECT(rd(R_PHASE), 0x46, "Command Phase 0x46");
  EXPECT(count_regs(), 0, "count registers at zero");
  EXPECT(rd(R_ASR) & 0xB0, 0, "not busy, no interrupt while the target waits");
  EXPECT(dma_in.size(), 32768, "first half moved");
  EXPECT(top->busy, 0, "disk light off while the target waits");
  EXPECT(complete(resume(32768), "resumed at phase 0x45"), 0, "READ status");
  expect_data(dma_in, 3, 65536, 2048, disc_byte, "READ(6): 32 blocks in two halves");

  // a short data phase: nine blocks into a 32 KB count
  dma_in.clear();
  EXPECT(run(2, {0x08, 0, 0, 40, 9}, 32768, "READ(6), nine blocks"), 0, "READ status");
  expect_data(dma_in, 40, 18432, 2048, disc_byte, "READ(6): nine blocks");
  EXPECT(count_regs(), 32768 - 18432, "the count left");

  // counts that run out inside a block, twice; READ(10)
  dma_in.clear();
  EXPECT(command(2, {0x28, 0, 0, 0, 0, 90, 0, 0, 3}, 1000), 0x49, "count ran out mid-block");
  EXPECT(resume(100), 0x49, "count ran out again");
  EXPECT(rd(R_PHASE), 0x46, "Command Phase 0x46 again");
  EXPECT(dma_in.size(), 1100, "1100 bytes so far");
  // a resume at a phase that expects status, not data: the same interrupt, nothing moved
  EXPECT(resume(4000, 0x46), 0x49, "resume at 0x46: the target still asks for data");
  EXPECT(dma_in.size(), 1100, "nothing moved");
  EXPECT(complete(resume(6000), "resumed to the end"), 0, "READ status");
  expect_data(dma_in, 90, 6144, 2048, disc_byte, "READ(10): three blocks in three pieces");
  EXPECT(count_regs(), 6000 - (6144 - 1100), "the count left");

  // no count at all: the target has data and the chip expects status
  dma_in.clear();
  EXPECT(command(2, {0x08, 0, 0, 7, 1}, 0), 0x49, "no count, a data phase");
  EXPECT(complete(resume(2048), "resumed"), 0, "READ status");
  expect_data(dma_in, 7, 2048, 2048, disc_byte, "READ(6): block 7");

  // the last block, and past it
  dma_in.clear();
  EXPECT(run(2, {0x08, 0, 0, DISC_BLOCKS - 1, 1}, 2048, "READ(6), last block"), 0, "READ status");
  expect_data(dma_in, DISC_BLOCKS - 1, 2048, 2048, disc_byte, "READ(6): the last block");
  dma_in.clear();
  EXPECT(run(2, {0x28, 0, 0, 0, 0, DISC_BLOCKS - 2, 0, 0, 4}, 8192, "READ(10) past the end"), 2, "CHECK CONDITION past the end");
  EXPECT(dma_in.size(), 0, "no data past the end");
  expect_sense(2, 5, 0x21, "ILLEGAL REQUEST, block out of range");

  // writes refused before any data
  dma_out.assign(4096, 0x55); dma_out_pos = 0;
  EXPECT(run(2, {0x0A, 0, 0, 5, 1}, 2048, "WRITE(6) to the disc", false), 2, "CHECK CONDITION for a write");
  EXPECT(dma_out_pos, 0, "no data taken");
  expect_sense(2, 7, 0x27, "DATA PROTECT, write protected");

  // the reset pin while the target waits: the chip resets, the target is let go
  dma_in.clear();
  EXPECT(command(2, {0x08, 0, 0, 20, 4}, 3000), 0x49, "count ran out");
  top->mr = 1; tick(); top->mr = 0;
  EXPECT(interrupt(), 0x00, "reset pin interrupt while connected");
  wr(0x00, 0x0F); wr(R_CMD, 0x00);
  EXPECT(interrupt(), 0x00, "Reset command interrupt");
  wr(0x01, 0x85);
  EXPECT(run(2, {0x00}, 0, "TEST UNIT READY after the reset"), 2, "CHECK CONDITION after the reset");
  expect_sense(2, 6, 0x29, "UNIT ATTENTION, reset");
  dma_in.clear();
  EXPECT(run(2, {0x08, 0, 0, 20, 4}, 8192, "READ(6) after the reset"), 0, "READ status");
  expect_data(dma_in, 20, 8192, 2048, disc_byte, "READ(6): a new command after the reset");

  // the Reset command while the target waits
  EXPECT(command(2, {0x08, 0, 0, 20, 4}, 3000), 0x49, "count ran out");
  wr(0x00, 0x0F); wr(R_CMD, 0x00);
  EXPECT(interrupt(), 0x00, "Reset command interrupt while connected");
  wr(0x01, 0x85);
  dma_in.clear();
  EXPECT(run(2, {0x08, 0, 0, 60, 2}, 4096, "READ(6) after the Reset command"), 0, "READ status");
  expect_data(dma_in, 60, 4096, 2048, disc_byte, "READ(6): a new command after the Reset command");

  // the disc taken out, another put in
  mount(2, nullptr, 0);
  EXPECT(run(2, {0x00}, 0, "TEST UNIT READY, disc out"), 2, "CHECK CONDITION, disc out");
  expect_sense(2, 2, 0x3A, "NOT READY, medium not present");
  mount(2, disc, (uint64_t)DISC_BLOCKS * 2048);
  EXPECT(run(2, {0x00}, 0, "TEST UNIT READY, disc back"), 2, "CHECK CONDITION, disc back");
  expect_sense(2, 6, 0x28, "UNIT ATTENTION, medium changed");
  dma_in.clear();
  EXPECT(run(2, {0x08, 0, 0, 1, 1}, 2048, "READ(6), disc back"), 0, "READ status");
  expect_data(dma_in, 1, 2048, 2048, disc_byte, "READ(6): block 1 of the disc put back");

  // ---- a disk at target 0
  FILE* disk = make_image(DISK_BLOCKS, 1280, 1536, disk_byte);
  mount(0, disk, (uint64_t)DISK_BLOCKS * 1536);
  dma_in.clear();
  EXPECT(run(0, {0x12, 0, 0, 0, 36}, 36, "INQUIRY, disk"), 0, "INQUIRY status");
  check(dma_in.size() == 36 && dma_in[0] == 0x00 && dma_in[1] == 0x00 &&
        !memcmp(&dma_in[8], "SYMBOLICXL1200 DISK     0001", 28), "INQUIRY: a fixed disk");
  EXPECT(run(0, {0x00}, 0, "TEST UNIT READY, disk"), 0, "a disk has no UNIT ATTENTION");
  dma_in.clear();
  EXPECT(run(0, {0x25}, 8, "READ CAPACITY, disk"), 0, "READ CAPACITY status");
  check(dma_in.size() == 8 && dma_in[3] == DISK_BLOCKS - 1 && dma_in[6] == 0x05 && dma_in[7] == 0x00,
        "READ CAPACITY: 64 blocks of 1280 bytes");
  dma_in.clear();
  EXPECT(run(0, {0x28, 0, 0, 0, 0, 5, 0, 0, 23}, 23 * 1280, "READ(10), 23 blocks"), 0, "READ status");
  expect_data(dma_in, 5, 23 * 1280, 1280, disk_byte, "READ(10): 23 blocks across three windows");
  dma_in.clear();
  EXPECT(run(0, {0x08, 0, 0, 9, 1}, 1280, "READ(6), in the window"), 0, "READ status");
  expect_data(dma_in, 9, 1280, 1280, disk_byte, "READ(6): a block of the window just read");
  // the disc again: the window is the disk's
  dma_in.clear();
  EXPECT(run(2, {0x08, 0, 0, 9, 1}, 2048, "READ(6), disc after the disk"), 0, "READ status");
  expect_data(dma_in, 9, 2048, 2048, disc_byte, "READ(6): the disc's block 9, not the disk's");

  // a write split by the count, then read back
  std::vector<uint8_t> w(3 * 1280);
  for (size_t k = 0; k < w.size(); k++) w[k] = (uint8_t)(k * 3 + 0x40);
  dma_out = w; dma_out_pos = 0;
  EXPECT(command(0, {0x2A, 0, 0, 0, 0, 20, 0, 0, 3}, 2000, false), 0x48, "count ran out: unexpected data-out phase");
  EXPECT(rd(R_PHASE), 0x46, "Command Phase 0x46");
  EXPECT(dma_out_pos, 2000, "2000 bytes taken");
  EXPECT(complete(resume(1840), "write resumed"), 0, "WRITE status");
  EXPECT(dma_out_pos, 3840, "all the data taken");
  dma_in.clear();
  EXPECT(run(0, {0x28, 0, 0, 0, 0, 19, 0, 0, 5}, 5 * 1280, "READ(10) of the written blocks"), 0, "READ status");
  {
    bool ok = dma_in.size() == 5 * 1280;
    for (size_t k = 0; ok && k < 1280; k++) ok = dma_in[k] == disk_byte(19, (uint32_t)k) && dma_in[4 * 1280 + k] == disk_byte(23, (uint32_t)k);
    for (size_t k = 0; ok && k < w.size(); k++) ok = dma_in[1280 + k] == w[k];
    check(ok, "the written blocks read back, their neighbours untouched");
  }
  {
    // in the image: three sectors a block, the pad zero
    std::vector<uint8_t> b(1536);
    fseeko(disk, 21 * 1536, SEEK_SET);
    bool ok = fread(b.data(), 1, 1536, disk) == 1536;
    for (size_t k = 0; ok && k < 1280; k++) ok = b[k] == w[1280 + k];
    for (size_t k = 1280; ok && k < 1536; k++) ok = b[k] == 0;
    check(ok, "the image holds the written block");
  }
  // a write of twelve blocks: two groups to the image
  std::vector<uint8_t> w2(12 * 1280);
  for (size_t k = 0; k < w2.size(); k++) w2[k] = (uint8_t)(k * 11 + 9);
  dma_out = w2; dma_out_pos = 0;
  EXPECT(run(0, {0x2A, 0, 0, 0, 0, 30, 0, 0, 12}, 12 * 1280, "WRITE(10), twelve blocks", false), 0, "WRITE status");
  dma_in.clear();
  EXPECT(run(0, {0x28, 0, 0, 0, 0, 30, 0, 0, 12}, 12 * 1280, "READ(10) of the twelve"), 0, "READ status");
  check(dma_in == w2, "twelve written blocks read back");

  // a read-only disk at target 1: the write's data is taken and dropped
  FILE* disk1 = make_image(DISK_BLOCKS, 1280, 1536, disk_byte);
  mount(1, disk1, (uint64_t)DISK_BLOCKS * 1536, true);
  dma_out = w; dma_out_pos = 0;
  EXPECT(run(1, {0x0A, 0, 0, 2, 2}, 2560, "WRITE(6), read-only image", false), 0, "WRITE status");
  EXPECT(dma_out_pos, 2560, "the data taken");
  dma_in.clear();
  EXPECT(run(1, {0x08, 0, 0, 2, 2}, 2560, "READ(6), read-only image"), 0, "READ status");
  expect_data(dma_in, 2, 2560, 1280, disk_byte, "READ(6): the read-only image unchanged");

  printf("%d checks, %d failures, %llu cycles\n", checks, failures, (unsigned long long)ticks);
  delete top;
  return failures ? 1 : 0;
}
