#!/bin/bash
# Downloads Goodmountain, the device app's start screen face (apps/client/spstart.m: "Choose a Game", the
# SLASHPLAYED line, and the game buttons) and the site's display face, and its license, from Hermann-S-Designs/Goodmountain at a pinned
# commit, each checked against its SHA-256. Never committed: the font's license (a custom end-user license,
# not OFL) allows shipping the file unchanged with its license, and forbids modifying or renaming it or
# uploading it to another platform, so the repo holds only this script and the app ships the OTF byte for
# byte (no subsetting).
#
#   scripts/fetch-font.sh
#
# Output, under work/fonts/ (gitignored): Goodmountain-Regular.otf, and LICENSE.md, which apps/client/build.sh
# and the companion's bundle-resources.sh ship in the device app as licenses/goodmountain.txt; and the
# designer's own webfont, Goodmountain-Regular.woff2, which release.yml's Pages deploy (and
# scripts/site-preview.sh) put next to site/index.html with LICENSE.md as goodmountain-license.txt.
# Once is enough: files already there with the right checksums aren't downloaded again.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO=Hermann-S-Designs/Goodmountain
COMMIT=173263b3514891042649d03755e41dab4f5185a1
OUT=work/fonts
# <path in the repo> <name in work/fonts/> <SHA-256>
FILES=(
  "Fonts/OTF/Goodmountain-Regular.otf Goodmountain-Regular.otf c9ce9fcbeb05646e110b6ccdaa0d96c493b0c3894a985f0aea4b8b9912359125"
  "Fonts/Webfont/Goodmountain-Regular.woff2 Goodmountain-Regular.woff2 a75531e739de84aed50d123a1a2e14ac273b2581de7fca54b1e024bb73e22f08"
  "LICENSE.md LICENSE.md 62e2a4a9be0f5c72b1d8b8c3372cd693e13a1603650e90c8029aaac0fabc60d4"
)

die() { echo "fetch-font: $*" >&2; exit 1; }
command -v curl >/dev/null || die "curl isn't installed"
# sha256sum where there is one (Linux, and Git Bash on Windows, which has no shasum: the companion-rs
# builds fetch the font there), else the Mac's shasum.
if command -v sha256sum >/dev/null; then
  sha() { sha256sum "$1" | cut -d' ' -f1; }
else
  sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
fi

mkdir -p "$OUT"
for entry in "${FILES[@]}"; do
  read -r path name want <<<"$entry"
  dest=$OUT/$name
  if [[ -f "$dest" && "$(sha "$dest")" == "$want" ]]; then
    continue
  fi
  tmp=$(mktemp "$OUT/.$name.XXXXXX")
  url=https://raw.githubusercontent.com/$REPO/$COMMIT/$path
  curl -fsSL --retry 3 -o "$tmp" "$url" || { rm -f "$tmp"; die "couldn't download $url"; }
  got=$(sha "$tmp")
  if [[ "$got" != "$want" ]]; then
    rm -f "$tmp"
    die "$path at $COMMIT has SHA-256 $got, expected $want (did the pin or the file change?)"
  fi
  chmod 0644 "$tmp"
  mv "$tmp" "$dest"
  echo "fetch-font: $dest ($(wc -c <"$dest" | tr -d ' ') bytes)" >&2
done
