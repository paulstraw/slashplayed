#!/bin/bash
# Copies an Apple token into the installed Slashplayed's Library/spappletoken.json, as slashplayed-companion's
# setup does: the launcher imports it into its keychain at its next start (apps/client/spapple.m: this device
# only, never synced) and zeroes and deletes the file whatever happens. A dev script, for testing the app's
# profile renewal (run.sh's SP_PROFILES_DRILL=apple) with a login the isideload spike stored:
#
#   apps/client/push-apple-token.sh <apple-id>
#
# The token comes from `spisideload export-token` (research/isideload) into a 0600 file in a fresh scratch
# folder, which is zeroed and deleted (rm -P) once it's copied, or on any failure. It's a credential: this
# never prints it or its size. SP_PLATFORM and SP_DEVICE pick the device, as for build.sh; SP_BUNDLE_ID the
# app (config/local.env).
set -euo pipefail
cd "$(dirname "$0")"
. ../../scripts/platform.sh
die() { echo "push-apple-token.sh: $*" >&2; exit 1; }
[ $# = 1 ] || die "usage: push-apple-token.sh <apple-id> (a login spisideload stored)"
sp_need SP_BUNDLE_ID
sp_need_device
SPISIDELOAD=../../work/isideload/spisideload
[ -x "$SPISIDELOAD" ] || die "no $SPISIDELOAD (run research/isideload/build.sh)"
dir=$(mktemp -d "${TMPDIR:-/tmp}/spappletoken.XXXXXX")
trap 'rm -P -f "$dir/token.json"; rmdir "$dir"' EXIT
"$SPISIDELOAD" export-token --apple-id "$1" --out "$dir/token.json" >/dev/null 2>&1 ||
  die "spisideload export-token failed (is there a stored login for that Apple ID?)"
xcrun devicectl device copy to --device "$SP_DEVICE" --domain-type appDataContainer --domain-identifier "$SP_BUNDLE_ID" \
  --source "$dir/token.json" --destination Library/spappletoken.json >/dev/null ||
  die "couldn't copy the token into $SP_BUNDLE_ID (is it installed? build.sh)"
echo "pushed an Apple token to $SP_BUNDLE_ID; the launcher imports it at its next start"
