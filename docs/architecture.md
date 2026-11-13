# How Slashplayed works

Slashplayed runs the unmodified Mac World of Warcraft clients (Classic Era, TBC Anniversary, MoP Classic, and Retail) on M1-or-later iPads and the A17 Pro iPad mini (iPadOS; untested on M1 and the mini), iPhone 15 Pro and later (iOS), and Apple Vision Pro (visionOS). It's a
compatibility layer: the client's own arm64 code runs natively on the device, and a set of shim
libraries stands in for the macOS frameworks it expects (AppKit, CoreGraphics, Carbon, CoreAudio,
Security, …), translating to UIKit, RemoteIO and friends. No game code is changed: the device loads
the game's own arm64 client, unchanged and unsigned, with a loader of Slashplayed's own, and no game
files ship with Slashplayed.

This page is the map. The experiments behind each technique are in [research.md](research.md).

## The pipeline

The Mac companion app (`apps/companion`) does all of this on the user's Mac, for whichever games
they've chosen for the device, whether or not the game is installed on the Mac:

1. **Build the app.** The launcher, the on-device JIT helper (`PlugIns/SPJitHelper.appex`), the shims,
   the shims' `exports.json` and `rewrite-map.txt`, the system root certificates (`sproots.plist`), the
   addons, the third-party licenses (`licenses/`), and the filled-in Info.plist and entitlements go into
   `Slashplayed.app` (`ClientAssembly.assemble`). The app holds no game. The companion makes or refreshes
   explicit-App-ID development profiles with the user's own team, one for the app and one for the
   helper (by building a tiny stub project with `xcodebuild -allowProvisioningUpdates`), signs
   everything, the helper before the app, and installs it with `devicectl`, unless the device still holds
   the install this Mac made of this build (`ClientBuild.installNeed`). There's one build per platform
   (`client-ios`, shared by the iPad and the iPhone, and `client-xros`), the same whatever games a device
   has: it's rebuilt only when the companion's resources, the bundle ID, or the entitlements change, or its
   profile is about to run out (`ClientBuild.isComplete`). A device's app may have been deleted there or
   installed from another Mac, so the companion keeps a record per device of the build it installed, and
   checks it against the app `devicectl` lists there: every install puts the app in a new folder, so one
   made since is told apart. Then it makes sure the app has what the helper needs (see [The on-device JIT
   helper](#the-on-device-jit-helper)), in its data container, which the install comes before.
2. **Fetch the client.** The companion asks Blizzard's patch service for each game's current build and
   downloads just the arm64 slice of that build's Mac client from Blizzard's CDN (`BlizzardCDN.swift`:
   one ranged request for the chunks that cover it, about 50 MB, each checked against its key, and
   cached in `~/Library/Application Support/Slashplayed/cdn/`). The dev script
   `apps/client/seed-client.sh` takes the same slice from the Mac's install instead, with `lipo -thin
   arm64`: for the same build it's the same bytes.
3. **Check binds.** Every import of the slice is looked up in the bundled `exports.json` (what each shim
   and system library exports, under the names the client gives its libraries). An import nothing
   provides means a game patch added something Slashplayed doesn't cover yet; the companion stops with a
   clear message instead of copying a client that would fail to load (`BindCheck.swift`).
4. **Copy the client.** The companion reads each game's stamp back from the device
   (`Library/spgames/spbuild-<flavor>`) and, when it's missing or older than the CDN's build, copies the
   slice, unchanged and unsigned, as `Library/spgames/wow-<flavor>`, then its `.build.info` row,
   `spsource-<flavor>` (`mac`), and the stamp last (`ClientBuild.copyClient`). A game patch comes to
   that: a ~50 MB copy, not a new app. A newer client the device fetched itself stays (see [Updating on
   the device](#updating-on-the-device)).
5. **Game data.** The client streams its own game data from Blizzard's CDN into the app's
   `Documents/Data/`, so all it needs to start is `Documents/.build.info` and, in `Documents/Data/config/`,
   the build, CDN, and key configs its row names. That's what the companion sends by default. **Copy Game
   Files from This Mac** (a per-device choice in Settings > Games, on for devices
   paired before it existed) copies the Mac's whole store instead, with `devicectl device copy`,
   incrementally (only files whose size or modification time differ; configs and CDN indexes, named by
   their content, only by size). When a device holds only some
   games, only the storage archives those games use are copied. See [Game data on the
   device](#game-data-on-the-device).
6. **Launch and load.** At every launch the helper, on the device, attaches to the app and services one
   stop, the JIT prepare described below, then detaches, and the launcher loads the client with spguest
   ([Loading the client](#loading-the-client-spguest)). The Mac isn't needed: a launch from the home
   screen works the same as one from the companion.

The entitlements are `get-task-allow` (a debugger may attach; development signing gives it),
`com.apple.developer.kernel.increased-memory-limit` and `extended-virtual-addressing` (Retail needs
more than the default ~5 GB limit; with them it's ~8 GB). A free Personal Team can't have
`extended-virtual-addressing` (Apple refuses the profile), so the companion leaves it out for one;
`increased-memory-limit` alone runs every flavor, Retail included. A free team's profile lasts 7 days,
and the companion re-signs within two days of that. A device set up by `slashplayed-companion`, or one
signed in to Apple in the launcher, renews its own profiles instead ([Renewing the app's
profiles](#the-on-device-jit-helper)), so it doesn't need the computer again for them.

Every third-party component that ships carries its license text, generated at build time from the
pinned sources. The device app's `licenses/` has idevice's with every Rust crate the JIT helper links,
spapple's with isideload and every Rust crate the launcher links, the Rust standard library's notices, and
Goodmountain's license (`goodmountain.txt`, from `scripts/fetch-font.sh`). `scripts/build-idevice.sh` and
`scripts/build-spapple.sh` each run `scripts/crate-notices.py` over `cargo tree` for the same features and
targets as their build, and fail on a crate whose source has no license text (spapple's also on a
GPL-family one); crates that declare MIT but ship no file get the text from
`scripts/crate-licenses/`. The companion's `Contents/Resources/Acknowledgements/`, linked from its About
panel and Help menu, has Sparkle's (a build phase copies it from the SPM checkout), idevice's as the
companion links it, and the device app's: idevice's and spapple's for each device platform, and
Goodmountain's. `AcknowledgementsTests` checks idevice's and spapple's notices against the crates the
archives' own symbols name.

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

So the client's rewrite is serviced through an alias mapping, by the launcher's loader and the libSystem
shim (`shims/system/spsystem.c`):

- The loader reserves the client's span before its code is in it, and asks the debugger, with one
  `brk #0xf00d` (the StikDebug-compatible protocol), to prepare all of `__TEXT` (`prepare_text` in
  `apps/client/spguestlaunch.m`). The debugger writes over every page (`research/jittest/jit.py`, mode
  `bulkx`: raw binary `X` packets, the fewest round trips), then detaches. The loader maps a read-write
  alias of `__TEXT`, copies the client's code in through it, and tells the shim where both are
  (`sp_set_client`).
- The client looks up its memory functions with `dlsym`. The shim's `dlsym` hides
  `pthread_jit_write_protect_np` (no `MAP_JIT` here), so the client takes its plain
  `mprotect`/`memcpy` path, and hands out the shim's own `mprotect` and `memcpy`.
- `mprotect` inside `__TEXT` returns 0 without doing anything, and the shim's `memcpy` writes into
  `__TEXT` through the alias. `__TEXT` itself is never writable.

A `brk` with no debugger kills the process, so the launcher waits for the helper's attach and checks
`P_TRACED` before the stop. The debugger is needed at every launch (the prepare can't happen after
detach).

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
3. **attach**: the helper attaches, and once the launcher sees `P_TRACED` it starts loading the client.
   The helper services the loader's prepare stop (one byte written to every 16 KB page of `__TEXT`,
   2,800 to 3,300 pages in about 0.1 s) and detaches (`guest: detached`, the line the companion's launch
   follows).

One more request, **profiles**, installs provisioning profiles through misagent over the same tunnel
(`com.apple.misagent.shim.remote`) and lists the device's: iOS opens an app on any valid installed profile
for its App ID, not only the one it embeds, so a renewed profile keeps the app opening with no re-sign
and no reinstall. The launcher's `sp_jit_profiles` hands over only the app's and its helper's own
profiles; the profiles drill (`SP_PROFILES_DRILL`, `run.sh`) tries it from files in
`Documents/spprofiles/`.

**Renewing the app's profiles** (`spapple.m`'s `sp_profiles_renew`) uses that request at every launch of a
game, after the sign-in and before the attach. When the app's or its helper's profiles have less than 3
days left (the earlier of the two: the embedded ones and the copies of earlier renewals in
`Library/spprofiles/`), the launcher asks Apple for new ones with the Apple token the device keeps
(`slashplayed-companion` pushes it, below, or the launcher's own sign-in makes it, next), through `spapple`,
a Rust static library on the vendored isideload
(`scripts/build-spapple.sh`). A free team's App IDs lapse 7 days after they're made, so one that's gone is
made again first, under the same identifier, with increased-memory-limit for the app's; the profiles
already on the device stay valid until their own day either way. The helper installs the new pair and
the launcher keeps copies. Nothing stops the launch: on a failure the profiles still have days left.
`Library/sprenew.txt` (`ok`, `failed`, `signin`, or `signedin`, with the time the app stops opening) is what
the start screen reads: it says under the logo when the next launch may retry alone (`failed`), or when the
token is missing or refused (`signin`), with the day and Sign In to Apple… under it; after a sign-in there
(`signedin`) it says the next launch renews. Settings shows Signed Until, Sign In to Apple… without a token
(or with a refused one), and Forget Apple Token with one. `SP_RENEW=now|off` (`run.sh`) forces or skips it.
Without a token and with no sign-in on the device (a Mac companion's install), nothing is renewed and the
companion re-signs as before.

**The launcher's Apple sign-in** is the token's other source, opt-in: the Mac companion signs through Xcode,
whose Apple session is in Xcode's own keychain group and bound to the Mac's anisette identity, so it has no
token to give a device (every Vision Pro is set up that way), and a pushed token Apple stops taking would
otherwise need a computer again. It's `slashplayed-companion`'s sign-in, run on the device: `spapple`'s
`login` op (isideload's GSA sign-in over SRP, its 2FA, and anisette from a remote-v3 server, by default the
same `mac-ani.jkcoxson.com`, with the same fixed client identity, which every later request then claims).
The login runs as a task in `spapple`; its 2FA callback parks until the next call (`login_answer`) brings the
code, a text to one of Apple's trusted numbers, or the Apple devices, so the screen (`spapplescreen.swift`)
can ask between calls. At the end `spapple` mints the `xcode.auth` token, checks with `listTeams` that the
Apple ID is on the team that signed the app (a token for another team renews nothing), and hands the token
to `spapple.m`, which keeps it as a pushed one. The password is typed on the device and used once: it's
held in `spapple` only for the sign-in (isideload signs in again with it after the 2FA code) and zeroed
when that ends, and never kept or logged (CLAUDE.md, "The Apple ID is a
credential"). The screen says plainly that this is a second sign-in through a third-party anisette server,
which sees the device's anisette identity but never the Apple ID, the password, or the token; the server
can be changed there, and the last one used is offered next time (`sp_anisette_url` in the app's defaults).

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

## Loading the client: spguest

visionOS won't `exec` or `posix_spawn` another executable from an app bundle, dyld won't `dlopen` an
`MH_EXECUTE`, and the system runs no code that isn't signed. So the launcher loads the game's client
itself, with spguest (`apps/client/spguest.c`, `spguest.h`, and `spguest_tlv.S`; its load step is
`spguestlaunch.m`), a loader of our own modelled on Tolkara's (MIT, github.com/tolkara/tolkara,
`runtime/`). The client is `Library/spgames/wow-<flavor>`, the arm64 slice of Blizzard's Mac file as it
is: no load-command rewrite, no retype, no signature. dyld never sees it. spguest:

- **maps** its segments into one reserved span. On the device `__TEXT` is prepared by the helper first and
  written only through a read-write alias ([above](#executable-memory-under-txm));
- **binds** it, applying the rebase, bind, lazy, and weak opcode streams (the clients' dyld-info fixups;
  lazy pointers are bound at load). Each library the client names is opened through the app's
  `rewrite-map.txt`, so the shims in `Frameworks/` take the macOS frameworks and the device's own
  libraries the rest, as the bind check assumed. An import nothing provides fails the load with its name;
- **registers** it with the Objective-C runtime (`_objc_map_images`, `_objc_load_image`) and the unwinder
  (`__unw_add_find_dynamic_unwind_sections`), so its classes, categories, `+load`, C++ exceptions, and
  NSExceptions work as from a dyld-loaded image, and serves its thread-locals through its own
  `__tlv_bootstrap`;
- runs its initializers and calls `main`.

Those three hooks are private. The launcher checks for them before the start screen
(`sp_guest_hooks_problem`), so a new OS that took one away says so before anything is downloaded. Before
the sign-in it checks the client's file with spguest's own parse of its header and load commands
(`spguest_check_file`, through `sp_guest_preflight`), so a file the device can't load (one with chained
fixups, say, which spguest doesn't apply) says why before anyone types a password, not after the helper's
attach. The start's retire and Update's check of a new slice use the same parse, so none of them passes a
file the load refuses.

**The client's questions about itself.** dyld never lists the client, so spguest answers for it: `dladdr`
and the `_dyld_*` image calls give it as image 0, named by its own file. Its `dlsym` and
`_NSGetExecutablePath` are the libSystem shim's, as for a dyld-loaded client; the executable path is the
launcher's, which the [install-root redirect](#sandbox-redirects) expects. The loader tells the shim where
the client and its `__TEXT` alias are (`sp_set_client`), so the shims' caller offsets and the `__TEXT`
services find it, and `sp_dladdr` names the client's frames (`wow-<flavor>+offset`) in the shims' stall,
render-callback, crash, and exception stacks, where dyld's `dladdr` has nothing.

**The self-`dlopen`.** Once, early in `main`, the client `dlopen`s the path `dladdr` gives for its own
code. Under dyld that returned the loaded image. For the client's own file, an unchanged `MH_EXECUTE`,
dyld refuses ("cannot dlopen a main executable") and the client goes on with NULL. spguest's `dlopen`
hook answers that path with NULL without asking dyld, in case a later dyld would load it. Every game has
played into the world that way; what the client keeps the handle for isn't known.

A load that fails after the attach ends the launch with spguest's reason (an unresolved import, an opcode
it doesn't know, a refused hook). A file in `Library/spgames` that isn't a client spguest can load (not an
arm64 `MH_EXECUTE`, cut short, or an image an older Slashplayed assembled there) is retired at the start
with its stamp, row, and `spsource` (`sp_slice_retire`), so the next Play or Update replaces it. Loading
through spguest costs nothing measurable against dyld, at startup or in play
(`research/guestloadtest/README.md`, "The dyld baseline"). Its test is the guest toy in
`apps/client/guesttest/`, a program of our own built like the client: CI runs its checks on the macOS
runner (`SP_GUEST_REFS=none apps/client/guesttest/build.sh mac`), which also shows the private hooks still
work there; the device runs are manual. The system's crash reports don't symbolicate the client, since
dyld doesn't list it; the shims' own crash and stall stacks name it.

## One app, every game

`Slashplayed.app` holds no game. Each game's client sits in the app's data container
([above](#loading-the-client-spguest)), and the app's main executable is a small launcher
(`apps/client/launcher.m`) that:

1. deletes the game files the companion listed in `Library/spdelete.txt` (devicectl can't delete
   files) and writes the device's free space to `Library/spfree.txt`: the figure Settings shows, which
   counts space iOS can clear, and the figure without it. Lockdown, all the Mac can read, gives only
   the second, so the companion adds the difference to lockdown's figure now (`FreeSpace.now`). It retires
   a `Library/spgames` file spguest can't load ([above](#loading-the-client-spguest)), and deletes the
   signing identity Slashplayed 1.4 and earlier kept on the device for its game updates (its keychain
   items and files; for two releases, `forget_identity`);
2. on iPadOS, brings up UIKit and waits for an active scene first (see [iPad](#ipad));
3. picks the game: the one the companion's Play or `run.sh` names (`SP_LAUNCH_FLAVOR`), else the one
   tapped on its start screen (`spstart.m`, every other launch, even with one game; its gear opens the
   app's Settings, [below](#the-start-screen-and-settings)). The names,
   their order, and Battle.net's arguments for each come from the app's `flavors.plist`
   (`apps/client/flavors.plist`, which `scripts/flavor.sh` and the companion read too). Every launch
   makes sure the game's `Config.wtf` has its region and languages (`portal`, `textLocale`,
   `audioLocale`), from the game's region ([below](#a-games-region)), adding missing ones and replacing
   empty ones (and, for a game the device decides the region of, replacing all three once Settings has
   moved it to another region): started by Battle.net, the client takes them from Battle.net's launch options, which
   nothing writes on the device, and with neither it opens a region picker the device can't show, exits,
   and saves the three empty, so every later launch would exit too. On a game's
   first launch on the device, it marks the intro movie as played in that game's `Config.wtf` (the
   setting the game writes itself once it has): a first session on an empty store sets up its data
   first, and the intro it starts then never asks the CDN for the movie's data, so it would wait on its
   download bar forever (the next session plays it at once). For a run nobody watches
   (`SP_SKIP_INTRO=1`: `run.sh`, the companion's `-skip-intro`), it also adds what answering Retail's
   Screen Narrator question writes. Only settings that are missing, so neither holds up the launch.
   A game with no client is installed first, and one with game data but no client gets its data's own
   build ([Installing a game on the device](#installing-a-game-on-the-device));
4. logs the client's build against the game data's, and asks Blizzard's patch service whether a newer
   build is out (both below); then, before the sign-in, checks that the client can be loaded (the
   preflight, [above](#loading-the-client-spguest)) and refuses to load the game over a copy of game files
   that stopped partway (`Library/spcopying.txt`, see [Game data on the device](#game-data-on-the-device));
5. puts up the loading screen (below), tells the libSystem shim which game folder is the install root,
   and loads the client with spguest, which calls its `main`.

Each client carries its build in a file beside it, `spbuild-<flavor>` next to `wow-<flavor>`: the
build columns of the game's `.build.info` row (`Product`, `Branch`, `Build Key`, `Version`), as a one-row
table of the same `|`-separated shape, so one parser reads both. The companion (`ClientAssembly.Stamp`)
writes it from the patch service's version row (`Region`, `BuildConfig`, `VersionsName`),
`seed-client.sh` from the install's `.build.info`, and the device from the row it fetched; for the same
build they write the same bytes. Beside them are the client's `.build.info` row (`spbuildinfo-<flavor>`),
which the launcher writes into `Documents/.build.info` before the client loads when the row there isn't
the client's build (`sp_build_info_for_image`), and `spsource-<flavor>`, one word for where the client
came from (`mac`, `updated`, or `installed`), which Settings shows and which says who decides the game's
region ([below](#a-games-region)). Every writer puts the stamp last, so a stamp is only ever beside a
whole client of its build. At each Play the companion asks the patch service for each of the device's
games' current build (about 80 ms each) and copies a client whose stamp is missing or older; if the
service can't be reached, the device's clients are played as they are. The launcher reads the stamp of
the client it's about to load and logs it against `Documents/.build.info`'s row for the product
(`build: image and game data are both …`, or `build: MISMATCH: …`): the client and the data are copied
separately, so after a patch one can reach the device without the other.

Then the patch check (`apps/client/sppatch.m`), before the sign-in and the helper: the launcher fetches
`https://<region>.version.battle.net/v2/products/<product>/versions` (the same `|`-separated table
shape, one row per region; the region is the game's, [below](#a-games-region): the stamp's `Branch` for a
game the Mac copied) and compares that region's `BuildConfig` with the stamp's `Build Key`. The same
means nothing shows. A different one means Blizzard has a newer build out than the client, so a screen
says so, first finds out whether this Slashplayed can run it at all, and offers to update it on the
device ([Updating on the device](#updating-on-the-device)). The device fetches the new build's client
from Blizzard's CDN the way the companion does (`apps/client/spcdn.m`, the port of `BlizzardCDN.swift`: build config, install manifest, one encoding page, then one ranged request for the
chunks covering the arm64 slice, everything checked against the key that names it; about 45 MB, 3 s on
an iPhone on Wi-Fi), the sibling `/cdns` table giving the servers. On cellular, a hotspot, or Low Data
Mode it asks first (**Download** or **Not Now**). Then it checks the slice's imports against the
`exports.json` the app carries (`build.sh` and `ClientAssembly` both copy it into the app): the device
has no `dyld_info`, so `apps/client/spbind.m` reads the imports from the Mach-O itself, from either kind
of fixup info (bind opcodes, which the clients have, or chained fixups), leaving weak imports out as
`BindCheck` does. The companion's tests hold it to `BindCheck`'s answer on fixtures of both kinds and,
opt-in, on every build the untethered research kept. It binds: "<Game> <version> is out. This iPhone
can update itself in a few seconds.", with **Update**. It doesn't: "This patch needs a Slashplayed
update." It couldn't tell (the download failed, Not Now, an app without `exports.json`): "Whether
Slashplayed can run it couldn't be checked." Each has **Play Anyway**, which goes on with the client it
has; the companion follows the screen as a wait on the person (`patch: showing the newer-build screen`,
`patch: Play Anyway`, `patch: Update`). The slice stays in `Library/spslice/<flavor>.arm64` with its own
stamp (`spbuild-<flavor>`, written once the slice is whole), so a later launch for the same build doesn't
fetch it again, and Update takes it from there. A check that can't be made (offline, a timeout, no row)
goes on without a word: the service fetch has a 3 s budget, and a refused connection fails at once. The
log has a line for each step, versions only (`patch: up to date: …`,
`patch: newer build out: …`, `patch: slice: …`, `patch: imports: N of M resolve …` and any `UNRESOLVED`
ones, `patch: message: update here: …` or `patch: message: needs a Slashplayed update: …`,
`patch: couldn't check …: going on`). `SP_PATCH_SERVICE` (passed by `run.sh`) replaces the base URL
for tests: a URL, or a path in the app's home directory read as files (`Library/sppatchtest` with
`Library/sppatchtest/<product>/versions` copied in by `devicectl`; a `cdns` file beside it is optional,
the real service's is used without one, so a row naming a real build tests the whole check).
`SP_PATCH_CELLULAR=1` makes it ask, as on cellular.

The loading screen (`shims/appkit/sploading.m`, in the AppKit shim; the launcher calls
`sp_uikit_loading` with the game's name) covers the time from the load to the client's first
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

All games share one app container, so the shared `Data/` store is copied once.

A game install on the Mac is optional, and so is Battle.net. The companion's pipeline doesn't read the
install; it's the source of two choices only: **Copy Game Files from This Mac** (step 5) and **Play with
My Mac's Battle.net** (see [Sandbox redirects](#sandbox-redirects)), which the menu by Play offers only
when one of the device's games is installed. The small identity file login needs from the Mac needs no
install. Onboarding (`Onboarding.swift`) requires Xcode, the team, the device, LocalDevVPN, and a game
per device; its last step lists what the Mac has installed and always passes. The dev script
`apps/client/build.sh` builds the app as the companion does, with no game in it; `seed-client.sh` copies a
game's client from the Mac's install, and `seed.sh` its game data.

### The start screen and Settings

Every launch that doesn't name a game (a launch from the home screen) opens on the start screen
(`spstart.m`, its screen in SwiftUI, `spstartscreen.swift`): the app icon's medallion and a framed
button per game in `flavors.plist`'s order, all drawn in code (**Install <game>** for one the device
has nothing of yet, [below](#installing-a-game-on-the-device)). Its face is Goodmountain, which the app
ships unmodified with its license (`scripts/fetch-font.sh`; it's never committed). The gear opens
Settings, a stock dark inset-grouped sheet in SwiftUI (`spsettings.swift`), one for iOS and visionOS:

- **Battle.net**: whether a sign-in is saved; **Show Email** (the one place the saved email is shown,
  read from the keychain inside `splogin.m` at the tap and hidden again when the app goes to the
  background, the sheet closes, or a game starts); **Forget My Sign-In**; or, with none saved,
  **Sign In…**, which presents the sign-in screen to save one ahead of time.
- **Display**: Scale, Automatic, 1x, or 2x, the backing scale for every launch on this device (Render
  scale, under Window, screen and scene tracking).
- **A section per game**: the build it starts with and where its client came from, from
  `spsource-<flavor>`: "From your Mac", "Updated on this device", or "Installed on this device" (a client
  with no word, which none of today's writers leaves, reads as the device's own); "Not Ready" for one
  whose next start gets it ready, and "Not Installed" for a game the device has nothing of
  ([below](#installing-a-game-on-the-device)). Then its **Region** (a picker for a game the device decides
  it for, the Mac's named for one the Mac copied: [A game's region](#a-games-region)),
  **Open in Files**, and **Reset Game Settings**, which deletes the game's
  `WTF/Config.wtf` and `Library/sprenderscale-<flavor>` so the next start seeds them as on a first
  launch (the region and languages too); `WTF/Account/` (keybindings, macros, addons' saved settings) is kept.
- **About**: the app's version and Acknowledgements, the files in the app's `licenses/`.

`Info.plist` has `UIFileSharingEnabled` (Finder on a Mac browses `Documents/`) and
`LSSupportsOpeningDocumentsInPlace`, so all of `Documents/` shows in the Files app too. Open in Files
opens the game's folder, `Documents/_<flavor>_/`, with its `shareddocuments://` URL (the folder's path),
or `Documents/` before the game's first start makes the folder. That exposes `Data/` (a deleted archive
or index leaves the store unreadable: "installation is damaged") and, for the moments it exists, the
game's `login.txt`; both were weighed and accepted: the files are the person's own, on their own device.

The forget and the reset act at the tap, after a confirmation whose default is Cancel.

A dev-only drill opens the screen in a given state, so each can be screenshotted without taps:
`SP_START_DRILL=<state> apps/client/run.sh`. `run.sh` alone passes it (a home-screen launch has no
environment), and it launches with no console. The states are `settings`, `display`, `games`, `about`,
`sign-in`, `sign-in-launch`, `vpn`, `pair`, `pair-code`, `acknowledgements`, `license-<file>` (e.g.
`license-rust-std`), the confirmations `alert-forget-signin` and `alert-reset`, and `reset-<flavor>`, which resets
that game's settings with no confirmation, for a test, `scale-<0|1|2>`, which saves that Scale
(0 is Automatic), `files-<flavor>`, that game's Open in Files tapped, and `region-<flavor>-<region>`, that
game's Region picked. `SP_START=1` shows the start screen alone, and
`SP_START_TEXT_SIZE=<XS…XXXL, AX1…AX5>` sets its Dynamic Type size.

## Updating on the device

When Blizzard puts out a build newer than the device's client of a game, the device can take it itself,
with no Mac and nothing to sign, since spguest loads the new slice as it loads any. That works on every
team, free ones included. The chain, all in the launcher, between the patch check and the load:

1. **Find it.** The patch check sees the service's build differ from the client's stamp, fetches the new
   build's arm64 slice from the CDN into `Library/spslice/` (`spcdn.m`; on cellular it asks first), and
   checks its imports (`spbind.m`), as [above](#one-app-every-game).
2. **Offer it.** The build binds: the screen offers **Update** beside Play Anyway. Otherwise it's Play
   Anyway alone, with why.
3. **Take it.** Update fetches the build's configs (build, CDN, and Retail's KeyRing: the bytes
   `BlizzardCDN.configData` gives, checked against their keys) into `Documents/Data/config/` unless
   they're there. Then, in `Library/spgames/`, it renames the kept slice to `wow-<flavor>` (one volume, so
   nothing is copied), writes the build's `.build.info` row (`spbuildinfo-<flavor>`) and `spsource-<flavor>`
   (`updated`), and the stamp last. Nothing is assembled or signed. The configs go first: they're named by
   their content, so they're harmless to the old build, and a failure leaves the old client. So does a
   rename that fails: the old client's stamp goes back. A write that fails after the rename leaves the new
   client with no stamp, which nothing loads; the old one is gone then, so there's no Play Anyway, and the
   next start gets the game ready.
4. **Load it.** Just before the client loads, the launcher writes the kept row into
   `Documents/.build.info` (`sp_build_info_for_image`, through `sp_build_info_with`: the line
   `BlizzardCDN.buildInfoLine` writes, the Tags kept from the device's row, or for a game the device
   decides the region of, its region's, [below](#a-games-region); the other products' rows kept). It does
   so at every start whose row isn't the client's build, not only the one that updated, so a start that
   ended before the client loaded (at the sign-in, say), or game data emptied under the client, doesn't
   leave the client streaming with no row for its build (#134, "Invalid schema … for Table StartupFiles",
   issue #36). The client then streams the build's new content itself, as it does into an empty store.

Play Anyway leaves the client in `Library/spgames` untouched and the slice kept for a later Update. Once
the client has caught up with a kept slice (`sp_update_caught_up` in `spcdn.m`: the same Build Key or
Version, or a later Version), as after the companion copied that build or a later one, the launcher
deletes the slice, stamp first, at its next start (`retire_caught_up`, `update: retired …`). The log has
`update:` lines for each step (configs, the client chosen, the `.build.info` row), versions only. The test
hook `SP_PATCH_CHOOSE=<a button's title>` (passed by `run.sh`) presses that button on the patch check's
screen a second after it shows. The companion's tests hold the config store, `sp_build_info_with`, and the
version comparison (`sp_version_newer`) to the companion's own code.

The Mac and the device write the same files, so either can be ahead, and the device is the record. At
Play, Update Client (and so a free team's weekly re-sign), and Copy Game Files, once its app is installed,
the companion reads the device's stamps and `spsource` words (`ClientBuild.deviceClients`: `Library` is
listed whole, since `devicectl` fails on a folder that isn't there, and each stamp beside its client is
pulled) and compares each with Blizzard's current build (`ClientBuild.clientCopy`, by the same rule as
`sp_update_caught_up`; the tests hold them to each other). Missing or older: it copies the slice, stopping
a client running on the device just before the first write, since that maps its file (once the slice is
downloaded and binds, so a download or a patch that fails leaves a game being played alone). Newer (the device updated or installed it
ahead of the patch service the Mac asked): it's kept, and so are its game data's `.build.info` row and
configs. Its build is left out of what the files step writes, and a copy leaves the store whole
(`StoreKept.newerOnDevice`), as for a newer `.build.info` row (`GameStore.deviceBuildInfo`), so nothing of
an older build goes to it. The main window lists those games ("Classic Era 1.15.9.70003, updated on the
iPhone"), from `updatedOnDevice.<UDID>`, as the last action found them.

What the device holds for it, all in the app's container:

| What | Where | Written by | Gone when |
|---|---|---|---|
| A game's client | `Library/spgames/wow-<flavor>`, its stamp `spbuild-<flavor>`, its `.build.info` row `spbuildinfo-<flavor>`, and `spsource-<flavor>` | the companion's copy (`mac`), Update (`updated`), or an install (`installed`) | a newer build's replaces it, or it isn't a client spguest can load |
| A newer build's slice | `Library/spslice/<flavor>.arm64`, `spbuild-<flavor>` | the patch check | Update takes it, or the client catches up with it |
| A device-decided game's region | `Library/spregion-<flavor>` | an install or Update, and Settings' Region | never (it outlives the client, so an install again keeps it) |
| The build's row and configs | `Documents/.build.info`, `Documents/Data/config/` | Update's configs, and the launcher's row before a load whose row isn't the client's build | a later build's are written |

### Installing a game on the device

The same chain installs a game the device has no client of, so a host that installs only the app (the
[host tool](#the-host-tool-no-mac)) needs nothing else, and no game install on the Mac.

- **The games.** The start screen offers every game in `flavors.plist`. One the device has nothing of
  reads **Install <game>** (`sp_games`, in `spcdn.m`), and Settings says "Not Installed".
- **The install.** Tapping one runs `sp_patch_install` (`sppatch.m`) before anything else for that game,
  on the patch screen: the patch service's current build, the slice and its bind check (asking first on
  cellular), and the update's configs, row, client, `spsource` (`installed`), and stamp into
  `Library/spgames/`. Nothing is signed, so it works on a free team. It installs in the game's region
  ([below](#a-games-region)), which the screen names ("Installing Classic Era for Europe…"). Any failure
  shows why with **Back**, which returns to the start screen; a launch that named the game
  (`SP_LAUNCH_FLAVOR`) stops on the reason instead. The log has `patch: install: …` lines, versions only.
- **Getting a game ready.** A game with game data but no client (the first start after upgrading from a
  Slashplayed that bundled its clients, whose images were retired) runs the same chain for the data's own
  build, not the current one ("Getting Classic Era ready…", 50 to 58 MB), and keeps the data's region. If
  that build can't be downloaded (the CDN no longer serves it, say), it gets the current one instead, which
  streams its content over the data's as after Update. The patch check after it offers any newer build as
  usual. A Mac's next Play copies the same client, if it gets there first.
- **After it.** The launcher loads the new client, writing `.build.info` from its kept row first, as after
  Update; the client then sets up its empty store and streams.

The small identity file login needs from the Mac isn't part of the install. The companion still sends it,
for the Battle.net launch credentials it moves from the Mac. A device that signs in itself doesn't need it:
the host tool's install reached character select without one (iPhone, free team, 2026-11-01). The addons are the app's own (below), so an installed game has them too.

### A game's region

Each game has its own region and languages, as Battle.net does it (`sp_game_region` in `spcdn.m`, read at
each start by `sp_game_region_now` in `launcher.m`). Who decides depends on where the game came from:

- **A game the Mac copied** (`spsource` `mac`: the companion copied its client, and syncs the Mac's game
  data): the Mac does. Its `.build.info` row's Branch and Tags, which the companion sends again at every
  sync, else the client's stamp. Settings names the region and says to change it in Battle.net on the Mac.
- **A game the device decides** (installed or updated here, so it has a region file, or with no game
  data yet, and not the Mac's): the device does,
  from `Library/spregion-<flavor>`, a one-row table of the region, its text and speech locales, and the
  locales the build ships. The install writes it: by default the device's region in Settings mapped to
  Blizzard's (`sp_region_for_country`: the Americas and Oceania `us`; Europe, Russia, the Middle East, and
  Africa `eu`; Korea `kr`; Taiwan, Hong Kong, and Macao `tw`; anything else `us`, never `cn`, `sg`, or `xx`),
  and the device's first preferred language that region has a locale for (`sp_region_locale`: us enUS esMX
  ptBR; eu enUS deDE esES frFR itIT ruRU; kr koKR; tw zhTW), else the region's default. Speech follows text.
  Europe's English is `enUS`, as Blizzard ships it: the clients have no `enGB`, and one set to it opens the
  region picker the device can't show, and exits (issue #88), so an `enGB` that 1.4 or 1.5 wrote reads as `enUS`.
  The slice download reads the build's install manifest, so the locale is checked against the tags it lists
  (`sp_locale_shipped`; Classic's have no itIT).
  Settings' **Region** picker rewrites the file; nothing else does but an install or Update.

Everything else follows that file at each start, so a change isn't put back by a copy written before it:
the patch check's region, an Update's kept row (its Branch and Tags, `sp_region_tags`) and stamp, the
start-time `.build.info` rewrite (which also writes the row again when it's in another region,
`sp_build_info_for_image`), and `Config.wtf` (`sp_config_with_region`). Before the client is chosen the
launcher moves the kept row and stamp into the region (`region_sync`, `region:` lines). The stamp's Branch
stays, but decides nothing for these games. Tags are Battle.net's layout without its `acct-` and `geoip-`
tags, which no install manifest lists. `SP_REGION_COUNTRY` and `SP_REGION_LANGUAGES` (`run.sh`) stand in for the device's
region and languages in tests, and the Settings drill `region-<flavor>-<region>` picks one.

### The addons

The device app carries the addons, `addons/SPMovie/` and `addons/SPHover/` (their `.toc` and `.lua` as
`addon/` has them; `apps/client/build.sh` and the companion's `ClientAssembly` both bundle them, on both
platforms). Before each start, once the game is picked, the launcher puts them in the game's
`Interface/AddOns/` (`sp_addons_place` in `spcdn.m`): SPMovie on every device, SPHover on the headset only
(the iPad and iPhone have a real pointer), each file written when the game's copy is missing or its bytes
differ (`addons: N up to date, wrote …`). Each TOC lists every flavor's Interface number, so one copy
suits each game. The companion used to copy them with the game files; it doesn't any more, and a changed
addon reaches a device with the rebuild the companion's resources digest asks for (`ClientBuild`).

## The host tool (no Mac)

The Slashplayed Companion for Windows and Linux (`apps/companion-rs`, Rust: the window, `slashplayed-companion`,
and the command line, `slashplayed-cli`, on one library) sets up an iPad or iPhone from Windows, Linux, or a Mac
without Xcode. It does what the companion does with Xcode and devicectl, and nothing the device does for itself:
the device installs and updates games, picks their region, and writes `.build.info`, `Config.wtf`, and the
addons. **Vision Pro stays Mac-only:** there's no public visionOS developer disk image besides Xcode's, and
pairing a headset without a Mac is unproven. The tool refuses a headset.

One run, of the window or of `slashplayed-cli [install]`, which also signs the app again whenever the device can't renew
its own profiles:

1. **The device kit** (`src/kit.rs`): the device app, unsigned and, like every build of it, with no game
   in it, one per platform, which `scripts/release/device-kit.sh` assembles at release from what
   `bundle-resources.sh` stages, as `ClientAssembly.assemble` does. Only the bundle ID is left to fill in
   (`@BUNDLE_ID@` in the two Info.plists), plus the entitlements templates. A release build has the kit's SHA-256 compiled in
   (`build.rs`, `SP_KIT_SHA256`) and downloads it from its own GitHub Release; `--kit` names a local one.
   The kit comes first, so a bad download doesn't cost a sign-in.
2. **The device** (`src/device.rs`), over USB through usbmuxd: Apple's driver on Windows (Apple Devices or
   iTunes), the `usbmuxd` service on Linux, macOS's own on a Mac. If this computer isn't trusted, the tool
   pairs (lockdown `Pair`; the person taps Trust) and saves the record with usbmuxd, as Finder or iTunes
   would. If Developer Mode is off, the tool reveals it in Settings (amfi); the window then waits through
   the device's restart and Turn On, while `slashplayed-cli` stops and is run again.
3. **The Apple ID** (`src/account.rs`), through the vendored isideload: GSA over SRP, 2FA, anisette from
   `mac-ani.jkcoxson.com` by default (`--anisette` for another). The password is typed, used for the one
   login, and zeroed. The whole login lives in memory and ends with the process (owner decision), so
   each run asks again. No tracing subscriber is installed, and `DEBUG_SENSITIVE` is cleared at start.
4. **Provisioning** (`src/provision.rs`), isideload's low-level developer-services API, not its
   `Sideloader`:
   - The device is registered.
   - The App IDs `<bundle id>` and `<bundle id>.helper` are found, or made only when missing and the
     team has room.
   - Capabilities are set in one v1 PATCH: increased-memory-limit, plus extended-virtual-addressing,
     which Apple refuses a free team. Its answer was checked on the iPhone with both teams (2026-11-02): a
     free team gets 403, a paid one a 2xx. Any other status stops the run, rather than signing a paid
     team's app as a free one's.
   - The certificate is one whose public key is this computer's.
   - Both profiles are downloaded and checked: application-identifier, the device, our certificate, and
     the entitlements.
   - Free or paid is the profile's call (`IsFreeProvisioningProfile`, or a 7-day life): listTeams has no
     flag for it.
5. **Signing** (`src/sign.rs`, `zsign/`): zsign, compiled in by the spzsign crate (`zsign/build.rs`) from
   the source `scripts/build-zsign.sh source` patches, with OpenSSL 3.5 from openssl-src. It's a crate of its
   own, at a fixed version, so a release's version bump doesn't rebuild OpenSSL.
   - Each bundle is signed with its own profile and the entitlements the Mac signs it with: the kit's
     templates, less `Signing.freeTeamDropped` on a free team. A profile's own entitlements carry more
     (keychain-access-groups).
   - The key, certificate, and profiles go to zsign in memory (`zsign.patch`'s `InitData`).
6. **Install** over USB: an IPA built from the signed folder, with the Unix modes set by the tool so a
   Windows build is the same, through installation_proxy. That updates in place and keeps the container.
7. **Into the container** (house_arrest, AFC):
   - The RemotePairing record (`Library/sppairing.plist`, as `Pairing.send`), when the app has none or
     with `--pair-again`.
   - The developer disk image (below).
   - The Apple token as `Library/spappletoken.json`, every run: the `xcode.auth` app token from this
     sign-in, its adsid, and the anisette server and machine identity it was made on
     (`account::device_token`). The launcher imports it into its keychain (`spapple.m`) and gets the app's
     renewed profiles from Apple with it. Not with `--server-client-info`, whose client identity the
     device doesn't claim.

   Nothing else: the device installs and updates games with no credential on it. The token is only for
   the app's own profiles.

**The signing key** stays between runs in the OS credential store, never a file: the macOS Keychain,
Windows Credential Manager, or the Secret Service on Linux (`src/keystore.rs`). There's one item per
Apple ID, and it's stored before Apple sees a request for it. With no store (a Linux box with no Secret
Service), each run makes a new key and certificate. At the team's certificate limit, the tool revokes
the oldest certificate a Slashplayed tool made (machine name "Slashplayed companion", the earlier "Slashplayed setup", or the spike's
"Slashplayed spike"), and never anyone else's. Xcode's Manage Certificates lists only Apple Development
certificates, not the "iOS Development" kind these are, so this is the only way such a slot comes back
without a paid team's developer site.
- With no store, the tool can't find its certificate again next run, so it would reach the limit every
  run and keep revoking, possibly another computer's certificate (that computer's device then won't open
  Slashplayed until it runs again). So without a store it asks first: the window shows the certificates
  with Revoke and Cancel, and `slashplayed-cli` stops at the limit and revokes only with
  `--revoke-oldest`. With a store it revokes without asking, at most once per computer.

**The developer disk image** (`src/ddi.rs`). Owner decision (2026-11-01): with no Xcode on the host, the
iOS cryptex comes from the `doronz88/DeveloperDiskImage` mirror at run time, from a pinned commit, each
file checked against a pinned SHA-256. Slashplayed never hosts it. The files go to `Library/spddi/` as
`DeveloperDiskImage.swift` puts Xcode's, with `version.txt` last.
- The pin is the mirror's image as published: Xcode 27 beta's build 27A5228h. The owner chose it over
  waiting for 27B52 to be published.
- On a device the Mac companion set up, `version.txt` names Xcode's image, so the tool replaces that copy
  with the mirror's, which may be older (27A5228h in place of a local Xcode's 27B52). That's fine: the
  helper mounts only when no image is installed, and the mirror's mounts on every iOS version that Xcode 27
  supports. The next Play from the Mac copies Xcode's back.
- The device still trusts only Apple's signature. The helper has the image personalized by Apple's TSS
  for the device before mounting it.
- Checked on the iPhone 16 Pro (iOS 27.0.1, 2026-11-02): with no image installed, the helper mounted the
  mirror's copy (`com.apple.MobileAsset.DDI 27.1.5228.8`) in 1.7 s, then attached and prepared as usual.
- On iOS 27 the image is a cryptex that stays installed across restarts: a device needs one once, not
  after every reboot. Testing this on a Mac needs care, because CoreDevice installs Xcode's own image
  whenever devicectl starts a developer service (`apps/client/run.sh` does). Remove the installed one
  with idevice's `cryptexd uninstall com.apple.MobileAsset.DDI`, then launch from the device, unplugged.

**Credentials** follow the companion's rules:
- The pairing record goes from idevice's memory straight to the device over AFC, so it never touches the
  host's disk.
- Logs give sizes only. The scratch folder (private, deleted at exit) holds only the kit, the app, and
  the IPA.

**isideload is vendored** (`apps/companion-rs/vendor/isideload`, `VENDORED.md`, `isideload.patch`).
- Upstream links its LGPL-2.1 signer, apple-codesign-quick, unconditionally. A static binary would then
  carry the LGPL's relinking terms, so the vendored copy puts the signer behind an off-by-default feature.
- `scripts/check-tree.sh` checks that the signer stays optional and that the idevice pin and version
  agree with the rest of the repo.
- `scripts/crate-notices.py --deny-copyleft` fails a release build that links any GPL-family crate.

**Releases.**
- **Every `v*` release, labeled experimental** (owner decision, 2026-11-12): `release.yml` attaches the kit
  to the release, then builds the tool against it for Linux x86_64
  and aarch64 and Windows x86_64 (`companion-rs-build.yml`). The Windows `.exe` is unsigned (owner decision),
  so each archive gets SHA256SUMS lines and a build-provenance attestation.
- `apps/companion-rs/package.sh` packs each archive with its notices: the crates, the Rust standard library,
  zsign, OpenSSL, and zlib/minizip.
- CI's `companion-rs` job tests and builds it on Linux and Windows.

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
  Mac) it sends `.build.info` and the configs, plus each game's folder (`.flavor.info` and a first
  `Config.wtf`; the app places the addons, [The addons](#the-addons)), and nothing of the store.
  The first launch from nothing sets itself up and reaches character select in about 2.5 minutes on the
  iPhone; after that the client fetches what each zone needs as it goes (`docs/research.md`).
- **With copying**, the store goes whole: every archive and index that differs, archives first and
  `.build.info` last, or none of it. It stays as it is, and the log and the files step say why, when
  the device's `.build.info` has a newer build of any product than its clients (an on-device update
  put it there), when the Mac's install of a chosen game isn't the build of its client (Battle.net
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

The Mac's build of a game is its row in the install's `.build.info`, or, for an installed game the file
doesn't list, the build config in `Data/config/` whose `build-uid` is the game's product and whose
`build-name` names the build of the client in its folder (`GameStore.installTable`). Battle.net can
leave installed games out: on 2026-11-07 its agent's record of the installs was reset, and Forever's
install then wrote a `.build.info` with Forever's row alone, beside four other games. Nothing else in
the install says such a game's region or language, so it gets `Flavor`'s defaults (`us`, US English).

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
the Mac's files (`GameStore.deviceBuildInfo`). `.flavor.info` is written by the companion too, for the
ticked games, and by the launcher at every start when it isn't the game's (`flavor_info` in `launcher.m`):
Classic Era, TBC Anniversary, and MoP Classic are one client, which reads it to know which game it is, and
TBC Anniversary without one, its image from a dev build, read MoP Classic's static data and stopped with #134
("Invalid schema … for Table StartupFiles", the iPhone). Old
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
until the client's first frame), `spclipboard.m` (the clipboard), `sptouchpad.m` (touchpad swipes). `spnotice.m`, built into the CoreFoundation shim: the client's data setup dialog (below). |
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
- **Game controllers (visionOS).** By default the system turns a controller's buttons into pinches at the gaze
  point and the client's gamepad input (sticks, face buttons) reads zero. The scene's root view carries a
  `GCEventInteraction` for `GCUIEventTypeGamepad`, so a controller's events go to the Game Controller framework
  alone, which the client reads. `SP_GAMEPAD_SYSTEM=1` leaves them to the system. The look highlights are off
  while a gamepad is connected (`SP_HOVER_CONTROLLER=1` keeps them).
- **Controller rumble.** Needs no shim: the client rumbles through GameController's
  haptics (`GCDeviceHaptics` engines for the handles, or the triggers on a controller that has them, driven
  by a CoreHaptics player), and both frameworks are the system's. Its ForceFeedback imports stay generated
  stubs: they serve generic HID gamepads, and iOS doesn't let an app open a HID device (`IOHIDManagerOpen`
  returns `kIOReturnNotPermitted`), so no stub is reached. The game's own UI never asks for rumble; it comes
  from addons that call `C_GamePad.SetVibration`, such as Deadly Boss Mods, GTFO, and SilverDragon (Classic
  Era also needs the gamepad on, `GamePadEnable`).
  Checked on an iPhone with a DualShock 4 in Forever and Classic Era (#19); not yet on a Vision Pro.
- **Touchpad swipes.** A one-finger swipe of two-fifths of a DualSense's or DualShock 4's touchpad
  within 0.6 s, with no click, presses F16 (up), F17 (down), F18 (left), or F19 (right), for addon key
  bindings (`sptouchpad.m`). The game's own touchpad cursor still moves. Controllers are polled from the
  event pump rather than given handlers, since an element has one handler slot and the client's own
  would be replaced.
- **Clipboard.** `NSPasteboard` is the general pasteboard over `UIPasteboard`, text only
  (`spclipboard.m`); `NSPasteboardTypeString` and `NSPasteboardTypeFileURL` have macOS's values, so a
  file check answers no. Pasting another app's text shows iOS's Allow Paste prompt, once per copy,
  unless Settings > Slashplayed > Paste from Other Apps allows it; the read waits on the main thread, so
  the game stops drawing until it's answered. Making the view's `paste:` take Cmd+V (a paste through the
  system doesn't ask) didn't work on an iPhone: neither the system's shortcut nor a `UIKeyCommand` of the
  view's own reached it. Nothing logs the text or its length.
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
- **Game Mode and controllers.** The Info.plist calls the app a game (`LSApplicationCategoryType`) with
  `LSSupportsGameMode`, so iOS turns Game Mode on while it runs (less background work, lower Bluetooth
  latency for controllers and AirPods), and declares the extended gamepad profile
  (`GCSupportsControllerUserInteraction`, `GCSupportedGameControllers`), which is what lets Settings remap
  a controller for the app. The client reads controllers itself, through the system's GameController.
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
