#!/usr/bin/env bash
# Batch xsim run of tb_fpga_core. Expects Vivado's settings64.sh to be sourced.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/build/sim"
mkdir -p "$work"
cd "$work"

mapfile -t dut_srcs < <(grep -vE '^\s*(#|$)' "$root/dut_sources.f" | sed "s|^|$root/|")

xvlog --sv "${dut_srcs[@]}" "$root"/rtl/*.v "$root/sim/tb_fpga_core.sv"
xelab tb_fpga_core -s tb_fpga_core_sim -timescale 1ns/1ps \
      -generic_top "INIT_FILE=$root/input_image_w32.hex" \
      -generic_top "IMAGE_FILE=$root/input_image.hex" \
      -generic_top "TESTCASE_ROOT=$root/../../testcases/5x5"
xsim tb_fpga_core_sim -R | tee sim.out
grep -q '^PASS' sim.out
