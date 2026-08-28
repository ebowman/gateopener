#!/bin/bash
# Assembles GateOpener.app: builds the release binary via SwiftPM, lays out
# a proper .app bundle, generates Info.plist, copies the app icon, and
# ad-hoc code-signs the result.
#
# Usage: scripts/build-app.sh
# Output: GateOpener.app in the repo root (path printed on success).
#
# Idempotent: safe to run repeatedly from a clean checkout — always removes
# any stale bundle first and rebuilds from scratch.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_NAME="GateOpener"
BUNDLE_ID="ie.boboco.GateOpener"
APP_BUNDLE="${REPO_ROOT}/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

# Version: SINGLE AUTHORITATIVE SOURCE is the repo-root VERSION file (bump
# it by hand as releases happen). Everything else — this script's
# Info.plist, the eventual git tag, DMG filename, and update-manifest
# latestVersion — must be derived FROM the built bundle (see
# scripts/read-app-version.sh), never from a second hardcoded literal, so
# they cannot silently disagree.
#
# CFBundleVersion (the build number) is derived from git commit count, which
# is reproducible and always increases as commits land, so macOS reliably
# treats a later build as newer even when CFBundleShortVersionString is
# unchanged between two builds. Falls back to "0" if git metadata is
# unavailable (e.g. building from a source tarball with no .git directory),
# so the script never fails outright over an unavailable build number.
VERSION_FILE="${REPO_ROOT}/VERSION"
if [ ! -f "${VERSION_FILE}" ]; then
    echo "error: VERSION file not found at ${VERSION_FILE}" >&2
    exit 1
fi
# Trim leading/trailing whitespace ONLY — deliberately not `tr -d`, which
# strips interior whitespace too and would silently turn "1. 2.0" (or a
# value with an embedded newline) into a valid-looking "1.2.0". The updater
# performs no such normalization, so anything the build quietly repairs here
# is a version the two sides could disagree about.
SHORT_VERSION="$(<"${VERSION_FILE}")"
SHORT_VERSION="${SHORT_VERSION#"${SHORT_VERSION%%[![:space:]]*}"}"
SHORT_VERSION="${SHORT_VERSION%"${SHORT_VERSION##*[![:space:]]}"}"

# Guard: fail loudly on an unversionable value rather than produce a bundle
# whose version cannot be meaningfully ordered. Mirrors the updater's
# fail-closed SemanticVersion (Sources/GateOpenerCore/UpdateManifest.swift):
# 1 to 4 dot-separated non-negative integer components, nothing else.
if ! [[ "${SHORT_VERSION}" =~ ^[0-9]+(\.[0-9]+){0,3}$ ]]; then
    echo "error: VERSION file contains an invalid version string: '${SHORT_VERSION}'" >&2
    echo "       expected 1-4 dot-separated non-negative integers, e.g. 1.2.0" >&2
    exit 1
fi

# Each component must also fit in Int64, because SemanticVersion parses via
# Swift's Int(_:) and returns nil on overflow. A bundle whose version the
# updater cannot parse fails CLOSED — users would simply never be offered an
# update again, silently. 18 digits is comfortably under Int64.max and far
# beyond any real version number.
IFS='.' read -r -a _version_components <<< "${SHORT_VERSION}"
for _component in "${_version_components[@]}"; do
    if [ "${#_component}" -gt 18 ]; then
        echo "error: VERSION component '${_component}' is too large to parse as an integer." >&2
        echo "       The updater would silently stop offering updates. Keep components under 19 digits." >&2
        exit 1
    fi
done
unset _version_components _component

BUILD_NUMBER="$(git -C "${REPO_ROOT}" rev-list --count HEAD 2>/dev/null || echo "0")"

ICON_SVG="${REPO_ROOT}/Resources/AppIcon.svg"
ICON_ICNS="${REPO_ROOT}/Resources/AppIcon.icns"
ICON_NAME="AppIcon"

OVERLAY_VIDEO="${REPO_ROOT}/Resources/gate-open.mp4"
OVERLAY_VIDEO_NAME="gate-open.mp4"

DOOR_VIDEO_PAGE="${REPO_ROOT}/Resources/door-video.html"
DOOR_VIDEO_PAGE_NAME="door-video.html"

echo "==> Building ${APP_NAME} (release)..."
swift build -c release --package-path "${REPO_ROOT}"

RELEASE_BIN="$(swift build -c release --package-path "${REPO_ROOT}" --show-bin-path)/${APP_NAME}"
if [ ! -x "${RELEASE_BIN}" ]; then
    echo "error: release binary not found at ${RELEASE_BIN}" >&2
    exit 1
fi

echo "==> Regenerating app icon..."
if [ -f "${ICON_SVG}" ]; then
    "${SCRIPT_DIR}/generate-icon.sh"
elif [ ! -f "${ICON_ICNS}" ]; then
    echo "error: no icon source (${ICON_SVG}) and no existing ${ICON_ICNS}" >&2
    exit 1
else
    echo "    (no SVG source found; reusing existing ${ICON_ICNS})"
fi

if [ ! -f "${OVERLAY_VIDEO}" ]; then
    echo "error: overlay video not found at ${OVERLAY_VIDEO}. Run scripts/generate-overlay-video.sh first." >&2
    exit 1
fi

if [ ! -f "${DOOR_VIDEO_PAGE}" ]; then
    echo "error: door camera WebRTC page not found at ${DOOR_VIDEO_PAGE}." >&2
    exit 1
fi

echo "==> Assembling ${APP_NAME}.app (removing any stale bundle first)..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${RELEASE_BIN}" "${MACOS_DIR}/${APP_NAME}"
cp "${ICON_ICNS}" "${RESOURCES_DIR}/${ICON_NAME}.icns"
cp "${OVERLAY_VIDEO}" "${RESOURCES_DIR}/${OVERLAY_VIDEO_NAME}"
cp "${DOOR_VIDEO_PAGE}" "${RESOURCES_DIR}/${DOOR_VIDEO_PAGE_NAME}"

cat > "${CONTENTS_DIR}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleDisplayName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleExecutable</key>
	<string>${APP_NAME}</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${SHORT_VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${BUILD_NUMBER}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleIconFile</key>
	<string>${ICON_NAME}</string>
	<key>CFBundleIconName</key>
	<string>${ICON_NAME}</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>Copyright (c) 2026 boboco.ie. All rights reserved.</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

# Prefer a STABLE signing identity over ad-hoc. An ad-hoc signature
# (`--sign -`) derives the app's identity from its own hash, so it changes
# on EVERY rebuild and macOS treats each build as a different application
# — invalidating any keychain "Always Allow" grant and re-prompting for the
# Comelit credentials every single time. A Developer ID identity is keyed
# on identifier + team, so one grant survives all future rebuilds.
#
# Overridable via CODESIGN_IDENTITY; auto-detected otherwise; falls back to
# ad-hoc so contributors without an Apple certificate can still build. This
# resolution logic is shared with scripts/make-dmg.sh via
# scripts/lib/resolve-codesign-identity.sh so the app and its DMG always
# end up signed with the same identity.
# shellcheck source=lib/resolve-codesign-identity.sh
source "${SCRIPT_DIR}/lib/resolve-codesign-identity.sh"

if [ -n "${CODESIGN_IDENTITY}" ]; then
    echo "==> Code-signing ${APP_NAME}.app with: ${CODESIGN_IDENTITY}"
    # Hardened runtime + a secure (networked) timestamp are both REQUIRED
    # for notarization (see scripts/notarize-dmg.sh, bead gateopener-c33.3)
    # — Apple's notary service rejects a Developer ID-signed binary that
    # lacks either with "does not include a secure timestamp" / "does not
    # have the hardened runtime enabled". Only applied on the Developer ID
    # path: the ad-hoc fallback below can never be notarized anyway, so
    # there's no reason to pay for a network round trip to Apple's
    # timestamp server on that path.
    codesign --force --deep --sign "${CODESIGN_IDENTITY}" --timestamp --options runtime "${APP_BUNDLE}"
else
    echo "==> Ad-hoc code-signing ${APP_NAME}.app (no Developer ID identity found)..."
    echo "    NOTE: ad-hoc identity changes on every rebuild, so macOS will"
    echo "    re-prompt for keychain access after each build. Set"
    echo "    CODESIGN_IDENTITY, or install a Developer ID certificate, to stop that."
    codesign --force --deep --sign - "${APP_BUNDLE}"
fi

echo "==> Verifying signature..."
codesign -dv "${APP_BUNDLE}"

# Read the version back OUT of the built bundle rather than trust the
# shell variables above, so downstream release steps (git tag, DMG
# filename, update-manifest latestVersion) can rely on what was actually
# written to Info.plist. See scripts/read-app-version.sh.
BUILT_SHORT_VERSION="$("${SCRIPT_DIR}/read-app-version.sh" "${APP_BUNDLE}" short)"
BUILT_BUILD_NUMBER="$("${SCRIPT_DIR}/read-app-version.sh" "${APP_BUNDLE}" build)"
echo "==> Built version: ${BUILT_SHORT_VERSION} (build ${BUILT_BUILD_NUMBER})"

echo "==> Done: ${APP_BUNDLE}"
