#!/bin/bash
# Copies a development identity's .p12 and its password into the installed Slashplayed's Library/
# (spidentity.p12, spidentity.pass), as the companion's push will: the launcher imports them into its
# keychain at its next start (apps/client/spsign.m: checked with SecPKCS12Import first, this device only,
# never synced) and zeroes and deletes both files whatever happens. A dev script, for testing the plumbing
# with a throwaway identity of your own: a certificate no installed profile lists signs images the device
# refuses, which is what the test expects.
#
#   apps/client/push-identity.sh <identity.p12>     # its password in <identity>.pass beside it, both 0600
#   apps/client/push-identity.sh --forget           # the launcher forgets it at its next start
#
# Then, to sign a fixture of our own and load it (the launcher's SP_SIGN_TEST hook; nothing else runs):
#   xcrun devicectl device copy to --device "$SP_DEVICE" --domain-type appDataContainer \
#     --domain-identifier "$SP_BUNDLE_ID" --source <fixture.bundle> --destination Library/spsigntest/fixture.bundle
#   DEVICECTL_CHILD_SP_SIGN_TEST=Library/spsigntest/fixture.bundle xcrun devicectl device process launch \
#     --device "$SP_DEVICE" --terminate-existing --console "$SP_BUNDLE_ID"
# --forget copies the companion's own request, Library/spidentity.forget (what turning Update Games on This
# Device off sends): the launcher deletes the identity and the marker at its next start. The Settings sheet's
# Forget Signing Identity does it at once, but also tells the companion to turn the setting off.
#
# The .p12 and its password are credentials: this never prints them, only sizes. SP_PLATFORM and SP_DEVICE
# pick the device, as for build.sh; SP_BUNDLE_ID the app (config/local.env).
set -euo pipefail
cd "$(dirname "$0")"
. ../../scripts/platform.sh
die() { echo "push-identity.sh: $*" >&2; exit 1; }
[ $# = 1 ] || die "usage: push-identity.sh <identity.p12> (its password in <identity>.pass), or push-identity.sh --forget"
sp_need SP_BUNDLE_ID
copy() {
  xcrun devicectl device copy to --device "$SP_DEVICE" --domain-type appDataContainer --domain-identifier "$SP_BUNDLE_ID" \
    --source "$1" --destination "$2" >/dev/null || die "couldn't copy $2 into $SP_BUNDLE_ID (is it installed? build.sh)"
}
if [ "$1" = --forget ]; then
  sp_need_device
  marker=$(mktemp "${TMPDIR:-/tmp}/spidentity.forget.XXXXXX")
  trap 'rm -f "$marker"' EXIT
  echo forget >"$marker"
  copy "$marker" Library/spidentity.forget
  echo "asked $SP_BUNDLE_ID to forget its signing identity; the launcher does at its next start"
  exit 0
fi
p12=$1
pass=${p12%.p12}.pass
[ -f "$p12" ] && [ -f "$pass" ] || die "need both $p12 and $pass"
for f in "$p12" "$pass"; do
  [ "$(stat -f %Lp "$f")" = 600 ] || die "$f isn't 0600: a credential stays readable only by you"
done
sp_need_device
# The password last: the launcher imports only a pair, and deletes a lone .p12.
copy "$p12" Library/spidentity.p12
copy "$pass" Library/spidentity.pass
echo "copied the .p12 ($(stat -f %z "$p12") bytes) and its password to $SP_BUNDLE_ID's Library/; the launcher imports and deletes them at its next start"
