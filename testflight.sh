#!/usr/bin/env bash
set -euo pipefail

# TestFlight deployment script for GateOpener (iOS only)
# Usage:
#   ./testflight.sh ios                  # Archive + export + upload iOS
#   ./testflight.sh ios --archive-only    # Archive only; no export, no
#                                          # upload, no bump commit. Restores
#                                          # project.yml afterwards so the
#                                          # tree is left clean.
#
# Env overrides:
#   CLEAN_DERIVED_DATA=1   Wipe ~/Library/Developer/Xcode/DerivedData before
#                          building. Off by default — too aggressive for
#                          routine use in this repo.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

BUILD_DIR="$SCRIPT_DIR/build"
PROJECT_YML="$SCRIPT_DIR/project.yml"
PROJECT_YML_REL="project.yml"
VERSION_FILE="$SCRIPT_DIR/VERSION"
EXPORT_OPTIONS="$SCRIPT_DIR/ExportOptions.plist"

# Load App Store Connect API key credentials
# shellcheck source=/dev/null
[[ -f "$SCRIPT_DIR/.env" ]] && source "$SCRIPT_DIR/.env"
API_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${API_KEY_ID:-}.p8"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}▸${NC} $1"; }
warn() { echo -e "${YELLOW}▸${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; exit 1; }

# --- Preflight checks ---
command -v xcodegen >/dev/null 2>&1 || fail "xcodegen not found. Install with: brew install xcodegen"
[[ -f "$EXPORT_OPTIONS" ]] || fail "ExportOptions.plist not found"
[[ -f "$PROJECT_YML" ]] || fail "project.yml not found"
[[ -n "${API_KEY_ID:-}" ]] || fail "API_KEY_ID not set. Add it to .env"
[[ -n "${API_ISSUER_ID:-}" ]] || fail "API_ISSUER_ID not set. Add it to .env"
[[ -f "$API_KEY_PATH" ]] || fail "API key not found at $API_KEY_PATH"

# --- Git hygiene ---
ensure_clean_worktree() {
    if [[ -n "$(git status --porcelain)" ]]; then
        git status --short
        fail "Git worktree is dirty. Commit or stash changes before running TestFlight deployment."
    fi
}

# --- Sync MARKETING_VERSION from VERSION file into project.yml ---
sync_marketing_version() {
    [[ -f "$VERSION_FILE" ]] || fail "VERSION file not found"
    local version
    version=$(tr -d '[:space:]' < "$VERSION_FILE")
    [[ -n "$version" ]] || fail "VERSION file is empty"
    sed -i '' -E "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"$version\"/" "$PROJECT_YML"
    log "MARKETING_VERSION synced to $version (from VERSION)"
}

commit_version_bump() {
    local build_num="$1"
    local changed=()
    local unexpected=()
    local untracked=()
    local path

    while IFS= read -r -d '' path; do
        changed+=("$path")
    done < <(git -c core.quotepath=false diff --name-only -z)

    while IFS= read -r -d '' path; do
        [[ -n "$path" ]] && untracked+=("$path")
    done < <(git -c core.quotepath=false ls-files --others --exclude-standard -z)

    if [[ "${#untracked[@]}" -gt 0 ]]; then
        printf '%s\n' "${untracked[@]}" >&2
        fail "Unexpected untracked files after successful upload; refusing to auto-commit."
    fi

    [[ "${#changed[@]}" -gt 0 ]] || return 0

    for path in "${changed[@]}"; do
        case "$path" in
            "$PROJECT_YML_REL")
                ;;
            *)
                unexpected+=("$path")
                ;;
        esac
    done

    if [[ "${#unexpected[@]}" -gt 0 ]]; then
        printf '%s\n' "${unexpected[@]}" >&2
        fail "Unexpected files changed after successful upload; refusing to auto-commit."
    fi

    git add -- "$PROJECT_YML_REL"
    git commit -m "Bump iOS build number to $build_num after TestFlight upload"
    log "Committed version bump for build $build_num"
}

# --- Bump build number ---
bump_build_number() {
    local current
    current=$(grep 'CURRENT_PROJECT_VERSION:' "$PROJECT_YML" | head -1 | awk '{print $2}')
    local next=$((current + 1))
    sed -i '' "s/CURRENT_PROJECT_VERSION: $current/CURRENT_PROJECT_VERSION: $next/" "$PROJECT_YML"
    log "Build number: $current → $next" >&2
    echo "$next"
}

# --- Clean DerivedData (opt-in) ---
clean_derived_data() {
    if [[ "${CLEAN_DERIVED_DATA:-0}" != "1" ]]; then
        return 0
    fi
    log "Cleaning DerivedData (CLEAN_DERIVED_DATA=1)..."
    rm -rf ~/Library/Developer/Xcode/DerivedData 2>/dev/null || true
    mkdir -p ~/Library/Developer/Xcode/DerivedData
    log "DerivedData cleaned"
}

# --- Generate Xcode project ---
generate_project() {
    log "Running xcodegen..."
    xcodegen generate --spec "$PROJECT_YML"
    log "Xcode project generated"
}

# --- Archive ---
archive() {
    local scheme="$1"
    local destination="$2"
    local archive_path="$3"
    local log_path="$4"

    log "Archiving $scheme... (log: $log_path)"
    local exit_code=0
    xcodebuild archive \
        -project GateOpener.xcodeproj \
        -scheme "$scheme" \
        -destination "$destination" \
        -archivePath "$archive_path" \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$API_KEY_PATH" \
        -authenticationKeyID "$API_KEY_ID" \
        -authenticationKeyIssuerID "$API_ISSUER_ID" \
        > "$log_path" 2>&1 || exit_code=$?

    if [[ "$exit_code" -ne 0 ]] || [[ ! -d "$archive_path.xcarchive" ]]; then
        echo "--- tail of $log_path ---" >&2
        tail -40 "$log_path" >&2
        fail "Archive failed: $archive_path.xcarchive not found. Full log: $log_path"
    fi

    tail -5 "$log_path"
    log "Archive complete: $archive_path.xcarchive"
}

# --- Export + Upload ---
export_and_upload() {
    local archive_path="$1"
    local export_path="$2"

    log "Exporting and uploading to App Store Connect..."
    local output exit_code=0
    output=$(xcodebuild -exportArchive \
        -archivePath "$archive_path.xcarchive" \
        -exportOptionsPlist "$EXPORT_OPTIONS" \
        -exportPath "$export_path" \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$API_KEY_PATH" \
        -authenticationKeyID "$API_KEY_ID" \
        -authenticationKeyIssuerID "$API_ISSUER_ID" \
        2>&1) || exit_code=$?

    echo "$output" | tail -10

    # xcodebuild can exit 0 but still report failure in output
    if [[ "$exit_code" -ne 0 ]] || echo "$output" | grep -qE "\*\* (EXPORT|BUILD) FAILED \*\*|UPLOAD FAILED|Failed to upload"; then
        echo "$output"
        fail "Export/upload failed. See output above."
    fi

    log "Upload complete!"
}

# --- iOS build ---
build_ios() {
    local build_num="$1"
    local archive_only="$2"
    local archive_path="$BUILD_DIR/GateOpener-iOS-$build_num"
    local archive_log="$BUILD_DIR/ios-$build_num.log"
    local export_path="$BUILD_DIR/ios-export-$build_num"

    archive "GateOpener-iOS" "generic/platform=iOS" "$archive_path" "$archive_log"

    if [[ "$archive_only" == "1" ]]; then
        log "Archive-only mode: skipping export/upload/commit."
        return 0
    fi

    export_and_upload "$archive_path" "$export_path"
    log "iOS build $build_num uploaded to TestFlight"
}

# --- Main ---
main() {
    local platform="${1:-}"
    local archive_only=0

    if [[ "$platform" != "ios" ]]; then
        fail "Usage: ./testflight.sh ios [--archive-only]"
    fi
    shift || true

    for arg in "$@"; do
        case "$arg" in
            --archive-only)
                archive_only=1
                ;;
            *)
                fail "Unknown argument: $arg"
                ;;
        esac
    done

    mkdir -p "$BUILD_DIR"
    ensure_clean_worktree

    log "Starting TestFlight deployment for: $platform"
    echo ""

    sync_marketing_version

    if [[ "$archive_only" == "1" ]]; then
        # No build-number bump in archive-only mode: nothing is uploaded, so
        # there is nothing to attribute a bumped build number to. Use the
        # current CURRENT_PROJECT_VERSION as-is for the archive path/name.
        local build_num
        build_num=$(grep 'CURRENT_PROJECT_VERSION:' "$PROJECT_YML" | head -1 | awk '{print $2}')

        clean_derived_data
        generate_project
        echo ""

        # Always restore project.yml (the MARKETING_VERSION sync) in
        # archive-only mode so the tree is left clean, regardless of archive
        # outcome. A plain `build_ios ... || restore_failed=1` does NOT work
        # here: archive()/fail() call `exit 1` directly on failure, which
        # bypasses `||` entirely (it only catches a non-zero return, not a
        # process exit) and would otherwise leave project.yml dirty. A trap
        # on EXIT runs regardless of how this shell exits — success, `fail`,
        # or a signal.
        trap 'git checkout -- "$PROJECT_YML_REL"' EXIT

        build_ios "$build_num" "1"

        trap - EXIT
        git checkout -- "$PROJECT_YML_REL"
        log "Restored $PROJECT_YML_REL (archive-only mode)"

        echo ""
        log "Archive-only run complete for build $build_num."
        return 0
    fi

    local build_num
    build_num=$(bump_build_number)
    local done_marker="$BUILD_DIR/testflight-$build_num.done"
    rm -f "$done_marker"
    clean_derived_data
    generate_project

    echo ""

    build_ios "$build_num" "0"

    commit_version_bump "$build_num"
    printf 'build=%s\ncompleted_at=%s\n' "$build_num" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" > "$done_marker"

    echo ""
    log "Done! Check App Store Connect for build $build_num"
}

main "$@"
