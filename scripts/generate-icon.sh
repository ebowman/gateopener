#!/bin/bash
# Generates Resources/AppIcon.icns reproducibly from Resources/AppIcon.svg.
#
# Pipeline: rsvg-convert (SVG -> PNG at each required size) -> assemble an
# .iconset directory -> iconutil (.iconset -> .icns).
#
# Requirements: rsvg-convert (`brew install librsvg`) and iconutil (ships
# with macOS). Both the SVG source and this script are committed, so the
# .icns is always regenerable — it is never hand-placed.
#
# Usage: scripts/generate-icon.sh
# Output: Resources/AppIcon.icns

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SVG_SOURCE="${REPO_ROOT}/Resources/AppIcon.svg"
OUTPUT_ICNS="${REPO_ROOT}/Resources/AppIcon.icns"
ICONSET_DIR="${REPO_ROOT}/Resources/AppIcon.iconset"

if [ ! -f "${SVG_SOURCE}" ]; then
    echo "error: SVG source not found at ${SVG_SOURCE}" >&2
    exit 1
fi

if ! command -v rsvg-convert >/dev/null 2>&1; then
    echo "error: rsvg-convert not found. Install with: brew install librsvg" >&2
    exit 1
fi

if ! command -v iconutil >/dev/null 2>&1; then
    echo "error: iconutil not found (expected to ship with macOS)" >&2
    exit 1
fi

# Clean slate so the .iconset never accumulates stale sizes.
rm -rf "${ICONSET_DIR}"
mkdir -p "${ICONSET_DIR}"

# macOS .iconset naming convention: base size + "@2x" for the Retina variant
# of the size below it. Standard set of 10 files for a complete .icns.
declare -a SIZES=(
    "16:icon_16x16.png"
    "32:icon_16x16@2x.png"
    "32:icon_32x32.png"
    "64:icon_32x32@2x.png"
    "128:icon_128x128.png"
    "256:icon_128x128@2x.png"
    "256:icon_256x256.png"
    "512:icon_256x256@2x.png"
    "512:icon_512x512.png"
    "1024:icon_512x512@2x.png"
)

for entry in "${SIZES[@]}"; do
    size="${entry%%:*}"
    filename="${entry##*:}"
    rsvg-convert --width "${size}" --height "${size}" \
        "${SVG_SOURCE}" -o "${ICONSET_DIR}/${filename}"
done

rm -f "${OUTPUT_ICNS}"
iconutil -c icns "${ICONSET_DIR}" -o "${OUTPUT_ICNS}"

# The .iconset is intermediate build output; only the .svg source and this
# script are meant to be committed.
rm -rf "${ICONSET_DIR}"

echo "Generated ${OUTPUT_ICNS}"
