# conv_filter_chip
Repository for the convolutional filter chip designed by Group 1 in EE209A/B at UCLA

## Directory Structure
- hardware/src: Contains SystemVerilog files for synthesis
- testbench: Contains SystemVerilog testbenches, other test modules (drivers, sinks), and yml files for RTL simulation with hammer flow.
- ee209-hammer-internal: Contains hammer installation. top.sv instantiates the top-level hardware module, and test.yml points to all source files and timing constraints.

## Usage
Must be run on a UCLA eeapps server machine (license paths are fixed). 
- For RTL simulation, enter the ee209-hammer-internal directory and run `make -f Makefile.flow sim TB_CFGS="/path/to/testbench.yml"`. Replace the path with the relative path of the .yml config of the testbench you would like to run.
- For synthesis, enter the ee209-hammer-internal directory and run `make -f Makefile.flow syn`
- For place&route, enter the ee209-hammer-internal directory and run `make -f Makefile.flow par
