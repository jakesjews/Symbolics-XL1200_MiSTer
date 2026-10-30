# The FPA's arithmetic: emu/fpa.cpp against the host's IEEE floating point
# (fpa_test), and rtl/xl/xl_fpa_unit.sv against emu/fpa.cpp (Vxl_fpa_unit).
#   make && ./fpa_test && ./obj_dir/Vxl_fpa_unit
VERILATOR ?= verilator
EMU := $(abspath ../../emu)
XL := $(abspath ../../rtl/xl)

all: fpa_test obj_dir/Vxl_fpa_unit

fpa_test: fpa_test.cpp $(EMU)/fpa.cpp $(EMU)/fpa.h
	$(CXX) -std=c++17 -O2 -frounding-math -I$(EMU) fpa_test.cpp $(EMU)/fpa.cpp -o $@

obj_dir/Vxl_fpa_unit: $(XL)/xl_fpa_unit.sv tb_fpa_unit.cpp $(EMU)/fpa.cpp $(EMU)/fpa.h
	$(VERILATOR) --cc --exe --build -j 8 -O3 -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL \
	  -CFLAGS "-std=c++17 -O2 -I$(EMU)" --top-module xl_fpa_unit $(XL)/xl_fpa_unit.sv \
	  tb_fpa_unit.cpp $(EMU)/fpa.cpp

clean:
	rm -rf obj_dir fpa_test
