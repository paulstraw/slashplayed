#!/bin/bash
# guesttest, spguest's test (../spguest.c, the launcher's loader; research/guestloadtest/README.md has the
# research and the device runs).
#   ./build.sh mac      builds the toy guest and the Mac host, and runs the toy on the Mac, then tries broken
#                       copies of it (malformed.c): exits non-zero on any failed check, or a broken copy taken or
#                       crashed on. CI runs it with SP_GUEST_REFS=none (.github/workflows/ci.yml).
#   ./build.sh device   builds the toy and SPGuestLoadTest.app (the device host, with the on-device JIT helper,
#                       PlugIns/SPJitHelper.appex), signs it, and installs it. The toy itself is never signed:
#                       run.sh copies it into the app's Documents/.
# Device env as research/jittest/build.sh: SP_PLATFORM, SP_DEVICE, SP_TEAM, SP_SIGN_ID (config/local.env unless
# set), SP_PROFILE and SP_HELPER_PROFILE (the newest Xcode-managed profiles for the two bundle IDs,
# apps/client/signing/regen.sh). SP_GUEST_BUNDLE_ID installs it as another test app that already has
# profiles (com.strawdynamics.spdlopentest, whose container already holds the pairing record and the disk
# image). SP_NO_INSTALL=1 stops after signing.
set -euo pipefail
cd "$(dirname "$0")"
OUT=out
mkdir -p $OUT
MODE=${1:-mac}
case $MODE in mac|device) ;; *) echo "usage: build.sh mac|device" >&2; exit 1 ;; esac

# The guest: an MH_EXECUTE like the client (dyld-info fixups from macOS 11.0), exporting its symbols. It's a
# macOS program on the device too: the loader, not the OS, decides what runs it.
# SP_GUEST_REFS (default retail; none to skip) names a game whose imports the toy takes too, all of them, from
# the same libraries, as research/loadertest does: refs.c (gen_refs.py, symbol names only) from that game's
# local recon (scripts/recon/regen.sh's work/regen/<platform>/<game>/imports.json) and thinned client. Nothing
# from either is committed; out/ is ignored.
REFS=${SP_GUEST_REFS:-retail}
TOY_EXTRA=(-framework Foundation)
if [ "$REFS" != none ]; then
  RECON=../../../work/regen/${SP_PLATFORM:-xros}/$REFS/imports.json
  CLIENT=../../../work/$([ "$REFS" = classic_era ] || echo "$REFS/")wow-arm64
  [ -f "$RECON" ] && [ -f "$CLIENT" ] ||
    { echo "build.sh: no $RECON or $CLIENT for SP_GUEST_REFS=$REFS (scripts/recon/regen.sh; or SP_GUEST_REFS=none)" >&2; exit 1; }
  python3 ../../../research/loadertest/gen_refs.py "$RECON" "$CLIENT" $OUT/refs.c
  # The client's frameworks, in its order. The client's older SDK exported exp2/log2/modff from
  # CoreServices and today's .tbd doesn't, so link against a copy that does (loadertest's fix).
  SDK=$(xcrun --sdk macosx --show-sdk-path)
  mkdir -p $OUT/fw/CoreServices.framework
  awk '/^--- !tapi-tbd/ && ++n == 2 { print "exports:\n  - targets: [ arm64e-macos ]\n    symbols: [ _exp2, _log2, _modff ]" } 1' \
    "$SDK/System/Library/Frameworks/CoreServices.framework/CoreServices.tbd" > $OUT/fw/CoreServices.framework/CoreServices.tbd
  clang -arch arm64 -mmacosx-version-min=11.0 -O1 -w -c $OUT/refs.c -o $OUT/refs.o
  # shellcheck disable=SC2207 # one -framework pair per line
  TOY_EXTRA=(-DSP_REFS $OUT/refs.o -Wl,-F,$OUT/fw $(otool -L "$CLIENT" | sed -n 's|^.*/\([A-Za-z]*\)\.framework/.*|-framework \1|p')
    -lc++abi -lbsm)
fi
clang++ -std=c++17 -arch arm64 -mmacosx-version-min=11.0 -fobjc-arc -O1 -Wall -x objective-c++ toy.mm -x none \
  "${TOY_EXTRA[@]}" -Wl,-export_dynamic -Wl,-U,_sp_missing_weak -o $OUT/toy-guest
echo "toy: $(dyld_info -fixups $OUT/toy-guest | grep -c ' ') fixup lines (dyld-info opcodes), imports from SP_GUEST_REFS=$REFS"

if [ "$MODE" = mac ]; then
  # The host links the loader; it is a different program from the guest, so the guest is never dyld-loaded.
  clang -arch arm64 -mmacosx-version-min=11.0 -O1 -Wall -I .. host.c ../spguest.c ../spguest_tlv.S -o $OUT/host
  codesign -f -s - $OUT/host
  rm -f $OUT/toy.log
  SP_GUEST_LOG=$OUT/toy.log $OUT/host $OUT/toy-guest
  # Broken copies of the toy, each of which spguest must refuse with its reason, not crash on (malformed.c).
  clang -arch arm64 -mmacosx-version-min=11.0 -O1 -Wall -I .. malformed.c ../spguest.c ../spguest_tlv.S -o $OUT/malformed
  codesign -f -s - $OUT/malformed
  $OUT/malformed $OUT/toy-guest $OUT
  exit
fi

. ../../../scripts/platform.sh
sp_need SP_TEAM SP_SIGN_ID
BUNDLE_ID=${SP_GUEST_BUNDLE_ID:-com.strawdynamics.spguestloadtest}
HELPER_ID=$BUNDLE_ID.helper
: "${SP_PROFILE:=$(sp_profile "$BUNDLE_ID")}"
: "${SP_HELPER_PROFILE:=$(sp_profile "$HELPER_ID")}"
[ -f "$SP_PROFILE" ] && [ -f "$SP_HELPER_PROFILE" ] ||
  { echo "build.sh: no development profile for $BUNDLE_ID or $HELPER_ID (apps/client/signing/regen.sh <device UDID>, or SP_GUEST_BUNDLE_ID)" >&2; exit 1; }
APP=$OUT/SPGuestLoadTest.app
HELPER=$APP/PlugIns/SPJitHelper.appex
HELPER_SRC=../helper
IDEVICE=../../../work/idevice
[ -f "$IDEVICE/$SP_PLATFORM"/libidevice_ffi.a ] ||
  { echo "build.sh: no $IDEVICE/$SP_PLATFORM/libidevice_ffi.a: the helper needs idevice (scripts/build-idevice.sh $SP_PLATFORM)" >&2; exit 1; }
NATIVE_LIBS=$(cat "$IDEVICE/$SP_PLATFORM"/native-libs.txt)
SWIFTC="xcrun --sdk $SP_SDK swiftc -target $SP_TARGET -O -parse-as-library"
CC="xcrun --sdk $SP_SDK clang -target $SP_TARGET -O1 -Wall"

rm -rf $APP && mkdir -p $APP $HELPER
$CC -I .. -c device.c -o $OUT/device.o
$CC -c ../spguest.c -o $OUT/spguest.o
$CC -c ../spguest_tlv.S -o $OUT/spguest_tlv.o
# shellcheck disable=SC2086 # NATIVE_LIBS is a list of linker flags
$SWIFTC -D SP_IDEVICE -I $IDEVICE/include -I $HELPER_SRC/iokit ../../../research/jittest/helper_host.swift $HELPER_SRC/Device.swift \
  $OUT/device.o $OUT/spguest.o $OUT/spguest_tlv.o "$IDEVICE/$SP_PLATFORM"/libidevice_ffi.a $NATIVE_LIBS \
  -framework Foundation -Xlinker -rpath -Xlinker @executable_path/Frameworks -o $APP/SPGuestLoadTest
# The shims as they are, in Frameworks/, and the map that sends the toy's libraries to them (device.c).
../../../shims/build.sh "$SP_PLATFORM"
mkdir -p $APP/Frameworks
cp ../../../build/"$SP_PLATFORM"/*.dylib $APP/Frameworks/
cp ../../../shims/generated/rewrite-map.txt $APP/
sp_plist Info.plist $APP/Info.plist "$BUNDLE_ID"
cp "$SP_PROFILE" $APP/embedded.mobileprovision

# The helper, the client's own (research/jittest/README.md, "The helper extension").
# shellcheck disable=SC2086
$SWIFTC -application-extension -Xlinker -e -Xlinker _NSExtensionMain -D SP_IDEVICE \
  -I $IDEVICE/include -I $HELPER_SRC/iokit $HELPER_SRC/Helper.swift $HELPER_SRC/Device.swift $HELPER_SRC/Pair.swift \
  "$IDEVICE/$SP_PLATFORM"/libidevice_ffi.a $NATIVE_LIBS -o $HELPER/SPJitHelper
sp_plist $HELPER_SRC/Info.plist $HELPER/Info.plist "$HELPER_ID"
cp "$SP_HELPER_PROFILE" $HELPER/embedded.mobileprovision

entitlements() {
  cat <<EOT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>application-identifier</key><string>$SP_TEAM.$1</string>
  <key>com.apple.developer.team-identifier</key><string>$SP_TEAM</string>
  <key>get-task-allow</key><true/>
</dict></plist>
EOT
}
entitlements "$BUNDLE_ID" > $OUT/entitlements.plist
entitlements "$HELPER_ID" > $OUT/helper-entitlements.plist
# Inside out: the libraries and the helper are sealed into the app's signature, so they're signed first.
codesign -f -s "$SP_SIGN_ID" $APP/Frameworks/*.dylib
codesign -f -s "$SP_SIGN_ID" --entitlements $OUT/helper-entitlements.plist $HELPER
codesign -f -s "$SP_SIGN_ID" --entitlements $OUT/entitlements.plist $APP
[ -z "${SP_NO_INSTALL:-}" ] || exit 0
sp_need_device
xcrun devicectl device install app --device "$SP_DEVICE" $APP
