# The device app

`Slashplayed.app` on the iPad, iPhone, or Vision Pro: the launcher, its start screen and Settings,
how it keeps itself signed, and how it updates and installs games itself.

## One app, every game

`Slashplayed.app` holds no game. Each game's client sits in the app's data container ([Running the
client](loading.md#loading-the-client-spguest)), and the app's main executable is a small launcher
(`apps/client/launcher.m`) that:

1. tidies up: deletes the game files the companion listed in `Library/spdelete.txt` (devicectl can't
   delete files), writes the device's free space to `Library/spfree.txt` (with and without the space iOS
   can clear; lockdown, all the Mac can read, gives only the second, so the companion adds the difference
   to lockdown's figure, `FreeSpace.now`), and retires a `Library/spgames` file spguest can't load
   ([spguest](loading.md#loading-the-client-spguest));
2. on iPadOS, brings up UIKit and waits for an active scene first (see [iPad](shims.md#ipad));
3. picks the game: the one the companion's Play or `run.sh` names (`SP_LAUNCH_FLAVOR`), else the one
   tapped on the start screen ([below](#the-start-screen-and-settings)). The names, their order, and
   Battle.net's arguments for each come from `apps/client/flavors.plist`, which `scripts/flavor.sh` and
   the companion read too. A game with no client is installed first, and one with game data but no client
   gets its data's own build ([Installing a game on the device](#installing-a-game-on-the-device));
4. seeds the game's `Config.wtf` (below);
5. logs the client's build against the game data's and runs the patch check ([Updating on the
   device](#updating-on-the-device)); then, before the sign-in, checks that the client can be loaded (the
   preflight, [spguest](loading.md#loading-the-client-spguest)) and refuses to load the game over a copy
   of game files that stopped partway (`Library/spcopying.txt`, see [Game data on the
   device](companion.md#game-data-on-the-device));
6. puts up the loading screen (below), tells the libSystem shim which game folder is the install root,
   and loads the client with spguest, which calls its `main`.

**`Config.wtf`.** The launcher writes only settings that are missing or that it owns, so none of this
holds up the launch:

- **Region and languages** (`portal`, `textLocale`, `audioLocale`), from the game's region ([A game's
  region](#a-games-region)). Started by Battle.net, the client takes them from Battle.net's launch
  options, which nothing writes on the device; with neither it opens a region picker the device can't
  show, exits, and saves the three empty, so every later launch would exit too. The launcher adds missing
  ones, replaces empty ones, and replaces all three when the portal isn't the game's region (Settings or
  Battle.net on the Mac moved it, or an older companion wrote `us` whatever the Mac's region, issue #94).
- **The intro movie**, marked as played on a game's first launch on the device: a first session on an
  empty store sets up its data first, and the intro it starts then never asks the CDN for the movie's
  data, so it would wait on its download bar forever.
- **Retail's Screen Narrator question**, answered only for a run nobody watches (`SP_SKIP_INTRO=1`, the
  companion's `-skip-intro`).

Each client carries its build in a file beside it, `spbuild-<flavor>` next to `wow-<flavor>`: the build
columns of the game's `.build.info` row (`Product`, `Branch`, `Build Key`, `Version`), as a one-row table
of the same `|`-separated shape, so one parser reads both. The companion (`ClientAssembly.Stamp`) writes
it from the patch service's version row (`Region`, `BuildConfig`, `VersionsName`), `seed-client.sh` from
the install's `.build.info`, and the device from the row it fetched; for the same build they write the
same bytes. Beside them are the client's `.build.info` row (`spbuildinfo-<flavor>`), which the launcher
writes into `Documents/.build.info` before the client loads when the row there isn't the client's build
(`sp_build_info_for_image`), and `spsource-<flavor>`, one word for where the client came from (`mac`,
`updated`, or `installed`), which Settings shows and which says who decides the game's region
([below](#a-games-region)). Every writer puts the stamp last, so a stamp is only ever beside a whole
client of its build. At each Play the companion asks the patch service for each of the device's games'
current build (about 80 ms each) and copies a client whose stamp is missing or older; if the service
can't be reached, the device's clients are played as they are. The launcher reads the stamp of the client
it's about to load and logs it against `Documents/.build.info`'s row for the product: the client and the
data are copied separately, so after a patch one can reach the device without the other.

The loading screen (`shims/appkit/sploading.m`, in the AppKit shim; the launcher calls `sp_uikit_loading`
with the game's name) covers the time from the load to the client's first frame, which was black: a few
seconds on a full store, and from an empty one the client's data setup (about 10 s on an iPhone; see [the
data setup dialog](shims.md#the-data-setup-dialog)) and then up to a minute and a half with its window up
and no frames while it streams its startup data. It shows the game's name and a spinner, or during the
setup a progress bar (the percentage from `spnotice.m`, which posts it as an `SPDataSetupProgress`
notification). It sits on the root view above the client's Metal layer, and the first `presentDrawable`
(hooked in `sphover.m`) takes it down. In both spans the client holds the main thread without pumping
events, so UIKit's run loop doesn't turn: each change is committed with an explicit `CATransaction`
flush, and the spinner is a Core Animation animation, which the render server runs on its own. On iOS
UIKit is up already and the screen goes up at once; on visionOS it goes up when the scene connects, once
the client has started UIKit. With `SP_HOVER_OFF=1` the presents aren't hooked, so there's no loading
screen.

### The start screen and Settings

Every launch that doesn't name a game (a launch from the home screen) opens on the start screen
(`spstart.m`, its screen in SwiftUI, `spstartscreen.swift`): the app icon's medallion and a framed
button per game in `flavors.plist`'s order, all drawn in code (**Install <game>** for one the device
has nothing of yet, [below](#installing-a-game-on-the-device)). Its face is Goodmountain, which the app
ships unmodified with its license (`scripts/fetch-font.sh`; it's never committed). The gear opens
Settings, a stock dark inset-grouped sheet in SwiftUI (`spsettings.swift`), one for iOS and visionOS.
[The guide](../guide.md#settings) lists what's in it. What's behind it:

- **Show Email** is the one place the saved Battle.net email is shown: it's read from the keychain inside
  `splogin.m` at the tap and hidden again when the app goes to the background, the sheet closes, or a game
  starts.
- **Scale** is the backing scale for every launch on this device ([Render
  scale](shims.md#window-screen-and-scene-tracking)).
- **Each game's section** names where its client came from, from `spsource-<flavor>` (a client with no
  word reads as the device's own), and its **Region** ([A game's region](#a-games-region)).
- **Reset Game Settings** deletes the game's `WTF/Config.wtf` and `Library/sprenderscale-<flavor>`, so the
  next start seeds them as on a first launch (the region and languages too); `WTF/Account/` (keybindings,
  macros, addons' saved settings) is kept.
- **Acknowledgements** shows the files in the app's `licenses/`.

`Info.plist` has `UIFileSharingEnabled` (Finder on a Mac browses `Documents/`) and
`LSSupportsOpeningDocumentsInPlace`, so all of `Documents/` shows in the Files app too. Open in Files
opens the game's folder, `Documents/_<flavor>_/`, with its `shareddocuments://` URL (the folder's path),
or `Documents/` before the game's first start makes the folder. That exposes `Data/` (a deleted archive
or index leaves the store unreadable: "installation is damaged") and, for the moments it exists, the
game's `login.txt`; both were weighed and accepted: the files are the person's own, on their own device.

The forget and the reset act at the tap, after a confirmation whose default is Cancel.

The dev-only drill that opens each of these screens in a given state is in
[maintaining.md](../maintaining.md#test-hooks-on-the-device).

## Keeping the app signed

**Renewing the app's profiles** (`spapple.m`'s `sp_profiles_renew`) uses the JIT helper's [profiles
request](loading.md#the-on-device-jit-helper) at every launch of a game, after the sign-in and before the
attach. When the app's or its helper's profiles have less than 3 days left (the earlier of the two: the
embedded ones and the copies of earlier renewals in `Library/spprofiles/`), the launcher asks Apple for
new ones with the Apple token the device keeps ([the host tool](host-tool.md) pushes it, or the
launcher's own sign-in makes it, below), through `spapple`, a Rust static library on the vendored
isideload (`scripts/build-spapple.sh`). A free team's App IDs lapse 7 days after they're made, so one
that's gone is made again first, under the same identifier, with increased-memory-limit for the app's;
the profiles already on the device stay valid until their own day either way. The helper installs the new
pair and the launcher keeps copies. Nothing stops the launch: on a failure the profiles still have days
left. The outcome goes to `Library/sprenew.txt` (`ok`, `failed`, `signin`, or `signedin`, with the time
the app stops opening), which the start screen and Settings read to say when the app stops opening and to
offer Sign In to Apple… when the token is missing or refused. Without a token and with no sign-in on the
device (a Mac companion's install), nothing is renewed and the companion re-signs as before.

**The launcher's Apple sign-in** is the token's other source, opt-in: the Mac companion signs through
Xcode, whose Apple session is in Xcode's own keychain group and bound to the Mac's anisette identity, so
it has no token to give a device (every Vision Pro is set up that way), and a pushed token Apple stops
taking would otherwise need a computer again. It's `slashplayed-companion`'s sign-in, run on the device:
`spapple`'s `login` op (isideload's GSA sign-in over SRP, its 2FA, and anisette from a remote-v3 server,
by default the same `mac-ani.jkcoxson.com`, with the same fixed client identity, which every later
request then claims). The login runs as a task in `spapple`; its 2FA callback parks until the next call
(`login_answer`) brings the code, a text to one of Apple's trusted numbers, or the Apple devices, so the
screen (`spapplescreen.swift`) can ask between calls. At the end `spapple` mints the `xcode.auth` token,
checks with `listTeams` that the Apple ID is on the team that signed the app (a token for another team
renews nothing), and hands the token to `spapple.m`, which keeps it as a pushed one. The password is
typed on the device and used once: it's held in `spapple` only for the sign-in (isideload signs in again
with it after the 2FA code) and zeroed when that ends, and never kept or logged (CLAUDE.md, "The Apple ID
is a credential"). The screen says plainly that this is a second sign-in through a third-party anisette
server, which sees the device's anisette identity but never the Apple ID, the password, or the token; the
server can be changed there, and the last one used is offered next time (`sp_anisette_url` in the app's
defaults).

## Updating on the device

When Blizzard puts out a build newer than the device's client of a game, the device can take it itself,
with no Mac and nothing to sign, since spguest loads the new slice as it loads any. That works on every
team, free ones included. The chain, all in the launcher, runs between the build log and the load:

1. **Find it.** The patch check (`apps/client/sppatch.m`) runs before the sign-in and the helper. The
   launcher fetches `https://<region>.version.battle.net/v2/products/<product>/versions` (the same
   `|`-separated table shape, one row per region; the region is the game's, [below](#a-games-region): the
   stamp's `Branch` for a game the Mac copied) and compares that region's `BuildConfig` with the stamp's
   `Build Key`. When they differ, it fetches the new build's arm64 slice from Blizzard's CDN the way the
   companion does (`apps/client/spcdn.m`, the port of `BlizzardCDN.swift`: build config, install manifest,
   one encoding page, then one ranged request for the chunks covering the slice, everything checked
   against the key that names it; about 45 MB, 3 s on an iPhone on Wi-Fi), the sibling `/cdns` table
   giving the servers. On cellular, a hotspot, or Low Data Mode it asks first. The slice stays in
   `Library/spslice/<flavor>.arm64` with its own stamp, written once the slice is whole, so a later launch
   for the same build doesn't fetch it again. A check that can't be made (offline, a timeout, no row) goes
   on without a word: the service fetch has a 3 s budget, and a refused connection fails at once.
2. **Check it.** The device has no `dyld_info`, so `apps/client/spbind.m` reads the slice's imports from
   the Mach-O itself, from either kind of fixup info (bind opcodes, which the clients have, or chained
   fixups), leaving weak imports out as `BindCheck` does, and looks them up in the `exports.json` the app
   carries. The companion's tests hold it to `BindCheck`'s answer on fixtures of both kinds and, opt-in,
   on every build the untethered research kept.
3. **Offer it.** A screen says a newer build is out. When it binds, it offers **Update**; otherwise it
   says why not (the patch needs a Slashplayed update, or it couldn't be checked). Each has **Play
   Anyway**, which goes on with the client the device has. The companion's Play follows the screen as a
   wait on the person.
4. **Take it.** Update fetches the build's configs (build, CDN, and Retail's KeyRing: the bytes
   `BlizzardCDN.configData` gives, checked against their keys) into `Documents/Data/config/` unless
   they're there. Then, in `Library/spgames/`, it renames the kept slice to `wow-<flavor>` (one volume,
   so nothing is copied), writes the build's `.build.info` row (`spbuildinfo-<flavor>`) and
   `spsource-<flavor>` (`updated`), and the stamp last. Nothing is assembled or signed. The configs go
   first: they're named by their content, so they're harmless to the old build, and a failure leaves the
   old client. So does a rename that fails: the old client's stamp goes back. A write that fails after
   the rename leaves the new client with no stamp, which nothing loads; the old one is gone then, so
   there's no Play Anyway, and the next start gets the game ready.
5. **Load it.** Just before the client loads, the launcher writes the kept row into
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
deletes the slice, stamp first, at its next start (`retire_caught_up`). The companion's tests hold the
config store, `sp_build_info_with`, and the version comparison (`sp_version_newer`) to the companion's
own code.

The Mac and the device write the same files, so either can be ahead, and the device is the record. At
Play, Update Client (and so a free team's weekly re-sign), and Copy Game Files, once its app is
installed, the companion reads the device's stamps and `spsource` words (`ClientBuild.deviceClients`:
`Library` is listed whole, since `devicectl` fails on a folder that isn't there, and each stamp beside
its client is pulled) and compares each with Blizzard's current build (`ClientBuild.clientCopy`, by the
same rule as `sp_update_caught_up`; the tests hold them to each other). Missing or older: it copies the
slice, stopping a client running on the device just before the first write, since that maps its file
(once the slice is downloaded and binds, so a download or a patch that fails leaves a game being played
alone). Newer (the device updated or installed it ahead of the patch service the Mac asked): it's kept,
and so are its game data's `.build.info` row and configs. Its build is left out of what the files step
writes, and a copy leaves the store whole (`StoreKept.newerOnDevice`), as for a newer `.build.info` row
(`GameStore.deviceBuildInfo`), so nothing of an older build goes to it. The main window lists those games
("Classic Era 1.15.9.70003, updated on the iPhone"), from `updatedOnDevice.<UDID>`, as the last action
found them.

What the device holds for it, all in the app's container:

| What | Where | Written by | Gone when |
|---|---|---|---|
| A game's client | `Library/spgames/wow-<flavor>`, its stamp `spbuild-<flavor>`, its `.build.info` row `spbuildinfo-<flavor>`, and `spsource-<flavor>` | the companion's copy (`mac`), Update (`updated`), or an install (`installed`) | a newer build's replaces it, or it isn't a client spguest can load |
| A newer build's slice | `Library/spslice/<flavor>.arm64`, `spbuild-<flavor>` | the patch check | Update takes it, or the client catches up with it |
| A device-decided game's region | `Library/spregion-<flavor>` | an install or Update, and Settings' Region | never (it outlives the client, so an install again keeps it) |
| The build's row and configs | `Documents/.build.info`, `Documents/Data/config/` | Update's configs, and the launcher's row before a load whose row isn't the client's build | a later build's are written |

### Installing a game on the device

The same chain installs a game the device has no client of, so a host that installs only the app (the
[host tool](host-tool.md)) needs nothing else, and no game install on the Mac.

- **The games.** The start screen offers every game in `flavors.plist`. One the device has nothing of
  reads **Install <game>** (`sp_games`, in `spcdn.m`), and Settings says "Not Installed".
- **The install.** Tapping one runs `sp_patch_install` (`sppatch.m`) before anything else for that game,
  on the patch screen: the patch service's current build, the slice and its bind check (asking first on
  cellular), and the update's configs, row, client, `spsource` (`installed`), and stamp into
  `Library/spgames/`. Nothing is signed, so it works on a free team. It installs in the game's region
  ([below](#a-games-region)), which the screen names ("Installing Classic Era for Europe…"). Any failure
  shows why with **Back**, which returns to the start screen; a launch that named the game
  (`SP_LAUNCH_FLAVOR`) stops on the reason instead.
- **Getting a game ready.** A game with game data but no client (its client was retired, or never copied)
  runs the same chain for the data's own build, not the current one ("Getting Classic Era ready…", 50 to
  58 MB), and keeps the data's region. If that build can't be downloaded (the CDN no longer serves it,
  say), it gets the current one instead, which streams its content over the data's as after Update. The
  patch check after it offers any newer build as usual. A Mac's next Play copies the same client, if it
  gets there first.
- **After it.** The launcher loads the new client, writing `.build.info` from its kept row first, as after
  Update; the client then sets up its empty store and streams.

The small identity file login needs from the Mac isn't part of the install. The companion still sends it,
for the Battle.net launch credentials it moves from the Mac. A device that signs in itself doesn't need
it: the host tool's install reaches character select without one. The addons are the app's own (below),
so an installed game has them too.

### A game's region

Each game has its own region and languages, as Battle.net does it (`sp_game_region` in `spcdn.m`, read at
each start by `sp_game_region_now` in `launcher.m`). Who decides depends on where the game came from:

- **A game the Mac copied** (`spsource` `mac`: the companion copied its client, and syncs the Mac's game
  data): the Mac does. Its `.build.info` row's Branch and Tags, which the companion sends again at every
  sync, else the client's stamp. Settings names the region and says to change it in Battle.net on the Mac.
  The game's first `Config.wtf`, which the companion sends, says that row's region and languages
  (`GameFiles.firstConfig`): without Battle.net the client signs in to its portal's account server.
- **A game the device decides** (installed or updated here, so it has a region file, or with no game data
  yet, and not the Mac's): the device does, from `Library/spregion-<flavor>`, a one-row table of the
  region, its text and speech locales, and the locales the build ships. The install writes it: by default
  the device's region in Settings mapped to Blizzard's (`sp_region_for_country`: the Americas and Oceania
  `us`; Europe, Russia, the Middle East, and Africa `eu`; Korea `kr`; Taiwan, Hong Kong, and Macao `tw`;
  anything else `us`, never `cn`, `sg`, or `xx`), and the device's first preferred language that region
  has a locale for (`sp_region_locale`: us enUS esMX ptBR; eu enUS deDE esES frFR itIT ruRU; kr koKR; tw
  zhTW), else the region's default. Speech follows text. Europe's English is `enUS`, as Blizzard ships
  it: the clients have no `enGB`, and one set to it opens the region picker the device can't show, and
  exits (issue #88), so an `enGB` an older version wrote reads as `enUS`. The slice download reads the
  build's install manifest, so the locale is checked against the tags it lists (`sp_locale_shipped`;
  Classic's have no itIT). Settings' **Region** picker rewrites the file; nothing else does but an
  install or Update.

Everything else follows that file at each start, so a change isn't put back by a copy written before it:
the patch check's region, an Update's kept row (its Branch and Tags, `sp_region_tags`) and stamp, the
start-time `.build.info` rewrite (which also writes the row again when it's in another region,
`sp_build_info_for_image`), and `Config.wtf` (`sp_config_with_region`). Before the client is chosen the
launcher moves the kept row and stamp into the region (`region_sync`, `region:` lines). The stamp's Branch
stays, but decides nothing for these games. Tags are Battle.net's layout without its `acct-` and `geoip-`
tags, which no install manifest lists.

### The addons

The device app carries the addons, `addons/SPMovie/`, `addons/SPHover/`, and `addons/SPKeyboard/` (their
`.toc` and `.lua` as `addon/` has them; `apps/client/build.sh` and the companion's `ClientAssembly` both
bundle them, on both platforms). Before each start, once the game is picked, the launcher puts them in
the game's `Interface/AddOns/` (`sp_addons_place` in `spcdn.m`): SPMovie on every device, SPHover on the
headset only (the iPad and iPhone have a real pointer), SPKeyboard on the iPad and iPhone only (the
on-screen keyboard), each file written when the game's copy is missing or its bytes differ. Each TOC
lists every flavor's Interface number, so one copy suits each game. A changed addon reaches a device with
the rebuild the companion's resources digest asks for (`ClientBuild`).
