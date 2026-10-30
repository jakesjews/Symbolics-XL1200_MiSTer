// MiSTer's SD block interface (hps_io's side of sd_rd/sd_wr) for Verilator
// testbenches: acknowledge, move (blk_cnt+1) 512-byte sectors of an image
// file through sd_buff_*, drop the acknowledgement.
#pragma once
#include <cstdint>
#include <cstdio>
#include <vector>

template <class T>
struct SdModel {
  FILE* f[8] = {};
  int busy = -1;            // target being served
  bool writing = false;
  int phase = 0;
  uint32_t pos = 0, len = 0, lba = 0;
  std::vector<uint8_t> data;
  int wait = 0;
  int targets = 2;

  void step(T* top) {
    top->sd_buff_wr = 0;
    if (busy < 0) {
      for (int i = 0; i < targets; i++)
        if (f[i] && ((top->sd_rd >> i & 1) || (top->sd_wr >> i & 1))) {
          busy = i;
          writing = top->sd_wr >> i & 1;
          lba = top->sd_lba[i];
          len = (top->sd_blk_cnt[i] + 1) * 512;
          data.assign(len, 0);
          if (!writing) {
            fseeko(f[i], (off_t)lba * 512, SEEK_SET);
            size_t got = fread(data.data(), 1, len, f[i]);
            (void)got;
          }
          pos = 0;
          phase = 0;
          wait = 20;
          return;
        }
      return;
    }
    if (wait > 0) { wait--; return; }
    switch (phase) {
    case 0:   // acknowledge
      top->sd_ack = 1u << busy;
      top->sd_buff_addr = 0;
      phase = 1;
      wait = 2;
      break;
    case 1:
      if (!writing) {
        top->sd_buff_addr = pos;
        top->sd_buff_dout = data[pos];
        top->sd_buff_wr = 1;
        if (++pos == len) phase = 2;
        wait = 1;
      } else {
        // sd_buff_din follows sd_buff_addr a cycle later
        if (pos > 0) data[pos - 1] = top->sd_buff_din[busy];
        if (pos == len) { phase = 2; break; }
        top->sd_buff_addr = pos++;
        wait = 1;
      }
      break;
    case 2:
      if (writing) {
        fseeko(f[busy], (off_t)lba * 512, SEEK_SET);
        fwrite(data.data(), 1, len, f[busy]);
        fflush(f[busy]);
      }
      top->sd_ack = 0;
      busy = -1;
      break;
    }
  }
};
