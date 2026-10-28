# Non-project Vivado flow for the FPGA testbench (single board, or tester +
# DUT board connected through the RPi header).
#
#   make fetch-ip     fetch Digilent rgb2dvi/dvi2rgb sources (HDMI) into third_party/
#   make ip           generate vendor IP (clk_wiz, ila, jtag_axi, ila_dut) into ip/
#   make bit          tester bitstream   -> build/tester/testbench.{bit,ltx}
#   make bit-dut      DUT board bitstream -> build/dut/dut_board.{bit,ltx}
#   make sim          xsim self-checking testbench (internal and external DUT)
#   make program      program the tester board   (tester_serial in boards.local.tcl)
#   make program-dut  program the DUT board      (dut_serial in boards.local.tcl)
#   make program-all  both
#   make list-boards  show connected boards (JTAG serials) and their roles
#   make pinout       board-to-board wiring table
#   make hw           interactive Vivado Tcl shell with tcl/hw_access.tcl loaded
#   make clean        remove build/ (make distclean also removes ip/)
#   make env          show how Vivado will be found and run
#
# Vivado environment (auto-detected; override in local.mk or on the command line):
#   - DISTROBOX: run Vivado inside this distrobox container. Defaults to
#     "vivado" if such a container exists (and we're not already inside one),
#     otherwise empty: Vivado runs natively.
#   - XILINX_SETTINGS: settings64.sh to source. Defaults to the first one found
#     in the usual install locations for VIVADO_VERSION; if none is found,
#     Vivado must already be on PATH (e.g. settings64.sh sourced in your shell).
# Example local.mk (not in git):  XILINX_SETTINGS = /opt/amd/2026.1/Vivado/settings64.sh

-include local.mk

VIVADO_VERSION ?= 2026.1

# (origin, not ifndef: an explicitly empty value must stay empty)
ifeq ($(origin DISTROBOX),undefined)
DISTROBOX := $(if $(wildcard /run/.containerenv),,$(shell command -v distrobox >/dev/null 2>&1 && \
	distrobox list 2>/dev/null | awk -F'|' '{gsub(/ /, "", $$2)} $$2 == "vivado" {print "vivado"; exit}'))
endif

ifeq ($(origin XILINX_SETTINGS),undefined)
XILINX_SETTINGS := $(firstword $(wildcard \
	$(HOME)/.local/Xilinx/$(VIVADO_VERSION)/Vivado/settings64.sh \
	$(HOME)/Xilinx/$(VIVADO_VERSION)/Vivado/settings64.sh \
	/tools/Xilinx/$(VIVADO_VERSION)/Vivado/settings64.sh \
	/opt/Xilinx/$(VIVADO_VERSION)/Vivado/settings64.sh \
	/opt/amd/$(VIVADO_VERSION)/Vivado/settings64.sh \
	$(HOME)/Xilinx/Vivado/$(VIVADO_VERSION)/settings64.sh \
	/tools/Xilinx/Vivado/$(VIVADO_VERSION)/settings64.sh \
	/opt/Xilinx/Vivado/$(VIVADO_VERSION)/settings64.sh))
endif

ifeq ($(strip $(DISTROBOX)),)
RUN = bash -c
else
RUN = distrobox enter $(DISTROBOX) -- bash -c
endif

# Prefix for every command that needs Vivado's tools on PATH ($(EMPTY) keeps
# the trailing space)
EMPTY :=
ifneq ($(strip $(XILINX_SETTINGS)),)
VIVADO_ENV = source $(XILINX_SETTINGS) && $(EMPTY)
else
VIVADO_ENV = { command -v vivado >/dev/null || { echo "Vivado not found: source its settings64.sh or set XILINX_SETTINGS (see the top of the Makefile)" >&2; exit 1; }; } && $(EMPTY)
endif

ROOT  := $(CURDIR)
BUILD := $(ROOT)/build
PY    ?= python3

# $(call vivado,<script>,<extra args>)
vivado = $(RUN) '$(VIVADO_ENV)mkdir -p $(BUILD) && cd $(BUILD) && \
	vivado -mode batch -nojournal -log $(BUILD)/$(1).log -source $(ROOT)/tcl/$(1).tcl $(2)'

RTL      := $(wildcard rtl/*.v) rtl/edid_720p.data dut_sources.f $(wildcard ../../hardware/src/*.sv) \
            testbench.xdc tcl/build.tcl tcl/common.tcl tcl/link_pins.tcl tcl/hdmi_pins.tcl
IP_STAMP := ip/.generated
BIT      := $(BUILD)/tester/testbench.bit
BIT_DUT  := $(BUILD)/dut/dut_board.bit
DIGILENT := third_party/vivado-library/License.txt
TESTCASES := ../../testcases/5x5
GEN_RTL  := rtl/kernel_rom.v rtl/font_rom.v

.PHONY: all env fetch-ip ip bit bit-dut sim program program-dut program-all list-boards pinout hw clean distclean

all: bit

env:
	@echo "DISTROBOX       = $(if $(strip $(DISTROBOX)),$(DISTROBOX) (Vivado runs in this container),(none: Vivado runs natively))"
	@echo "XILINX_SETTINGS = $(if $(strip $(XILINX_SETTINGS)),$(XILINX_SETTINGS),(none: Vivado must already be on PATH))"
	@$(RUN) '$(VIVADO_ENV) echo "vivado          = $$(command -v vivado)"'

fetch-ip: $(DIGILENT)
$(DIGILENT): third_party/fetch_digilent.sh
	third_party/fetch_digilent.sh

ip: $(IP_STAMP)
$(IP_STAMP): tcl/gen_ip.tcl tcl/common.tcl
	$(call vivado,gen_ip)
	touch $@

input_image_w32.hex: input_image.hex scripts/img_tool.py
	$(PY) scripts/img_tool.py pack $< $@

# Generated RTL. Not in git: the repo-root .gitignore excludes **_rom.v.
rtl/kernel_rom.v: scripts/gen_kernel_rom.py $(wildcard $(TESTCASES)/*/kernel.hex $(TESTCASES)/*/config.yml)
	$(PY) scripts/gen_kernel_rom.py $(TESTCASES) $@

rtl/font_rom.v: scripts/gen_font.py
	$(PY) scripts/gen_font.py $@

bit: $(BIT)
$(BIT): $(IP_STAMP) $(DIGILENT) $(RTL) $(GEN_RTL) testbench.v input_image_w32.hex
	$(call vivado,build,-tclargs tester)
	@grep -h '^TIMING\|^IOB' $(BUILD)/build.log

bit-dut: $(BIT_DUT)
$(BIT_DUT): $(IP_STAMP) $(RTL) $(GEN_RTL) dut_board.v
	$(RUN) '$(VIVADO_ENV)mkdir -p $(BUILD) && cd $(BUILD) && \
		vivado -mode batch -nojournal -log $(BUILD)/build_dut.log -source $(ROOT)/tcl/build.tcl -tclargs dut'
	@grep -h '^TIMING\|^IOB' $(BUILD)/build_dut.log

sim: input_image_w32.hex $(GEN_RTL)
	$(RUN) '$(VIVADO_ENV)$(ROOT)/sim/run_sim.sh'

program: $(BIT)
	$(call vivado,program,-tclargs tester)

program-dut: $(BIT_DUT)
	$(RUN) '$(VIVADO_ENV)mkdir -p $(BUILD) && cd $(BUILD) && \
		vivado -mode batch -nojournal -log $(BUILD)/program_dut.log -source $(ROOT)/tcl/program.tcl -tclargs dut'

program-all: program-dut program

list-boards:
	$(RUN) '$(VIVADO_ENV)mkdir -p $(BUILD) && cd $(BUILD) && \
		vivado -mode batch -notrace -nojournal -log $(BUILD)/list_boards.log -source $(ROOT)/tcl/list_boards.tcl' \
		| grep -E "^localhost|xilinx_tcf|ERROR|WARNING: boards"

pinout:
	@echo 'source tcl/link_pins.tcl; link_pinout' | tclsh

hw:
	$(RUN) '$(VIVADO_ENV)mkdir -p $(BUILD) && cd $(BUILD) && \
		vivado -mode tcl -notrace -nojournal -log $(BUILD)/hw.log -source $(ROOT)/tcl/hw_access.tcl -tclargs connect'

clean:
	rm -rf $(BUILD) .Xil

distclean: clean
	rm -rf ip
