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

#- Create report dir (if necessary)
file mkdir ./reports/fplan

#- Make a intermediate database save right before floorplanning
write_db ./dbs/init.enc

##MS run batchfp.tcl manually and create sroute.fp
# Load the user floorplan script
#source ./scripts/batchfp.tcl
read_floorplan ./sroute.fp

#- generate tracks after creating floorplan
add_tracks

#- Insert tap cells if required by library and simple checkerboard is desired
#- Need to temporarily change add_filler_keep_fixed or delete_filler will not work
set prev_keep_fixed_attr [get_db add_fillers_keep_fixed]
set_db add_fillers_keep_fixed false
delete_filler -cells [get_db athena_tap_cells]
set_db add_fillers_keep_fixed $prev_keep_fixed_attr
foreach domain [get_db power_domains .name] {
    add_well_taps -cell [get_db athena_tap_cells] -cell_interval [get_db athena_tap_interval] -start_row 1 -prefix WELLTAP -checker_board -power_domain $domain
}
check_well_taps -cells [get_db athena_tap_cells] -max_distance [expr [get_db athena_tap_interval]/2] -report reports/dtop_welltap.rpt


set report_path "./reports/fplan"

#- Insert isolation ring if enabled
if {[get_db athena_insert_isolation_ring] == "yes"} {
    athena_insert_isolation_ring -rpt $report_path
}

#- Insert buffer ring if enabled
if {[get_db athena_insert_buffer_ring] == "yes"} {
    athena_insert_buffer_ring -input_buffer [get_db athena_input_net_buffer] \
         -output_buffer [get_db athena_output_net_buffer] -rpt $report_path
}

#- Isolate output ports if enabled
if {[get_db athena_isolate_output_ports] == "yes"} {
    athena_isolate_output_ports -buffer [get_db athena_output_net_buffer] -cts_buffer [get_db cts_buffer_cells] -rpt $report_path
}

# Check timing constraints for consistency and completeness
check_timing > ./reports/fplan/check_timing.rpt

check_power_domains -lib_cell_binding -global_connection -always_on_bias -nets_missing_iso -nets_missing_shifter -retention -drc_file ./reports/fplan/check_power_domains.drc
check_design -type {power_intent} -out_file ./reports/fplan/check_design.rpt

#- Generate reports
report_area -out_file ./reports/fplan/area.summary.rpt -min_count 1000
report_summary -out_file ./reports/fplan/summary.rpt

#- Update the timer for hold and write reports
time_design -expanded_views -hold -pre_place -report_dir debug
#- Reports that describe timing health
report_constraint -all_violators -early > ./reports/fplan/hold.all_violators.rpt
report_analysis_summary -early -merged_groups > ./reports/fplan/hold.analysis_summary.rpt
report_timing -early -max_paths 5 -path_type endpoint > ./reports/fplan/hold.start_end_slack.rpt
#- Reports that show detailed timing with Graph based analysis
report_timing -early -max_paths 1 -nworst 1 -path_type full_clock -net > ./reports/fplan/hold.worst_max_path.rpt
report_timing -early -max_paths 500 -nworst 1 -path_type full_clock > ./reports/fplan/hold.gba_500_paths.rpt
#- Update the timer for setup and write reports
time_design -expanded_views -pre_place -report_dir debug
#- Reports that describe timing health
report_constraint -all_violators > ./reports/fplan/setup.all_violators.rpt
report_analysis_summary -merged_groups > ./reports/fplan/setup.analysis_summary.rpt
report_timing -late -path_type endpoint -max_paths 5 > ./reports/fplan/setup.start_end_slack.rpt
#- Reports that show detailed timing with Graph based analysis
report_timing -late -max_paths 1 -nworst 1 -path_type full_clock -net > ./reports/fplan/setup.worst_max_path.rpt
report_timing -late -max_paths 500 -nworst 1 -path_type full_clock > ./reports/fplan/setup.gba_500_paths.rpt

#- Reset the opt_size_only_file setting to avoid errors on future db reads
reset_db opt_size_only_file

#- Save the database
write_db ./dbs/fplan.enc

