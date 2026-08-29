# Resolves CODESIGN_IDENTITY: the code-signing identity used for both
# GateOpener.app (scripts/build-app.sh) and its DMG (scripts/make-dmg.sh).
#
# Meant to be SOURCED, not executed, from another script's `set -euo
# pipefail` context, e.g.:
#
#   # shellcheck source=lib/resolve-codesign-identity.sh
#   source "${SCRIPT_DIR}/lib/resolve-codesign-identity.sh"
#
# Behaviour (must stay identical between build-app.sh and make-dmg.sh so a
# rebuilt app and its DMG are always signed with the same identity):
#   1. If CODESIGN_IDENTITY is already set in the environment, use it as-is
#      (lets an operator pin an exact identity).
#   2. Otherwise auto-detect the first "Developer ID Application: ..."
#      identity in the login keychain via `security find-identity`.
#   3. If neither is available, CODESIGN_IDENTITY is left empty — callers
#      decide for themselves whether an empty identity (ad-hoc fallback) is
#      acceptable for their artifact.
#
# A Developer ID identity is keyed on identifier + team, so it is STABLE
# across rebuilds. An ad-hoc identity (`--sign -`) is derived from the
# binary's own hash and therefore changes on every rebuild, which resets
# any keychain "Always Allow" grant. Preferring Developer ID is what keeps
# the operator from being re-prompted for Comelit keychain access after
# every rebuild (see bead gateopener-sal).
#
# On exit: CODESIGN_IDENTITY is set (possibly to "").

if [ -z "${CODESIGN_IDENTITY:-}" ]; then
    CODESIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
fi
