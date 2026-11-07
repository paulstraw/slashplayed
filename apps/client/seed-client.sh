#!/bin/bash
# Copies the Mac's installed client for SP_FLAVOR (scripts/flavor.sh) into the device app's data container,
# as the companion's Play copies the CDN's: the launcher loads it from there with spguest (launcher.m). The
# arm64 slice of the installed client (lipo -thin arm64: the same file as the CDN's slice, BlizzardCDN.swift's
# header comment), unchanged, as Library/spgames/wow-<flavor>, then its .build.info row (spbuildinfo-<flavor>:
# the install's header and the product's row), spsource-<flavor> ("mac"), and its stamp last
# (spbuild-<flavor>: .build.info's columns that name a build, for the flavor's product, as a one-row table of
# the same shape; the companion's ClientAssembly.Stamp writes the same bytes, ClientAssemblyTests checks the
# awk below against it). An empty stamp goes first, as the companion's copy does (devicectl can't delete), so
# a stamp is only ever beside a whole client of its build. For a device app built by build.sh, which carries
# no client; the game data is seed.sh's. Stop the app on the device first: the launcher maps the file it runs.
#   SP_PLATFORM=ios SP_FLAVOR=classic_era apps/client/seed-client.sh
# Everything staged goes in work/clienttest-seed-client$SP_SUFFIX/ (Blizzard's binary: never commit).
set -euo pipefail
cd "$(dirname "$0")"
. ../../scripts/platform.sh
. ../../scripts/flavor.sh
sp_need SP_BUNDLE_ID
sp_need_device
F=$SP_FLAVOR
P=$(sp_flavor_product "$F")
CLIENT=$(sp_flavor_client "$F")
INFO=$SP_INSTALL/.build.info
[ -f "$CLIENT" ] || { echo "seed-client.sh: no $F client at $CLIENT (SP_INSTALL, scripts/flavor.sh)" >&2; exit 1; }
[ -f "$INFO" ] || { echo "seed-client.sh: no .build.info in $SP_INSTALL" >&2; exit 1; }
OUT=../../work/clienttest-seed-client$SP_SUFFIX
rm -rf "$OUT" && mkdir -p "$OUT"

lipo -thin arm64 "$CLIENT" -output "$OUT/wow-$F"
awk -F'|' -v p="$P" '
    NR == 1 { for (i = 1; i <= NF; i++) { split($i, n, "!"); c[n[1]] = i }; next }
    $c["Product"] == p { row = p "|" $c["Branch"] "|" $c["Build Key"] "|" $c["Version"]; ok = $c["Build Key"] != "" && $c["Version"] != "" }
    END {
      if (!ok) { print "the game install has no " p " build in .build.info" > "/dev/stderr"; exit 1 }
      print "Product!STRING:0|Branch!STRING:0|Build Key!HEX:16|Version!STRING:0"
      print row
    }' "$INFO" > "$OUT/spbuild-$F"
# The install's row for the product (the last, as GameStore.buildInfo takes it), under its header.
awk -F'|' -v p="$P" '
    NR == 1 { head = $0; for (i = 1; i <= NF; i++) { split($i, n, "!"); if (n[1] == "Product") col = i }; next }
    $col == p { row = $0 }
    END { if (row == "") exit 1; print head; print row }' "$INFO" > "$OUT/spbuildinfo-$F"
echo mac > "$OUT/spsource-$F"
: > "$OUT/empty"

copy() {
  xcrun devicectl device copy to --device "$SP_DEVICE" --domain-type appDataContainer \
    --domain-identifier "$SP_BUNDLE_ID" --source "$1" --destination "$2" >/dev/null
}
copy "$OUT/empty" "Library/spgames/spbuild-$F"
for f in "wow-$F" "spbuildinfo-$F" "spsource-$F" "spbuild-$F"; do copy "$OUT/$f" "Library/spgames/$f"; done
echo "seeded Library/spgames/wow-$F: $(tail -n 1 "$OUT/spbuild-$F" | cut -d'|' -f4), $(stat -f %z "$OUT/wow-$F") bytes"
