# LVS Flow Steps

## Importing Standard Cell Library to Virtuoso
1. Create a new library in Virtuoso. Attach it to the `tsmc18` library.
2. In the Virtuoso CIW Window, click File -> Import -> SPICE. 
3. Choose the following options: 

(Input Tab)
- SPICE file: `/w/class.1/ee/ee209b/ee209bta/TSMC180PDK/Standard_Cells_and_IO/180_G_Standard_Cell/core_cell_library/core_cell_library/7-track/tcb018gbwp7t_290a/TSMCHOME/digital/Back_End/spice/tcb018gbwp7t_270a/tcb018gbwp7t_270a.spi`
- Netlist Language: SPICE
- Reference Library List: `tsmc18 basic analogLib`
- Master Cell for Ground Node: VSS
- Device Mapping File: yes

(Output Tab)
- Output Library: [Library you just created]

(Schematic Generation Tab)
- Analog Schematic Generation: yes
- Generate Top Cell Symbol: yes

(Device Mapping Tab)
- File -> Open -> Navigate to ee209-hammer-internal/hammer/src/vlsi/technology/tsmc180/virtuoso_mapping/tcb018gbwp7t.map

4. Click "OK". SpiceIn may freeze at 100% (last cell), just kill and reopen Virtuoso and it will be fine. 

5. Go to File -> Import -> Stream
- Stream file: `/w/class.1/ee/ee209b/ee209bta/TSMC180PDK/Standard_Cells_and_IO/180_G_Standard_Cell/core_cell_library/core_cell_library/7-track/tcb018gbwp7t_290a/TSMCHOME/digital/Back_End/gds/tcb018gbwp7t_270a/tcb018gbwp7t.gds`
- Library: The one you just created
6. Click "Translate". It should pass with a few warnings, no errors. 

## Preparing post-P&R netlist and imoprting into Virtuoso
1. In the `ee209-hammer-internal` directory, go to `build/par-rundir` and find `[design_name].lvs.v`. 
2. Use the scripts in the `lvs_scripts` folder to prepare the netlist. 
- First, run the generate_spice script by first sourcing the setup script for Calibre, then changing the file reference in the script to match the lvs.v file. Also change the output `.cdl` file to a convenient name, perhaps [design_name].cdl. 
- Next, run the python script called fix_slashes.py and give it the cdl script you just created. You can name the output [design_name]_virtuoso.cdl. 

3. Next, import the CDL to virtuoso (File -> Import -> Spice) with the following options: 
(Input Tab)
- SPICE file: [design_name]_virtuoso.cdl
- Netlist Language: CDL
- Reference Library List: `tsmc18 basic analogLib`
- Master Cell for Ground Node: VSS
- Device Mapping File: no

(Output Tab)
- Output Library: [Library you just created]

(Schematic Generation Tab)
- Analog Schematic Generation: yes
- Generate Top Cell Symbol: yes
- Generate Fast Schematic: yes (reduce the inst count to be low enough for this to trigger - 5000 worked for me)

4. Click OK. It may freeze at 100% again or just finish. You can now open the layout of top_3x3 and run LVS on it to verify correctness. Additionally, you can now connect the pad frame and verify the connection to it. 




