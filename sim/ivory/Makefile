# Lockstep test of the RTL Ivory and its MMU (rtl/ivory) against the C++ model (emu/).
#   make            build obj_dir/Vivory_core
#   ./obj_dir/Vivory_core PROM.mem DISK.dd [STEPS] [TYPE-AT TEXT]   (both run the XL1200 from reset)
VERILATOR ?= verilator
EMU := $(abspath ../../emu)
RTL := $(abspath ../../rtl/ivory)

SV := $(RTL)/ivory_pkg.sv $(RTL)/ivory_cpu.sv $(RTL)/ivory_mmu.sv $(RTL)/ivory_core.sv
SVH := $(wildcard $(RTL)/*.svh)
CPP := tb_lockstep.cpp $(EMU)/machine.cpp $(EMU)/nvram.cpp $(EMU)/pit.cpp $(EMU)/scsi.cpp $(EMU)/i82586.cpp $(EMU)/ioboard.cpp \
       $(EMU)/console.cpp $(EMU)/cpu_core.cpp $(EMU)/cpu_insn.cpp

obj_dir/Vivory_core: $(SV) $(SVH) $(CPP) $(wildcard $(EMU)/*.h)
	python3 ../../tools/gen_ivory_states.py
	$(VERILATOR) --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast --noassert \
	  -Wno-fatal -Wno-WIDTHTRUNC -Wno-MULTIDRIVEN -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
	  -I$(RTL) -CFLAGS "-std=c++17 -O2 -I$(EMU)" \
	  --top-module ivory_core $(SV) $(CPP)

clean:
	rm -rf obj_dir
