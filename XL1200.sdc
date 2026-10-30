derive_pll_clocks
derive_clock_uncertainty

# core specific constraints
# Between the processor clock and the dot clock: the video settings, which
# change only while the FEP programs the SCN2674, and synchronized status bits
# (the line counter crosses as Gray code).
set_false_path -from [get_clocks {emu|pll|pll_inst|altera_pll_i|*[0].*|divclk}] -to [get_clocks {emu|pll|pll_inst|altera_pll_i|*[1].*|divclk}]
set_false_path -from [get_clocks {emu|pll|pll_inst|altera_pll_i|*[1].*|divclk}] -to [get_clocks {emu|pll|pll_inst|altera_pll_i|*[0].*|divclk}]
