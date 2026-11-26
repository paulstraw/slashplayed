#!/bin/sh
# Runs the companion's unit tests (apps/companion/Tests; needs xcodegen). Extra arguments go to
# xcodebuild, e.g. -only-testing:SPCompanionTests/ClientAssemblyTests.
set -e
cd "$(dirname "$0")"
OUT=$(cd ../.. && pwd)/build/companion-tests
./idevice-config.sh
xcodegen generate --quiet
# xcodebuild gives the tests only TEST_RUNNER_-prefixed variables, not DEVELOPER_DIR, so a test's xcrun
# falls back to xcode-select's choice: often the Command Line Tools, whose older llvm-cxxfilt leaves Rust
# symbols mangled (AcknowledgementsTests then finds no crates). Hand the tests the Xcode that builds them.
if [ -n "${DEVELOPER_DIR:-}" ]; then export TEST_RUNNER_DEVELOPER_DIR="$DEVELOPER_DIR"; fi
# No test diagnostics: by default xcodebuild spends ~8 s after the last test collecting a system log
# archive into the result bundle (235 MB against 1.7 MB without), even when every test passed. A
# caller after one for a failure can still ask: a later -collect-test-diagnostics in "$@" wins.
xcodebuild -project SPCompanion.xcodeproj -scheme SPCompanion -derivedDataPath "$OUT" -quiet test \
  -collect-test-diagnostics never "$@"
