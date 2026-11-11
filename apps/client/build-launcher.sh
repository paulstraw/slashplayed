#!/bin/sh
# Builds the device app's main executable, the launcher (launcher.m, spjit.m, its side of the JIT helper,
# sppair.m, the headset's pairing screen, spsettings.swift, the Settings sheet (in SwiftUI), spvpn.m, the wait
# for LocalDevVPN, splogin.m and spsignin.swift, the Battle.net sign-in, spstart.m and spstartscreen.swift, the
# start screen, sppatch.m, the patch check, with spcdn.m, Blizzard's CDN, and spbind.m, the bind check on the
# device, spguestlaunch.m with spguest.c, the loader that runs the game's unchanged client, and spapple.m,
# the Apple token, the app's profile renewal, and the Apple sign-in (spapplescreen.swift its screen), with the
# spapple library), for
# SP_PLATFORM (scripts/platform.sh):
#   apps/client/build-launcher.sh <output>
# spapple, Apple's developer services for the app's profile renewal (spapple.h), comes from
# scripts/build-spapple.sh (work/spapple/<platform>/). Unsigned. apps/client/build.sh puts it in the app it
# builds; the companion's bundle-resources.sh in the companion, which assembles the app itself.
set -e
[ -n "$1" ] || { echo "usage: $0 <output>" >&2; exit 1; }
OUT=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
cd "$(dirname "$0")"
. ../../scripts/platform.sh
SPAPPLE=../../work/spapple/$SP_PLATFORM
for f in "$SPAPPLE/libspapple.a" "$SPAPPLE/native-libs.txt"; do
  [ -f "$f" ] || { echo "build-launcher: no ${f#../../} (run scripts/build-spapple.sh $SP_PLATFORM)" >&2; exit 1; }
done
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# The Swift screens (spstartscreen.swift, the start screen; spsettings.swift, the Settings sheet; spsignin.swift, the Battle.net sign-in;
# spapplescreen.swift, the Apple sign-in; sppairscreen.swift and spvpnscreen.swift, the pairing and LocalDevVPN waits;
# sppatchscreen.swift, the newer-build screen; spstyle.swift, their shared
# look), with spswift.h as their bridging header: the
# Objective-C they call, and their C entry points the Objective-C calls. -parse-as-library: main is launcher.m's. -wmo: one module, one object.
xcrun --sdk "$SP_SDK" swiftc -target "$SP_TARGET" -O -wmo -parse-as-library -module-name SPLauncher \
  -import-objc-header spswift.h -c spstyle.swift spstartscreen.swift spsettings.swift spsignin.swift spapplescreen.swift sppairscreen.swift spvpnscreen.swift sppatchscreen.swift -o "$TMP/spswift.o"
for m in launcher spjit sppair spvpn splogin spstart sppatch spcdn spbind spguestlaunch spapple; do
  xcrun --sdk "$SP_SDK" clang -target "$SP_TARGET" -O1 -Wall -fobjc-arc -c $m.m -o "$TMP/$m.o"
done
# spguest, the loader (spguestlaunch.m runs it); guesttest/ is its test.
xcrun --sdk "$SP_SDK" clang -target "$SP_TARGET" -O1 -Wall -c spguest.c -o "$TMP/spguest.o"
xcrun --sdk "$SP_SDK" clang -target "$SP_TARGET" -c spguest_tlv.S -o "$TMP/spguest_tlv.o"
# swiftc links, so the Swift runtime (the OS's, in /usr/lib/swift) and its rpath come with it. Security is
# splogin.m's and spapple.m's keychain (and the older identity's cleanup, launcher.m); zlib is spcdn.m's.
# -S: no debug map, whose entries name each object's path on this Mac (spapple's archive holds C and
# assembly objects with debug info, which bundle-resources.sh's no-absolute-paths check refuses).
# -dead_strip: most of spapple's crates are code the one request never reaches.
# shellcheck disable=SC2046 # native-libs.txt is a list of linker flags
xcrun --sdk "$SP_SDK" swiftc -target "$SP_TARGET" \
  -framework Foundation -framework UIKit -framework SwiftUI -framework CoreGraphics -framework QuartzCore \
  -framework CoreText -framework Network -framework Security -lz \
  "$TMP"/*.o "$SPAPPLE/libspapple.a" $(cat "$SPAPPLE/native-libs.txt") -o "$OUT" \
  -Xlinker -rpath -Xlinker @executable_path/Frameworks -Xlinker -S -Xlinker -dead_strip
