#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
#  TSMC N180RF plugin for Hammer.
#
#  See LICENSE for licence details.

import sys
import re
import os, shutil
from pathlib import Path
from typing import NamedTuple, List, Optional, Tuple, Dict, Set, Any

import hammer_tech
from hammer_tech import HammerTechnology
from hammer_vlsi import HammerTool, HammerPlaceAndRouteTool, TCLTool, HammerDRCTool, HammerLVSTool, HammerToolHookAction

import specialcells
from specialcells import CellType, SpecialCell

class TSMCN180RFTech(HammerTechnology):
    """
    Override the HammerTechnology used in `hammer_tech.py`
    This class is loaded by function `load_from_json`, and will pass the `try` in `importlib`.
    """
    def post_install_script(self) -> None:
        self.library_name = 'tcb018gbwp7t'
        # check whether variables were overriden to point to a valid path
        self.use_openram = False
        self.use_nda_files = False
        print('Loaded TSMC N180RF Tech')

    def get_tech_par_hooks(self, tool_name: str) -> List[HammerToolHookAction]:
        return [
            HammerTool.make_post_insertion_hook("init_design",tsmc180_innovus_settings),
            HammerTool.make_pre_insertion_hook("place_tap_cells", tsmc180_add_endcaps)
            ]

def tsmc180_add_endcaps(ht: HammerTool) -> bool:
    assert isinstance(ht, HammerPlaceAndRouteTool), "endcap insertion only for par"
    assert isinstance(ht, TCLTool), "endcap insertion can only run on TCL tools"
    endcap_cells=ht.technology.get_special_cell_by_type(CellType.EndCap)
    endcap_cell=endcap_cells[0].name[0]
    ht.append(
        f'''
set_db add_endcaps_boundary_tap     true
set_db add_endcaps_left_edge        {endcap_cell}
set_db add_endcaps_right_edge       {endcap_cell}
add_endcaps
    '''
    )
    return True

# various Innovus database settings
def tsmc180_innovus_settings(ht: HammerTool) -> bool:
    assert isinstance(ht, HammerPlaceAndRouteTool), "Innovus settings only for par"
    assert isinstance(ht, TCLTool), "innovus settings can only run on TCL tools"
    """Settings for every tool invocation"""
    ht.append(
        '''

##########################################################
# Placement attributes  [get_db -category place]
##########################################################
#-------------------------------------------------------------------------------
set_db opt_honor_fences true
set_db place_detail_dpt_flow true
set_db place_detail_color_aware_legal true
set_db place_global_solver_effort high
set_db place_detail_check_cut_spacing true
set_db place_global_cong_effort high

##########################################################
# Optimization attributes  [get_db -category opt]
##########################################################
#-------------------------------------------------------------------------------

set_db opt_fix_fanout_load true
set_db opt_clock_gate_aware false
set_db opt_area_recovery true
set_db opt_post_route_area_reclaim setup_aware
set_db opt_fix_hold_verbose true

##########################################################
# Clock attributes  [get_db -category cts]
##########################################################
#-------------------------------------------------------------------------------
set_db cts_target_skew 450ps
set_db cts_max_fanout 10
set_db cts_target_max_transition_time 400ps
set_db opt_setup_target_slack 0.1
set_db opt_hold_target_slack 0.1
create_route_rule -name cts_spec_1w_2s_leaf -width {METAL1 0.23 METAL2 0.28 METAL3 0.28 METAL4 0.28 METAL5 0.28 METAL6 2.6} -spacing {METAL1 0.23 METAL2 0.28 METAL3 0.28 METAL4 0.28 METAL5 0.28 METAL6 2.5} 
create_route_type -name RT_LEAF_RULE -route_rule cts_spec_1w_2s_leaf -top_preferred_layer METAL6 -bottom_preferred_layer METAL2 -preferred_routing_layer_effort high
create_route_rule -name cts_spec_2w_2s_shield -width {METAL1 0.46 METAL2 0.56 METAL3 0.56 METAL4 0.56 METAL5 0.56 METAL6 5.2} -spacing {METAL1 0.46 METAL2 0.56 METAL3 0.56 METAL4 0.56 METAL5 0.56 METAL6 5.0} 
create_route_type -name RT_TRUNK_RULE -route_rule cts_spec_2w_2s_shield -shield_net VSS -top_preferred_layer METAL4 -bottom_preferred_layer METAL3 -preferred_routing_layer_effort high
set_db cts_route_type_top "default"
set_db cts_route_type_trunk "RT_TRUNK_RULE"
set_db cts_route_type_leaf "RT_LEAF_RULE"
commit_clock_tree_route_attributes

set_db cts_primary_delay_corner WCCOM.setup_delay
set_db cts_buffer_cells {{CKBD1BWP7T} {CKBD2BWP7T} {CKBD3BWP7T} {CKBD4BWP7T} {CKBD6BWP7T} {CKBD8BWP7T} {CKBD10BWP7T} {CKBD12BWP7T}}
set_db cts_inverter_cells {{CKND0BWP7T} {CKND1BWP7T} {CKND2BWP7T} {CKND3BWP7T} {CKND4BWP7T} {CKND6BWP7T}{CKND8BWP7T} {CKND10BWP7T} {CKND12BWP7T}}
set_db cts_logic_cells {{CKAN2D0BWP7T} {CKAN2D1BWP7T} {CKAN2D2BWP7T} {CKAN2D8BWP7T} {CKXOR2D0BWP7T} {CKXOR2D1BWP7T} {CKXOR2D2BWP7T} {CKXOR2D4BWP7T} {CKMUX2D0BWP7T} {CKMUX2D1BWP7T} {CKMUX2D2BWP7T} {CKND2D0BWP7T} {CKND2D1BWP7T} {CKND2D2BWP7T} {CKND2D3BWP7T} {CKND2D4BWP7T} {CKND2D8BWP7T}}
    
set_db route_design_antenna_diode_insertion true
set_db route_design_antenna_cell_name ANTENNABWP7T

set_db extract_rc_engine post_route
set_db extract_rc_effort_level high
set_db extract_rc_coupled true
    '''
    )
    return True

tech = TSMCN180RFTech()
