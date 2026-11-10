# The WD33C93 and its targets (rtl/xl/xl_scsi.sv) driven as Genera's driver
# drives them, on generated images: the CD-ROM drive (INQUIRY, UNIT ATTENTION,
# no disc, a new disc, writes refused), reads split at a transfer count that
# runs out (status 0x49, Command Phase 0x46) and resumed from phase 0x45, the
# same for a disk write, resets while a target waits, and the disks' windows.
#   make && ./obj_dir/Vxl_scsi
VERILATOR ?= verilator
XL := $(abspath ../../rtl/xl)

obj_dir/Vxl_scsi: $(XL)/xl_scsi.sv tb_scsi.cpp ../system/sd_model.h
	$(VERILATOR) --cc --exe --build -j 8 -O2 -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL \
	  -CFLAGS "-std=c++17 -O2 -I$(abspath ../system)" --top-module xl_scsi $(XL)/xl_scsi.sv tb_scsi.cpp

clean:
	rm -rf obj_dir
