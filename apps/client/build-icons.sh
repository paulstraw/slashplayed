#!/bin/sh
# Compiles the device app's icon for SP_PLATFORM (scripts/platform.sh) into a directory whose contents go
# in the app's root:
#   apps/client/build-icons.sh <dir>
# On iOS the icon is icons/AppIcon.icon, the Icon Composer icon the companion uses too (a solid
# background under two glass layers, the medallion and the S; actool also writes the loose
# AppIcon60x60@2x.png and AppIcon76x76@2x~ipad.png older lookups use). visionOS has no .icon, so
# icons/xros.xcassets holds its three-layer solid image stack (back, middle, front; the system masks it
# to a circle), rendered from the same layers. The device app isn't an Xcode
# target, so actool runs here; the Info.plist keys that name the icon are in sp_plist's @PLATFORM_KEYS@
# (and ClientAssembly.Platform.platformKeys), as actool's partial Info.plist has them (on iOS both the
# iPhone's CFBundleIcons and the iPad's CFBundleIcons~ipad; the files are the same with either device).
# apps/client/build.sh compiles straight into its app; the companion's bundle-resources.sh into
# Resources/<platform>/icon/, which ClientAssembly copies, so the user's Mac never runs actool. Sources:
# art/ (README there).
set -e
[ -n "$1" ] || { echo "usage: $0 <dir>" >&2; exit 1; }
mkdir -p "$1"
OUT=$(cd "$1" && pwd)
cd "$(dirname "$0")"
. ../../scripts/platform.sh
case $SP_PLATFORM in
  xros) _source=icons/xros.xcassets; _devices='--target-device vision' ;;
  ios) _source=icons/AppIcon.icon; _devices='--target-device iphone --target-device ipad' ;;
esac
# Absolute: actool hands the work to a helper that resolves a relative input against its own working
# directory, not this one, then exits 0 with only a "Failed to read file attributes" notice. Quoted below:
# the checkout's path may have a space in it ("/Volumes/SSK SSD/..."). _devices is split on purpose.
_source=$(pwd)/$_source
PARTIAL=$(mktemp -t sp-icon-plist)
trap 'rm -f "$PARTIAL"' EXIT
# actool reports problems on stdout in its own plist and still exits 0 for most of them, so a warning or
# error there fails the build rather than shipping an app without its icon.
RESULT=$(xcrun actool "$_source" --compile "$OUT" --platform $SP_SDK \
  --minimum-deployment-target $SP_MINOS $_devices --app-icon AppIcon \
  --output-partial-info-plist "$PARTIAL" --output-format human-readable-text --warnings --errors) \
  || { echo "actool failed on $_source:" >&2; echo "$RESULT" >&2; exit 1; }
if echo "$RESULT" | grep -qE '/\* com\.apple\.actool\.(document|errors|warnings)'; then
  echo "actool complained about $_source:" >&2; echo "$RESULT" >&2; exit 1
fi
[ -f "$OUT"/Assets.car ] || { echo "actool wrote no Assets.car to $OUT" >&2; exit 1; }
