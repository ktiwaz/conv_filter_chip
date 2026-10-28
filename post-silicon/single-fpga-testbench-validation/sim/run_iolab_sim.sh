#!/usr/bin/env bash
# Batch xsim run of tb_iolab (MMCM/ODDR/BUFG from the UNISIM library).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/build/sim_iolab"
mkdir -p "$work"
cd "$work"
xvlog --sv -i "$root/sim" "$XILINX_VIVADO/data/verilog/src/glbl.v" \
      "$root/rtl/iolab_core.v" "$root/rtl/axi4_slave_native.v" "$root/rtl/bram_dp_be.v" \
      "$root/iolab_board.v" "$root/sim/tb_iolab.sv"
xelab tb_iolab glbl -L unisims_ver -s tb_iolab_sim -timescale 1ns/1ps
xsim tb_iolab_sim -R | tee sim.out
grep -q '^PASS' sim.out
