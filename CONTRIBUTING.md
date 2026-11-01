# Contributing to Slashplayed

Thanks for helping out. Slashplayed is a Mac companion app (`apps/companion`), a device app
(`apps/client`, with its on-device JIT helper in `apps/client/helper`), and the shim libraries it
loads (`shims/`). [docs/architecture.md](docs/architecture.md)
explains how they fit together; read it before changing the pipeline, the shims or the launcher.

## Two rules first

- **No Blizzard bytes, ever**: not in commits, pull requests, issues, CI, test fixtures or release
  artifacts. That means no client binaries (thinned or not), no game data, no metallibs extracted from
  the client, and no logs or crash reports that hold credentials. Test fixtures are built from our own
  code at test time; `research/loadertest` (a small AppKit program with the same import shape as the
  client) is the model. `work/` holds thinned clients and game data and is gitignored: never commit it
  or attach anything from it.
- **The scrub line.** Apple-platform findings are welcome in full: executable memory under TXM and the
  debugger prepare, the metallib retag, the AppKit→UIKit event loop coroutine, RemoteIO, sandbox
  redirects, the load-command rewrite, the launch watchdog, heat. Client internals are not: no offsets
  into the client or addresses of its functions, nothing about credential formats. Describe them at
  the level architecture.md does ("the client rewrites its own code at startup; the shim services that
  through an alias mapping", "the companion moves your Battle.net launch credentials to your device;
  values are never read", "the small identity file login needs from the Mac").

Code must also never read, print, or log credentials: values from `net.battle` prefs or the
companion's exported credentials (sizes and timestamps only, as `apps/companion/Sources/TokenRelay.swift`
does); the Battle.net email and password, which only the launcher's sign-in screen (`splogin.m`)
handles; signing identities (`.p12` files and their passwords); and RemotePairing records. Files that
hold them are 0600 and deleted once copied. [CLAUDE.md](CLAUDE.md) has the full rules.

## Prerequisites

- An Apple Silicon Mac on macOS 15 or later, with Xcode 27 (the visionOS and iOS platforms and the
  Metal toolchain).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). The companion's project
  is generated from `apps/companion/project.yml`; edit that, never the generated project.
- [rustup](https://rustup.rs). [idevice](https://github.com/jkcoxson/idevice) is linked statically
  into the companion (making an iPad's or iPhone's RemotePairing record over USB,
  `apps/companion/Sources/Pairing.swift`) and into the on-device JIT helper (`apps/client/helper`).
  `scripts/build-idevice.sh macos|ios|xros` builds it from source at a pinned commit with the Rust
  toolchain it pins, into `work/idevice/` (never committed), with the license texts of every crate it
  links (`scripts/crate-notices.py`, which needs Python 3 and fails on a crate with no license text).
- [zsign](https://github.com/zhlynn/zsign) and [OpenSSL](https://www.openssl.org), which the device
  app's launcher links for signing a game update on the device (`apps/client/spsign.m`), and the
  companion's tests on the Mac. `scripts/build-zsign.sh` builds both from source at pinned commits
  (zsign with `zsign.patch`), into `work/zsign/` with the licenses the app ships.
- For running on a device: an Apple Account signed in to Xcode (a paid Apple Developer Program team,
  or a free Personal Team with 7-day signing); a Vision Pro, an M2-or-later iPad, or an iPhone 15 Pro
  or later, paired with Developer Mode on; and [LocalDevVPN](https://apps.apple.com/app/id6755608044)
  on the device.
- For regenerating shims only: Python 3 with PyYAML (`pip install pyyaml`).

## Building from source

The generated shim sources are committed, so a fresh clone builds without a game install:

```sh
scripts/build-idevice.sh macos            # once (and after re-pinning): idevice for the companion
scripts/build-idevice.sh ios              # idevice for the JIT helper on the iPad and iPhone
scripts/build-idevice.sh xros             # and on the Vision Pro (all three into work/idevice/)
scripts/build-zsign.sh                    # once: zsign + OpenSSL for ios, xros, and macos (work/zsign/)
shims/build.sh xros                       # build/xros/*.dylib + exports.json
shims/build.sh ios                        # the same for iPadOS and iOS
apps/companion/build.sh                   # build/companion/Slashplayed Companion.app, resources bundled
apps/companion/test.sh                    # the companion's unit tests (extra args go to xcodebuild)
```

The companion built this way works like the released one: it finds your team in Xcode and your
device with `devicectl`, and fetches the game's client from Blizzard's CDN, so it needs no
configuration and no game install. A game installed through Battle.net on the Mac is optional (for
copying its files to a device, and the "Play with My Mac's Battle.net" fallback); the companion finds
it where Battle.net put it.

Some companion tests are opt-in because they compare against your own game install or Blizzard's CDN
(see each test's doc comment, e.g. `TEST_RUNNER_SP_CHECK_INSTALLED=1`, `TEST_RUNNER_SP_COMPARE_STORE=1`,
`TEST_RUNNER_SP_COMPARE_CDN=1`, `TEST_RUNNER_SP_COMPARE_BUILDS=1`, `TEST_RUNNER_SP_COMPARE_ASSEMBLY=1`). They read Blizzard files locally
(the CDN one fetches into `$TMPDIR`) and must never write anything from them into the repo.

## The command-line scripts and `config/local.env`

The dev scripts (`apps/client/build.sh`, `run.sh`, `seed.sh`, `pull-logs.sh`, the research harnesses)
sign and install without the companion. They take your values from the environment or from
`config/local.env`, which is gitignored:

```sh
cp config/local.env.example config/local.env   # then fill in SP_TEAM, SP_SIGN_ID, SP_BUNDLE_ID
SP_PLATFORM=ios SP_FLAVOR=classic_era apps/client/build.sh
SP_PLATFORM=ios SP_NO_INSTALL=1 apps/client/build.sh        # build only, no device needed
```

`SP_PLATFORM=xros|ios` picks the device platform and `SP_FLAVOR=classic_era|anniversary|classic|retail`
the game (`classic` is MoP Classic, Battle.net's `_classic_`). The scripts fail loudly
when a value is missing. **Never commit your own values**: no device UDIDs, team IDs, or signing hashes
in tracked files.

Pick your bundle ID once. A new bundle ID is a new, empty app container on the device, so every game
starts from nothing: its data is fetched again as it plays, or with copying on, copied again (over an
hour for Retail on the headset).

`apps/client/build.sh`, `apps/companion/Sources/ClientAssembly.swift`, and `apps/client/spassemble.m`
(the device's own assembly of a newer build) must produce byte-identical client images. If you change
one, change all three, and run the opt-in comparison tests.

## A new game build

When a game patch adds an import the shims don't cover, the companion's bind check says the version
isn't supported yet (maintainers can run `scripts/recon/check-patch.sh`). To fix it:

1. Let Battle.net update the game on your Mac (regenerating needs the installed clients).
2. Run `scripts/recon/regen.sh xros`, then `scripts/recon/regen.sh ios`. The second run must show no
   diff; if it does, the platforms need separate generated sets. Scratch goes to `work/regen/`.
3. Review the `shims/generated/` diff like any other source change. Generated stubs only log: an import
   the client really uses needs a hand-written implementation (`gen_stubs.py`'s `EXTRA_CODE` /
   `EXTRA_INCLUDES`).
4. Rebuild (`shims/build.sh`, `apps/companion/build.sh`), run the tests, and try each affected flavor
   on a device.

The generated sources contain only symbol and library names. If you find anything else from the
client in them, stop and say so in the PR.

## Style

- Match the code around you. Comments are dense and explain *why* (the platform constraint, the
  measurement, what broke without it), not what the next line does.
- Swift matches `apps/companion/Sources`. Logic you can test goes in small types covered by
  `apps/companion/Tests`.
- Shell scripts use `set -e` (`set -euo pipefail` in new ones) and fail with a specific error that says
  what to do next.
- Names use the `sp` / `SP_` prefix (`libspAppKit`, `SPEvent`, `SP_SCALE`).
- Put scratch output in `$TMPDIR` or `build/`, never in the tree.

## Pull requests

- Open an issue first for anything bigger than a small fix, so we can agree on the approach. For a
  broken game patch, use the "New game patch broke it" issue form (the companion's **Report It…** link
  fills it in).
- Keep each PR to one focused change, with commit messages in the repo's style.
- CI must pass: the scrub and no-hardcoding checks, idevice and zsign built from source, the shim
  builds for both platforms, the unsigned companion build, and the companion tests.
- Say what you tested and how: unit tests, which flavor on which device and OS version. Reviewers
  can't see your headset, so include details for anything that only shows on a device.
- Attach logs only from **Help > Export Diagnostics…**, which leaves your credentials out and blanks
  device identifiers and personal details. Never paste `net.battle` contents, your Battle.net sign-in, a signing identity,
  or a pairing record.
- User-visible changes get a line under `## [Unreleased]` in `CHANGELOG.md`, written for users.
- Report security issues privately, as described in [SECURITY.md](SECURITY.md). Don't open a public
  issue for them.

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
