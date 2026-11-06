#!/bin/bash
# Builds spapple (apps/client/spapple: Apple's developer services for the launcher, through the vendored
# isideload) as a static library for the device app:
#
#   scripts/build-spapple.sh [ios|xros]...     (default: both)
#
# Output, all under work/spapple/ (gitignored, never committed):
#   <platform>/libspapple.a       the static library (built with no debug info)
#   <platform>/native-libs.txt    the system libraries it needs at link time (rustc's native-static-libs)
#   <platform>/licenses/          spapple.txt, the license texts of every crate this platform's build links
#                                 (scripts/crate-notices.py, which fails on a crate with none or a GPL-family
#                                 one), and rust-std.html, the Rust standard library's notices
#   BUILD.txt                     toolchain, and each archive's size and SHA-256
#
# Rust 1.99.0, the toolchain scripts/build-idevice.sh pins, for the same reason: a prebuilt std for
# aarch64-apple-visionos. --locked: apps/client/spapple/Cargo.lock is committed. The launcher links only this
# Rust archive (the helper links idevice's), so the two never put two copies of Rust's std in one binary.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD

TOOLCHAIN=1.99.0
CRATE=$ROOT/apps/client/spapple
OUT=$ROOT/work/spapple
PLATFORMS=${*:-ios xros}
FEATURES=""  # the crate's own; isideload's are set in its Cargo.toml

die() { echo "build-spapple: $*" >&2; exit 1; }

command -v rustup >/dev/null || die "rustup isn't installed (https://rustup.rs), or isn't on PATH (~/.cargo/bin)"
command -v xcrun >/dev/null || die "xcrun isn't available: install Xcode and select it (xcode-select -p)"
command -v python3 >/dev/null || die "python3 isn't installed (scripts/crate-notices.py writes the license texts)"
rustup toolchain list | grep -q "^$TOOLCHAIN-" || {
  echo "installing Rust $TOOLCHAIN" >&2
  rustup toolchain install "$TOOLCHAIN" --profile minimal || die "rustup couldn't install Rust $TOOLCHAIN"
}
target_of() {
  case $1 in
    ios) echo aarch64-apple-ios ;;
    xros) echo aarch64-apple-visionos ;;
    *) die "unknown platform $1 (ios, xros)" ;;
  esac
}
for p in $PLATFORMS; do
  t=$(target_of "$p")
  rustup "+$TOOLCHAIN" target list --installed | grep -qx "$t" || {
    echo "adding the $t target to Rust $TOOLCHAIN" >&2
    rustup "+$TOOLCHAIN" target add "$t" || die "rustup couldn't add $t to Rust $TOOLCHAIN"
  }
done

# Panic messages carry source paths: map the ones on this machine to fixed names, so nothing built from
# this names anyone's home directory.
CARGO_DIR=${CARGO_HOME:-$HOME/.cargo}
SYSROOT=$(rustup run "$TOOLCHAIN" rustc --print sysroot)
export RUSTFLAGS="--remap-path-prefix=$CARGO_DIR/registry/src=/cargo --remap-path-prefix=$CARGO_DIR/git/checkouts=/cargo-git --remap-path-prefix=$SYSROOT=/rustc --remap-path-prefix=$ROOT=/slashplayed"
mkdir -p "$OUT"
kept=""
if [ -f "$OUT/BUILD.txt" ]; then
  kept=$(grep -E '^(ios|xros):' "$OUT/BUILD.txt" | grep -vE "^($(echo $PLATFORMS | tr ' ' '|')):" || true)
fi
lines=""
for p in $PLATFORMS; do
  target=$(target_of "$p")
  case $p in
    ios) export IPHONEOS_DEPLOYMENT_TARGET=26.0 ;;
    xros) export XROS_DEPLOYMENT_TARGET=27.0 ;;
  esac
  mkdir -p "$OUT/$p"
  echo "building spapple for $target" >&2
  # Touching the crate root makes rustc run (and print native-static-libs) even when nothing changed.
  touch "$CRATE/src/lib.rs"
  (cd "$CRATE" && CARGO_TARGET_DIR="$OUT/target" rustup run "$TOOLCHAIN" cargo rustc --locked --release \
    --lib --target "$target" -- --print native-static-libs) 2>&1 | tee "$OUT/$p/cargo.log" ||
    die "cargo failed for $target (see above, or $OUT/$p/cargo.log)"
  lib=$OUT/target/$target/release/libspapple.a
  [ -f "$lib" ] || die "cargo succeeded but $lib isn't there"
  sed -n 's/.*native-static-libs: //p' "$OUT/$p/cargo.log" | tail -1 > "$OUT/$p/native-libs.txt"
  [ -s "$OUT/$p/native-libs.txt" ] || die "rustc didn't print native-static-libs for $target (see $OUT/$p/cargo.log)"
  # Copied as cargo made it, not through strip -S as idevice's is: the crate builds with no debug info
  # (Cargo.toml), and strip -S on this archive turned local copies of shared generics into private externs,
  # which the launcher's link then refused as ~200 duplicate symbols.
  cp "$lib" "$OUT/$p/libspapple.a"
  size=$(stat -f %z "$OUT/$p/libspapple.a")
  sum=$(shasum -a 256 "$OUT/$p/libspapple.a" | cut -d' ' -f1)
  lines="$lines$p: libspapple.a $size bytes, sha256 $sum
"
  rm -rf "$OUT/$p/licenses" && mkdir -p "$OUT/$p/licenses"
  python3 -I "$ROOT/scripts/crate-notices.py" --toolchain "$TOOLCHAIN" --manifest-dir "$CRATE" \
    --features "$FEATURES" --target "$target" --own spapple --deny-copyleft --out "$OUT/$p/licenses/spapple.txt" \
    --title "spapple (Slashplayed's, MIT) and the Rust crates it's built with, isideload among them, as the Slashplayed app links them" ||
    die "couldn't write the license texts for $p (see above)"
  rust_notices=$SYSROOT/share/doc/rust/COPYRIGHT-library.html
  [ -s "$rust_notices" ] || die "Rust $TOOLCHAIN has no $rust_notices (the standard library's notices)"
  cp "$rust_notices" "$OUT/$p/licenses/rust-std.html"
done
{
  rustup run "$TOOLCHAIN" rustc --version
  [ -z "$kept" ] || echo "$kept"
  printf %s "$lines"
} > "$OUT/BUILD.txt"
cat "$OUT/BUILD.txt"
