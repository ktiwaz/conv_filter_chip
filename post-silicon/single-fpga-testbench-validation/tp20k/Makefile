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
#   make sim-sccb   camera init engine + register ROM vs an SCCB monitor
#   make sim-ddrarb DDR3 arbiter + AXI window vs a model of the controller
#   make sim-pvwr   RGB565 capture + preview writer vs a synthetic camera
#   make sim-pvrd   preview reader vs a 720p scan (DDR side out of reset late)
#   make sim-ddrsys all five DDR3 ports on one arbiter (preview, grabber, DMA, bridge window)
#   make sim-cgrab  colour grabber -> DDR3 -> plane DMA vs reference averages
#   The camera initializes itself and goes live after reset (no PC needed);
#   ../scripts/cam_host.py status / grab / init (manual) still work.
#
#   make clean
#
# First: git submodule update --init, then tools/setup.sh (nextpnr + apycula).
#
# Variables: BAUD (default 1000000), PORT (default: autodetect), PY,
#   SEED (nextpnr placement seed for the camera build).
# Needs sv2v (the chip RTL uses unpacked-array ports) and pyserial for the host.
#
# Place-and-route tools are built locally from the pinned submodules
# (../third_party/apicula, ../third_party/nextpnr) by tools/setup.sh, about a
# minute; yosys, sv2v and openFPGALoader come from PATH.

ROOT    := $(abspath ..)
REPO    := $(abspath ../../..)
BUILD   ?= build
PY      ?= $(if $(wildcard $(ROOT)/.venv/bin/python),$(ROOT)/.venv/bin/python,python3)
BAUD    ?= 1000000
CLK_HZ  := 48000000
DEVICE  := GW2A-LV18PG256C8/I7
FAMILY  := GW2A-18C
PORT    ?=
TOOLS   := $(abspath tools)
NEXTPNR := $(TOOLS)/bin/nextpnr-himbaechel
PACK    := $(TOOLS)/venv/bin/gowin_pack
OFL     := $(TOOLS)/bin/openFPGALoader
define check_tools
	@test -x $(NEXTPNR) -a -x $(PACK) -a -x $(OFL) || { echo "local toolchain missing: run tools/setup.sh" >&2; false; }
endef
SEED       ?= 1   # any seed: 10/10 seeds meet 74.25 MHz with >= 15 % margin

BRIDGE  := $(ROOT)/third_party/core_dbg_bridge/src_v
CHIP_SV := $(addprefix $(ROOT)/,$(filter %.sv,$(shell cat $(ROOT)/dut_sources.f)))

RTL := tp20k_top.v \
       $(ROOT)/rtl/fpga_tb_core.v $(ROOT)/rtl/axi4_slave_native.v $(ROOT)/rtl/bram_dp_be.v \
       $(ROOT)/rtl/dut_sequencer.v $(ROOT)/rtl/link_phy.v \
       $(BRIDGE)/dbg_bridge.v $(BRIDGE)/dbg_bridge_uart.v $(BRIDGE)/dbg_bridge_fifo.v \
       $(BUILD)/kernel_rom.v $(BUILD)/chip.v

INIT_FILE := $(ROOT)/input_image_w32.hex
HOST      := $(PY) $(ROOT)/scripts/tb_host.py --baud $(BAUD) $(if $(PORT),--port $(PORT))

.PHONY: all bit program flash sim host-test clean bit-cam program-cam flash-cam sim-grab sim-tmds sim-sccb sim-ddrarb sim-pvwr sim-pvrd sim-ddrsys sim-cgrab
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
	$(check_tools)
	$(NEXTPNR) --json $< --write $@ --device $(DEVICE) \
		--vopt family=$(FAMILY) --vopt cst=tp20k.cst \
		--freq $(shell echo $$(( $(CLK_HZ) / 1000000 ))) \
		-l $(BUILD)/nextpnr.log
	@grep -A30 'Device utilisation' $(BUILD)/nextpnr.log | grep -E 'LUT4|DFF|BSRAM|MULT|ALU|rPLL|IOB' | grep -v ' 0/'
	@grep 'Max frequency' $(BUILD)/nextpnr.log | tail -1

$(BUILD)/tp20k.fs: $(BUILD)/tp20k_pnr.json
	$(PACK) -d $(FAMILY) -o $@ $<

bit: $(BUILD)/tp20k.fs

# SRAM loads first reconfigure from flash over JTAG (RELOAD, openFPGALoader
# --reset): erasing SRAM directly hangs while the camera + DDR3 bitstream is
# running (status stays in edit mode, MEMORY_ERASE never sets) until a power
# cycle; over the flash design it always works.
LOAD  = $(OFL) -b tangprimer20k --reset && sleep 2 && $(OFL) -b tangprimer20k
# SPI flash, read back and compared (our openFPGALoader writes 128-byte chunks)
FLASH = $(OFL) -b tangprimer20k --reset && sleep 2 && $(OFL) -b tangprimer20k -f --verify

program: $(BUILD)/tp20k.fs
	$(LOAD) $<

flash: $(BUILD)/tp20k.fs
	$(check_tools)
	$(FLASH) $<

#--------------------------------------------------
# Camera pipeline
#--------------------------------------------------
CAM_REGS := cam/ov3660_384sq_rgb565.txt
CAM_RTL := tp20k_cam_top.v rtl/hdmi_tx_gowin.v rtl/tmds_encoder.v rtl/sccb_init.v \
           $(ROOT)/rtl/fpga_tb_core.v $(ROOT)/rtl/axi4_slave_native.v $(ROOT)/rtl/bram_dp_be.v \
           $(ROOT)/rtl/dut_sequencer.v $(ROOT)/rtl/link_phy.v \
           $(ROOT)/rtl/video_downscale.v $(ROOT)/rtl/video_frame.v $(ROOT)/rtl/video_out.v \
           $(ROOT)/rtl/video_timing.v $(ROOT)/rtl/text_line.v \
           $(BRIDGE)/dbg_bridge.v $(BRIDGE)/dbg_bridge_uart.v $(BRIDGE)/dbg_bridge_fifo.v \
           $(BUILD)/kernel_rom.v $(BUILD)/font_rom.v $(BUILD)/chip.v $(BUILD)/cam_init_rom.v \
           rtl/ddr_arb.v rtl/axi_ddr.v rtl/async_fifo.v rtl/pix565.v rtl/preview_wr.v \
           rtl/preview_rd.v rtl/cam_compositor.v rtl/rgb_grab.v rtl/plane_dma.v rtl/color_live.v \
           rtl/color_frame.v
# DDR3 (SystemVerilog, gowin-ddr3 submodule + our burst-write patch)
DDR3    := $(ROOT)/third_party/gowin-ddr3
CAM_SV  := rtl/ddr3_sys.sv
CAM_SV_DEPS := $(CAM_SV) $(BUILD)/ddr3/ddr3_ctrl.sv $(BUILD)/ddr3/ddr3_phy_2to1.sv $(wildcard $(DDR3)/ddr3/*.sv $(DDR3)/ddr3/clk/*.sv)

# gowin-ddr3 files we patch (ddr3/*.patch): ddr3_ctrl with BL8 burst writes,
# ddr3_phy_2to1 holding the write data instead of a 9-deep pipeline. The
# copies go to $(BUILD)/ddr3, which comes first on the include path.
$(BUILD)/ddr3/%.sv: $(DDR3)/ddr3/%.sv ddr3/%.patch | $(BUILD)
	mkdir -p $(BUILD)/ddr3
	cp $< $@
	patch -s -p1 -d $(BUILD) < ddr3/$*.patch

$(BUILD)/font_rom.v: $(ROOT)/scripts/gen_font.py | $(BUILD)
	$(PY) $< $@

# Camera register list -> ROM for sccb_init (+ expected writes for sim-sccb)
$(BUILD)/cam_init_rom.v $(BUILD)/cam_init_expected.hex &: $(ROOT)/scripts/gen_cam_rom.py $(CAM_REGS) | $(BUILD)
	$(PY) $< $(CAM_REGS) $(BUILD)/cam_init_rom.v --expected $(BUILD)/cam_init_expected.hex

# Two-step synth_gowin: memories without a ram_style (the font / preset
# ROMs) go to logic. In block RAM their short address paths fail nextpnr's
# hold check at 74.25 MHz.
CAM_CLK_HZ := 46406250   # 371.25 MHz / 8 (tp20k_cam_top's single PLL)
$(BUILD)/cam.json: $(CAM_RTL) $(CAM_SV_DEPS) $(INIT_FILE)
	yosys -q -l $(BUILD)/yosys_cam.log -p "read_verilog -defer $(CAM_RTL); \
		read_verilog -sv -defer -I$(abspath $(BUILD)) -I$(DDR3) $(CAM_SV); \
		hierarchy -top tp20k_cam_top -chparam CLK_HZ $(CAM_CLK_HZ) -chparam BAUD $(BAUD); \
		synth_gowin -top tp20k_cam_top -family gw2a -run :map_ram; \
		setattr -set ram_style \"logic\" t:\$$mem_v2 a:ram_style %d; \
		synth_gowin -top tp20k_cam_top -family gw2a -run map_ram: -json $@"

$(BUILD)/cam_pnr.json: $(BUILD)/cam.json tp20k_cam.cst cam_clocks.py
	$(check_tools)
	$(NEXTPNR) --json $< --write $@ --device $(DEVICE) \
		--vopt family=$(FAMILY) --vopt cst=tp20k_cam.cst --pre-pack cam_clocks.py \
		--seed $(SEED) -l $(BUILD)/nextpnr_cam.log
	@grep -A30 'Device utilisation' $(BUILD)/nextpnr_cam.log | grep -E 'LUT4|DFF|BSRAM|MULT|rPLL' | grep -v ' 0/'
	@grep 'Max frequency' $(BUILD)/nextpnr_cam.log | tail -3

$(BUILD)/cam.fs: $(BUILD)/cam_pnr.json
	$(PACK) -d $(FAMILY) -o $@ $<

bit-cam: $(BUILD)/cam.fs

program-cam: $(BUILD)/cam.fs
	$(LOAD) $<

flash-cam: $(BUILD)/cam.fs
	$(check_tools)
	$(FLASH) $<

sim-tmds: | $(BUILD)
	iverilog -g2012 -o $(BUILD)/tb_tmds.vvp -s tb_tmds sim/tb_tmds.sv rtl/tmds_encoder.v
	vvp -n $(BUILD)/tb_tmds.vvp | tee $(BUILD)/sim_tmds.out
	@grep -q '^PASS' $(BUILD)/sim_tmds.out

sim-pvwr: | $(BUILD)
	iverilog -g2012 -o $(BUILD)/tb_preview_wr.vvp -s tb_preview_wr sim/tb_preview_wr.sv \
		rtl/pix565.v rtl/async_fifo.v rtl/preview_wr.v
	vvp -n $(BUILD)/tb_preview_wr.vvp | tee $(BUILD)/sim_pvwr.out
	@grep -q '^PASS' $(BUILD)/sim_pvwr.out

sim-pvrd: | $(BUILD)
	iverilog -g2012 -o $(BUILD)/tb_preview_rd.vvp -s tb_preview_rd sim/tb_preview_rd.sv rtl/preview_rd.v
	vvp -n $(BUILD)/tb_preview_rd.vvp | tee $(BUILD)/sim_pvrd.out
	@grep -q '^PASS' $(BUILD)/sim_pvrd.out

sim-ddrsys: | $(BUILD)
	iverilog -g2012 -o $(BUILD)/tb_ddr_all.vvp -s tb_ddr_all sim/tb_ddr_all.sv rtl/ddr_arb.v \
		rtl/axi_ddr.v rtl/pix565.v rtl/async_fifo.v rtl/preview_wr.v rtl/rgb_grab.v rtl/plane_dma.v
	vvp -n $(BUILD)/tb_ddr_all.vvp | tee $(BUILD)/sim_ddrsys.out
	@grep -q '^PASS' $(BUILD)/sim_ddrsys.out

sim-cgrab: | $(BUILD)
	iverilog -g2012 -o $(BUILD)/tb_color_grab.vvp -s tb_color_grab sim/tb_color_grab.sv rtl/pix565.v \
		rtl/async_fifo.v rtl/rgb_grab.v rtl/plane_dma.v rtl/ddr_arb.v
	vvp -n $(BUILD)/tb_color_grab.vvp | tee $(BUILD)/sim_cgrab.out
	@grep -q '^PASS' $(BUILD)/sim_cgrab.out

sim-ddrarb: | $(BUILD)
	iverilog -g2012 -o $(BUILD)/tb_ddr_arb.vvp -s tb_ddr_arb sim/tb_ddr_arb.sv rtl/ddr_arb.v rtl/axi_ddr.v
	vvp -n $(BUILD)/tb_ddr_arb.vvp | tee $(BUILD)/sim_ddrarb.out
	@grep -q '^PASS' $(BUILD)/sim_ddrarb.out

sim-sccb: $(BUILD)/cam_init_rom.v $(BUILD)/cam_init_expected.hex
	iverilog -g2012 -o $(BUILD)/tb_sccb_init.vvp -s tb_sccb_init \
		-P tb_sccb_init.EXPECTED=\"$(BUILD)/cam_init_expected.hex\" \
		sim/tb_sccb_init.sv rtl/sccb_init.v $(BUILD)/cam_init_rom.v
	vvp -n $(BUILD)/tb_sccb_init.vvp | tee $(BUILD)/sim_sccb.out
	@grep -q '^PASS' $(BUILD)/sim_sccb.out

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
	rm -rf $(BUILD)
