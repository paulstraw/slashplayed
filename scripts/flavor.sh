# Which WoW flavor the tools work on. Sourced by the build, seed, run and addon scripts.
# SP_FLAVOR picks it: classic_era, anniversary (TBC Anniversary), classic (MoP Classic, in
# _classic_), retail, or forever (World of Warcraft: Forever, in _forever_). If it isn't set, the flavor
# last run by apps/client/run.sh is used (work/clienttest/last-flavor), so seed.sh, install.sh and
# grab-token.sh follow it; with no run yet, classic_era.
# SP_INSTALL (scripts/config.sh) is the game install, /Applications/World of Warcraft unless set.
# Sets:
#   SP_FLAVOR_DIR  the flavor's folder in the install, and on the headset in Documents/ (_classic_era_)
#   SP_CLIENT      the Mac client's executable
#   SP_PRODUCT     its product: .build.info's Product column, and the patch service's
#   SP_ARGS        the arguments Battle.net launches it with, less its credentials (run.sh passes them)
#   SP_FLAVORS     every flavor installed on the Mac (the ones apps/client/build.sh bundles)
. "$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || git rev-parse --show-toplevel)/scripts/config.sh"
: "${SP_INSTALL:=/Applications/World of Warcraft}"
_root=$SP_ROOT
if [ -z "$SP_FLAVOR" ]; then
  SP_FLAVOR=$(cat "$_root/work/clienttest/last-flavor" 2>/dev/null || true)
  : "${SP_FLAVOR:=classic_era}"
fi
# The flavors, their products, clients, arguments and addon numbers: apps/client/flavors.plist, also the companion's
# and the launcher's. Its key paths are <index>.<key>, so each one is found by its id.
_plist=$_root/apps/client/flavors.plist
_ids= _at=
_i=0
while _id=$(plutil -extract $_i.id raw -o - "$_plist" 2>/dev/null); do
  _ids="$_ids $_id"
  [ "$_id" = "$SP_FLAVOR" ] && _at=$_i
  _i=$((_i + 1))
done
[ -n "$_ids" ] || { echo "no flavors in $_plist (plutil can't read it)" >&2; exit 1; }
[ -n "$_at" ] || { echo "unknown SP_FLAVOR $SP_FLAVOR (one of:$_ids)" >&2; exit 1; }
# A key of any flavor's entry: _sp_flavor_key <id> <key>.
_sp_flavor_key() {
  _j=0
  while _x=$(plutil -extract $_j.id raw -o - "$_plist" 2>/dev/null); do
    [ "$_x" = "$1" ] && { plutil -extract $_j.$2 raw -o - "$_plist"; return; }
    _j=$((_j + 1))
  done
  echo "unknown flavor $1 (not in $_plist)" >&2
  return 1
}
# Any flavor's product (apps/client/build.sh stamps each image it bundles with its build).
sp_flavor_product() { _sp_flavor_key "$1" product; }
# Any flavor's Mac client in the install: its folder, then flavors.plist's client path.
sp_flavor_client() { echo "$SP_INSTALL/_$1_/$(_sp_flavor_key "$1" client)"; }
SP_PRODUCT=$(plutil -extract $_at.product raw -o - "$_plist")
SP_ARGS=
_i=0
while _arg=$(plutil -extract $_at.arguments.$_i raw -o - "$_plist" 2>/dev/null); do
  SP_ARGS="$SP_ARGS $_arg"
  _i=$((_i + 1))
done
SP_ARGS=${SP_ARGS# }
SP_FLAVOR_DIR=_${SP_FLAVOR}_
SP_CLIENT=$(sp_flavor_client $SP_FLAVOR)
SP_FLAVORS=
for _f in $_ids; do
  [ -f "$(sp_flavor_client $_f)" ] && SP_FLAVORS="$SP_FLAVORS $_f"
done
SP_FLAVORS=${SP_FLAVORS# }
echo "flavor: $SP_FLAVOR" >&2
