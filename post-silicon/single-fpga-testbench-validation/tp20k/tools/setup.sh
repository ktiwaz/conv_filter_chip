#!/usr/bin/env bash
# Local Gowin place-and-route toolchain, pinned by submodules:
#   tools/venv/   apycula from ../third_party/apicula + tools/chipdb/*.msgpack.xz
#   tools/bin/    nextpnr-himbaechel (Gowin, GW2A-18/-18C) from ../third_party/nextpnr,
#                 its chip database generated from that apycula and built in;
#                 openFPGALoader from ../third_party/openFPGALoader with
#                 tools/openfpgaloader.patch (128-byte flash writes: the dock's
#                 BL702 debugger stalls on long 256-byte page writes)
# yosys and sv2v still come from PATH.
#
# Needs: python3 (with venv), cmake, a C++17 compiler, Boost (filesystem,
# program_options, iostreams, thread), Eigen3, Python development headers;
# for openFPGALoader libftdi1, libusb-1.0, hidapi, zlib and pkg-config.
#
#   tools/setup.sh            build (again); JOBS=n to limit parallelism
set -euo pipefail

TOOLS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
THIRD=$(cd "$TOOLS/../../third_party" && pwd)
# parallel compile jobs: one per CPU, but at most one per ~2 GB of available
# memory (a C++ compiler on these sources can take 1-2 GB; -j $(nproc) ran a
# 32 GB machine out of memory). JOBS=n overrides.
mem_jobs=$(awk '/MemAvailable/ { j = int($2 / 2097152); print (j < 1 ? 1 : j) }' /proc/meminfo 2>/dev/null || echo 1)
cpu_jobs=$(nproc)
JOBS=${JOBS:-$(( mem_jobs < cpu_jobs ? mem_jobs : cpu_jobs ))}
DEVICES="GW2A-18;GW2A-18C"

for sub in apicula nextpnr openFPGALoader; do
    if [ ! -e "$THIRD/$sub/.git" ]; then
        echo "third_party/$sub is empty: run 'git submodule update --init' first" >&2
        exit 1
    fi
done

echo "== building with $JOBS parallel jobs (JOBS=n to change)"
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

# openFPGALoader with our patch, applied for the build only (the submodule
# stays clean); the udev rules for the debugger come with the distribution
# package or openFPGALoader's 99-openfpgaloader.rules
echo "== openFPGALoader ($(git -C "$THIRD/openFPGALoader" describe --tags --always))"
O="$TOOLS/build-openfpgaloader"
OFL="$THIRD/openFPGALoader"
git -C "$OFL" apply "$TOOLS/openfpgaloader.patch"
trap 'git -C "$OFL" apply -R "$TOOLS/openfpgaloader.patch"' EXIT
cmake -S "$OFL" -B "$O" -DCMAKE_BUILD_TYPE=Release -DENABLE_UDEV=OFF \
    -DCMAKE_INSTALL_PREFIX="$TOOLS" > "$TOOLS/cmake_ofl.log"
cmake --build "$O" -j "$JOBS" > "$TOOLS/build_ofl.log"
cmake --install "$O" > /dev/null
t3=$(date +%s)

echo "== done: apycula $((t1 - t0)) s, nextpnr $((t2 - t1)) s, openFPGALoader $((t3 - t2)) s"
echo "   $TOOLS/bin/nextpnr-himbaechel"
echo "   $TOOLS/venv/bin/gowin_pack"
echo "   $TOOLS/bin/openFPGALoader"
