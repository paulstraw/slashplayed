#!/bin/bash
# The source of slashplayed-companion's app signer: zsign (https://github.com/zhlynn/zsign, MIT) at a
# pinned commit with our patch (scripts/zsign.patch), into work/zsign/src/zsign (gitignored, never
# committed). Nothing is built here: apps/companion-rs/build.rs compiles it, on Windows, Linux, and macOS,
# with OpenSSL from openssl-src (Cargo.toml pins it), so this needs only git.
#
#   scripts/build-zsign.sh source
#
# zsign.patch: (1) no entitlements blob in a non-executable's signature, which iOS refuses (the shim
# dylibs in the app's Frameworks/; research/dlopentest/README.md, "Signing on the device"); (2)
# ZSignAsset::InitData, so the key, certificate, and profiles come from memory and are never written to a
# file; (3) no terminal colors in its messages.
#
# Until the launcher loaded the game's unchanged client with spguest, this also built zsign and OpenSSL for
# the device (the launcher signed game updates there) and for the Mac (the companion's tests): v1.4.0's
# scripts/build-zsign.sh has those modes, which research/dlopentest and research/isideload still use.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD

ZSIGN_REPO=https://github.com/zhlynn/zsign
ZSIGN_COMMIT=9299685bab7ef99827e06e5dfda93af747386590
PATCH=$ROOT/scripts/zsign.patch
OUT=$ROOT/work/zsign

die() { echo "build-zsign: $*" >&2; exit 1; }
[ "$*" = source ] || die "usage: $0 source (the device and Mac builds went with on-device signing; v1.4.0's script has them)"
command -v git >/dev/null || die "git isn't installed"

# Source at exactly the pinned commit: a moved tag is an error, not a silent update.
mkdir -p "$OUT/src"
if [ ! -d "$OUT/src/zsign/.git" ]; then
  git clone --quiet "$ZSIGN_REPO" "$OUT/src/zsign" || die "couldn't clone $ZSIGN_REPO"
fi
git -C "$OUT/src/zsign" cat-file -e "$ZSIGN_COMMIT^{commit}" 2>/dev/null ||
  git -C "$OUT/src/zsign" fetch --quiet origin || die "couldn't fetch $ZSIGN_REPO"
git -C "$OUT/src/zsign" -c advice.detachedHead=false checkout --quiet --force "$ZSIGN_COMMIT" ||
  die "$ZSIGN_REPO has no commit $ZSIGN_COMMIT"
git -C "$OUT/src/zsign" apply "$PATCH" || die "zsign.patch doesn't apply at $ZSIGN_COMMIT"
echo "zsign $ZSIGN_COMMIT, patched, in ${OUT#"$ROOT"/}/src/zsign" >&2
