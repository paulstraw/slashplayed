#!/bin/sh
# Test of the SPHover pixel strip: the addon runs against a mock WoW API, and the shim's decoder
# (shims/appkit/sphoverstrip.h) has to get back the rects the mock UI should produce.
# Needs cc and lua ($LUA if set). The addon is written for WoW's Lua 5.1: Homebrew's lua is 5.4, and CI
# (on Linux; nothing here is Mac-only) sets LUA=lua5.1, so both are covered. -lm for decode.c's fabsf,
# which macOS links implicitly and glibc doesn't.
set -e
cd "$(dirname "$0")"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
cc -O1 -Wall -o "$OUT/decode" decode.c -lm
# Through a file rather than a pipe: a plain sh pipeline's status is only the decoder's, so a Lua error
# after the frames it did print would pass unseen.
"${LUA:-lua}" mockwow.lua ../SPHover/SPHover.lua 30 > "$OUT/frames.txt"
"$OUT/decode" < "$OUT/frames.txt"
