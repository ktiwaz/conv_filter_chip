# DDR3 burst memory test + throughput (gowin-ddr3 fast PHY, BL8 write patch).
#   make            build/top.fs      (needs ../tools/setup.sh)
#   make program    SRAM; the report is on the debugger UART at 115200 8N1
TOOLS  := $(abspath ../tools)
DDR3   := $(abspath ../../third_party/gowin-ddr3)
BUILD  := build
NEXTPNR := $(TOOLS)/bin/nextpnr-himbaechel
PACK    := $(TOOLS)/venv/bin/gowin_pack

all: $(BUILD)/top.fs

# our patched gowin-ddr3 files (../ddr3/*.patch), found before the submodule's
$(BUILD)/ddr3/%.sv: $(DDR3)/ddr3/%.sv ../ddr3/%.patch
	mkdir -p $(BUILD)/ddr3
	cp $< $@
	patch -s -p1 -d $(BUILD) < ../ddr3/$*.patch

$(BUILD)/synth.json: top.sv ddr3_burst_test.sv $(BUILD)/ddr3/ddr3_ctrl.sv $(BUILD)/ddr3/ddr3_phy_2to1.sv $(wildcard $(DDR3)/ddr3/*.sv)
	yosys -q -p "read -incdir $(abspath $(BUILD)); read -incdir $(DDR3); read -incdir $(DDR3)/examples; \
		read -incdir $(CURDIR); read_verilog -sv top.sv; hierarchy -top top; synth_gowin -family gw2a -json $@"

$(BUILD)/pnr.json: $(BUILD)/synth.json
	$(NEXTPNR) --json $< --write $@ --device GW2A-LV18PG256C8/I7 --vopt family=GW2A-18C \
		--vopt cst=$(DDR3)/examples/tang-primer-20k.cst --freq 108 -l $(BUILD)/nextpnr.log
	@grep 'Max frequency' $(BUILD)/nextpnr.log | tail -1

$(BUILD)/top.fs: $(BUILD)/pnr.json
	$(PACK) -d GW2A-18C -o $@ $<

OFL     := $(TOOLS)/bin/openFPGALoader

# reconfigure from flash first, as tp20k/Makefile's program targets do
program: $(BUILD)/top.fs
	$(OFL) -b tangprimer20k --reset && sleep 2 && $(OFL) -b tangprimer20k $<

clean:
	rm -rf $(BUILD)

.PHONY: all program clean
