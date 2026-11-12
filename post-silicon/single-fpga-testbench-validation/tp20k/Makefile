# Open-source flow for the Sipeed Tang Primer 20K (GW2A-LV18PG256C8/I7):
# yosys -> nextpnr-himbaechel -> gowin_pack -> openFPGALoader.
#
#   make bit        bitstream -> build/tp20k.fs
#   make program    load into SRAM (lost on power cycle)
#   make flash      write to the onboard SPI flash
#   make sim        Icarus simulation through the UART (tb_tp20k.sv)
#   make host-test  selftest + every 5x5 golden testcase on the board
#
# Camera -> DUT -> 720p HDMI pipeline (tp20k_cam_top; the tester works on it too):
#   make bit-cam / program-cam / flash-cam    build/cam.fs
#   make sim-grab   grabber in its camera configuration vs a reference model
#   make sim-tmds   TMDS encoder vs a reference decoder
#   then: ../scripts/cam_host.py init && ../scripts/cam_host.py live on
#   make bit-cam-gowin / program-cam-gowin   same design with Gowin EDA (cross-check)
#
#   make clean
#
# Variables: BAUD (default 1000000), PORT (default: autodetect), PY,
#   SEED (nextpnr placement seed for the camera build), GOWIN_HOME.
# Needs sv2v (the chip RTL uses unpacked-array ports) and pyserial for the host.
#
# apycula <= 0.35 needs upstream fix 993faec (YosysHQ/apicula#576): in a bank
# with true-LVDS outputs and an ordinary output, it configured every
# single-ended pin as LVDS25, which kills the 27 MHz clock input next to the
# HDMI pairs. Until a release has it, delete the line
#   bank_desc.set_attr("IO_TYPE", default_io_type)
# under "if bank_desc.has_true_lvds_outputs:" in check_io_banks() of the
# installed apycula/gowin_pack.py. The pack rules check for it.

ROOT    := $(abspath ..)
REPO    := $(abspath ../../..)
BUILD   ?= build
PY      ?= $(if $(wildcard $(ROOT)/.venv/bin/python),$(ROOT)/.venv/bin/python,python3)
BAUD    ?= 1000000
CLK_HZ  := 48000000
DEVICE  := GW2A-LV18PG256C8/I7
FAMILY  := GW2A-18C
PORT    ?=
GOWIN_PACK ?= $(or $(shell command -v gowin_pack),$(wildcard $(HOME)/.venvs/apycula/bin/gowin_pack),gowin_pack)
# apycula's Python (next to gowin_pack) locates the installed gowin_pack.py
APYCULA_PY ?= $(dir $(GOWIN_PACK))python
PACK       := $(GOWIN_PACK)
# Fails if the installed gowin_pack still has the YosysHQ/apicula#576 bug
define check_pack_fix
	@$(APYCULA_PY) -c "import apycula.gowin_pack as g, inspect, re, sys; \
	src = inspect.getsource(g.Device.check_io_banks); \
	bad = re.search(r'has_true_lvds_outputs:\n(.*\n){2}\s*bank_desc.set_attr\(\"IO_TYPE\", default_io_type\)', src); \
	sys.exit('gowin_pack lacks apicula fix 993faec (#576): single-ended I/O next to TLVDS would be packed as LVDS25. See the Makefile header.' if bad else 0)"
endef
SEED       ?= 1   # any seed: 10/10 seeds meet 74.25 MHz with >= 15 % margin
GOWIN_HOME ?= $(HOME)/.local/Gowin_EDA
# Gowin's bundled FreeType breaks the system fontconfig; no display for gw_sh
GW_SH      := QT_QPA_PLATFORM=minimal LD_PRELOAD=/usr/lib/libfreetype.so.6 $(GOWIN_HOME)/IDE/bin/gw_sh

BRIDGE  := $(ROOT)/third_party/core_dbg_bridge/src_v
CHIP_SV := $(addprefix $(ROOT)/,$(filter %.sv,$(shell cat $(ROOT)/dut_sources.f)))

RTL := tp20k_top.v \
       $(ROOT)/rtl/fpga_tb_core.v $(ROOT)/rtl/axi4_slave_native.v $(ROOT)/rtl/bram_dp_be.v \
       $(ROOT)/rtl/dut_sequencer.v $(ROOT)/rtl/link_phy.v \
       $(BRIDGE)/dbg_bridge.v $(BRIDGE)/dbg_bridge_uart.v $(BRIDGE)/dbg_bridge_fifo.v \
       $(BUILD)/kernel_rom.v $(BUILD)/chip.v

INIT_FILE := $(ROOT)/input_image_w32.hex
HOST      := $(PY) $(ROOT)/scripts/tb_host.py --baud $(BAUD) $(if $(PORT),--port $(PORT))

.PHONY: all bit program flash sim host-test clean bit-cam program-cam flash-cam sim-grab bit-cam-gowin program-cam-gowin sim-tmds
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
	$(check_pack_fix)
	$(PACK) -d $(FAMILY) -o $@ $<

bit: $(BUILD)/tp20k.fs

program: $(BUILD)/tp20k.fs
	openFPGALoader -b tangprimer20k $<

flash: $(BUILD)/tp20k.fs
	openFPGALoader -b tangprimer20k -f $<

#--------------------------------------------------
# Camera pipeline
#--------------------------------------------------
CAM_RTL := tp20k_cam_top.v rtl/hdmi_tx_gowin.v rtl/tmds_encoder.v \
           $(ROOT)/rtl/fpga_tb_core.v $(ROOT)/rtl/axi4_slave_native.v $(ROOT)/rtl/bram_dp_be.v \
           $(ROOT)/rtl/dut_sequencer.v $(ROOT)/rtl/link_phy.v \
           $(ROOT)/rtl/video_downscale.v $(ROOT)/rtl/video_frame.v $(ROOT)/rtl/video_out.v \
           $(ROOT)/rtl/video_timing.v $(ROOT)/rtl/text_line.v \
           $(BRIDGE)/dbg_bridge.v $(BRIDGE)/dbg_bridge_uart.v $(BRIDGE)/dbg_bridge_fifo.v \
           $(BUILD)/kernel_rom.v $(BUILD)/font_rom.v $(BUILD)/chip.v

$(BUILD)/font_rom.v: $(ROOT)/scripts/gen_font.py | $(BUILD)
	$(PY) $< $@

# Two-step synth_gowin: memories without a ram_style (the font / preset
# ROMs) go to logic. In block RAM their short address paths fail nextpnr's
# hold check at 74.25 MHz.
CAM_CLK_HZ := 46406250   # 371.25 MHz / 8 (tp20k_cam_top's single PLL)
$(BUILD)/cam.json: $(CAM_RTL) $(INIT_FILE)
	yosys -q -l $(BUILD)/yosys_cam.log -p "read_verilog -defer $(CAM_RTL); \
		hierarchy -top tp20k_cam_top -chparam CLK_HZ $(CAM_CLK_HZ) -chparam BAUD $(BAUD); \
		synth_gowin -top tp20k_cam_top -family gw2a -run :map_ram; \
		setattr -set ram_style \"logic\" t:\$$mem_v2 a:ram_style %d; \
		synth_gowin -top tp20k_cam_top -family gw2a -run map_ram: -json $@"

$(BUILD)/cam_pnr.json: $(BUILD)/cam.json tp20k_cam.cst cam_clocks.py
	nextpnr-himbaechel --json $< --write $@ --device $(DEVICE) \
		--vopt family=$(FAMILY) --vopt cst=tp20k_cam.cst --pre-pack cam_clocks.py \
		--seed $(SEED) -l $(BUILD)/nextpnr_cam.log
	@grep -A30 'Device utilisation' $(BUILD)/nextpnr_cam.log | grep -E 'LUT4|DFF|BSRAM|MULT|rPLL' | grep -v ' 0/'
	@grep 'Max frequency' $(BUILD)/nextpnr_cam.log | tail -3

$(BUILD)/cam.fs: $(BUILD)/cam_pnr.json
	$(check_pack_fix)
	$(PACK) -d $(FAMILY) -o $@ $<

bit-cam: $(BUILD)/cam.fs

program-cam: $(BUILD)/cam.fs
	openFPGALoader -b tangprimer20k $<

flash-cam: $(BUILD)/cam.fs
	openFPGALoader -b tangprimer20k -f $<

# Gowin EDA build of the same design (gowin/cam.tcl): writes impl/pnr/tp20k_cam.fs
GOWIN_FS := impl/pnr/tp20k_cam.fs
$(GOWIN_FS): $(CAM_RTL) $(INIT_FILE) gowin/cam.tcl gowin/tp20k_cam_gowin.cst gowin/tp20k_cam.sdc
	rm -rf impl
	$(GW_SH) gowin/cam.tcl > $(BUILD)/gowin_cam.log 2>&1 || (grep -E '^ERROR' $(BUILD)/gowin_cam.log; false)
	@test -f $@

bit-cam-gowin: $(GOWIN_FS)

program-cam-gowin: $(GOWIN_FS)
	openFPGALoader -b tangprimer20k $<

sim-tmds: | $(BUILD)
	iverilog -g2012 -o $(BUILD)/tb_tmds.vvp -s tb_tmds sim/tb_tmds.sv rtl/tmds_encoder.v
	vvp -n $(BUILD)/tb_tmds.vvp | tee $(BUILD)/sim_tmds.out
	@grep -q '^PASS' $(BUILD)/sim_tmds.out

sim-grab: | $(BUILD)
	iverilog -g2012 -o $(BUILD)/tb_cam_grab.vvp -s tb_cam_grab sim/tb_cam_grab.sv $(ROOT)/rtl/video_downscale.v
	vvp -n $(BUILD)/tb_cam_grab.vvp | tee $(BUILD)/sim_grab.out
	@grep -q '^PASS' $(BUILD)/sim_grab.out

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
	rm -rf $(BUILD) impl
