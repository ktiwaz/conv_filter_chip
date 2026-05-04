
from pathlib import Path

p = Path("build/par-rundir/par.tcl")
txt = p.read_text()

needle = "floorPlan"

if "place_pins.tcl" not in txt:
    lines = txt.splitlines()
    for i, line in enumerate(lines):
        if "floorPlan" in line:
            lines.insert(i+1, 'puts ">>> Running custom pin placement"')
            lines.insert(i+2, 'source ../../tcl/place_pins.tcl')
            break
    p.write_text("\n".join(lines))
    print("Injected place_pins.tcl")
else:
    print("Already injected")
