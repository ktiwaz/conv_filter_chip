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
#   make pinout-pdf   the same as a printable PDF: docs/two_fpga_pinout.pdf
#   make hw           interactive Vivado Tcl shell with tcl/hw_access.tcl loaded
#
# I/O timing lab (one board, loopback wiring; see tcl/iolab_pins.tcl):
#   make bit-iolab     IOLAB_WIRING=pmod8|pmod8_rev|pmod_fwd|jumper IOLAB_MHZ=25|50|62|83|100
#   make program-iolab (same variables; programs the tester_serial board)
#   make iolab-pinout  wiring table for IOLAB_WIRING
#   make sim-iolab     xsim of the sweep engine with modelled wire delays
#   make hw-iolab      Vivado Tcl shell with tcl/iolab_access.tcl loaded
#   make clean        remove build/ (make distclean also removes ip/)
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

RTL      := $(wildcard rtl/*.v) rtl/edid_720p.data dut_sources.f $(wildcard ../../hardware/src/*.sv) \
            testbench.xdc tcl/build.tcl tcl/common.tcl tcl/link_pins.tcl tcl/hdmi_pins.tcl
IP_STAMP := ip/.generated
BIT      := $(BUILD)/tester/testbench.bit
BIT_DUT  := $(BUILD)/dut/dut_board.bit
DIGILENT := third_party/vivado-library/License.txt

IOLAB_WIRING ?= pmod8
IOLAB_MHZ    ?= 25
IOLAB_DIR    := $(BUILD)/iolab_$(IOLAB_WIRING)_$(IOLAB_MHZ)
BIT_IOLAB    := $(IOLAB_DIR)/iolab.bit
IOLAB_SRC    := iolab.v iolab_board.v rtl/iolab_core.v rtl/axi4_slave_native.v rtl/bram_dp_be.v \
                tcl/iolab_pins.tcl tcl/build.tcl tcl/common.tcl testbench.xdc

.PHONY: bit-iolab program-iolab iolab-pinout sim-iolab hw-iolab
.PHONY: all fetch-ip ip bit pinout-pdf bit-dut sim program program-dut program-all list-boards pinout hw clean distclean

all: bit

fetch-ip: $(DIGILENT)
$(DIGILENT): third_party/fetch_digilent.sh
	third_party/fetch_digilent.sh

ip: $(IP_STAMP)
$(IP_STAMP): tcl/gen_ip.tcl tcl/common.tcl
	$(call vivado,gen_ip)
	touch $@

input_image_w32.hex: input_image.hex scripts/img_tool.py
	$(PY) scripts/img_tool.py pack $< $@

bit: $(BIT)
$(BIT): $(IP_STAMP) $(DIGILENT) $(RTL) testbench.v input_image_w32.hex
	$(call vivado,build,-tclargs tester)
	@grep -h '^TIMING\|^IOB' $(BUILD)/build.log

bit-dut: $(BIT_DUT)
$(BIT_DUT): $(IP_STAMP) $(RTL) dut_board.v
	$(RUN) 'source $(XILINX_SETTINGS) && mkdir -p $(BUILD) && cd $(BUILD) && \
		vivado -mode batch -nojournal -log $(BUILD)/build_dut.log -source $(ROOT)/tcl/build.tcl -tclargs dut'
	@grep -h '^TIMING\|^IOB' $(BUILD)/build_dut.log

sim: input_image_w32.hex
	$(RUN) 'source $(XILINX_SETTINGS) && $(ROOT)/sim/run_sim.sh'

program: $(BIT)
	$(call vivado,program,-tclargs tester)

program-dut: $(BIT_DUT)
	$(RUN) 'source $(XILINX_SETTINGS) && mkdir -p $(BUILD) && cd $(BUILD) && \
		vivado -mode batch -nojournal -log $(BUILD)/program_dut.log -source $(ROOT)/tcl/program.tcl -tclargs dut'

program-all: program-dut program

list-boards:
	$(RUN) 'source $(XILINX_SETTINGS) && mkdir -p $(BUILD) && cd $(BUILD) && \
		vivado -mode batch -notrace -nojournal -log $(BUILD)/list_boards.log -source $(ROOT)/tcl/list_boards.tcl' \
		| grep -E "^localhost|xilinx_tcf|ERROR|WARNING: boards"

pinout:
	@echo 'source tcl/link_pins.tcl; link_pinout' | tclsh

bit-iolab: $(BIT_IOLAB)
$(BIT_IOLAB): $(IP_STAMP) $(IOLAB_SRC)
	$(RUN) 'source $(XILINX_SETTINGS) && mkdir -p $(BUILD) && cd $(BUILD) && \
		vivado -mode batch -nojournal -log $(BUILD)/build_iolab_$(IOLAB_WIRING)_$(IOLAB_MHZ).log -source $(ROOT)/tcl/build.tcl \
		-tclargs iolab $(IOLAB_WIRING) $(IOLAB_MHZ)'
	@grep -h '^TIMING\|^IOB' $(BUILD)/build_iolab_$(IOLAB_WIRING)_$(IOLAB_MHZ).log

program-iolab: $(BIT_IOLAB)
	$(RUN) 'source $(XILINX_SETTINGS) && mkdir -p $(BUILD) && cd $(BUILD) && \
		vivado -mode batch -nojournal -log $(BUILD)/program_iolab.log -source $(ROOT)/tcl/program.tcl \
		-tclargs iolab $(IOLAB_WIRING) $(IOLAB_MHZ)'

iolab-pinout:
	@echo 'source tcl/iolab_pins.tcl; iolab_pinout $(IOLAB_WIRING)' | tclsh

sim-iolab:
	$(RUN) 'source $(XILINX_SETTINGS) && $(ROOT)/sim/run_iolab_sim.sh'

hw-iolab:
	$(RUN) 'source $(XILINX_SETTINGS) && mkdir -p $(BUILD) && cd $(BUILD) && \
		vivado -mode tcl -notrace -nojournal -log $(BUILD)/hw_iolab.log -source $(ROOT)/tcl/iolab_access.tcl -tclargs connect'

pinout-pdf: docs/two_fpga_pinout.pdf
docs/two_fpga_pinout.pdf: tcl/link_pins.tcl scripts/gen_pinout_pdf.py
	@mkdir -p docs
	$(PY) scripts/gen_pinout_pdf.py $< $@

hw:
	$(RUN) 'source $(XILINX_SETTINGS) && mkdir -p $(BUILD) && cd $(BUILD) && \
		vivado -mode tcl -notrace -nojournal -log $(BUILD)/hw.log -source $(ROOT)/tcl/hw_access.tcl -tclargs connect'

clean:
	rm -rf $(BUILD) .Xil

distclean: clean
	rm -rf ip
