/* libInit File for "UCLA_CEMiD_1x1_PadFrame_PCELL"

	Description:  "libInit.il" file for the library named "UCLA_CEMiD_1x1_PadFrame_PCELL"
	Created:      15-APR-2025, Sean Wang
	
	NOTES:  	
	1.  This is NOT the best practices way to package pcells but was created prioritizing ease of sharing.
	Refer to referenced Cadence documentation for best practices on how to package pcells for a commercial PDK.
	2.  Using matts pad footprint
		
*/


; -- Some Constants Used in Schematic Creation
SCWschematicConstants = list(nil)
SCWschematicConstants->pinRectDim = 0.01875
SCWschematicConstants->pinSpacing = 0.125
SCWschematicConstants->pinFontHeight = 0.0625

; -- Mapping needed to fix Calibre LVS Bug
SCWschematicConstants->lvs_map = list(11 19 20 21 22 23 24 25 26 1 2 3 4 5 6 7 8 9 10 12 13 14 15 16 17 18)
SCWschematicConstants->lvs_map = listToVector(SCWschematicConstants->lvs_map)

; --- Variables for "SCW_seal_ring_pcell.il" ---
SCW_seal_ring = list(nil)
SCW_seal_ring->libName = "UCLA_CEMiD_1x1_PadFrame_PCELL"
SCW_seal_ring->cellName = "SCW_seal_ring_pcell"
SCW_seal_ring->seal_ring_lib = "UCLA_CEMiD_1x1_PadFrame_PCELL"
SCW_seal_ring->seal_ring_edge_cell = "tsmc_c018_seal_ring_edge_1p6m"
SCW_seal_ring->seal_ring_corner_cell = "tsmc_c018_sealring_corner_1p6m"
SCW_seal_ring->seal_ring_clearance = 10.0
SCW_seal_ring->seal_ring_pimp_protrusion = 0.18
SCW_seal_ring->corner_edge_offset = 5.0
SCW_seal_ring->corner_offset = 20.0
SCW_seal_ring->edge_piece_span = 1.0
SCW_seal_ring->firstEdgeBottom_coords = list(11,15)
SCW_seal_ring->firstEdgeBottom_orient = "R180"
SCW_seal_ring->firstEdgeLeft_coords   = list(15, 10)
SCW_seal_ring->firstEdgeLeft_orient   = "R90"
SCW_seal_ring->edgeRight_orient = "R270"
SCW_seal_ring->edgeTop_orient = "R0"
SCW_seal_ring->cornerBottomLeft_orient = "R0"
SCW_seal_ring->cornerBottomRight_orient = "R90"
SCW_seal_ring->cornerTopRight_orient = "R180"
SCW_seal_ring->cornerTopLeft_orient = "R270"
SCW_seal_ring->prBoundary = list("prBoundary" "drawing")
; -- Ceil to the nearest um for seal ring
procedure(SCWceilToUm(point)
	x = ceiling(point/1.)*1.		
)

; --- Variables for "UCLA_CEMiD_pad_frame_2x2_pcell.il" ---
;  I got lazy and copy pasted all orientations using the code below instead of manually typing them.
;     cellToPrint = "M_PDB3AC_w_bond_and_schematic"
;     foreach(inst geGetSelSet(geGetEditCellView()) if( equal(inst~>cellName cellToPrint) then printf("list(%f:%f \"%s\")\n" car(inst~>xy) cadr(inst~>xy) inst~>orient)))
SCW_180nm_padframe_64 = list(nil)
SCW_180nm_padframe_64->libName = "UCLA_CEMiD_1x1_PadFrame_PCELL"
SCW_180nm_padframe_64->cellName = "UCLA_CEMiD_pad_frame_2x2_pcell"
SCW_180nm_padframe_64->pad_count = 56
SCW_180nm_padframe_64->corner_dim = 1964.88
SCW_180nm_padframe_64->corner_dim_for_sealring = 1959; because we have less than 10um of isolation region (subtract from corner_dim rounded to nearest integer um)
SCW_180nm_padframe_64->plus_sealring_dim = 2000.0
SCW_180nm_padframe_64->seal_ring_offset = list(-17.56:-17.56 "R0")
SCW_180nm_padframe_64->filler45p58 = "PFILLER45p58A"
SCW_180nm_padframe_64->filler45p585 = "PFILLER45p585A"
SCW_180nm_padframe_64->filler30p585 = "PFILLER30p585A"
SCW_180nm_padframe_64->fillerPattern30p585 = list(
list(0.000000:160.585000 "R270")
list(0.000000:1834.880000 "R270")
list(130.000000:0.000000 "R0")
list(160.585000:1964.880000 "R180")
list(1804.295000:0.000000 "R0")
list(1834.880000:1964.880000 "R180")
list(1964.880000:130.000000 "R90")
list(1964.880000:1804.295000 "R90")
											)
SCW_180nm_padframe_64->fillerPattern45p58 = list(
list(0.000000:1638.710000 "R270")
list(0.000000:1533.130000 "R270")
list(0.000000:1427.550000 "R270")
list(0.000000:1321.970000 "R270")
list(0.000000:1216.390000 "R270")
list(0.000000:1110.810000 "R270")
list(0.000000:1005.230000 "R270")
list(0.000000:899.650000 "R270")
list(0.000000:794.070000 "R270")
list(0.000000:688.490000 "R270")
list(0.000000:582.910000 "R270")
list(0.000000:477.330000 "R270")
list(0.000000:371.750000 "R270")
list(326.170000:0.000000 "R0")
list(371.750000:1964.880000 "R180")
list(431.750000:0.000000 "R0")
list(477.330000:1964.880000 "R180")
list(537.330000:0.000000 "R0")
list(582.910000:1964.880000 "R180")
list(642.910000:0.000000 "R0")
list(688.490000:1964.880000 "R180")
list(748.490000:0.000000 "R0")
list(794.070000:1964.880000 "R180")
list(854.070000:0.000000 "R0")
list(899.650000:1964.880000 "R180")
list(959.650000:0.000000 "R0")
list(1005.230000:1964.880000 "R180")
list(1065.230000:0.000000 "R0")
list(1110.810000:1964.880000 "R180")
list(1170.810000:0.000000 "R0")
list(1216.390000:1964.880000 "R180")
list(1276.390000:0.000000 "R0")
list(1321.970000:1964.880000 "R180")
list(1381.970000:0.000000 "R0")
list(1427.550000:1964.880000 "R180")
list(1487.550000:0.000000 "R0")
list(1533.130000:1964.880000 "R180")
list(1593.130000:0.000000 "R0")
list(1638.710000:1964.880000 "R180")
list(1964.880000:326.170000 "R90")
list(1964.880000:431.750000 "R90")
list(1964.880000:537.330000 "R90")
list(1964.880000:642.910000 "R90")
list(1964.880000:748.490000 "R90")
list(1964.880000:854.070000 "R90")
list(1964.880000:959.650000 "R90")
list(1964.880000:1065.230000 "R90")
list(1964.880000:1170.810000 "R90")
list(1964.880000:1276.390000 "R90")
list(1964.880000:1381.970000 "R90")
list(1964.880000:1487.550000 "R90")
list(1964.880000:1593.130000 "R90")
											)
SCW_180nm_padframe_64->fillerPattern45p585 = list(
list(0.000000:266.170000 "R270")
list(266.170000:1964.880000 "R180")
list(1698.710000:0.000000 "R0")
list(1964.880000:1698.710000 "R90")
											)
SCW_180nm_padframe_64->orientation_marker_coords = list(
148.385:1790.495 
159.155:1790.495 
174.385:1805.725 
174.385:1827.265 
159.155:1842.495 
137.615:1842.495 
122.385:1827.265 
122.385:1805.725 
137.615:1790.495 
148.385:1790.495 
148.385:1796.495 
140.1:1796.495 
128.385:1808.21 
128.385:1824.78 
140.1:1836.495 
156.67:1836.495 
168.385:1824.78 
168.385:1808.21 
156.67:1796.495 
148.385:1796.495
											)
											
											
SCW_180nm_padframe_64->fixed_pad_pattern = list(
											list("M64_PVDD3VSS2AC_w_bond_and_schematic" 160.585:0 "R0")
											list("M64_PVDD3VSS2AC_w_bond_and_schematic" 1964.88:160.585 "R90")
											list("M64_PVDD3VSS2AC_w_bond_and_schematic" 1804.295:1964.88 "R180")
											list("M64_PVDD3VSS2AC_w_bond_and_schematic" 0:1804.295 "R270")
										)
SCW_180nm_padframe_64->variable_pad_coords = list(
list(371.750000:0.000000 "R0")
list(477.330000:0.000000 "R0")
list(582.910000:0.000000 "R0")
list(688.490000:0.000000 "R0")
list(794.070000:0.000000 "R0")
list(899.650000:0.000000 "R0")
list(1005.230000:0.000000 "R0")
list(1110.810000:0.000000 "R0")
list(1216.390000:0.000000 "R0")
list(1321.970000:0.000000 "R0")
list(1427.550000:0.000000 "R0")
list(1533.130000:0.000000 "R0")
list(1638.710000:0.000000 "R0")
list(1744.295000:0.000000 "R0")
list(1964.880000:371.750000 "R90")
list(1964.880000:477.330000 "R90")
list(1964.880000:582.910000 "R90")
list(1964.880000:688.490000 "R90")
list(1964.880000:794.070000 "R90")
list(1964.880000:899.650000 "R90")
list(1964.880000:1005.230000 "R90")
list(1964.880000:1110.810000 "R90")
list(1964.880000:1216.390000 "R90")
list(1964.880000:1321.970000 "R90")
list(1964.880000:1427.550000 "R90")
list(1964.880000:1533.130000 "R90")
list(1964.880000:1638.710000 "R90")
list(1964.880000:1744.295000 "R90")
list(1593.130000:1964.880000 "R180")
list(1487.550000:1964.880000 "R180")
list(1381.970000:1964.880000 "R180")
list(1276.390000:1964.880000 "R180")
list(1170.810000:1964.880000 "R180")
list(1065.230000:1964.880000 "R180")
list(959.650000:1964.880000 "R180")
list(854.070000:1964.880000 "R180")
list(748.490000:1964.880000 "R180")
list(642.910000:1964.880000 "R180")
list(537.330000:1964.880000 "R180")
list(431.750000:1964.880000 "R180")
list(326.170000:1964.880000 "R180")
list(220.585000:1964.880000 "R180")
list(0.000000:1593.130000 "R270")
list(0.000000:1487.550000 "R270")
list(0.000000:1381.970000 "R270")
list(0.000000:1276.390000 "R270")
list(0.000000:1170.810000 "R270")
list(0.000000:1065.230000 "R270")
list(0.000000:959.650000 "R270")
list(0.000000:854.070000 "R270")
list(0.000000:748.490000 "R270")
list(0.000000:642.910000 "R270")
list(0.000000:537.330000 "R270")
list(0.000000:431.750000 "R270")
list(0.000000:326.170000 "R270")
list(0.000000:220.585000 "R270")
										)
											



procedure( SCW_180nm_padframe_64_pcellCB() let( ()
	cdfgData->var_pad01_schematic->value = cdfgData->var_pad01->value
	cdfgData->var_pad02_schematic->value = cdfgData->var_pad02->value
	cdfgData->var_pad03_schematic->value = cdfgData->var_pad03->value
	cdfgData->var_pad04_schematic->value = cdfgData->var_pad04->value
	cdfgData->var_pad05_schematic->value = cdfgData->var_pad05->value
	cdfgData->var_pad06_schematic->value = cdfgData->var_pad06->value
	cdfgData->var_pad07_schematic->value = cdfgData->var_pad07->value
	cdfgData->var_pad08_schematic->value = cdfgData->var_pad08->value
	cdfgData->var_pad09_schematic->value = cdfgData->var_pad09->value
	cdfgData->var_pad10_schematic->value = cdfgData->var_pad10->value
	cdfgData->var_pad11_schematic->value = cdfgData->var_pad11->value
	cdfgData->var_pad12_schematic->value = cdfgData->var_pad12->value
	cdfgData->var_pad13_schematic->value = cdfgData->var_pad13->value
	cdfgData->var_pad14_schematic->value = cdfgData->var_pad14->value
	cdfgData->var_pad15_schematic->value = cdfgData->var_pad15->value
	cdfgData->var_pad16_schematic->value = cdfgData->var_pad16->value
	cdfgData->var_pad17_schematic->value = cdfgData->var_pad17->value
	cdfgData->var_pad18_schematic->value = cdfgData->var_pad18->value
	cdfgData->var_pad19_schematic->value = cdfgData->var_pad19->value
	cdfgData->var_pad20_schematic->value = cdfgData->var_pad20->value
	cdfgData->var_pad21_schematic->value = cdfgData->var_pad21->value
	cdfgData->var_pad22_schematic->value = cdfgData->var_pad22->value
	cdfgData->var_pad23_schematic->value = cdfgData->var_pad23->value
	cdfgData->var_pad24_schematic->value = cdfgData->var_pad24->value
	cdfgData->var_pad25_schematic->value = cdfgData->var_pad25->value
	cdfgData->var_pad26_schematic->value = cdfgData->var_pad26->value
	cdfgData->var_pad27_schematic->value = cdfgData->var_pad27->value
	cdfgData->var_pad28_schematic->value = cdfgData->var_pad28->value
	cdfgData->var_pad29_schematic->value = cdfgData->var_pad29->value
	cdfgData->var_pad30_schematic->value = cdfgData->var_pad30->value
	cdfgData->var_pad31_schematic->value = cdfgData->var_pad31->value
	cdfgData->var_pad32_schematic->value = cdfgData->var_pad32->value
	cdfgData->var_pad33_schematic->value = cdfgData->var_pad33->value
	cdfgData->var_pad34_schematic->value = cdfgData->var_pad34->value
	cdfgData->var_pad35_schematic->value = cdfgData->var_pad35->value
	cdfgData->var_pad36_schematic->value = cdfgData->var_pad36->value
	cdfgData->var_pad37_schematic->value = cdfgData->var_pad37->value
	cdfgData->var_pad38_schematic->value = cdfgData->var_pad38->value
	cdfgData->var_pad39_schematic->value = cdfgData->var_pad39->value
	cdfgData->var_pad40_schematic->value = cdfgData->var_pad40->value
	cdfgData->var_pad41_schematic->value = cdfgData->var_pad41->value
	cdfgData->var_pad42_schematic->value = cdfgData->var_pad42->value
	cdfgData->var_pad43_schematic->value = cdfgData->var_pad43->value
	cdfgData->var_pad44_schematic->value = cdfgData->var_pad44->value
	cdfgData->var_pad45_schematic->value = cdfgData->var_pad45->value
	cdfgData->var_pad46_schematic->value = cdfgData->var_pad46->value
	cdfgData->var_pad47_schematic->value = cdfgData->var_pad47->value
	cdfgData->var_pad48_schematic->value = cdfgData->var_pad48->value
	cdfgData->var_pad49_schematic->value = cdfgData->var_pad49->value
	cdfgData->var_pad50_schematic->value = cdfgData->var_pad50->value
	cdfgData->var_pad51_schematic->value = cdfgData->var_pad51->value
	cdfgData->var_pad52_schematic->value = cdfgData->var_pad52->value
	cdfgData->var_pad53_schematic->value = cdfgData->var_pad53->value
	cdfgData->var_pad54_schematic->value = cdfgData->var_pad54->value
	cdfgData->var_pad55_schematic->value = cdfgData->var_pad55->value
	cdfgData->var_pad56_schematic->value = cdfgData->var_pad56->value
	)
); procedure




; --- Variables for "UCLA_CEMiD_pad_frame_1x1_pcell.il" ---
SCW_180nm_padframe = list(nil)
SCW_180nm_padframe->libName = "UCLA_CEMiD_1x1_PadFrame_PCELL"
SCW_180nm_padframe->cellName = "UCLA_CEMiD_pad_frame_1x1_pcell"
SCW_180nm_padframe->pad_lib = "UCLA_CEMiD_1x1_PadFrame_PCELL"
SCW_180nm_padframe->pad_choices = list("M_PDB3AC_w_bond_and_schematic" "M_PVDD3AC_w_bond_and_schematic" "M_PVSS2AC_w_bond_and_schematic" "M_PDB3AC_LITE_w_bond_and_schematic" "M_bond_pad_no_ESD")
SCW_180nm_padframe->pad_count = 26
SCW_180nm_padframe->corner_lib = "UCLA_CEMiD_1x1_PadFrame_PCELL"
SCW_180nm_padframe->corner_name = "PCORNERA"
SCW_180nm_padframe->corner_dim = 914.88
SCW_180nm_padframe->corner_dim_for_sealring = 909; because we have less than 10um of isolation region 
SCW_180nm_padframe->plus_sealring_dim = 950.0
SCW_180nm_padframe->seal_ring_offset = list(-17.56:-17.56 "R0")
SCW_180nm_padframe->filler_lib = "UCLA_CEMiD_1x1_PadFrame_PCELL"
SCW_180nm_padframe->filler7p765 = "PFILLER7p765A"
SCW_180nm_padframe->filler22p765 = "PFILLER22p765A"
SCW_180nm_padframe->filler22p76 = "PFILLER22p76A"
SCW_180nm_padframe->fillerPattern7p765 = list(; a list of coordinates and orientations for the 7p765 fillers
											list(130:0 "R0")
											list(777.115:0 "R0")
											list(SCW_180nm_padframe->corner_dim:130 "R90")
											list(SCW_180nm_padframe->corner_dim:777.115 "R90")
											list(784.88:SCW_180nm_padframe->corner_dim "R180")
											list(137.765:SCW_180nm_padframe->corner_dim "R180")
											list(0:784.88 "R270")
											list(0:137.765 "R270")
										)
SCW_180nm_padframe->fillerPattern22p76 = list(; a list of coordinates and orientations for the 22p76 fillers
											list(446.06:0 "R0")
											list(SCW_180nm_padframe->corner_dim:446.06 "R90")
											list(468.82:SCW_180nm_padframe->corner_dim "R180")
											list(0:468.82 "R270")
										)
SCW_180nm_padframe->fillerPattern22p765 = list(; a list of coordinates and orientations for the 22p765 fillers
											list(197.765:0 "R0")
											list(280.53:0 "R0")
											list(363.295:0 "R0")
											list(528.82:0 "R0")
											list(611.585:0 "R0")
											list(694.35:0 "R0")
											list(SCW_180nm_padframe->corner_dim:197.765 "R90")
											list(SCW_180nm_padframe->corner_dim:280.53 "R90")
											list(SCW_180nm_padframe->corner_dim:363.295 "R90")
											list(SCW_180nm_padframe->corner_dim:528.82 "R90")
											list(SCW_180nm_padframe->corner_dim:611.585 "R90")
											list(717.115:SCW_180nm_padframe->corner_dim "R180")
											list(634.35:SCW_180nm_padframe->corner_dim "R180")
											list(551.585:SCW_180nm_padframe->corner_dim "R180")
											list(386.06:SCW_180nm_padframe->corner_dim "R180")
											list(303.295:SCW_180nm_padframe->corner_dim "R180")
											list(220.53:SCW_180nm_padframe->corner_dim "R180")
											list(0:717.115 "R270")
											list(0:634.35 "R270")
											list(0:551.585 "R270")
											list(0:386.06 "R270")
											list(0:303.295 "R270")
										)
SCW_180nm_padframe->orientation_marker_coords = list(
	148.385:740.495 
	159.155:740.495
	174.385:755.725
	174.385:777.265
	159.155:792.495
	137.615:792.495
	122.385:777.265
	122.385:755.725
	137.615:740.495
	148.385:740.495
	148.385:746.495
	140.1:746.495
	128.385:758.21
	128.385:774.78
	140.1:786.495
	156.67:786.495
	168.385:774.78
	168.385:758.21 
	156.67:746.495 
	148.385:746.495)
SCW_180nm_padframe->orientation_marker_lpp = list("METAL6" "drawing")

SCW_180nm_padframe->fixed_pad_pattern = list(; code assumes all fixed pads are only VDD and VSS
											list("M_PVDD3AC_w_bond_and_schematic" 717.115:0 "R0")
											list("M_PVDD3VSS2AC_w_bond_and_schematic" SCW_180nm_padframe->corner_dim:777.115 "MYR90")
											list("M_PVDD3AC_w_bond_and_schematic" 197.765:SCW_180nm_padframe->corner_dim "R180")
											list("M_PVDD3VSS2AC_w_bond_and_schematic" 0:137.765 "MXR90")
										)
SCW_180nm_padframe->variable_pad_coords = list(
											list(137.765:0 "R0")
											list(220.53:0 "R0")
											list(303.295:0 "R0")
											list(386.06:0 "R0")
											list(468.82:0 "R0")
											list(551.585:0 "R0")
											list(634.35:0 "R0")
											list(SCW_180nm_padframe->corner_dim:137.765 "R90")
											list(SCW_180nm_padframe->corner_dim:220.53 "R90")
											list(SCW_180nm_padframe->corner_dim:303.295 "R90")
											list(SCW_180nm_padframe->corner_dim:386.06 "R90")
											list(SCW_180nm_padframe->corner_dim:468.82 "R90")
											list(SCW_180nm_padframe->corner_dim:551.585 "R90")
											list(777.115:SCW_180nm_padframe->corner_dim "R180")
											list(694.35:SCW_180nm_padframe->corner_dim "R180")
											list(611.585:SCW_180nm_padframe->corner_dim "R180")
											list(528.82:SCW_180nm_padframe->corner_dim "R180")
											list(446.06:SCW_180nm_padframe->corner_dim "R180")
											list(363.295:SCW_180nm_padframe->corner_dim "R180")
											list(280.53:SCW_180nm_padframe->corner_dim "R180")
											list(0:777.115 "R270")
											list(0:694.35 "R270")
											list(0:611.585 "R270")
											list(0:528.82 "R270")
											list(0:446.06 "R270")
											list(0:363.295 "R270")
										)

; --- Callback to create the schematic and symbol "on-the-spot" whenever the variable pads are changed
procedure( SCW_180nm_padframe_pcellCB() let( ()
	cdfgData->var_pad01_schematic->value = cdfgData->var_pad01->value
	cdfgData->var_pad02_schematic->value = cdfgData->var_pad02->value
	cdfgData->var_pad03_schematic->value = cdfgData->var_pad03->value
	cdfgData->var_pad04_schematic->value = cdfgData->var_pad04->value
	cdfgData->var_pad05_schematic->value = cdfgData->var_pad05->value
	cdfgData->var_pad06_schematic->value = cdfgData->var_pad06->value
	cdfgData->var_pad07_schematic->value = cdfgData->var_pad07->value
	cdfgData->var_pad08_schematic->value = cdfgData->var_pad08->value
	cdfgData->var_pad09_schematic->value = cdfgData->var_pad09->value
	cdfgData->var_pad10_schematic->value = cdfgData->var_pad10->value
	cdfgData->var_pad11_schematic->value = cdfgData->var_pad11->value
	cdfgData->var_pad12_schematic->value = cdfgData->var_pad12->value
	cdfgData->var_pad13_schematic->value = cdfgData->var_pad13->value
	cdfgData->var_pad14_schematic->value = cdfgData->var_pad14->value
	cdfgData->var_pad15_schematic->value = cdfgData->var_pad15->value
	cdfgData->var_pad16_schematic->value = cdfgData->var_pad16->value
	cdfgData->var_pad17_schematic->value = cdfgData->var_pad17->value
	cdfgData->var_pad18_schematic->value = cdfgData->var_pad18->value
	cdfgData->var_pad19_schematic->value = cdfgData->var_pad19->value
	cdfgData->var_pad20_schematic->value = cdfgData->var_pad20->value
	cdfgData->var_pad21_schematic->value = cdfgData->var_pad21->value
	cdfgData->var_pad22_schematic->value = cdfgData->var_pad22->value
	cdfgData->var_pad23_schematic->value = cdfgData->var_pad23->value
	cdfgData->var_pad24_schematic->value = cdfgData->var_pad24->value
	cdfgData->var_pad25_schematic->value = cdfgData->var_pad25->value
	cdfgData->var_pad26_schematic->value = cdfgData->var_pad26->value
	)
); procedure






; --- Pin Rectangle Creating Helper Function ---
procedure(SCWpinRect(x y)
	list(x-SCWschematicConstants->pinRectDim:y-SCWschematicConstants->pinRectDim 
		 x+SCWschematicConstants->pinRectDim:y+SCWschematicConstants->pinRectDim
		)
)