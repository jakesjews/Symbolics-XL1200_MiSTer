// The 82586 and its wire to Main's mailbox, driven as Genera's driver drives
// the chip (network/82586-ethernet-driver.lisp): the SCP/ISCP/SCB handshake,
// configure and IA-setup, the receive unit on RFD and RBD chains, transmit
// blocks with TBD chains; Main's side of the mailbox (support/sun/sun_enet.cpp)
// is played here.  Exit status 0 when every check passes.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include "Vtb_ether.h"
#include "Vtb_ether___024root.h"
#include "verilated.h"

static Vtb_ether* top;
static uint64_t cyc = 0;
static int fails = 0;

#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

// ------------------------------------------------------------ buffer memory
static uint8_t rd8(uint32_t a) { return (top->rootp->tb_ether__DOT__bufmem[(a >> 2) & 0x7FFF] >> (8 * (a & 3))) & 0xFF; }
static void wr8(uint32_t a, uint8_t v) {
  uint32_t& w = top->rootp->tb_ether__DOT__bufmem[(a >> 2) & 0x7FFF];
  w = (w & ~(0xFFu << (8 * (a & 3)))) | ((uint32_t)v << (8 * (a & 3)));
}
static uint16_t rd16(uint32_t a) { return rd8(a) | (rd8(a + 1) << 8); }
static void wr16(uint32_t a, uint16_t v) { wr8(a, v & 0xFF); wr8(a + 1, v >> 8); }
static void wr24(uint32_t a, uint32_t v) { wr16(a, v & 0xFFFF); wr16(a + 2, (v >> 16) & 0xFF); }

// The layout, byte addresses in the chip's space (the I/O board's buffer
// memory, 128 KB); offsets in the structures are from SCB_BASE.
static const uint32_t SCB_BASE = 0x1C000, ISCP = SCB_BASE, SCB = SCB_BASE + 8, SCP = 0x1FFF6;
static const uint32_t CMD_AREA = 0x1C020, RBD_AREA = 0x1C800, RFD_AREA = 0x1F800;   // transmit buffers at 0x18000
static const int NRBD = 60, RBD_UNIT = 204, RBD_SIZE = 192, NRFD = 60, RFD_UNIT = 24;
static uint16_t off(uint32_t a) { return a - SCB_BASE; }
static uint32_t rbd_at(int k) { return RBD_AREA + k * RBD_UNIT; }
static uint32_t rbuf_at(int k) { return rbd_at(k) + 12; }
static uint32_t rfd_at(int k) { return RFD_AREA + k * RFD_UNIT; }

// ------------------------------------------------------------ the mailbox (Main's side)
static const uint64_t MAGIC = 0x584C455448303031ULL;   // "XLETH001"
static const int W_MAGIC = 0, W_GEN = 1, W_TXW = 2, W_TXR = 3, W_RXW = 4, W_RXR = 5, W_MAC = 6;
static const int W_TX = 0x1000 / 8, W_RX = 0x5000 / 8, SLOT = 256, TX_RING = 8, RX_RING = 16;
static uint64_t& mb(int w) { return top->rootp->tb_ether__DOT__mbox[w]; }
static uint32_t crc_tab[256];
static uint32_t crc32_le(const uint8_t* p, int n) {
  uint32_t c = 0xFFFFFFFF;
  while (n--) c = crc_tab[(c ^ *p++) & 0xFF] ^ (c >> 8);
  return c;
}
static uint32_t host_txr = 0, host_rxw = 0;
static std::vector<std::vector<uint8_t>> sent;        // frames Main took
static void host_poll() {
  if (mb(W_MAGIC) != MAGIC) return;
  uint32_t txw = (uint32_t)mb(W_TXW);
  while (host_txr != txw) {
    int slot = W_TX + SLOT * (host_txr % TX_RING);
    int len = mb(slot) & 0x7FF;
    std::vector<uint8_t> f(len);
    for (int i = 0; i < len; i++) f[i] = (mb(slot + 1 + i / 8) >> (8 * (i % 8))) & 0xFF;
    sent.push_back(f);
    host_txr++;
  }
  mb(W_TXR) = host_txr;
}
static bool host_send(std::vector<uint8_t> f) {
  uint32_t rxr = (uint32_t)mb(W_RXR);
  if (host_rxw - rxr >= RX_RING) return false;
  while (f.size() < 60) f.push_back(0);
  uint32_t fcs = ~crc32_le(f.data(), f.size());
  for (int k = 0; k < 4; k++) f.push_back(fcs >> (8 * k));
  uint32_t hash = crc32_le(f.data(), 6) >> 26;
  int slot = W_RX + SLOT * (host_rxw % RX_RING);
  for (int i = 0; i < (int)f.size(); i += 8) {
    uint64_t w = 0;
    for (int k = 0; k < 8 && i + k < (int)f.size(); k++) w |= (uint64_t)f[i + k] << (8 * k);
    mb(slot + 1 + i / 8) = w;
  }
  mb(slot) = (uint64_t)f.size() | ((uint64_t)hash << 16);
  mb(W_RXW) = ++host_rxw;
  return true;
}

// ------------------------------------------------------------ clocking and the chip's pins
static void tick(int n = 1) {
  while (n--) {
    top->clk = 0; top->eval();
    top->clk = 1; top->eval();
    cyc++;
    host_poll();
  }
}
static void pins(uint8_t v) {
  top->pins = v; top->pins_we = 1; tick();
  top->pins_we = 0; tick();
}
static const uint8_t UP = 0xE0;                        // reset released, CA high, loopback released
static void ca() { pins(UP & ~0x40); pins(UP); }
// Run until the chip is idle and the SCB command word is 0, as the driver waits
static bool quiet(int limit = 100000) {
  for (int i = 0; i < limit; i++) {
    tick();
    if (!top->busy && rd16(SCB + 2) == 0) return true;
  }
  return false;
}
static bool wait_status(uint16_t mask, int limit = 100000) {
  for (int i = 0; i < limit; i++) {
    tick();
    if ((rd16(SCB) & mask) == mask && !top->busy) return true;
  }
  return false;
}
static void scb_command(uint16_t cmd) {
  CHECK(rd16(SCB + 2) == 0, "SCB command word busy: %04X", rd16(SCB + 2));
  wr16(SCB + 2, cmd);
  ca();
}
static void ack() {                                    // acknowledge every status bit, as the interrupt handler
  uint16_t s = rd16(SCB) & 0xF000;
  if (s) { scb_command(s); CHECK(quiet(), "ack did not complete"); }
  CHECK((rd16(SCB) & 0xF000) == 0, "status not cleared: %04X", rd16(SCB));
  CHECK(!top->irq, "irq still up");
}

// ------------------------------------------------------------ command blocks
static uint32_t cb_next = CMD_AREA;
static uint32_t new_cb(int bytes) { uint32_t a = cb_next; cb_next += (bytes + 3) & ~3; if (cb_next > CMD_AREA + 0x700) cb_next = CMD_AREA; return a; }
static void cb_header(uint32_t cb, uint16_t cmd, bool el, bool intr) {
  wr16(cb, 0);
  wr16(cb + 2, cmd | (intr ? 0x2000 : 0) | (el ? 0x8000 : 0));
  wr16(cb + 4, 0xFFFF);
}
static void run_cbl(uint32_t first_cb) {              // start the CU on the list, wait for it to go idle
  wr16(SCB + 4, off(first_cb));
  scb_command(0x0100);
  CHECK(wait_status(0x2000), "CNA not seen after the command list");
}
static uint32_t cb_configure(bool alloc, bool prom, bool prev_el, uint32_t* prev) {
  uint32_t cb = new_cb(18);
  cb_header(cb, 2, true, true);
  wr8(cb + 6, 12); wr8(cb + 7, 10);                    // byte count, fifo limit
  wr8(cb + 8, 0x00);
  wr8(cb + 9, 0x06 | (alloc ? 0x08 : 0) | 0x20);        // address length 6, AL-LOC, preamble 2
  wr8(cb + 10, 0x00); wr8(cb + 11, 96);
  wr8(cb + 12, 0x00); wr8(cb + 13, 0xF2);               // slot time 512, 15 retries
  wr8(cb + 14, prom ? 0x01 : 0x00);
  wr8(cb + 15, 0x00); wr8(cb + 16, 64); wr8(cb + 17, 0);
  if (prev) { wr16(*prev + 4, off(cb)); if (!prev_el) wr16(*prev + 2, rd16(*prev + 2) & ~0x8000); }
  return cb;
}
static const uint8_t MAC[6] = {0x08, 0x00, 0x05, 0x12, 0x00, 0x01};
static uint32_t cb_ia(uint32_t* prev) {
  uint32_t cb = new_cb(12);
  cb_header(cb, 1, true, true);
  for (int i = 0; i < 6; i++) wr8(cb + 6 + i, MAC[i]);
  if (prev) { wr16(*prev + 4, off(cb)); wr16(*prev + 2, rd16(*prev + 2) & ~0x8000); }
  return cb;
}

// ------------------------------------------------------------ receive area
static void build_ru(int el_rfd) {
  for (int k = 0; k < NRBD; k++) {
    uint32_t r = rbd_at(k);
    wr16(r, 0);
    wr16(r + 2, off(rbd_at((k + 1) % NRBD)));
    wr24(r + 4, rbuf_at(k));
    wr16(r + 8, RBD_SIZE | (k == NRBD - 1 ? 0x8000 : 0));
  }
  for (int k = 0; k < NRFD; k++) {
    uint32_t f = rfd_at(k);
    wr16(f, 0);
    wr16(f + 2, k == el_rfd ? 0x8000 : 0);
    wr16(f + 4, off(rfd_at((k + 1) % NRFD)));
    wr16(f + 6, k == 0 ? off(rbd_at(0)) : 0xFFFF);
    for (int i = 8; i < 22; i += 2) wr16(f + i, 0);
  }
  wr16(SCB + 6, off(rfd_at(0)));
  scb_command(0x0010);                                 // RUC start
  CHECK(quiet(), "RU start did not complete");
  CHECK((rd16(SCB) & 0x0070) == 0x0040, "RU not ready: SCB %04X", rd16(SCB));
}

static std::vector<uint8_t> frame(int len, const uint8_t* dst, uint8_t seed) {
  std::vector<uint8_t> f(len);
  for (int i = 0; i < 6; i++) f[i] = dst[i];
  for (int i = 0; i < 6; i++) f[6 + i] = MAC[i];
  f[12] = 0x08; f[13] = 0x00;
  for (int i = 14; i < len; i++) f[i] = (uint8_t)(seed + i * 7);
  return f;
}
static bool same(const std::vector<uint8_t>& a, const std::vector<uint8_t>& b, const char* what) {
  if (a.size() != b.size()) { CHECK(false, "%s: length %zu, wanted %zu", what, a.size(), b.size()); return false; }
  for (size_t i = 0; i < a.size(); i++)
    if (a[i] != b[i]) { CHECK(false, "%s: byte %zu is %02X, wanted %02X", what, i, a[i], b[i]); return false; }
  return true;
}

// A transmit block with a chain of TBDs over the given buffers
static uint32_t cb_transmit(const std::vector<uint8_t>& f, const std::vector<std::pair<uint32_t, int>>& bufs,
                            bool alloc) {
  uint32_t cb = new_cb(16);
  cb_header(cb, 4, true, true);
  size_t p = alloc ? 0 : 14;
  if (!alloc) {
    for (int i = 0; i < 6; i++) wr8(cb + 8 + i, f[i]);
    wr8(cb + 14, f[12]); wr8(cb + 15, f[13]);
  }
  uint32_t tbd_prev = 0;
  for (size_t b = 0; b < bufs.size(); b++) {
    uint32_t tbd = new_cb(8);
    int n = bufs[b].second;
    wr16(tbd, n | (b + 1 == bufs.size() ? 0x8000 : 0));
    wr16(tbd + 2, 0xFFFF);
    wr24(tbd + 4, bufs[b].first);
    for (int i = 0; i < n; i++) wr8(bufs[b].first + i, f[p + i]);
    p += n;
    if (b == 0) wr16(cb + 6, off(tbd)); else wr16(tbd_prev + 2, off(tbd));
    tbd_prev = tbd;
  }
  CHECK(p == f.size(), "buffers cover %zu of %zu bytes", p, f.size());
  return cb;
}

static void test_transmit(const char* name, const std::vector<uint8_t>& f,
                          const std::vector<std::pair<uint32_t, int>>& bufs, bool alloc) {
  size_t before = sent.size();
  uint32_t cb = cb_transmit(f, bufs, alloc);
  run_cbl(cb);
  CHECK((rd16(SCB) & 0x8000) != 0, "%s: CX not set: SCB %04X", name, rd16(SCB));
  CHECK(rd16(cb) == 0xA000, "%s: CB status %04X", name, rd16(cb));
  tick(50);
  CHECK(sent.size() == before + 1, "%s: Main took %zu frames, wanted 1", name, sent.size() - before);
  if (sent.size() == before + 1) same(sent.back(), f, name);
  ack();
}

// The frame delivered through the RFD at rfd, its RBDs from the buffers
static std::vector<uint8_t> delivered(uint32_t rfd, bool alloc, int* nrbd, uint16_t* first) {
  std::vector<uint8_t> f;
  *nrbd = 0;
  if (!alloc) for (int i = 0; i < 14; i++) f.push_back(rd8(rfd + 8 + i));
  uint16_t r = rd16(rfd + 6);
  *first = r;
  for (int guard = 0; guard < 64 && r != 0xFFFF; guard++) {
    uint32_t rbd = SCB_BASE + r;
    uint16_t st = rd16(rbd);
    int n = st & 0x3FFF;
    uint32_t buf = rd16(rbd + 4) | ((uint32_t)rd8(rbd + 6) << 16);
    CHECK(st & 0x4000, "RBD %04X without F: %04X", r, st);
    for (int i = 0; i < n; i++) f.push_back(rd8(buf + i));
    (*nrbd)++;
    if (st & 0x8000) break;
    r = rd16(rbd + 2);
  }
  return f;
}

static void dump(const char* why) {
  printf("-- %s: cycle %llu SCB %04X cmd %04X rxw %u RXR %u irq %d busy %d\n", why, (unsigned long long)cyc,
         rd16(SCB), rd16(SCB + 2), host_rxw, (unsigned)mb(W_RXR), top->irq, top->busy);
  for (int k = 0; k < 10; k++)
    printf("   RFD%d status %04X cmd %04X link %04X rbd %04X\n", k, rd16(rfd_at(k)), rd16(rfd_at(k) + 2),
           rd16(rfd_at(k) + 4), rd16(rfd_at(k) + 6));
  for (int k = 0; k < 16; k++)
    printf("   RBD%d status %04X next %04X buf %02X%02X%02X%02X\n", k, rd16(rbd_at(k)), rd16(rbd_at(k) + 2),
           rd8(rbuf_at(k)), rd8(rbuf_at(k) + 1), rd8(rbuf_at(k) + 2), rd8(rbuf_at(k) + 3));
}
static int rfd_i = 0;                                   // the next RFD a frame lands in
static void test_receive(const char* name, const std::vector<uint8_t>& f, bool alloc, int want_rbds,
                         uint16_t want_first) {
  CHECK(host_send(f), "%s: RX ring full", name);
  if (!wait_status(0x4000, 150000)) { CHECK(false, "%s: FR not seen", name); dump(name); }
  uint32_t rfd = rfd_at(rfd_i);
  CHECK((rd16(rfd) & 0xE000) == 0xA000, "%s: RFD %d status %04X", name, rfd_i, rd16(rfd));
  int nrbd; uint16_t first;
  std::vector<uint8_t> got = delivered(rfd, alloc, &nrbd, &first);
  std::vector<uint8_t> want = f;
  while (want.size() < 60) want.push_back(0);
  int before = fails;
  same(got, want, name);
  if (fails != before) dump(name);
  CHECK(nrbd == want_rbds, "%s: %d RBDs, wanted %d", name, nrbd, want_rbds);
  CHECK(first == want_first, "%s: first RBD %04X, wanted %04X", name, first, want_first);
  rfd_i++;
  ack();
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  top = new Vtb_ether;
  for (uint32_t i = 0; i < 256; i++) {
    uint32_t c = i;
    for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xEDB88320 & -(c & 1));
    crc_tab[i] = c;
  }
  for (int i = 0; i < 32768; i++) top->rootp->tb_ether__DOT__bufmem[i] = 0;
  for (int i = 0; i < 8192; i++) top->rootp->tb_ether__DOT__mbox[i] = 0;
  top->ena = 1;
  top->reset = 1; tick(5); top->reset = 0; tick(5);

  // ---- the mailbox comes up
  tick(100);
  CHECK(mb(W_MAGIC) == MAGIC, "mailbox magic %016llX", (unsigned long long)mb(W_MAGIC));

  // ---- SCP, ISCP, SCB; reset and the first channel attention
  wr16(SCP, 0); wr24(SCP + 6, ISCP);
  wr8(ISCP, 1); wr8(ISCP + 1, 0); wr16(ISCP + 2, SCB - SCB_BASE); wr24(ISCP + 4, SCB_BASE);
  for (int i = 0; i < 16; i += 2) wr16(SCB + i, 0);
  wr16(SCB + 4, 0xFFFF); wr16(SCB + 6, 0xFFFF);
  pins(0x00);                                           // reset asserted
  pins(UP);
  ca();
  CHECK(quiet(), "initialisation did not complete");
  CHECK(rd8(ISCP) == 0, "ISCP busy byte %02X", rd8(ISCP));
  CHECK(rd16(SCB) == 0xA000, "SCB after init %04X (CX|CNA wanted)", rd16(SCB));
  CHECK(top->irq, "no interrupt after init");
  ack();

  // ---- configure (AL-LOC 1) and IA setup
  {
    uint32_t cfg = cb_configure(true, false, false, nullptr);
    uint32_t ia = cb_ia(&cfg);
    run_cbl(cfg);
    CHECK(rd16(cfg) == 0xA000, "configure status %04X", rd16(cfg));
    CHECK(rd16(ia) == 0xA000, "IA setup status %04X", rd16(ia));
    CHECK((rd16(SCB) & 0x8000) != 0, "CX after the list");
    ack();
    tick(200);
    uint64_t mac = mb(W_MAC);
    CHECK(mac == 0x8000080005120001ULL, "MAC word %016llX", (unsigned long long)mac);
  }

  // ---- receive unit
  build_ru(-1);

  // ---- transmit: one buffer, then a chain with odd lengths and an odd start
  const uint8_t BCAST[6] = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};
  const uint8_t PEER[6] = {0x00, 0x11, 0x22, 0x33, 0x44, 0x55};
  test_transmit("tx one buffer", frame(100, BCAST, 1), {{0x18000, 100}}, true);
  test_transmit("tx chain", frame(123, PEER, 2), {{0x18000, 50}, {0x18101, 73}}, true);
  test_transmit("tx 1514", frame(1514, PEER, 3), {{0x18000, 1514}}, true);
  test_transmit("tx runt 14", frame(14, PEER, 4), {{0x18000, 14}}, true);

  // ---- receive: ours (two buffers), broadcast and odd, a 1514, then one for another station
  test_receive("rx 300", frame(300, MAC, 5), true, 2, off(rbd_at(0)));
  test_receive("rx 61 broadcast", frame(61, BCAST, 6), true, 1, off(rbd_at(2)));
  test_receive("rx 1514", frame(1514, MAC, 7), true, 8, off(rbd_at(3)));
  {
    size_t before = sent.size();
    CHECK(host_send(frame(200, PEER, 8)), "RX ring full");
    CHECK(!wait_status(0x4000, 150000), "a frame for another station was delivered");
    CHECK(sent.size() == before, "something was transmitted");
    CHECK((uint32_t)mb(W_RXR) == host_rxw, "the filtered frame was not consumed");
  }
  // a frame while the RU is suspended is dropped, and the RU resumed takes the next
  scb_command(0x0030); CHECK(quiet(), "RU suspend");
  CHECK((rd16(SCB) & 0x0070) == 0x0010, "RU not suspended: %04X", rd16(SCB));
  ack();
  CHECK(host_send(frame(80, MAC, 9)), "RX ring full");
  CHECK(!wait_status(0x4000, 150000), "a frame was delivered to a suspended RU");
  scb_command(0x0020); CHECK(quiet(), "RU resume");
  CHECK((rd16(SCB) & 0x0070) == 0x0040, "RU not ready: %04X", rd16(SCB));
  ack();
  test_receive("rx after resume", frame(90, MAC, 10), true, 1, off(rbd_at(11)));

  // ---- no resources: the RFD with EL takes the frame and ends the area; Genera restarts the RU
  {
    uint32_t rfd = rfd_at(rfd_i);
    wr16(rfd + 2, 0x8000);
    test_receive("rx into the last RFD", frame(70, MAC, 11), true, 1, off(rbd_at(12)));
    CHECK((rd16(SCB) & 0x0070) == 0x0020, "RU not out of resources: %04X", rd16(SCB));
    CHECK(host_send(frame(72, MAC, 12)), "RX ring full");
    CHECK(!wait_status(0x4000, 150000), "a frame was delivered with no resources");
    // the driver's restart: the next RFD names the next free RBD
    wr16(rfd + 2, 0);
    uint32_t next = rfd_at(rfd_i);
    wr16(next + 6, off(rbd_at(13)));
    wr16(SCB + 6, off(next));
    scb_command(0x0010); CHECK(quiet(), "RU restart");
    CHECK((rd16(SCB) & 0x0070) == 0x0040, "RU not ready after restart: %04X", rd16(SCB));
    ack();
    test_receive("rx after restart", frame(75, MAC, 13), true, 1, off(rbd_at(13)));
  }

  // ---- AL-LOC 0: the addresses and length in the block and the RFD
  {
    uint32_t cfg = cb_configure(false, false, true, nullptr);
    run_cbl(cfg);
    CHECK(rd16(cfg) == 0xA000, "configure (AL-LOC 0) status %04X", rd16(cfg));
    ack();
    test_transmit("tx AL-LOC 0", frame(60, PEER, 14), {{0x18000, 46}}, false);
    test_receive("rx AL-LOC 0", frame(100, MAC, 15), false, 1, off(rbd_at(14)));
  }

  // ---- the network off: a transmit completes, nothing reaches Main
  {
    uint32_t cfg = cb_configure(true, false, true, nullptr);
    run_cbl(cfg); ack();
    top->ena = 0;
    size_t before = sent.size();
    uint32_t cb = cb_transmit(frame(100, BCAST, 16), {{0x18000, 100}}, true);
    run_cbl(cb);
    CHECK(rd16(cb) == 0xA000, "transmit with the network off: CB status %04X", rd16(cb));
    tick(100);
    CHECK(sent.size() == before, "a frame reached Main with the network off");
    ack();
    top->ena = 1;
  }

  printf("%s: %d failures, %llu cycles\n", fails ? "FAIL" : "PASS", fails, (unsigned long long)cyc);
  delete top;
  return fails ? 1 : 0;
}
