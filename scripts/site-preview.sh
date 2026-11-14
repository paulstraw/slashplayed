#!/bin/bash
# Serves site/ as the Pages deploys (release.yml, and pages.yml without a release) lay it out: the page,
# plus Goodmountain's webfont and its license (scripts/fetch-font.sh), which are never committed and so
# only exist next to the page once staged. The staging copy lives in $TMPDIR, so nothing fetched lands
# in site/.
#
#   scripts/site-preview.sh [--port N] [--bind ADDR]
#
# --bind 0.0.0.0 lets a phone on the LAN open it (at the Mac's address); the default is 127.0.0.1 only.
# The copy is a snapshot: rerun after editing site/.
set -euo pipefail
cd "$(dirname "$0")/.."

PORT=8765
BIND=127.0.0.1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT=${2:?--port needs a number}; shift 2 ;;
    --bind) BIND=${2:?--bind needs an address}; shift 2 ;;
    *) echo "site-preview: unknown argument $1 (usage: $0 [--port N] [--bind ADDR])" >&2; exit 1 ;;
  esac
done

scripts/fetch-font.sh
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/sp-site-preview.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
cp -R site/. "$STAGE/"
cp work/fonts/Goodmountain-Regular.woff2 "$STAGE/"
cp work/fonts/LICENSE.md "$STAGE/goodmountain-license.txt"

host=$BIND
[[ "$host" == 0.0.0.0 ]] && host=$(ipconfig getifaddr en0 2>/dev/null || echo localhost)
echo "site-preview: serving $STAGE at http://$host:$PORT/ (Ctrl-C stops it)" >&2
python3 -m http.server "$PORT" --bind "$BIND" --directory "$STAGE"
