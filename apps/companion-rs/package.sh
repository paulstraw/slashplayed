#!/bin/bash
# Packages a release build of slashplayed-companion for one target, with every notice its license terms ask for:
#
#   apps/companion-rs/package.sh <target triple> <out dir>
#
# after `cargo build --release --locked --target <triple>` here (CI's companion-rs jobs, .github/workflows/). Writes
# <out dir>/slashplayed-companion-<os>-<arch>.zip (Windows) or .tar.gz (Linux, macOS), holding:
#   slashplayed-companion[.exe]   the tool
#   README.txt                what it is and where its docs are
#   licenses/NOTICES.txt      every Rust crate it links (scripts/crate-notices.py, which also fails on a
#                             GPL-family crate: the binary is static)
#   licenses/rust-std.html    the Rust standard library's notices
#   licenses/zsign.txt, openssl.txt, zlib.txt   the C code build.rs compiles in: zsign (MIT), OpenSSL
#                             (Apache-2.0), and the zlib and minizip zsign carries (zlib license)
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
BIN=$CRATE/target/$TARGET/release/slashplayed-companion$exe
[ -f "$BIN" ] || die "no $BIN: build it first (cargo build --release --locked --target $TARGET)"
ZSIGN=${SP_ZSIGN_SRC:-$ROOT/work/zsign/src/zsign}
[ -f "$ZSIGN/LICENSE" ] || die "no zsign source in $ZSIGN (scripts/build-zsign.sh source)"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
NAME=slashplayed-companion-$os-$arch
PKG=$STAGE/$NAME
mkdir -p "$PKG/licenses"
cp "$BIN" "$PKG/"

"${PYTHON:-python3}" -I "$ROOT/scripts/crate-notices.py" --toolchain "$TOOLCHAIN" --manifest-dir "$CRATE" --features "" \
  --target "$TARGET" --own slashplayed-companion --deny-copyleft --out "$PKG/licenses/NOTICES.txt" \
  --title "slashplayed-companion and the Rust crates it's built with, as the $TARGET build links them" ||
  die "couldn't write the crate notices (see above)"
SYSROOT=$(rustup run "$TOOLCHAIN" rustc --print sysroot)
[ -s "$SYSROOT/share/doc/rust/COPYRIGHT-library.html" ] || die "Rust $TOOLCHAIN has no COPYRIGHT-library.html"
cp "$SYSROOT/share/doc/rust/COPYRIGHT-library.html" "$PKG/licenses/rust-std.html"
cp "$ZSIGN/LICENSE" "$PKG/licenses/zsign.txt"
# OpenSSL's license, from the very openssl-src source build.rs compiled.
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
cat > "$PKG/README.txt" <<EOF
slashplayed-companion $(sed -n 's/^version = "\(.*\)"/\1/p' "$CRATE/Cargo.toml" | head -1)

Sets up Slashplayed on an iPhone or iPad over USB, with no Mac: signs in to your Apple ID, makes the
signing profiles, signs and installs the app, and gets it ready to install games on the device itself.
Run it again to re-sign: within 7 days on a free Apple ID, within a year on a paid one.

  slashplayed-companion --help

Guide: https://github.com/paulstraw/slashplayed/blob/main/docs/setup-without-a-mac.md
Vision Pro still needs a Mac with the Slashplayed Companion.
Third-party notices are in licenses/.
EOF

rm -f "$OUTDIR/$NAME".zip "$OUTDIR/$NAME".tar.gz
if [ "$os" = windows ]; then
  # Git Bash has no zip; PowerShell's Compress-Archive does.
  (cd "$STAGE" && powershell -NoProfile -Command "Compress-Archive -Path '$NAME' -DestinationPath '$NAME.zip'") ||
    die "Compress-Archive failed"
  mv "$STAGE/$NAME.zip" "$OUTDIR/"
  echo "$OUTDIR/$NAME.zip"
else
  tar -C "$STAGE" -czf "$OUTDIR/$NAME.tar.gz" "$NAME"
  echo "$OUTDIR/$NAME.tar.gz"
fi
