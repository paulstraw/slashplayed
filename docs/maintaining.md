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
4. If the patch changed a game's version, set its `toc` in `apps/client/flavors.plist` and in both
   addons' TOCs (`addon/SPHover/SPHover.toc`, `addon/SPMovie/SPMovie.toc`), or the game flags the
   addons as out of date. `FlavorTests` checks the TOCs against `flavors.plist`.
5. Rebuild (`shims/build.sh`, `apps/companion/build.sh`), run the tests, and try each affected game on
   a device.

The generated sources hold only symbol and library names. If you find anything else from the client in
them, stop and say so in the PR.
