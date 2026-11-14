# Maintaining Slashplayed

Material for maintainers and for contributors working past the basics. Start with
[CONTRIBUTING.md](../CONTRIBUTING.md); its hard rules apply here too.

## The dev scripts and `config/local.env`

The dev scripts (`apps/client/build.sh`, `run.sh`, `seed.sh`, `seed-client.sh`, `pull-logs.sh`, and the
research harnesses) sign and install without the companion. They read your values from the environment or from
`config/local.env`, which is gitignored:

```sh
cp config/local.env.example config/local.env   # then fill in SP_TEAM, SP_SIGN_ID, and SP_BUNDLE_ID
SP_PLATFORM=ios apps/client/build.sh            # build, sign, and install
SP_PLATFORM=ios SP_NO_INSTALL=1 apps/client/build.sh   # build only, no device needed
SP_PLATFORM=ios SP_FLAVOR=classic_era apps/client/seed-client.sh   # the Mac's client onto the device
SP_PLATFORM=ios SP_FLAVOR=classic_era apps/client/run.sh
```

`SP_PLATFORM` is `xros` (the default) or `ios`. `SP_FLAVOR` is `classic_era`, `anniversary`, `classic`
(MoP Classic, Battle.net's `_classic_`), `retail`, or `forever`. `apps/client/build.sh` builds the app with
no game in it, as the companion does. A game's client goes into the app's data container on its own:
`seed-client.sh` copies the Mac's installed one, or the device installs it when you tap the game. The
scripts fail loudly when a value is missing.
**Never commit your own values**: no device UDIDs, team IDs, or signing hashes in tracked files.

Pick your bundle ID once. A new bundle ID gets a new, empty app container on the device, so every game
starts over: its data is fetched again as it plays, or copied again (over an hour for Retail on the
headset).

## The device app in two places

`apps/client/build.sh` and `apps/companion/Sources/ClientAssembly.swift` both assemble the device app, with
no game in it. If you change what goes into it, change both. The game's client is never changed: the
companion, `seed-client.sh`, and the device itself all put the same unchanged arm64 slice in
`Library/spgames/`, and the launcher loads it with spguest (`apps/client/spguest.c`; its test is
`apps/client/guesttest/`, which CI runs).

## Opt-in tests

Some companion tests are off by default because they compare against your own game install or
Blizzard's CDN: `TEST_RUNNER_SP_CHECK_INSTALLED=1`, `TEST_RUNNER_SP_COMPARE_STORE=1`,
`TEST_RUNNER_SP_COMPARE_CDN=1`, and `TEST_RUNNER_SP_COMPARE_BUILDS=1`. Each test's doc comment says what it needs. Set one in the
environment of `apps/companion/test.sh`. They read Blizzard files locally (the CDN one fetches into
`$TMPDIR`) and must never write anything from them into the repo.

## Test hooks on the device

`apps/client/run.sh` passes these to the launcher; a launch from the home screen has no environment, so
none of them ever reaches a player. Its header says what each does in full.

| Variable | What it does |
|---|---|
| `SP_START=1` | Shows the start screen, as a home-screen launch does, instead of naming a game. |
| `SP_START_DRILL=<state>` | Opens the start screen with Settings in one state, for screenshots with no taps (the states are listed in `spsettings.swift`). |
| `SP_START_TEXT_SIZE=<XS…XXXL, AX1…AX5>` | The start screen's Dynamic Type size. |
| `SP_PATCH_SERVICE=<url or path>` | Replaces Blizzard's patch service: a base URL, or a folder in the app's home holding `<product>/versions` (and optionally `cdns`). |
| `SP_PATCH_CELLULAR=1` | The patch check treats the network as cellular, so it asks before downloading. |
| `SP_PATCH_CHOOSE=<button title>` | Presses that button on the patch screen a second after it shows. |
| `SP_PATCH_DRILL`, `SP_LOADING_DRILL` | Show the newer-build screen or the loading screen in a given state. |
| `SP_REGION_COUNTRY`, `SP_REGION_LANGUAGES` | Stand in for the device's region and preferred languages, which decide an installed game's region. |
| `SP_RENEW=now\|off` | Renews the app's profiles at once, or never. |
| `SP_PROFILES_DRILL=1` | Installs `Documents/spprofiles/*.mobileprovision` through the JIT helper, or lists the app's profiles. |
| `SP_SKIP_INTRO=1` | Skips the intro movie and Retail's Screen Narrator question, in the device's `Config.wtf`. |
| `SP_SCALE=1\|2` | Overrides Settings > Display's scale. |
| `SP_INPUT_LOG_MAX=<n>` | Logs `n` input events (0 for no cap) and every key with what it types: never type a real password on such a run. |

## After a game patch

When a patch adds an import the shims don't cover, the companion's bind check says the version isn't
supported yet. `scripts/recon/check-patch.sh` gives the same answer. To fix it:

1. Let Battle.net update the game on your Mac. Regenerating needs the installed clients.
2. Run `scripts/recon/regen.sh xros`, then `scripts/recon/regen.sh ios`. It needs Python 3 with PyYAML
   (`pip install pyyaml`). The second run must show no diff; if it does, the platforms need separate
   generated sets. Scratch goes to `work/regen/`.
3. Review the `shims/generated/` diff like any other source change. Generated stubs only log: an import
   the client really uses needs a hand-written implementation (`EXTRA_CODE` or `EXTRA_INCLUDES` in
   `scripts/recon/gen_stubs.py`).
4. If the patch changed a game's version, set its `toc` in `apps/client/flavors.plist` and in the
   addons' TOCs (`addon/SPHover/SPHover.toc`, `addon/SPMovie/SPMovie.toc`,
   `addon/SPKeyboard/SPKeyboard.toc`), or the game flags the
   addons as out of date. `FlavorTests` checks the TOCs against `flavors.plist`.
5. Rebuild (`shims/build.sh`, `apps/companion/build.sh`), run the tests, and try each affected game on
   a device.

The generated sources hold only symbol and library names. If you find anything else from the client in
them, stop and say so in the PR.
