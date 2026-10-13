#!/bin/bash

# 
# Vivado(TM)
# runme.sh: a Vivado-generated Runs Script for UNIX
# Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
# Copyright 2022-2026 Advanced Micro Devices, Inc. All Rights Reserved.
# 

if [ -z "$PATH" ]; then
  PATH=/home/ktiwaz/.local/Xilinx/2026.1/Vitis/bin:/home/ktiwaz/.local/Xilinx/2026.1/Vivado/ids_lite/ISE/bin/lin64:/home/ktiwaz/.local/Xilinx/2026.1/Vivado/bin
else
  PATH=/home/ktiwaz/.local/Xilinx/2026.1/Vitis/bin:/home/ktiwaz/.local/Xilinx/2026.1/Vivado/ids_lite/ISE/bin/lin64:/home/ktiwaz/.local/Xilinx/2026.1/Vivado/bin:$PATH
fi
export PATH

if [ -z "$LD_LIBRARY_PATH" ]; then
  LD_LIBRARY_PATH=
else
  LD_LIBRARY_PATH=:$LD_LIBRARY_PATH
fi
export LD_LIBRARY_PATH

HD_PWD='/home/ktiwaz/Projects/Tapeout/conv_filter_chip/post-silicon/single-fpga-testbench-validation/simple-fpga-testbench-validation/simple-fpga-testbench-validation.runs/impl_1'
cd "$HD_PWD"

HD_LOG=runme.log
/bin/touch $HD_LOG

ISEStep="./ISEWrap.sh"
EAStep()
{
     $ISEStep $HD_LOG "$@" >> $HD_LOG 2>&1
     if [ $? -ne 0 ]
     then
         exit
     fi
}

# pre-commands:
/bin/touch .write_bitstream.begin.rst
EAStep vivado -log testbench.vdi -applog -m64 -product Vivado -messageDb vivado.pb -mode batch -source testbench.tcl -notrace


