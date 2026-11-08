#!/bin/bash
# The spike end to end on an iPad or iPhone: provisions with spisideload (which reuses what exists and
# makes nothing: run `spisideload provision --create-app-ids --create-cert` once first, by hand), builds
# the device app with no game images under the spike's bundle ID, signs it with zsign (or isideload's
# apple-codesign-quick) using those profiles and that identity, installs it with devicectl, and launches it
# to its start screen. Optionally copies an installed Slashplayed's RemotePairing record across so the JIT
# helper can be tried (apps/client/run.sh). (It once also pushed the identity for the launcher to sign game
# updates with; the launcher loads the unchanged client with spguest now and signs nothing.)
#
#   SP_DEVICE=<udid> SPIKE_APPLE_ID=<id> SPIKE_TEAM=<team> SPIKE_KIND=free|paid SPIKE_OUT=<dir> \
#     research/isideload/sign-install.sh
#
#   SPIKE_SIGNER=zsign (default) or quick (apple-codesign-quick, through spisideload sign-quick)
#   SPIKE_PAIRING_FROM=<bundle id>  copy that installed app's Library/sppairing.plist to the spike's
#
# The app is <team>.slashplayed.spike (helper .helper): never the owner's real bundle ID, so the real
# install's App IDs, profiles, and data container are untouched (the record copy only reads it).
# Output in SPIKE_OUT: provision.json, profiles/, signed-{app,helper}.entitlements, verify.txt,
# result.txt. The identity (key.pem, cert.pem, spidentity.p12/.pass) is made in a private mktemp folder
# for this run and overwritten and deleted on exit, whatever happens; the record likewise.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
die() { echo "sign-install.sh: $*" >&2; exit 1; }
for v in SP_DEVICE SPIKE_APPLE_ID SPIKE_TEAM SPIKE_KIND SPIKE_OUT; do
  [ -n "${!v:-}" ] || die "$v isn't set (see the header)"
done
case $SPIKE_KIND in free|paid) ;; *) die "SPIKE_KIND is free or paid" ;; esac
SIGNER=${SPIKE_SIGNER:-zsign}
case $SIGNER in zsign|quick) ;; *) die "SPIKE_SIGNER is zsign or quick" ;; esac
CLI=$ROOT/work/isideload/spisideload
ZSIGN=$ROOT/work/isideload/zsign
[ -x "$CLI" ] && [ -x "$ZSIGN" ] || die "run research/isideload/build.sh first"
BUNDLE=$SPIKE_TEAM.slashplayed.spike
mkdir -p "$SPIKE_OUT"
OUT=$(cd "$SPIKE_OUT" && pwd)

WORK=$(mktemp -d "${TMPDIR:-/tmp}/spike-sign.XXXXXX")
chmod 700 "$WORK"
mkdir -m 700 "$WORK/identity"
cleanup() {
  for f in "$WORK"/identity/* "$WORK"/sppairing.plist; do
    [ -f "$f" ] && rm -P "$f"
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "== provision ($SPIKE_KIND team)" >&2
"$CLI" provision --apple-id "$SPIKE_APPLE_ID" --team "$SPIKE_TEAM" --udid "$SP_DEVICE" "--$SPIKE_KIND" \
  --out "$OUT/profiles" --identity "$WORK/identity" --report "$OUT/provision.json"

echo "== build (no images, ios)" >&2
# Signed ad hoc here (SP_SIGN_ID=-): the real signature is the signer's below, over everything.
SP_PLATFORM=ios SP_NO_INSTALL=1 SP_TEAM=$SPIKE_TEAM SP_BUNDLE_ID=$BUNDLE SP_SIGN_ID=- \
  SP_PROFILE=$OUT/profiles/app.mobileprovision SP_HELPER_PROFILE=$OUT/profiles/helper.mobileprovision \
  SP_OUT=$WORK/build "$ROOT/apps/client/build.sh" >"$OUT/build.txt" 2>&1 || die "build failed: $OUT/build.txt"
APP=$WORK/build/Slashplayed.app

echo "== sign ($SIGNER)" >&2
start=$(date +%s)
if [ "$SIGNER" = zsign ]; then
  # Each bundle gets the profile whose application-identifier ends in its bundle ID, and that profile's
  # entitlements (no -e: zsign's -e would give the helper the app's).
  # From the private folder: zsign keeps a .zsign_cache in its working directory.
  ( cd "$WORK" && "$ZSIGN" -f -q -k "$WORK/identity/key.pem" -c "$WORK/identity/cert.pem" \
      -m "$OUT/profiles/app.mobileprovision" -m "$OUT/profiles/helper.mobileprovision" "$APP" ) ||
    die "zsign failed"
else
  "$CLI" sign-quick --apple-id "$SPIKE_APPLE_ID" --profiles "$OUT/profiles" --app "$APP" \
    --report "$OUT/sign-quick.json" || die "apple-codesign-quick failed"
fi
echo "signer=$SIGNER seconds=$(( $(date +%s) - start ))" >"$OUT/result.txt"
codesign -d --entitlements - --xml "$APP" >"$OUT/signed-app.entitlements" 2>/dev/null || true
codesign -d --entitlements - --xml "$APP/PlugIns/SPJitHelper.appex" >"$OUT/signed-helper.entitlements" 2>/dev/null || true
{ codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 || true; } >"$OUT/verify.txt"

echo "== install" >&2
if xcrun devicectl device install app --device "$SP_DEVICE" "$APP" >"$OUT/install.txt" 2>&1; then
  echo "install=ok" >>"$OUT/result.txt"
else
  echo "install=failed" >>"$OUT/result.txt"
  die "install failed: $OUT/install.txt"
fi

if [ -n "${SPIKE_PAIRING_FROM:-}" ]; then
  echo "== copy the RemotePairing record from $SPIKE_PAIRING_FROM" >&2
  # A credential: through a 0600 file in the private folder, deleted (rm -P) on exit; never read here.
  ( umask 077
    xcrun devicectl device copy from --device "$SP_DEVICE" --domain-type appDataContainer \
      --domain-identifier "$SPIKE_PAIRING_FROM" --source Library/sppairing.plist \
      --destination "$WORK/sppairing.plist" >/dev/null ) || die "couldn't copy the record from $SPIKE_PAIRING_FROM"
  chmod 600 "$WORK/sppairing.plist"
  xcrun devicectl device copy to --device "$SP_DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
    --source "$WORK/sppairing.plist" --destination Library/sppairing.plist >/dev/null || die "couldn't copy the record to $BUNDLE"
  echo "pairing_record=copied bytes=$(stat -f %z "$WORK/sppairing.plist")" >>"$OUT/result.txt"
fi

echo "== launch to the start screen" >&2
# By pid: the owner's real Slashplayed has the same executable path, so a name match proves nothing.
if xcrun devicectl device process launch --device "$SP_DEVICE" --terminate-existing --json-output "$WORK/launch.json" \
    "$BUNDLE" >"$OUT/launch.txt" 2>&1; then
  pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["result"]["process"]["processIdentifier"])' "$WORK/launch.json")
  sleep 5
  xcrun devicectl device info processes --device "$SP_DEVICE" --json-output "$WORK/procs.json" >/dev/null 2>&1 || true
  if python3 -c 'import json,sys; sys.exit(0 if any(p.get("processIdentifier") == int(sys.argv[2]) for p in json.load(open(sys.argv[1]))["result"]["runningProcesses"]) else 1)' \
      "$WORK/procs.json" "$pid"; then
    echo "launch=running after 5 s" >>"$OUT/result.txt"
  else
    echo "launch=not running after 5 s" >>"$OUT/result.txt"
  fi
else
  echo "launch=failed" >>"$OUT/result.txt"
fi
cat "$OUT/result.txt"
