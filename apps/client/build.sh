#!/bin/sh
# The device app, as the companion assembles it (apps/companion/Sources/ClientAssembly.swift) but with no
# game in it: the launcher (launcher.m, the main executable, slashplayed), the on-device JIT helper
# (PlugIns/SPJitHelper.appex, build-helper.sh), the shims, and what the launcher reads (flavors.plist, the
# shims' exports.json and rewrite-map.txt, the addons, the licenses), signed and installed. The app carries no
# game client and ships no Blizzard bytes: each game's client is its unchanged arm64 slice in the app's data
# container, Library/spgames/wow-<flavor>, which the launcher loads with spguest. seed-client.sh copies the
# Mac's installed one there; the companion's Play copies the CDN's; or the device installs the game itself
# (the start screen's "Install <game>", sppatch.m). Installed over an older app, the container is kept, and
# the launcher's first start retires any image an older Slashplayed made there (launcher.m). The bundle goes
# in work/clienttest$SP_SUFFIX/. Other env as research/jittest/build.sh.
# SP_NO_INSTALL=1 builds without installing (the Mac companion installs once the headset is awake).
# SP_OUT puts the build elsewhere. <out>/build-complete marks a finished build; needs-install, one not yet
# installed. (The companion keeps its own record of what each device holds instead: ClientBuild.installNeed.)
set -e
cd "$(dirname "$0")"
# The app's own Xcode-managed profile (explicit App ID with Increased Memory Limit and Extended Virtual
# Addressing; the wildcard team profile can't carry those). Xcode made it from a stub project built with
# -allowProvisioningUpdates: apps/client/signing/regen.sh <UDID> (re)makes it, e.g. for a new device.
# SP_TEAM, SP_SIGN_ID, SP_BUNDLE_ID and SP_DEVICE come from config/local.env (scripts/config.sh).
. ../../scripts/platform.sh
sp_need SP_TEAM SP_SIGN_ID SP_BUNDLE_ID
[ "$SP_NO_INSTALL" = 1 ] || sp_need_device
OUT=${SP_OUT:-../../work/clienttest$SP_SUFFIX}
APP="$OUT"/Slashplayed.app
BUNDLE_ID=$SP_BUNDLE_ID
HELPER_ID=$BUNDLE_ID.helper
: "${SP_PROFILE:=$(sp_profile $BUNDLE_ID)}"
# The JIT helper extension's own profile (an extension's App ID is its own bundle ID): regen.sh makes it too.
: "${SP_HELPER_PROFILE:=$(sp_profile $HELPER_ID)}"

rm -f "$OUT"/build-complete
rm -rf "$APP" && mkdir -p "$APP"/Frameworks
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
# The rewrite map: spguest opens each library the client names as the shim this sends it to (spguestlaunch.m).
cp ../../shims/generated/rewrite-map.txt "$APP"/
# The licenses of what the app's code links: the JIT helper's idevice (MIT) with its Rust crates, and the
# Rust standard library (scripts/build-idevice.sh writes those two from the pinned sources). And the start
# screen's face, Goodmountain (spstart.m), shipped byte for byte with its license, as that license asks
# (scripts/fetch-font.sh downloads both; neither is ever committed).
for f in ../../work/fonts/Goodmountain-Regular.otf ../../work/fonts/LICENSE.md; do
  [ -f "$f" ] || { echo "build.sh: no ${f#../../} (run scripts/fetch-font.sh)" >&2; exit 1; }
done
mkdir -p "$APP"/licenses
cp ../../work/idevice/$SP_PLATFORM/licenses/idevice.txt ../../work/idevice/$SP_PLATFORM/licenses/rust-std.html "$APP"/licenses/
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
codesign -f -s "$SP_SIGN_ID" "$APP"/Frameworks/*.dylib
codesign -f -s "$SP_SIGN_ID" --entitlements "$OUT"/helper-entitlements.plist "$HELPER"
codesign -f -s "$SP_SIGN_ID" --entitlements "$OUT"/entitlements.plist "$APP"
touch "$OUT"/build-complete
touch "$OUT"/needs-install
[ "$SP_NO_INSTALL" = 1 ] && exit 0
xcrun devicectl device install app --device "$SP_DEVICE" "$APP"
rm -f "$OUT"/needs-install
