#!/bin/bash
# Reads CFBundleShortVersionString and CFBundleVersion back OUT of a BUILT
# .app bundle's Info.plist, rather than trusting a shell literal or the
# repo's VERSION file directly.
#
# This exists because downstream release steps (git tag, DMG filename,
# update-manifest latestVersion) must reflect what scripts/build-app.sh
# actually wrote into the bundle, not what was merely intended — reading
# from the source VERSION file again would not catch a build that silently
# used a stale or unexpected value.
#
# Usage:
#   scripts/read-app-version.sh short              # prints CFBundleShortVersionString
#   scripts/read-app-version.sh build               # prints CFBundleVersion (build number)
#   scripts/read-app-version.sh [path-to-App.app] short|build
#
# If no bundle path is given, defaults to GateOpener.app in the repo root
# (i.e. the output of scripts/build-app.sh run with no arguments).
#
# Exits non-zero with a message on stderr if the bundle or the requested
# key is missing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
    echo "Usage: $(basename "$0") [path-to-App.app] short|build" >&2
    exit 1
}

if [ "$#" -eq 2 ]; then
    APP_BUNDLE="$1"
    FIELD="$2"
elif [ "$#" -eq 1 ]; then
    APP_BUNDLE="${REPO_ROOT}/GateOpener.app"
    FIELD="$1"
else
    usage
fi

case "${FIELD}" in
    short) PLIST_KEY="CFBundleShortVersionString" ;;
    build) PLIST_KEY="CFBundleVersion" ;;
    *) usage ;;
esac

INFO_PLIST="${APP_BUNDLE}/Contents/Info.plist"
if [ ! -f "${INFO_PLIST}" ]; then
    echo "error: no Info.plist found at ${INFO_PLIST} (build the app first)" >&2
    exit 1
fi

/usr/libexec/PlistBuddy -c "Print :${PLIST_KEY}" "${INFO_PLIST}"
