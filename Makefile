.PHONY: build test run clean release xcodeproj ios-build ios-sim-build ios-sim-run ios-test testflight-archive

build:
	swift build

test:
	swift test

run:
	swift run GateOpener

clean:
	swift package clean
	rm -rf .build

# Regenerates GateOpener.xcodeproj from project.yml via xcodegen. The
# generated project is gitignored; regenerate on demand rather than editing
# it by hand.
xcodeproj:
	xcodegen generate --spec project.yml

# Regenerates the Xcode project and builds the iOS app target for the
# Simulator, without code signing (no team-provisioned device involved).
# Does not disturb the SwiftPM build of the macOS app (`make build`/`test`).
ios-build: xcodeproj
	xcodebuild -project GateOpener.xcodeproj -scheme GateOpener-iOS \
		-destination 'generic/platform=iOS Simulator' \
		-derivedDataPath .build/xcode build CODE_SIGNING_ALLOWED=NO

# Builds the iOS app SIGNED for a concrete simulator device, so the
# app's entitlements (application-groups, keychain-access-groups) are
# actually embedded and honoured — CODE_SIGNING_ALLOWED=NO (as used by
# `ios-build` above) skips code signing entirely, and an unsigned app has
# no entitlements, so `KeychainCredentialStore(accessGroup:)` fails on the
# very first save with `KeychainError.saveFailed(status: -34018)`
# (errSecMissingEntitlement). Needed to verify sign-in and Keychain
# behaviour end to end on the simulator.
#
# Signing approach: this uses project.yml's existing automatic signing
# (CODE_SIGN_STYLE: Automatic, DEVELOPMENT_TEAM: Y5SB82BPYL, debug
# CODE_SIGN_IDENTITY "Apple Development") completely unmodified — i.e. no
# xcodebuild-level CODE_SIGN_IDENTITY/CODE_SIGNING_ALLOWED overrides at
# all. Forcing CODE_SIGN_IDENTITY="-" (ad hoc) or ="Apple Development" on
# the xcodebuild command line made no difference to the outcome below, so
# neither override is used.
#
# What actually happens (Xcode 26 / iphonesimulator SDK), confirmed by
# inspection: xcodebuild always code-signs simulator builds ad hoc
# ("Sign to Run Locally", TeamIdentifier=not set), regardless of
# CODE_SIGN_IDENTITY — `codesign -d --entitlements :-` on the resulting
# .app therefore legitimately reports an EMPTY entitlements dict, and
# that is expected, not a failure. The real entitlements
# (application-groups, keychain-access-groups, with $(AppIdentifierPrefix)
# resolved to the team ID) are instead embedded as a "Simulated
# entitlements" Mach-O section (__TEXT,__entitlements) in the app
# binary — this is the mechanism the Simulator OS actually reads for
# keychain/app-group access checks, and it is populated correctly
# whenever CODE_SIGN_ENTITLEMENTS (project.yml) points at a real
# .entitlements file, independent of the ad hoc code signature. Verify
# with:
#   otool -s __TEXT __entitlements <path>/GateOpener.app/GateOpener
# (bytes appear as 32-bit big-endian words from otool -s; each 4-byte
# group must be byte-swapped back to get the plist XML).
SIM_DEVICE ?= iPhone 17 Pro
ios-sim-build: xcodeproj
	xcodebuild -project GateOpener.xcodeproj -scheme GateOpener-iOS \
		-destination 'platform=iOS Simulator,name=$(SIM_DEVICE)' \
		-derivedDataPath .build/xcode build

IOS_APP_BUNDLE_ID := ie.boboco.GateOpener
IOS_APP_PATH := .build/xcode/Build/Products/Debug-iphonesimulator/GateOpener.app

# Boots the target simulator (if needed), installs the signed build from
# `ios-sim-build`, and launches it. Pass extra launch arguments via
# SIM_ARGS, e.g.:
#   make ios-sim-run SIM_ARGS="--signin-debug-attempt user@example.com pass"
ios-sim-run: ios-sim-build
	xcrun simctl boot "$(SIM_DEVICE)" 2>/dev/null || true
	xcrun simctl uninstall booted $(IOS_APP_BUNDLE_ID) 2>/dev/null || true
	xcrun simctl install booted $(IOS_APP_PATH)
	xcrun simctl launch booted $(IOS_APP_BUNDLE_ID) $(SIM_ARGS)

# Runs the GateOpener-iOSTests unit-test bundle (bead gateopener-672.18),
# hosted by the GateOpener-iOS app target, on the Simulator. Reuses
# SIM_DEVICE (default "iPhone 17 Pro", see above) so this targets the same
# device family as ios-sim-build/ios-sim-run.
ios-test: xcodeproj
	xcodebuild test -project GateOpener.xcodeproj -scheme GateOpener-iOS \
		-destination 'platform=iOS Simulator,name=$(SIM_DEVICE)' \
		-derivedDataPath .build/xcode

# Publishes a GitHub release: generates the update manifest (appcast.json)
# describing the just-built, notarized DMG, then uploads both as release
# assets via `gh release create`. See scripts/publish-release.sh for the
# full precondition list and rationale (never a shell literal for the
# version, working tree must be clean, tag must not already exist, DMG
# must exist and pass notarization).
#
# Deliberately NOT a dependency of `build`, `test`, `all`, or the default
# target, and not listed first in this Makefile (make's default target is
# the first target, `build`) — `make` and `make all` must never publish a
# release as a side effect. Only `make release`, invoked deliberately by a
# human operator, runs this.
release:
	scripts/publish-release.sh

# Archives the iOS app via testflight.sh in --archive-only mode: verifies
# automatic signing and provisioning end to end without exporting or
# uploading anything to App Store Connect, and without committing a
# build-number bump. See testflight.sh and the README's "iOS app
# (TestFlight)" section.
testflight-archive:
	./testflight.sh ios --archive-only
