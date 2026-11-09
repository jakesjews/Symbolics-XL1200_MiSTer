# The calendar clock (rtl/xl/xl_nvram.sv) against the host's gmtime: MiSTer's
# timestamp converted to the MK48T02's BCD registers, with and without the 28
# years back; the running clock across the ends of days, months and years;
# the machine setting the clock itself.
#   make && ./obj_dir/Vxl_nvram
VERILATOR ?= verilator
XL := $(abspath ../../rtl/xl)

obj_dir/Vxl_nvram: $(XL)/xl_nvram.sv tb_nvram.cpp
	$(VERILATOR) --cc --exe --build -j 8 -O2 -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL \
	  -CFLAGS "-std=c++17 -O2" --top-module xl_nvram $(XL)/xl_nvram.sv tb_nvram.cpp

clean:
	rm -rf obj_dir
