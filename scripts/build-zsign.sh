#!/bin/bash
# Builds the launcher's on-device signer (apps/client/spsign.m, spzsign.cpp): zsign
# (https://github.com/zhlynn/zsign, MIT) at a pinned commit with our patch (scripts/zsign.patch), and the
# OpenSSL it needs (Apache-2.0), from source at a pinned release. Never a prebuilt archive.
#
#   scripts/build-zsign.sh [ios|xros|macos]...     (default: all three)
#   scripts/build-zsign.sh source                  zsign's patched source only, nothing built
#
# source is the host tool's (apps/companion-rs/build.rs compiles zsign itself, on Windows and Linux too, so this
# needs only git: no xcrun, no perl, no OpenSSL clone).
# ios and xros are the launcher's (apps/client/build-launcher.sh links them); macos is the companion's unit
# tests' (they sign a fixture of our own with spsign.m on the Mac), arm64 only, like the test run.
#
# Output, all under work/zsign/ (gitignored, never committed):
#   src/zsign/, src/openssl/       the clones, at the pinned commits (zsign with zsign.patch applied)
#   <platform>/libzsign.a          zsign's single-image signer (no zip, bundle, metadata, or OCSP code)
#   <platform>/openssl/            libcrypto.a and its headers (make install_dev)
#   licenses/zsign.txt, openssl.txt  the two licenses, from the pinned sources: build.sh and the companion's
#                                  bundle-resources.sh ship them in the device app (licenses/)
#   BUILD.txt                      the pins, and each archive's size and SHA-256
#
# Choices, and why:
# - OpenSSL 3.5, the long-term-support series. Only libcrypto is linked. no-module builds the providers into
#   libcrypto, so the legacy provider (RC2-40, which a .p12 exported from Keychain Access uses, and which
#   zsign loads before PKCS12_parse) is there with no module file to load from the app.
# - zsign's sources for signing one Mach-O only: archo, macho, signing, openssl, and common/ (json, sha, fs,
#   log, util). zsign.patch: (1) no entitlements blob in a non-executable's signature, which iOS refuses
#   (research/dlopentest/README.md, "Signing on the device"); (2) ZSignAsset::InitData, so the key,
#   certificate, and profile come from memory and are never written to a file; (3) no terminal colors in
#   its messages: in the launcher's log the codes were stray bytes that made grep take the log for binary.
# - The deployment targets match scripts/platform.sh's SP_MINOS, and macos the companion's deployment target.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD

ZSIGN_REPO=https://github.com/zhlynn/zsign
ZSIGN_COMMIT=9299685bab7ef99827e06e5dfda93af747386590
OPENSSL_REPO=https://github.com/openssl/openssl
OPENSSL_TAG=openssl-3.5.9
OPENSSL_COMMIT=45e844fa2a14ec92d146bd8f5778ac130b6625fb
PATCH=$ROOT/scripts/zsign.patch
OUT=$ROOT/work/zsign
PLATFORMS=${*:-ios xros macos}

die() { echo "build-zsign: $*" >&2; exit 1; }
command -v git >/dev/null || die "git isn't installed"
if [ "$PLATFORMS" != source ]; then
  command -v xcrun >/dev/null || die "xcrun isn't available: install Xcode and select it (xcode-select -p)"
  command -v perl >/dev/null || die "perl isn't installed (OpenSSL's Configure needs it)"
fi

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
if [ "$PLATFORMS" = source ]; then
  echo "zsign $ZSIGN_COMMIT, patched, in ${OUT#"$ROOT"/}/src/zsign" >&2
  exit 0
fi

if [ ! -d "$OUT/src/openssl/.git" ]; then
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$OPENSSL_TAG" "$OPENSSL_REPO" "$OUT/src/openssl" ||
    die "couldn't clone $OPENSSL_REPO at $OPENSSL_TAG"
fi
got=$(git -C "$OUT/src/openssl" rev-parse HEAD)
[ "$got" = "$OPENSSL_COMMIT" ] || die "$OPENSSL_TAG is $got here, not the pinned $OPENSSL_COMMIT: check what changed before re-pinning"
[ -z "$(git -C "$OUT/src/openssl" status --porcelain --untracked-files=no)" ] || die "$OUT/src/openssl has local changes"

ZSRC=$OUT/src/zsign/src
ZSIGN_SRCS="archo.cpp macho.cpp signing.cpp openssl.cpp common/json.cpp common/sha.cpp common/fs.cpp common/log.cpp common/util.cpp"
rm -f "$OUT/BUILD.txt.tmp"
kept=""
if [ -f "$OUT/BUILD.txt" ]; then
  kept=$(grep -E '^(ios|xros|macos):' "$OUT/BUILD.txt" | grep -vE "^($(echo "$PLATFORMS" | tr ' ' '|')):" || true)
fi
for p in $PLATFORMS; do
  case $p in
    ios) sdk=iphoneos; target=arm64-apple-ios26.0 ;;
    xros) sdk=xros; target=arm64-apple-xros27.0 ;;
    macos) sdk=macosx; target=arm64-apple-macos15.0 ;;
    *) die "unknown platform $p (ios, xros, macos)" ;;
  esac
  cc="xcrun --sdk $sdk clang -target $target"
  cxx="xcrun --sdk $sdk clang++ -target $target"
  dest=$OUT/$p
  rm -rf "$dest" "$OUT/build-$p"
  mkdir -p "$dest" "$OUT/build-$p"

  # OpenSSL, out of tree. darwin64-arm64-cc is the generic arm64 Darwin target; the compiler's -target picks
  # the platform. The prefix and OPENSSLDIR name nothing on the device (no config file, engine, or module is
  # read), and libcrypto keeps them as strings, so they're a fixed path, not this Mac's: the companion
  # refuses to bundle anything holding the repo's path (bundle-resources.sh). make install_dev stages
  # under DESTDIR, and the staged prefix becomes $dest/openssl.
  echo "building OpenSSL $OPENSSL_TAG for $p" >&2
  (cd "$OUT/build-$p" && CC="$cc" "$OUT/src/openssl/Configure" darwin64-arm64-cc \
    no-shared no-module no-tests no-apps no-docs no-ui-console no-engine no-dso no-async \
    --prefix=/nonexistent/spzsign --openssldir=/nonexistent/spzsign >"$OUT/build-$p/configure.log" 2>&1) ||
    die "OpenSSL's Configure failed for $p (see $OUT/build-$p/configure.log)"
  (cd "$OUT/build-$p" && make -j"$(sysctl -n hw.ncpu)" build_libs >"$OUT/build-$p/make.log" 2>&1 &&
    make install_dev DESTDIR="$OUT/build-$p/stage" >>"$OUT/build-$p/make.log" 2>&1) ||
    die "OpenSSL's build failed for $p (see $OUT/build-$p/make.log)"
  mv "$OUT/build-$p/stage/nonexistent/spzsign" "$dest/openssl"
  rm -f "$dest/openssl/lib/libssl.a"
  rm -rf "$dest/openssl/lib/pkgconfig" "$dest/openssl/lib/cmake"

  # zsign. Its sources mostly assume a command-line tool; these files are the signer alone.
  echo "building zsign for $p" >&2
  objs=()
  for f in $ZSIGN_SRCS; do
    o=$OUT/build-$p/zsign-$(echo "$f" | tr / -).o
    # shellcheck disable=SC2086 # cxx is a command with arguments
    # The file prefix map keeps this Mac's path out of __FILE__ (zsign's asserts use it).
    $cxx -std=c++11 -O2 -w -ffile-prefix-map="$ROOT/"= -I"$ZSRC" -I"$ZSRC/common" -I"$dest/openssl/include" \
      -c "$ZSRC/$f" -o "$o" ||
      die "zsign's $f didn't compile for $p"
    objs+=("$o")
  done
  xcrun --sdk "$sdk" libtool -static -o "$dest/libzsign.a" "${objs[@]}" 2>/dev/null || die "libtool failed for $p"
  for a in libzsign.a openssl/lib/libcrypto.a; do
    ! strings -a "$dest/$a" | grep -qF "$ROOT" || die "$p's $a holds this Mac's path $ROOT"
    echo "$p: $a $(stat -f %z "$dest/$a") bytes, sha256 $(shasum -a 256 "$dest/$a" | cut -d' ' -f1)" >> "$OUT/BUILD.txt.tmp"
  done
done
# The notices the device app ships for what it links.
mkdir -p "$OUT/licenses"
cp "$OUT/src/zsign/LICENSE" "$OUT/licenses/zsign.txt"
cp "$OUT/src/openssl/LICENSE.txt" "$OUT/licenses/openssl.txt"
{
  echo "zsign $ZSIGN_COMMIT from $ZSIGN_REPO, with scripts/zsign.patch (sha256 $(shasum -a 256 "$PATCH" | cut -d' ' -f1))"
  echo "OpenSSL $OPENSSL_TAG ($OPENSSL_COMMIT) from $OPENSSL_REPO"
  [ -z "$kept" ] || echo "$kept"
  cat "$OUT/BUILD.txt.tmp"
} > "$OUT/BUILD.txt"
rm -f "$OUT/BUILD.txt.tmp"
cat "$OUT/BUILD.txt"
