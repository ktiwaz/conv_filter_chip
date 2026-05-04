#- Version 2022-11
###############################################################################
#
# Batch floorplan tcl file
#
# BELOW COMMANDS ARE ONLY SOME POSSIBLE EXAMPLES 
# PLEASE USE THEM AS A GUIDE FOR WRITING YOUR DESIGN SPECIFIC FLOORPLAN FILE
#
# The Innovus command "help" can be used to get more information on any of the
# commands or attributes below:  "help create_floorplan"
#
###############################################################################
read_db ./dbs/init.enc

## use read_db_stop_at_design_in_memory false with caution, for iterative debug only, not in "production":
## set_db read_db_stop_at_design_in_memory false
set_db read_db_stop_at_design_in_memory true

##### Create an initial flooprlan with cell rows
create_floorplan -core_density 1.0 0.60 1.96 1.96 1.96 1.96

read_def ../inputs/dtop_floorplan.def

read_power_intent ./scripts/dtop.cpf -cpf
commit_power_intent

##### Place block pins
set_db current_design .ports.place_status placed

legalize_pins

set_db current_design .ports.place_status fixed

write_db ./dbs/pins_done.enc
write_def ./dtop_floorplan_pins.def -no_std_cells -no_core_cells -no_special_net -no_tracks


add_stripes -nets VPP  -layer MET5 -direction horizontal -width 14.0 -spacing 0.5 -number_of_sets 1 -area {2879.42 -0.55 3458.825 30.3} -start_from bottom -start 15.0 -stop 100.0 -switch_layer_over_obs false -max_same_layer_jog_length 2 -pad_core_ring_top_layer_limit MET5 -pad_core_ring_bottom_layer_limit MET1 -block_ring_top_layer_limit MET5 -block_ring_bottom_layer_limit MET1 -use_wire_group 0 -snap_wire_center_to_grid none
add_stripes -nets VDDO -layer MET5 -direction horizontal -width 14.0 -spacing 0.5 -number_of_sets 1 -area {2875.12 -0.55 3463.125 30.3} -start_from bottom -start  0.0 -stop 100.0 -switch_layer_over_obs false -max_same_layer_jog_length 2 -pad_core_ring_top_layer_limit MET5 -pad_core_ring_bottom_layer_limit MET1 -block_ring_top_layer_limit MET5 -block_ring_bottom_layer_limit MET1 -use_wire_group 0 -snap_wire_center_to_grid none



##### Place stripes

set_db add_stripes_ignore_block_check true
set_db add_stripes_break_at {  block_ring  overlap_ringpin  blocks_without_same_net  }
set_db add_stripes_route_over_rows_only false
set_db add_stripes_rows_without_stripes_only false
set_db add_stripes_extend_to_closest_target none
set_db add_stripes_stop_at_last_wire_for_area true
set_db add_stripes_partial_set_through_domain false
set_db add_stripes_ignore_non_default_domains false
set_db add_stripes_trim_antenna_back_to_shape block_ring
set_db add_stripes_spacing_type edge_to_edge
set_db add_stripes_spacing_from_block 0
set_db add_stripes_stripe_min_length stripe_width
set_db add_stripes_stacked_via_top_layer MET5
set_db add_stripes_stacked_via_bottom_layer MET1
set_db add_stripes_via_using_exact_crossover_size false
set_db add_stripes_split_vias false
set_db add_stripes_orthogonal_only true
set_db add_stripes_allow_jog none
set_db add_stripes_skip_via_on_pin {  standardcell }
set_db add_stripes_skip_via_on_wire_shape {  noshape   }

create_place_blockage -area 3161.645 -0.52 3176.4 369.425 -type hard -name pwrsw_place_block_otp_center

## Left side stripes
add_stripes -nets {vdd vss} -layer MET2 -direction vertical -width 2.3 -spacing 0.3 -set_to_set_distance 100 -start_from left -start   9.0   -stop  910.0 -snap_wire_center_to_grid none

## Left side stripes
add_stripes -nets {vdd vss} -layer MET4 -direction vertical -width 2.3 -spacing 0.3 -set_to_set_distance 100 -start_from left -start   9.0   -stop  910.0 -snap_wire_center_to_grid none

write_db ./dbs/pre_sroute.enc

## remove routing blockages before
eval_legacy { sroute -nets { vdd vss } -connect { blockPin padPin padRing corePin                } -layerChangeRange { MET1(1) MET4(4) } -blockPinTarget { blockring stripe blockpin                      } -connectAlignedBlockAndPadPin { blockPinAsTarget } -padPinPortConnect { allPort allGeom } -padPinTarget { nearestTarget                                    } -corePinTarget { firstAfterRowEnd } -floatingStripeTarget { blockring padring ring stripe ringpin blockpin followpin }                           -blockPinRouteWithPinWidth -allowJogging 0 -crossoverViaLayerRange { MET1(1) MET4(4) } -allowLayerChange 0 -targetViaLayerRange { MET1(1) MET4(4) } -blockPin { onBoundary topBoundary bottomBoundary leftBoundary rightBoundary } -noBlockPinOneAmongOverlappedPins  }

write_db ./dbs/partial_sroute.enc

write_db ./dbs/sroute.enc
write_def ./sroute.def -no_std_cells 
write_floorplan ./sroute.fp
