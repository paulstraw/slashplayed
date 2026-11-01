#!/bin/sh
# Builds the Mac companion app into "build/companion/Slashplayed Companion.app" (needs xcodegen), with its
# run-time resources bundled in (bundle-resources.sh: shims, launcher, and JIT helper for both platforms,
# templates, the addon, the signing stub project). To work on it in Xcode, run this once, then open
# apps/companion/SPCompanion.xcodeproj (an app run from Xcode has no bundled resources until this runs).
set -e
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
OUT=$ROOT/build/companion
APP="$OUT/Slashplayed Companion.app"
# The device builds (shims, launcher, JIT helper, and icon, per platform) read nothing from the app, so
# they run in the background while Xcode compiles it: on CI's 3-core runner the Release compile is mostly
# one single-threaded optimizer per architecture, leaving a core for them, and they used to wait for it
# (about 70s after a 2-minute compile). Their output goes to a log, printed whole once xcodebuild is done,
# so it isn't interleaved with Xcode's. If xcodebuild fails first, the build phase's script is killed on
# the way out (a compiler it started may finish on its own, but the phase never marks its output done).
STAGE=$OUT/resources
mkdir -p "$OUT"
BUNDLE_LOG=$(mktemp -t sp-bundle-build)
./bundle-resources.sh --build "$STAGE" >"$BUNDLE_LOG" 2>&1 &
BUNDLE_PID=$!
trap '[ -z "$BUNDLE_PID" ] || kill "$BUNDLE_PID" 2>/dev/null || true; rm -f "$BUNDLE_LOG"' EXIT
./idevice-config.sh
xcodegen generate --quiet
xcodebuild -project SPCompanion.xcodeproj -scheme SPCompanion -configuration Release \
  -derivedDataPath "$OUT/DerivedData" -quiet build
BUNDLE_STATUS=0
wait "$BUNDLE_PID" || BUNDLE_STATUS=$?
BUNDLE_PID=  # reaped: nothing for the trap to kill (its PID could be reused)
cat "$BUNDLE_LOG" >&2
[ "$BUNDLE_STATUS" -eq 0 ] || { echo "bundle-resources.sh --build failed (status $BUNDLE_STATUS; its output is above)" >&2; exit 1; }
rm -rf "$APP"
cp -R "$OUT/DerivedData/Build/Products/Release/Slashplayed Companion.app" "$OUT/"
./bundle-resources.sh --install "$STAGE" "$APP"
# Re-sealed after the resources go in, deliberately without the hardened runtime: its library validation
# only loads frameworks with the app's own Team ID, and the embedded Sparkle.framework keeps the ad hoc
# seal Xcode gave it, so it would fail to load ("different Team IDs"). Release builds sign everything
# with Developer ID and the runtime on.
# The seal is your Apple Development identity (SP_SIGN_ID, from the environment or config/local.env)
# when there is one, else ad hoc (CI, or no local.env). It matters for privacy prompts: macOS keys an
# answer like "access files on a removable volume" (a game install on an external drive) to the app's
# designated requirement. Ad hoc, that's the binary's hash, so every rebuild asks again; signed, it's the
# bundle ID and certificate, so one answer lasts across rebuilds.
. "$ROOT/scripts/config.sh"
if [ -n "${SP_SIGN_ID:-}" ]; then
  security find-identity -v -p codesigning | grep -q "$SP_SIGN_ID" ||
    { echo "SP_SIGN_ID isn't a valid codesigning identity in your keychain" \
        "(security find-identity -v -p codesigning); unset it to build ad hoc" >&2; exit 1; }
  codesign -f -s "$SP_SIGN_ID" "$APP"
else
  codesign -f -s - "$APP"
fi
# Earlier builds told the companion where the repo was; it reads nothing from it now.
defaults delete com.strawdynamics.slashplayed.companion SPDevRepoRoot 2>/dev/null || true
echo "built build/companion/Slashplayed Companion.app"
