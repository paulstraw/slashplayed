# CLAUDE.md

Notes for agents working in this repo. Users' docs are in `README.md` and `docs/`; how everything
works is `docs/architecture.md`. Read that before changing the pipeline, the shims or the launcher.

## Where work happens

Development continues in a clone of the public repo, `paulstraw/slashplayed`, on branches off
`main`. Its history starts at one "Initial public release" commit; the private archive it was
exported from is history only and takes no new work. Changes go to the public repo as pull requests,
where CI runs. Agents don't merge PRs, tag, create or edit releases, or touch settings, environments,
secrets, or Pages on their own (see Releasing): those are the owner's, and an agent does one only when
the owner asks for it.

## Layout

- `apps/companion/`: the Mac companion (SwiftUI, XcodeGen `project.yml`, target `SPCompanion`,
  `com.strawdynamics.slashplayed.companion`). `Sources/` is the whole user-time pipeline in Swift:
  `ClientAssembly.swift` (the device app, which holds no game), `ClientBuild.swift` (its build and install,
  and each game's unchanged slice copied into the device's `Library/spgames` when the device's is missing or
  older), `BindCheck.swift` (each slice's imports against the shims, before it's copied), `Signing.swift`,
  `GameStore.swift`/`GameFiles.swift` (archive selection, sync), `BlizzardCDN.swift` (the
  patch service and CDN: version rows, configs, and the client's arm64 slice), `ClientLauncher.swift`
  (launch, following the on-device prepare), `TokenRelay.swift`, `Pairing.swift` (the device's
  RemotePairing record over USB, through idevice, and lockdown's free space), `DeveloperDiskImage.swift` (Xcode's DDI into the
  app's container), `Diagnostics.swift`, `Onboarding*.swift`. Tests in `Tests/`.
  At run time it reads only its bundled resources (`bundle-resources.sh`), never the repo, and runs only
  `/usr/bin` tools and `xcrun`. It links idevice statically (`idevice-config.sh` writes the xcconfig from
  `work/idevice/macos/`).
- `apps/client/`: the device app. `launcher.m` (the `slashplayed` executable: picks the game, retires what it can't load, and loads
  `Library/spgames/wow-<flavor>`, the game's unchanged slice, with spguest),
  `spjit.m` (its side of the JIT helper), `sppair.m` (the headset's pairing; its screen is `sppairscreen.swift`), `spvpn.m` (the
  wait for LocalDevVPN; its screen is `spvpnscreen.swift`), `spstyle.swift` (the launcher's look, shared by every
  SwiftUI screen: one game button, `GameButtonStyle`), `splogin.m` (the Battle.net sign-in: the keychain and `login.txt`; its screen is `spsignin.swift`),
  `spstart.m` (the start screen, every launch that doesn't name a game: the wait for a tap, `SP_START_TEXT_SIZE`, Goodmountain's
  registration, `sp_face`; its screen is `spstartscreen.swift`; its logo is the icon's own vectors, `splogo.h`, and its face
  Goodmountain, never committed: `scripts/fetch-font.sh`), `spsettings.swift` (the start screen's Settings sheet: the sign-in's forget,
  each game's build and where it came from (`spsource-<flavor>`), Open in Files, and Reset Game Settings, Acknowledgements, and the `SP_START_DRILL` states), `sppatch.m` (the check for a newer build; its screen is `sppatchscreen.swift`; it fetches the new client with
  `spcdn.m`, the port of `BlizzardCDN.swift`, and checks its imports with `spbind.m`; both Foundation only,
  tested in the companion's tests; an Update or an install puts that slice in place, signing nothing), `spapple.m` (the
  Apple token: the one file that holds it, and the app's renewed profiles from Apple through `spapple/`, a Rust
  static library on the vendored isideload, `scripts/build-spapple.sh`; the helper installs them through misagent,
  `spjit.m`'s `sp_jit_profiles`; and the optional Apple sign-in that makes a token on the device, its screen
  `spapplescreen.swift`), `flavors.plist` (each game's
  name, `.build.info` product, client path, Battle.net arguments, and addon number: the one list, read by the
  launcher, the companion's `Flavor.swift`, and `scripts/flavor.sh`), `spguest.c`/`.h` and `spguest_tlv.S`
  (spguest, a loader of our own: the unchanged, unsigned client mapped, bound, and run without dyld;
  `spguestlaunch.m` is the launcher's load step and its preflight), `guesttest/` (spguest's test: a toy
  guest of our own, `build.sh mac` on the Mac, which CI runs, and `build.sh device`/`run.sh` on a device;
  `research/guestloadtest/README.md` has the research and the device runs),
  `helper/` (the
  on-device JIT helper, a classic app extension on idevice, `Pair.swift` its pair-setup;
  `build-helper.sh`; jittest builds the same source), Info.plist and
  entitlements templates, `icons/` (the app icon catalogs, compiled by `build-icons.sh`),
  `signing/` (stub project for the explicit-App-ID profile), and
  dev scripts (`build.sh`, the app with no game in it, `run.sh`, `seed.sh`, `seed-client.sh`, the Mac's
  client into `Library/spgames`, `pull-logs.sh`, `grab-token.sh`, `push-apple-token.sh`, `casc_archives.py`).
- `apps/companion-rs/`: `slashplayed-companion`, the host tool for an iPad or iPhone without a Mac (Windows, Linux, a
  Mac without Xcode; Rust, `rust-toolchain.toml` pins it): `src/kit.rs` (the device kit, the unsigned app
  `scripts/release/device-kit.sh` makes at release), `device.rs` (usbmuxd, trust, Developer Mode, install,
  house_arrest, the RemotePairing record), `account.rs` (the Apple ID sign-in, memory only), `provision.rs`
  (device, App IDs, capabilities, certificate, profiles), `keystore.rs` (the signing key, in the OS's
  credential store), `sign.rs` with `build.rs` and `zsign/` (zsign compiled in), `ddi.rs` (the pinned
  mirror DDI). `vendor/isideload/` is isideload with its LGPL signer made optional (`VENDORED.md`).
  `package.sh` packs a release build with its notices. Vision Pro stays Mac-only.
- `shims/`: hand-written shims (`appkit/`, `audio/`, `coregraphics/`, `ident/`, `security/`, `system/`)
  and `generated/` (`gen_stubs.py`'s output, committed, one set for both platforms; it `#include`s the
  hand-written files). `exports_manifest.py` writes `exports.json`, the bind check's manifest.
- `addon/`: the in-game addons, `SPHover` (look highlights, headset only) and `SPMovie` (a tap opens a
  cinematic's skip dialog, every device); `addon/test/test.sh` tests both (needs lua and cc; CI runs it
  on Linux with Lua 5.1, the game's).
- `scripts/`: `build-idevice.sh` (idevice from source at a pinned commit, Rust pinned: `macos` for the
  companion, `ios`/`xros` for the on-device JIT helper; into `work/idevice/`, with `<platform>/licenses/`),
  `fetch-font.sh` (Goodmountain, the start screen's and the site's face, OTF and woff2, and its license, at a
  pinned commit and checked SHA-256, into `work/fonts/`: its license forbids changing the file, so it's never
  committed), `site-preview.sh` (`site/` staged as Pages deploys it, font included, served on 127.0.0.1),
  `build-zsign.sh source` (zsign's source at a pinned commit with `zsign.patch`, into `work/zsign/src/zsign`, for
  slashplayed-companion's `build.rs`; git only, nothing built), `crate-notices.py`
  (build-idevice.sh's license texts of every linked crate, failing on one with none; `crate-licenses/` holds
  the texts of crates that ship none), `check-tree.sh` (scrub and
  no-hardcoding greps), `config.sh` (loads `config/local.env`),
  `platform.sh` (`SP_PLATFORM`), `flavor.sh` (`SP_FLAVOR`: `classic_era`, `anniversary`, `classic`
  (MoP Classic, `_classic_`, not Classic Era), `retail`; `SP_INSTALL`); `recon/` for maintainers
  (`regen.sh`, `bucket.py`, `gen_stubs.py`, `verify_binds.py`, `check_exports.py`, `check-patch.sh`);
  `release/` (`release.sh`, `appcast-merge.sh`, `update-test.sh`).
- `research/{jittest,loadertest,metaltest,dlopentest}`: the experiments, each with a README; `docs/research.md`.
  `research/guestloadtest/` is a README only: its loader and toy are `apps/client/spguest.*` and `guesttest/`.
- `work/`, `build/`: gitignored output. `work/` holds thinned clients and game data: never commit it.

## Build and test

```sh
scripts/build-idevice.sh macos             # once (and after re-pinning): the companion links it
scripts/build-idevice.sh ios; scripts/build-idevice.sh xros   # the JIT helper links these
scripts/build-spapple.sh                   # once (and after changing apps/client/spapple): the launcher links it
scripts/fetch-font.sh                      # once: the start screen's font and its license, into work/fonts/
shims/build.sh <xros|ios>                  # build/<platform>/*.dylib + exports.json
apps/companion/build.sh                    # build/companion/Slashplayed Companion.app (needs xcodegen)
apps/companion/test.sh                     # companion unit tests; extra args go to xcodebuild
SP_PLATFORM=ios SP_NO_INSTALL=1 apps/client/build.sh   # the script build of the device app, no install
scripts/build-zsign.sh source; (cd apps/companion-rs && cargo test --locked && cargo build --release --locked)
                                           # slashplayed-companion; a device run needs --kit <zip>:
                                           # scripts/release/device-kit.sh <bundle-resources.sh --build dir> <zip>
SP_GUEST_REFS=none apps/client/guesttest/build.sh mac   # spguest's toy on the Mac, as CI runs it
research/<harness>/build.sh                # research harnesses (they install; no no-install switch)
```

Some companion tests are opt-in because they read the owner's real install (see each test's doc
comment, e.g. `TEST_RUNNER_SP_CHECK_INSTALLED=1`, `TEST_RUNNER_SP_COMPARE_STORE=1`,
`TEST_RUNNER_SP_COMPARE_CDN=1`, `TEST_RUNNER_SP_COMPARE_BUILDS=1`). They compare against Blizzard files locally (the CDN one fetches from
Blizzard's CDN into `$TMPDIR`); nothing from them is ever written into the repo.

Companion launch flags for headless work: `-play` (Play the game the menu by Play picks, signed in on
the device; add `-skip-intro` to start without the intro movie or Retail's Screen Narrator question, as
`SP_SKIP_INTRO=1` does for `apps/client/run.sh`; it sets them in the device's `Config.wtf`, so they stay
skipped there), `-update`, `-sync`, `-pull-logs`, `-export-diagnostics`, `-setup-step <n>`,
`-check-for-updates`, `-pair` (Pair Again: an iPad or iPhone on USB gets a new RemotePairing record;
the headset's is cleared, so its next launch pairs). These act inside the running
GUI app, which doesn't quit afterwards: follow `~/Library/Logs/Slashplayed/companion.txt` and quit it.

## config/local.env

The dev scripts take `SP_TEAM`, `SP_SIGN_ID`, `SP_BUNDLE_ID` (and optionally `SP_DEVICE`,
`SP_DEVICE_XROS`, `SP_DEVICE_IOS`, `SP_INSTALL`) from the environment or the gitignored
`config/local.env` (template: `config/local.env.example`), and fail loudly when one is missing. Never
commit owner values: no UDIDs, team IDs or signing hashes in tracked files. The companion doesn't use
this file; it finds the team in Xcode's accounts and devices with `devicectl`.

`SP_DEVICE_IOS` names one device, and there are two iOS test devices (the iPad and the iPhone). Before a
device step, check which one it names against `xcrun devicectl list devices`, and set `SP_DEVICE` for
the run when it's the other one. Don't edit the owner's `local.env`. Pointing at an unreachable device
fails with CoreDeviceError 4016 ("not able to fulfill the requested usage assertion requirements"),
which looks like a locked or disconnected phone but isn't.

Xcode 27 has no Devices and Simulators window: devices are paired in **Device Hub** (Xcode > Open
Developer Tool > Device Hub). The headset pairs there with Settings > General > Remote Devices open on it.
Clearing that Remote Devices list unpairs the Mac too (devicectl then shows the headset unavailable), so
pairing Slashplayed on the headset never needs it cleared.

Changing a device app's bundle ID gives it a new, empty data container, so every game file is copied
again (over an hour for Retail on the headset). Don't change it casually.

## Rules

- **Signing identities are credentials.** A `.p12`, its password, or a keychain export is never read
  into a log, printed or committed: sizes and validity dates only, files 0600, zeroed and deleted after the
  copy. Test identities are made at test time in `$TMPDIR`.
- **Pairing records are credentials.** A RemotePairing record (and the Mac's lockdown pair record, which
  idevice holds in memory to make one) is never read, printed or logged: sizes only, files 0600 and
  deleted after the copy, as `Pairing.swift` and `research/jittest/push-pairing.sh` do.
- **No Blizzard bytes, ever**, in the repo, CI, fixtures or release artifacts: no client binaries
  (thinned or not), no game data, no metallibs from the client, no logs or crash reports with
  credentials. Test fixtures are built from our own code (`research/loadertest` is the model).
- **The Apple ID is a credential.** `slashplayed-companion` (`apps/companion-rs/src/account.rs`) takes the password
  typed by the person, uses it once for the sign-in, and zeroes it; the login lives in memory only and
  ends with the process. Nothing about it is logged or stored on the computer, not even sizes, and no
  tracing subscriber is ever installed (isideload's logs would carry account data). The one thing that
  outlives the process is the Apple token this sign-in makes, which goes only to the device, for the app to
  renew its own profiles (the next rule). The person types it; test runs use the owner's own Terminal. The
  tool's signing key goes only to the OS credential store, never to the device. It never revokes a
  certificate a Slashplayed tool didn't make.
  The launcher's own Apple sign-in (opt-in, from the start screen's note and Settings: `spapple.m`, its
  screen `spapplescreen.swift`, and `spapple`'s `login` op) is held to the same: the person types the
  password on the device, it goes to `spapple` in one request written into a buffer zeroed after, `spapple`
  zeroes it as soon as Apple has it, and nothing stores it (the zeroing is best effort: copies Foundation
  and isideload make on the way are freed unzeroed). Nothing logs the Apple ID, the password, its size, a
  2FA code, or the masked numbers Apple sends; the screen keeps none of them, and its fields are emptied
  once they're sent. Only the token the sign-in makes is kept, as the next rule says. Its screen
  says plainly that it's a second sign-in to the Apple ID through a third-party anisette server.
- **The Apple token is a credential.** The device keeps one Apple token (the `xcode.auth` app token, its
  adsid, and the anisette server and machine identity it was made on), and only `spapple.m` handles it: in
  the keychain (this device only, never synced), imported from `Library/spappletoken.json`, which is zeroed
  and deleted at once, or kept from the launcher's own sign-in's reply, which `spapple` zeroes once it's
  read; and handed to `spapple` in memory only. Zeroing it after use is best effort: `spapple.m` and
  `spapple` zero the buffers they own, but Foundation's and isideload's copies are freed unzeroed. What
  holds without exception: it's never logged, and never stored anywhere but that keychain item (and the
  pushed file until its import). Its screens keep nothing. Never the password or the GrandSlam token. Logs
  give the stated expiry's date only, never the token, its fields, or its size; `spapple`'s errors never
  carry it. `push-apple-token.sh` (dev) and `slashplayed-companion` are the only
  things that push one, and the launcher's sign-in the only thing on the device that makes one.
- **Never read, print or log values from `net.battle` prefs** or the exported credentials file. Sizes
  and timestamps only, as `TokenRelay.swift` does.
- **The Battle.net sign-in is a credential too.** Only the launcher's sign-in (`splogin.m`, and its
  screen `spsignin.swift`, which hands what's typed straight to it and keeps nothing) handles the email and password: it keeps them in the keychain (this device only, never synced), writes
  `login.txt` 0600 just before the client loads, the libSystem shim deletes it on the client's close or
  exit, whichever comes first (`spsystem.c`), and the launcher deletes every game's leftover at its start. Nothing logs, prints, or stores them anywhere else, and logs don't even give the
  file's size. Outside that code, a `login.txt` (on the Mac or a device) is never read or opened:
  existence, timestamps, and sizes only, and `rm -P` once a test is done. The owner types any password.
- **The scrub line.** Keep Apple-platform findings in full (TXM and debugger-prepare JIT, metallib
  retag, the AppKit→UIKit coroutine, RemoteIO, sandbox redirects, load-command rewrite, launch
  watchdog, heat). Generalize client internals: no offsets into the client or client function addresses;
  say "the client rewrites its own code at startup; the shim services that through an alias mapping",
  "the companion moves your Battle.net launch credentials to your device; values are never read", and
  "the small identity file login needs from the Mac". Nothing about credential formats: docs may say the
  game signs in from a file holding the email and password, never how it's laid out.
- Comments are dense and explain *why*. Shell scripts use `set -e` (`set -euo pipefail` in new ones)
  with loud, specific errors. Swift matches `apps/companion/Sources`. Scratch files go in `$TMPDIR`.
- Docs, UI strings, and commit messages use the serial (Oxford) comma: "iPad, iPhone, or Vision Pro".
  Older text predates this; fix it when you touch it.
- **Commits** use [Conventional Commits](https://www.conventionalcommits.org/): a subject of at most
  72 characters, `type(scope): summary` in the imperative, no period; a blank line; a body wrapped at 72
  that says why, and what was checked where (devices, tests, check-tree) in a line or two. Types: `feat`,
  `fix`, `docs`, `test`, `refactor`, `perf`, `build`, `ci`, `chore`, `revert`. Scopes: `companion`,
  `client`, `helper`, `companion-rs`, `shims`, `addon`, `recon`, `release`, `research/<harness>`; no scope for `docs`
  and `ci` commits or a change spread across the repo. The body
  is a few short paragraphs, not a changelog of every function touched: the diff has that.
  `scripts/hooks/commit-msg` checks the format; turn it on once per checkout with
  `git config core.hooksPath scripts/hooks`.
- **Changelog.** A PR with a change people using Slashplayed would notice (a feature, a setting, a
  fix, a new known issue, or one gone) adds its entry under `## [Unreleased]` in `CHANGELOG.md`, in
  that PR, in the Keep a Changelog section it belongs to (`Added`, `Changed`, `Fixed`, `Removed`, then
  `Known issues`). Write it for players, not developers: what they can do or what no longer goes wrong,
  not which file changed. Refactors, tests, CI, and docs-only changes don't get one. Releases are cut
  from `[Unreleased]`, so a missing entry is a missing release note.
- Names use the `sp`/`SP_` prefix (`libspAppKit`, `SPEvent`, `SP_SCALE`, `Documents/spconsole.log`).

## After a game patch

1. Let Battle.net update the game on the Mac. The companion's bind check (or
   `scripts/recon/check-patch.sh`) says whether the new client still binds against the shims.
2. If it doesn't: `scripts/recon/regen.sh xros`, then `scripts/recon/regen.sh ios` (the second run
   must show no diff; if it does, the platforms need separate generated sets). Needs Python 3 with
   PyYAML. Scratch goes to `work/regen/`.
3. Review the `shims/generated/` diff. Generated stubs only log: an import the client really uses needs
   a hand-written implementation (`gen_stubs.py` `EXTRA_CODE` / `EXTRA_INCLUDES`).
4. If the patch changed a game's version, set its `toc` in `flavors.plist` and in both addons' TOCs
   (`addon/SPHover/SPHover.toc`, `addon/SPMovie/SPMovie.toc`), or the game flags them as out of date
   (`TEST_RUNNER_SP_COMPARE_CDN=1` checks `flavors.plist` against the patch service; `FlavorTests`, the
   TOCs against it).
5. Rebuild (`shims/build.sh`, `apps/companion/build.sh`), run the tests, try each affected flavor on a
   device, and release a new companion version.

## Releasing

- **CI** (`.github/workflows/ci.yml`, PRs and `main`): `scripts/check-tree.sh` (the scrub and
  no-hardcoding greps; run it before committing), shims for both platforms, the unsigned companion,
  its tests, with idevice built from source first (rustup-init pinned by version and checksum). Runner `xcode-27` (GitHub's hosted image, Xcode 27.1 selected; listed in
  `.github/actionlint.yaml` so `actionlint` accepts it). And the addon's test, `addon/test/test.sh`,
  on Linux with Lua 5.1. Keep `actionlint` clean. CodeQL runs from `.github/workflows/codeql.yml`
  (advanced setup, so fork PRs are scanned too; the ruleset requires its results), with default setup off.
- **Version**: `MARKETING_VERSION` in `apps/companion/project.yml` is the source of truth;
  `apps/companion-rs/Cargo.toml`'s version (and its `Cargo.lock` entry) must equal it (check-tree). A
  release needs its own dated `## [X.Y.Z]` section in `CHANGELOG.md` and the real Sparkle key in
  `SP_SPARKLE_PUBLIC_KEY`. To bump it ("prepare X.Y.Z"), follow
  `.agents/skills/preparing-releases/SKILL.md`; the tag stays the owner's.
- **Release** (`.github/workflows/release.yml`): the owner pushes tag `vX.Y.Z` (it must equal
  `v$MARKETING_VERSION`) and approves the `release` environment. The job imports the Developer ID
  identity into a throwaway keychain, runs `scripts/release/release.sh` (build, sign, notarize, staple,
  DMG, no-Blizzard-bytes check, `appcast-item.xml`, `SHA256SUMS`), creates the GitHub Release (DMG and
  `SHA256SUMS`), merges the item into the live appcast (`scripts/release/appcast-merge.sh`; the seed
  `site/appcast.xml` on a 404) and deploys `site/` to Pages, with Goodmountain's woff2 and its license
  (`goodmountain-license.txt`) fetched by `scripts/fetch-font.sh` and copied next to the page, since they're
  never committed; `scripts/site-preview.sh` stages and serves it the same way. Secrets in that environment:
  `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`, `ASC_API_KEY_P8_BASE64`, `ASC_API_KEY_ID`,
  `ASC_API_ISSUER_ID`, `SPARKLE_ED_PRIVATE_KEY`. A re-run after the Release exists fails on purpose;
  delete the Release first.
- **slashplayed-companion** ships in prereleases only, until the owner sets the repository variable
  `SP_RELEASE_COMPANION_RS` to `true`; then it rides the same release. `release.sh` makes the device kit
  (`scripts/release/device-kit.sh`, attached as `slashplayed-device-kit.zip`), then `release.yml` builds the
  tool against its hash (`companion-rs-build.yml`) and attaches the Windows and Linux archives, their attestations,
  and their SHA256SUMS lines.
  Volunteer prereleases: `companion-rs-prerelease.yml` (run by hand on a branch, which it builds), published only after the owner
  approves the `prerelease` environment.
- **Locally**: `scripts/release/release.sh --unsigned` smoke-tests the whole script with no certificate.
  A signed local build (release candidates: `SP_RELEASE_VERSION=X.Y.Z-rc1`) uses `NOTARY_PROFILE` and
  the Sparkle key in the login keychain. `scripts/release/update-test.sh` tests a Sparkle update
  end to end on 127.0.0.1.
- Agents don't tag, create or edit releases, or touch environments, secrets, or Pages settings on
  their own: those are the owner's. When the owner asks for one (say, fixing a published release's
  notes), do it.
