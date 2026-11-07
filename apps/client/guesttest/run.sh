#!/bin/bash
# Copies the toy (unsigned, out/toy-guest) into the installed app's Documents/, launches the app with no
# arguments (the helper attaches by itself, as in the client), and prints this run's part of
# Documents/guest.log. SP_GUEST_BUNDLE_ID as for build.sh. The helper needs what research/jittest's h3 does:
# LocalDevVPN on, Wi-Fi, Documents/pairingFile.plist and Documents/DDI (jittest's push-pairing.sh and
# push-ddi.sh, with SP_PUSH_TO set to the bundle ID).
set -euo pipefail
cd "$(dirname "$0")"
. ../../../scripts/platform.sh
BUNDLE_ID=${SP_GUEST_BUNDLE_ID:-com.strawdynamics.spguestloadtest}
sp_need_device
[ -f out/toy-guest ] || { echo "run.sh: no out/toy-guest (./build.sh device)" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
: > "$tmp/run.log"
xcrun devicectl device copy to --device "$SP_DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
  --source out/toy-guest --destination Documents/toy-guest >/dev/null
xcrun devicectl device process launch --device "$SP_DEVICE" --terminate-existing "$BUNDLE_ID" >/dev/null
echo "launched; waiting for it to finish (up to 3 minutes: a disk image mount can take a while)"
# The log is shared by every run: wait for the last "=== guest (" header and a "=== guest done" after it.
# Stop early once the app is gone without one.
for i in $(seq 36); do
  sleep 5
  rm -f "$tmp/guest.log"
  xcrun devicectl device copy from --device "$SP_DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source Documents/guest.log --destination "$tmp/guest.log" >/dev/null 2>&1 || continue
  awk 'index($0, "=== guest (") == 1 { buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }' \
    "$tmp/guest.log" > "$tmp/run.log"
  grep -q "^=== guest done" "$tmp/run.log" && break
  if [ "$i" -ge 2 ] && ! xcrun devicectl device info processes --device "$SP_DEVICE" 2>/dev/null | grep -q 'SPGuestLoadTest.app/SPGuestLoadTest'; then
    echo "(the app is gone without finishing: killed, or crashed; see the device's crash reports)"
    break
  fi
done
cat "$tmp/run.log"
