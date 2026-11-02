#!/bin/bash
# The device kit, the release asset slashplayed-setup installs from (apps/setup/src/kit.rs): the device app,
# unsigned and with no game images, for each device platform, assembled from what
# apps/companion/bundle-resources.sh stages, the way the companion's ClientAssembly.assemble assembles it with
# no clients (keep the three in step: a file the companion's app gets, the kit's gets too).
#
#   scripts/release/device-kit.sh <resources> <out.zip>
#
# <resources> holds xros/ and ios/ as bundle-resources.sh stages them (its --build output, or a built
# companion's Contents/Resources); the templates, flavors.plist, and the addons come from the repo, as
# bundle-resources.sh copies them. The zip holds:
#   kit.json                                  {"version": MARKETING_VERSION's X.Y.Z}
#   <platform>/Slashplayed.app/               the app; Info.plists filled for the platform and version, with
#                                             the bundle ID left as @BUNDLE_ID@ (the host fills it in)
#   <platform>/entitlements.plist             the app's template (@TEAM@, @BUNDLE_ID@)
#   <platform>/helper-entitlements.plist      the JIT helper's
# Nothing in it is Blizzard's: no client is read (release.sh's no-Blizzard-bytes check runs over it too).
# Needs macOS: the root CAs (sproots.plist) come from its system roots keychain, as build.sh's do.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
die() { echo "device-kit: $*" >&2; exit 1; }
[ $# -eq 2 ] || die "usage: $0 <resources dir> <out.zip>"
RES=$(cd "$1" && pwd) || die "no folder $1"
OUT=$2
command -v security >/dev/null || die "needs macOS (security, for the root CAs)"

WORK=$(mktemp -d -t sp-kit)
trap 'rm -rf "$WORK"' EXIT
KIT=$WORK/kit
mkdir -p "$KIT"

# The root CAs, for the client's own TLS trust store (shims/security/spssl.m): build.sh's way.
security find-certificate -a -p /System/Library/Keychains/SystemRootCertificates.keychain | python3 -I -c '
import base64, plistlib, re, sys
ders = [base64.b64decode(b) for b in re.findall(r"-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----", sys.stdin.read(), re.S)]
assert ders, "no root certificates"
plistlib.dump(ders, open(sys.argv[1], "wb"), fmt=plistlib.FMT_BINARY)' "$WORK/sproots.plist" || die "couldn't export the root CAs"

VERSION=
for p in xros ios; do
  SRC=$RES/$p
  [ -d "$SRC" ] || die "no $p/ in $RES (run apps/companion/bundle-resources.sh --build <dir> first)"
  # Each platform's settings from scripts/platform.sh, in a subshell so the two don't mix. sp_plist fills
  # every placeholder; giving it @BUNDLE_ID@ as the bundle ID leaves that one for the host.
  (
    export SP_PLATFORM=$p
    # shellcheck source=../platform.sh
    . "$ROOT/scripts/platform.sh" 2>/dev/null
    APP=$KIT/$p/Slashplayed.app
    mkdir -p "$APP/Frameworks" "$APP/PlugIns/SPJitHelper.appex"
    set -- "$SRC"/*.dylib
    [ -f "$1" ] || die "no shims in $SRC"
    cp "$@" "$APP/Frameworks/"
    for f in slashplayed SPJitHelper exports.json rewrite-map.txt Goodmountain-Regular.otf; do
      [ -f "$SRC/$f" ] || die "no $p/$f in $RES"
    done
    cp "$SRC/slashplayed" "$APP/"
    cp "$SRC/SPJitHelper" "$APP/PlugIns/SPJitHelper.appex/"
    sp_plist "$ROOT/apps/client/helper/Info.plist" "$APP/PlugIns/SPJitHelper.appex/Info.plist" @BUNDLE_ID@
    cp "$SRC/exports.json" "$SRC/rewrite-map.txt" "$SRC/Goodmountain-Regular.otf" "$APP/"
    [ -d "$SRC/licenses" ] || die "no $p/licenses in $RES"
    cp -R "$SRC/licenses" "$APP/licenses"
    [ -f "$SRC/icon/Assets.car" ] || die "no $p/icon/Assets.car in $RES"
    cp "$SRC"/icon/* "$APP/"
    sp_plist "$ROOT/apps/client/Info.plist" "$APP/Info.plist" @BUNDLE_ID@
    cp "$ROOT/apps/client/flavors.plist" "$APP/"
    for a in SPMovie SPHover; do
      mkdir -p "$APP/addons/$a"
      cp "$ROOT/addon/$a/$a.toc" "$ROOT/addon/$a/$a.lua" "$APP/addons/$a/"
    done
    : > "$APP/wow.icns"
    cp "$WORK/sproots.plist" "$APP/"
    cp "$ROOT/apps/client/entitlements.plist" "$KIT/$p/entitlements.plist"
    cp "$ROOT/apps/client/helper/entitlements.plist" "$KIT/$p/helper-entitlements.plist"
    for f in "$APP/Info.plist" "$APP/PlugIns/SPJitHelper.appex/Info.plist"; do
      [ "$(grep -o @BUNDLE_ID@ "$f" | wc -l | tr -d ' ')" = 1 ] || die "$f doesn't keep exactly one @BUNDLE_ID@"
      sed 's/@BUNDLE_ID@//' "$f" | grep -q '@[A-Z_]*@' && die "$f has a placeholder left besides @BUNDLE_ID@"
    done
    echo "$SP_VERSION" > "$WORK/version"
  )
done
VERSION=$(cat "$WORK/version")
printf '{"version":"%s"}\n' "$VERSION" > "$KIT/kit.json"

# No absolute path from this machine in the kit (as bundle-resources.sh checks the companion).
for path in "$ROOT" "$HOME/"; do
  if grep -rlF "$path" "$KIT" >/dev/null; then
    grep -rlF "$path" "$KIT" | sed 's/^/  /' >&2
    die "these kit files contain the path $path"
  fi
done

rm -f "$OUT"
mkdir -p "$(dirname "$OUT")"
OUT=$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")
# -X: no extra file attributes, so the zip is the same from any Mac.
(cd "$KIT" && zip -X -r -q "$OUT" kit.json ios xros) || die "zip failed"
echo "device kit $VERSION: $OUT ($(stat -f %z "$OUT") bytes, SHA-256 $(shasum -a 256 "$OUT" | cut -d' ' -f1))" >&2
