# Open-source flow for the Sipeed Tang Primer 20K (GW2A-LV18PG256C8/I7):
# yosys -> nextpnr-himbaechel -> gowin_pack -> openFPGALoader.
#
#   make bit        bitstream -> build/tp20k.fs
#   make program    load into SRAM (lost on power cycle)
#   make flash      write to the onboard SPI flash
#   make sim        Icarus simulation through the UART (tb_tp20k.sv)
#   make host-test  selftest + every 5x5 golden testcase on the board
#   make clean
#
# Variables: BAUD (default 1000000), PORT (default: autodetect), PY.
# Needs sv2v (the chip RTL uses unpacked-array ports) and pyserial for the host.

ROOT    := $(abspath ..)
REPO    := $(abspath ../../..)
BUILD   ?= build
PY      ?= $(if $(wildcard $(ROOT)/.venv/bin/python),$(ROOT)/.venv/bin/python,python3)
BAUD    ?= 1000000
CLK_HZ  := 48000000
DEVICE  := GW2A-LV18PG256C8/I7
FAMILY  := GW2A-18C
PORT    ?=

BRIDGE  := $(ROOT)/third_party/core_dbg_bridge/src_v
CHIP_SV := $(addprefix $(ROOT)/,$(filter %.sv,$(shell cat $(ROOT)/dut_sources.f)))

RTL := tp20k_top.v \
       $(ROOT)/rtl/fpga_tb_core.v $(ROOT)/rtl/axi4_slave_native.v $(ROOT)/rtl/bram_dp_be.v \
       $(ROOT)/rtl/dut_sequencer.v $(ROOT)/rtl/link_phy.v \
       $(BRIDGE)/dbg_bridge.v $(BRIDGE)/dbg_bridge_uart.v $(BRIDGE)/dbg_bridge_fifo.v \
       $(BUILD)/kernel_rom.v $(BUILD)/chip.v

INIT_FILE := $(ROOT)/input_image_w32.hex
HOST      := $(PY) $(ROOT)/scripts/tb_host.py --baud $(BAUD) $(if $(PORT),--port $(PORT))

.PHONY: all bit program flash sim host-test clean
all: bit

$(BUILD):
	mkdir -p $@

# Filter presets (order: sorted testcases/5x5, as in tcl/hw_access.tcl)
$(BUILD)/kernel_rom.v: $(ROOT)/scripts/gen_kernel_rom.py $(wildcard $(REPO)/testcases/5x5/*/*) | $(BUILD)
	$(PY) $< $(REPO)/testcases/5x5 $@

# Chip RTL -> Verilog-2005 (yosys can't read unpacked-array ports)
$(BUILD)/chip.v: $(CHIP_SV) $(ROOT)/dut_sources.f | $(BUILD)
	sv2v $(CHIP_SV) > $@

$(INIT_FILE): $(ROOT)/input_image.hex $(ROOT)/scripts/img_tool.py
	$(PY) $(ROOT)/scripts/img_tool.py pack $< $@

# Runs in this directory: tp20k_top's INIT_FILE default is relative to it
$(BUILD)/tp20k.json: $(RTL) $(INIT_FILE)
	yosys -q -l $(BUILD)/yosys.log -p "read_verilog -defer $(RTL); \
		hierarchy -top tp20k_top -chparam CLK_HZ $(CLK_HZ) -chparam BAUD $(BAUD); \
		synth_gowin -top tp20k_top -family gw2a -json $@"

$(BUILD)/tp20k_pnr.json: $(BUILD)/tp20k.json tp20k.cst
	nextpnr-himbaechel --json $< --write $@ --device $(DEVICE) \
		--vopt family=$(FAMILY) --vopt cst=tp20k.cst \
		--freq $(shell echo $$(( $(CLK_HZ) / 1000000 ))) \
		-l $(BUILD)/nextpnr.log
	@grep -A30 'Device utilisation' $(BUILD)/nextpnr.log | grep -E 'LUT4|DFF|BSRAM|MULT|ALU|rPLL|IOB' | grep -v ' 0/'
	@grep 'Max frequency' $(BUILD)/nextpnr.log | tail -1

$(BUILD)/tp20k.fs: $(BUILD)/tp20k_pnr.json
	gowin_pack -d $(FAMILY) -o $@ $<

bit: $(BUILD)/tp20k.fs

program: $(BUILD)/tp20k.fs
	openFPGALoader -b tangprimer20k $<

flash: $(BUILD)/tp20k.fs
	openFPGALoader -b tangprimer20k -f $<

# Simulation: 48 MHz clock straight in (no rPLL), 3 Mbaud UART
SIM_SRC := sim/tb_tp20k.sv
$(BUILD)/tb_tp20k.vvp: $(RTL) $(SIM_SRC) $(INIT_FILE)
	iverilog -g2012 -o $@ -s tb_tp20k \
		-P tb_tp20k.INIT_FILE=\"$(INIT_FILE)\" \
		-P tb_tp20k.TESTCASES=\"$(REPO)/testcases/5x5\" \
		$(RTL) $(SIM_SRC)

sim: $(BUILD)/tb_tp20k.vvp
	cd $(BUILD) && vvp -n tb_tp20k.vvp | tee sim.out
	@grep -q '^PASS' $(BUILD)/sim.out

host-test:
	$(HOST) selftest
	$(HOST) run-all

clean:
	rm -rf $(BUILD)
