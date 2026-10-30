// DDR3 behind MiSTer's DDRAM port (Avalon-MM, 64-bit) for Verilator
// testbenches: random wait states and read latency.
#pragma once
#include <cstdint>
#include <cstdlib>
#include <deque>
#include <unordered_map>
#include <vector>

struct DdrModel {
  std::unordered_map<uint32_t, uint64_t> mem;
  // a flat array for [flat_base, flat_base + flat.size()), faster for big tests
  std::vector<uint64_t> flat;
  uint32_t flat_base = 0;
  int busy_pct = 25, min_latency = 4, max_latency = 14;
  // read beats waiting to come back: (cycle due, data)
  std::deque<std::pair<uint64_t, uint64_t>> pending;
  uint64_t cycle = 0;
  uint32_t waddr = 0;
  int wleft = 0;
  bool busy = false;
  bool watch = false;
  uint32_t watch_addr = 0;
  // When set, the address of every word written is appended here.
  std::vector<uint32_t>* write_log = nullptr;

  uint64_t& at(uint32_t a) {
    a &= 0x1FFFFFFF;
    if (a - flat_base < flat.size()) return flat[a - flat_base];
    return mem[a];
  }

  // Avalon transfers happen at a clock edge with the values driven before it:
  // call sample() before the rising edge and update() after it.
  bool s_rd = false, s_we = false;
  uint32_t s_addr = 0, s_cnt = 0;
  uint64_t s_din = 0;
  uint8_t s_be = 0;
  template <class T>
  void sample(T* d) {
    s_rd = d->ddr_rd && !busy;
    s_we = d->ddr_we && !busy;
    s_addr = d->ddr_addr; s_cnt = d->ddr_burstcnt; s_din = d->ddr_din; s_be = d->ddr_be;
  }
  template <class T>
  void update(T* d) {
    cycle++;
    if (s_rd) {
      uint64_t due = cycle + min_latency + rand() % (max_latency - min_latency + 1);
      for (uint32_t i = 0; i < s_cnt; i++) pending.emplace_back(due + i, at(s_addr + i));
    }
    if (s_we) {
      if (wleft == 0) { waddr = s_addr; wleft = s_cnt; }
      uint64_t& m = at(waddr);
      if (watch && (waddr & 0x1FFFFFFF) == watch_addr)
        printf("[ddr] write %08x be %02x data %016llx burst-start %08x (cycle %llu)\n", waddr, s_be,
               (unsigned long long)s_din, s_addr, (unsigned long long)cycle);
      uint64_t mask = 0;
      for (int b = 0; b < 8; b++)
        if (s_be & (1 << b)) mask |= 0xFFull << (8 * b);
      m = (m & ~mask) | (s_din & mask);
      if (write_log) write_log->push_back(waddr & 0x1FFFFFFF);
      waddr++;
      wleft--;
    }
    d->ddr_dout_ready = 0;
    if (!pending.empty() && pending.front().first <= cycle) {
      d->ddr_dout = pending.front().second;
      d->ddr_dout_ready = 1;
      pending.pop_front();
    }
    busy = (rand() % 100) < busy_pct;
    d->ddr_busy = busy;
  }
};
