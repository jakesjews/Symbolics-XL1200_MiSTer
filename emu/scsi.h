// Western Digital WD33C93 SCSI bus interface controller (initiator role) with
// SCSI direct-access disk targets and a CD-ROM drive backed by image files, as
// on the Merlin I/O board.  Data phases move bytes through a DMA port supplied
// by the board.
#pragma once
#include <cstdint>
#include <cstdio>
#include <deque>
#include <functional>
#include <string>
#include <vector>

class ScsiDisk {
  friend struct ModelState;   // sim/system: copies state into the RTL
  friend struct Snapshot;     // emu/snapshot.cpp: saves and restores the state
public:
  // An image holds one block every `stride` bytes.  SCSI2SD stores a 1280-byte
  // block in three 512-byte SD sectors, so raw card dumps use a stride of 1536.
  bool open(const std::string& path, uint32_t block_size, uint32_t stride);
  // A CD-ROM drive at this address: it answers with or without a disc, reads
  // 2048-byte blocks of an ISO image and refuses writes.  insert() puts a
  // disc in ("" takes it out); the next command meets UNIT ATTENTION.
  void fit_cdrom();
  bool insert(const std::string& path);
  bool present() const { return f != nullptr || cdrom; }
  void bus_reset();   // a CD-ROM reports the reset as UNIT ATTENTION
  // Bytes the command takes in a data-out phase.
  uint32_t data_out_length(const uint8_t* cdb) const;
  // Execute CDB; data_in receives bytes for data-in phases, data_out supplies
  // bytes for data-out phases (sized by the caller from the CDB).  Returns the
  // SCSI status byte.
  uint8_t execute(const uint8_t* cdb, std::vector<uint8_t>& data_in,
                  const std::vector<uint8_t>& data_out, bool& is_write, uint32_t& out_len);
  uint32_t block_size = 1280, stride = 1536;
  uint64_t blocks = 0;
  std::string vendor = "SYMBOLIC", product = "XL1200 DISK     ", rev = "0001";
  bool cdrom = false;
  // XLEMU_STOP_ON: set once a write carries this text (a scripted batch's
  // results file), so the run can stop when the batch is done.
  std::string watch;
  bool watch_seen = false;

private:
  FILE* f = nullptr;
  uint8_t sense_key = 0, asc = 0;
  uint8_t attention = 0;   // UNIT ATTENTION to report: 0x28 medium changed, 0x29 reset
};

class WD33C93 {
  friend struct ModelState;   // sim/system: copies state into the RTL
  friend struct Snapshot;     // emu/snapshot.cpp: saves and restores the state
public:
  WD33C93();
  void write_reg(int reg, uint8_t v);
  uint8_t read_reg(int reg);       // reg 0x1F = auxiliary status
  bool irq() const { return (asr & 0x80) != 0; }
  void hardware_reset();   // MR pin: chip resets and interrupts with status 0

  // The 'A' part answers a reset with advanced features enabled (own ID bit 3)
  // with status 0x01; the original part always answers 0x00.  The FEP shows
  // "SCSI part WD33C93A" in Show Configuration for the former; the reference
  // XL1201 doesn't, so the original part is the default.
  bool a_part = false;
  ScsiDisk targets[8];
  int own_id = 7;
  // DMA port to the board's buffer memory.
  std::function<uint8_t()> dma_read;
  std::function<void(uint8_t)> dma_write;
  int trace = 0;

private:
  uint8_t regs[0x20];
  uint8_t asr = 0;
  std::deque<uint8_t> pending;   // statuses queued behind the one in the status register
  void command(uint8_t c);
  void interrupt(uint8_t status);   // queue a status; it is presented when INT is clear
  void select_and_transfer(bool atn);
  void data_phase();
  // The target of a Select-and-Transfer stays connected while its data
  // phase waits for a transfer count: the count ran out first (status 0x48 or
  // 0x49, Command Phase 0x46) and the command is resumed at phase 0x45.
  struct Connection {
    bool active = false, out = false;
    int id = 0;
    uint8_t cdb[12] = {};
    uint8_t status = 0;
    std::vector<uint8_t> data;
    uint64_t pos = 0;
  } conn;
  uint32_t count() const { return (regs[0x12] << 16) | (regs[0x13] << 8) | regs[0x14]; }
  void set_count(uint32_t c) { regs[0x12] = c >> 16; regs[0x13] = c >> 8; regs[0x14] = c; }
};
