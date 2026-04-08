dummy:
	calibre -drc -hier -turbo 40 Dummy_Metal_Calibre_0.18um.214a
	calibre -drc -hier -turbo 40 Dummy_OD_PO_Calibre_0.18um.215_2a
	calibredrv -a layout filemerge -append \
			-topcell "chip_sr" \
			-in ../sealring/chip_sr.gds \
			-in DM.gds \
			-in DOD.gds \
			-out finish.gds

clean:
	rm -f finish.gds DOD* DM* *~
