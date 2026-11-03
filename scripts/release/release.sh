#!/bin/bash
# Builds a Developer ID-signed, notarized release of Slashplayed Companion: the DMG users download, its
# Sparkle appcast item and checksums.
#
# Usage: scripts/release/release.sh [--unsigned]
#
# Environment:
#   RELEASE_TAG             Optional. When set (CI sets it to the pushed tag), it must equal
#                           v$SP_RELEASE_VERSION, which by default is project.yml's MARKETING_VERSION.
#   SP_RELEASE_VERSION      Optional. The version to stamp, for release candidates: MARKETING_VERSION
#                           itself or MARKETING_VERSION-<suffix> (e.g. 1.0.1-rc1). Release notes come from
#                           the CHANGELOG.md section of the version without the suffix.
#   SP_RELEASE_SIGN_ID      Optional. The codesign identity. Default: the one "Developer ID Application"
#                           identity in the keychain search list (CI imports exactly one); with several,
#                           set this. No team ID is written down here: it comes from the identity.
#   NOTARY_PROFILE          notarytool keychain profile (`xcrun notarytool store-credentials`). Local use.
#   ASC_API_KEY_PATH, ASC_API_KEY_ID, ASC_API_ISSUER_ID
#                           App Store Connect API key (.p8 path, key ID, issuer ID) for notarytool. CI;
#                           takes precedence over NOTARY_PROFILE.
#   SPARKLE_ED_PRIVATE_KEY  The Sparkle EdDSA private key (CI). When unset, sign_update reads it from the
#                           login keychain under SPARKLE_KEY_ACCOUNT.
#   SPARKLE_KEY_ACCOUNT     Keychain account of that key. Default: the companion's bundle ID, which the key
#                           was generated under (generate_keys --account com.strawdynamics.slashplayed.companion).
#   SP_CHANGELOG            Optional. Overrides CHANGELOG.md, so the notes extraction can be tried on a
#                           scratch file.
#
# Artifacts, all in build/release/:
#   Slashplayed-Companion-<version>.dmg   signed, notarized and stapled; the app plus an /Applications link
#   notes.md                              this version's CHANGELOG.md section (the GitHub release notes)
#   appcast-item.xml                      one Sparkle <item>; appcast-merge.sh prepends it to the live feed
#   slashplayed-device-kit.zip            the device app, unsigned, for slashplayed-companion (device-kit.sh)
#   SHA256SUMS                            for the DMG and the kit
#
# What it does, in order: checks the version, the changelog and (signed) every credential it will need,
# so nothing fails after a long build and a notarization round trip; builds the companion (Release) with
# CFBundleVersion an epoch stamp (Sparkle compares that) and SP_RELEASE_BUILD=YES (the project then
# refuses the placeholder Sparkle key); bundles its resources with bundle-resources.sh, which builds the
# shims and the launcher for both device platforms; signs it as update-test.sh proved works through a
# Sparkle update (Sparkle's helpers inside out, then the app, Developer ID, hardened runtime, plus a
# secure timestamp here); asserts no Blizzard bytes went in, and makes the device kit from the app's bundled
# resources (scripts/release/device-kit.sh), checked the same way; notarizes and staples the app (so a copy
# dragged out of the DMG carries its own ticket), then the DMG; signs the DMG for Sparkle.
#
# --unsigned skips Developer ID signing, notarization and the EdDSA signature (the app is sealed ad hoc
# without the runtime, as apps/companion/build.sh does, and the placeholder Sparkle key is allowed), but
# still makes every artifact, so the script can be smoke-tested with no certificate or Apple account.
# Its appcast item has no sparkle:edSignature, so no Sparkle client would accept it.
#
# sign_update is the copy in the Sparkle SPM artifact this very build resolves, so the signing tool is
# always the Sparkle version the app links. Nothing is installed and no device is touched.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$(pwd)

SIGNED=yes
for arg in "$@"; do
  case "$arg" in
    --unsigned) SIGNED=no ;;
    *) echo "usage: $(basename "$0") [--unsigned]" >&2; exit 2 ;;
  esac
done

OUT=$ROOT/build/release
DD=$OUT/DerivedData
STAGE=$OUT/dmg
APP_NAME="Slashplayed Companion.app"
APP_ID=com.strawdynamics.slashplayed.companion
PROJECT_YML=apps/companion/project.yml
FEED_URL=https://slashplayed.strawdynamics.com/appcast.xml
CHANGELOG="${SP_CHANGELOG:-CHANGELOG.md}"
SPARKLE_BIN=$DD/SourcePackages/artifacts/sparkle/Sparkle/bin

command -v xcodegen >/dev/null || { echo "error: xcodegen not found (brew install xcodegen)" >&2; exit 1; }

# --- Version -------------------------------------------------------------------------------------------
# project.yml is the one source of truth. The tag, the changelog and the bundle all have to agree with it,
# and it's far cheaper to find out they don't before the build and notarization.
MARKETING="$(awk -F'"' '/^ *MARKETING_VERSION:/ {print $2; exit}' "$PROJECT_YML")"
if [[ ! "$MARKETING" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: $PROJECT_YML MARKETING_VERSION is '$MARKETING', expected X.Y.Z" >&2
  exit 1
fi
VERSION="${SP_RELEASE_VERSION:-$MARKETING}"
if [[ "$VERSION" != "$MARKETING" && ! "$VERSION" =~ ^"$MARKETING"-[0-9A-Za-z.]+$ ]]; then
  echo "error: SP_RELEASE_VERSION '$VERSION' must be $MARKETING (project.yml MARKETING_VERSION) or" >&2
  echo "       $MARKETING-<suffix>, e.g. $MARKETING-rc1. Bump MARKETING_VERSION for a new version." >&2
  exit 1
fi
if [[ -n "${RELEASE_TAG:-}" && "$RELEASE_TAG" != "v$VERSION" ]]; then
  echo "error: tag $RELEASE_TAG does not match the version being built, $VERSION (expected v$VERSION)." >&2
  echo "       Bump MARKETING_VERSION in $PROJECT_YML or re-tag." >&2
  exit 1
fi

# --- Release notes -------------------------------------------------------------------------------------
# The section body, minus its heading, becomes the GitHub release notes and the appcast description. Keep a
# Changelog headings look like "## [1.0.1] - 2026-10-20". An rc takes its final version's section.
NOTES_VERSION="${VERSION%%-*}"
mkdir -p "$OUT"
if [[ ! -f "$CHANGELOG" ]]; then
  echo "error: $CHANGELOG not found; it needs a \"## [$NOTES_VERSION]\" section for this release" >&2
  exit 1
fi
HEADING="$(grep -m1 -F "## [$NOTES_VERSION]" "$CHANGELOG" || true)"
if [[ -z "$HEADING" ]]; then
  echo "error: $CHANGELOG has no \"## [$NOTES_VERSION]\" section. Add one before releasing." >&2
  exit 1
fi
# The date is a placeholder until someone sets it at tag time. A final signed release must not ship it;
# an rc or a smoke test can.
if [[ "$HEADING" == *X* ]]; then
  if [[ "$SIGNED" == yes && "$VERSION" == "$MARKETING" ]]; then
    echo "error: $CHANGELOG's heading '$HEADING' still has a placeholder date; set the release date." >&2
    exit 1
  fi
  echo "warning: $CHANGELOG's heading '$HEADING' still has a placeholder date" >&2
fi
awk -v heading="## [$NOTES_VERSION]" '
  index($0, heading) == 1 { found = 1; next }
  found && /^## / { exit }
  found { print }
' "$CHANGELOG" \
  | sed -e '/./,$!d' \
  | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}' > "$OUT/notes.md"
if [[ ! -s "$OUT/notes.md" ]]; then
  echo "error: the \"## [$NOTES_VERSION]\" section of $CHANGELOG is empty" >&2
  exit 1
fi
echo "Release notes: build/release/notes.md ($(wc -l < "$OUT/notes.md" | tr -d ' ') lines)"

# --- Credentials (signed only) -------------------------------------------------------------------------
# Everything signing, notarization and Sparkle need is checked now, not after the build.
if [[ "$SIGNED" == yes ]]; then
  SIGN_ID="${SP_RELEASE_SIGN_ID:-}"
  if [[ -z "$SIGN_ID" ]]; then
    ids="$(security find-identity -v -p codesigning | sed -nE 's/^ *[0-9]+\) [0-9A-F]{40} "(Developer ID Application: .*)"$/\1/p' | sort -u)"
    case "$(grep -c . <<<"$ids" || true)" in
      0) echo "error: no valid \"Developer ID Application\" identity in the keychain search list" >&2
         echo "       (security find-identity -v -p codesigning), or pass --unsigned." >&2
         exit 1 ;;
      1) SIGN_ID="$ids" ;;
      *) echo "error: several Developer ID Application identities; set SP_RELEASE_SIGN_ID to one of:" >&2
         sed 's/^/         /' <<<"$ids" >&2
         exit 1 ;;
    esac
  fi
  if ! security find-identity -v -p codesigning | grep -qF "\"$SIGN_ID\""; then
    echo "error: SP_RELEASE_SIGN_ID '$SIGN_ID' isn't a valid codesigning identity in the keychain" >&2
    exit 1
  fi
  TEAM_ID="$(sed -nE 's/.*\(([A-Z0-9]{10})\)$/\1/p' <<<"$SIGN_ID")"
  [[ -n "$TEAM_ID" ]] || { echo "error: can't read a team ID from the identity '$SIGN_ID'" >&2; exit 1; }
  echo "Signing as: $SIGN_ID"

  if [[ -n "${ASC_API_KEY_PATH:-}" ]]; then
    if [[ ! -f "$ASC_API_KEY_PATH" || -z "${ASC_API_KEY_ID:-}" || -z "${ASC_API_ISSUER_ID:-}" ]]; then
      echo "error: ASC_API_KEY_PATH needs an existing .p8 file plus ASC_API_KEY_ID and ASC_API_ISSUER_ID" >&2
      echo "       (got path '$ASC_API_KEY_PATH')." >&2
      exit 1
    fi
    NOTARY_AUTH=(--key "$ASC_API_KEY_PATH" --key-id "$ASC_API_KEY_ID" --issuer "$ASC_API_ISSUER_ID")
  elif [[ -n "${NOTARY_PROFILE:-}" ]]; then
    NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
  else
    echo "error: no notarization credentials. Set NOTARY_PROFILE to a profile saved with" >&2
    echo "       \`xcrun notarytool store-credentials\`, or ASC_API_KEY_PATH, ASC_API_KEY_ID and" >&2
    echo "       ASC_API_ISSUER_ID (or pass --unsigned)." >&2
    exit 1
  fi
  # A bad profile or key is otherwise only found out after the build.
  xcrun notarytool history "${NOTARY_AUTH[@]}" --output-format json >/dev/null \
    || { echo "error: notarytool can't authenticate with these credentials (notarytool history failed)" >&2; exit 1; }

  KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-$APP_ID}"
fi

# --- Build ---------------------------------------------------------------------------------------------
# Clear everything a previous run left, so nothing stale can be uploaded with this run's output.
rm -rf "$STAGE" "$OUT/notarize" "$OUT"/Slashplayed-Companion-*.dmg "$OUT/appcast-item.xml" "$OUT/SHA256SUMS" \
  "$OUT/slashplayed-device-kit.zip" "$OUT/device-kit"
BUILD="$(date +%s)"
echo "Building Slashplayed Companion $VERSION ($BUILD), $([[ "$SIGNED" == yes ]] && echo "Developer ID" || echo "unsigned")"

(cd apps/companion && ./idevice-config.sh && xcodegen generate --quiet)
xcodebuild -project apps/companion/SPCompanion.xcodeproj -scheme SPCompanion \
  -derivedDataPath "$DD" -quiet -resolvePackageDependencies
[[ -x "$SPARKLE_BIN/sign_update" && -x "$SPARKLE_BIN/generate_keys" ]] || {
  echo "error: sign_update/generate_keys not found in $SPARKLE_BIN. The Sparkle SPM artifact layout may" >&2
  echo "       have changed; look under $DD/SourcePackages/artifacts." >&2
  exit 1
}

if [[ "$SIGNED" == yes ]]; then
  # The private key that will sign the DMG must be the half of the SUPublicEDKey the app ships with, or
  # every installed copy rejects the update. Its public half is derived here and compared after the build.
  if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
    SPARKLE_KEY_ARGS=(--ed-key-file -)
    # Sparkle's private key is the base64 of the 32-byte Ed25519 seed, CryptoKit's rawRepresentation
    # (/usr/bin/openssl is LibreSSL without Ed25519). The key goes in on stdin so it never appears in a
    # process list, so the Swift source can't: it's a file (a `swift -` heredoc would take stdin from the
    # pipe, and the script would read an empty key).
    # swift runs a file only with the .swift extension, hence a directory rather than a mktemp file.
    DERIVE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sp-release-derive.XXXXXX")"
    DERIVE_SWIFT="$DERIVE_DIR/derive.swift"
    cat > "$DERIVE_SWIFT" <<'SWIFT'
import CryptoKit
import Foundation
let text = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)!
guard let seed = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else { exit(1) }
print(key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
    SIGNING_PUBLIC_KEY="$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | xcrun swift "$DERIVE_SWIFT" 2>/dev/null || true)"
    rm -rf "$DERIVE_DIR"
    [[ -n "$SIGNING_PUBLIC_KEY" ]] || { echo "error: SPARKLE_ED_PRIVATE_KEY isn't a Sparkle EdDSA private key (base64 of a 32-byte seed)" >&2; exit 1; }
  else
    SPARKLE_KEY_ARGS=(--account "$KEY_ACCOUNT")
    SIGNING_PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" --account "$KEY_ACCOUNT" -p 2>/dev/null || true)"
    [[ -n "$SIGNING_PUBLIC_KEY" ]] || {
      echo "error: no Sparkle key in the login keychain for account $KEY_ACCOUNT (set SPARKLE_ED_PRIVATE_KEY" >&2
      echo "       or SPARKLE_KEY_ACCOUNT; check with generate_keys --account $KEY_ACCOUNT -p)" >&2
      exit 1
    }
  fi
  RELEASE_BUILD=YES
else
  RELEASE_BUILD=NO
fi

rm -rf "$DD/Build/Products"
xcodebuild -project apps/companion/SPCompanion.xcodeproj -scheme SPCompanion -configuration Release \
  -derivedDataPath "$DD" -quiet \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" SP_RELEASE_BUILD="$RELEASE_BUILD" \
  build
mkdir -p "$STAGE"
cp -R "$DD/Build/Products/Release/$APP_NAME" "$STAGE/"
APP="$STAGE/$APP_NAME"
sh apps/companion/bundle-resources.sh "$APP"

# Each of these would fail on users' Macs in a confusing way (or never update), so check the bundle.
plist() { /usr/libexec/PlistBuddy -c "Print $1" "$APP/Contents/Info.plist" 2>/dev/null || true; }
got="$(plist CFBundleShortVersionString) $(plist CFBundleVersion)"
[[ "$got" == "$VERSION $BUILD" ]] || { echo "error: the built app is '$got', expected '$VERSION $BUILD'" >&2; exit 1; }
got="$(plist SUFeedURL)"
[[ "$got" == "$FEED_URL" ]] || { echo "error: the built app's SUFeedURL is '$got', expected $FEED_URL" >&2; exit 1; }
APP_PUBLIC_KEY="$(plist SUPublicEDKey)"
[[ "$APP_PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] || { echo "error: the built app's SUPublicEDKey '$APP_PUBLIC_KEY' isn't a Sparkle EdDSA key" >&2; exit 1; }
if [[ "$SIGNED" == yes && "$APP_PUBLIC_KEY" != "$SIGNING_PUBLIC_KEY" ]]; then
  echo "error: the app's SUPublicEDKey ($APP_PUBLIC_KEY, from $PROJECT_YML SP_SPARKLE_PUBLIC_KEY) isn't the" >&2
  echo "       public half of the key that would sign this update ($SIGNING_PUBLIC_KEY)." >&2
  exit 1
fi
MIN_OS="$(plist LSMinimumSystemVersion)"
[[ "$MIN_OS" == 15.0 ]] || { echo "error: the built app's LSMinimumSystemVersion is '$MIN_OS', expected 15.0 (the appcast says so)" >&2; exit 1; }

# --- Sign ----------------------------------------------------------------------------------------------
# Everything Sparkle nests (its XPC services, Autoupdate, Updater.app) before the framework, then the app,
# each with the hardened runtime and a secure timestamp (notarization needs both). --deep would sign them
# with the app's settings, which Apple advises against. Same order as update-test.sh's sign_app.
if [[ "$SIGNED" == yes ]]; then
  fw="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  nested=()
  for x in "$fw"/XPCServices/*.xpc; do [[ -e "$x" ]] && nested+=("$x"); done
  nested+=("$fw/Autoupdate" "$fw/Updater.app" "$APP/Contents/Frameworks/Sparkle.framework")
  for x in "${nested[@]}"; do
    [[ -e "$x" ]] || { echo "error: expected $x in the Sparkle framework (layout changed?)" >&2; exit 1; }
    codesign -f -s "$SIGN_ID" -o runtime --timestamp "$x"
  done
  # The bundled shims and launcher are device code the companion re-signs with the user's identity at
  # build time; as resources they're only sealed by the app's signature, which is what notarization needs.
  codesign -f -s "$SIGN_ID" -o runtime --timestamp "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
  # Notarization rejects any executable without the runtime, and says so only after a round trip. The
  # output is captured first: piped straight into grep -q, codesign can die of SIGPIPE once grep has its
  # match, and pipefail then reports a correctly signed app as unsigned.
  for x in "$APP" "${nested[@]}"; do
    info="$(codesign -dv "$x" 2>&1)"
    [[ "$info" == *flags=*runtime* ]] || { echo "error: $x is signed without the hardened runtime" >&2; exit 1; }
  done
else
  # Ad hoc, no runtime: library validation would refuse Sparkle.framework without a Team ID (build.sh).
  codesign -f -s - "$APP"
fi

# --- No Blizzard bytes ---------------------------------------------------------------------------------
# Nothing from the game may ship. Every Mach-O in what's about to be packaged is compared, by LC_UUID and by
# size, against every client this Mac has: the thinned ones in work/, every Mach-O the companion keeps
# under Application Support (the assembled images in client-*, and cdn/'s slices, named by hash rather than
# wow-*), and the installed clients themselves (thinning and the load-command rewrite keep the UUID). Our own
# Mach-Os there are left out, since they're what ships: the launcher, the shims, the JIT helper, and the
# signing stubs' build products. So is certificate/, whose keychain isn't opened even for its magic number.
# Anything else there counts, so a new cache can't slip past. On a machine
# with none (CI), that half finds nothing to compare and says so; the size and name rules still hold:
# besides the companion's own executable, no file over 20 MB, and nothing named like a client image,
# game storage or a metallib.
REF_UUIDS="$OUT/ref-uuids.txt"
REF_SIZES="$OUT/ref-sizes.txt"
is_macho() {
  case "$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')" in
    cffaedfe|cefaedfe|feedfacf|feedface|cafebabe|bebafeca) return 0 ;;
    *) return 1 ;;
  esac
}
: > "$REF_UUIDS"; : > "$REF_SIZES"
refs=0
# A missing place is skipped (a CI runner has no Application Support/Slashplayed), but a find that fails
# on one that exists stops the release loudly: this group runs in a pipeline subshell under set -e, where a
# bare failing find would end the script with no message, or a half-read list would weaken the check.
ref_dir_files() {
  local dir=$1; shift
  [[ -d "$dir" ]] || return 0
  find "$dir" -type f "$@" || { echo "error: couldn't list $dir for the no-Blizzard-bytes check" >&2; exit 1; }
}
{
  ref_dir_files work \( -name 'wow-*' -o -name 'World of Warcraft*' \) -not -name '*.*'
  ref_dir_files "$HOME/Library/Application Support/Slashplayed" \
    -not -path '*.app/slashplayed' -not -path '*.app/Frameworks/*' -not -path '*.app/PlugIns/*' \
    -not -path '*/DerivedData/*' -not -path '*/Slashplayed/certificate/*'
  for f in "${SP_INSTALL:-/Applications/World of Warcraft}"/_*_/World\ of\ Warcraft*.app/Contents/MacOS/*; do
    [[ -f "$f" ]] && echo "$f"
  done
  true
} | while IFS= read -r f; do
  is_macho "$f" || continue
  xcrun dwarfdump --uuid "$f" 2>/dev/null | awk '/^UUID:/ {print $2}' >> "$REF_UUIDS"
  stat -f %z "$f" >> "$REF_SIZES"
done
refs=$(sort -u "$REF_SIZES" | grep -c . || true)
check_no_blizzard_bytes() {
  local dir=$1 bad=0 f size uuid rel
  while IFS= read -r -d '' f; do
    rel="${f#"$dir"/}"
    size=$(stat -f %z "$f")
    case "$(basename "$f")" in
      wow-*|*.metallib|.build.info|data.[0-9][0-9][0-9]|*.idx)
        echo "error: $rel is named like a game file" >&2; bad=1 ;;
    esac
    if (( size > 20 * 1024 * 1024 )) && [[ "$rel" != "$APP_NAME/Contents/MacOS/Slashplayed Companion" ]]; then
      echo "error: $rel is $((size / 1024 / 1024)) MB; nothing but the companion's executable may exceed 20 MB" >&2; bad=1
    fi
    is_macho "$f" || continue
    if grep -qx "$size" "$REF_SIZES"; then
      echo "error: $rel is a Mach-O the size of a game client on this Mac ($size bytes)" >&2; bad=1
    fi
    for uuid in $(xcrun dwarfdump --uuid "$f" 2>/dev/null | awk '/^UUID:/ {print $2}'); do
      if grep -qx "$uuid" "$REF_UUIDS"; then
        echo "error: $rel has the UUID of a game client on this Mac ($uuid)" >&2; bad=1
      fi
    done
  done < <(find "$dir" -type f -print0)
  (( bad == 0 )) || { echo "error: $dir holds Blizzard-derived files; refusing to package" >&2; exit 1; }
}
check_no_blizzard_bytes "$STAGE"
# The device kit slashplayed-companion installs (apps/companion-rs): the app's own bundled resources, assembled into the
# unsigned device app. Unpacked and checked like the app before it ships.
scripts/release/device-kit.sh "$APP/Contents/Resources" "$OUT/slashplayed-device-kit.zip"
mkdir -p "$OUT/device-kit" && (cd "$OUT/device-kit" && unzip -q "$OUT/slashplayed-device-kit.zip")
check_no_blizzard_bytes "$OUT/device-kit"
rm -rf "$OUT/device-kit"
if (( refs == 0 )); then
  echo "No game clients on this machine to compare against; checked sizes and names only."
else
  echo "No Blizzard bytes: compared every Mach-O with $refs game client image(s) on this Mac."
fi

# notarytool exits 0 for some rejected submissions, so trust only the status it reports, and print Apple's
# log on failure: it names the offending binary.
notarize() {
  local file="$1" result id status
  echo "Notarizing $(basename "$file")…"
  result="$(xcrun notarytool submit "$file" "${NOTARY_AUTH[@]}" --wait --output-format json)" || true
  id="$(plutil -extract id raw -o - - <<< "$result" 2>/dev/null || true)"
  status="$(plutil -extract status raw -o - - <<< "$result" 2>/dev/null || true)"
  if [[ "$status" != Accepted ]]; then
    echo "error: notarization of $file ended with status '${status:-unknown}':" >&2
    echo "$result" >&2
    [[ -n "$id" ]] && xcrun notarytool log "$id" "${NOTARY_AUTH[@]}" >&2 || true
    return 1
  fi
  echo "Notarized $(basename "$file") (submission $id)"
}

# The app first, through a ditto zip (it keeps the bundle's symlinks the signature covers), so the copy a
# user drags to /Applications has a stapled ticket and opens offline.
if [[ "$SIGNED" == yes ]]; then
  mkdir -p "$OUT/notarize"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/notarize/app.zip"
  notarize "$OUT/notarize/app.zip"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  rm -rf "$OUT/notarize"
fi

# --- DMG -----------------------------------------------------------------------------------------------
DMG_NAME="Slashplayed-Companion-$VERSION.dmg"
DMG="$OUT/$DMG_NAME"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Slashplayed Companion" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

# Mount it read-only and look: the app is there, its signature holds, and the image holds no more than
# was checked above.
MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/sp-release-dmg.XXXXXX")"
hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" "$DMG" >/dev/null
detach() { hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || hdiutil detach "$MOUNT" -force -quiet || true; rmdir "$MOUNT" 2>/dev/null || true; }
trap detach EXIT
[[ -d "$MOUNT/$APP_NAME" && -L "$MOUNT/Applications" ]] || { echo "error: $DMG_NAME doesn't hold $APP_NAME and the Applications link" >&2; exit 1; }
codesign --verify --deep --strict "$MOUNT/$APP_NAME"
check_no_blizzard_bytes "$MOUNT"
detach
trap - EXIT
echo "Mounted and checked $DMG_NAME"

if [[ "$SIGNED" == yes ]]; then
  # The DMG gets its own signature and ticket so the first thing Gatekeeper sees on download checks out.
  # Stapling rewrites the file, so the Sparkle signature comes after it.
  codesign -s "$SIGN_ID" --timestamp "$DMG"
  codesign --verify --strict --verbose=2 "$DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  ED_SIGNATURE="$(
    if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then printf '%s\n' "$SPARKLE_ED_PRIVATE_KEY"; fi \
      | "$SPARKLE_BIN/sign_update" "${SPARKLE_KEY_ARGS[@]}" -p "$DMG"
  )"
  [[ -n "$ED_SIGNATURE" ]] || { echo "error: sign_update produced no EdDSA signature for $DMG" >&2; exit 1; }
fi

# --- Appcast item --------------------------------------------------------------------------------------
# The description is notes.md as HTML; Sparkle shows it in the update prompt. Only the Markdown CHANGELOG.md
# uses is handled (headings, "-"/"*" bullets with indented continuation lines, paragraphs, `code`, **bold**,
# *italics*, [links](url)), in macOS's stock perl, so neither a runner nor a contributor needs a Markdown
# package. Text is escaped before markup is added, which also means no "]]>" can end the CDATA early.
render_notes_html() {
  perl -e '
    use strict; use warnings;
    sub esc { my $s = shift; $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; $s }
    sub inline {
      my @parts = split /`/, shift, -1;
      for my $i (0 .. $#parts) {
        if ($i % 2) { $parts[$i] = "<code>" . esc($parts[$i]) . "</code>"; next }
        my $t = esc($parts[$i]);
        $t =~ s{\[([^\]]+)\]\(([^)\s]+)\)}{<a href="$2">$1</a>}g;
        $t =~ s{\*\*(.+?)\*\*}{<strong>$1</strong>}g;
        $t =~ s{(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])}{<em>$1</em>}g;
        $parts[$i] = $t;
      }
      join "", @parts;
    }
    my (@out, @para, @items, $in_list);
    sub flush {
      push @out, "<p>" . inline(join " ", @para) . "</p>" if @para;
      push @out, "<ul>\n" . join("", map { "<li>" . inline($_) . "</li>\n" } @items) . "</ul>" if @items;
      @para = (); @items = (); $in_list = 0;
    }
    while (my $line = <>) {
      chomp $line;
      if ($line =~ /^\s*$/) { flush(); next }
      if ($line =~ /^(#{1,6})\s+(.*?)\s*$/) {
        flush(); my $n = length $1; push @out, "<h$n>" . inline($2) . "</h$n>"; next;
      }
      if ($line =~ /^[-*]\s+(.*)$/) {
        push @out, "<p>" . inline(join " ", @para) . "</p>" if @para; @para = ();
        push @items, $1; $in_list = 1; next;
      }
      if ($in_list && $line =~ /^\s+(\S.*)$/) { $items[-1] .= " $1"; next }
      flush() if $in_list;
      (my $text = $line) =~ s/^\s+//;
      push @para, $text;
    }
    flush();
    print join("\n", @out), "\n";
  ' "$1"
}

# One <item>. It isn't a standalone document (the sparkle: prefix is declared on the feed's <rss>);
# appcast-merge.sh prepends it to the live appcast.xml and validates the result. sparkle:version is
# CFBundleVersion, the epoch stamp: it's what Sparkle compares.
if [[ "$SIGNED" == yes ]]; then
  signature_attr=" sparkle:edSignature=\"$ED_SIGNATURE\""
  unsigned_note=""
else
  signature_attr=""
  unsigned_note=$'\n      <!-- Unsigned smoke-test build: no sparkle:edSignature, so Sparkle would reject this item. -->'
fi
{
  cat <<ITEM
    <item>
      <title>Version $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <description><![CDATA[
ITEM
  render_notes_html "$OUT/notes.md"
  cat <<ITEM
      ]]></description>$unsigned_note
      <enclosure url="https://github.com/paulstraw/slashplayed/releases/download/v$VERSION/$DMG_NAME" length="$(stat -f %z "$DMG")" type="application/octet-stream"$signature_attr/>
    </item>
ITEM
} > "$OUT/appcast-item.xml"

(cd "$OUT" && shasum -a 256 "$DMG_NAME" slashplayed-device-kit.zip > SHA256SUMS)
rm -f "$REF_UUIDS" "$REF_SIZES"

echo
if [[ "$SIGNED" == yes ]]; then
  echo "Release $VERSION ($BUILD) is notarized, stapled and Sparkle-signed."
else
  echo "Unsigned release $VERSION ($BUILD): Developer ID signing, notarization and Sparkle skipped."
fi
echo "Artifacts in build/release:"
for f in "$DMG_NAME" slashplayed-device-kit.zip notes.md appcast-item.xml SHA256SUMS; do echo "  $f"; done
