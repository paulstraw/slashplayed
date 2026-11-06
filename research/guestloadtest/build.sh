#!/bin/sh
# guestloadtest. ./build.sh mac   builds the toy guest and the loader's host and runs the toy on the Mac.
set -euo pipefail
cd "$(dirname "$0")"
OUT=out
mkdir -p $OUT
# The guest: an MH_EXECUTE like the client (dyld-info fixups from macOS 11.0), exporting its symbols.
clang++ -std=c++17 -arch arm64 -mmacosx-version-min=11.0 -fobjc-arc -O1 -Wall -x objective-c++ toy.mm \
  -framework Foundation -Wl,-export_dynamic -Wl,-U,_sp_missing_weak -o $OUT/toy-guest
# The host links the loader; it is a different program from the guest, so the guest is never dyld-loaded.
clang -arch arm64 -mmacosx-version-min=11.0 -O1 -Wall host.c spguest.c spguest_tlv.S -o $OUT/host
codesign -f -s - $OUT/host
echo "toy: $(dyld_info -fixups $OUT/toy-guest | grep -c ' ')"' fixup lines (dyld-info opcodes)'
rm -f $OUT/toy.log
SP_GUEST_LOG=$OUT/toy.log $OUT/host $OUT/toy-guest
