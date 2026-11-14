#!/bin/sh
# Tests of the addons. SPHover's pixel strip: the addon runs against a mock WoW API, and the shim's
# decoder (shims/appkit/sphoverstrip.h) has to get back the rects the mock UI should produce. SPKeyboard's
# strip, the same way: the focused box's rect once a box has focus, and a new message when it's focused again. SPMovie:
# a tap on a mock MovieFrame has to open its close dialog (spmovie.lua).
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
"${LUA:-lua}" mockwow.lua ../SPKeyboard/SPKeyboard.lua 10 focus > "$OUT/focus.txt"
"$OUT/decode" K 3 < "$OUT/focus.txt"
"${LUA:-lua}" spmovie.lua ../SPMovie/SPMovie.lua
