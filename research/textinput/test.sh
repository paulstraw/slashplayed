#!/bin/bash
# Build and replay the UIKit input harness on an iOS simulator, never a physical device.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
[ $# -eq 1 ] || { echo "usage: $0 <iOS simulator UDID>" >&2; exit 1; }
SIM=$1
OUT=$ROOT/build/textinput
mkdir -p "$OUT"
xcodegen generate --spec research/textinput/project.yml --quiet
xcodebuild -project research/textinput/TextInputHarness.xcodeproj -scheme TextInputHarness \
  -configuration Debug -destination "id=$SIM" -derivedDataPath "$OUT/DerivedData" -quiet build >"$OUT/build.log" 2>&1 ||
  { cat "$OUT/build.log" >&2; exit 1; }
xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl bootstatus "$SIM" -b >"$OUT/boot.log"
xcrun simctl install "$SIM" "$OUT/DerivedData/Build/Products/Debug-iphonesimulator/TextInputHarness.app"
CONTAINER=$(xcrun simctl get_app_container "$SIM" com.strawdynamics.textinput-harness data)
RESULT=$CONTAINER/Documents/textinput-tests.json
if [ -f "$RESULT" ]; then mv "$RESULT" "$OUT/previous-result.json"; fi
for log in stdout stderr; do
  if [ -f "$OUT/$log.log" ]; then mv "$OUT/$log.log" "$OUT/previous-$log.log"; fi
done
xcrun simctl launch --terminate-running-process --stdout="$OUT/stdout.log" --stderr="$OUT/stderr.log" \
  "$SIM" com.strawdynamics.textinput-harness --test
for _ in $(seq 60); do
  if [ -f "$RESULT" ]; then
    cp "$RESULT" "$OUT/result.json"
    # A committed draft must never enter the shim's logging, even with the normal input logging on.
    if grep -qF 'native paste' "$OUT/stderr.log"; then
      echo "text input harness: a draft reached the input log" >&2; exit 1
    fi
    cat "$OUT/result.json"
    exit 0
  fi
  sleep 0.5
done
tail -30 "$OUT/stderr.log" >&2
echo "text input harness: no result within 30 seconds" >&2
exit 1
