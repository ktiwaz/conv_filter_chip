# Non-project Vivado flow for the single-FPGA testbench.
#
#   make ip       generate vendor IP (clk_wiz, ila, jtag_axi) into ip/
#   make bit      synth + impl + bitstream -> build/testbench.{bit,ltx}
#   make sim      xsim self-checking testbench of fpga_tb_core
#   make program  program the board over JTAG
#   make hw       interactive Vivado Tcl shell with tcl/hw_access.tcl loaded
#   make clean    remove build/ (make distclean also removes ip/)
#
# Vivado runs inside the "vivado" distrobox by default. Inside the container
# (or with a native install) DISTROBOX is empty and Vivado runs directly.

XILINX_SETTINGS ?= $(HOME)/.local/Xilinx/2026.1/Vivado/settings64.sh
DISTROBOX       ?= $(if $(wildcard /run/.containerenv),,vivado)

ifeq ($(strip $(DISTROBOX)),)
RUN = bash -c
else
RUN = distrobox enter $(DISTROBOX) -- bash -c
endif

ROOT  := $(CURDIR)
BUILD := $(ROOT)/build
PY    ?= python3

# $(call vivado,<script>,<extra args>)
vivado = $(RUN) 'source $(XILINX_SETTINGS) && mkdir -p $(BUILD) && cd $(BUILD) && \
	vivado -mode batch -nojournal -log $(BUILD)/$(1).log -source $(ROOT)/tcl/$(1).tcl $(2)'

RTL      := testbench.v $(wildcard rtl/*.v)
IP_STAMP := ip/.generated
BIT      := $(BUILD)/testbench.bit

.PHONY: all ip bit sim program hw clean distclean

all: bit

ip: $(IP_STAMP)
$(IP_STAMP): tcl/gen_ip.tcl tcl/common.tcl
	$(call vivado,gen_ip)
	touch $@

input_image_w32.hex: input_image.hex scripts/img_tool.py
	$(PY) scripts/img_tool.py pack $< $@

bit: $(BIT)
$(BIT): $(IP_STAMP) $(RTL) testbench.xdc input_image_w32.hex tcl/build.tcl tcl/common.tcl
	$(call vivado,build)
	@grep -h '^TIMING' $(BUILD)/build.log

sim: input_image_w32.hex
	$(RUN) 'source $(XILINX_SETTINGS) && $(ROOT)/sim/run_sim.sh'

program: $(BIT)
	$(call vivado,program)

hw:
	$(RUN) 'source $(XILINX_SETTINGS) && mkdir -p $(BUILD) && cd $(BUILD) && \
		vivado -mode tcl -notrace -nojournal -log $(BUILD)/hw.log -source $(ROOT)/tcl/hw_access.tcl -tclargs connect'

clean:
	rm -rf $(BUILD) .Xil

distclean: clean
	rm -rf ip
