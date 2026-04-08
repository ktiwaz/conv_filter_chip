import pya

print("Reading sealring GDS")
layout_sealring = pya.Layout()
layermap_sealring = layout_sealring.read("./sealring_2x2.gds")

print("Reading chip layout GDS")
layout_chip = pya.Layout()
layermap_chip = layout_chip.read("../../layout/out/chip.gds")

print("Old Top Cell: ", layout_chip.cell("chip").basic_name())
layout_sealring.top_cell().name = "chip_sr"
print("New Top Cell: ", layout_sealring.top_cell().basic_name())

source_chip_cell = layout_chip.cell("chip")
target_chip_cell = layout_sealring.top_cell()

cm = pya.CellMapping()
cm.for_single_cell_full(target_chip_cell, source_chip_cell)
layout_sealring.copy_tree_shapes(layout_chip, cm)

# Use this to move the seal ring origin to 0,0.
# Without this, the core design will be 0,0
# t = pya.Trans(15000,15000)
# layout_sealring.top_cell().transform(t)

print("Merged Layout: chip_sr.gds")
layout_sealring.write("chip_sr.gds")
