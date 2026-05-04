#- Load PDK specific variables
source -quiet ./scripts/innovus_config.tcl
set_db current_flow "floorplan" 

#- Setting to avoid creating new assign statements during optimization
set_db init_delete_assigns true

#- Standalone mode so create a new database from verilog, mmmc, and cpf
read_mmmc ./scripts/mmmc_config.tcl

read_physical -lef <point to LEF files>
read_netlist ../synthesis/outputs/dtop_pre_layout.v

set cpf_file ./scripts/dtop.cpf
read_power_intent $cpf_file -cpf

# Library lef does not contain all the required routing vias so router must generate vias
add_route_via_defs

init_design

commit_power_intent

#- Remove incoming assign statements from netlist first without using buffers 
delete_assigns

#- Now allow buffers to remove any remaining assign statements
delete_assigns -add_buffer -prefix pd_assign

#- Set don't use on cells listed in attribute (by default includes all unselected components from CAPS)
foreach dont_use_cell [get_db <list of cells not to use>] {
    set_db [get_db base_cells -if ".base_name == $dont_use_cell"] .dont_use true
}

#- Fplan step should turn off si
set_db delaycal_enable_si false
set_db extract_rc_engine pre_route

#- Make a intermediate database save right before floorplanning
write_db ./dbs/init.enc


