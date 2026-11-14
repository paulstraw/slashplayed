#!/bin/sh
# Copies the addons into the client's install root (Documents/_classic_era_ or the flavor's folder, see
# apps/client/seed.sh and scripts/flavor.sh), where the client looks for Interface/AddOns, as the
# companion does: SPMovie on every device, SPHover on the headset only, SPKeyboard on the iPad and iPhone. Each TOC lists every flavor's
# Interface number (apps/client/flavors.plist), so they're copied as they are. Survives reinstalls. The
# device is SP_PLATFORM's (scripts/platform.sh, scripts/config.sh).
set -e
cd "$(dirname "$0")"
. ../scripts/flavor.sh
. ../scripts/platform.sh
sp_need SP_BUNDLE_ID
sp_need_device
files="SPMovie/SPMovie.toc SPMovie/SPMovie.lua"
if [ "$SP_PLATFORM" = xros ]; then files="$files SPHover/SPHover.toc SPHover/SPHover.lua"
else files="$files SPKeyboard/SPKeyboard.toc SPKeyboard/SPKeyboard.lua"; fi
for f in $files; do
  xcrun devicectl device copy to --device "$SP_DEVICE" --domain-type appDataContainer \
    --domain-identifier "$SP_BUNDLE_ID" --source "$f" \
    --destination "Documents/$SP_FLAVOR_DIR/Interface/AddOns/$f" >/dev/null
  echo "copied $f"
done
