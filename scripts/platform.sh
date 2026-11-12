# Which device platform the tools build for. Sourced by the build and run scripts.
# SP_PLATFORM picks it: xros (Vision Pro, the default) or ios (M2-or-later iPad, iPhone 15 Pro or later).
# Sets:
#   SP_SDK          xcrun SDK name (xros, iphoneos)
#   SP_TARGET       clang target triple for app code
#   SP_METAL_TARGET metal -target for our own shaders
#   SP_VTOOL        vtool -set-build-version platform name
#   SP_MINOS        deployment target (also MinimumOSVersion)
#   SP_SUFFIX       appended to per-device work/ dirs (work/clienttest$SP_SUFFIX): empty or -ios
# sp_plist <in> <out> [bundle id] fills an Info.plist template: @BUNDLE_ID@, @PLATFORM@
# (CFBundleSupportedPlatforms), @DTPLATFORM@, @MINOS@, @FAMILY@ (UIDeviceFamily integers), @PLATFORM_KEYS@
# (keys only this platform gets: on iOS a launch screen, without which the app runs in a scaled
# 1024x768 compatibility mode, no status bar, and landscape only on an iPhone (it came up portrait and
# cropped; the iPad's window is landscape whatever the orientation, so it's left alone); on both the
# app icon's keys, as actool's partial Info.plist has them for apps/client/build-icons.sh's catalog), and
# @VERSION@ (CFBundleShortVersionString: SP_VERSION).
#   SP_VERSION      the device app's version: the companion's MARKETING_VERSION (apps/companion/project.yml),
#                   the one place a release's version is set, so the app's Settings > About shows the
#                   companion's. Its X.Y.Z only (an -rc1 suffix isn't a valid bundle version);
#                   ClientAssembly.swift takes the same from the companion's own Info.plist.
# Also loads scripts/config.sh (SP_TEAM, SP_SIGN_ID, SP_BUNDLE_ID, sp_need, and sp_need_device for the
# device UDID).
. "$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || git rev-parse --show-toplevel)/scripts/config.sh"
: "${SP_PLATFORM:=xros}"
export SP_PLATFORM
case $SP_PLATFORM in
  xros)
    SP_SDK=xros; SP_MINOS=27.0; SP_VTOOL=visionos
    SP_TARGET=arm64-apple-xros$SP_MINOS; SP_METAL_TARGET=air64-apple-xros$SP_MINOS
    _plat=XROS; _family='<integer>7</integer>'; SP_SUFFIX=
    _keys='<key>CFBundleIcons</key><dict><key>CFBundlePrimaryIcon</key><string>AppIcon</string></dict>' ;;
  ios)
    # The test iPad (iPad14,5, M2) runs iPadOS 26.6, the test iPhone (iPhone17,1, A18 Pro) iOS 27.0.1.
    SP_SDK=iphoneos; SP_MINOS=26.0; SP_VTOOL=ios
    SP_TARGET=arm64-apple-ios$SP_MINOS; SP_METAL_TARGET=air64-apple-ios$SP_MINOS
    # Family 1 (iPhone) and 2 (iPad): an app without 1 won't install on an iPhone. ClientAssembly.swift
    # has the same list.
    _plat=iPhoneOS; _family='<integer>1</integer><integer>2</integer>'; SP_SUFFIX=-ios
    _keys='<key>UILaunchScreen</key><dict/><key>UIStatusBarHidden</key><true/>'
    _keys="$_keys<key>UISupportedInterfaceOrientations~iphone</key><array><string>UIInterfaceOrientationLandscapeLeft</string><string>UIInterfaceOrientationLandscapeRight</string></array>"
    _keys="$_keys<key>CFBundleIcons</key><dict><key>CFBundlePrimaryIcon</key><dict><key>CFBundleIconFiles</key><array><string>AppIcon60x60</string></array><key>CFBundleIconName</key><string>AppIcon</string></dict></dict>"
    _keys="$_keys<key>CFBundleIcons~ipad</key><dict><key>CFBundlePrimaryIcon</key><dict><key>CFBundleIconFiles</key><array><string>AppIcon60x60</string><string>AppIcon76x76</string></array><key>CFBundleIconName</key><string>AppIcon</string></dict></dict>"
    # A game, with Game Mode (less background work, lower Bluetooth latency for a controller and AirPods),
    # and a game controller's extended profile, which is what lets Settings remap a controller for this app
    # (the client reads controllers itself, through GCController). ClientAssembly.swift has the same keys.
    _keys="$_keys<key>LSApplicationCategoryType</key><string>public.app-category.games</string><key>LSSupportsGameMode</key><true/>"
    _keys="$_keys<key>GCSupportsControllerUserInteraction</key><true/><key>GCSupportedGameControllers</key><array><dict><key>ProfileName</key><string>ExtendedGamepad</string></dict></array>" ;;
  *) echo "unknown SP_PLATFORM $SP_PLATFORM (xros, ios)" >&2; exit 1 ;;
esac
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || git rev-parse --show-toplevel)
SP_VERSION=$(awk -F'"' '/^ *MARKETING_VERSION:/ {print $2; exit}' "$_root/apps/companion/project.yml" | sed -E 's/^([0-9.]*).*/\1/')
[ -n "$SP_VERSION" ] || { echo "error: no MARKETING_VERSION in $_root/apps/companion/project.yml" >&2; exit 1; }
sp_plist() {
  sed -e "s/@BUNDLE_ID@/$3/" -e "s/@VERSION@/$SP_VERSION/" -e "s/@PLATFORM@/$_plat/" -e "s/@DTPLATFORM@/$SP_SDK/" \
    -e "s/@MINOS@/$SP_MINOS/" -e "s#@FAMILY@#$_family#" -e "s#@PLATFORM_KEYS@#$_keys#" "$1" > "$2"
}
# sp_profile <bundle id> prints the newest development profile made for that bundle id
# (apps/client/signing/regen.sh writes them), else the team wildcard profile.
sp_profile() {
  _best=; _wild=
  for _f in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.mobileprovision; do
    _n=$(security cms -D -i "$_f" 2>/dev/null | plutil -extract Name raw -o - - 2>/dev/null)
    case $_n in
      "iOS Team Provisioning Profile: $1") [ -z "$_best" ] || [ "$_f" -nt "$_best" ] && _best=$_f ;;
      "iOS Team Provisioning Profile: *") _wild=$_f ;;
    esac
  done
  echo "${_best:-$_wild}"
}
echo "platform: $SP_PLATFORM" >&2
