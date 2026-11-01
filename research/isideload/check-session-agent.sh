#!/bin/bash
# The token-lifetime measurement: a user LaunchAgent that runs `spisideload check-session` once a day for
# each Apple ID given, appending one JSON line per run (outcomes, Apple's error codes, the login's age:
# never a token or its size) to ~/Library/Logs/Slashplayed/spike-check-session.jsonl. Remove it when the
# measurement ends; the README says what it found.
#
#   research/isideload/check-session-agent.sh install <apple-id>...   (after build.sh and each login)
#   research/isideload/check-session-agent.sh remove
#
# install copies the built CLI to ~/Library/Application Support/Slashplayed/spike/ (the Keychain item trusts
# its signature, not its path, so the copy reads it without asking when build.sh signed it with SP_SIGN_ID)
# so the agent doesn't depend on this checkout. remove unloads the agent and deletes the plist and the copy;
# it leaves the log, and the logins (spisideload forget --apple-id <id> deletes those).
set -euo pipefail
LABEL=com.strawdynamics.slashplayed.spike.check-session
PLIST=$HOME/Library/LaunchAgents/$LABEL.plist
BIN_DIR="$HOME/Library/Application Support/Slashplayed/spike"
LOG=$HOME/Library/Logs/Slashplayed/spike-check-session.jsonl
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
die() { echo "check-session-agent.sh: $*" >&2; exit 1; }

case ${1:-} in
  remove)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    rm -rf "$BIN_DIR"
    echo "removed $LABEL (the log stays at $LOG)"
    ;;
  install)
    shift
    [ $# -ge 1 ] || die "usage: check-session-agent.sh install <apple-id>..."
    [ -x "$ROOT/work/isideload/spisideload" ] || die "run research/isideload/build.sh first"
    mkdir -p "$BIN_DIR" "$(dirname "$LOG")" "$(dirname "$PLIST")"
    cp "$ROOT/work/isideload/spisideload" "$BIN_DIR/spisideload"
    # One shell line: each Apple ID in turn, the agent's own output (progress lines) to a sibling file.
    cmd=""
    for id in "$@"; do
      case $id in *[!A-Za-z0-9@._+-]*) die "unexpected characters in $id" ;; esac
      cmd="$cmd \"$BIN_DIR/spisideload\" check-session --apple-id $id --log \"$LOG\";"
    done
    cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/sh</string><string>-c</string><string>$cmd</string></array>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>9</integer><key>Minute</key><integer>17</integer></dict>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/Slashplayed/spike-check-session.out.txt</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/Slashplayed/spike-check-session.out.txt</string>
</dict></plist>
EOF
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "installed $LABEL: daily at 09:17, appending to $LOG"
    ;;
  *) die "usage: check-session-agent.sh install <apple-id>... | remove" ;;
esac
