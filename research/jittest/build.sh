#!/bin/sh
# Builds, signs and installs SPJitTest.app on the device, with its helper extension
# (PlugIns/SPJitHelper.appex, com.strawdynamics.spjittest.helper) for the H experiments.
# Env: SP_PLATFORM (scripts/platform.sh), SP_DEVICE (UDID), SP_TEAM, SP_SIGN_ID (codesign identity hash),
# SP_PROFILE and SP_HELPER_PROFILE (.mobileprovision paths; apps/client/signing/regen.sh makes both).
# SP_DEVICE, SP_TEAM and SP_SIGN_ID come from config/local.env unless set (scripts/config.sh).
# SP_NO_INSTALL=1 stops after signing.
set -e
cd "$(dirname "$0")"
BUNDLE_ID=com.strawdynamics.spjittest
HELPER_ID=$BUNDLE_ID.helper
. ../../scripts/platform.sh
sp_need SP_TEAM SP_SIGN_ID
: "${SP_PROFILE:=$(sp_profile $BUNDLE_ID)}"
: "${SP_HELPER_PROFILE:=$(sp_profile $HELPER_ID)}"
OUT=out
APP=$OUT/SPJitTest.app
HELPER=$APP/PlugIns/SPJitHelper.appex
# The helper is the client's (apps/client/helper); jittest builds the same source.
HELPER_SRC=../../apps/client/helper
SWIFTC="xcrun --sdk $SP_SDK swiftc -target $SP_TARGET -O -parse-as-library"

rm -rf $OUT && mkdir -p $APP $HELPER
# main.c plus the helper's host side (helper_host.swift); swiftc links, so the Swift runtime comes along.
xcrun --sdk $SP_SDK clang -target $SP_TARGET -O1 -Wall -c main.c -o $OUT/main.o
# SP_IDEVICE_DIR: another idevice build than scripts/build-idevice.sh's.
IDEVICE=${SP_IDEVICE_DIR:-../../work/idevice}
if [ -f $IDEVICE/$SP_PLATFORM/libidevice_ffi.a ]; then
  # P1 pairs from the app itself, so the host links idevice too.
  # shellcheck disable=SC2046 # native-libs.txt is a list of linker flags
  $SWIFTC -D SP_IDEVICE -I $IDEVICE/include -I $HELPER_SRC/iokit helper_host.swift pair_host.swift ui_host.swift $HELPER_SRC/Device.swift \
    $OUT/main.o $IDEVICE/$SP_PLATFORM/libidevice_ffi.a $(cat $IDEVICE/$SP_PLATFORM/native-libs.txt) -o $APP/SPJitTest
else
  $SWIFTC helper_host.swift pair_host.swift ui_host.swift $OUT/main.o -o $APP/SPJitTest
fi
# Link libSystem through the real shim (shims/system), as the client will be (E7). It only
# changes what dlsym hands out, which E1-E6 don't use.
../../shims/system/build.sh $SP_PLATFORM $APP/Frameworks
install_name_tool -change /usr/lib/libSystem.B.dylib @rpath/libspSystem.dylib \
  -add_rpath @executable_path/Frameworks $APP/SPJitTest
sp_plist Info.plist $APP/Info.plist $BUNDLE_ID
cp "$SP_PROFILE" $APP/embedded.mobileprovision

# The helper, a classic app extension (research/jittest/README.md): the .appex in PlugIns/, package type
# XPC!, an NSExtension dictionary naming Apple's AR viewer point and the principal class, linked as an app
# extension with NSExtensionMain (Foundation's) as the entry point. With idevice built (scripts/build-idevice.sh,
# work/idevice/), the helper also gets its real work (H2-H4, apps/client/helper/Device.swift); without it, it answers
# only H1's ping and says how to get the rest.
if [ -f $IDEVICE/$SP_PLATFORM/libidevice_ffi.a ]; then
  echo "helper: with idevice ($(head -1 $IDEVICE/BUILD.txt))" >&2
  # shellcheck disable=SC2046 # native-libs.txt is a list of linker flags
  $SWIFTC -application-extension -Xlinker -e -Xlinker _NSExtensionMain -D SP_IDEVICE \
    -I $IDEVICE/include -I $HELPER_SRC/iokit $HELPER_SRC/Helper.swift $HELPER_SRC/Device.swift $HELPER_SRC/Pair.swift \
    $IDEVICE/$SP_PLATFORM/libidevice_ffi.a $(cat $IDEVICE/$SP_PLATFORM/native-libs.txt) -o $HELPER/SPJitHelper
else
  echo "helper: without idevice (no $IDEVICE/$SP_PLATFORM/libidevice_ffi.a; scripts/build-idevice.sh makes it): h1 only" >&2
  $SWIFTC -application-extension -Xlinker -e -Xlinker _NSExtensionMain $HELPER_SRC/Helper.swift -o $HELPER/SPJitHelper
fi
sp_plist $HELPER_SRC/Info.plist $HELPER/Info.plist $HELPER_ID
cp "$SP_HELPER_PROFILE" $HELPER/embedded.mobileprovision

# Each bundle signs with its own application-identifier, and both get get-task-allow (the helper will be
# debugged by nothing, but the profile carries it and Xcode signs development extensions with it).
entitlements() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>application-identifier</key><string>$SP_TEAM.$1</string>
  <key>com.apple.developer.team-identifier</key><string>$SP_TEAM</string>
  <key>get-task-allow</key><true/>
</dict></plist>
EOF
}
entitlements $BUNDLE_ID > $OUT/entitlements.plist
entitlements $HELPER_ID > $OUT/helper-entitlements.plist
# Inside out: the helper is sealed into the app's signature, so it's signed first.
codesign -f -s "$SP_SIGN_ID" $APP/Frameworks/*.dylib
codesign -f -s "$SP_SIGN_ID" --entitlements $OUT/helper-entitlements.plist $HELPER
codesign -f -s "$SP_SIGN_ID" --entitlements $OUT/entitlements.plist $APP
[ -z "$SP_NO_INSTALL" ] || exit 0
sp_need_device
xcrun devicectl device install app --device "$SP_DEVICE" $APP
