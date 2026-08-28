#!/bin/bash
# Assembles a signed, distributable DMG of GateOpener.app: builds (or
# reuses) the signed .app, stages it in a temp directory alongside an
# /Applications symlink for drag-to-install, packs that into a read-only
# compressed disk image, and code-signs the DMG itself.
#
# Usage: scripts/make-dmg.sh
# Output: GateOpener-<version>.dmg in the repo root (path printed on
#         success). <version> is CFBundleShortVersionString read back OUT
#         of the just-built bundle via scripts/read-app-version.sh, never
#         from the repo's VERSION file directly — the filename must
#         reflect what was actually built.
#
# This script ALWAYS runs scripts/build-app.sh first rather than requiring
# a pre-built .app: build-app.sh is itself idempotent/fast to rerun, and
# always building from source guarantees the DMG can never silently
# contain a stale bundle left over from an earlier checkout.
#
# Signing: the DMG is signed with the same Developer ID identity as the
# .app (see scripts/lib/resolve-codesign-identity.sh, shared with
# build-app.sh so the two never drift). Unlike build-app.sh, this script
# does NOT fall back to ad-hoc signing by default — an ad-hoc-signed DMG
# can never be notarized (see bead gateopener-c33.3), so shipping one
# under a release filename would be a silently unusable artifact. Set
# ALLOW_ADHOC_DMG=1 to explicitly opt into an ad-hoc-signed DMG for local
# testing only; such a DMG must never be distributed.
#
# Idempotent: safe to run repeatedly. Removes any DMG already at the
# target path before creating the new one, and cleans up its staging
# directory and mount point on both success and failure via trap.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_NAME="GateOpener"
APP_BUNDLE="${REPO_ROOT}/${APP_NAME}.app"
VOLUME_NAME="${APP_NAME}"

STAGING_DIR=""
MOUNT_POINT=""

cleanup() {
    # Detach unconditionally when a mount point was recorded, tolerating
    # failure, rather than gating on `mount | grep`. mktemp under TMPDIR
    # returns an UNRESOLVED path (/var/folders/...) while mount(8) prints the
    # RESOLVED one (/private/var/folders/...), so that guard never matched on
    # stock macOS and the detach was silently skipped — leaking a /Volumes
    # mount on every failure, which is precisely what this trap exists to
    # prevent. `|| true` keeps cleanup safe when nothing is attached.
    if [ -n "${MOUNT_POINT}" ]; then
        hdiutil detach "${MOUNT_POINT}" -quiet -force 2>/dev/null || true
    fi
    if [ -n "${STAGING_DIR}" ] && [ -d "${STAGING_DIR}" ]; then
        rm -rf "${STAGING_DIR}"
    fi
}
trap cleanup EXIT

echo "==> Building ${APP_NAME}.app..."
"${SCRIPT_DIR}/build-app.sh"

if [ ! -d "${APP_BUNDLE}" ]; then
    echo "error: expected ${APP_BUNDLE} after build-app.sh, but it is missing" >&2
    exit 1
fi

# Read the version back OUT of the built bundle, matching build-app.sh's
# own approach, so the DMG filename always reflects what was actually
# built rather than what the VERSION file merely intends.
SHORT_VERSION="$("${SCRIPT_DIR}/read-app-version.sh" "${APP_BUNDLE}" short)"
if [ -z "${SHORT_VERSION}" ]; then
    echo "error: could not read version from ${APP_BUNDLE}" >&2
    exit 1
fi

DMG_NAME="${APP_NAME}-${SHORT_VERSION}.dmg"
DMG_PATH="${REPO_ROOT}/${DMG_NAME}"

# Same identity-resolution logic as build-app.sh (see the sourced file for
# rationale) so the app and its DMG are always signed with the same
# identity.
# shellcheck source=lib/resolve-codesign-identity.sh
source "${SCRIPT_DIR}/lib/resolve-codesign-identity.sh"

if [ -z "${CODESIGN_IDENTITY}" ]; then
    if [ "${ALLOW_ADHOC_DMG:-}" = "1" ]; then
        echo "==> WARNING: no Developer ID identity found; ALLOW_ADHOC_DMG=1 set," >&2
        echo "    so proceeding with an ad-hoc-signed DMG. This DMG can NEVER be" >&2
        echo "    notarized and must not be distributed — local testing only." >&2
    else
        echo "error: no Developer ID Application identity found (and CODESIGN_IDENTITY is unset)." >&2
        echo "       An ad-hoc-signed DMG can never be notarized, so refusing to produce one" >&2
        echo "       under a release filename. Install a Developer ID certificate, set" >&2
        echo "       CODESIGN_IDENTITY explicitly, or set ALLOW_ADHOC_DMG=1 to override for" >&2
        echo "       local testing only (such a DMG must not be distributed)." >&2
        exit 1
    fi
fi

# Confirm the .app itself is signed with the identity we're about to sign
# the DMG with (or is at least signed at all, in the ad-hoc opt-out case),
# rather than silently packaging an unsigned or differently-signed bundle.
echo "==> Verifying ${APP_NAME}.app signature..."
codesign -dv "${APP_BUNDLE}"

echo "==> Staging DMG contents..."
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gateopener-dmg-staging.XXXXXX")"
cp -R "${APP_BUNDLE}" "${STAGING_DIR}/${APP_NAME}.app"
ln -s /Applications "${STAGING_DIR}/Applications"

echo "==> Removing any pre-existing DMG at ${DMG_PATH}..."
rm -f "${DMG_PATH}"

echo "==> Creating ${DMG_NAME}..."
hdiutil create \
    -volname "${VOLUME_NAME}" \
    -srcfolder "${STAGING_DIR}" \
    -format UDZO \
    -ov \
    "${DMG_PATH}"

if [ -n "${CODESIGN_IDENTITY}" ]; then
    echo "==> Code-signing ${DMG_NAME} with: ${CODESIGN_IDENTITY}"
    codesign --force --sign "${CODESIGN_IDENTITY}" --timestamp=none "${DMG_PATH}"
else
    echo "==> Ad-hoc code-signing ${DMG_NAME} (ALLOW_ADHOC_DMG=1; local testing only)..."
    codesign --force --sign - "${DMG_PATH}"
fi

echo "==> Verifying DMG signature..."
codesign -dv "${DMG_PATH}"

echo "==> Verifying mounted DMG contents..."
MOUNT_POINT="$(mktemp -d "${TMPDIR:-/tmp}/gateopener-dmg-mount.XXXXXX")"
rmdir "${MOUNT_POINT}"
hdiutil attach "${DMG_PATH}" -mountpoint "${MOUNT_POINT}" -nobrowse -quiet -readonly

if [ ! -d "${MOUNT_POINT}/${APP_NAME}.app" ]; then
    echo "error: ${APP_NAME}.app not found inside mounted DMG" >&2
    exit 1
fi
if [ ! -L "${MOUNT_POINT}/Applications" ]; then
    echo "error: /Applications symlink not found inside mounted DMG" >&2
    exit 1
fi

codesign -dv "${MOUNT_POINT}/${APP_NAME}.app"

hdiutil detach "${MOUNT_POINT}" -quiet
MOUNT_POINT=""

echo "==> Done: ${DMG_PATH}"
