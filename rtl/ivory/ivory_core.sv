// The Ivory processor with its address translation: ivory_cpu and ivory_mmu,
// with a physical bus (every bus address is physical), and the instruction
// cache's prefetcher sharing the MMU's port with the processor.
module ivory_core
  import ivory_pkg::*;
(
  input  logic        clk,
  input  logic        reset,
  input  logic        run,
  input  logic        hold,

  output logic        bus_req   /*verilator public_flat_rd*/,
  output logic        bus_we,
  output logic [31:0] bus_addr  /*verilator public_flat_rd*/,
  output word_t       bus_wdata,
  input  logic        bus_ack   /*verilator public_flat_rd*/,
  input  word_t       bus_rdata,
  input  logic        bus_buserr,
  input  logic        bus_busy,     // the memory is still filling a line: a prefetch now would wait

  output logic        cop_req,
  output logic        cop_we,
  output logic        cop_wait,
  output logic [9:0]  cop_reg,
  output word_t       cop_wdata,
  input  logic        cop_ack,
  input  word_t       cop_rdata,
  input  logic        cop_err,

  input  logic        hp_sb,
  input  logic        lp_sb,
  input  logic        reset_req,
  output logic        hp_sb_taken,
  output logic        lp_sb_taken,
  input  logic [31:0] usec_clock,

  output logic        retire,
  output logic        retire_counted,
  output logic        halted,
  output logic [1:0]  trap_mode,
  output logic [63:0] insn_count,
  output logic [7:0]  halt_reason,
  output logic [31:0] dbg_pc
);

  logic        mem_req /*verilator public_flat_rd*/, mem_we /*verilator public_flat_rd*/;
  logic        mem_phys /*verilator public_flat_rd*/, mem_ack, mem_buserr, mem_transport;
  logic [31:0] mem_addr /*verilator public_flat_rd*/, mem_bus_pa, mem_pa;
  word_t       mem_wdata, mem_rdata /*verilator public_flat_rd*/;
  logic [11:0] mem_fault;
  logic        ic_hit, ic_fill, icache_on, pf_on;
  logic [3:0]  pf_high;
  logic [31:0] ic_pc_a, ic_pc_b, ic_fill_va, ic_fill_pa;
  logic        ic_sel_a;
  word_t       ic_word, ic_fill_word;
  logic        pf_busy, pf_req /*verilator public_flat_rd*/, port_ack /*verilator public_flat_rd*/;
  logic [31:0] pf_addr /*verilator public_flat_rd*/;
  logic [31:0] pht_base, pht_mask, map_data;
  logic        map_flush, map_load, map_inval, map_reload;
  logic [23:0] map_vpn;

  ivory_cpu cpu (
    .clk, .reset, .run, .hold,
    .dbg_we(1'b0), .dbg_sel(4'd0), .dbg_data('0),
    .mem_req, .mem_we, .mem_phys, .mem_addr, .mem_wdata, .mem_ack, .mem_rdata,
    .mem_fault, .mem_buserr, .mem_bus_pa, .mem_transport, .mem_pa,
    .ic_hit, .ic_word, .ic_fill, .ic_fill_va, .ic_fill_pa, .ic_fill_word,
    .ic_pc_a, .ic_pc_b, .ic_sel_a,
    .icache_on, .pf_on, .pf_high,
    .pht_base_o(pht_base), .pht_mask_o(pht_mask),
    .map_flush, .map_load, .map_inval, .map_vpn, .map_data, .map_reload,
    .cop_req, .cop_we, .cop_wait, .cop_reg, .cop_wdata, .cop_ack, .cop_rdata, .cop_err,
    .hp_sb, .lp_sb, .reset_req, .hp_sb_taken, .lp_sb_taken, .usec_clock,
    .retire, .retire_counted, .halted,
    .trap_mode, .eos(), .zos(), .insn_count, .halt_reason, .dbg_pc
  );

  ivory_icache icache (
    .clk, .reset, .enable(icache_on), .pf_enable(pf_on), .pf_high,
    .pc_a(ic_pc_a), .pc_b(ic_pc_b), .sel_a(ic_sel_a), .hit(ic_hit), .word(ic_word),
    .fill(ic_fill), .fill_va(ic_fill_va), .fill_pa(ic_fill_pa), .fill_word(ic_fill_word),
    .snoop(mem_req && mem_we && (!mem_phys || mem_addr[31:27] == 5'd0)),
    .snoop_va(mem_phys ? {5'h1F, mem_addr[26:0]} : mem_addr),
    .cpu_req(mem_req), .mem_busy(bus_busy), .pf_busy, .pf_req, .pf_addr,
    .pf_ack(port_ack && pf_busy), .pf_rdata(mem_rdata), .pf_err(mem_buserr)
  );
  assign mem_ack = port_ack && !pf_busy;

  // A prefetch owns the port from its request to its ack; the processor's
  // request waits meanwhile and is taken the cycle after
  ivory_mmu mmu (
    .clk, .reset,
    .cpu_req(pf_busy ? pf_req : mem_req), .cpu_we(pf_busy ? 1'b0 : mem_we),
    .cpu_phys(pf_busy ? 1'b1 : mem_phys), .cpu_addr(pf_busy ? pf_addr : mem_addr), .cpu_wdata(mem_wdata),
    .cpu_ack(port_ack), .cpu_rdata(mem_rdata), .cpu_fault(mem_fault), .cpu_buserr(mem_buserr),
    .cpu_bus_pa(mem_bus_pa), .cpu_transport(mem_transport), .cpu_pa(mem_pa),
    .pht_base, .pht_mask, .map_flush, .map_load, .map_inval, .map_vpn, .map_data, .map_reload,
    .bus_req, .bus_we, .bus_addr, .bus_wdata, .bus_ack, .bus_rdata, .bus_buserr
  );

endmodule
