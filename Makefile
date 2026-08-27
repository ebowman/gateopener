.PHONY: build test run clean

build:
	swift build

test:
	swift test

run:
	swift run GateOpener

clean:
	swift package clean
	rm -rf .build
