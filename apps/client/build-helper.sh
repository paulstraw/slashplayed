#!/bin/sh
# Builds the on-device JIT helper's executable (helper/: a classic app extension, PlugIns/SPJitHelper.appex
# in the device app) for SP_PLATFORM (scripts/platform.sh):
#   apps/client/build-helper.sh <output>
# Unsigned, like build-launcher.sh: apps/client/build.sh puts it in the app it builds, the companion's
# bundle-resources.sh in the companion, which assembles the app itself. The appex's Info.plist is the
# template helper/Info.plist, filled when the app is assembled (its bundle ID is the app's plus .helper).
# Links idevice (scripts/build-idevice.sh <platform> builds it into work/idevice/), which the helper needs
# for all its work: the RemotePairing tunnel, the disk image, and the debugger.
set -eu
[ $# -eq 1 ] && [ -n "$1" ] || { echo "usage: $0 <output>" >&2; exit 1; }
OUT=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
cd "$(dirname "$0")"
. ../../scripts/platform.sh
IDEVICE=../../work/idevice
[ -f "$IDEVICE/$SP_PLATFORM/libidevice_ffi.a" ] && [ -f "$IDEVICE/$SP_PLATFORM/native-libs.txt" ] ||
  { echo "build-helper: no idevice for $SP_PLATFORM in work/idevice/: run scripts/build-idevice.sh $SP_PLATFORM" >&2; exit 1; }
# NSExtensionMain (Foundation's) is the entry point, as for any app extension; -application-extension
# keeps the code to extension-safe API.
# shellcheck disable=SC2046 # native-libs.txt is a list of linker flags
xcrun --sdk $SP_SDK swiftc -target $SP_TARGET -O -parse-as-library -application-extension \
  -Xlinker -e -Xlinker _NSExtensionMain -D SP_IDEVICE -I "$IDEVICE/include" -I helper/iokit \
  helper/Helper.swift helper/Device.swift helper/Pair.swift "$IDEVICE/$SP_PLATFORM/libidevice_ffi.a" \
  $(cat "$IDEVICE/$SP_PLATFORM/native-libs.txt") -o "$OUT"
