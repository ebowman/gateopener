#!/bin/bash
# Generates Resources/gate-open.mp4, a short looping "gate opening" animation
# used by the overlay HUD panel as a canned confirmation clip (this is NOT
# live door-camera footage).
#
# Pipeline: a single ffmpeg invocation using the `geq` (generic equation)
# filter to procedurally render every frame directly from per-pixel/per-frame
# math (X = column, T = seconds elapsed). No external image or footage
# inputs are needed, so the output is fully reproducible from this script
# alone. (Note: this ffmpeg build's `drawbox` does not animate its geometry
# from the `t` expression variable reliably, so `geq` is used instead — it
# evaluates cleanly per frame.)
#
# Visual: two solid "gate leaf" panels (flat slate fill, clearly lighter
# than the background) start touching at the horizontal center and slide
# apart to reveal a dark opening behind them, edged by a warm amber glow
# where each leaf meets the opening. The gap grows monotonically for the
# first OPEN_DURATION seconds to a wide, unmistakable opening, then holds
# at full width for the rest of the clip. The first and last frames do NOT
# match: it opens and stays open, which is the intended reading for a
# confirmation glyph (the gate opened; it did not open and shut again).
# Callers that loop this will see it snap back shut on repeat — the overlay
# is expected to play it once per open. Deliberately simple/flat — this is a small
# confirmation glyph in a HUD panel, not a polished animation: legibility
# of "two things parting" at a glance is the only bar, not visual detail.
#
# Requirements: ffmpeg (`brew install ffmpeg`), built with libx264.
#
# Usage: scripts/generate-overlay-video.sh
# Output: Resources/gate-open.mp4
#   - 320x240 (4:3), ~2.2s, 25fps, H.264, no audio track.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_MP4="${REPO_ROOT}/Resources/gate-open.mp4"

# Looked up on PATH (matching generate-icon.sh's approach) rather than
# hardcoding an Apple-Silicon Homebrew path, so this also works on Intel
# Homebrew and MacPorts. Override with FFMPEG_BIN=... if needed.
FFMPEG_BIN="${FFMPEG_BIN:-ffmpeg}"

if ! command -v "${FFMPEG_BIN}" >/dev/null 2>&1; then
    echo "error: ffmpeg not found at ${FFMPEG_BIN}. Install with: brew install ffmpeg" >&2
    exit 1
fi

WIDTH=320
HEIGHT=240
FPS=25
DURATION=2.2
OPEN_DURATION=1.4      # seconds for the gap to reach full width
MAX_HALF_GAP=70         # half-width in px of the fully open gap (~44% of frame width total)
GLOW_WIDTH=10            # px falloff radius of the amber glow around each leaf's inner edge

CENTER_X=$((WIDTH / 2))

# gap(T): half-width of the open center gap, grows 0 -> MAX_HALF_GAP over
# OPEN_DURATION seconds, then holds (min(T, OPEN_DURATION) clamps time).
GAP="min(T\,${OPEN_DURATION})/${OPEN_DURATION}*${MAX_HALF_GAP}"
# dist(X): distance in px from the frame's horizontal center.
DIST="abs(X-${CENTER_X})"
# onLeaf: 1 where this column is still covered by a gate leaf (outside the
# opening), 0 where it has been revealed as the dark opening behind.
ON_LEAF="gt(${DIST}\,${GAP})"
# glow(X,T): triangular falloff peaking exactly at each leaf's inner edge
# (dist == gap), fading to 0 within GLOW_WIDTH px on either side, clamped
# to [0, 1]. Only meaningful right at the boundary; combined with ON_LEAF
# below so it only tints the opening side, not the leaf face.
GLOW="max(0\,1-abs(${DIST}-${GAP})/${GLOW_WIDTH})"

# Colors (0-255 RGB), flat fills only:
#   leaf face:           mid slate (92, 99, 110) — clearly lighter than bg
#   background/opening:  near-black (24, 26, 30), warmed by the glow term
#   glow peak color:     amber (217, 160, 82), blended in via GLOW on the
#                        opening side of each leaf's inner edge
LEAF_R=92;  LEAF_G=99;  LEAF_B=110
BG_R=24; BG_G=26; BG_B=30

R="if(${ON_LEAF}\,${LEAF_R}\,${BG_R}+193*${GLOW})"
G="if(${ON_LEAF}\,${LEAF_G}\,${BG_G}+134*${GLOW})"
B="if(${ON_LEAF}\,${LEAF_B}\,${BG_B}+52*${GLOW})"

rm -f "${OUTPUT_MP4}"

"${FFMPEG_BIN}" -y \
    -f lavfi -i "color=c=0x18191e:s=${WIDTH}x${HEIGHT}:d=${DURATION}:r=${FPS}" \
    -vf "format=gbrp,geq=r='${R}':g='${G}':b='${B}'" \
    -an \
    -c:v libx264 -pix_fmt yuv420p -profile:v baseline -level 3.0 \
    -crf 26 -preset veryslow -movflags +faststart \
    "${OUTPUT_MP4}"

echo "Generated ${OUTPUT_MP4}"
