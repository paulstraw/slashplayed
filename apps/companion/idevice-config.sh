#!/bin/bash
# Writes Generated/idevice.xcconfig, which links the companion against idevice's static library for the
# Mac (Sources/Pairing.swift): the header's module, the universal archive, and the system libraries rustc
# says it needs (work/idevice/macos/native-libs.txt). build.sh, test.sh and the release script run this
# before xcodebuild. The library comes from scripts/build-idevice.sh macos, built from source at a pinned
# commit; it isn't committed.
set -euo pipefail
cd "$(dirname "$0")"
IDEVICE=../../work/idevice
for f in "$IDEVICE/include/idevice.h" "$IDEVICE/include/module.modulemap" "$IDEVICE/macos/libidevice_ffi.a" \
         "$IDEVICE/macos/native-libs.txt"; do
  [ -f "$f" ] || { echo "idevice-config: no ${f#../../} (run scripts/build-idevice.sh macos)" >&2; exit 1; }
done
mkdir -p Generated
# Paths relative to the project (SRCROOT), so the file names no one's home directory. Quoted: these two
# settings are lists, split on spaces, and SRCROOT may have one ("/Volumes/SSK SSD/...").
cat > Generated/idevice.xcconfig <<XCCONFIG
// Written by idevice-config.sh; not committed.
SP_IDEVICE_DIR = \$(SRCROOT)/../../work/idevice
SWIFT_INCLUDE_PATHS = \$(inherited) "\$(SP_IDEVICE_DIR)/include"
OTHER_LDFLAGS = \$(inherited) "\$(SP_IDEVICE_DIR)/macos/libidevice_ffi.a" $(cat "$IDEVICE/macos/native-libs.txt")
XCCONFIG
