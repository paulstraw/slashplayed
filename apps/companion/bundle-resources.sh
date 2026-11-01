#!/bin/sh
# Copies everything the companion needs at run time into a built "Slashplayed Companion.app", so the app
# never reads the repo (build.sh runs it; so will the release script):
#   apps/companion/bundle-resources.sh <app>
# Contents/Resources/ gets, per device platform (xros, ios), <platform>/: the unsigned shim dylibs, their
# exports.json (the bind check's manifest) and rewrite-map.txt, the unsigned launcher (slashplayed) and
# licenses/ (the device app's: zsign's and OpenSSL's, which the launcher links, from scripts/build-zsign.sh,
# idevice's with its crates' and the Rust standard library's, which the helper links, from
# scripts/build-idevice.sh <platform>, and the start screen's face's, goodmountain.txt), the start screen's
# face, Goodmountain-Regular.otf, unmodified (scripts/fetch-font.sh: its license forbids changing it), the unsigned JIT helper's executable (SPJitHelper,
# apps/client/build-helper.sh: needs idevice for the platform), and icon/ (the device app's compiled icon,
# apps/client/build-icons.sh; actool needs Xcode, so not at run time).
# Acknowledgements/ (the About panel links it): every third-party license the companion ships. Sparkle's
# the build put there (project.yml); this adds idevice's as the companion links it, and the device app's.
# Once, for both platforms: client/Info.plist and client/entitlements.plist (the device app's templates),
# client/flavors.plist (copied into the app as it is), and client/helper/'s
# two (the helper's), the SPHover addon, the signing stub project (signing/SPProfiles.xcodeproj, generated
# here, since the user's Mac has no xcodegen). (The identity
# file mac-identity.c writes comes from its Swift port, MacIdentity.) Needs xcodegen; nothing here is Blizzard's (no client is read).
set -euo pipefail
[ $# -eq 1 ] && [ -d "$1/Contents" ] || { echo "usage: $0 <path to Slashplayed Companion.app>" >&2; exit 1; }
APP=$(cd "$1" && pwd)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
RES=$APP/Contents/Resources
mkdir -p "$RES"
FONT=$ROOT/work/fonts
for f in "$FONT/Goodmountain-Regular.otf" "$FONT/LICENSE.md"; do
  [ -f "$f" ] || { echo "no ${f#"$ROOT"/} (run scripts/fetch-font.sh)" >&2; exit 1; }
done

for p in xros ios; do
  rm -rf "${RES:?}/$p" && mkdir -p "$RES/$p/licenses"
  cp "$ROOT/work/zsign/licenses/zsign.txt" "$ROOT/work/zsign/licenses/openssl.txt" "$RES/$p/licenses/"
  cp "$ROOT/work/idevice/$p/licenses/idevice.txt" "$ROOT/work/idevice/$p/licenses/rust-std.html" "$RES/$p/licenses/"
  cp "$FONT/LICENSE.md" "$RES/$p/licenses/goodmountain.txt"
  cp "$FONT/Goodmountain-Regular.otf" "$RES/$p/"
done

# The builds, per platform: the shims, the launcher, the JIT helper, and the icon. None reads another's
# output (each writes its own file or folder: build/<platform>/, mktemp scratch), and each is a chain of
# single-threaded compiler runs, so one after another they left most cores idle: about 55s of a CI run
# on the 3-core runner. They run as background jobs instead, each into its own log, and the logs print
# whole, in this order, once all are done, so the output reads as it did serially and a failure's
# messages aren't interleaved with the others'. A job's subshell keeps set -e (it isn't on the left of
# an && or ||, where the shell would ignore it), so its first failing command ends it before the .ok.
JOBS=$(mktemp -d -t sp-bundle)
trap 'rm -rf "$JOBS"' EXIT
NAMES=
job() {
  _name=$1; shift
  NAMES="$NAMES $_name"
  ( "$@"; touch "$JOBS/$_name.ok" ) >"$JOBS/$_name.log" 2>&1 &
}
shims() {
  sh "$ROOT/shims/build.sh" "$1"
  cp "$ROOT/build/$1"/*.dylib "$ROOT/build/$1/exports.json" "$ROOT/shims/generated/rewrite-map.txt" "$RES/$1/"
  [ "$(ls "$RES/$1"/*.dylib | wc -l)" -gt 0 ] || { echo "no shim dylibs for $1 in build/$1" >&2; exit 1; }
}
for p in xros ios; do
  job "shims-$p" shims $p
  job "launcher-$p" env SP_PLATFORM=$p sh "$ROOT/apps/client/build-launcher.sh" "$RES/$p/slashplayed"
  job "helper-$p" env SP_PLATFORM=$p sh "$ROOT/apps/client/build-helper.sh" "$RES/$p/SPJitHelper"
  job "icon-$p" env SP_PLATFORM=$p sh "$ROOT/apps/client/build-icons.sh" "$RES/$p/icon"
done
wait
FAILED=
for name in $NAMES; do
  cat "$JOBS/$name.log" >&2
  [ -f "$JOBS/$name.ok" ] || FAILED="$FAILED $name"
done
[ -z "$FAILED" ] || { echo "bundle-resources: these builds failed (their output is above):$FAILED" >&2; exit 1; }

rm -rf "$RES/client" && mkdir -p "$RES/client/helper"
cp "$ROOT/apps/client/Info.plist" "$ROOT/apps/client/entitlements.plist" "$ROOT/apps/client/flavors.plist" "$RES/client/"
cp "$ROOT/apps/client/helper/Info.plist" "$ROOT/apps/client/helper/entitlements.plist" "$RES/client/helper/"
rm -f "$RES/jit.py"  # bundled while the Mac's lldb did the prepare
rm -rf "$RES/SPHover" && cp -R "$ROOT/addon/SPHover" "$RES/SPHover"

# The stub project goes in as a generated .xcodeproj with its sources beside it (xcodegen writes paths
# relative to the project, so the copy works wherever the app is).
rm -rf "$RES/signing" && mkdir -p "$RES/signing"
cp "$ROOT/apps/client/signing/project.yml" "$RES/signing/"
cp -R "$ROOT/apps/client/signing/Stub" "$RES/signing/Stub"
(cd "$RES/signing" && xcodegen generate --quiet) || { echo "xcodegen failed on the signing stub project" >&2; exit 1; }
rm "$RES/signing/project.yml"

rm -f "$RES/mac-identity"  # bundled before MacIdentity replaced it

# The third-party licenses, for the About panel's Acknowledgements link. Sparkle.txt comes from the build
# (project.yml copies it from the very Sparkle checkout it links), so it's checked rather than copied.
ACK=$RES/Acknowledgements
[ -s "$ACK/Sparkle.txt" ] || { echo "no Sparkle.txt in $ACK: the build's Sparkle license phase (project.yml) didn't run" >&2; exit 1; }
cp "$ROOT/work/idevice/macos/licenses/idevice.txt" "$ROOT/work/idevice/macos/licenses/rust-std.html" "$ACK/"
cp "$ROOT/work/zsign/licenses/zsign.txt" "$ROOT/work/zsign/licenses/openssl.txt" "$ACK/"
cp "$ROOT/work/idevice/ios/licenses/idevice.txt" "$ACK/idevice-ios.txt"
cp "$ROOT/work/idevice/xros/licenses/idevice.txt" "$ACK/idevice-visionos.txt"
cp "$FONT/LICENSE.md" "$ACK/goodmountain.txt"
cat > "$ACK/README.txt" <<'EOF'
Slashplayed Companion is MIT-licensed (Copyright (c) 2026 Straw Dynamics) and includes these
third-party components, each under its own license:

  Sparkle             the companion's own updates                     Sparkle.txt
  idevice             pairing a device over USB, with the Rust        idevice.txt
                      crates it's built with and the Rust standard    rust-std.html
                      library

The Slashplayed app it builds for your device also includes:

  zsign and OpenSSL   signing a game update on the device             zsign.txt, openssl.txt
  idevice             the JIT helper, with its Rust crates and the    idevice-ios.txt,
                      Rust standard library (rust-std.html)           idevice-visionos.txt
  Goodmountain        the start screen's typeface, by Hermann S       goodmountain.txt
                      Designs (shipped unmodified)

The device app carries the same texts in its own licenses/ folder.
EOF

# No absolute path from this Mac may end up in the app: the repo's would point at one the user doesn't
# have, and the home directory's (the Rust toolchain's and cargo's, in idevice's panic messages unless
# scripts/build-idevice.sh remaps them) names whoever built it.
for path in "$ROOT" "$HOME/"; do
  if grep -rlF "$path" "$APP" >/dev/null; then
    echo "these files in the app contain the path $path:" >&2
    grep -rlF "$path" "$APP" | sed 's/^/  /' >&2
    exit 1
  fi
done
echo "bundled resources into $APP" >&2
