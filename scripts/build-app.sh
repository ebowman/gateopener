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

# Version: a fixed short version for now (bump by hand as releases happen),
# plus a build number derived from git so two builds from different commits
# are distinguishable. Falls back to "0" if git metadata is unavailable
# (e.g. building from a tarball with no .git directory), so the script
# never fails outright over an unavailable build number.
SHORT_VERSION="0.1.0"
BUILD_NUMBER="$(git -C "${REPO_ROOT}" rev-list --count HEAD 2>/dev/null || echo "0")"

ICON_SVG="${REPO_ROOT}/Resources/AppIcon.svg"
ICON_ICNS="${REPO_ROOT}/Resources/AppIcon.icns"
ICON_NAME="AppIcon"

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

echo "==> Assembling ${APP_NAME}.app (removing any stale bundle first)..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${RELEASE_BIN}" "${MACOS_DIR}/${APP_NAME}"
cp "${ICON_ICNS}" "${RESOURCES_DIR}/${ICON_NAME}.icns"

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

echo "==> Ad-hoc code-signing ${APP_NAME}.app..."
codesign --force --deep --sign - "${APP_BUNDLE}"

echo "==> Verifying signature..."
codesign -dv "${APP_BUNDLE}"

echo "==> Done: ${APP_BUNDLE}"
