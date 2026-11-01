# How Slashplayed works

Slashplayed runs the unmodified Mac World of Warcraft clients (Classic Era, TBC Anniversary, MoP Classic, and Retail) on M1-or-later iPads (iPadOS; untested on M1), iPhone 15 Pro and later (iOS), and Apple Vision Pro (visionOS). It's a
compatibility layer: the client's own arm64 code runs natively on the device, and a set of shim
libraries stands in for the macOS frameworks it expects (AppKit, CoreGraphics, Carbon, CoreAudio,
Security, …), translating to UIKit, RemoteIO and friends. No game code is changed beyond Mach-O
header and load-command edits made on the user's Mac (or on the device, when it updates a game
itself), and no game files ship with Slashplayed.

This page is the map. The experiments behind each technique are in [research.md](research.md).

## The pipeline

The Mac companion app (`apps/companion`) does all of this on the user's Mac, for whichever games
they've chosen for the device, whether or not the game is installed on the Mac:

1. **Fetch the client.** The companion asks Blizzard's patch service for the game's current build and
   downloads just the arm64 slice of that build's Mac client from Blizzard's CDN (`BlizzardCDN.swift`:
   one ranged request for the chunks that cover it, about 50 MB, each checked against its key, and
   cached in `~/Library/Application Support/Slashplayed/cdn/`). The dev script `apps/client/build.sh`
   takes the same slice from the Mac's install instead, with `lipo -thin arm64`. That's the only place
   the two differ: their *input*. For the same build the slice is the same bytes, and so is every image
   made from it (`ClientAssemblyTests.testMatchesBuildShOnInstalledClients`, opt-in, compares them).
   Steps 2 to 4 have a third producer, the launcher's `apps/client/spassemble.m`, which makes the image
   on the device (see [Updating on the device](#updating-on-the-device)).
2. **Rewrite load commands.** Every macOS library the client links (about 30) is pointed at either
   the device's real library (when visionOS/iPadOS has it with the same exports) or a Slashplayed shim
   (`@rpath/libsp<Name>.dylib`), using `shims/generated/rewrite-map.txt` and `install_name_tool`. An
   `@executable_path/Frameworks` rpath is added. Nothing in the client's code or data changes.
3. **Set the platform.** `vtool -set-build-version` marks the image as visionOS or iOS, so the
   device's dyld will load it.
4. **Retype.** The client's header file type changes from `MH_EXECUTE` to `MH_BUNDLE`, and the
   file offset of its zero-fill thread-local section is zeroed (header only; see
   [One app, every game](#one-app-every-game)).
5. **Check binds.** Every import of the rewritten client is looked up in the bundled
   `exports.json` (what each shim and system library exports). An import nothing provides means a
   game patch added something Slashplayed doesn't cover yet; the companion stops with a clear
   message instead of installing something that would crash at launch (`BindCheck.swift`).
6. **Assemble and sign.** The launcher, the on-device JIT helper (`PlugIns/SPJitHelper.appex`), the
   shims, every chosen game's client image with its build stamp (`spbuild-<flavor>`), the system
   root certificates (`sproots.plist`), the third-party licenses (`licenses/`), and the filled-in
   Info.plist and entitlements go into `Slashplayed.app`. The companion makes or refreshes
   explicit-App-ID development profiles with the user's own team, one for the app and one for the
   helper (by building a tiny stub project with `xcodebuild -allowProvisioningUpdates`), signs
   everything, the helper before the app, and installs it with `devicectl`, unless the device still holds
   the install this Mac made of this build (`ClientBuild.installNeed`). The iPad and the iPhone share one
   build, and a device's app may have been deleted there or installed from another Mac, with other games.
   So the companion keeps a record per device (the build and its games), and checks it against the app
   `devicectl` lists there: every install puts the app in a new folder, so one made since is told apart.
   Then it makes sure the app has what the helper needs (see [The on-device JIT
   helper](#the-on-device-jit-helper)), in its data container, which the install comes before.
7. **Game data.** The client streams its own game data from Blizzard's CDN into the app's
   `Documents/Data/`, so all it needs to start is `Documents/.build.info` and, in `Documents/Data/config/`,
   the build, CDN, and key configs its row names. That's what the companion sends by default. **Copy Game
   Files from This Mac** (a per-device choice in Settings > Games, on for devices
   paired before it existed) copies the Mac's whole store instead, with `devicectl device copy`,
   incrementally (only files whose size or modification time differ; configs and CDN indexes, named by
   their content, only by size). When a device holds only some
   games, only the storage archives those games use are copied. See [Game data on the
   device](#game-data-on-the-device).
8. **Launch and prepare.** At every launch the helper, on the device, attaches to the game and
   services one stop, the JIT prepare described below, then detaches. The Mac isn't needed: a
   launch from the home screen works the same as one from the companion.

The entitlements are `get-task-allow` (a debugger may attach; development signing gives it),
`com.apple.developer.kernel.increased-memory-limit` and `extended-virtual-addressing` (Retail needs
more than the default ~5 GB limit; with them it's ~8 GB). A free Personal Team can't have
`extended-virtual-addressing` (Apple refuses the profile), so the companion leaves it out for one;
`increased-memory-limit` alone runs every flavor, Retail included. A free team's profile lasts 7 days,
and the companion re-signs within two days of that.

Every third-party component that ships carries its license text, generated at build time from the
pinned sources. The device app's `licenses/` has zsign's and OpenSSL's (`scripts/build-zsign.sh`), and
idevice's with every Rust crate the JIT helper links and the Rust standard library's notices
(`scripts/build-idevice.sh` runs `scripts/crate-notices.py` over `cargo tree` for the same features and
targets as the build, and fails on a crate whose source has no license text; the two crates that declare
MIT but ship no file get the text from `scripts/crate-licenses/`). The companion's
`Contents/Resources/Acknowledgements/`, linked from its About panel and Help menu, has Sparkle's (a
build phase copies it from the SPM checkout), idevice's as the companion links it, and the device app's.
`AcknowledgementsTests` checks the notices against the crates the archives' own symbols name.

## Executable memory under TXM

The client rewrites its own code at startup: it makes regions of its own `__TEXT` writable, writes
new code there, and makes them executable again. On macOS that's ordinary. On M2-era devices running
visionOS 26+/iPadOS 26+, the Trusted Execution Monitor (TXM) decides what may execute, and no
certificate a third party can get grants `MAP_JIT` there. The M1 iPads predate TXM (the Page
Protection Layer, PPL, enforces code signing there instead), and the path below hasn't been run on
one: it's expected to work, but M1 iPads are allowed as untested (`Device.isUntestedIPad`).

What does work, on visionOS 27 and iPadOS 26 alike (measured in `research/jittest`):

- A page that a **debugger** has written to stays `r-x` with maximum protection `rwx`. Code written to
  it afterwards **through a separate read-write alias** (`vm_remap`) executes, at any address,
  including the app's own signed `__TEXT` at its real load address, and keeps working after the
  debugger detaches.
- A page made writable **in place** (`mprotect` RW, or even `vm_protect` with `VM_PROT_COPY`) can
  never be executable again.

So the libSystem shim (`shims/system/spsystem.c`) services the client's rewrite through an alias
mapping:

- The client looks up its memory functions with `dlsym`. The shim's `dlsym` hides
  `pthread_jit_write_protect_np` (no `MAP_JIT` here), so the client takes its plain
  `mprotect`/`memcpy` path, and hands out the shim's own `mprotect` and `memcpy`.
- The first `mprotect(rwx)` inside the main image's `__TEXT` copies `__TEXT` aside and asks the
  debugger, with one `brk #0xf00d` (the StikDebug-compatible protocol), to prepare all of it. The
  debugger writes over every page (`research/jittest/jit.py`, mode `bulkx`: raw binary `X` packets,
  the fewest round trips), then detaches. The shim maps a read-write alias of `__TEXT` and restores
  the saved contents through it.
- From then on, `mprotect` inside `__TEXT` returns 0 without doing anything, and the shim's `memcpy`
  writes into `__TEXT` through the alias. `__TEXT` itself is never writable.

A `brk` with no debugger kills the process, so the shim checks `P_TRACED` first, and waits up to 60 s
for it. The debugger is needed at every launch (the prepare can't happen after detach).

## The on-device JIT helper

A process can't service its own debugger stops, so the debugger is a second process: an app extension
bundled in the app (`apps/client/helper`, `PlugIns/SPJitHelper.appex`). It's a classic extension that
claims Apple's AR viewer extension point (`com.apple.ar.viewer`), with an activation rule nothing
matches, because visionOS installs an extension only on one of Apple's points. The launcher starts it
by bundle ID with `NSExtension`'s private request calls, the ones LiveContainer uses; each request is a
new helper process. On a free Personal Team the helper takes one more of the team's weekly App IDs, but
not one of the three app slots a device has for free teams.

The helper reaches the device's own developer services the way a Mac does over the network: it opens
a RemotePairing tunnel through a loopback VPN (LocalDevVPN, at `10.7.0.1:49152`) with
[idevice](https://github.com/jkcoxson/idevice), linked statically (`scripts/build-idevice.sh`). Through
the tunnel it starts debugserver and speaks the GDB remote protocol to it. The launcher (`spjit.m`)
runs, before the client is loaded:

1. **status**: the tunnel, and whether the developer disk image is mounted.
2. **mount**, only when it isn't: debugserver is in the image. The helper personalizes the image's
   cryptex with Apple's signing server and installs it. On iOS 27 it stays mounted across a reboot.
3. **attach**: the helper attaches, services the shim's prepare stop (one byte written to every 16 KB
   page of `__TEXT`, about 2,900 pages in 0.1 s), and detaches. The launcher loads the client once it
   sees `P_TRACED`.

A launch with the image mounted takes about 1.5 s from start to attached. On iOS the launcher shows
the scene first (see [iPad](#ipad)), and if the helper can't do its part, the launcher puts the reason
on the scene and doesn't load the client: no pairing record, no image to mount. LocalDevVPN off isn't
one of those: before pairing and each status request, the launcher tries a TCP connect to
`10.7.0.1:49152`, and when that fails it shows a screen and waits (`spvpn.m`). The screen opens
`localdevvpn://enable?scheme=slashplayed`, once by itself and again from its button: LocalDevVPN turns
its VPN on and opens `slashplayed://` (the app's one URL type), back to the app. The connect, tried
every second off the main thread, is what ends the wait, so turning it on by hand works too. Opening the
app again would only bring the waiting one back, which is why it doesn't fail and ask for that. An app
that a debugger already holds (StikDebug launched it) skips the helper. When the device no longer
accepts the record (the status reply says `rejected`: the tunnel's pair-verify failed and idevice asked
for a pair-setup code), the launcher deletes it, so it's made again.

What the helper needs is in the app's data container. The companion puts it there when it installs,
except the headset's record:

- **The RemotePairing record** (`Library/sppairing.plist`), on an iPad or iPhone. iOS won't make one on
  the device (its network RemotePairing service resets a host it doesn't trust before pair-setup), so
  the companion makes one over USB, through lockdown's `remotepairingdeviced` service, with no prompt
  (`Pairing.swift`). It's a credential: never read or logged, 0600 on the Mac and deleted after the
  copy. The launcher hands it to the helper in memory.
- **The headset's RemotePairing record**, made on the headset, by Slashplayed, on its first launch. With
  Settings > General > Remote Devices open, visionOS advertises `_remotepairing-manual-pairing._tcp`
  and does pair-setup with a six-digit code it shows, the way Xcode pairs a Vision Pro over Wi-Fi. The
  launcher shows a pairing screen (`sppair.m`; UIKit starts before the client for it, as on iOS, since
  the launch watchdog kills an app that waits on a person without a scene), finds the service over
  Bonjour (so the local network prompt is the app's), and sends the helper a **pair** request. The
  helper runs pair-setup with idevice (`helper/Pair.swift`), so idevice stays out of the launcher. The
  code is needed while that request is running, and a request has no way in, so the helper connects
  back to a listener the launcher opens on 127.0.0.1 (its port and a random token are in the request;
  the code goes only to a connection that sends the token). The helper proves the new record with a
  tunnel and returns it in its reply, and the launcher writes it to `Library/sppairing.plist` (0600)
  and goes on with the launch. iOS refuses pair-setup with itself, hence the companion's USB pairing
  there.
- **The developer disk image** (`Library/spddi/`), copied from the Mac's Xcode
  (`DeveloperDiskImage.swift`): the cryptex only, ~17 MB for iOS and ~13 MB for visionOS. It's copied
  again when Xcode has a newer one.

## One app, every game

visionOS won't `exec` or `posix_spawn` another executable from an app bundle, and dyld won't `dlopen`
an `MH_EXECUTE`. But it will `dlopen` an `MH_BUNDLE`, and the client's constructors, Objective-C
classes and thread-local variables all work from one. So `Slashplayed.app` holds every chosen game
as `wow-<flavor>` (retyped `MH_BUNDLE`), and its main executable is a small launcher
(`apps/client/launcher.m`) that:

1. deletes the game files the companion listed in `Library/spdelete.txt` (devicectl can't delete
   files) and writes the device's free space to `Library/spfree.txt`: the figure Settings shows, which
   counts space iOS can clear, and the figure without it. Lockdown, all the Mac can read, gives only
   the second, so the companion adds the difference to lockdown's figure now (`FreeSpace.now`);
2. on iPadOS, brings up UIKit and waits for an active scene first (see [iPad](#ipad));
3. picks the game: the one the companion's Play or `run.sh` names (`SP_LAUNCH_FLAVOR`), else the one
   tapped on its start screen (`spstart.m`, every other launch, even with one game; its gear opens the
   app's Settings, [below](#the-start-screen-and-settings)). The names,
   their order, and Battle.net's arguments for each come from the app's `flavors.plist`
   (`apps/client/flavors.plist`, which `scripts/flavor.sh` and the companion read too). Every launch
   makes sure the game's `Config.wtf` has its region and languages (`portal`, `textLocale`,
   `audioLocale`), from the game's `.build.info` row (Branch and Tags), adding missing ones and replacing
   empty ones: started by Battle.net, the client takes them from Battle.net's launch options, which
   nothing writes on the device, and with neither it opens a region picker the device can't show, exits,
   and saves the three empty, so every later launch would exit too. On a game's
   first launch on the device, it marks the intro movie as played in that game's `Config.wtf` (the
   setting the game writes itself once it has): a first session on an empty store sets up its data
   first, and the intro it starts then never asks the CDN for the movie's data, so it would wait on its
   download bar forever (the next session plays it at once). For a run nobody watches
   (`SP_SKIP_INTRO=1`: `run.sh`, the companion's `-skip-intro`), it also adds what answering Retail's
   Screen Narrator question writes. Only settings that are missing, so neither holds up the launch;
4. logs the image's build against the game data's, and asks Blizzard's patch service whether a newer
   build is out (both below); then, before the sign-in, refuses to load the game over a copy of game
   files that stopped partway (`Library/spcopying.txt`, see
   [Game data on the device](#game-data-on-the-device));
5. puts up the loading screen (below), tells the libSystem shim which game folder is the install root,
   `dlopen`s that game's image and calls its `LC_MAIN` entry point.

Each image carries the build it was made from in a file beside it, `spbuild-<flavor>` next to
`wow-<flavor>`: the build columns of the game's `.build.info` row (`Product`, `Branch`, `Build Key`,
`Version`), as a one-row table of the same `|`-separated shape, so one parser reads both.
`apps/client/build.sh` takes them from the install's `.build.info`, the companion
(`ClientAssembly.Stamp`) from the patch service's version row (`Region`, `BuildConfig`,
`VersionsName`), and for the same build they write the same bytes. At each Play the companion asks the
patch service for each of the device's games' current build (about 80 ms each) and rebuilds an image
whose stamp isn't it; if the service can't be reached, an image that exists is played as it is. The
stamp is named after the image, not the app, so an image placed elsewhere later (an on-device update
in `Library/`) brings its own. The launcher reads the stamp of the image it's about to load and logs
it against `Documents/.build.info`'s row for the product (`build: image and game data are both …`, or
`build: MISMATCH: …`): today the image and the data are copied separately, so after a patch one can
reach the device without the other.

Then the patch check (`apps/client/sppatch.m`), before the sign-in and the helper: the launcher fetches
`https://<region>.version.battle.net/v2/products/<product>/versions` (the same `|`-separated table
shape, one row per region; the region is the stamp's `Branch`) and compares that region's
`BuildConfig` with the stamp's `Build Key`. The same means nothing shows. A different one means
Blizzard has a newer build out than the image, so a screen says so (or offers to update it on the
device: see [Updating on the device](#updating-on-the-device)), and first finds out whether this
Slashplayed can run it at all. The device fetches the new build's client from Blizzard's CDN the way the companion does (`apps/client/spcdn.m`, the port of
`BlizzardCDN.swift`: build config, install manifest, one encoding page, then one ranged request for the
chunks covering the arm64 slice, everything checked against the key that names it; about 45 MB, 3 s on
an iPhone on Wi-Fi), the sibling `/cdns` table giving the servers. On cellular, a hotspot, or Low Data
Mode it asks first (**Download** or **Not Now**). Then it checks the slice's imports against the
`exports.json` the app carries (`build.sh` and `ClientAssembly` both copy it into the app): the device
has no `dyld_info`, so `apps/client/spbind.m` reads the imports from the Mach-O itself, from either kind
of fixup info (bind opcodes, which the clients have, or chained fixups), leaving weak imports out as
`BindCheck` does. The companion's tests hold it to `BindCheck`'s answer on fixtures of both kinds and,
opt-in, on every build the untethered research kept. It binds: "<Game> <version> is out. Update on your
Mac to play it." It doesn't: "This patch needs a Slashplayed update." It couldn't tell (the download
failed, Not Now, an app without `exports.json`): the first. Each has **Play Anyway**, which goes on with
the image it has; the companion follows the screen as a wait on the person (`patch: showing the
newer-build screen`, `patch: Play Anyway`). The slice stays in `Library/spslice/<flavor>.arm64` with its
own stamp (`spbuild-<flavor>`, written once the slice is whole), so a later launch for the same build
doesn't fetch it again, and an on-device update can build its image from it. A check that can't be made
(offline, a timeout, no row) goes on without a word: the service fetch has a 3 s budget, and a refused
connection fails at once. The log has a line for each step, versions only (`patch: up to date: …`,
`patch: newer build out: …`, `patch: slice: …`, `patch: imports: N of M resolve …` and any `UNRESOLVED`
ones, `patch: message: update on your Mac: …` or `patch: message: needs a Slashplayed update: …`,
`patch: couldn't check …: going on`). `SP_PATCH_SERVICE` (passed by `run.sh`) replaces the base URL
for tests: a URL, or a path in the app's home directory read as files (`Library/sppatchtest` with
`Library/sppatchtest/<product>/versions` copied in by `devicectl`; a `cdns` file beside it is optional,
the real service's is used without one, so a row naming a real build tests the whole check).
`SP_PATCH_CELLULAR=1` makes it ask, as on cellular.

The loading screen (`shims/appkit/sploading.m`, in the AppKit shim; the launcher calls
`sp_uikit_loading` with the game's name) covers the time from the `dlopen` to the client's first
frame, which was black: a few seconds on a full store, and from an empty one the client's data setup
(about 10 s on an iPhone; see [the data setup dialog](#shims)) and then up to a minute and a half
with its window up and no frames while it streams its startup data. It shows the game's name and a
spinner with "Loading…", or during the setup a progress bar with "Preparing game data… 60%" (the
percentage from `spnotice.m`, which posts it as an `SPDataSetupProgress` notification; nothing of the
dialog's text). It sits on the root view above the client's Metal layer, and the first
`presentDrawable` (hooked in `sphover.m`) takes it down. In both spans the client holds the main
thread without pumping events, so UIKit's run loop doesn't turn: each change is committed with an
explicit `CATransaction` flush, and the spinner is a Core Animation animation, which the render server
runs on its own. On iOS UIKit is up already and the screen goes up at once; on visionOS it goes up
when the scene connects, once the client has started UIKit. With `SP_HOVER_OFF=1` the presents aren't
hooked, so there's no loading screen. Logged as `[sp:AppKit] loading: screen up …` and `[sp:AppKit]
loading: first frame … s after the client was asked for, screen down`.

The visionOS dyld also rejects a non-main image whose zero-fill section has a nonzero file offset
(the macOS dyld checks neither this nor the file type), hence the second header edit.

All games share one app container, so the shared `Data/` store is copied once.

A game install on the Mac is optional, and so is Battle.net. The companion's pipeline doesn't read the
install; it's the source of two choices only: **Copy Game Files from This Mac** (step 7) and **Play with
My Mac's Battle.net** (see [Sandbox redirects](#sandbox-redirects)), which the menu by Play offers only
when one of the device's games is installed. The small identity file login needs from the Mac needs no
install. Onboarding (`Onboarding.swift`) requires Xcode, the team, the device, LocalDevVPN, and a game
per device; its last step lists what the Mac has installed and always passes. The dev script
`apps/client/build.sh` still builds from an install (step 1), or with `SP_NO_IMAGES=1` builds the app with
no image at all ([Installing a game on the device](#installing-a-game-on-the-device)).

### The start screen and Settings

Every launch that doesn't name a game (a launch from the home screen) opens on the start screen
(`spstart.m`, its screen in SwiftUI, `spstartscreen.swift`): the app icon's medallion and a framed
button per game in `flavors.plist`'s order, all drawn in code (**Install <game>** for one an app without
images hasn't installed yet, [below](#installing-a-game-on-the-device)). Its face is Goodmountain, which the app
ships unmodified with its license (`scripts/fetch-font.sh`; it's never committed). The gear opens
Settings, a stock dark inset-grouped sheet in SwiftUI (`spsettings.swift`), one for iOS and visionOS:

- **Battle.net**: whether a sign-in is saved; **Show Email** (the one place the saved email is shown,
  read from the keychain inside `splogin.m` at the tap and hidden again when the app goes to the
  background, the sheet closes, or a game starts); **Forget My Sign-In**; or, with none saved,
  **Sign In…**, which presents the sign-in screen to save one ahead of time.
- **Game Updates**: the signing identity's state, dates only (`sp_identity_reading`, the same reading
  the log line and `Library/spidentity.txt` use), and **Forget Signing Identity**.
- **Display**: Scale, Automatic, 1x, or 2x, the backing scale for every launch on this device (Render
  scale, under Window, screen and scene tracking).
- **A section per game**: the build it starts with, shipped with the app, updated on this device, or
  installed on it (`sp_game_build`, by the launcher's own rules; "Not Installed" for a game an app
  without images hasn't installed yet, [below](#installing-a-game-on-the-device)), **Open in Files**, and **Reset Game Settings**, which deletes the game's
  `WTF/Config.wtf` and `Library/sprenderscale-<flavor>` so the next start seeds them as on a first
  launch (the region and languages too); `WTF/Account/` (keybindings, macros, addons' saved settings) is kept.
- **About**: the app's version and Acknowledgements, the files in the app's `licenses/`.

`Info.plist` has `UIFileSharingEnabled` (Finder on a Mac browses `Documents/`) and
`LSSupportsOpeningDocumentsInPlace`, so all of `Documents/` shows in the Files app too. Open in Files
opens the game's folder, `Documents/_<flavor>_/`, with its `shareddocuments://` URL (the folder's path),
or `Documents/` before the game's first start makes the folder. That exposes `Data/` (a deleted archive
or index leaves the store unreadable: "installation is damaged") and, for the moments it exists, the
game's `login.txt`; both were weighed and accepted: the files are the person's own, on their own device.

The forgets and the reset act at the tap, after a confirmation whose default is Cancel. Forgetting the
identity rewrites `Library/spidentity.txt` at once with `forgotten`, so the companion turns Update Games
on This Device off for that device rather than send the identity back.

A dev-only drill opens the screen in a given state, so each can be screenshotted without taps:
`SP_START_DRILL=<state> apps/client/run.sh`. `run.sh` alone passes it (a home-screen launch has no
environment), and it launches with no console. The states are `settings`, `game-updates`, `display`,
`games`, `about`, `sign-in`, `acknowledgements`, `license-<file>` (e.g. `license-rust-std`), the confirmations
`alert-forget-signin`, `alert-forget-identity`, and `alert-reset`, and `reset-<flavor>`, which resets
that game's settings with no confirmation, for a test, `scale-<0|1|2>`, which saves that Scale
(0 is Automatic), and `files-<flavor>`, that game's Open in Files tapped. `SP_START=1` shows the start screen alone, and
`SP_START_TEXT_SIZE=<XS…XXXL, AX1…AX5>` sets its Dynamic Type size.

## Updating on the device

When Blizzard puts out a build newer than the device's image of a game, a device that holds a signing
identity of the team can make that build's image itself, with no Mac. **Update Games on This Device**,
in the companion, puts the identity there; it's off for every device until the person turns it on. The
chain, all in the launcher, between the patch check and the client's `dlopen`:

1. **Find it.** The patch check sees the service's build differ from the image's stamp, fetches the new
   build's arm64 slice from the CDN into `Library/spslice/` (`spcdn.m`; on cellular it asks first), and
   checks its imports (`spbind.m`), as [above](#one-app-every-game).
2. **Offer it.** The build binds and the device's identity is usable (valid, and listed in a profile the
   app can see): the screen offers **Update** beside Play Anyway. Otherwise it's the screen above.
3. **Make it.** Update fetches the build's configs into `Documents/Data/config/`, assembles the image from
   the kept slice (`spassemble.m`: the pipeline's steps 2 to 4, the same bytes as the Mac's), and signs it
   (`spsign.m`, zsign) into `Library/spgames/wow-<flavor>`, its stamp beside it. Under a second on an
   iPhone, after the slice's 2–3 s.
4. **Load it.** The launcher `dlopen`s it and, only once that has succeeded, writes the new build's row
   into `Documents/.build.info`. The client then streams the build's new content itself, as it does
   into an empty store.

Which image a start loads, in order:

- A `Library/spgames` image the bundled image has caught up with (its stamp has the update's build, or a
  later version) is deleted first: the companion installed that build or a later one since.
- The `Library/spgames` image, when its stamp is the patch service's current build, or when the service
  couldn't be asked and it's later than the bundled image, **and** a profile the app can see lists its
  signer. When none does, it's signed again with the device's identity if a profile lists that one;
  if not, this start loads the bundled image and the update is kept for a later identity.
- Otherwise the bundled image. When `dlopen` refuses the `Library/spgames` image it's deleted, a note
  says so for a few seconds, and the bundled image loads with `.build.info` left as it was.

### Installing a game on the device

The same chain installs a game the app has no image of, so a host can install the app without shipping
any client image (Blizzard's bytes) at all. `SP_NO_IMAGES=1 apps/client/build.sh` builds such an app:
no `wow-<flavor>` and no `spbuild-<flavor>`, and no game install on the Mac needed. The Mac companion
still ships images, and an app with images behaves as before.

- **The games.** An app with images offers the games it bundles, as always. An app with none offers
  every game in `flavors.plist`; those the device hasn't made a loadable `Library/spgames` image of read
  **Install <game>** on the start screen (`sp_games`, in `spcdn.m`), and Settings says "Not Installed".
- **The install.** Tapping one runs `sp_patch_install` (`sppatch.m`) before anything else for that game,
  on the patch screen: the signing identity first (`sp_identity_usable`, before any download; without
  one the screen says which it is, none, forgotten, expired, unreadable, or not in the app's profile,
  and that the companion's Update Games on This Device sends one), then the patch service's current
  build, the slice and its bind check (asking first on cellular), and the update's configs, assembly,
  signing, and stamp into `Library/spgames/`, plus the game folder's `.flavor.info` if it has none (what
  the companion sends, `sp_flavor_info`). The region is the product's `.build.info` Branch if the device
  has a row, else `us`, as the companion's first `Config.wtf` assumes (`sp_install_region`). Any failure
  shows why with **Back**, which returns to the start screen; a launch that named the game
  (`SP_LAUNCH_FLAVOR`) stops on the reason instead. The log has `patch: install: …` lines, versions only.
- **After it.** The launcher loads the new image and writes `.build.info` once it has loaded, as after
  Update; the client then sets up its empty store and streams. Later starts treat the `Library/spgames`
  image as the game's only image: the patch check compares it, Update replaces it, and Play Anyway
  plays it. With no bundled image to fall back on, an image `dlopen` refuses is deleted and the launch
  stops on the reason; the next start offers Install again.

The addons and the small identity file login needs from the Mac aren't part of the install: they come
from the host, as the companion sends them today.

What the device holds for it, all in the app's container:

| What | Where | Written by | Gone when |
|---|---|---|---|
| The signing identity | the app's keychain, service "Slashplayed signing identity" (this device only, never synced) | the launcher, from the pushed `Library/spidentity.p12` and `.pass` (deleted at once) | Forget Signing Identity on the device, or the companion's forget marker (the setting turned off, Stop Using the Slashplayed Certificate) |
| What it holds | `Library/spidentity.txt` (`present <day>`, `expired`, `none`, `forgotten`) | the launcher, every start | rewritten every start |
| B's profile | installed device-wide, and a copy in `Library/spprofile.mobileprovision` | the companion | it expires (an expired one lists nothing) |
| A newer build's slice | `Library/spslice/<flavor>.arm64`, `spbuild-<flavor>` | the patch check | the bundled image catches up |
| The updated image | `Library/spgames/wow-<flavor>`, `spbuild-<flavor>` | Update | the bundled image catches up, or `dlopen` refuses it |
| The build's row and configs | `Documents/.build.info`, `Documents/Data/config/` | Update, after the load | the companion writes a later build's |

Forgetting the identity leaves the images: one already made keeps loading while a profile lists its
signer, and the next newer build shows "Update on your Mac" again, with no Update button. Deleting the
app deletes the container and everything in it, but iOS keeps an app's keychain items after the app is
gone, and installed profiles stay too, so Forget Signing Identity comes first.

The parts, in the order the chain uses them:


The device can also make the client image itself from a kept slice: `apps/client/spassemble.m` does
steps 2 to 4 of [the pipeline](#the-pipeline) in Foundation, with the `rewrite-map.txt` the app carries
(`build.sh` and `ClientAssembly` both copy it in) and the platform and minimum OS of the launcher's own
`LC_BUILD_VERSION` (`build-launcher.sh` compiles it for `scripts/platform.sh`'s target, the one `vtool`
is given). Its output is the same bytes as `install_name_tool` and `vtool` write, so the three producers
(`build.sh`, `ClientAssembly.prepareClient`, `spassemble.m`) make one unsigned image from one slice.
What the tools do was read from their output: each `-change` rewrites its dylib command in place (the
name at offset 24, zero padding to 8 bytes), the rpath and the new `LC_BUILD_VERSION` (no tools, the SDK
set to the minimum OS) are appended at the end, every older build version is dropped, and what's left of
the old commands' space is zeroed; nothing past the load commands changes. A shipped client's signature
(`LC_CODE_SIGNATURE` and its bytes) is left where it is, stale, for signing to replace. The tools re-sign
an image signed only by the linker (renaming its identifier after their output file); `spassemble.m`
refuses one, since a client never is. The companion's tests compare it with `prepareClient` byte for byte
on fixtures of our own (signed as a client is, and unsigned) and, opt-in
(`TEST_RUNNER_SP_COMPARE_ASSEMBLY=1`), on every game's current CDN slice for both platforms; the opt-in
`testMatchesBuildShOnInstalledClients` holds it to `build.sh`'s image too. An update on the device (below) loads it.
The test hook `SP_ASSEMBLE_TEST=<flavor>` (pass it as `DEVICECTL_CHILD_SP_ASSEMBLE_TEST` to `devicectl
device process launch`) assembles `Library/spslice/<flavor>.arm64` into the app's `tmp/wow-<flavor>`,
logs `assemble: <product> <version> … <size> in <time>, platform …, minimum OS …, sha256 …` and a line per
retype change, and ends the launch without loading anything: the SHA-256 is the one the opt-in test prints
for the same build, or that `shasum` gives `build.sh`'s image of it. About 0.06 s for 50 MB on an iPhone.

The device can sign such an image too: `apps/client/spsign.m` signs with a development identity kept in
the app's keychain, through [zsign](https://github.com/zhlynn/zsign) (MIT; `apps/client/spzsign.cpp`)
and OpenSSL (Apache-2.0), both built from source at pinned commits by `scripts/build-zsign.sh`, with
`scripts/zsign.patch` applied, and linked into the launcher by `build-launcher.sh`. The device app
carries their licenses in `licenses/`, with the JIT helper's (see [The pipeline](#the-pipeline)). The identity comes from the Mac as
`Library/spidentity.p12` and `Library/spidentity.pass` (both 0600); at every start the launcher checks
the pair with `SecPKCS12Import` (one identity, the password opens it), puts it in the keychain
(`WhenUnlockedThisDeviceOnly`, never synchronized), and zeroes and deletes both files whatever happens.
It logs `identity: imported …` or why not, then `identity: present, certificate valid until <date>` or
`identity: none`: never the certificate's subject or hash, never the password. **Forget Signing
Identity** in the start screen's Settings deletes it, and any pushed files not yet imported, at the tap. Signing takes the app's own `embedded.mobileprovision`
for the team, and never puts entitlements in a non-executable's signature (iOS refuses a library or bundle
with an entitlements blob, even an empty one; zsign writes one unpatched). zsign writes through a shared
writable mapping, and an image loaded from such a file is killed in `dlopen` (CODESIGNING, Invalid
Page), so `sp_sign` signs a copy, reads it back, writes the bytes into a new file with `write()`, and
renames that into place; the file zsign wrote is never loaded. An image signed this way loads from
`Library/` when some installed profile lists the certificate ([research](research.md),
`research/dlopentest`). The companion's tests sign a fixture of our own on the Mac with a throwaway CA
and identity made at test time, and check the signature (the chain, the team, both code directories,
no entitlements blob). The dev script `apps/client/push-identity.sh <p12>` pushes an identity as the
companion will, and the test hook `SP_SIGN_TEST=<path in the app's home>` signs a copy of that file into
`tmp/` and loads it, logging `sign:` lines, and ends the launch. An update on the device (below) signs the client image.

The companion sends that identity (`DeviceIdentity.swift`), only to a device whose **Update Games on This
Device** is on (`updateGames.<hardware UDID>`, off by default; turning it on shows what's sent and how to
take it back first). Where the key comes from depends on the team: a free team uses the identity the
companion already signs the app with (**A**), and a paid team uses a Slashplayed certificate of its own
(**B**: until it's set up, a paid team sends nothing). The `signingSource` default (`A` or `B`) overrides
the team's choice for testing. For A, the identity is the built app's signer
(`Signing.signer`), exported from the login keychain with `SecItemExport` as a `.p12` (the identity
alone, as Keychain Access exports it: zsign takes the issuer from its own copies of Apple's WWDR
intermediates); macOS's export prompt is the consent, and a refusal turns the setting off. Each push has
a new random password; both files are written 0600 in a 0700 folder under `$TMPDIR`, copied with
`devicectl`, and zeroed and deleted at once, as `Pairing.swift` does with the pairing record. The
launcher writes what it holds to `Library/spidentity.txt` at every start (`present <day>`, `expired
<day>`, `none`, `forgotten`, or `unreadable`, the day being the certificate's last valid one in UTC), and
the companion decides from that, from the SHA-1 it last sent to the device (`identityPushed.<UDID>`, kept
on the Mac, with its source, A or B, in `identityPushedSource.<UDID>`), and from its own identity and that
certificate's last valid day (`DeviceIdentity.decide`): it pushes when the device has none, an expired or
unreadable one, or one whose day isn't its own certificate's, or when the identity to send isn't the one
sent last, and not while a push still waits for the launcher. The log says which change that was: the
source switched (the device gets B instead of A, or A instead of B), Xcode replaced A's certificate, or
there's a new Slashplayed certificate. Turning the setting off sends `Library/spidentity.forget`, which the launcher takes as
Settings' Forget. When the device says `forgotten` (Settings' Forget) after a push, the companion turns
the setting off instead of pushing it back, and forgets its record, so turning it on again sends the
identity again. Play and Update Client run this after the install; the `-push-identity` launch flag runs
it alone. Logs give sizes and the decision, never the `.p12`, its password, or the SHA-1. The companion's
tests check the choice of source, the default, the status lines, and each decision, and export a
throwaway identity from a keychain file of their own (never on the search list, deleted after): its
password opens it, the device's signer (zsign, on the Mac) signs a fixture with it, a missing identity
fails, and a refusal (macOS not allowed to ask) is reported as one.

B's certificate (`SlashplayedCertificate.swift`) is the person's to make, with the companion's help, in
Settings > Updates on Devices > Slashplayed Certificate (or `-certificate-request` for the first step). The companion makes an
RSA-2048 key in a keychain file of its own (`Application Support/Slashplayed/certificate/`, 0600, a new
name each time, since a keychain deleted and made again at one path stays the deleted one to the
process). That file is never on the user's search list, and Xcode and codesign look for identities only
there, so neither ever signs with it. Its random password is a generic password in the login keychain
("Slashplayed certificate keychain"). The keychain is unlocked only around each use, with macOS's prompts
off (a locked one would otherwise ask for its password), then locked again; it also locks itself after
5 minutes and on sleep. The key's access list is the default one, the copy of the app that made it, so
the export for a push asks nothing. Another copy, signed differently (a dev build and a release), is
refused every use with the prompts off, and the keychain's password can't change the list (that needs a
prompt), so a test signature finds it (`.otherCopy`) and Settings says to stop using the certificate and
make a new one. The request is PKCS#10 written by hand (`CertificateRequest`: subject CN=Slashplayed, which
Apple ignores, SHA-256 with RSA), saved to `~/Downloads/Slashplayed.certSigningRequest`. The same key
gives the same request, so asking again is harmless. The `.cer` the person downloads (DER or PEM) must
hold the key's public key, have the team ID as its subject's OU, and be valid now. It's then kept beside
the key. Before a push, some profile installed on the device must list the certificate (5.3: profiles are
device-wide, and installing one needs no reinstall). That's the app's own embedded profile, or one the
companion installed (`client-<platform>/certificate-profile.mobileprovision`, still listed by `devicectl
device profile list`). Otherwise the companion forgets Xcode's cached profile, builds the stub again so
Xcode fetches the team's current one (which lists every development certificate of the team), checks
it, and installs it with `devicectl device profile install`. If even that doesn't list it, nothing is
sent. **Stop Using the Slashplayed Certificate** deletes the keychain file and its password, and turns
the setting off for every device the certificate was sent to (`identityPushed.<UDID>` equal to its
SHA-1), so each device's next action sends it the forget marker. The tests make the store in `$TMPDIR`,
check the request with `openssl req -verify`, and issue certificates from a CA of their own with
`openssl ca`: the team's for the key is kept, and another team's, another key's, an expired one, and
garbage are refused. The export opens with its password with prompts off, and `lists` reads a profile of
their own.

With an identity on the device, the patch check's screen for a newer build that binds offers **Update**
beside Play Anyway (`patch: message: update here: …`; without an identity it's the screen above). Update
(`patch: Update`, which the companion follows as it does Play Anyway) fetches the build's configs (build,
CDN, and Retail's KeyRing: the bytes `BlizzardCDN.configData` gives, checked against their keys) into
`Documents/Data/config/` unless they're there, assembles the image from the kept slice, signs it, and puts
it in `Library/spgames/wow-<flavor>`, its stamp `spgames/spbuild-<flavor>` beside it, written last (an
older update's stamp is deleted first). On an iPhone that's under a second from a kept slice (configs
0.2–0.4 s, assembly 0.03–0.07 s, signing 0.2 s). The launcher then loads that image, and only once
`dlopen` has succeeded, before the client's entry point, writes `Documents/.build.info` with the
product's row for the new build (`sp_build_info_with`: the line `BlizzardCDN.buildInfoLine` writes, the
Tags kept from the device's row, the other products' rows kept), so a refused image leaves the old build's
row beside the old image. The image the launcher loads: the `Library/spgames` one when its stamp is the
patch service's current build, or when the service couldn't be asked and its version is later than the
bundled image's; otherwise the bundled one (`update: image: …`). When `dlopen` refuses the `Library/spgames`
image, the launcher deletes it and its stamp, says so on the screen for a few seconds (the helper is
attached by then, so nothing waits on the person), and loads the bundled image, leaving `.build.info`
alone; the next start offers the update again. The log has `update:` lines for each step (configs,
assembly, signing, the image chosen, which image loaded, the `.build.info` row), versions only. The test
hook `SP_PATCH_CHOOSE=<a button's title>` (passed by `run.sh`) presses that button on the patch check's
screen a second after it shows. The companion's tests hold the config store, `sp_build_info_with`, and
the version comparison (`sp_version_newer`) to the companion's own code.

The companion always installs Blizzard's current build, so an update the device made is either ahead of
the image just installed or caught up with by it. One rule decides which, on both sides: the bundled
image's stamp has the update's Build Key or Version, or a later Version (`sp_update_caught_up` in
`spcdn.m`, `ClientBuild.deviceUpdate` in the companion; the tests hold them to each other). The
launcher applies it at every start, before choosing an image (`retire_caught_up`): a caught-up update
is deleted, stamp first, and so is a kept slice (`Library/spslice/`) the bundled image has caught up
with (`update: retired …`). That's the launcher's own rule rather than an entry in `spdelete.txt`,
which only ever names game data, so it holds however the newer bundled image got there. The
`.build.info` row stays: the update wrote its build's, and the companion has written the bundled
image's by then if that's later. At Play, Update Client (and so a free team's weekly re-sign), and Copy
Game Files, once its image is installed, the companion reads the device's `Library/spgames` stamps
(`ClientBuild.deviceUpdates`: `Library` is listed whole, since `devicectl` fails on a folder that isn't
there, and each stamp beside its image is pulled) and logs which are caught up (the device deletes them
at its next start) and which are ahead. A game whose update is ahead keeps the device's `.build.info`
row and configs: its build is left out of what the files step writes, and a copy leaves the store
whole (`StoreKept.newerOnDevice`), as for a newer `.build.info` row (`GameStore.deviceBuildInfo`), so
nothing of an older build goes to it. The main window lists those games ("Classic Era 1.15.9.70003,
updated on the iPhone"), from `updatedOnDevice.<UDID>`, as the last action found them.

An update's image keeps the signature it was made with while the identity behind it can change: Xcode
replaces a free team's certificate (A) and the next install's profile lists only the new one, a
regenerated profile no longer lists the Slashplayed certificate (B), or the companion switches a device
from one source to the other. A reinstall (the companion's Play or Update Client, so a free team's weekly
re-sign) keeps the app's container and its keychain, so the image and the identity are both still there;
what can be missing is a profile that lists the image's signer, and `dlopen` refuses such an image as it
does an ad hoc one (5.3). So before the launcher chooses an update's image (`library_signed` in
`launcher.m`), it reads the certificates in the image's code signature (`sp_image_certificates`: the CMS
blob's certificate set, read with `read()`, never a mapping) and looks for one in the profiles the app can
see (`sp_listed_certificates`): its own `embedded.mobileprovision`, and `Library/spprofile.mobileprovision`,
a copy of the profile the companion installed for B (the system's list of installed profiles is
device-wide, but the app can't read it, so the companion copies the one it installed beside it; an expired
profile lists nothing). Listed: the image is chosen as before (`update: … is signed with a certificate the
app's profiles list`). Not listed: when the device's identity is valid and listed, the image is signed
again in place with it (`sp_sign`, into a new file renamed over it; `update: … signed again with this
device's identity in 0.2 s`); otherwise this start loads the bundled image and keeps the update, since a
later identity that's listed can sign it again (`update: … loading the bundled image, keeping the
update`). The identity itself counts as usable for Update only when a profile lists it too
(`sp_identity_usable`), so a device never makes an update that can't load, and the launcher's `identity:`
line says whether it's listed. The companion's tests sign a fixture with a throwaway identity and check
`sp_image_certificates` (the signer and its issuer; nothing for the linker's ad hoc signature, an
unsigned image, or garbage), `sp_profile_certificates` (a profile of their own, expired or not), and the
decision both ways, including the signature in place with a second identity of the team.

On the Mac, before each push and at every Play and Update Client, the companion checks that the identity
it would send still stands (`DeviceIdentity.standing`): its last valid day, and whether it was revoked.
macOS's own trust evaluation doesn't see a development certificate's revocation (SecTrust with an OCSP
revocation policy requiring a positive answer, and `security verify-cert -R ocsp -R require`, both still
called one trusted hours after it was revoked), so the companion asks Apple's OCSP responder itself, the
address the certificate names, with `/usr/bin/openssl ocsp`, and takes its answer only when its signature
verifies against the chain SecTrust builds (the WWDR intermediate and Apple's root). Only public
certificates are written, to a scratch folder deleted after. An expired or revoked identity isn't sent,
and the main window says so with the next step: for A, a new Apple Development certificate in Xcode,
then Play; for B, Stop Using the Slashplayed Certificate and make a new one (Settings shows a revoked or
expired B there too). When the answer can't be had (offline), it's logged and nothing changes. When Xcode
has replaced A's certificate since the last push, the push says so; if its export is refused, the main
window says that the device's updates may not load until it's sent. For B, every action (not only a push)
checks that a profile on the device still lists the certificate, installing the team's current one if
none does, and keeps the launcher's copy in place.

## Game data on the device

`Documents/` is laid out like the Mac's install: `.build.info`, the shared `Data/` (`config/` and
`indices/`, named by their content; the store: `data/` with its `data.NNN` archives and `.idx`
indexes, `ecache/`, and a folder of indexes per product), and each game's folder. Two writers can fill
the store: the companion's copy (`GameFiles.swift`) and the device's own client, which fetches whatever
its build needs and isn't there (an empty store, a patch's new content). Each keeps its archives and
indexes consistent with each other, but not with the other's: the client reads the newest `.idx` of
each bucket, so an index one wrote points into archives only it wrote. So the companion never mixes
them:

- **Without copying** (the default for a new device, and the only way without a game install on the
  Mac) it sends `.build.info` and the configs, plus each game's folder (`.flavor.info`, a first
  `Config.wtf`, the addons), and nothing of the store.
  The first launch from nothing sets itself up and reaches character select in about 2.5 minutes on the
  iPhone; after that the client fetches what each zone needs as it goes (`docs/research.md`).
- **With copying**, the store goes whole: every archive and index that differs, archives first and
  `.build.info` last, or none of it. It stays as it is, and the log and the files step say why, when
  the device's `.build.info` has a newer build of any product than its images (an on-device update
  put it there), when the Mac's install of a chosen game isn't the build of its image (Battle.net
  hasn't updated it to Blizzard's current one yet; the device's client fetches the difference
  itself), when it is but hasn't run on the Mac since Battle.net put that build there (its build
  config in `Data/config/` is newer than every file in the game's `Logs/`; `GameFiles.Unplayed`:
  Battle.net finishes a patched game's part of the shared store only after its next session on the
  Mac, and a copy before that quit TBC Anniversary on the iPhone with "Invalid schema … for Table
  StartupFiles"), or when the device's client has written an index since the last copy whose version
  outranks every one the Mac has for its bucket (`GameStore.outranking`). The Mac's configs and CDN
  indexes, named by their content, are copied either way. A store the device's client streamed is a
  few archives of its own, so the first copy after it sends the Mac's whole store again (24 GB for
  Classic Era); a store a copy made isn't re-sent, as the client doesn't touch the archives up to
  character select. The log says why each store file goes (`GameFiles.storeSummary`: how many are
  missing, another size, or the same size with another date, and the first of each with the device's
  size or date against the Mac's).

No order of the store's files leaves it readable if a copy stops partway: over a store the device's
client streamed, the copy replaces the client's archives before it sends the indexes that point into
them, and in between the client's own indexes, still the newest, point into the Mac's bytes. Every
game then quits about 3 s in with "Your World of Warcraft installation is damaged" (the iPhone,
2026-10-29). devicectl can't rename or delete, so the copy is made to finish instead: just before the
store's first file it writes `Library/spcopying.txt` saying `copying`, and once every copy has
succeeded, `done` (`GameFiles.copyMarker`). The next Play that finds `copying` finishes the copy
whether or not the device copies game files (only the ticked games' archives, as any copy), ignoring
the client's indexes (they can't be trusted over a half-copied store), or, with no game install on
the Mac or a store it can't copy (above), says why at the files step. The launcher won't load a game
over `copying`: it says the copy stopped and that a Play finishes it, before the sign-in, and it
deletes a `done` marker.

Either way the `.build.info` rows and configs come from Blizzard, not the Mac: for each game whose
image is Blizzard's current build, the row (`BlizzardCDN.buildInfoLine`: the version row's keys and
version, the cdns row's CDN columns, and the Tags of a US English install, or the Mac install's) and
the build, CDN, and KeyRing configs it names, so the device's data always names the build of its
image. The companion first reads the device's `.build.info`; a game whose image is older keeps the
device's row, as does a product whose build on the device is newer (by `Version`), which gets none of
the Mac's files (`GameStore.deviceBuildInfo`). `.flavor.info` is written by the companion too. Old
indexes are listed in `Library/spdelete.txt` only when the store was copied, and only ones older than
the device's `.build.info` (which carries a date no later than the last copy): an index the device's
client wrote is never deleted. `devicectl device copy` skips a file whose size and modification time
both match the destination's, so a `.build.info` the companion writes is dated a second after the
device's (or the Mac's, when the store goes), never the same.

## Shims

`shims/generated/` holds one Objective-C source per macOS library the client uses, generated by
`scripts/recon/gen_stubs.py` from the client's import table and the device SDK. For each import it
decides: exported by the device's library (re-export it), available elsewhere on the device
(re-export from there), or missing (a stub that logs its first call and returns zero; classes copy
macOS's superclass chain and answer any selector). Hand-written code is `#include`d into the
generated shims, and a function defined with `__asm__("_symbol")` replaces the generated stub. Of the
1,063 imports Classic Era has, 872 exist on visionOS 27 as they are, 10 exist with differences and 181
are missing; Retail adds a handful and MoP Classic two (`printf`, `vprintf`), all
available. The iOS SDK gives the same buckets.

The hand-written families:

| Directory | Library | What it does |
|---|---|---|
| `shims/system/` | libSystem | The JIT prepare and alias (above). Sandbox fixes: path redirection, shared memory, `SIGPIPE`. Tracing (`SP_SYSTEM_TRACE=1`). The device console log. |
| `shims/appkit/` | AppKit | `spuikit.m` (the event loop coroutine), `spwindow.m` (screen, window, view geometry), `spevent.m` (input), `spimage.m` (bitmaps, images, cursors), `sphover.m` (look highlights), `spstats.m` (play-session stats), `sploading.m` (the loading screen
until the client's first frame). `spnotice.m`, built into the CoreFoundation shim: the client's data setup dialog (below). |
| `shims/coregraphics/` | CoreGraphics | `spdisplay.m`: one display matching NSScreen; cursor association and warping for mouselook. |
| `shims/audio/` | CoreAudio, AudioToolbox | A fake HAL device, the macOS HAL output unit mapped to RemoteIO, and no microphone. |
| `shims/security/` | Security | The client's legacy CSSM crypto calls over CommonCrypto; Secure Transport logging; the bundled root certificates for the client's certificate query. |
| `shims/ident/` | CoreFoundation, Foundation, IOKit | Tracing of what the client reads about the machine (types, sizes and hashes only), a made-up network interface, and the small identity file login needs from the Mac. |

Also generated with real bodies: Carbon's text input source and hotkey queries (a US keyboard;
`UCKeyTranslate` in CoreServices), and AppKit's `NSBundle` nib-loading category, which the
import-table recon can't see (category methods on Foundation classes aren't imports; they show up as
`unrecognized selector` exceptions under `SP_SYSTEM_TRACE=1`).

**The data setup dialog.** When the client starts with game data it has to fetch first (an empty or
partial store, or a build whose content isn't on disk yet), it shows a progress dialog through
`CFUserNotification` ("performing initial setup of required data files", one button, Cancel), hides
its window, streams what it needs from Blizzard's CDN, and cancels the dialog when it's done. iOS and
visionOS have no alert server for apps: the real `CFUserNotificationCreate` returns a notification
that answers at once with Cancel, which the client takes as the person giving up, and it quit a few
seconds into every such launch. `spnotice.m` keeps the notification itself and never answers it; the
progress is logged (`CFUserNotificationUpdate: "60%"`) and shown on the launcher's loading screen
(`sploading.m`; see [One app, every game](#one-app-every-game)) while the dialog would be up (10 to 15 s for
Classic Era from an empty store on the iPhone). The client also looks up its
icon, `wow.icns`, for the dialog and throws on a nil path, so the app carries an empty `wow.icns`
(`build.sh` and `ClientAssembly` alike).

### Sandbox redirects

- **Install root.** The client treats the parent of its executable's directory as the game root and
  writes there (`WTF/`, `Logs/`, `Cache/`). That's inside the read-only app bundle on the device. The
  libSystem shim redirects every path under it, except the bundle itself, to
  `Documents/_<flavor>_/` (the game's own folder; `Data/` sits next to it), including `chdir`, so
  relative paths follow. Only libSystem calls are redirected.
- **Shared memory.** The sandbox refuses `shm_open` (`EPERM`). The client only shares these regions
  with itself, so the shim backs them with files in the app's `tmp/`.
- **`msync`.** The client syncs its game data index in 4 KB ranges, which a 16 KB-page system refuses
  unless the range starts on a page. A device streaming into an empty store syncs constantly, and with
  every sync failing, Retail on the iPhone sat at its download bar for good. The shim starts each range
  at its page.
- **`SIGPIPE`.** visionOS tears down a backgrounded app's sockets; the client's TLS close a few
  seconds later raised `SIGPIPE` and killed it. It's ignored.
- **Root certificates.** The client builds its trust store from a keychain query for certificates. A
  device app sees only its own keychain, so the query found nothing and every TLS connection to
  Battle.net failed. The companion exports the Mac's system root certificates into the app
  (`sproots.plist`), and the Security shim answers an empty certificate query with them.
- **Launch credentials.** Battle.net starts the Mac client with launch credentials for one login. For
  Play with My Mac's Battle.net (the fallback sign-in), the companion catches that launch, stops the
  Mac client, and moves the credentials to the device
  (`Library/spnetbattle.plist`). The launcher sees the file and skips the saved sign-in; just before
  the client loads, the AppKit shim imports them into the app's preferences and deletes the file. Values are never read, printed or logged; only sizes and timestamps
  are.
- **Sign-in on the device.** The unmodified client signs itself in, with no Battle.net, from a file in
  its game folder; it fills its own logon form from it, and asks for an authenticator's code in the
  game. The launcher (`splogin.m`) asks for the Battle.net email and password once, on a screen of its
  own (SwiftUI, `spsignin.swift`), and keeps them in the keychain (readable only while unlocked, this device only, never synced).
  It writes the file just before the client loads, after the JIT helper attaches, so a launch that
  stops earlier leaves nothing. The libSystem shim recognizes the client's open of it by the open file's
  path and deletes it, zeroed first, when the client closes it, the same second (the client never
  deletes it, and doesn't read it again). One still there when the process exits (`exit`, `_exit`, or
  `_Exit`, the client's or anyone's: a client that quits before reading it, as one with a damaged
  install does) goes then. A launch killed
  before either (a signal, or the system ending it) leaves one, and the launcher deletes any game's
  leftover at its next start, before the start screen. The client takes this path only when started with Battle.net's `-launcherlogin` option
  (without it, it reads the file and stops at its login screen), so Play passes the flavor's Battle.net
  arguments, less the credentials, and a launch from the home screen replays the last ones, else those.
  The file overrides relayed launch credentials (while it exists, even empty, the client takes that
  path), so a launch with fresh ones, which come only from Play with My Mac's Battle.net, writes no file
  and keeps the saved sign-in for the next launch. **Forget My Sign-In** in the start screen's Settings
  forgets the saved sign-in at the tap. The client's own typed login form doesn't work (see `docs/research.md`).

## The event loop coroutine

The client runs its own main loop on the main thread and pumps AppKit events from it. UIKit needs the
main thread too, and the system kills an app that hasn't brought up a scene about 20 s after launch.
So `spuikit.m` runs them as coroutines on one thread:

- `+[NSApplication sharedApplication]` starts `UIApplicationMain` on a stack of its own (8 MB), with
  a hand-written context switch of the callee-saved registers and the stack pointer. Each side keeps
  its own autorelease pool stack (objc's per-thread TSD slot is swapped with the stack).
- A `BeforeWaiting` run loop observer switches back to the client each time UIKit's run loop is about
  to sleep.
- The client's `nextEventMatchingMask:…` switches to UIKit for one run loop iteration when its event
  queue is empty; `-run` does the same in a loop.

The toy client pumps at ~59 fps for minutes with this. A watcher thread logs the main thread's stack
when the client hasn't pumped for 3 s, which is how spins in stubbed methods are found.

When the window closes (or the headset comes off, or another app is in front), the scene delegate
starts a background task, so the client keeps running and answering the server until the system
suspends it (~26 s seen). Nothing public gets a game more: after a longer stretch away the server
connection can drop (README's known issues). `terminate:` follows AppKit's
sequence (`applicationShouldTerminate:`, `applicationWillTerminate:`), and the client shuts down on
its own.

## Window, screen and scene tracking

There is one NSWindow, the size of the game rect in points, at the origin of one screen, so screen,
window and view coordinates are the same AppKit points. `-[NSView setLayer:]` puts the client's
`CAMetalLayer` in the UIKit window, over the game rect.

- **Game rect.** The UIKit window, except on an iPhone in landscape: there the Dynamic Island's side
  is cut off (`sp_game_rect`), and the strip beside the game stays black, so UI anchored to the
  screen's edge (quest log, spellbook, map) isn't under the island. The cut goes to the island's
  outer edge plus 4 pt (55 pt on a 16 Pro, where the island reaches 50.7 pt in), from the island's
  rect in UIKit's private screen exclusion area (`_exclusionArea`, read defensively); without a
  plausible rect it's the side's whole safe-area inset (62 pt). iOS reports the left and right
  insets the same, so the island's side comes from where the top of the portrait-up screen
  (`fixedCoordinateSpace`) lands in the window; the top and bottom (the home indicator, which hides
  itself) aren't cut. Turning the phone from one landscape to the other moves the game rect
  without resizing it: the layer, look highlights, and cursor move, and the client isn't told. Input
  is converted from the game rect; a touch, click, scroll, or hover that starts in the strip is
  outside the window and reaches no one, as beside a Mac window. An iPad and the headset keep the
  whole window.

- **Screen.** The client reads the display once at startup and caps its drawable at the display
  mode's pixel size. On visionOS the shim reports a fixed screen at least as big as any window
  (2560x1440 pt); on iPad, the real screen, landscape. CoreGraphics reports one display with the same
  size.
- **Scene tracking.** The client's event pump calls `sp_window_track_scene`. At first and after every
  scene resize it sets the window, content view and layer frames, then posts the resize notifications
  and delegate calls AppKit would after a live resize. The client responds by resizing its drawable.
  The layer is put back whenever it doesn't fill the game rect (the client sometimes makes a new
  full-screen layer after a reactivation, and moves its layer to its view's origin on the first
  resize), and an old layer is removed when the client sets a new one.
- **Render scale.** The backing scale: 1 renders a drawable the size of the window in points, 2 a
  Retina-sized one. 1x cuts GPU time sharply; see Heat below. The device owns it: the start screen's
  Settings > Display (Automatic, 1x, or 2x, in the app's `NSUserDefaults` as `sp_scale`) applies to
  every launch, from the companion or the home screen. `SP_SCALE` (`run.sh`) is a dev override that
  wins over it. Automatic is 2 on an iPhone (see iPhone, under iPad) and 1 elsewhere. The AppKit shim
  works it out once (`sp_backing_scale`), and the launcher's first-run 50% render scale on an iPhone
  asks the shim, so the precedence lives in one place.

## Input

The client takes input the standard AppKit way (overriding `sendEvent:`; its view handles key, mouse
and scroll events and `NSTextInputClient`), with no event taps. `spevent.m`:

- **Events.** `SPEvent`, an NSEvent subclass with real state, is queued for
  `nextEventMatchingMask:`. `sendEvent:` delivers keys to the first responder, mouse and scroll events
  to the content view, and mouse moves to tracking-area owners, as AppKit does. The first 60 key,
  click, and modifier events go to the device log as `input:` lines; `SP_INPUT_LOG_MAX` changes that
  (0 for no cap). They include typed text, chat too, so a raised cap is for diagnosis runs only.
- **Keyboard.** The scene's root view is UIKit's first responder. Presses become key events (HID usage
  to Mac key code, AppKit function-key characters, device-dependent modifier bits; modifier keys
  become `flagsChanged`). Key repeat is synthesized, since UIKit doesn't repeat. `interpretKeyEvents:`
  sends text to `insertText:replacementRange:` and editing keys to `doCommandBySelector:`.
- **Pointer and touch.** Touches and pinches become left clicks and drags, a secondary-button mask a
  right click; hover becomes mouse moves; a scroll pan becomes precise `scrollWheel:`. Each change in
  a pointer touch's button mask is a press or release, and GameController's `GCMouse` reports buttons
  too, because UIKit's mask misses a button released while another is held (both-button autorun).
- **Finger chords (iPhone and iPad).** Fingers that land within `SP_CHORD_MS` (50 ms) of each other
  press one button: one left, two right, three middle, held while they're down, so a two-finger drag is
  mouselook. No button goes down until the window closes (a press can't be taken back), so a left click
  waits out the window. The press is at the leftmost finger, or the rightmost with Settings > Touch.
  With Accessibility Zoom on, iOS holds three-finger touches about half a second before the app gets them.
- **Mouselook.** The client hides the cursor, dissociates it from the mouse and reads drag deltas. The
  CoreGraphics shim's cursor calls go to the AppKit shim; while dissociated, deltas come from
  `GCMouse`'s raw movement and the position stays put. iPadOS honours pointer lock, so it's on by
  default there; visionOS ignores it for a window.
- **Cursor.** The client sets its cursor with cursor rects. The shim rebuilds them, draws the cursor of
  the rect under the pointer as a UIView (the system pointer is hidden over the window), and scales
  it (`SP_CURSOR_SCALE`).
- **Look highlights (visionOS).** visionOS never tells an app where the user is looking, so the game
  gets no hover from gaze. The `SPHover` addon draws the rects of the visible clickable UI as a
  3-pixel strip of colored blocks along the bottom of the screen; `sphover.m` blits those rows out of
  each drawable in the client's own command buffer, decodes them, crops the strip out of the picture
  with `contentsRect`, and places clear UIViews with a `hoverStyle` over the rects. The system draws
  its gaze glow on those, out of process. Addons don't run on the login and character screens, so
  those get no highlights.
- **Skipping a cinematic by touch.** The game's movie frame leaves a movie only on a key (Escape,
  Space, or Enter opens its skip dialog, whose Yes and No are clickable). The `SPMovie` addon, on
  every device, has the frame take clicks and opens that dialog on one, so a tap does what Escape
  does. A cinematic can stay black on a device (GitHub issue #24), and without a keyboard this is the
  only way out of it. In game only, as addons are.

## Audio

- **CoreAudio.** The real HAL calls work in the sandbox but describe a device with no name that isn't
  in the device list, and they load macOS-style HAL plugins into the app. `spcoreaudio.m` answers the
  client's legacy HAL calls with one fake device with Mac-like values instead.
- **AudioToolbox.** The client asks for the macOS HAL output unit, which doesn't exist on visionOS or
  iPadOS; it gets RemoteIO. `CurrentDevice` is accepted and ignored, and a playback audio session
  (mixing with others) is set up first.
- **The RemoteIO sample-rate bug.** Before it's initialized, RemoteIO reports its output stream
  format with a **sample rate of 0**, where the Mac's AUHAL reports the device's (44.1 kHz,
  interleaved float). The client mixes at the rate it reads there. At 0 its mixer spent ~20 ms of CPU
  per 10 ms callback, the overrunning real-time IO thread garbled **all** audio on the headset (other
  apps' too), and the client eventually died. The shim reports AUHAL's format for RemoteIO units;
  callbacks now take ~0.08 ms.
- **Interruptions.** When the app goes to the background the system interrupts the session and
  RemoteIO stops. Nothing in the client restarts it, so the shim reactivates the session and restarts
  the units the client had started.
- **No voice chat, no microphone.** On the Mac the client runs voice chat in a separate helper app
  (`WowVoiceProxy.app`, with the Vivox SDK) that it launches at world entry and talks to across
  processes. The device can't launch it ([One app, every game](#one-app-every-game)) and the app
  doesn't bundle it, so the client reports it couldn't start it (VoiceError 14). The app has no
  `NSMicrophoneUsageDescription`, and without one TCC kills the process on any request for audio
  input, so nothing may ask: after the client loads, the launcher has the AudioToolbox shim make
  `AVCaptureDevice`'s permission calls answer "denied" for audio and video (an initializer is too
  early: AVFoundation installs its own methods over them), and the shim refuses input on an output
  unit and the voice-processing unit. The fake HAL device touches no hardware. Running the helper
  in-process is the way to real support ([issue #12](https://github.com/paulstraw/slashplayed/issues/12)).

## Metal and the metallib retag

Metal is the device's own; the shim adds the macOS-only device properties and device-observer calls
the client uses. The client's shader libraries are built for macOS with an old deployment target,
and visionOS and iPadOS refuse them: "This library format is not supported on this platform".

The cause is one bit (`research/metaltest`). The device rejects a metallib only when its container
header's macOS flag (bit 15 of the 16-bit target field at offset 4) is set **and** the container is
older than v2.6, the version that added an explicit platform field. Clearing that bit makes every
v2.2–v2.5 macOS container load, and both compute and render pipelines produce correct output. No hash,
UUID or bitcode needs changing, and v2.6+ macOS libraries load unmodified.

The client loads every library through `-[MTLDevice newLibraryWithData:error:]`, so the Metal shim
hooks that one method: for a `MTLB` container with the flag set and a version below 2.6, it clears
the bit in a **copy** and calls the original. Nothing on disk changes.

## iPad

iPadOS behaves like visionOS for everything above (TXM and the prepare, the metallib retag, the
bucketed imports and rewrite map), so the same generated shims are built for both platforms; only the
clang target differs. The differences:

- **Launch watchdog.** iOS kills an app that has no scene 20 s after launch (`0x8badf00d`), and the
  time spent waiting for and inside the debugger counts. So on iPadOS the launcher starts UIKit and
  waits for an active scene (~0.6 s) **before** it loads the client; the coroutine then takes over the
  already-running UIKit. visionOS is unchanged.
- **Screen.** Without `UILaunchScreen` in the Info.plist iPadOS runs the app in a 1024x768
  compatibility mode. The iPad Info.plist has it, and NSScreen and CoreGraphics report the real screen,
  landscape. The status bar and home indicator are hidden and edge gestures deferred.
- **Pointer lock** works, so mouselook locks the pointer by default.
- **No look highlights** (there's no gaze), so the `SPHover` addon isn't installed.
- **Storage.** Most iPads can't hold every game's data (Retail alone needs ~150 GB). The companion
  computes which storage archives the chosen games use (`GameStore.swift`) and, with copying on,
  copies only those; otherwise the game fetches only what it plays. MoP Classic's blocks
  (~23 GB) are spread over every archive of the Mac's store, so a copy of it takes all ~150 GB.
- **Frame rate.** The client isn't capped at 60 fps, so on a ProMotion iPad it renders at 120 fps.

Retail on the iPad needs ~150 GB free and 8 GB of memory. On an M2 iPad (8 GB, streaming from a fresh
start) it reached character select 58 s after launch and played at ~56 fps, with the footprint
peaking at 4.4 GB: a memory warning at 4.2 GB (4 GB left), thermal state `serious`, and a jetsam event
that killed another process, not Slashplayed. Its streaming wrote 4.3 GB in 13 minutes, which set off
iPadOS's daily disk-writes report (a report; no action taken).

**iPhone.** The same app and build as the iPad (device families 1 and 2), with these differences:

- **Landscape only** (`UISupportedInterfaceOrientations~iphone`); with rotation lock on it otherwise
  comes up portrait and cropped.
- **No system pointer.** iOS gives an app no pointer events for a mouse unless AssistiveTouch is on,
  and AssistiveTouch reports buttons unreliably both ways: a left click arrives as a touch of its own,
  the other buttons as a pointer touch whose mask can be stale, and `GCMouse` sees the left press late.
  So the left button comes from touches and the others from `GCMouse` (`spevent.m`).
- **No pointer lock**, so AssistiveTouch's pointer keeps moving during mouselook; deltas still come
  from `GCMouse`.
- **2x by default.** At 1x (874x402 on a 16 Pro) the UI's text is unreadable, though the 3D world
  looks fine. So the backing scale defaults to 2, and the first time each game runs on an iPhone at 2x
  the launcher sets the game's own render scale to 50% in its `Config.wtf` (once, so a change in the
  game's settings sticks): a sharp UI, with the world's GPU cost near 1x's.
- Supported from the iPhone 15 Pro (8 GB); only the 16 Pro is tested.

## Heat

Heat is the main limit on session length on the headset. Measured with the shim's `stats:` lines
(fps, GPU time per frame from command-buffer timestamps, CPU, memory, thermal state every 30 s):

- Uncapped, the client renders ~119 fps on the headset (the display reports 60 Hz) and reaches the
  `serious` thermal state after ~4 min, `critical` at ~86 min.
- Classic Era with an in-game cap of 90 fps: GPU ~11–13 ms per frame, CPU ~65–75% of one core;
  `serious` after 5.5–16.5 min.
- Retail at 2x: 75–86 fps, GPU-bound, `serious` at ~5 min. At 1x it holds ~89 fps with far less GPU
  time, but reaches `serious` just as soon (2.5–4.6 min, depending on the cool-down before). So the GPU
  isn't what dominates: CPU, the system's own compositing and the display are left. 1x is the default.
- iPad, Classic Era at 1x: 120 fps, thermal state nominal for the first minutes; long sessions get
  hot. The game runs uncapped by default; its Max Foreground FPS setting is the next lever.
- iPad, Retail: `serious` by about 6 min in (see the iPad section above).

## Logs and diagnostics

On the device the libSystem shim copies stderr to `Documents/spconsole.log` (older launches rotate
to `spconsole*.log`, five kept, with a clock time per line); devicectl's `--console` capture isn't reliable,
and a launch from the home screen has none. The launcher loads that shim first thing, so the log covers
the whole launch, the JIT helper and the pairing screen included, not only the client. The companion keeps its
own logs in `~/Library/Logs/Slashplayed/`, pulls the device's logs and crash and jetsam reports, and
Export Diagnostics zips them with launch credential values, device identifiers (UDIDs, serial numbers,
ECIDs, and the crash reports' device keys), and personal details (your name and signing certificates'
names, Xcode's teams and Apple IDs, the devices' and the Mac's names, and the user folder in paths)
blanked.
