# isideload, vendored

[isideload](https://github.com/nab138/isideload) (MIT, by nab138), the `isideload/` crate of its repository at
commit `326e56229d0727cb6e7b34c8cf03e37e2cd3e17d` (version 0.5.2): the commit `research/isideload` pinned
and tested on a free and a paid team. Its `LICENSE` is the repository's. The crate's README isn't copied.

## Why it's vendored

isideload depends on [apple-codesign-quick](https://crates.io/crates/apple-codesign-quick), its own code
signer, unconditionally, and that crate is LGPL-2.1-or-later. `slashplayed-setup` is one statically linked
binary, so linking the crate would bind the whole binary to the LGPL's relinking terms, even though the tool
never calls the signer: it signs with zsign (`apps/setup/build.rs`). The owner chose (2026-11-01) to patch
the dependency out, here in the repository, so the change is reviewed with the rest.

## What changed

`../isideload.patch` is the whole diff from the upstream commit (`patch -p1` in a copy of the upstream
repository, the folder that holds `isideload/`, applies it and gives this copy):

- **Cargo.toml:** `apple-codesign-quick` is optional, behind a new `sideload` feature, which is on by
  default as before. `slashplayed-setup` turns default features off. The `readme` key is gone, since the
  README isn't copied.
- **src/lib.rs:** the `sideload` module (the high-level `Sideloader`, its signer, and its install path)
  builds only with that feature. A new `certs` module holds Apple's root and WWDR G3 certificates, which
  were `sideload::cert_identity`'s, because the GrandSlam client pins the root (`auth/grandslam.rs`).
  `cert_identity` re-exports them.
- **src/util/callbacks.rs:** the callback types that name `sideload`'s types build only with the feature.

Nothing in the sign-in, anisette, or developer-services code changed. `scripts/check-tree.sh` fails if
`Cargo.toml` stops making the signer optional, and `scripts/crate-notices.py --deny-copyleft` (run by
`apps/setup/package.sh` for every release build) fails if any GPL-family crate is linked.

## Updating

1. Copy the new commit's `isideload/` here.
2. Apply `../isideload.patch`, and fix whatever no longer applies.
3. Regenerate the patch against the new commit.
4. Update the commit above, and run `apps/setup`'s tests and a device run.

The cleaner fix is upstream: a PR to isideload that makes the signer optional would let this go back to a
pinned git dependency.
