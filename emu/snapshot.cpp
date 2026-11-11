#include "snapshot.h"
#include <cstdio>
#include <cstring>
#include <deque>
#include <map>
#include <vector>
#include "machine.h"

namespace {
// Version 03 adds the CD-ROM drive and the WD33C93's connection; a version
// 02 snapshot still loads, those left as the machine was built.  Version 04
// has the same fields: its stack cache lower bound and overflow limit moved
// with the pushes, as the core's do, and an older one's are brought there
// when it loads.
const char MAGIC[8] = {'X', 'L', 'S', 'N', 'A', 'P', '0', '4'};
const char MAGIC_03[8] = {'X', 'L', 'S', 'N', 'A', 'P', '0', '3'};
const char MAGIC_02[8] = {'X', 'L', 'S', 'N', 'A', 'P', '0', '2'};

struct Out {
  FILE* f;
  int version = 4;
  bool ok = true;
  void raw(const void* p, size_t n) { if (fwrite(p, 1, n, f) != n) ok = false; }
  template <class T> void pod(const T& v) { raw(&v, sizeof v); }
  template <class T> void arr(const T* p, size_t n) { raw(p, n * sizeof(T)); }
  template <class T> void vec(const std::vector<T>& v) { uint64_t n = v.size(); pod(n); if (n) raw(v.data(), n * sizeof(T)); }
  template <class T> void deq(const std::deque<T>& d) { uint64_t n = d.size(); pod(n); for (const T& x : d) pod(x); }
  template <class K, class V> void map(const std::map<K, V>& m) { uint64_t n = m.size(); pod(n); for (auto& kv : m) { pod(kv.first); pod(kv.second); } }
  void str(const std::string& s) { uint64_t n = s.size(); pod(n); raw(s.data(), n); }
};
struct In {
  FILE* f;
  int version = 4;
  bool ok = true;
  void raw(void* p, size_t n) { if (fread(p, 1, n, f) != n) ok = false; }
  template <class T> void pod(T& v) { raw(&v, sizeof v); }
  template <class T> void arr(T* p, size_t n) { raw(p, n * sizeof(T)); }
  template <class T> void vec(std::vector<T>& v) { uint64_t n = 0; pod(n); v.resize(n); if (n) raw(v.data(), n * sizeof(T)); }
  template <class T> void deq(std::deque<T>& d) { uint64_t n = 0; pod(n); d.clear(); for (uint64_t i = 0; i < n; i++) { T x; pod(x); d.push_back(x); } }
  template <class K, class V> void map(std::map<K, V>& m) { uint64_t n = 0; pod(n); m.clear(); for (uint64_t i = 0; i < n; i++) { K k; V v; pod(k); pod(v); m[k] = v; } }
  void str(std::string& s) { uint64_t n = 0; pod(n); s.resize(n); raw(&s[0], n); }
};

}  // namespace

// One function body for both directions: S is Out or In, and each field is
// visited in the same order.  A nested struct of Snapshot, so the classes'
// friend declarations cover it.
struct Snapshot::V {
template <class S> static void visit(S& s, Ivory& c) {
  s.pod(c.halted); s.str(c.halt_reason); s.pod(c.pushing_trap_frame);
  s.pod(c.pc); s.pod(c.sp); s.pod(c.fp); s.pod(c.lp); s.pod(c.cont); s.pod(c.cr);
  s.arr(c.bar, 4); s.pod(c.alu_control); s.pod(c.rotate_latch);
  s.pod(c.ephemeral_oldspace); s.pod(c.zone_oldspace); s.pod(c.fp_coprocessor_present);
  s.pod(c.preempt_register); s.pod(c.icache_control); s.pod(c.prefetcher_control);
  s.pod(c.map_cache_control); s.pod(c.memory_control);
  s.pod(c.stack_cache_lower_bound); s.pod(c.stack_cache_overflow_limit); s.pod(c.entry_max_args);
  s.pod(c.event_count); s.pod(c.binding_stack_pointer); s.pod(c.catch_block_list);
  s.pod(c.control_stack_limit); s.pod(c.control_stack_extra_limit); s.pod(c.binding_stack_limit);
  s.pod(c.pht_base); s.pod(c.pht_mask); s.pod(c.count_map_reloads);
  s.pod(c.list_cache_area); s.pod(c.list_cache_address); s.pod(c.list_cache_length);
  s.pod(c.structure_cache_area); s.pod(c.structure_cache_address); s.pod(c.structure_cache_length);
  s.pod(c.dynamic_binding_cache_base); s.pod(c.dynamic_binding_cache_mask);
  s.pod(c.choice_pointer); s.pod(c.structure_stack_choice_pointer);
  s.pod(c.fep_mode_trap_vector_address); s.pod(c.mapping_table_cache); s.pod(c.mapping_table_length);
  s.pod(c.stack_frame_maximum_size); s.pod(c.stack_cache_dump_quantum);
  s.arr(c.scratch, 01000); s.pod(c.chip_revision);
  s.pod(c.icount); s.pod(c.trap_count); s.pod(c.last_trap_vector); s.pod(c.last_vma);
  s.arr(c.map, Ivory::MAP_SIZE);
  s.pod(c.err_detail);
  // per-instruction scratch and the instruction buffer, so a resume continues exactly
  s.pod(c.cur_opcode); s.pod(c.inst_pc); s.pod(c.next_pc); s.pod(c.operand_mode); s.pod(c.operand_popped);
  s.pod(c.restart_sp); s.pod(c.pc_changed); s.pod(c.ib_valid); s.pod(c.ib_addr); s.pod(c.ib_word);
}

template <class S> static void visit(S& s, Nvram& n) {
  s.arr(n.mem, Nvram::SIZE); s.pod(n.dirty); s.pod(n.frozen); s.pod(n.writing); s.pod(n.offset_seconds);
}
template <class S> static void visit(S& s, ScsiDisk& d) {
  s.pod(d.block_size); s.pod(d.stride); s.pod(d.blocks); s.pod(d.sense_key); s.pod(d.asc);
  if (s.version >= 3) s.pod(d.attention);
}
template <class S> static void visit(S& s, WD33C93& w) {
  s.pod(w.a_part); s.pod(w.own_id); s.arr(w.regs, 0x20); s.pod(w.asr); s.deq(w.pending); s.pod(w.trace);
  for (int i = 0; i < 8; i++) visit(s, w.targets[i]);
  if (s.version >= 3) {
    s.pod(w.conn.active); s.pod(w.conn.out); s.pod(w.conn.id); s.arr(w.conn.cdb, 12); s.pod(w.conn.status);
    s.vec(w.conn.data); s.pod(w.conn.pos);
  }
}
template <class S> static void visit(S& s, I82586& e) {
  s.pod(e.in_reset); s.pod(e.ca); s.pod(e.need_init); s.pod(e.scb); s.pod(e.stat); s.pod(e.cus); s.pod(e.rus);
  s.pod(e.cbl); s.pod(e.scb_base);
}
template <class S> static void visit(S& s, Console& c) {
  s.pod(c.switchpack); s.pod(c.brightness); s.pod(c.volume); s.deq(c.out); s.vec(c.cmd); s.vec(c.keys_down);
}
template <class S> static void visit(S& s, IoBoard& b) {
  s.vec(b.buffer); s.vec(b.video);
  visit(s, b.ether); s.pod(b.ether_pins);
  visit(s, b.scsi);
  visit(s, b.console);
  s.pod(b.video_control); s.vec(b.sync_program); s.pod(b.sync_address); s.pod(b.frame_counter);
  s.arr(b.idprom, 32); s.pod(b.polled_latch); s.arr(b.duscc, 0x40);
  for (int i = 0; i < 4; i++) {
    s.pod(b.dma[i].base_addr); s.pod(b.dma[i].base_count); s.pod(b.dma[i].addr); s.pod(b.dma[i].count);
    s.pod(b.dma[i].mode); s.pod(b.dma[i].masked);
  }
  s.pod(b.dma_flipflop); s.pod(b.dma_command); s.pod(b.dma_status); s.pod(b.next_console_byte);
  s.pod(b.dma_control); s.arr(b.dma_regs, 4); s.pod(b.dma_byte_addr);
  s.map(b.regs);
}
template <class S> static void visit(S& s, Pit82C54& p) {
  for (int i = 0; i < 3; i++) {
    s.pod(p.c[i].mode); s.pod(p.c[i].rw); s.pod(p.c[i].msb_next); s.pod(p.c[i].reload); s.pod(p.c[i].value);
    s.pod(p.c[i].pending); s.pod(p.c[i].counting); s.pod(p.c[i].out);
  }
}
template <class S> static void visit(S& s, Wtl3164& f) {
  s.pod(f.r0h); s.pod(f.r0l); s.pod(f.r1h); s.pod(f.r1l); s.pod(f.r2h); s.pod(f.r2l); s.pod(f.cond);
  s.arr(f.sr, 12); s.pod(f.operations);
}
template <class S> static void visit(S& s, Machine& m) {
  s.vec(m.ram);
  visit(s, m.nvram);
  visit(s, m.iob);
  visit(s, m.pit);
  visit(s, m.fpa);
  s.pod(m.fpa_fitted); s.pod(m.interrupt_mask); s.pod(m.hp_sb); s.pod(m.lp_sb);
  s.pod(m.cycles); s.pod(m.pit_usec);
  s.map(m.io_regs);
}
};

bool Snapshot::save(const std::string& path, Ivory& cpu, Machine& m) {
  FILE* f = fopen(path.c_str(), "wb");
  if (!f) { perror(path.c_str()); return false; }
  Out o{f};
  o.raw(MAGIC, 8);
  V::visit(o, cpu);
  V::visit(o, m);
  fclose(f);
  return o.ok;
}

bool Snapshot::load(const std::string& path, Ivory& cpu, Machine& m) {
  FILE* f = fopen(path.c_str(), "rb");
  if (!f) { perror(path.c_str()); return false; }
  In i{f};
  char magic[8];
  i.raw(magic, 8);
  if (memcmp(magic, MAGIC_02, 8) == 0) i.version = 2;
  else if (memcmp(magic, MAGIC_03, 8) == 0) i.version = 3;
  else if (memcmp(magic, MAGIC, 8) != 0) { fprintf(stderr, "%s: not a snapshot\n", path.c_str()); fclose(f); return false; }
  V::visit(i, cpu);
  V::visit(i, m);
  fclose(f);
  cpu.iv_phase = 0;   // error-log detail of the last instruction
  if (i.version < 4) cpu.sc_normalize();
  return i.ok;
}
