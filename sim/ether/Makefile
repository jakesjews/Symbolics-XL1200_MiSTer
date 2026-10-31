# The 82586 with its wire to Main's mailbox (rtl/xl/xl_i82586.sv, xl_eth_hps.sv):
#   make && ./obj_dir/Vtb_ether
VERILATOR ?= verilator
XL := $(abspath ../../rtl/xl)
SV := $(XL)/xl_i82586.sv $(XL)/xl_eth_hps.sv tb_ether.sv
VFLAGS := --cc --exe --build -j 8 -O2 --x-assign fast --x-initial fast \
  -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-BLKSEQ -Wno-MULTIDRIVEN \
  --public-flat-rw --top-module tb_ether

obj_dir/Vtb_ether: $(SV) tb_ether.cpp
	$(VERILATOR) $(VFLAGS) -CFLAGS "-std=c++17 -O2" $(SV) tb_ether.cpp

clean:
	rm -rf obj_dir
