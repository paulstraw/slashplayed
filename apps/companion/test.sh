#!/bin/sh
# Runs the companion's unit tests (apps/companion/Tests; needs xcodegen). Extra arguments go to
# xcodebuild, e.g. -only-testing:SPCompanionTests/ClientAssemblyTests.
set -e
cd "$(dirname "$0")"
OUT=$(cd ../.. && pwd)/build/companion-tests
./idevice-config.sh
# The launcher's signer (spsign.m) is tested on the Mac, linked with zsign and OpenSSL built for it.
[ -f ../../work/zsign/macos/libzsign.a ] && [ -f ../../work/zsign/macos/openssl/lib/libcrypto.a ] ||
  { echo "test.sh: no work/zsign/macos/libzsign.a or its libcrypto.a (run scripts/build-zsign.sh macos)" >&2; exit 1; }
xcodegen generate --quiet
# No test diagnostics: by default xcodebuild spends ~8 s after the last test collecting a system log
# archive into the result bundle (235 MB against 1.7 MB without), even when every test passed. A
# caller after one for a failure can still ask: a later -collect-test-diagnostics in "$@" wins.
xcodebuild -project SPCompanion.xcodeproj -scheme SPCompanion -derivedDataPath "$OUT" -quiet test \
  -collect-test-diagnostics never -resultBundlePath "$OUT/ci-debug.xcresult" "$@" || rc=$?
xcrun xcresulttool get test-results tests --path "$OUT/ci-debug.xcresult" > "$OUT/ci-debug.json"
python3 -c '
import json,sys
cases=[]
def walk(n,s=None):
    if n.get("nodeType")=="Test Suite": s=n["name"]
    if n.get("nodeType")=="Test Case": cases.append((n.get("durationInSeconds",0),s+"/"+n["name"]))
    for c in n.get("children",[]): walk(c,s)
for n in json.load(open(sys.argv[1]))["testNodes"]: walk(n)
print("DEBUG sum", round(sum(c[0] for c in cases),1))
for d,n in sorted(cases,reverse=True)[:25]: print("DEBUG %6.2f %s"%(d,n))
' "$OUT/ci-debug.json"
exit ${rc:-0}
