#!/usr/bin/env python3
import argparse
import re
from pathlib import Path


SKIP_LINE_RE = re.compile(r"^\s*(\*|\.include\b|\.inc\b|\.lib\b)", re.IGNORECASE)


def fix_cdl_slashes(input_path: Path, output_path: Path) -> None:
    with input_path.open("r", encoding="utf-8", errors="replace") as fin, \
         output_path.open("w", encoding="utf-8") as fout:

        for line in fin:
            if SKIP_LINE_RE.search(line):
                fout.write(line)
            else:
                fout.write(line.replace("/", "_"))


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Fix Virtuoso CDL import syntax by replacing '/' with '_' outside comments/includes."
    )
    parser.add_argument("input", help="Input CDL/SPICE netlist")
    parser.add_argument("output", help="Output fixed CDL/SPICE netlist")
    args = parser.parse_args()

    input_path = Path(args.input)
    output_path = Path(args.output)

    if not input_path.exists():
        raise FileNotFoundError(f"Input file does not exist: {input_path}")

    fix_cdl_slashes(input_path, output_path)
    print(f"Wrote fixed CDL to: {output_path}")


if __name__ == "__main__":
    main()