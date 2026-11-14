# The Mac companion

The Mac companion (`apps/companion`) builds and signs the device app, puts each game's client and
the start of its game data in the app's container, and launches it. This page is its pipeline and the
game data it copies.

## The pipeline

The Mac companion app (`apps/companion`) does all of this on the user's Mac, for whichever games
they've chosen for the device, whether or not the game is installed on the Mac:

1. **Build the app.** The launcher, the on-device JIT helper (`PlugIns/SPJitHelper.appex`), the shims,
   the shims' `exports.json` and `rewrite-map.txt`, the system root certificates (`sproots.plist`), the
   addons, the third-party licenses (`licenses/`), and the filled-in Info.plist and entitlements go into
   `Slashplayed.app` (`ClientAssembly.assemble`). The app holds no game. The companion makes or refreshes
   explicit-App-ID development profiles with the user's own team, one for the app and one for the helper
   (by building a tiny stub project with `xcodebuild -allowProvisioningUpdates`), signs everything, the
   helper before the app, and installs it with `devicectl`, unless the device still holds the install
   this Mac made of this build (`ClientBuild.installNeed`). There's one build per platform (`client-ios`,
   shared by the iPad and the iPhone, and `client-xros`), the same whatever games a device has: it's
   rebuilt only when the companion's resources, the bundle ID, or the entitlements change, or its profile
   is about to run out (`ClientBuild.isComplete`). A device's app may have been deleted there or
   installed from another Mac, so the companion keeps a record per device of the build it installed, and
   checks it against the app `devicectl` lists there: every install puts the app in a new folder, so one
   made since is told apart. Then it makes sure the app has what the helper needs (see [The on-device JIT
   helper](loading.md#the-on-device-jit-helper)), in its data container, which the install comes before.
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
   the device](device-app.md#updating-on-the-device)).
5. **Game data.** The client streams its own game data from Blizzard's CDN, so by default the companion
   sends only `.build.info` and the configs its row names. **Copy Game Files from This Mac**, a per-device
   choice, copies the Mac's store instead, only the archives the device's games use. See [Game data on the
   device](#game-data-on-the-device).
6. **Launch and load.** At every launch the helper, on the device, attaches to the app and services one
   stop, the JIT prepare ([Running the client](loading.md)), then detaches, and the launcher loads the
   client with spguest ([Loading the client](loading.md#loading-the-client-spguest)). The Mac isn't
   needed: a launch from the home screen works the same as one from the companion.

## Entitlements and free teams

The entitlements are `get-task-allow` (a debugger may attach; development signing gives it),
`com.apple.developer.kernel.increased-memory-limit` and `extended-virtual-addressing` (Retail needs
more than the default ~5 GB limit; with them it's ~8 GB). A free Personal Team can't have
`extended-virtual-addressing` (Apple refuses the profile), so the companion leaves it out for one;
`increased-memory-limit` alone runs every flavor, Retail included. A free team's profile lasts 7 days,
and the companion re-signs within two days of that. A device set up by `slashplayed-companion`, or one
signed in to Apple in the launcher, renews its own profiles instead ([Renewing the app's
profiles](loading.md#the-on-device-jit-helper)), so it doesn't need the computer again for them.

## Third-party licenses

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

## Without a game install on the Mac

A game install on the Mac is optional, and so is Battle.net. The companion's pipeline doesn't read the
install; it's the source of two choices only: **Copy Game Files from This Mac** (step 5) and **Play with
My Mac's Battle.net** (see [Sandbox redirects](shims.md#sandbox-redirects)), which the menu by Play
offers only when one of the device's games is installed. The small identity file login needs from the Mac
needs no install. Onboarding (`Onboarding.swift`) requires Xcode, the team, the device, LocalDevVPN, and
a game per device; its last step lists what the Mac has installed and always passes.

## Game data on the device

All games share one app container, so the shared `Data/` store is copied once.

`Documents/` is laid out like the Mac's install: `.build.info`, the shared `Data/` (`config/` and
`indices/`, named by their content; the store: `data/` with its `data.NNN` archives and `.idx`
indexes, `ecache/`, and a folder of indexes per product), and each game's folder. Two writers can fill
the store: the companion's copy (`GameFiles.swift`) and the device's own client, which fetches whatever
its build needs and isn't there (an empty store, a patch's new content). Each keeps its archives and
indexes consistent with each other, but not with the other's: the client reads the newest `.idx` of
each bucket, so an index one wrote points into archives only it wrote. So the companion never mixes
them:

- **Without copying** (the default for a new device, and the only way without a game install on the Mac)
  it sends `.build.info` and the configs, plus each game's folder (`.flavor.info` and a first
  `Config.wtf`; the app places the addons, [The addons](device-app.md#the-addons)), and nothing of the
  store. The first launch from nothing sets itself up and reaches character select in about 2.5 minutes
  on the iPhone; after that the client fetches what each zone needs as it goes (`docs/research.md`).
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
leave installed games out: after its agent's record of the installs is reset, the next install writes a
`.build.info` with its own row alone. Nothing else in
the install says such a game's region or language, so it gets `Flavor`'s defaults (`us`, US English).

No order of the store's files leaves it readable if a copy stops partway: over a store the device's
client streamed, the copy replaces the client's archives before it sends the indexes that point into
them, and in between the client's own indexes, still the newest, point into the Mac's bytes. Every game
then quits about 3 s in with "Your World of Warcraft installation is damaged". devicectl can't rename or
delete, so the copy is made to finish instead: just before the store's first file it writes
`Library/spcopying.txt` saying `copying`, and once every copy has succeeded, `done`
(`GameFiles.copyMarker`). The next Play that finds `copying` finishes the copy whether or not the device
copies game files (only the ticked games' archives, as any copy), ignoring the client's indexes (they
can't be trusted over a half-copied store), or, with no game install on the Mac or a store it can't copy
(above), says why at the files step. The launcher won't load a game over `copying`: it says the copy
stopped and that a Play finishes it, before the sign-in, and it deletes a `done` marker.

Either way the `.build.info` rows and configs come from Blizzard, not the Mac: for each game whose image
is Blizzard's current build, the row (`BlizzardCDN.buildInfoLine`: the version row's keys and version,
the cdns row's CDN columns, and the Tags of a US English install, or the Mac install's) and the build,
CDN, and KeyRing configs it names, so the device's data always names the build of its image. The
companion first reads the device's `.build.info`; a game whose image is older keeps the device's row, as
does a product whose build on the device is newer (by `Version`), which gets none of the Mac's files
(`GameStore.deviceBuildInfo`). `.flavor.info` is written by the companion too, for the ticked games, and
by the launcher at every start when it isn't the game's (`flavor_info` in `launcher.m`): Classic Era, TBC
Anniversary, and MoP Classic are one client, which reads it to know which game it is, and TBC Anniversary
without one, its image from a dev build, read MoP Classic's static data and stopped with #134 ("Invalid
schema … for Table StartupFiles", the iPhone). Old indexes are listed in `Library/spdelete.txt` only when
the store was copied, and only ones older than the device's `.build.info` (which carries a date no later
than the last copy): an index the device's client wrote is never deleted. `devicectl device copy` skips a
file whose size and modification time both match the destination's, so a `.build.info` the companion
writes is dated a second after the device's (or the Mac's, when the store goes), never the same.
