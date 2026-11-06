---
name: preparing-releases
description: "Bumps Slashplayed's release version and cuts the changelog for it, as a `chore(release): prepare X.Y.Z` PR. Use when asked to prepare a release, prepare X.Y.Z, bump the version, or cut the changelog. Stops before the tag and the release, which are the owner's."
---

# Preparing a release

One PR, branched off `main`, that makes the tree ready for the owner to tag `vX.Y.Z`. Past examples:
`git show 97ee042` (1.3.0) and `026aa7c` (1.2.0); since then the Cargo files move too.

## 1. Pick the version

Read `## [Unreleased]` in `CHANGELOG.md` against the current `MARKETING_VERSION` in
`apps/companion/project.yml`:

- anything under `Added` or `Changed`: a minor bump (1.3.0 → 1.4.0);
- only `Fixed` or `Known issues`: a patch bump (1.3.0 → 1.3.1);
- `Removed`, or something that stops working for someone (a device, an OS, or a game dropped): stop
  and ask the owner whether it's a major bump.

When the owner named a version, use it, but say so in the PR if the entries suggest another. An empty
`[Unreleased]` means there's nothing to release: stop and say so.

## 2. Edit

All to the same `X.Y.Z`:

- `apps/companion/project.yml`: `MARKETING_VERSION: "X.Y.Z"` (the source of truth; release.sh and
  release.yml check the tag against it). Leave `CURRENT_PROJECT_VERSION` alone; the release build stamps it.
- `apps/companion-rs/Cargo.toml`: the package's `version` (check-tree requires it to equal
  `MARKETING_VERSION`), and `apps/companion-rs/Cargo.lock`: the `version` under
  `name = "slashplayed-companion"`.
- `CHANGELOG.md`: insert `## [X.Y.Z] - YYYY-MM-DD` (today, `date +%F`, never an `XX` placeholder: the
  signed build refuses it) on its own line, with a blank line on each side, directly under
  `## [Unreleased]`. The existing entries become the release's and Unreleased is left empty. Don't
  reword or reorder the entries.
- `.github/ISSUE_TEMPLATE/bug_report.yml`: the companion version's `placeholder: X.Y.Z (1)`.
- `.github/ISSUE_TEMPLATE/game_patch.yml`: the companion version's `placeholder: X.Y.Z`.

Then `rg -n -F '<old version>'` across those files: nothing should be left, apart from the old section
heading in `CHANGELOG.md`.

## 3. Check

```sh
scripts/check-tree.sh
(cd apps/companion-rs && cargo metadata --locked --offline --format-version 1 >/dev/null)   # lock in step
# release.sh's own notes extraction, as a signed final release runs it, on the new section:
v=X.Y.Z; out=$(mktemp -d)
VERSION=$v MARKETING=$v SIGNED=yes CHANGELOG=CHANGELOG.md OUT=$out bash -euo pipefail \
  -c "$(sed -n '/^NOTES_VERSION=/,/^echo "Release notes:/p' scripts/release/release.sh)"
cat "$out/notes.md"; rm -rf "$out"
```

The notes must be exactly the entries that were under Unreleased, and the extraction must not warn about
a placeholder date.

## 4. Commit and open the PR

`git config core.hooksPath scripts/hooks` once in the checkout, then one commit:

```
chore(release): prepare X.Y.Z

Bump MARKETING_VERSION and slashplayed-companion's version to X.Y.Z,
and cut the Unreleased changelog section (<a few words on what's in
it>) as X.Y.Z, dated today. A minor bump, as it adds a feature. The
issue templates' version placeholders follow.

Checked: check-tree, and release.sh's notes extraction on the new
section.
```

Say why that bump in the body ("A patch bump: fixes only."). Push the branch and open the PR with
`gh pr create`, the same text as its body. No changelog entry for the bump itself.

## Then it's the owner's

The owner merges, pushes tag `vX.Y.Z`, and approves the `release` environment (CLAUDE.md's Releasing
section). Never merge, tag, create or edit a release, or run release.yml yourself; end by saying the PR
is ready for that.
