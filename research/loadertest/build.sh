#!/bin/sh
# Phase 2 loader proof. ./build.sh [mac]
#   mac: build the macOS binary and run it locally, unrewritten.
#   default: also rewrite its load commands (rewrite-map.txt), bundle the shims, sign, install.
# Needs Classic Era's imports.json from scripts/recon/regen.sh, run with the same SP_PLATFORM.
# Env as research/jittest/build.sh.
set -e
cd "$(dirname "$0")"
. ../../scripts/platform.sh
sp_need SP_TEAM SP_SIGN_ID
RECON=../../work/regen/$SP_PLATFORM/classic_era
CLIENT=../../work/wow-arm64
BUNDLE_ID=com.strawdynamics.sploader
: "${SP_PROFILE:=$(sp_profile $BUNDLE_ID)}"
OUT=out
APP=$OUT/SPLoader.app

rm -rf $OUT && mkdir -p $OUT
python3 gen_refs.py $RECON/imports.json $CLIENT $OUT/refs.c
# Same link order as the client; macOS 11.0 gives the same dyld-info (non-chained) fixup format.
FRAMEWORKS=$(otool -L $CLIENT | sed -n 's|^.*/\([A-Za-z]*\)\.framework/.*|-framework \1|p')
# The client's older SDK exported exp2/log2/modff from CoreServices; today's .tbd doesn't, so link
# against a copy that does (the runtime library still has them).
SDK=$(xcrun --sdk macosx --show-sdk-path)
mkdir -p $OUT/fw/CoreServices.framework
awk '/^--- !tapi-tbd/ && ++n == 2 { print "exports:\n  - targets: [ arm64e-macos ]\n    symbols: [ _exp2, _log2, _modff ]" } 1' \
  $SDK/System/Library/Frameworks/CoreServices.framework/CoreServices.tbd > $OUT/fw/CoreServices.framework/CoreServices.tbd
clang -arch arm64 -mmacosx-version-min=11.0 -fobjc-arc -O1 -Wall -Wno-incompatible-library-redeclaration \
  -headerpad_max_install_names -Wl,-F,$OUT/fw main.m $OUT/refs.c $FRAMEWORKS -lc++abi -lbsm -lc++ \
  -Wl,-rpath,@executable_path -o $OUT/sploader-macos

# Every client import must be imported from the same library (more is fine: the toy's own uses).
dyld_info -imports $CLIENT | sed -n 's/^ *\([^ ]*\) *(from \(.*\))$/\2 \1/p' | sort > $OUT/client-imports.txt
dyld_info -imports $OUT/sploader-macos | sed -n 's/^ *\([^ ]*\) *(from \(.*\))$/\2 \1/p' | sort > $OUT/toy-imports.txt
MISSING=$(comm -23 $OUT/client-imports.txt $OUT/toy-imports.txt | grep -v ' dyld_stub_binder$' || true)
if [ -n "$MISSING" ]; then echo "toy lacks client imports:"; echo "$MISSING"; exit 1; fi
echo "toy covers all $(wc -l < $OUT/client-imports.txt | tr -d ' ') client imports;" \
  "extra: $(comm -13 $OUT/client-imports.txt $OUT/toy-imports.txt | tr '\n' ' ')"

if [ "$1" = mac ]; then
  # Link libSystem through the macOS build of the shim, as shims/system/test-mac.sh did for the client.
  ../../shims/system/build.sh macos $OUT @executable_path/
  install_name_tool -change /usr/lib/libSystem.B.dylib @executable_path/libspSystem.dylib $OUT/sploader-macos
  codesign -f -s - $OUT/sploader-macos $OUT/*.dylib
  SP_LOADER_LOG=$OUT/sploader-mac.log $OUT/sploader-macos
  exit
fi

mkdir -p $APP/Frameworks
cp $OUT/sploader-macos $APP/SPLoader
CHANGES=$(sed 's/^\(.*\) -> \(.*\)$/-change \1 \2/' ../../shims/generated/rewrite-map.txt)
install_name_tool $CHANGES -add_rpath @executable_path/Frameworks $APP/SPLoader
vtool -set-build-version $SP_VTOOL $SP_MINOS $SP_MINOS -replace -output $APP/SPLoader $APP/SPLoader
../../shims/build.sh $SP_PLATFORM
cp ../../build/$SP_PLATFORM/*.dylib $APP/Frameworks/
sp_plist Info.plist $APP/Info.plist $BUNDLE_ID
cp "$SP_PROFILE" $APP/embedded.mobileprovision
cat > $OUT/entitlements.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>application-identifier</key><string>$SP_TEAM.$BUNDLE_ID</string>
  <key>com.apple.developer.team-identifier</key><string>$SP_TEAM</string>
  <key>get-task-allow</key><true/>
</dict></plist>
EOF
codesign -f -s "$SP_SIGN_ID" $APP/Frameworks/*.dylib
codesign -f -s "$SP_SIGN_ID" --entitlements $OUT/entitlements.plist $APP
otool -L $APP/SPLoader | tail -n +2 | grep -v -e '@rpath/' -e '^\s*/System/Library/Frameworks/[A-Za-z]*\.framework/[A-Za-z]* ' \
  -e '^\s*/usr/lib/' && { echo "unrewritten load commands above"; exit 1; }
sp_need_device
xcrun devicectl device install app --device "$SP_DEVICE" $APP
