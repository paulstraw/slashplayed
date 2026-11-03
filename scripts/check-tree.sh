#!/bin/bash
# Checks the tracked tree for what must never be published: CI runs it on every PR and push, and it's
# cheap enough to run before any commit.
#   scripts/check-tree.sh
# Two families of check, each a grep over `git ls-files` (so work/ and build/ never count):
#   - The scrub line (CLAUDE.md, docs/architecture.md): no offsets into the client, no word or path
#     that points at the dropped research notes or the client's startup-code internals.
#   - No hardcoding: no device UDIDs, team IDs, signing identity hashes or home-directory paths, and no
#     signing material or config/local.env tracked by mistake. The owner's real values can't be listed
#     here (this file is public too), so these are shapes, not values; the test fixtures' placeholder
#     team, ABCDE12345, is the one allowed match.
# Exits 1 with every hit listed, so one run shows everything to fix. Patterns are POSIX ERE as git grep
# takes them on macOS (no \b: the boundary classes below stand in for it).
set -euo pipefail
cd "$(dirname "$0")/.."

# This file necessarily spells out every pattern it looks for.
SELF=scripts/check-tree.sh
B='(^|[^0-9A-Za-z])'
E='([^0-9A-Za-z]|$)'
failed=0

# check [--skip <pathspec>] <title> <git grep flags and pattern...>: prints the hits (minus allowed ones)
# and records a failure. --skip leaves a path out of that one check.
check() {
  local skip=":!$SELF"
  if [[ $1 == --skip ]]; then skip=$2; shift 2; fi
  local title=$1; shift
  local hits
  hits=$(git grep -nI "$@" -- . ":!$SELF" "$skip" | grep -vE 'ABCDE12345' || true)
  if [[ -n "$hits" ]]; then
    echo "error: $title:" >&2
    sed 's/^/  /' <<<"$hits" >&2
    failed=1
  fi
}

# --- Scrub line ---------------------------------------------------------------------------------------
check "offsets into the client (the scrub line keeps client internals general)" \
  -E 'wow\+0x|\+0x[0-9a-f]{5,}'
# Not the vendored isideload (apps/companion-rs/vendor), third-party code whose AES-CBC decryptor is Apple's
# sign-in, nothing of the client's.
check --skip ':!apps/companion-rs/vendor' "client-internal or dropped-research wording (generalize, or link docs/ instead)" \
  -iE 'decryptor|notes/|research-00|recon-001'

# --- No hardcoding -------------------------------------------------------------------------------------
check "a device UDID (devices come from devicectl or SP_DEVICE in config/local.env)" \
  -E "${B}[0-9A-F]{8}-[0-9A-F]{16}${E}"
# Uppercase only: codesign and security print identity hashes that way, while the workflows' action
# pins are lowercase commit SHAs.
check "a signing identity hash (SP_SIGN_ID belongs in config/local.env)" \
  -E "${B}[0-9A-F]{40}${E}"
check "a team ID (teams come from Xcode's accounts or SP_TEAM in config/local.env)" \
  -E "${B}[A-Z0-9]{10}\.slashplayed|DEVELOPMENT_TEAM[:=] *\"?[A-Z0-9]{10}${E}|SP_TEAM=\"?[A-Z0-9]{10}${E}|(Developer ID Application|Apple Development|Apple Distribution): [^\"]*\([A-Z0-9]{10}\)"
# /Users/Shared is a fixed system path (Battle.net's agent lives there), not anyone's home.
hits=$(git grep -nIE '/Users/[A-Za-z]' -- . ":!$SELF" | grep -v '/Users/Shared' || true)
if [[ -n "$hits" ]]; then
  echo "error: a home-directory path (use \$HOME, ~ or a path relative to the repo):" >&2
  sed 's/^/  /' <<<"$hits" >&2
  failed=1
fi
# Apple's public root and WWDR G3 CA certificates in the vendored isideload (it pins Apple's root for the
# sign-in) are the one exception: public certificates, no key.
hits=$(git ls-files | grep -E '(^|/)local\.env$|\.(p12|p8|cer|mobileprovision|provisionprofile)$' |
  grep -vxE 'apps/companion-rs/vendor/isideload/src/assets/(apple_root|AppleWWDRCAG3)\.cer' || true)
if [[ -n "$hits" ]]; then
  echo "error: signing material or local config is tracked (git rm --cached it; .gitignore covers local.env):" >&2
  sed 's/^/  /' <<<"$hits" >&2
  failed=1
fi

# The start screen's face (scripts/fetch-font.sh) may be shipped only unmodified with its license and never
# uploaded elsewhere, which a commit to a public repo would be; no font file is ours to commit either.
hits=$(git ls-files | grep -iE '\.(otf|ttf|ttc|woff2?)$' || true)
if [[ -n "$hits" ]]; then
  echo "error: a font file is tracked (scripts/fetch-font.sh downloads Goodmountain into work/fonts/ instead):" >&2
  sed 's/^/  /' <<<"$hits" >&2
  failed=1
fi

# The site makes no requests off its own origin (no font services, CDNs, scripts, or trackers): anything it
# loads (a stylesheet, script, font, image, or frame, or a preconnect) is a file next to it. Links out, in
# <a href>, are fine.
hits=$(git grep -nIiE '<(link|script|img|source|iframe|video|audio|embed|object)[^>]*(href|src|srcset|data)="?(https?:)?//|url\(["'"'"']?(https?:)?//|@import' -- site/index.html || true)
if [[ -n "$hits" ]]; then
  echo "error: site/index.html loads something from another site (serve it from site/, or link to it with <a>):" >&2
  sed 's/^/  /' <<<"$hits" >&2
  failed=1
fi

# --- Pins that must agree ------------------------------------------------------------------------------
# The host tool (apps/companion-rs) links idevice through Cargo, the rest of the repo through build-idevice.sh:
# one vetted commit for both. Its version is the release's (MARKETING_VERSION), since a release carries it
# and the device kit it installs under one tag.
idevice_pin=$(sed -n 's/^COMMIT=\([0-9a-f]*\)$/\1/p' scripts/build-idevice.sh)
setup_pin=$(sed -n 's/^idevice = { git = .*rev = "\([0-9a-f]*\)" }$/\1/p' apps/companion-rs/Cargo.toml)
if [[ -z "$idevice_pin" || "$idevice_pin" != "$setup_pin" ]]; then
  echo "error: apps/companion-rs/Cargo.toml's idevice rev ($setup_pin) isn't scripts/build-idevice.sh's COMMIT ($idevice_pin)" >&2
  failed=1
fi
marketing=$(awk -F'"' '/^ *MARKETING_VERSION:/ {print $2; exit}' apps/companion/project.yml)
setup_version=$(sed -n 's/^version = "\(.*\)"$/\1/p' apps/companion-rs/Cargo.toml | head -1)
if [[ "$marketing" != "$setup_version" ]]; then
  echo "error: apps/companion-rs/Cargo.toml's version ($setup_version) isn't MARKETING_VERSION ($marketing)" >&2
  failed=1
fi
# The vendored isideload keeps its LGPL signer optional (apps/companion-rs/vendor/isideload/VENDORED.md).
if ! grep -qx 'apple-codesign-quick = { version = "0.1.0", optional = true }' apps/companion-rs/vendor/isideload/Cargo.toml; then
  echo "error: apps/companion-rs/vendor/isideload/Cargo.toml no longer makes apple-codesign-quick optional" >&2
  failed=1
fi

if (( failed )); then
  exit 1
fi
echo "check-tree: scrub and no-hardcoding checks passed ($(git ls-files | wc -l | tr -d ' ') tracked files)"
