#!/usr/bin/env bash
# Fetch Digilent's vivado-library (BSD-3 sources) at a pinned commit, for the
# rgb2dvi (HDMI out) and dvi2rgb (HDMI in) VHDL sources.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo=https://github.com/Digilent/vivado-library.git
commit=0362ce72d39eebc400fdabacff706ee7fa8ad564
dest="$here/vivado-library"

if [ -d "$dest/.git" ] && [ "$(git -C "$dest" rev-parse HEAD)" = "$commit" ]; then
    echo "vivado-library already at $commit"
    exit 0
fi
rm -rf "$dest"
git init -q "$dest"
git -C "$dest" remote add origin "$repo"
# Only the two IPs we use
git -C "$dest" sparse-checkout set --no-cone ip/rgb2dvi ip/dvi2rgb License.txt
git -C "$dest" fetch -q --depth 1 origin "$commit"
git -C "$dest" checkout -q FETCH_HEAD
echo "vivado-library checked out at $commit"
