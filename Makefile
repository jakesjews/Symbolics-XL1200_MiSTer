# Lint the core with Verilator: XL1200.sv and rtl/ (sys/, the MiSTer
# framework, is parsed for its interfaces and not linted; lint/exclusions.vlt).
#   make lint
# The tests that need nothing outside the repository (docs/building.md):
#   make test
VERILATOR ?= verilator

lint: lint-prepare
	$(VERILATOR) --lint-only -Wall -Wno-UNOPTFLAT --timescale-override 1ns/1ps --top-module emu -f lint/rtl.f

lint-prepare:
	@mkdir -p lint/gen
	@printf '`define BUILD_DATE "lint"\n' > lint/gen/build_id.v

# The emulator and its CPU tests, the FPA (the model against the host's IEEE
# arithmetic, the RTL's arithmetic against the model, the RTL on its bus with
# its timing), the 82586 with its mailbox wire, the calendar clock against
# the host's gmtime and the SCSI chip with its disks and CD-ROM drive on
# generated images.
test: lint
	$(MAKE) -C emu
	python3 tools/cputest.py
	$(MAKE) -C sim/fpa VERILATOR=$(VERILATOR)
	cd sim/fpa && ./fpa_test && ./obj_dir/Vxl_fpa_unit && ./obj_bus/Vxl_fpa
	$(MAKE) -C sim/ether VERILATOR=$(VERILATOR)
	cd sim/ether && ./obj_dir/Vtb_ether
	$(MAKE) -C sim/nvram VERILATOR=$(VERILATOR)
	cd sim/nvram && ./obj_dir/Vxl_nvram
	$(MAKE) -C sim/scsi VERILATOR=$(VERILATOR)
	cd sim/scsi && ./obj_dir/Vxl_scsi

.PHONY: lint lint-prepare test
