#!/bin/bash
# Generates the iOS AppIcon PNG reproducibly from Resources/AppIcon.svg.
#
# Pipeline: rsvg-convert (SVG -> flattened opaque PNG at 1024x1024), the same
# renderer scripts/generate-icon.sh uses for the macOS .icns.
#
# iOS icons must be fully opaque (no alpha channel) with square corners —
# iOS applies the rounded-corner mask itself at render time, and App Store
# Connect rejects icons that carry an alpha channel. The source SVG's
# background is itself a rounded rect (rx="224"), so naively rasterizing it
# leaves the four corners transparent; this script flattens the render onto
# the icon's own background color (#2B3A55, matching Resources/AppIcon.svg)
# so the corners are opaque too — iOS discards that corner fill when it
# applies its mask, so its exact color is not visible in practice.
#
# Requirements: rsvg-convert (`brew install librsvg`).
#
# Usage: scripts/generate-ios-icon.sh
# Output: iOS/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
#
# Idempotent: running this script twice produces byte-identical output
# (rsvg-convert's PNG output carries no timestamps or other embedded
# metadata that would vary between runs).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SVG_SOURCE="${REPO_ROOT}/Resources/AppIcon.svg"
OUTPUT_PNG="${REPO_ROOT}/iOS/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"

# Background color to flatten onto, matching the SVG's own background rect.
BACKGROUND_COLOR="#2B3A55"

if [ ! -f "${SVG_SOURCE}" ]; then
    echo "error: SVG source not found at ${SVG_SOURCE}" >&2
    exit 1
fi

if ! command -v rsvg-convert >/dev/null 2>&1; then
    echo "error: rsvg-convert not found. Install with: brew install librsvg" >&2
    exit 1
fi

mkdir -p "$(dirname "${OUTPUT_PNG}")"

rsvg-convert --width 1024 --height 1024 \
    --background-color "${BACKGROUND_COLOR}" \
    "${SVG_SOURCE}" -o "${OUTPUT_PNG}"

echo "Generated ${OUTPUT_PNG}"
