#!/bin/sh
# Copies everything the companion needs at run time into a built "Slashplayed Companion.app", so the app
# never reads the repo (build.sh, scripts/release/release.sh, and update-test.sh run it):
#   apps/companion/bundle-resources.sh <app>
# or in two phases, so the device builds can run while Xcode compiles the app (build.sh does: they read
# nothing from it, and on CI's 3-core runner they'd otherwise wait about 2 minutes on a compile that
# leaves a core idle):
#   apps/companion/bundle-resources.sh --build <staging dir>          the per-platform builds, no app
#   apps/companion/bundle-resources.sh --install <staging dir> <app>  their output and the rest, into it
# Contents/Resources/ gets, per device platform (xros, ios), <platform>/: the unsigned shim dylibs, their
# exports.json (the bind check's manifest) and rewrite-map.txt, the unsigned launcher (slashplayed) and
# licenses/ (the device app's: idevice's with its crates' and the Rust standard library's, which the helper links, from
# scripts/build-idevice.sh <platform>, and the start screen's face's, goodmountain.txt), the start screen's
# face, Goodmountain-Regular.otf, unmodified (scripts/fetch-font.sh: its license forbids changing it), the unsigned JIT helper's executable (SPJitHelper,
# apps/client/build-helper.sh: needs idevice for the platform), and icon/ (the device app's compiled icon,
# apps/client/build-icons.sh; actool needs Xcode, so not at run time).
# Acknowledgements/ (the About panel links it): every third-party license the companion ships. Sparkle's
# the build put there (project.yml); this adds idevice's as the companion links it, and the device app's.
# Once, for both platforms: client/Info.plist and client/entitlements.plist (the device app's templates),
# client/flavors.plist (copied into the app as it is), and client/helper/'s
# two (the helper's), the addons (addons/SPHover, addons/SPMovie: their .toc and .lua), the signing stub project (signing/SPProfiles.xcodeproj, generated
# here, since the user's Mac has no xcodegen). (The identity
# file mac-identity.c writes comes from its Swift port, MacIdentity.) Needs xcodegen; nothing here is Blizzard's (no client is read).
set -euo pipefail
usage() {
  echo "usage: $0 <path to Slashplayed Companion.app>" >&2
  echo "       $0 --build <staging dir>" >&2
  echo "       $0 --install <staging dir> <path to Slashplayed Companion.app>" >&2
  exit 1
}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# Scratch removed on exit: the one-shot's staging dir and the build jobs' logs.
SCRATCH=
trap 'rm -rf $SCRATCH' EXIT
# The build phase makes each <platform>/ whole in $STAGE; the install phase copies it into the app as it is.
case "${1:-}" in
  --build) [ $# -eq 2 ] || usage; MODE=build; STAGE=$(mkdir -p "$2" && cd "$2" && pwd) ;;
  --install) [ $# -eq 3 ] && [ -d "$3/Contents" ] || usage; MODE=install; STAGE=$(cd "$2" && pwd); APP=$(cd "$3" && pwd) ;;
  *) [ $# -eq 1 ] && [ -d "$1/Contents" ] || usage; MODE=oneshot; STAGE=$(mktemp -d -t sp-stage); SCRATCH=$STAGE
     APP=$(cd "$1" && pwd) ;;
esac
FONT=$ROOT/work/fonts
for f in "$FONT/Goodmountain-Regular.otf" "$FONT/LICENSE.md"; do
  [ -f "$f" ] || { echo "no ${f#"$ROOT"/} (run scripts/fetch-font.sh)" >&2; exit 1; }
done

if [ "$MODE" != install ]; then
# A re-run starts each platform's folder over, and the marker goes until the builds all succeed, so the
# install phase never takes a failed or half-done build phase's output.
rm -f "$STAGE/.built"
for p in xros ios; do
  rm -rf "${STAGE:?}/$p" && mkdir -p "$STAGE/$p/licenses"
  cp "$ROOT/work/idevice/$p/licenses/idevice.txt" "$ROOT/work/idevice/$p/licenses/rust-std.html" "$STAGE/$p/licenses/"
  cp "$FONT/LICENSE.md" "$STAGE/$p/licenses/goodmountain.txt"
  cp "$FONT/Goodmountain-Regular.otf" "$STAGE/$p/"
done

# The builds, per platform: the shims, the launcher, the JIT helper, and the icon. None reads another's
# output (each writes its own file or folder: build/<platform>/, mktemp scratch), and each is a chain of
# single-threaded compiler runs, so one after another they left most cores idle: about 55s of a CI run
# on the 3-core runner. They run as background jobs instead, each into its own log, and the logs print
# whole, in this order, once all are done, so the output reads as it did serially and a failure's
# messages aren't interleaved with the others'. A job's subshell keeps set -e (it isn't on the left of
# an && or ||, where the shell would ignore it), so its first failing command ends it before the .ok.
JOBS=$(mktemp -d -t sp-bundle)
SCRATCH="$SCRATCH $JOBS"
NAMES=
job() {
  _name=$1; shift
  NAMES="$NAMES $_name"
  ( "$@"; touch "$JOBS/$_name.ok" ) >"$JOBS/$_name.log" 2>&1 &
}
shims() {
  sh "$ROOT/shims/build.sh" "$1"
  cp "$ROOT/build/$1"/*.dylib "$ROOT/build/$1/exports.json" "$ROOT/shims/generated/rewrite-map.txt" "$STAGE/$1/"
  [ "$(ls "$STAGE/$1"/*.dylib | wc -l)" -gt 0 ] || { echo "no shim dylibs for $1 in build/$1" >&2; exit 1; }
}
for p in xros ios; do
  job "shims-$p" shims $p
  job "launcher-$p" env SP_PLATFORM=$p sh "$ROOT/apps/client/build-launcher.sh" "$STAGE/$p/slashplayed"
  job "helper-$p" env SP_PLATFORM=$p sh "$ROOT/apps/client/build-helper.sh" "$STAGE/$p/SPJitHelper"
  job "icon-$p" env SP_PLATFORM=$p sh "$ROOT/apps/client/build-icons.sh" "$STAGE/$p/icon"
done
wait
FAILED=
for name in $NAMES; do
  cat "$JOBS/$name.log" >&2
  [ -f "$JOBS/$name.ok" ] || FAILED="$FAILED $name"
done
[ -z "$FAILED" ] || { echo "bundle-resources: these builds failed (their output is above):$FAILED" >&2; exit 1; }
touch "$STAGE/.built"
[ "$MODE" = oneshot ] || { echo "built the bundle's device builds into $STAGE" >&2; exit 0; }
fi

[ -f "$STAGE/.built" ] || { echo "no finished build phase in $STAGE (run $0 --build $STAGE first)" >&2; exit 1; }
RES=$APP/Contents/Resources
mkdir -p "$RES"
for p in xros ios; do
  rm -rf "${RES:?}/$p" && cp -R "$STAGE/$p" "$RES/$p"
done

rm -rf "$RES/client" && mkdir -p "$RES/client/helper"
cp "$ROOT/apps/client/Info.plist" "$ROOT/apps/client/entitlements.plist" "$ROOT/apps/client/flavors.plist" "$RES/client/"
cp "$ROOT/apps/client/helper/Info.plist" "$ROOT/apps/client/helper/entitlements.plist" "$RES/client/helper/"
rm -f "$RES/jit.py"  # bundled while the Mac's lldb did the prepare
# The addons, into the device app as it's assembled (ClientAssembly.addonFiles): the launcher puts them in
# each game's folder. The loose copies are from before, when the companion copied them to the device itself.
rm -rf "${RES:?}/SPHover" "${RES:?}/SPMovie" "${RES:?}/addons"
for a in SPHover SPMovie; do mkdir -p "$RES/addons/$a" && cp "$ROOT/addon/$a/$a.toc" "$ROOT/addon/$a/$a.lua" "$RES/addons/$a/"; done

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

# The notices, checked as the app now has them rather than as the copies above meant them: a file missing,
# extra, stale, or altered on the way in fails the build, every build (it takes well under a second).
# bundled-notices.txt names each one and its source, and AcknowledgementsTests holds ClientAssembly's
# lists (what the companion copies into the device app) to the same file, so the two can't drift. This
# replaced a test that read the built app, which made CI compile a whole Debug app and test bundle
# after the build just to compare these files. Every problem is listed before it fails, not just the first.
NL='
'
PROBLEMS=
problem() { PROBLEMS="$PROBLEMS  $1$NL"; }
same() {  # <file in the app> <its source>: byte for byte (the font's license forbids any change to it)
  if [ ! -f "$2" ]; then problem "no ${2#"$ROOT"/} to check ${1#"$RES"/} against"
  elif ! cmp -s "$1" "$2"; then problem "${1#"$RES"/} isn't ${2#"$ROOT"/} byte for byte (or is missing)"; fi
}
names() {  # <dir> <the names it should hold, one per line>: exactly those, nothing more
  _have=$(ls -A "$1" 2>/dev/null | LC_ALL=C sort)
  _want=$(printf '%s\n' "$2" | sed '/^$/d' | LC_ALL=C sort)
  [ "$_have" = "$_want" ] ||
    problem "${1#"$RES"/} holds [$(echo $_have)], not bundled-notices.txt's [$(echo $_want)]"
}
LICENSES= FONTS= ACKS="README.txt${NL}Sparkle.txt"
while read -r kind name src; do
  case $kind in
    ''|'#'*) continue ;;
    license|font)
      [ "$kind" = license ] && LICENSES="$LICENSES$NL$name" || FONTS="$FONTS$NL$name"
      [ "$kind" = license ] && dir=licenses/ || dir=
      for p in xros ios; do same "$RES/$p/$dir$name" "$ROOT/$(printf %s "$src" | sed "s/{platform}/$p/g")"; done ;;
    acknowledgement) ACKS="$ACKS$NL$name"; same "$ACK/$name" "$ROOT/$src" ;;
    *) problem "bundled-notices.txt: unknown kind \"$kind\" (license, font, or acknowledgement)" ;;
  esac
done < "$ROOT/apps/companion/bundled-notices.txt"
[ -n "$LICENSES" ] && [ -n "$FONTS" ] || problem "bundled-notices.txt lists no license or no font"
for p in xros ios; do
  names "$RES/$p/licenses" "$LICENSES"
  for f in $FONTS; do [ -f "$RES/$p/$f" ] || problem "no $p/$f"; done
done
names "$ACK" "$ACKS"
[ -s "$ACK/README.txt" ] || problem "Acknowledgements/README.txt is empty"
# Sparkle's own license file ends with its dependencies' under this heading: the whole notice, not a stub.
grep -q "EXTERNAL LICENSES" "$ACK/Sparkle.txt" ||
  problem "Acknowledgements/Sparkle.txt has no EXTERNAL LICENSES section: not Sparkle's whole notice"
if [ -n "$PROBLEMS" ]; then
  printf 'bundle-resources: the notices in %s are wrong:\n%s' "$APP" "$PROBLEMS" >&2
  exit 1
fi
echo "bundled resources into $APP" >&2
