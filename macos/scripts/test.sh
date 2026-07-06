#!/bin/bash
# Runs the PenBoard test suite.
#
# Why this script exists (not just `swift test`): this machine has Xcode
# Command Line Tools only, no Xcode.app. CLT ships `Testing.framework` (Swift
# Testing) but does not put it on the default compiler/linker search paths,
# and it does not ship `XCTest.framework` at all. `Package.swift` adds the
# needed `-F`/`-L`/`-rpath` flags to the `PenBoardTests` target itself, but
# SwiftPM's auto-generated test-runner aggregator module (which contains the
# `import Testing` entry point) is built as a separate, implicit target that
# does not inherit per-target Package.swift settings — so plain `swift test`
# silently compiles and exits 0 having run zero tests. Passing the same flags
# on the command line applies them to every module SwiftPM builds, including
# that aggregator, which is what makes tests actually run.
#
# On a machine with full Xcode.app installed, none of this is needed — CLT_DIR
# below resolves to the Xcode toolchain instead, the extra search paths won't
# exist, and this script degrades to a plain `swift test`.
set -euo pipefail

CLT_DIR="$(xcode-select -p)"
TESTING_FRAMEWORKS_DIR="$CLT_DIR/Library/Developer/Frameworks"
TESTING_LIB_DIR="$CLT_DIR/Library/Developer/usr/lib"

EXTRA_FLAGS=()
if [ -d "$TESTING_FRAMEWORKS_DIR" ]; then
	EXTRA_FLAGS+=(
		-Xswiftc -F -Xswiftc "$TESTING_FRAMEWORKS_DIR"
		-Xlinker -F -Xlinker "$TESTING_FRAMEWORKS_DIR"
		-Xlinker -rpath -Xlinker "$TESTING_FRAMEWORKS_DIR"
	)
fi
if [ -d "$TESTING_LIB_DIR" ]; then
	EXTRA_FLAGS+=(
		-Xlinker -L -Xlinker "$TESTING_LIB_DIR"
		-Xlinker -rpath -Xlinker "$TESTING_LIB_DIR"
	)
fi

cd "$(dirname "$0")/.."
exec swift test "${EXTRA_FLAGS[@]}" "$@"
