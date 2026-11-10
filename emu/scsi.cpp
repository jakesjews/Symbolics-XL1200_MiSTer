#include "scsi.h"
#include <algorithm>
#include <cstring>

// ---------------------------------------------------------------------------
// Direct-access disk and CD-ROM targets
// ---------------------------------------------------------------------------

bool ScsiDisk::open(const std::string& path, uint32_t bs, uint32_t st) {
  f = fopen(path.c_str(), "r+b");
  if (!f) f = fopen(path.c_str(), "rb");
  if (!f) return false;
  block_size = bs;
  stride = st < bs ? bs : st;
  fseeko(f, 0, SEEK_END);
  uint64_t size = (uint64_t)ftello(f);
  blocks = size >= block_size ? (size - block_size) / stride + 1 : 0;
  return true;
}

void ScsiDisk::fit_cdrom() {
  cdrom = true;
  block_size = stride = 2048;
  blocks = 0;
  product = "XL1200 CD-ROM   ";
  attention = 0x29;
}

bool ScsiDisk::insert(const std::string& path) {
  if (f) fclose(f);
  f = nullptr;
  blocks = 0;
  if (path.empty()) return true;
  f = fopen(path.c_str(), "rb");
  if (!f) return false;
  fseeko(f, 0, SEEK_END);
  blocks = (uint64_t)ftello(f) / block_size;
  attention = 0x28;   // not ready to ready: the medium may have changed
  return true;
}

void ScsiDisk::bus_reset() {
  if (cdrom) attention = 0x29;
}

uint32_t ScsiDisk::data_out_length(const uint8_t* cdb) const {
  if (cdrom) return 0;   // a write is refused before any data
  if (cdb[0] == 0x0A) return (cdb[4] ? cdb[4] : 256) * block_size;
  if (cdb[0] == 0x2A) return ((cdb[7] << 8) | cdb[8]) * block_size;
  return 0;
}

static void put_be32(uint8_t* p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }

uint8_t ScsiDisk::execute(const uint8_t* cdb, std::vector<uint8_t>& in, const std::vector<uint8_t>& out,
                          bool& is_write, uint32_t& out_len) {
  is_write = false;
  out_len = 0;
  in.clear();
  auto check = [&](uint8_t key, uint8_t code) { sense_key = key; asc = code; return (uint8_t)2; };
  if (cdrom && cdb[0] != 0x03 && cdb[0] != 0x12) {
    if (attention) {   // reported once, to the first command that isn't INQUIRY or REQUEST SENSE
      uint8_t code = attention;
      attention = 0;
      return check(6, code);
    }
    if (!f) return check(2, 0x3A);   // not ready: medium not present
    if (cdb[0] == 0x0A || cdb[0] == 0x2A) return check(7, 0x27);   // data protect: write protected
  }
  switch (cdb[0]) {
  case 0x00:  // TEST UNIT READY
    sense_key = 0;
    return 0;
  case 0x03: {  // REQUEST SENSE
    uint8_t s[18] = {0x70, 0, sense_key, 0, 0, 0, 0, 10, 0, 0, 0, 0, asc, 0, 0, 0, 0, 0};
    int n = cdb[4] ? cdb[4] : 4;
    in.assign(s, s + (n < 18 ? n : 18));
    sense_key = asc = 0;
    return 0;
  }
  case 0x12: {  // INQUIRY
    uint8_t s[36];
    memset(s, ' ', sizeof s);
    s[0] = cdrom ? 0x05 : 0x00;   // CD-ROM, removable
    s[1] = cdrom ? 0x80 : 0x00;
    s[2] = 1; s[3] = 1; s[4] = 31; s[5] = s[6] = s[7] = 0;
    memcpy(s + 8, vendor.data(), vendor.size() < 8 ? vendor.size() : 8);
    memcpy(s + 16, product.data(), product.size() < 16 ? product.size() : 16);
    memcpy(s + 32, rev.data(), rev.size() < 4 ? rev.size() : 4);
    int n = cdb[4];
    in.assign(s, s + (n < 36 ? n : 36));
    return 0;
  }
  case 0x1A: {  // MODE SENSE(6): header + one block descriptor
    uint8_t s[12] = {11, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0};
    uint32_t nb = blocks > 0xFFFFFF ? 0xFFFFFF : (uint32_t)blocks;
    s[5] = nb >> 16; s[6] = nb >> 8; s[7] = nb;
    s[9] = block_size >> 16; s[10] = block_size >> 8; s[11] = block_size;
    int n = cdb[4];
    in.assign(s, s + (n < 12 ? n : 12));
    return 0;
  }
  case 0x01:  // REZERO UNIT
  case 0x0B:  // SEEK(6)
  case 0x15:  // MODE SELECT(6) (parameters ignored)
  case 0x1B:  // START STOP UNIT
  case 0x1E:  // PREVENT/ALLOW MEDIUM REMOVAL
  case 0x2B:  // SEEK(10)
  case 0x2F:  // VERIFY(10)
  case 0x35:  // SYNCHRONIZE CACHE
    return 0;
  case 0x25: {  // READ CAPACITY
    uint8_t s[8];
    put_be32(s, (uint32_t)(blocks - 1));
    put_be32(s + 4, block_size);
    in.assign(s, s + 8);
    return 0;
  }
  case 0x08: case 0x28: case 0x0A: case 0x2A: {  // READ/WRITE (6)/(10)
    uint32_t lba, n;
    if (cdb[0] == 0x08 || cdb[0] == 0x0A) {
      lba = ((cdb[1] & 0x1F) << 16) | (cdb[2] << 8) | cdb[3];
      n = cdb[4] ? cdb[4] : 256;
    } else {
      lba = (cdb[2] << 24) | (cdb[3] << 16) | (cdb[4] << 8) | cdb[5];
      n = (cdb[7] << 8) | cdb[8];
    }
    if ((uint64_t)lba + n > blocks) return check(5, 0x21);   // illegal request: LBA out of range
    bool wr = cdb[0] == 0x0A || cdb[0] == 0x2A;
    if (!wr) {
      in.resize((size_t)n * block_size);
      for (uint32_t i = 0; i < n; i++) {
        fseeko(f, (off_t)(lba + i) * stride, SEEK_SET);
        if (fread(in.data() + (size_t)i * block_size, 1, block_size, f) != block_size) return check(3, 0x11);
      }
    } else {
      is_write = true;
      out_len = n * block_size;
      if (out.size() >= out_len) {
        for (uint32_t i = 0; i < n; i++) {
          fseeko(f, (off_t)(lba + i) * stride, SEEK_SET);
          fwrite(out.data() + (size_t)i * block_size, 1, block_size, f);
        }
        fflush(f);
        if (!watch.empty() && std::search(out.begin(), out.begin() + out_len, watch.begin(), watch.end()) != out.begin() + out_len)
          watch_seen = true;
      }
    }
    return 0;
  }
  default:
    return check(5, 0x20);   // illegal request: invalid command
  }
}

// ---------------------------------------------------------------------------
// WD33C93
// ---------------------------------------------------------------------------

enum {
  R_OWN_ID = 0x00, R_CONTROL = 0x01, R_TIMEOUT = 0x02, R_CDB1 = 0x03, R_TARGET_LUN = 0x0F,
  R_COMMAND_PHASE = 0x10, R_SYNC = 0x11, R_COUNT_HI = 0x12, R_DEST_ID = 0x15, R_SOURCE_ID = 0x16,
  R_SCSI_STATUS = 0x17, R_COMMAND = 0x18, R_DATA = 0x19, R_ASR = 0x1F,
};

WD33C93::WD33C93() { memset(regs, 0, sizeof regs); }

void WD33C93::hardware_reset() {
  memset(regs, 0, sizeof regs);
  asr = 0;
  pending.clear();
  conn.active = false;   // the board resets the bus with the chip
  for (ScsiDisk& t : targets) t.bus_reset();
  interrupt(0x00);
}

void WD33C93::interrupt(uint8_t status) {
  asr &= ~0x30;   // not busy, no command in progress
  if (asr & 0x80) { pending.push_back(status); return; }
  regs[R_SCSI_STATUS] = status;
  asr |= 0x80;
}

uint8_t WD33C93::read_reg(int reg) {
  if (reg == R_ASR) {
    if (trace > 1) fprintf(stderr, "[wd33c93] read ASR -> %02x\n", asr);
    return asr;
  }
  uint8_t v = regs[reg & 0x1F];
  if (reg == R_SCSI_STATUS) {   // reading the status clears INT and presents the next one
    asr &= ~0x80;
    if (!pending.empty()) {
      regs[R_SCSI_STATUS] = pending.front();
      pending.pop_front();
      asr |= 0x80;
    }
  }
  if (trace > 1) fprintf(stderr, "[wd33c93] read %02x -> %02x\n", reg, v);
  return v;
}

void WD33C93::write_reg(int reg, uint8_t v) {
  reg &= 0x1F;
  if (trace > 1) fprintf(stderr, "[wd33c93] write %02x <- %02x\n", reg, v);
  if (reg == R_COMMAND) { command(v); return; }
  regs[reg] = v;
}

void WD33C93::command(uint8_t c) {
  regs[R_COMMAND] = c;
  if (trace) fprintf(stderr, "[wd33c93] command %02x dest %d cdb %02x\n", c, regs[R_DEST_ID] & 7, regs[R_CDB1]);
  switch (c & 0x7F) {
  case 0x00:  // reset: advanced features if EAF set in own-id
    own_id = regs[R_OWN_ID] & 7;
    conn.active = false;
    interrupt((a_part && (regs[R_OWN_ID] & 0x08)) ? 0x01 : 0x00);
    return;
  case 0x01:  // abort
    interrupt(0x22);
    return;
  case 0x08: select_and_transfer(true); return;
  case 0x09: select_and_transfer(false); return;
  default:
    if (trace) fprintf(stderr, "[wd33c93] unimplemented command %02x\n", c);
    asr |= 0x40;   // last command ignored
    interrupt(0x40);
    return;
  }
}

static int cdb_length(uint8_t op, uint8_t cdb_size_reg) {
  switch (op >> 5) {
  case 0: return 6;
  case 1: case 2: return 10;
  case 5: return 12;
  default: return cdb_size_reg & 0x0F ? (cdb_size_reg & 0x0F) : 6;
  }
}

void WD33C93::select_and_transfer(bool) {
  if (conn.active) {
    // Issued while connected, the command resumes at the Command Phase
    // register: 0x45 (and 0x41) go on with the data phase; every other phase
    // expects something else than the data the target still asks for.
    uint8_t phase = regs[R_COMMAND_PHASE];
    if (trace) fprintf(stderr, "[wd33c93] resume at phase %02x count %u\n", phase, count());
    if (phase == 0x45 || phase == 0x41) data_phase();
    else interrupt(conn.out ? 0x48 : 0x49);
    return;
  }
  int id = regs[R_DEST_ID] & 7;
  ScsiDisk& t = targets[id];
  if (id == own_id || !t.present()) {
    regs[R_COMMAND_PHASE] = 0x00;
    interrupt(0x42);   // timeout during selection
    return;
  }
  conn = Connection();
  conn.id = id;
  memcpy(conn.cdb, &regs[R_CDB1], 12);
  int len = cdb_length(conn.cdb[0], regs[R_OWN_ID] >> 4);
  (void)len;
  // A write's data-out bytes are gathered first (the target needs them);
  // every other command runs now and its data-in bytes wait for the count.
  uint32_t want = t.data_out_length(conn.cdb);
  if (want) {
    conn.out = true;
    conn.data.resize(want);
  } else {
    bool is_write = false;
    uint32_t out_len = 0;
    conn.status = t.execute(conn.cdb, conn.data, {}, is_write, out_len);
  }
  conn.active = true;
  data_phase();
}

void WD33C93::data_phase() {
  ScsiDisk& t = targets[conn.id];
  uint32_t n = count();
  uint64_t left = conn.data.size() - conn.pos;
  uint32_t k = left < n ? (uint32_t)left : n;
  for (uint32_t i = 0; i < k; i++, conn.pos++) {
    if (conn.out) conn.data[conn.pos] = dma_read ? dma_read() : 0;
    else if (dma_write) dma_write(conn.data[conn.pos]);
  }
  n -= k;
  set_count(n);
  if (conn.pos < conn.data.size()) {
    // The count ran out and the target asks for more data: an unexpected
    // information phase (data out 0x48, data in 0x49) with the Command Phase
    // at 0x46, the target left connected (data sheet 7.6.1).
    regs[R_COMMAND_PHASE] = 0x46;
    if (trace) fprintf(stderr, "[wd33c93] target %d cdb %02x: count ran out, %llu bytes to go\n", conn.id, conn.cdb[0],
                       (unsigned long long)(conn.data.size() - conn.pos));
    interrupt(conn.out ? 0x48 : 0x49);
    return;
  }
  if (conn.out) {
    std::vector<uint8_t> in;
    bool is_write = false;
    uint32_t out_len = 0;
    conn.status = t.execute(conn.cdb, in, conn.data, is_write, out_len);
  }
  conn.active = false;
  regs[R_TARGET_LUN] = conn.status;
  regs[R_COMMAND_PHASE] = 0x60;
  if (trace) fprintf(stderr, "[wd33c93] target %d cdb %02x %02x %02x %02x %02x %02x status %d data %zu residual %u\n", conn.id,
                     conn.cdb[0], conn.cdb[1], conn.cdb[2], conn.cdb[3], conn.cdb[4], conn.cdb[5], conn.status,
                     conn.data.size(), n);
  // Command Complete gives 0x16; the target then goes bus free, which reports a
  // disconnect unless EDI (control bit 3) asks for the 0x16 to come at that point.
  interrupt(0x16);
  if (!(regs[R_CONTROL] & 0x08)) interrupt(0x85);
}
