#!/bin/sh
# Builds the device app's main executable, the launcher (launcher.m, spjit.m, its side of the JIT helper,
# sppair.m, the headset's pairing screen, spsettings.swift, the Settings sheet (in SwiftUI), spvpn.m, the wait
# for LocalDevVPN, splogin.m and spsignin.swift, the Battle.net sign-in, spstart.m and spstartscreen.swift, the
# start screen, sppatch.m, the patch check, with spcdn.m, Blizzard's CDN, and spbind.m, the bind check on the
# device, and spguestlaunch.m with spguest.c, the loader that runs the game's unchanged client), for
# SP_PLATFORM (scripts/platform.sh):
#   apps/client/build-launcher.sh <output>
# Unsigned. apps/client/build.sh puts it in the app it builds; the companion's bundle-resources.sh in the
# companion, which assembles the app itself.
set -e
[ -n "$1" ] || { echo "usage: $0 <output>" >&2; exit 1; }
OUT=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
cd "$(dirname "$0")"
. ../../scripts/platform.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# The Swift screens (spstartscreen.swift, the start screen; spsettings.swift, the Settings sheet; spsignin.swift, the Battle.net sign-in;
# sppairscreen.swift and spvpnscreen.swift, the pairing and LocalDevVPN waits; sppatchscreen.swift, the newer-build screen; spstyle.swift, their shared
# look), with spswift.h as their bridging header: the
# Objective-C they call, and their C entry points the Objective-C calls. -parse-as-library: main is launcher.m's. -wmo: one module, one object.
xcrun --sdk "$SP_SDK" swiftc -target "$SP_TARGET" -O -wmo -parse-as-library -module-name SPLauncher \
  -import-objc-header spswift.h -c spstyle.swift spstartscreen.swift spsettings.swift spsignin.swift sppairscreen.swift spvpnscreen.swift sppatchscreen.swift -o "$TMP/spswift.o"
for m in launcher spjit sppair spvpn splogin spstart sppatch spcdn spbind spguestlaunch; do
  xcrun --sdk "$SP_SDK" clang -target "$SP_TARGET" -O1 -Wall -fobjc-arc -c $m.m -o "$TMP/$m.o"
done
# spguest, the loader (spguestlaunch.m runs it); guesttest/ is its test.
xcrun --sdk "$SP_SDK" clang -target "$SP_TARGET" -O1 -Wall -c spguest.c -o "$TMP/spguest.o"
xcrun --sdk "$SP_SDK" clang -target "$SP_TARGET" -c spguest_tlv.S -o "$TMP/spguest_tlv.o"
# swiftc links, so the Swift runtime (the OS's, in /usr/lib/swift) and its rpath come with it. Security is
# splogin.m's keychain (and the older identity's cleanup, launcher.m); zlib is spcdn.m's.
xcrun --sdk "$SP_SDK" swiftc -target "$SP_TARGET" \
  -framework Foundation -framework UIKit -framework SwiftUI -framework CoreGraphics -framework QuartzCore \
  -framework CoreText -framework Network -framework Security -lz \
  "$TMP"/*.o -o "$OUT" \
  -Xlinker -rpath -Xlinker @executable_path/Frameworks
