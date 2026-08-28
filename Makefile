.PHONY: build test run clean release

build:
	swift build

test:
	swift test

run:
	swift run GateOpener

clean:
	swift package clean
	rm -rf .build

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
