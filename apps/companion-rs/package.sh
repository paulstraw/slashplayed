#!/bin/bash
# Packages a release build of the host tool's two programs for one target, with every notice its license
# terms ask for:
#
#   apps/companion-rs/package.sh <target triple> <out dir>
#
# after `cargo build --release --locked --target <triple>` here and scripts/fetch-font.sh (CI's companion-rs
# jobs, .github/workflows/). Writes <out dir>/slashplayed-companion-<os>-<arch>.zip (Windows) or .tar.gz
# (Linux, macOS), holding:
#   Slashplayed Companion.exe (Windows), slashplayed-companion (Linux, macOS)
#                             the window (cargo's slashplayed-companion: a cargo name can't hold a space)
#   slashplayed-cli[.exe]     the command line
#   Goodmountain-Regular.otf  the window's title face, byte for byte and under its own name: its license
#                             forbids changing or renaming it, so the window reads it from beside itself
#                             (src/gui/theme.rs) instead of compiling it in
#   README.txt                what they are and where their docs are
#   licenses/NOTICES.txt      every Rust crate either program links (scripts/crate-notices.py, which also
#                             fails on a GPL-family crate: the binaries are static)
#   licenses/rust-std.html    the Rust standard library's notices
#   licenses/zsign.txt, openssl.txt, zlib.txt   the C code spzsign compiles in: zsign (MIT), OpenSSL
#                             (Apache-2.0), and the zlib and minizip zsign carries (zlib license)
#   licenses/goodmountain.txt the font's license (its LICENSE.md)
#   licenses/slashplayed.txt  this repository's LICENSE
# Runs on Linux, macOS, and Windows (Git Bash; PYTHON names the Python where python3 isn't one).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
die() { echo "package: $*" >&2; exit 1; }
[ $# -eq 2 ] || die "usage: $0 <target triple> <out dir>"
TARGET=$1
mkdir -p "$2"
OUTDIR=$(cd "$2" && pwd)
CRATE=$ROOT/apps/companion-rs
TOOLCHAIN=$(sed -n 's/^channel = "\(.*\)"/\1/p' "$CRATE/rust-toolchain.toml")
[ -n "$TOOLCHAIN" ] || die "no channel in apps/companion-rs/rust-toolchain.toml"

case $TARGET in
  *windows*) os=windows; exe=.exe ;;
  *linux*) os=linux; exe= ;;
  *apple-darwin*) os=macos; exe= ;;
  *) die "unknown target $TARGET" ;;
esac
arch=${TARGET%%-*}
REL=$CRATE/target/$TARGET/release
for b in slashplayed-companion slashplayed-cli; do
  [ -f "$REL/$b$exe" ] || die "no $REL/$b$exe: build it first (cargo build --release --locked --target $TARGET)"
done
# The window's name: on Windows people see the file, so it's the app's name; elsewhere it's a command's.
if [ "$os" = windows ]; then window="Slashplayed Companion.exe"; else window=slashplayed-companion; fi
# On Linux, neither program may link a display library: winit, glutin, and the clipboard load X11, Wayland,
# xkbcommon, and GL at run time (Cargo.toml's eframe features), so slashplayed-cli runs on a headless box and
# the window starts with no -dev packages beyond glibc. A crate update that turns off a dlopen feature
# would put one in DT_NEEDED; this catches it before it ships.
if [ "$os" = linux ]; then
  for b in slashplayed-companion slashplayed-cli; do
    needed=$(readelf -d "$REL/$b" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
    [ -n "$needed" ] || die "readelf found no NEEDED entries in $b"
    bad=$(grep -E '^lib(X|xcb|xkb|wayland|decor|vulkan|gtk|gdk|GL|EGL|OpenGL|gbm|drm)' <<<"$needed" || true)
    [ -z "$bad" ] || die "$b links display libraries it should load at run time: $(echo $bad)"
  done
fi
FONT=$ROOT/work/fonts
for f in Goodmountain-Regular.otf LICENSE.md; do
  [ -s "$FONT/$f" ] || die "no work/fonts/$f (scripts/fetch-font.sh)"
done
ZSIGN=${SP_ZSIGN_SRC:-$ROOT/work/zsign/src/zsign}
[ -f "$ZSIGN/LICENSE" ] || die "no zsign source in $ZSIGN (scripts/build-zsign.sh source)"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
NAME=slashplayed-companion-$os-$arch
PKG=$STAGE/$NAME
mkdir -p "$PKG/licenses"
cp "$REL/slashplayed-companion$exe" "$PKG/$window"
cp "$REL/slashplayed-cli$exe" "$PKG/"
cp "$FONT/Goodmountain-Regular.otf" "$PKG/"
cp "$FONT/LICENSE.md" "$PKG/licenses/goodmountain.txt"

# cargo tree lists the package's dependencies, not one binary's, so this is the union of both programs'
# crates (slashplayed-cli links a subset of the window's).
"${PYTHON:-python3}" -I "$ROOT/scripts/crate-notices.py" --toolchain "$TOOLCHAIN" --manifest-dir "$CRATE" --features "" \
  --target "$TARGET" --own slashplayed-companion --own spzsign --deny-copyleft --out "$PKG/licenses/NOTICES.txt" \
  --title "Slashplayed Companion and slashplayed-cli, and the Rust crates they're built with, as the $TARGET build links them" ||
  die "couldn't write the crate notices (see above)"
SYSROOT=$(rustup run "$TOOLCHAIN" rustc --print sysroot)
[ -s "$SYSROOT/share/doc/rust/COPYRIGHT-library.html" ] || die "Rust $TOOLCHAIN has no COPYRIGHT-library.html"
cp "$SYSROOT/share/doc/rust/COPYRIGHT-library.html" "$PKG/licenses/rust-std.html"
cp "$ZSIGN/LICENSE" "$PKG/licenses/zsign.txt"
# OpenSSL's license, from the very openssl-src source spzsign (zsign/build.rs) compiled.
OPENSSL=$(cd "$CRATE" && rustup run "$TOOLCHAIN" cargo metadata --locked --format-version 1 | "${PYTHON:-python3}" -I -c '
import json, os, sys
m = json.load(sys.stdin)
p = [p for p in m["packages"] if p["name"] == "openssl-src"]
print(os.path.join(os.path.dirname(p[0]["manifest_path"]), "openssl", "LICENSE.txt") if p else "")')
[ -s "$OPENSSL" ] || die "no OpenSSL license in openssl-src's source ($OPENSSL)"
cp "$OPENSSL" "$PKG/licenses/openssl.txt"
# zlib's and minizip's terms are the comments at the top of their headers.
{
  echo "zlib and minizip, as zsign carries them (src/third-party), under the zlib license:"
  echo
  sed -n '/Copyright (C)/,/\*\//p' "$ZSIGN/src/third-party/zlib/zlib.h"
  echo
  sed -n '1,/^\*\//p' "$ZSIGN/src/third-party/minizip/zip.h"
} > "$PKG/licenses/zlib.txt"
grep -q "Jean-loup Gailly" "$PKG/licenses/zlib.txt" || die "couldn't find zlib's license in zlib.h"
cp "$ROOT/LICENSE" "$PKG/licenses/slashplayed.txt"
if [ "$os" = windows ]; then
  open_it='Double-click "Slashplayed Companion.exe". It isn'"'"'t signed, so Windows SmartScreen may
      say it'"'"'s from an unknown publisher: choose More info, then Run anyway.'
  cli='.\slashplayed-cli.exe --help   (in PowerShell, in this folder)'
else
  open_it='Run ./slashplayed-companion in a desktop session (X11 or
      Wayland, with OpenGL). It reaches the device through usbmuxd, which most distributions package.'
  cli='./slashplayed-cli --help'
fi
cat > "$PKG/README.txt" <<EOF
Slashplayed Companion $(sed -n 's/^version = "\(.*\)"/\1/p' "$CRATE/Cargo.toml" | head -1)

Sets up Slashplayed on an iPhone or iPad over USB, with no Mac: signs in to your Apple ID, makes the
signing profiles, signs and installs the app, and gets it ready to install games on the device itself.
Run it again to re-sign: within 7 days on a free Apple ID, within a year on a paid one.

Two programs here do the same job:

  $window
      The window. $open_it
      Keep Goodmountain-Regular.otf beside it: it's the window's title face.

  slashplayed-cli
      The same steps from a terminal, or on a computer with no display:
        $cli

Guide: https://github.com/paulstraw/slashplayed/blob/main/docs/setup-without-a-mac.md
Vision Pro still needs a Mac with the Slashplayed Companion.
Third-party notices are in licenses/.
EOF

rm -f "$OUTDIR/$NAME".zip "$OUTDIR/$NAME".tar.gz
if [ "$os" = windows ]; then
  # Git Bash has no zip. Windows' own tar.exe (bsdtar) writes one from the suffix, with forward slashes and
  # real folder entries; Windows PowerShell's Compress-Archive writes backslashes, which unzip and other
  # non-Windows tools take as part of a file's name. Its full path: Git Bash's tar is GNU tar, which can't.
  [ -n "${SYSTEMROOT:-}" ] || die "SYSTEMROOT isn't set, so tar.exe can't be found"
  bsdtar=$(cygpath -u "$SYSTEMROOT")/System32/tar.exe
  [ -x "$bsdtar" ] || die "no $bsdtar (Windows 10 1803 or later has it)"
  (cd "$STAGE" && "$bsdtar" -a -c -f "$NAME.zip" "$NAME") || die "tar.exe couldn't write $NAME.zip"
  # Check what it wrote, since a backslash name extracts as one flat file elsewhere: the raw names
  # (orig_filename; on Windows, zipfile's filename and libarchive's listing turn backslashes into slashes),
  # failing closed, so a zip Python can't read fails too.
  "${PYTHON:-python3}" -I -c 'import sys,zipfile; sys.exit(any("\\" in i.orig_filename for i in zipfile.ZipFile(sys.argv[1]).infolist()))' \
    "$STAGE/$NAME.zip" || die "$NAME.zip has a backslash in an entry name, or couldn't be read"
  mv "$STAGE/$NAME.zip" "$OUTDIR/"
  echo "$OUTDIR/$NAME.zip"
else
  tar -C "$STAGE" -czf "$OUTDIR/$NAME.tar.gz" "$NAME"
  echo "$OUTDIR/$NAME.tar.gz"
fi
