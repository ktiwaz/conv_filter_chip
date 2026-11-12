#!/usr/bin/env bash
# Local Gowin place-and-route toolchain, pinned by submodules:
#   tools/venv/   apycula from ../third_party/apicula + tools/chipdb/*.msgpack.xz
#   tools/bin/    nextpnr-himbaechel (Gowin, GW2A-18/-18C) from ../third_party/nextpnr,
#                 its chip database generated from that apycula and built in
# yosys and openFPGALoader still come from PATH.
#
# Needs: python3 (with venv), cmake, a C++17 compiler, Boost (filesystem,
# program_options, iostreams, thread), Eigen3, Python development headers.
#
#   tools/setup.sh            build (again); JOBS=n to limit parallelism
set -euo pipefail

TOOLS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
THIRD=$(cd "$TOOLS/../../third_party" && pwd)
JOBS=${JOBS:-$(nproc)}
DEVICES="GW2A-18;GW2A-18C"

for sub in apicula nextpnr; do
    if [ ! -e "$THIRD/$sub/.git" ]; then
        echo "third_party/$sub is empty: run 'git submodule update --init' first" >&2
        exit 1
    fi
done

t0=$(date +%s)

# apycula: install the pinned source, then add the chip databases (not in git)
echo "== apycula ($(git -C "$THIRD/apicula" rev-parse --short HEAD))"
python3 -m venv "$TOOLS/venv"
"$TOOLS/venv/bin/pip" install -q --upgrade pip
"$TOOLS/venv/bin/pip" install -q "$THIRD/apicula"
rm -rf "$THIRD/apicula/build" "$THIRD/apicula/Apycula.egg-info"   # keep the submodule clean
PKG=$("$TOOLS/venv/bin/python" -c 'import apycula, os; print(os.path.dirname(apycula.__file__))')
cp "$TOOLS"/chipdb/*.msgpack.xz "$PKG/"
t1=$(date +%s)

# nextpnr-himbaechel for Gowin; the chip database comes from the apycula above.
# A stale generated database would survive an apycula change, so drop it.
echo "== nextpnr ($(git -C "$THIRD/nextpnr" rev-parse --short HEAD))"
B="$TOOLS/build-nextpnr"
rm -f "$B"/himbaechel/uarch/gowin/chipdb-*.bba "$B"/himbaechel/gowin/chipdb-*.bin
# Pin the Python nextpnr embeds to the one that made the venv: FindPython
# otherwise takes the newest it finds (e.g. a uv-managed one not on the
# loader path).
PY=$(python3 -c 'import sys; print(sys.executable)')
cmake -S "$THIRD/nextpnr" -B "$B" -DCMAKE_BUILD_TYPE=Release \
    -DPython3_EXECUTABLE="$PY" -DPython3_FIND_STRATEGY=LOCATION \
    -DARCH=himbaechel -DHIMBAECHEL_UARCH=gowin -DHIMBAECHEL_GOWIN_DEVICES="$DEVICES" \
    -DAPYCULA_INSTALL_PREFIX="$TOOLS/venv" -DCMAKE_INSTALL_PREFIX="$TOOLS" > "$TOOLS/cmake.log"
cmake --build "$B" -j "$JOBS" > "$TOOLS/build.log"
cmake --install "$B" > /dev/null
t2=$(date +%s)

echo "== done: apycula $((t1 - t0)) s, nextpnr $((t2 - t1)) s"
echo "   $TOOLS/bin/nextpnr-himbaechel"
echo "   $TOOLS/venv/bin/gowin_pack"
