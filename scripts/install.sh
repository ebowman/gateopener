#!/bin/bash
# Builds GateOpener.app (via build-app.sh) and installs it into
# /Applications/GateOpener.app, replacing any existing copy.
#
# Usage: scripts/install.sh
#
# - Quits any running GateOpener instance first and waits for it to exit.
# - Copies the bundle into /Applications atomically (temp path + mv), so a
#   failure partway through never leaves a half-installed app.
# - Never invokes sudo. If /Applications is not writable, prints the exact
#   command for the operator to run and exits non-zero.
# - Verifies the ad-hoc signature survives the copy.
# - Relaunches the app from /Applications.
#
# Idempotent: safe to run repeatedly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_NAME="GateOpener"
SRC_BUNDLE="${REPO_ROOT}/${APP_NAME}.app"
DEST_DIR="/Applications"
DEST_BUNDLE="${DEST_DIR}/${APP_NAME}.app"
DEST_BIN="${DEST_BUNDLE}/Contents/MacOS/${APP_NAME}"

QUIT_TIMEOUT_SECS=15

echo "==> Building ${APP_NAME}.app..."
"${SCRIPT_DIR}/build-app.sh"

if [ ! -d "${SRC_BUNDLE}" ]; then
    echo "error: expected built bundle at ${SRC_BUNDLE} but it does not exist" >&2
    exit 1
fi

# --- Step: quit any running instance and wait for it to exit -----------

is_gateopener_running() {
    pgrep -f "${APP_NAME}\.app/Contents/MacOS/${APP_NAME}" >/dev/null 2>&1
}

if is_gateopener_running; then
    echo "==> Quitting running ${APP_NAME} instance..."
    osascript -e "tell application \"${APP_NAME}\" to quit" >/dev/null 2>&1 || true

    waited=0
    while is_gateopener_running && [ "${waited}" -lt "${QUIT_TIMEOUT_SECS}" ]; do
        sleep 1
        waited=$((waited + 1))
    done

    if is_gateopener_running; then
        echo "    osascript quit did not stop it; trying pkill..."
        pkill -f "${APP_NAME}\.app/Contents/MacOS/${APP_NAME}" || true

        waited=0
        while is_gateopener_running && [ "${waited}" -lt "${QUIT_TIMEOUT_SECS}" ]; do
            sleep 1
            waited=$((waited + 1))
        done
    fi

    if is_gateopener_running; then
        echo "error: ${APP_NAME} is still running after waiting ${QUIT_TIMEOUT_SECS}s for" \
             "osascript quit and pkill. Quit it manually (e.g. Activity Monitor) and re-run" \
             "this script." >&2
        exit 1
    fi
    echo "    ${APP_NAME} exited."
else
    echo "==> ${APP_NAME} is not currently running; nothing to quit."
fi

# --- Step: copy into /Applications atomically ---------------------------

echo "==> Installing into ${DEST_DIR}..."

if [ ! -w "${DEST_DIR}" ]; then
    echo "error: ${DEST_DIR} is not writable by $(whoami)." >&2
    echo "This script never invokes sudo on its own. Run this command yourself:" >&2
    echo "" >&2
    echo "    sudo rm -rf \"${DEST_BUNDLE}\" && sudo cp -R \"${SRC_BUNDLE}\" \"${DEST_DIR}/\"" >&2
    echo "" >&2
    exit 1
fi

TMP_BUNDLE="${DEST_DIR}/.${APP_NAME}.app.install-tmp.$$"

cleanup_tmp() {
    if [ -d "${TMP_BUNDLE}" ]; then
        rm -rf "${TMP_BUNDLE}"
    fi
}
trap cleanup_tmp EXIT

rm -rf "${TMP_BUNDLE}"
if ! cp -R "${SRC_BUNDLE}" "${TMP_BUNDLE}"; then
    echo "error: failed to copy ${SRC_BUNDLE} into ${DEST_DIR}." >&2
    echo "This script never invokes sudo on its own. Run this command yourself:" >&2
    echo "" >&2
    echo "    sudo rm -rf \"${DEST_BUNDLE}\" && sudo cp -R \"${SRC_BUNDLE}\" \"${DEST_DIR}/\"" >&2
    echo "" >&2
    exit 1
fi

OLD_BUNDLE_BACKUP=""
if [ -d "${DEST_BUNDLE}" ]; then
    OLD_BUNDLE_BACKUP="${DEST_DIR}/.${APP_NAME}.app.previous.$$"
    if ! mv "${DEST_BUNDLE}" "${OLD_BUNDLE_BACKUP}"; then
        echo "error: could not move existing ${DEST_BUNDLE} out of the way. The previous" \
             "install (if any) has been left untouched at ${DEST_BUNDLE}." >&2
        exit 1
    fi
fi

if ! mv "${TMP_BUNDLE}" "${DEST_BUNDLE}"; then
    echo "error: failed to move new bundle into place at ${DEST_BUNDLE}." >&2
    if [ -n "${OLD_BUNDLE_BACKUP}" ] && [ -d "${OLD_BUNDLE_BACKUP}" ]; then
        echo "Restoring previous install..." >&2
        mv "${OLD_BUNDLE_BACKUP}" "${DEST_BUNDLE}" || \
            echo "error: could not restore previous install either; it is sitting at" \
                 "${OLD_BUNDLE_BACKUP}" >&2
    fi
    exit 1
fi

# Swap succeeded; drop the backup of the old bundle, if any.
if [ -n "${OLD_BUNDLE_BACKUP}" ] && [ -d "${OLD_BUNDLE_BACKUP}" ]; then
    rm -rf "${OLD_BUNDLE_BACKUP}"
fi

trap - EXIT
cleanup_tmp

echo "    Installed to ${DEST_BUNDLE}"

# --- Step: verify signature survived the copy ---------------------------

echo "==> Verifying code signature..."
if ! codesign --verify --deep --strict "${DEST_BUNDLE}"; then
    echo "error: codesign --verify --deep --strict failed for ${DEST_BUNDLE}." >&2
    echo "The installed app's signature did not survive the copy. This will silently" >&2
    echo "break Keychain access and Launch-at-Login (SMAppService) with confusing" >&2
    echo "symptoms (e.g. 'wrong password' prompts). Do not use this install." >&2
    exit 1
fi
echo "    Signature OK."

# --- Step: relaunch from /Applications -----------------------------------

echo "==> Launching ${DEST_BUNDLE}..."
open "${DEST_BUNDLE}"

echo ""
echo "==> Done."
echo "    ${APP_NAME}.app is installed at: ${DEST_BUNDLE}"
echo "    Launched from /Applications."
echo ""
echo "    Note: because the app is ad-hoc signed and just moved to a new path," \
     "macOS may prompt for Keychain access the first time it runs from here." \
     "That prompt is expected, not a bug."
