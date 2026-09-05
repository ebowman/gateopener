.PHONY: build test run clean release xcodeproj ios-build

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
