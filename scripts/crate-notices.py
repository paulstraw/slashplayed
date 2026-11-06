#!/usr/bin/env python3
"""The license texts of every Rust crate a static library links, from the pinned source.

    scripts/crate-notices.py --toolchain <ver> --manifest-dir <crate> --features "<f...>" \
        --target <triple> [--target <triple>...] --title <text> --out <notices.txt> \
        [--own <crate>] [--deny-copyleft]

--own names the crate being built when it's this repository's own (apps/companion-rs's slashplayed-companion,
apps/client/spapple): it's MIT under the repository's LICENSE, which is its text. --deny-copyleft fails when a
linked crate can only be had under a GPL-family license (GPL, LGPL, AGPL): the host tool links statically,
so one would bind the whole binary (apps/companion-rs/vendor/isideload/VENDORED.md says why its signer is left out).

scripts/build-idevice.sh runs it for each platform after the build, with the same toolchain, crate,
features, and targets as the build, so the list is what cargo actually linked: `cargo tree` with normal
edges only (build scripts, dev-dependencies, and proc macros run at build time and don't ship), the union
over the targets (the Mac's two differ by a crate). Each crate's texts are the license files in its
source (cargo's registry copy, or for a crate of the workspace, its directory and the workspace root's),
plus Cargo.toml's license-file. A crate whose source has none (it declares a license and ships no
text) gets scripts/crate-licenses/<name>-<version>.txt, committed after checking its repository: named by
version, so a bump that adds such a crate fails until someone looks.

Writes <notices.txt>: the crates, one line each (name, version, its library's name where that differs,
SPDX expression, repository), then each distinct license text once with the crates that carry it, so the
many identical Apache-2.0 copies cost one. The companion's AcknowledgementsTests read the list back and
check it against the crates whose code is in the archive (its symbols name them). Fails, listing them,
when a crate has no license text: a build that ships it couldn't meet its license. No path from this
machine is written (bundle-resources.sh checks the app).
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys

# The texts for crates that ship none (see above).
EXTRA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "crate-licenses")

# File names a crate's license text goes by (Cargo's own license-file aside): LICENSE, LICENSE-MIT,
# LICENSE.txt, LICENCE, COPYING, COPYRIGHT, NOTICE, UNLICENSE, and the same in a LICENSES/ directory.
LICENSE_NAME = re.compile(r"^(licen[cs]e|copying|copyright|notice|unlicense)([-._].*)?$", re.I)


def die(msg):
    print(f"crate-notices: {msg}", file=sys.stderr)
    sys.exit(1)


def cargo(args, toolchain, cwd):
    try:
        r = subprocess.run(["rustup", "run", toolchain, "cargo", *args], cwd=cwd, check=True,
                           stdout=subprocess.PIPE, text=True)
    except subprocess.CalledProcessError as e:
        die(f"cargo {' '.join(args[:1])} failed ({e.returncode}) in {cwd}")
    return r.stdout


def license_files(directory):
    found = []
    for name in sorted(os.listdir(directory)):
        path = os.path.join(directory, name)
        if os.path.isfile(path) and LICENSE_NAME.match(name):
            found.append(path)
        elif os.path.isdir(path) and name.lower() == "licenses":
            found += [os.path.join(path, n) for n in sorted(os.listdir(path))
                      if os.path.isfile(os.path.join(path, n))]
    return found


def copyleft_only(spdx):
    """Whether every alternative of an SPDX expression (or the old "A/B" form) is GPL-family."""
    alternatives = [x for x in re.split(r"\s+OR\s+|/", spdx.replace("(", " ").replace(")", " ")) if x.strip()]
    return bool(alternatives) and all(re.search(r"\b(A|L)?GPL", x) for x in alternatives)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--toolchain", required=True)
    ap.add_argument("--manifest-dir", required=True)
    ap.add_argument("--features", required=True)
    ap.add_argument("--target", action="append", required=True)
    ap.add_argument("--title", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--own")
    ap.add_argument("--deny-copyleft", action="store_true")
    a = ap.parse_args()
    flags = ["--locked", "--no-default-features", "--features", a.features]

    # What's linked, per target: "name vX.Y.Z" (a path crate adds " (path)", a repeat " (*)").
    linked = set()
    for target in a.target:
        out = cargo(["tree", *flags, "--target", target, "-e", "normal,no-proc-macro",
                     "--prefix", "none", "-f", "{p}"], a.toolchain, a.manifest_dir)
        for line in out.splitlines():
            m = re.match(r"^(\S+) v(\S+)", line)
            if m:
                linked.add((m.group(1), m.group(2)))
    if not linked:
        die("cargo tree listed no crates")

    # Where each crate's source is, and what its Cargo.toml says about its license.
    meta = json.loads(cargo(["metadata", "--format-version", "1", *flags], a.toolchain, a.manifest_dir))
    root = meta["workspace_root"]
    packages = {}
    for p in meta["packages"]:
        packages.setdefault((p["name"], p["version"]), p)

    crates, texts, missing, copyleft = [], {}, [], []
    for name, version in sorted(linked):
        p = packages.get((name, version))
        if p is None:
            die(f"cargo tree lists {name} {version}, which cargo metadata doesn't have")
        if a.deny_copyleft and copyleft_only(p.get("license") or ""):
            copyleft.append(f"{name} {version} ({p.get('license')})")
        if a.own and name == a.own and p["source"] is None:
            crates.append((f"{name} {version}", "MIT (this repository's LICENSE)", "https://github.com/paulstraw/slashplayed"))
            # Its text too, so every crate listed has one (AcknowledgementsTests checks that).
            with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "LICENSE"), encoding="utf-8") as fh:
                body = fh.read().strip("\n")
            texts.setdefault(hashlib.sha256(body.encode()).hexdigest(), (body, []))[1].append(f"{name} {version}")
            continue
        directory = os.path.dirname(p["manifest_path"])
        files = license_files(directory)
        if p.get("license_file"):
            files.append(os.path.join(directory, p["license_file"]))
        # A crate of the workspace (idevice's own) is licensed by the repository's files.
        if p["source"] is None:
            d = directory
            while not files and os.path.commonpath([d, root]) == root:
                files = license_files(d)
                if d == root:
                    break
                d = os.path.dirname(d)
        # So is one from a git checkout (idevice, patched in by commit for apps/companion-rs): up to the checkout's
        # root, which cargo marks with .cargo-ok.
        elif p["source"].startswith("git+"):
            d = directory
            while not files:
                files = license_files(d)
                if os.path.exists(os.path.join(d, ".cargo-ok")) or d == os.path.dirname(d):
                    break
                d = os.path.dirname(d)
        extra = os.path.join(EXTRA, f"{name}-{version}.txt")
        if not files and os.path.isfile(extra):
            files = [extra]
        bodies = []
        for f in dict.fromkeys(os.path.realpath(f) for f in files):
            with open(f, encoding="utf-8", errors="replace") as fh:
                body = fh.read().strip("\n")
            if body.strip():
                bodies.append(body)
        if not bodies:
            missing.append(f"{name} {version} ({p.get('license') or 'no license field'})")
            continue
        repo = p.get("repository") or p.get("homepage") or f"https://crates.io/crates/{name}"
        # The workspace's own crates have no license field of their own (idevice-ffi): say whose they are.
        spdx = p.get("license") or ("see its repository's license" if p["source"] is None else "unspecified")
        # The library's name is what the archive's symbols use (md-5's is md5, rustls-webpki's webpki).
        lib = next((t["name"] for t in p["targets"] if set(t["kind"]) & {"lib", "rlib", "staticlib"}),
                   name).replace("-", "_")
        label = f"{name} {version}" + (f" (lib {lib})" if lib != name.replace("-", "_") else "")
        crates.append((label, spdx, repo))
        for body in bodies:
            texts.setdefault(hashlib.sha256(body.encode()).hexdigest(), (body, []))[1].append(f"{name} {version}")
    if copyleft:
        die("these linked crates are available only under a GPL-family license: " + ", ".join(copyleft))
    if missing:
        die("no license text in the source of: " + ", ".join(missing) +
            "\n  (a shipped crate needs one: find it in the crate's repository, or if it has none, write\n"
            f"  scripts/crate-licenses/<name>-<version>.txt as plist_ffi's is written)")

    width = max(len(label) for label, _, _ in crates)
    with open(a.out, "w", encoding="utf-8") as out:
        out.write(f"{a.title}\n\n")
        out.write(f"{len(crates)} crates, built with Rust {a.toolchain}. The Rust standard library's own notices "
                  "are in rust-std.html beside this file.\n\n")
        for label, spdx, repo in crates:
            out.write(f"  {label.ljust(width)}  {spdx}  {repo}\n")
        for body, users in sorted(texts.values(), key=lambda t: t[1][0]):
            out.write("\n" + "=" * 100 + "\n")
            out.write("The license text of: " + ", ".join(users) + "\n")
            out.write("-" * 100 + "\n\n" + body + "\n")
    print(f"crate-notices: {len(crates)} crates, {len(texts)} distinct texts into {a.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
