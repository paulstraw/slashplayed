#!/bin/sh
# Phase 3: the real client as a visionOS app, the same way research/loadertest builds the toy. One app
# holds every flavor (SP_BUILD_FLAVORS, default all installed: SP_FLAVORS in scripts/flavor.sh). Each
# flavor's installed client is thinned, its load commands rewritten (shims/generated/rewrite-map.txt),
# its platform set to visionOS and its header retyped MH_BUNDLE (retype.py), as wow-<flavor>, with the build
# it came from beside it (spbuild-<flavor>). The main
# executable, slashplayed, is the launcher (launcher.m), which picks a flavor and dlopens it: visionOS won't
# exec another executable. Then the on-device JIT helper (PlugIns/SPJitHelper.appex, build-helper.sh) and
# the shims are bundled, everything signed and installed. The bundle goes
# in work/clienttest/ (Blizzard's binaries: never commit). Only load commands and headers change; the
# game's code and data are untouched. Other env as research/jittest/build.sh.
# The companion does the same in Swift (apps/companion/Sources/ClientAssembly.swift, byte-identical
# client images), and the launcher on the device in spassemble.m (the same unsigned image from the same
# slice); keep the three in step.
# SP_NO_INSTALL=1 builds without installing (the Mac companion installs once the headset is awake).
# SP_OUT puts the build elsewhere (the companion: ~/Library/Application Support/Slashplayed/client-<platform>).
# <out>/build-complete marks a finished build; needs-install, one not yet installed. (The companion keeps
# its own record of what each device holds instead: ClientBuild.installNeed.)
# SP_NO_IMAGES=1 builds the app with no client image (no wow-<flavor>, no spbuild-<flavor>), as a host that
# ships no Blizzard bytes will: the start screen then offers every game in flavors.plist, and the device
# installs the one tapped itself (launcher.m, sppatch.m's sp_patch_install), which needs the signing identity
# an update needs (push-identity.sh). It needs no game install on the Mac (SP_BUILD_FLAVORS is ignored), and
# it changes nothing of the assembly: there's no image to assemble. run.sh then runs any flavor (one with no
# image yet is installed first, its screen with no Back). Installed over an app with images, it keeps the
# container: the games the device made in Library/spgames are installed, and the rest offer Install.
set -e
cd "$(dirname "$0")"
# The app's own Xcode-managed profile (explicit App ID with Increased Memory Limit and Extended Virtual
# Addressing; the wildcard team profile can't carry those). Xcode made it from a stub project built with
# -allowProvisioningUpdates: apps/client/signing/regen.sh <UDID> (re)makes it, e.g. for a new device.
# SP_TEAM, SP_SIGN_ID, SP_BUNDLE_ID and SP_DEVICE come from config/local.env (scripts/config.sh).
. ../../scripts/flavor.sh
. ../../scripts/platform.sh
sp_need SP_TEAM SP_SIGN_ID SP_BUNDLE_ID
[ "$SP_NO_INSTALL" = 1 ] || sp_need_device
FLAVORS=${SP_BUILD_FLAVORS:-$SP_FLAVORS}
if [ "$SP_NO_IMAGES" = 1 ]; then
  FLAVORS=
elif [ -n "$SP_NO_IMAGES" ] && [ "$SP_NO_IMAGES" != 0 ]; then
  echo "build.sh: SP_NO_IMAGES is 1, 0, or unset, not '$SP_NO_IMAGES'" >&2
  exit 1
elif [ -z "$FLAVORS" ]; then
  echo "build.sh: no game installed in $SP_INSTALL to bundle (SP_NO_IMAGES=1 builds without client images)" >&2
  exit 1
fi
OUT=${SP_OUT:-../../work/clienttest$SP_SUFFIX}
APP="$OUT"/Slashplayed.app
BUNDLE_ID=$SP_BUNDLE_ID
HELPER_ID=$BUNDLE_ID.helper
: "${SP_PROFILE:=$(sp_profile $BUNDLE_ID)}"
# The JIT helper extension's own profile (an extension's App ID is its own bundle ID): regen.sh makes it too.
: "${SP_HELPER_PROFILE:=$(sp_profile $HELPER_ID)}"

rm -f "$OUT"/build-complete
rm -rf "$APP" && mkdir -p "$APP"/Frameworks
CHANGES=$(sed 's/^\(.*\) -> \(.*\)$/-change \1 \2/' ../../shims/generated/rewrite-map.txt)
for f in $FLAVORS; do
  echo "bundling $f" >&2
  BIN="$APP"/wow-$f
  lipo -thin arm64 "$(sp_flavor_client $f)" -output "$BIN"
  install_name_tool $CHANGES -add_rpath @executable_path/Frameworks "$BIN" 2>/dev/null
  vtool -set-build-version $SP_VTOOL $SP_MINOS $SP_MINOS -replace -output "$BIN" "$BIN"
  ./retype.py "$BIN"
  # The build the image was made from, beside it as spbuild-<flavor> (the launcher reads it): .build.info's
  # columns that name a build, for the flavor's product, as a one-row table of the same shape. The last row
  # for the product, as the companion's GameStore.buildInfo takes it. ClientAssembly.Stamp writes the same bytes.
  P=$(sp_flavor_product $f)
  awk -F'|' -v p="$P" '
    NR == 1 { for (i = 1; i <= NF; i++) { split($i, n, "!"); c[n[1]] = i }; next }
    $c["Product"] == p { row = p "|" $c["Branch"] "|" $c["Build Key"] "|" $c["Version"]; ok = $c["Build Key"] != "" && $c["Version"] != "" }
    END {
      if (!ok) { print "the game install has no " p " build in .build.info" > "/dev/stderr"; exit 1 }
      print "Product!STRING:0|Branch!STRING:0|Build Key!HEX:16|Version!STRING:0"
      print row
    }' "$SP_INSTALL/.build.info" > "$APP"/spbuild-$f
done
./build-launcher.sh "$APP"/slashplayed
# The on-device JIT helper (helper/, spjit.m): an app extension, so it goes in PlugIns/ with its own
# Info.plist, profile and entitlements.
HELPER="$APP"/PlugIns/SPJitHelper.appex
mkdir -p "$HELPER"
./build-helper.sh "$HELPER"/SPJitHelper
sp_plist helper/Info.plist "$HELPER"/Info.plist $HELPER_ID
cp "$SP_HELPER_PROFILE" "$HELPER"/embedded.mobileprovision
./build-icons.sh "$APP"
../../shims/build.sh $SP_PLATFORM
cp ../../build/$SP_PLATFORM/*.dylib "$APP"/Frameworks/
# The shims' exports (shims/exports_manifest.py): the launcher's bind check of a newer build (sppatch.m,
# spbind.m) reads it, as the companion's BindCheck reads its own copy.
cp ../../build/$SP_PLATFORM/exports.json "$APP"/
# The rewrite map, for the client image's assembly on the device (spassemble.m), as the steps above use it.
cp ../../shims/generated/rewrite-map.txt "$APP"/
# The licenses of what the app's code links: the launcher's signer (spsign.m), zsign (MIT) and OpenSSL
# (Apache-2.0); the JIT helper's idevice (MIT) with its Rust crates, and the Rust standard library
# (scripts/build-idevice.sh writes those two from the pinned sources); the launcher's spapple with isideload
# (MIT) and its Rust crates (scripts/build-spapple.sh). And the start screen's face,
# Goodmountain (spstart.m), shipped byte for byte with its license, as that license asks
# (scripts/fetch-font.sh downloads both; neither is ever committed).
for f in ../../work/fonts/Goodmountain-Regular.otf ../../work/fonts/LICENSE.md; do
  [ -f "$f" ] || { echo "build.sh: no ${f#../../} (run scripts/fetch-font.sh)" >&2; exit 1; }
done
mkdir -p "$APP"/licenses
cp ../../work/zsign/licenses/zsign.txt ../../work/zsign/licenses/openssl.txt "$APP"/licenses/
cp ../../work/idevice/$SP_PLATFORM/licenses/idevice.txt ../../work/idevice/$SP_PLATFORM/licenses/rust-std.html "$APP"/licenses/
cp ../../work/spapple/$SP_PLATFORM/licenses/spapple.txt "$APP"/licenses/
cp ../../work/fonts/LICENSE.md "$APP"/licenses/goodmountain.txt
cp ../../work/fonts/Goodmountain-Regular.otf "$APP"/
sp_plist Info.plist "$APP"/Info.plist $BUNDLE_ID
# The flavors' names (the start screen, spstart.m) and Battle.net's arguments (launcher.m).
cp flavors.plist "$APP"/
# The addons, which the launcher puts in each game's folder before it loads (spcdn.m's sp_addons_place:
# SPMovie everywhere, SPHover on the headset). Both on both platforms, as the companion's ClientAssembly
# bundles them: the launcher decides.
for a in SPMovie SPHover; do
  mkdir -p "$APP"/addons/$a
  cp ../../addon/$a/$a.toc ../../addon/$a/$a.lua "$APP"/addons/$a/
done
# The client looks up its icon, wow.icns, for its data setup dialog's IconURL, and throws on a nil path.
# The dialog is never drawn (shims/appkit/spnotice.m), so the file only has to exist.
: > "$APP"/wow.icns
# The Mac's root CAs, for the client's own TLS trust store (shims/security/spssl.m).
security find-certificate -a -p /System/Library/Keychains/SystemRootCertificates.keychain | python3 -c '
import base64, plistlib, re, sys
ders = [base64.b64decode(b) for b in re.findall(r"-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----", sys.stdin.read(), re.S)]
plistlib.dump(ders, open(sys.argv[1], "wb"), fmt=plistlib.FMT_BINARY)' "$APP"/sproots.plist
cp "$SP_PROFILE" "$APP"/embedded.mobileprovision
sed -e "s/@TEAM@/$SP_TEAM/g" -e "s/@BUNDLE_ID@/$BUNDLE_ID/g" entitlements.plist > "$OUT/entitlements.plist"
sed -e "s/@TEAM@/$SP_TEAM/g" -e "s/@BUNDLE_ID@/$HELPER_ID/g" helper/entitlements.plist > "$OUT/helper-entitlements.plist"
# Inside out: the helper is sealed into the app's signature, so it's signed before the app.
# The images too, when there are any (SP_NO_IMAGES=1 has none, and the glob would stay as it is).
if [ -n "$FLAVORS" ]; then
  codesign -f -s "$SP_SIGN_ID" "$APP"/Frameworks/*.dylib "$APP"/wow-*
else
  codesign -f -s "$SP_SIGN_ID" "$APP"/Frameworks/*.dylib
fi
codesign -f -s "$SP_SIGN_ID" --entitlements "$OUT"/helper-entitlements.plist "$HELPER"
codesign -f -s "$SP_SIGN_ID" --entitlements "$OUT"/entitlements.plist "$APP"
for b in "$APP"/wow-*; do [ -f "$b" ] || continue; otool -L "$b" | tail -n +2 | grep -v -e '@rpath/' -e '^\s*/System/Library/Frameworks/[A-Za-z]*\.framework/[A-Za-z]* ' \
  -e '^\s*/usr/lib/' && { echo "unrewritten load commands above in $b"; exit 1; }; done
echo $FLAVORS > "$OUT"/build-complete
touch "$OUT"/needs-install
[ "$SP_NO_INSTALL" = 1 ] && exit 0
xcrun devicectl device install app --device "$SP_DEVICE" "$APP"
rm -f "$OUT"/needs-install
