#!/bin/sh
# Runs the client on the device (SP_PLATFORM, scripts/platform.sh): launches it with its stdout on
# devicectl's console and waits for it to exit. The launcher gets the on-device JIT helper attached for the
# one prepare stop (spjit.m; it needs the device's pairing record and LocalDevVPN on, as the companion sets
# up), so nothing on the Mac debugs it. Prints the launcher's JIT lines as they come, and its message if
# the helper couldn't do its part (the device shows the same).
# Output: work/clienttest$SP_SUFFIX/console.txt, each line prefixed with seconds since run.sh started.
# SP_FLAVOR (scripts/flavor.sh) picks which of the bundled clients the launcher runs; it's remembered in
# work/clienttest/last-flavor for the other scripts. Arguments are passed to the client; with none, the
# flavor's Battle.net ones (SP_ARGS; grab-token.sh prints the ones Battle.net used).
# SP_SCALE=1 or 2 sets the AppKit shim's backing scale, over the device's Settings > Display (a dev
# override; unset, the setting decides: Automatic is 2 on an iPhone, 1 elsewhere). SP_INPUT_LOG_MAX sets
# how many input events the AppKit shim logs (default 60, 0 for no cap; the lines include typed text).
# SP_PATCH_SERVICE replaces the patch check's service (sppatch.m) for tests: a base URL, or a path in the
# app's home directory holding <product>/versions files (copy one in with devicectl; a <product>/cdns there
# is optional). SP_PATCH_CELLULAR=1 has it treat the network as cellular (it asks before its download), and
# SP_PATCH_CHOOSE=<a button's title> presses that button on its screen (Update, Play Anyway).
# SP_PATCH_DRILL is the patch drill (sppatch.m): `binds` shows the newer-build screen for the current
# build, as one that binds; a symbol (_NSApp) is withheld from the check, so it says the patch needs a
# Slashplayed update.
# SP_LOADING_DRILL=loading or a percent 0-100 keeps the loading screen up over the game (the AppKit shim's
# sploading.m), showing "Loading…" or the data setup's progress at that percent, for screenshots.
# SP_SCENE_CONNECT_LATE=1 holds the scene's connect until the client has set its layer (the AppKit shim's
# spwindow.m), as a launch held until the headset is put on can do; the game must still come on screen.
# SP_SKIP_INTRO=1 starts the game without its intro movie or Retail's Screen Narrator question (launcher.m
# skip_intro), for runs nobody watches. It sets them in the device's Config.wtf, so they stay skipped there.
# SP_START=1 launches without naming a game, as the home screen does, so the start screen shows (spstart.m)
# and the game is the one tapped there (with the arguments last saved for it, not SP_ARGS); the follow below
# starts at once, so tap soon. SP_START_DRILL=<state> (the start screen's drill) opens it with the Settings
# sheet showing that state (spstart.m lists them; `settings` is the sheet as it opens), and returns once
# it's launched, with no console (screenshot it with devicectl device capture screenshot; the launcher's
# lines are in Documents/spconsole.log, pull-logs.sh). SP_START_TEXT_SIZE=<XS…XXXL, AX1…AX5> sets the start
# screen's Dynamic Type size.
set -e
cd "$(dirname "$0")"
. ../../scripts/platform.sh
OUT=../../work/clienttest$SP_SUFFIX
sp_need SP_BUNDLE_ID
sp_need_device
BUNDLE_ID=$SP_BUNDLE_ID
. ../../scripts/flavor.sh
[ -n "$SP_START_DRILL" ] && SP_START=1
if [ "$SP_START" = 1 ]; then
  [ -n "$SP_START_DRILL" ] && export DEVICECTL_CHILD_SP_START_DRILL=$SP_START_DRILL
  [ -n "$SP_START_TEXT_SIZE" ] && export DEVICECTL_CHILD_SP_START_TEXT_SIZE=$SP_START_TEXT_SIZE
else
  # A build with images has to have this one; one without (build.sh's SP_NO_IMAGES=1) installs it on the
  # device first if it hasn't yet (sppatch.m's sp_patch_install).
  if ls $OUT/Slashplayed.app/wow-* >/dev/null 2>&1; then
    [ -f $OUT/Slashplayed.app/wow-$SP_FLAVOR ] || { echo "$SP_FLAVOR isn't in the installed build (build.sh)"; exit 1; }
  fi
  [ $# = 0 ] && set -- $SP_ARGS
  echo $SP_FLAVOR > ../../work/clienttest/last-flavor
  export DEVICECTL_CHILD_SP_LAUNCH_FLAVOR=$SP_FLAVOR
fi
[ -n "$SP_SCALE" ] && export DEVICECTL_CHILD_SP_SCALE=$SP_SCALE
[ -n "$SP_INPUT_LOG_MAX" ] && export DEVICECTL_CHILD_SP_INPUT_LOG_MAX=$SP_INPUT_LOG_MAX
[ -n "$SP_PATCH_SERVICE" ] && export DEVICECTL_CHILD_SP_PATCH_SERVICE=$SP_PATCH_SERVICE
[ -n "$SP_PATCH_CELLULAR" ] && export DEVICECTL_CHILD_SP_PATCH_CELLULAR=$SP_PATCH_CELLULAR
[ -n "$SP_PATCH_CHOOSE" ] && export DEVICECTL_CHILD_SP_PATCH_CHOOSE=$SP_PATCH_CHOOSE
[ -n "$SP_PATCH_DRILL" ] && export DEVICECTL_CHILD_SP_PATCH_DRILL=$SP_PATCH_DRILL
[ -n "$SP_LOADING_DRILL" ] && export DEVICECTL_CHILD_SP_LOADING_DRILL=$SP_LOADING_DRILL
[ -n "$SP_SKIP_INTRO" ] && export DEVICECTL_CHILD_SP_SKIP_INTRO=$SP_SKIP_INTRO
[ -n "$SP_SCENE_CONNECT_LATE" ] && export DEVICECTL_CHILD_SP_SCENE_CONNECT_LATE=$SP_SCENE_CONNECT_LATE
if [ -n "$SP_START_DRILL" ]; then
  xcrun devicectl device process launch --device "$SP_DEVICE" --terminate-existing -- $BUNDLE_ID "$@"
  echo "start screen drill $SP_START_DRILL launched: screenshot with xcrun devicectl device capture screenshot --device $SP_DEVICE"
  exit 0
fi
T0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
stamp() { perl -MTime::HiRes=time -ne 'BEGIN { $| = 1 } printf "%7.2f %s", time - '$T0', $_'; }
xcrun devicectl device process launch --device "$SP_DEVICE" --terminate-existing --console \
  -- $BUNDLE_ID "$@" 2>&1 | stamp > $OUT/console.txt &
CONSOLE=$!
# Follow the launch to the end of the prepare (ClientLauncher.swift reads the same lines): 180 s covers a
# disk image mount, which the helper does when the device has none.
for i in $(seq 900); do
  grep -q -e '\[sp:System\] detached' -e "\[sp:launch\] can't prepare" $OUT/console.txt && break
  kill -0 $CONSOLE 2>/dev/null || break
  sleep 0.2
done
grep -E '\[sp:launch\] (jit:|vpn:|can.t prepare)|\[sp:System\] (preparing|detached)|ERROR' $OUT/console.txt || true
grep -q '\[sp:System\] detached' $OUT/console.txt || { echo "the client wasn't prepared (log: $OUT/console.txt)"; kill $CONSOLE 2>/dev/null; exit 1; }
wait $CONSOLE || true
cat $OUT/console.txt
