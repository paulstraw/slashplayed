#!/bin/bash
# Builds idevice's C library (https://github.com/jkcoxson/idevice, MIT) from source at a pinned release,
# for the on-device JIT helper (apps/client/helper): the RemotePairing tunnel through LocalDevVPN,
# debugserver over RSD, mounting the developer disk image, and installing provisioning profiles. Never a prebuilt archive.
#
#   scripts/build-idevice.sh [ios|xros]...     (default: both)
#
# Output, all under work/idevice/ (gitignored, never committed):
#   src/                          the clone, checked out at the pinned commit
#   <platform>/libidevice_ffi.a   the static library, debug symbols stripped
#   <platform>/native-libs.txt    the system libraries it needs at link time (rustc's native-static-libs)
#   <platform>/licenses/          what ships with the archive's code: idevice.txt, the license texts of
#                                 idevice and every crate this platform's build links (scripts/crate-notices.py,
#                                 which fails on a crate with none), and rust-std.html, the Rust standard
#                                 library's notices from the pinned toolchain. bundle-resources.sh and
#                                 apps/client/build.sh ship them (the companion's Acknowledgements, the
#                                 device app's licenses/)
#   include/                      idevice.h (cbindgen's, from this build), plist.h, module.modulemap
#   BUILD.txt                     tag, commit, toolchain, features, and each archive's size and SHA-256
#
# Choices, and why:
# - Rust 1.99.0, pinned: idevice is edition 2024 (needs 1.85+), and 1.99 ships a prebuilt std for
#   aarch64-apple-visionos, so visionOS needs neither nightly -Zbuild-std nor retagging the iOS
#   archive's load commands as a platform it wasn't built for.
# - Only the features each use needs. The helper: tunnel_tcp_stack (RemotePairing tunnel, RSD, the
#   userspace TCP stack), debug_proxy (debugserver), cryptexd (the DDI cryptex install and its TSS
#   personalization), mobile_image_mounter (checking for an image mounted the pre-26.4 way) and
#   misagent (installing the app's renewed provisioning profiles, so the device keeps itself signed).
#   The companion: usbmuxd (the device and its lockdown pair record, held in memory, never logged) and
#   remote_pairing (pairing through remotepairingdeviced's lockdown service).
# - rustls with the pure-Rust rustcrypto provider, not the crate's default aws-lc: nothing on the
#   helper's path opens a TLS session (the RemotePairing tunnel encrypts on its own, RSD services skip
#   lockdown's TLS, and Apple's signing server is plain HTTP), but idevice only defines PairingFile, and
#   so won't compile, with a TLS backend enabled. The companion's lockdown session does use TLS.
#   rustcrypto means no C or assembly to cross-compile. SP_IDEVICE_TLS swaps it (ring, aws-lc) if it
#   ever fails to build.
# - Only the static library (cargo rustc --crate-type staticlib): the crate also lists cdylib and rlib,
#   which we'd have to link for each platform for nothing.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD

TAG=v0.1.68
COMMIT=d32c8189c51c2789496b0768039419c3705498c3
REPO=https://github.com/jkcoxson/idevice
TOOLCHAIN=1.99.0
TLS=${SP_IDEVICE_TLS:-rustcrypto}
DEVICE_FEATURES="tunnel_tcp_stack debug_proxy cryptexd mobile_image_mounter misagent $TLS"
MAC_FEATURES="usbmuxd remote_pairing $TLS"
OUT=$ROOT/work/idevice
PLATFORMS=${*:-ios xros macos}

die() { echo "build-idevice: $*" >&2; exit 1; }

# Toolchain.
command -v git >/dev/null || die "git isn't installed"
command -v rustup >/dev/null || die "rustup isn't installed (https://rustup.rs), or isn't on PATH (~/.cargo/bin)"
command -v xcrun >/dev/null || die "xcrun isn't available: install Xcode and select it (xcode-select -p)"
command -v python3 >/dev/null || die "python3 isn't installed (scripts/crate-notices.py writes the license texts)"
rustup toolchain list | grep -q "^$TOOLCHAIN-" || {
  echo "installing Rust $TOOLCHAIN" >&2
  rustup toolchain install "$TOOLCHAIN" --profile minimal || die "rustup couldn't install Rust $TOOLCHAIN"
}
# Each platform's Rust targets (macos is two, lipo'd into one archive).
targets() {
  case $1 in
    ios) echo aarch64-apple-ios ;;
    xros) echo aarch64-apple-visionos ;;
    macos) echo aarch64-apple-darwin x86_64-apple-darwin ;;
    *) die "unknown platform $1 (ios, xros, macos)" ;;
  esac
}
for p in $PLATFORMS; do
  for t in $(targets "$p"); do
    rustup "+$TOOLCHAIN" target list --installed | grep -qx "$t" || {
      echo "adding the $t target to Rust $TOOLCHAIN" >&2
      rustup "+$TOOLCHAIN" target add "$t" || die "rustup couldn't add $t to Rust $TOOLCHAIN"
    }
  done
done
echo "rust: $(rustup run "$TOOLCHAIN" rustc --version)" >&2

# Source, at exactly the pinned commit: a tag moved upstream is an error, not a silent update.
mkdir -p "$OUT"
if [ ! -d "$OUT/src/.git" ]; then
  git clone --quiet "$REPO" "$OUT/src" || die "couldn't clone $REPO"
fi
git -C "$OUT/src" fetch --quiet --tags origin || die "couldn't fetch tags from $REPO"
got=$(git -C "$OUT/src" rev-parse "$TAG^{commit}") || die "$REPO has no tag $TAG"
[ "$got" = "$COMMIT" ] || die "$TAG is $got upstream, not the pinned $COMMIT: check what changed before re-pinning"
git -C "$OUT/src" -c advice.detachedHead=false checkout --quiet --force "$COMMIT"
[ -z "$(git -C "$OUT/src" status --porcelain --untracked-files=no)" ] || die "$OUT/src has local changes"
[ -f "$OUT/src/ffi/plist.h" ] || die "ffi/plist.h is missing at $TAG (its build script would download it)"

# Build each platform. The deployment targets match scripts/platform.sh's SP_MINOS and the companion's
# (project.yml), so the archive's objects don't claim a newer OS than what links them.
# BUILD.txt keeps the lines of platforms this run doesn't rebuild.
# Panic messages carry source paths: map the ones on this machine (the cargo registry, the toolchain, the
# clone) to fixed names, so nothing built from this names anyone's home directory.
CARGO_DIR=${CARGO_HOME:-$HOME/.cargo}
SYSROOT=$(rustup run "$TOOLCHAIN" rustc --print sysroot)
export RUSTFLAGS="--remap-path-prefix=$CARGO_DIR/registry/src=/cargo --remap-path-prefix=$CARGO_DIR/git/checkouts=/cargo-git --remap-path-prefix=$SYSROOT=/rustc --remap-path-prefix=$OUT/src=/idevice"
rm -f "$OUT/BUILD.txt.tmp"
kept=""
if [ -f "$OUT/BUILD.txt" ]; then
  kept=$(grep -E '^(ios|xros|macos)[ :]' "$OUT/BUILD.txt" | grep -vE "^($(echo $PLATFORMS | tr ' ' '|'))[ :]" || true)
fi
rm -f "$OUT/BUILD.txt"
for p in $PLATFORMS; do
  case $p in
    ios) export IPHONEOS_DEPLOYMENT_TARGET=26.0; features=$DEVICE_FEATURES; ships="the Slashplayed app's JIT helper on iPadOS and iOS" ;;
    xros) export XROS_DEPLOYMENT_TARGET=27.0; features=$DEVICE_FEATURES; ships="the Slashplayed app's JIT helper on visionOS" ;;
    macos) export MACOSX_DEPLOYMENT_TARGET=15.0; features=$MAC_FEATURES; ships="Slashplayed Companion" ;;
  esac
  mkdir -p "$OUT/$p"
  libs=()
  for target in $(targets "$p"); do
    echo "building $target ($features)" >&2
    # rustc's native-static-libs note lists the system libraries and frameworks the archive needs at link
    # time; the linkers use exactly those. Touching the crate root makes rustc run (and print it) even
    # when nothing changed since the last build.
    touch "$OUT/src/ffi/src/lib.rs"
    (cd "$OUT/src/ffi" && CARGO_TARGET_DIR="$OUT/target" rustup run "$TOOLCHAIN" cargo rustc --locked --release \
      --lib --crate-type staticlib --target "$target" --no-default-features --features "$features" \
      -- --print native-static-libs) 2>&1 | tee "$OUT/$p/cargo-$target.log" ||
      die "cargo failed for $target (see above, or $OUT/$p/cargo-$target.log)"
    lib=$OUT/target/$target/release/libidevice_ffi.a
    [ -f "$lib" ] || die "cargo succeeded but $lib isn't there"
    sed -n 's/.*native-static-libs: //p' "$OUT/$p/cargo-$target.log" | tail -1 > "$OUT/$p/native-libs.txt"
    [ -s "$OUT/$p/native-libs.txt" ] || die "rustc didn't print native-static-libs for $target (see $OUT/$p/cargo-$target.log)"
    # The archive is rebuilt in place per feature set, so keep this platform's copy.
    cp "$lib" "$OUT/$p/libidevice_ffi-$target.a"
    libs+=("$OUT/$p/libidevice_ffi-$target.a")
  done
  if [ ${#libs[@]} -gt 1 ]; then
    xcrun lipo -create "${libs[@]}" -output "$OUT/$p/libidevice_ffi-unstripped.a" || die "lipo failed for $p"
  else
    cp "${libs[0]}" "$OUT/$p/libidevice_ffi-unstripped.a"
  fi
  rm -f "${libs[@]}"
  # -S: debug symbols only. The archive's other symbols are what the app links against.
  xcrun strip -S -o "$OUT/$p/libidevice_ffi.a" "$OUT/$p/libidevice_ffi-unstripped.a" || die "strip failed for $p"
  unstripped=$(stat -f %z "$OUT/$p/libidevice_ffi-unstripped.a")
  rm -f "$OUT/$p/libidevice_ffi-unstripped.a"
  size=$(stat -f %z "$OUT/$p/libidevice_ffi.a")
  sum=$(shasum -a 256 "$OUT/$p/libidevice_ffi.a" | cut -d' ' -f1)
  echo "$p ($features): libidevice_ffi.a $size bytes (unstripped $unstripped), sha256 $sum" >> "$OUT/BUILD.txt.tmp"
  # The license texts of what this archive holds, from the same crate, features, targets and toolchain.
  rm -rf "$OUT/$p/licenses" && mkdir -p "$OUT/$p/licenses"
  target_args=()
  for target in $(targets "$p"); do target_args+=(--target "$target"); done
  python3 -I "$ROOT/scripts/crate-notices.py" --toolchain "$TOOLCHAIN" --manifest-dir "$OUT/src/ffi" \
    --features "$features" "${target_args[@]}" --out "$OUT/$p/licenses/idevice.txt" \
    --title "idevice $TAG ($REPO, MIT) and the Rust crates it's built with, as $ships links them" ||
    die "couldn't write the license texts for $p (see above)"
  rust_notices=$SYSROOT/share/doc/rust/COPYRIGHT-library.html
  [ -s "$rust_notices" ] || die "Rust $TOOLCHAIN has no $rust_notices (the standard library's notices)"
  cp "$rust_notices" "$OUT/$p/licenses/rust-std.html"
done

# The header comes from this build: the crate's build script runs cbindgen and writes ffi/idevice.h.
[ -f "$OUT/src/ffi/idevice.h" ] || die "the build didn't write ffi/idevice.h"
mkdir -p "$OUT/include"
cp "$OUT/src/ffi/idevice.h" "$OUT/src/ffi/plist.h" "$OUT/include/"
cat > "$OUT/include/module.modulemap" <<EOF
module idevice {
  header "idevice.h"
  export *
}
EOF
{
  echo "idevice $TAG ($COMMIT) from $REPO"
  rustup run "$TOOLCHAIN" rustc --version
  [ -z "$kept" ] || echo "$kept"
  cat "$OUT/BUILD.txt.tmp"
} > "$OUT/BUILD.txt"
rm -f "$OUT/BUILD.txt.tmp"
cat "$OUT/BUILD.txt"
