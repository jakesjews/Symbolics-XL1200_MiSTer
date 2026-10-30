// The Ivory processor with its address translation: ivory_cpu and ivory_mmu,
// with a physical bus (every bus address is physical).
module ivory_core
  import ivory_pkg::*;
(
  input  logic        clk,
  input  logic        reset,
  input  logic        run,
  input  logic        hold,

  output logic        bus_req,
  output logic        bus_we,
  output logic [31:0] bus_addr,
  output word_t       bus_wdata,
  input  logic        bus_ack,
  input  word_t       bus_rdata,
  input  logic        bus_buserr,

  output logic        cop_req,
  output logic        cop_we,
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

  logic        mem_req, mem_we, mem_phys, mem_ack, mem_buserr, mem_transport;
  logic [31:0] mem_addr, mem_bus_pa;
  word_t       mem_wdata, mem_rdata;
  logic [11:0] mem_fault;
  logic [31:0] pht_base, pht_mask, map_data;
  logic        map_flush, map_load, map_inval, map_reload;
  logic [23:0] map_vpn;

  ivory_cpu cpu (
    .clk, .reset, .run, .hold,
    .dbg_we(1'b0), .dbg_sel(4'd0), .dbg_data('0),
    .mem_req, .mem_we, .mem_phys, .mem_addr, .mem_wdata, .mem_ack, .mem_rdata,
    .mem_fault, .mem_buserr, .mem_bus_pa, .mem_transport,
    .pht_base_o(pht_base), .pht_mask_o(pht_mask),
    .map_flush, .map_load, .map_inval, .map_vpn, .map_data, .map_reload,
    .cop_req, .cop_we, .cop_reg, .cop_wdata, .cop_ack, .cop_rdata, .cop_err,
    .hp_sb, .lp_sb, .reset_req, .hp_sb_taken, .lp_sb_taken, .usec_clock,
    .retire, .retire_counted, .halted,
    .trap_mode, .eos(), .zos(), .insn_count, .halt_reason, .dbg_pc
  );

  ivory_mmu mmu (
    .clk, .reset,
    .cpu_req(mem_req), .cpu_we(mem_we), .cpu_phys(mem_phys), .cpu_addr(mem_addr), .cpu_wdata(mem_wdata),
    .cpu_ack(mem_ack), .cpu_rdata(mem_rdata), .cpu_fault(mem_fault), .cpu_buserr(mem_buserr),
    .cpu_bus_pa(mem_bus_pa), .cpu_transport(mem_transport),
    .pht_base, .pht_mask, .map_flush, .map_load, .map_inval, .map_vpn, .map_data, .map_reload,
    .bus_req, .bus_we, .bus_addr, .bus_wdata, .bus_ack, .bus_rdata, .bus_buserr
  );

endmodule
