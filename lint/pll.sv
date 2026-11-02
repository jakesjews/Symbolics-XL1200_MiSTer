// Lint-only interface for rtl/pll.v, the Quartus PLL (50 MHz and 80 MHz
// from the board's 50 MHz).  No implementation: never for simulation.
module pll (
	input  wire refclk,
	input  wire rst,
	output wire outclk_0,
	output wire outclk_1
);
endmodule
