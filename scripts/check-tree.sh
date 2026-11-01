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

# check <title> <git grep flags and pattern...>: prints the hits (minus allowed ones) and records a failure.
check() {
  local title=$1; shift
  local hits
  hits=$(git grep -nI "$@" -- . ":!$SELF" | grep -vE 'ABCDE12345' || true)
  if [[ -n "$hits" ]]; then
    echo "error: $title:" >&2
    sed 's/^/  /' <<<"$hits" >&2
    failed=1
  fi
}

# --- Scrub line ---------------------------------------------------------------------------------------
check "offsets into the client (the scrub line keeps client internals general)" \
  -E 'wow\+0x|\+0x[0-9a-f]{5,}'
check "client-internal or dropped-research wording (generalize, or link docs/ instead)" \
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
hits=$(git ls-files | grep -E '(^|/)local\.env$|\.(p12|p8|cer|mobileprovision|provisionprofile)$' || true)
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

if (( failed )); then
  exit 1
fi
echo "check-tree: scrub and no-hardcoding checks passed ($(git ls-files | wc -l | tr -d ' ') tracked files)"
