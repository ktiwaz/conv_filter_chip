# Notes

- From `appnote_q32013.pdf`: "Special attention is needed for clock tree design, such as balance, transition and skew. Following TSMC ISF recommendation of clock tree design is strongly suggested."
  - What is "TSMC ISF recommendation"?!
- Might need to set `DEL` cells (delay cells) to don't use during synthesis? The appnote suggests using them only for hold-time fixing.
- Didn't see endcap ~~and tapcell~~?!
  * tapcell found. Using `FILL2BWP7T` as endcaps for now
- ~~We don't have CDL files for SPICE simulation. We have SPI instead.~~ .spi file is in CDL
  format (source: digital library documentation)
- ~~Nominal supply voltage?~~ TC = TT25, 1.8V (source: NLDM lib), WC = SS100, 1.62V, BC = FF-40, 1.98V

- Temporarily using `BUFFD4BWP7T` as driver -- non-inverting buffer with 4x default
  drive strength.
- Currently using 6 metal layers. Affecting files in `hammer/src/hammer-vlsi/technology/tsmc180/`:
  - `tsmc180.tech.json`: `libraries.lef_file`, `libraries.tluplus_map_file`
  - `defaults.yml`: power straps
- We are on an older version of hammer. No support for `ctsinverter` and `ctslogic`

# EDA Errors & Warnings

## Syn

## Par

### Errors

### Warnings

- ~~from hammer: [par] You have not overridden place_tap_cells. By default this step adds a simple set of tapcells or does nothing; you will have trouble with power strap creation later.~~
  - Overwritten.

- **WARN: (IMPEXT-2773):	The via resistance between layers M0 and M1 could not be determined from the LEF technology file because the via resistance specification is missing. A default of 4 Ohms will be used as via resistance between these layers.
- **WARN: (IMPEXT-2776):	The via resistance between layers M1 and M2 is not defined in the capacitance table file. The via resistance of 6.4 Ohms defined in the LEF technology file will be used as via resistance between these layers.
- **WARN: (IMPEXT-2776):	The via resistance between layers M2 and M3 is not defined in the capacitance table file. The via resistance of 6.4 Ohms defined in the LEF technology file will be used as via resistance between these layers.
- **WARN: (IMPEXT-2776):	The via resistance between layers M3 and M4 is not defined in the capacitance table file. The via resistance of 6.4 Ohms defined in the LEF technology file will be used as via resistance between these layers.
- **WARN: (IMPEXT-2776):	The via resistance between layers M4 and M5 is not defined in the capacitance table file. The via resistance of 6.4 Ohms defined in the LEF technology file will be used as via resistance between these layers.
- **WARN: (IMPEXT-2776):	The via resistance between layers M5 and M6 is not defined in the capacitance table file. The via resistance of 2.54 Ohms defined in the LEF technology file will be used as via resistance between these layers.
- **WARN: (IMPEXT-2766):	The sheet resistance for layer M1 is not defined in the cap table. Therefore, the LEF value 0.078 will be used instead. To avoid this message, update the relevant cap table to include the sheet resistance for the specified layer and read it back in.
- **WARN: (IMPEXT-2766):	The sheet resistance for layer M2 is not defined in the cap table. Therefore, the LEF value 0.078 will be used instead. To avoid this message, update the relevant cap table to include the sheet resistance for the specified layer and read it back in.
- **WARN: (IMPEXT-2766):	The sheet resistance for layer M3 is not defined in the cap table. Therefore, the LEF value 0.078 will be used instead. To avoid this message, update the relevant cap table to include the sheet resistance for the specified layer and read it back in.
- **WARN: (IMPEXT-2766):	The sheet resistance for layer M4 is not defined in the cap table. Therefore, the LEF value 0.078 will be used instead. To avoid this message, update the relevant cap table to include the sheet resistance for the specified layer and read it back in.
- **WARN: (IMPEXT-2766):	The sheet resistance for layer M5 is not defined in the cap table. Therefore, the LEF value 0.078 will be used instead. To avoid this message, update the relevant cap table to include the sheet resistance for the specified layer and read it back in.
- **WARN: (IMPEXT-2766):	The sheet resistance for layer M6 is not defined in the cap table. Therefore, the LEF value 0.036 will be used instead. To avoid this message, update the relevant cap table to include the sheet resistance for the specified layer and read it back in.

- **WARN: (IMPPP-358):	The left edge of the area you specified is out of design boundary and only stripes in design boundary will be generated. 
- **WARN: (IMPPP-358):	The right edge of the area you specified is out of design boundary and only stripes in design boundary will be generated. 
- **WARN: (IMPPP-358):	The bottom edge of the area you specified is out of design boundary and only stripes in design boundary will be generated. 
- **WARN: (IMPPP-358):	The top edge of the area you specified is out of design boundary and only stripes in design boundary will be generated. 

- **WARN: (IMPEXT-6197):	The Cap table file is not specified. This will result in lower parasitic accuracy when using pre_route extraction or post_route extraction with effort level 'low'. It is recommended to generate the Cap table file using the 'write_cap_table' command and specify it before extraction using 'create_rc_corner/update_rc_corner -cap_table'.
  - (Ang) I do see captable somewhere in the digital library. need to figure out how to pass that through hammer