#!/bin/bash
# Renders the host tool's icons from art/icon.svg, the app icon's source, and writes them here, committed:
#   slashplayed.ico   the Windows executables' icon (build.rs puts it in their resources), 16 to 256 px
#   slashplayed.png   the window's icon on every system (src/gui, include_bytes), 256 px
# Run it after art/icon.svg changes. Needs rsvg-convert (librsvg) and ImageMagick's magick.
set -euo pipefail
cd "$(dirname "$0")"
die() { echo "make-icons: $*" >&2; exit 1; }
command -v rsvg-convert >/dev/null || die "rsvg-convert isn't installed (librsvg)"
command -v magick >/dev/null || die "magick isn't installed (ImageMagick)"
SVG=../../../art/icon.svg
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
sizes=(16 24 32 48 64 128 256)
for s in "${sizes[@]}"; do
  rsvg-convert -w "$s" -h "$s" "$SVG" -o "$TMP/$s.png"
done
pngs=()
for s in "${sizes[@]}"; do pngs+=("$TMP/$s.png"); done
# Smallest first; magick stores the 256 px entry as PNG, the rest as bitmaps.
magick "${pngs[@]}" "$TMP/slashplayed.ico"
cp "$TMP/slashplayed.ico" slashplayed.ico
cp "$TMP/256.png" slashplayed.png
echo "make-icons: slashplayed.ico ($(wc -c <slashplayed.ico | tr -d ' ') bytes), slashplayed.png" >&2
