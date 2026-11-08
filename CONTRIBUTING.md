# Contributing to Slashplayed

Thanks for helping out. Slashplayed has three parts: the Mac companion app (`apps/companion`), the
device app (`apps/client`), and the shim libraries the device app loads (`shims/`).
[docs/architecture.md](docs/architecture.md) explains how they fit together. Read it before you change
the pipeline, the shims, or the launcher.

## Setup

Install these first:

- An Apple Silicon Mac on macOS 15 or later, with Xcode 27 and its visionOS and iOS platforms and
  Metal toolchain.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.
- [rustup](https://rustup.rs). The build scripts pick their own pinned Rust toolchain.
- Python 3.
- To change the addons: `cc` and Lua, for `addon/test/test.sh`.
- For device work: an Apple Account signed in to Xcode (a paid team, or a free Personal Team);
  a Vision Pro, an M1-or-later iPad or the A17 Pro iPad mini, or an iPhone 15 Pro or later, paired, with Developer Mode on;
  and [LocalDevVPN](https://apps.apple.com/app/id6755608044) on the device.

Then, from a fresh clone (idevice and the font are once, and again after their pins change):

```sh
scripts/build-idevice.sh macos   # idevice, from source, into work/idevice/
scripts/build-idevice.sh ios
scripts/build-idevice.sh xros
scripts/fetch-font.sh            # the start screen's font, into work/fonts/
apps/companion/build.sh          # build/companion/Slashplayed Companion.app, shims included
apps/companion/test.sh           # the companion's unit tests
```

`shims/build.sh <xros|ios>` builds the shims on their own. The companion you build works like the
released one: it finds your team in Xcode and your device with `devicectl`, and fetches the game
client from Blizzard's CDN. It needs no configuration and no game install on the Mac.

## Making a change

- Match the code around you. Comments explain *why* (the platform limit, the measurement, what broke
  without it), not what the next line does.
- Swift matches `apps/companion/Sources`. Put logic you can test in small types covered by
  `apps/companion/Tests`.
- New shell scripts use `set -euo pipefail` and fail with a specific error that says what to do next.
- Names use the `sp` or `SP_` prefix (`libspAppKit`, `SPEvent`, `SP_SCALE`).
- Put scratch files in `$TMPDIR` or `build/`, never in the tree.
- Run the tests, and `scripts/check-tree.sh` before every commit. CI runs it too: it catches scrubbed
  material, device IDs, team IDs, and signing hashes.
- Commit messages use [Conventional Commits](https://www.conventionalcommits.org/): a subject of at
  most 72 characters, `type(scope): summary`, in the imperative, with no period; then a blank line and
  a body, wrapped at 72, that says why. Types: `feat`, `fix`, `docs`, `test`, `refactor`, `perf`,
  `build`, `ci`, `chore`, `revert`. Scopes: `companion`, `client`, `helper`, `shims`, `addon`,
  `recon`, `release`, `research/<harness>`. Leave the scope off for `docs` and `ci` commits and for a
  change spread across the repo. Turn on the hook that checks this once per clone:
  `git config core.hooksPath scripts/hooks`.

## Pull requests

- Open an issue first for anything bigger than a small fix, so we can agree on the approach. For a
  broken game patch, use the "New game patch broke it" issue form (the companion's **Report It…** link
  fills it in).
- Keep each PR to one focused change.
- CI must pass: the tree checks, the addon tests, idevice built from source, the unsigned companion
  build (with the shims for both platforms), the companion tests, the guest loader's test, and
  slashplayed-companion's build and tests on Linux and Windows.
- Say what you tested and how: unit tests, and which game on which device and OS version. Reviewers
  can't see your device, so describe anything that only shows there.
- Attach logs only from **Help > Export Diagnostics…**. It leaves out credentials and blanks device
  identifiers and personal details. Never paste `net.battle` contents, your Battle.net sign-in, a
  signing identity, or a pairing record.
- A change players would notice gets a line under `## [Unreleased]` in `CHANGELOG.md`, written for them.
- Report security issues privately, as [SECURITY.md](SECURITY.md) describes, not in a public issue.

## Hard rules

- **No Blizzard bytes, ever.** No client binaries (thinned or not), game data, metallibs from the
  client, or logs and crash reports that hold credentials: not in commits, PRs, issues, CI, test
  fixtures, or release artifacts. Build test fixtures from our own code (`research/loadertest` is the
  model). `work/` holds clients and game data: never commit it or attach anything from it.
- **Credentials are never read, printed, or logged.** That covers `net.battle` prefs and the exported
  credentials file (sizes and timestamps only), the Battle.net email and password (only the launcher's
  sign-in, `apps/client/splogin.m`, handles them), signing identities (`.p12` files and their
  passwords), and pairing records. Files that hold them are 0600 and deleted once copied.
- **The scrub line.** Apple-platform findings are welcome in full (the ones in
  [docs/architecture.md](docs/architecture.md)). Client internals are not: no offsets into the client,
  no addresses of its functions, and nothing about credential formats. Describe the client at the level
  architecture.md does, for example "the client rewrites its own code at startup; the shim services that
  through an alias mapping".

[CLAUDE.md](CLAUDE.md) has the full rules.

## Advanced

The dev scripts and `config/local.env`, the device app's assembly in two places, the opt-in tests against a real install, and the steps after a game patch are in
[docs/maintaining.md](docs/maintaining.md).

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
