# Lint the core with Verilator: XL1200.sv and rtl/ (sys/, the MiSTer
# framework, is parsed for its interfaces and not linted; lint/exclusions.vlt).
#   make lint
VERILATOR ?= verilator

lint: lint-prepare
	$(VERILATOR) --lint-only -Wall -Wno-UNOPTFLAT --timescale-override 1ns/1ps --top-module emu -f lint/rtl.f

lint-prepare:
	@mkdir -p lint/gen
	@printf '`define BUILD_DATE "lint"\n' > lint/gen/build_id.v

.PHONY: lint lint-prepare
