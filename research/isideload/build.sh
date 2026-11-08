#!/bin/bash
# Builds the isideload spike (README.md) into work/isideload/:
#   spisideload   the CLI (Cargo.toml, src/), with the repo's pinned Rust and the committed Cargo.lock
#   zsign         zsign's command-line signer, from the source scripts/build-zsign.sh pinned and patched,
#                 linked to the OpenSSL v1.4.0's scripts/build-zsign.sh built for macos: what
#                 sign-install.sh signs the app with (slashplayed-companion compiles the same zsign in)
#
#   research/isideload/build.sh
#
# Needs work/zsign/src/zsign and work/zsign/macos/openssl first: `scripts/build-zsign.sh macos` from a
# v1.4.0 checkout (the mode went when the launcher stopped signing on the device; `git worktree add
# <dir> v1.4.0`, run it there, and copy its work/zsign/macos here), and rustup (the toolchain is installed
# if missing, as scripts/build-idevice.sh does). Installs nothing on a device.
#
# The CLI's Keychain item trusts the binary that wrote it (src/store.rs): rebuilding after a login makes
# macOS ask once before the new binary may read it. Build, then log in.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
OUT=$ROOT/work/isideload
TOOLCHAIN=1.99.0
ZSRC=$ROOT/work/zsign/src/zsign
OPENSSL=$ROOT/work/zsign/macos/openssl
die() { echo "isideload/build.sh: $*" >&2; exit 1; }

command -v rustup >/dev/null || die "rustup isn't installed (https://rustup.rs), or isn't on PATH (~/.cargo/bin)"
rustup toolchain list | grep -q "^$TOOLCHAIN-" || rustup toolchain install "$TOOLCHAIN" --profile minimal ||
  die "rustup couldn't install Rust $TOOLCHAIN"
[ -f "$ZSRC/src/zsign.cpp" ] && [ -f "$OPENSSL/lib/libcrypto.a" ] ||
  die "no zsign source or macOS OpenSSL in work/zsign (scripts/build-zsign.sh macos from a v1.4.0 checkout; see the header)"
mkdir -p "$OUT/zsign-obj"

# zsign's CLI: its macOS Makefile's sources (all of src/, zlib, minizip), compiled straight from the pinned
# tree, so the patched copy build-zsign.sh made is the one built. Release flags as its Makefile; no
# pkg-config, the OpenSSL is ours.
echo "building zsign" >&2
objs=()
for c in "$ZSRC"/src/third-party/zlib/*.c "$ZSRC"/src/third-party/minizip/{ioapi,zip,unzip}.c; do
  o="$OUT/zsign-obj/$(basename "$(dirname "$c")")-$(basename "$c" .c).o"
  xcrun clang -O2 -w -I"$ZSRC/src/third-party/zlib" -c "$c" -o "$o"
  objs+=("$o")
done
xcrun clang++ -std=c++11 -O2 -w -DZSIGN_VERSION=spike -I"$ZSRC/src" -I"$ZSRC/src/common" \
  -I"$ZSRC/src/third-party/zlib" -I"$OPENSSL/include" "$ZSRC"/src/*.cpp "$ZSRC"/src/common/*.cpp \
  "${objs[@]}" "$OPENSSL/lib/libcrypto.a" -o "$OUT/zsign"

echo "building spisideload (Rust $TOOLCHAIN)" >&2
CARGO_TARGET_DIR="$OUT/target" rustup run "$TOOLCHAIN" cargo build --locked --release
cp "$OUT/target/release/spisideload" "$OUT/spisideload"
# Signed with your Apple Development identity when SP_SIGN_ID is set (environment or config/local.env), with
# a fixed identifier: the Keychain item's ACL then trusts "this identifier, this certificate", which a
# rebuild keeps, instead of the one ad hoc build that wrote it.
. "$ROOT/scripts/config.sh"
if [ -n "${SP_SIGN_ID:-}" ]; then
  codesign -f -s "$SP_SIGN_ID" -i com.strawdynamics.slashplayed.spike.spisideload "$OUT/spisideload" 2>/dev/null ||
    die "codesign couldn't sign spisideload with SP_SIGN_ID"
else
  echo "SP_SIGN_ID unset: spisideload stays ad hoc, so each rebuild asks before reading its Keychain item" >&2
fi
echo "built $OUT/spisideload and $OUT/zsign" >&2
