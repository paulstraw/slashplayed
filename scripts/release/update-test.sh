#!/bin/bash
# Tests the companion's Sparkle update path end to end without publishing anything: builds two throwaway
# versions, serves the higher one from a local appcast, and prints how to update the lower one to it.
#
# Usage: scripts/release/update-test.sh [--port N] [--real-key]     (default port 8765)
#
# What it does:
#   1. Builds the companion (Release, resources bundled as apps/companion/build.sh does) twice into
#      build/update-test/: old/ as <MARKETING_VERSION>-test, new/ as <MARKETING_VERSION, patch + 1>-test,
#      with CFBundleVersion an epoch stamp and that stamp + 1, so Sparkle sees new/ as the update. Both
#      get SUFeedURL http://127.0.0.1:<port>/appcast.xml and the test's SUPublicEDKey through build
#      settings (SP_SPARKLE_FEED_URL, SP_SPARKLE_PUBLIC_KEY in project.yml); no committed file is edited.
#   2. Signs both as a release is signed: Sparkle's helpers inside out, then the app, with the hardened
#      runtime, using the first "Developer ID Application" identity in the keychain (or
#      SP_UPDATE_TEST_SIGN_ID). The hardened runtime's library validation is part of what's being tested
#      (it's why build.sh's ad hoc builds leave it off). With no such identity, both are ad hoc without
#      the runtime, as build.sh makes them, with a warning.
#   3. Zips new/ with ditto, signs the zip with EdDSA, writes a one-item appcast and serves
#      build/update-test/serve/ with `python3 -m http.server` on 127.0.0.1 until Ctrl-C.
#
# The EdDSA key. By default a throwaway one, made here (CryptoKit, through xcrun swift: /usr/bin/openssl
# is LibreSSL without Ed25519) and kept in build/update-test/key/, so the test needs nothing from the
# owner: both builds trust it, so old/ really verifies new/'s signature. --real-key signs with the
# Sparkle key in the login keychain (account SPARKLE_KEY_ACCOUNT, default the companion's bundle ID)
# instead and builds both with its public half; that's the one to use for pointing an installed release
# (or rc) at this feed, since an installed app only accepts updates signed with the key it was built with.
#
# The test builds share the companion's defaults domain with any installed copy (same bundle ID), so
# they see the real settings; they never touch /Applications or a device. Plain http on 127.0.0.1 needs
# no App Transport Security exception (ATS doesn't apply to IP-address hosts); the EdDSA signature is
# what authenticates the update. Sparkle honours a SUFeedURL in the app's defaults for testing (it logs
# a deprecation warning that says as much); the printed commands use that for an installed copy built
# with the real feed.
#
# Environment:
#   SP_UPDATE_TEST_SIGN_ID   codesign identity for both builds (default: the first Developer ID Application)
#   SPARKLE_KEY_ACCOUNT      keychain account of the Sparkle key for --real-key (default: the bundle ID)
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$(pwd)

PORT=8765
REAL_KEY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || { echo "error: --port needs a number" >&2; exit 2; }
      PORT="$2"; shift 2 ;;
    --real-key) REAL_KEY=1; shift ;;
    *) echo "usage: $(basename "$0") [--port N] [--real-key]" >&2; exit 2 ;;
  esac
done

OUT=$ROOT/build/update-test
SERVE=$OUT/serve
FEED_URL="http://127.0.0.1:$PORT/appcast.xml"
APP_NAME="Slashplayed Companion.app"
APP_ID=com.strawdynamics.slashplayed.companion
PROJECT_YML=apps/companion/project.yml

MARKETING="$(awk -F'"' '/^ *MARKETING_VERSION:/ {print $2; exit}' "$PROJECT_YML")"
if [[ ! "$MARKETING" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "error: $PROJECT_YML MARKETING_VERSION is '$MARKETING', expected X.Y.Z" >&2
  exit 1
fi
OLD_VERSION="$MARKETING-test"
NEW_VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((BASH_REMATCH[3] + 1))-test"
OLD_BUILD="$(date +%s)"
NEW_BUILD=$((OLD_BUILD + 1))

# Fail before two multi-minute builds if the port is taken.
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "error: something is already listening on port $PORT; pass --port N" >&2
  exit 1
fi
command -v xcodegen >/dev/null || { echo "error: xcodegen not found (brew install xcodegen)" >&2; exit 1; }

SIGN_ID="${SP_UPDATE_TEST_SIGN_ID:-}"
if [[ -z "$SIGN_ID" ]]; then
  SIGN_ID="$(security find-identity -v -p codesigning | sed -nE 's/^ *[0-9]+\) [0-9A-F]{40} "(Developer ID Application: .*)"$/\1/p' | head -n1)"
fi
if [[ -z "$SIGN_ID" ]]; then
  echo "warning: no Developer ID Application identity; signing ad hoc without the hardened runtime." >&2
  echo "         That skips the library-validation half of the test; set SP_UPDATE_TEST_SIGN_ID to cover it." >&2
fi

rm -rf "$OUT/old" "$OUT/new" "$SERVE"
mkdir -p "$OUT" "$SERVE"

# Sparkle's tools, from the very version the app links (resolved by the build below; build.sh's
# DerivedData would do too, but this one always matches).
DD=$OUT/DerivedData
SPARKLE_BIN=$DD/SourcePackages/artifacts/sparkle/Sparkle/bin

(cd apps/companion && xcodegen generate --quiet)
# Resolve packages first: the key has to be known before either build.
xcodebuild -project apps/companion/SPCompanion.xcodeproj -scheme SPCompanion \
  -derivedDataPath "$DD" -quiet -resolvePackageDependencies
if [[ ! -x "$SPARKLE_BIN/sign_update" || ! -x "$SPARKLE_BIN/generate_keys" ]]; then
  echo "error: sign_update/generate_keys not found in $SPARKLE_BIN. The Sparkle SPM artifact layout" >&2
  echo "       may have changed; look under $DD/SourcePackages/artifacts." >&2
  exit 1
fi

if [[ $REAL_KEY == 1 ]]; then
  KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-$APP_ID}"
  PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" --account "$KEY_ACCOUNT" -p 2>/dev/null || true)"
  [[ -n "$PUBLIC_KEY" ]] || { echo "error: no Sparkle key in the login keychain for account $KEY_ACCOUNT (set SPARKLE_KEY_ACCOUNT, or check with generate_keys -p)" >&2; exit 1; }
  sign_archive() { "$SPARKLE_BIN/sign_update" --account "$KEY_ACCOUNT" -p "$1"; }
else
  # Sparkle's private key format is the base64 of the 32-byte Ed25519 seed, which is CryptoKit's
  # rawRepresentation; the public key likewise. The private half stays in build/ (gitignored), 0600.
  mkdir -p "$OUT/key" && chmod 700 "$OUT/key"
  KEYS="$(xcrun swift - <<'SWIFT'
import CryptoKit
let key = Curve25519.Signing.PrivateKey()
print(key.rawRepresentation.base64EncodedString())
print(key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
)" || { echo "error: couldn't make a test key with xcrun swift" >&2; exit 1; }
  (umask 077 && sed -n 1p <<<"$KEYS" | tr -d '\n' > "$OUT/key/private.txt")
  PUBLIC_KEY="$(sed -n 2p <<<"$KEYS")"
  printf %s "$PUBLIC_KEY" > "$OUT/key/public.txt"
  sign_archive() { "$SPARKLE_BIN/sign_update" --ed-key-file "$OUT/key/private.txt" -p "$1"; }
fi
[[ "$PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] || { echo "error: public key '$PUBLIC_KEY' isn't a Sparkle EdDSA key" >&2; exit 1; }

plist() { /usr/libexec/PlistBuddy -c "Print $2" "$1/Contents/Info.plist" 2>/dev/null || true; }

# Signs like the release: everything Sparkle nests (its XPC services, Autoupdate, Updater.app) before
# the framework, then the app, each with the runtime. --deep would sign them with the app's settings,
# which Apple advises against. No timestamp: nothing here is notarized.
sign_app() {
  local app=$1 fw="$1/Contents/Frameworks/Sparkle.framework/Versions/B"
  if [[ -z "$SIGN_ID" ]]; then
    codesign -f -s - "$app"
    return
  fi
  local nested=()
  for x in "$fw"/XPCServices/*.xpc; do [[ -e "$x" ]] && nested+=("$x"); done
  nested+=("$fw/Autoupdate" "$fw/Updater.app" "$1/Contents/Frameworks/Sparkle.framework")
  for x in "${nested[@]}"; do
    [[ -e "$x" ]] || { echo "error: expected $x in the Sparkle framework (layout changed?)" >&2; exit 1; }
    codesign -f -s "$SIGN_ID" -o runtime --timestamp=none "$x"
  done
  codesign -f -s "$SIGN_ID" -o runtime --timestamp=none "$app"
}

# build <old|new> <marketing version> <build number>
build() {
  local dir=$OUT/$1 version=$2 number=$3
  echo "Building Slashplayed Companion $version ($number) into $dir"
  rm -rf "$DD/Build/Products"
  xcodebuild -project apps/companion/SPCompanion.xcodeproj -scheme SPCompanion -configuration Release \
    -derivedDataPath "$DD" -quiet \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$number" \
    SP_SPARKLE_FEED_URL="$FEED_URL" SP_SPARKLE_PUBLIC_KEY="$PUBLIC_KEY" \
    build
  mkdir -p "$dir"
  cp -R "$DD/Build/Products/Release/$APP_NAME" "$dir/"
  local app="$dir/$APP_NAME"
  sh apps/companion/bundle-resources.sh "$app"
  sign_app "$app"
  codesign --verify --deep --strict "$app"

  # Each of these would fail on the client side in a confusing way, so check them here.
  local got
  got="$(plist "$app" CFBundleShortVersionString) $(plist "$app" CFBundleVersion)"
  [[ "$got" == "$version $number" ]] || { echo "error: $app is '$got', expected '$version $number'" >&2; exit 1; }
  got="$(plist "$app" SUFeedURL)"
  [[ "$got" == "$FEED_URL" ]] || { echo "error: $app SUFeedURL is '$got', expected $FEED_URL (is it still \$(SP_SPARKLE_FEED_URL) in project.yml?)" >&2; exit 1; }
  got="$(plist "$app" SUPublicEDKey)"
  [[ "$got" == "$PUBLIC_KEY" ]] || { echo "error: $app SUPublicEDKey is '$got', expected $PUBLIC_KEY" >&2; exit 1; }
}

build old "$OLD_VERSION" "$OLD_BUILD"
build new "$NEW_VERSION" "$NEW_BUILD"

# ditto, not zip: it keeps the bundle's symlinks and extended attributes, which the signature covers.
ARCHIVE_NAME="Slashplayed-Companion-$NEW_VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$OUT/new/$APP_NAME" "$SERVE/$ARCHIVE_NAME"
ED_SIGNATURE="$(sign_archive "$SERVE/$ARCHIVE_NAME")"
[[ -n "$ED_SIGNATURE" ]] || { echo "error: sign_update produced no EdDSA signature" >&2; exit 1; }

MIN_OS="$(plist "$OUT/new/$APP_NAME" LSMinimumSystemVersion)"
LENGTH="$(stat -f %z "$SERVE/$ARCHIVE_NAME")"
cat > "$SERVE/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Slashplayed Companion (local update test)</title>
    <link>$FEED_URL</link>
    <description>Throwaway feed from scripts/release/update-test.sh.</description>
    <language>en</language>
    <item>
      <title>Version $NEW_VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$NEW_BUILD</sparkle:version>
      <sparkle:shortVersionString>$NEW_VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <description><![CDATA[<p>Local update test build $NEW_VERSION ($NEW_BUILD). Not a release.</p>]]></description>
      <enclosure url="http://127.0.0.1:$PORT/$ARCHIVE_NAME" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$ED_SIGNATURE"/>
    </item>
  </channel>
</rss>
XML
xmllint --noout "$SERVE/appcast.xml"

KEY_NOTE="a throwaway key (build/update-test/key/); only old/ trusts it"
[[ $REAL_KEY == 1 ]] && KEY_NOTE="the real Sparkle key ($KEY_ACCOUNT); an installed release or rc trusts it too"
cat <<STEPS

Update $NEW_VERSION ($NEW_BUILD) is served from $SERVE.
EdDSA key: $KEY_NOTE.
Code signature (both builds): ${SIGN_ID:-ad hoc, no hardened runtime}.

To test (quit any running companion first):

  open "$OUT/old/$APP_NAME"

  Help > About shows $OLD_VERSION. Choose "Check for Updates…" (or launch it with -check-for-updates):
  Sparkle offers $NEW_VERSION; install it, and the companion relaunches showing $NEW_VERSION.
  To see a scheduled check instead, backdate the last one before launching:

    defaults write $APP_ID SULastCheckTime -date "2001-01-01 00:00:00 +0000"

  An installed copy built with the real feed URL (e.g. an rc in /Applications, with --real-key) is
  pointed at this feed through its defaults, which Sparkle honours for testing:

    defaults write $APP_ID SUFeedURL "$FEED_URL"

Afterwards, undo the override (the updated copy has this feed built in; reinstall the release for the
real one):

    defaults delete $APP_ID SUFeedURL

Serving on http://127.0.0.1:$PORT/ -- Ctrl-C to stop.
STEPS

exec python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$SERVE"
