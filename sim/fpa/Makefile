# The FPA's arithmetic: emu/fpa.cpp against the host's IEEE floating point
# (fpa_test), rtl/xl/xl_fpa_unit.sv against emu/fpa.cpp (Vxl_fpa_unit), and
# rtl/xl/xl_fpa.sv on its bus against the model's Wtl3164, with its timing
# (Vxl_fpa).
#   make && ./fpa_test && ./obj_dir/Vxl_fpa_unit && ./obj_bus/Vxl_fpa
VERILATOR ?= verilator
EMU := $(abspath ../../emu)
XL := $(abspath ../../rtl/xl)

all: fpa_test obj_dir/Vxl_fpa_unit obj_bus/Vxl_fpa

fpa_test: fpa_test.cpp $(EMU)/fpa.cpp $(EMU)/fpa.h
	$(CXX) -std=c++17 -O2 -frounding-math -I$(EMU) fpa_test.cpp $(EMU)/fpa.cpp -o $@

obj_dir/Vxl_fpa_unit: $(XL)/xl_fpa_unit.sv tb_fpa_unit.cpp $(EMU)/fpa.cpp $(EMU)/fpa.h
	$(VERILATOR) --cc --exe --build -j 8 -O3 -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL \
	  -CFLAGS "-std=c++17 -O2 -I$(EMU)" --top-module xl_fpa_unit $(XL)/xl_fpa_unit.sv \
	  tb_fpa_unit.cpp $(EMU)/fpa.cpp

obj_bus/Vxl_fpa: $(XL)/xl_fpa_unit.sv $(XL)/xl_fpa.sv tb_fpa_bus.cpp $(EMU)/fpa.cpp $(EMU)/fpa.h
	$(VERILATOR) --cc --exe --build -j 8 -O3 -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL \
	  --Mdir obj_bus -CFLAGS "-std=c++17 -O2 -I$(EMU)" --top-module xl_fpa $(abspath ../../rtl/ivory/ivory_pkg.sv) \
	  $(XL)/xl_fpa_unit.sv $(XL)/xl_fpa.sv tb_fpa_bus.cpp $(EMU)/fpa.cpp

clean:
	rm -rf obj_dir obj_bus fpa_test
