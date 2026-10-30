# System lockstep test of the RTL XL1200 (rtl/xl) against the C++ model (emu/).
#   make            build obj_dir/Vxl_machine (lockstep) and obj_free/Vxl_machine (as on the MiSTer)
#   ./obj_dir/Vxl_machine DISK.dd [STEPS] [TYPE-AT TEXT] [SCREEN.pgm]
#   ./obj_free/Vxl_machine DISK.dd SECONDS [AT-SECONDS TEXT] [SCREEN.pgm]
VERILATOR ?= verilator
EMU := $(abspath ../../emu)
IVORY := $(abspath ../../rtl/ivory)
XL := $(abspath ../../rtl/xl)
MEM := $(abspath ../mem)
PROM := $(XL)/boot_prom.mem

SV := $(IVORY)/ivory_pkg.sv $(IVORY)/ivory_cpu.sv $(XL)/xl_mem.sv $(XL)/xl_scsi.sv $(XL)/xl_console.sv \
      $(XL)/xl_video.sv $(XL)/xl_iob.sv $(XL)/xl_nvram.sv $(XL)/xl_machine.sv
SVH := $(wildcard $(IVORY)/*.svh)
CPP := tb_system.cpp $(EMU)/machine.cpp $(EMU)/nvram.cpp $(EMU)/pit.cpp $(EMU)/scsi.cpp $(EMU)/ioboard.cpp \
       $(EMU)/console.cpp $(EMU)/cpu_core.cpp $(EMU)/cpu_insn.cpp

VFLAGS := --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast --noassert \
  -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-MULTIDRIVEN -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
  -Wno-BLKSEQ -I$(IVORY) -I$(XL) --top-module xl_machine

all: obj_dir/Vxl_machine obj_free/Vxl_machine

obj_dir/Vxl_machine: $(SV) $(SVH) $(CPP) $(PROM) $(wildcard $(EMU)/*.h) $(MEM)/ddr_model.h
	python3 ../../tools/gen_ivory_states.py
	$(VERILATOR) $(VFLAGS) -GLOCKSTEP=1 -GMEM_CLEAR=0 -GPROM_FILE='"$(PROM)"' \
	  -CFLAGS "-std=c++17 -O2 -I$(EMU) -I$(MEM) -DPROM_PATH='\"$(PROM)\"'" $(SV) $(CPP)

obj_free/Vxl_machine: $(SV) $(SVH) tb_free.cpp sd_model.h $(PROM) $(MEM)/ddr_model.h
	python3 ../../tools/gen_ivory_states.py
	$(VERILATOR) $(VFLAGS) --Mdir obj_free -GPROM_FILE='"$(PROM)"' \
	  -CFLAGS "-std=c++17 -O2 -I$(EMU) -I$(MEM)" $(SV) tb_free.cpp

clean:
	rm -rf obj_dir obj_free
