#!/usr/bin/env python3
"""Which of the shared CASC store's archives (Data/data/data.NNN) the given flavors use.

Usage: casc_archives.py <install root> <product>... [--sizes]
  products as in .build.info: wow_classic_era, wow_anniversary, wow_classic, wow

All flavors share one store (~150 GB with every game). A device that can't hold it all only needs the
archives holding the blocks of its flavors' builds: every encoded key in a build's encoding file
(which lists all of the build's content), plus the encoding file itself, looked up in the local
.idx files. Prints one archive number per line. Only reads the install.

The companion runs its Swift port (apps/companion/Sources/GameStore.swift); keep the two in step.

Formats: https://wowdev.wiki/CASC (local .idx v7, encoding file, BLTE).
"""
import os
import plistlib
import struct
import sys
import zlib


def table(path):
    """A |-separated table whose header names carry a !type suffix (.build.info, .flavor.info), as rows."""
    lines = open(path).read().splitlines()
    cols = [c.split("!")[0] for c in lines[0].split("|")]
    return [dict(zip(cols, l.split("|"))) for l in lines[1:] if l]


def build_info(root):
    """.build.info's rows by product, with a row for each installed game it doesn't list: the build config
    in Data/config for the build of the client in the game's folder (GameStore.installTable; Battle.net's
    file doesn't always list every game in the install)."""
    rows = {r["Product"]: r for r in table(os.path.join(root, ".build.info"))}
    configs = None
    for folder in sorted(os.listdir(root)):
        info = os.path.join(root, folder, ".flavor.info")
        if not (len(folder) > 2 and folder[0] == folder[-1] == "_" and os.path.isfile(info)):
            continue
        product = (table(info) or [{}])[0].get("Product Flavor")
        if not product or product in rows:
            continue
        if configs is None:
            d = os.path.join(root, "Data/config")
            configs = {k: c for k, c in ((k, config(root, k)) for a in os.listdir(d) for b in os.listdir(os.path.join(d, a))
                                         for k in os.listdir(os.path.join(d, a, b))) if "build-uid" in c}
        for app in sorted(a for a in os.listdir(os.path.join(root, folder)) if a.endswith(".app")):
            try:
                version = plistlib.load(open(os.path.join(root, folder, app, "Contents/Info.plist"), "rb"))["CFBundleVersion"]
            except (OSError, KeyError, plistlib.InvalidFileException):
                continue
            short, _, build = version.rpartition(".")
            name = f"-{build}patch{short}"
            key = next((k for k in sorted(configs) if configs[k]["build-uid"] == [product]
                        and name in (configs[k].get("build-name") or [""])[0]), None)
            if short and key:
                rows[product] = {"Product": product, "Build Key": key, "Version": version}
                break
    return rows


def config(root, key):
    path = os.path.join(root, "Data/config", key[:2], key[2:4], key)
    out = {}
    for line in open(path):
        if " = " in line:
            k, v = line.strip().split(" = ", 1)
            out[k] = v.split()
    return out


def read_indexes(root):
    """9-byte encoded key prefix -> (archive, offset, size), from the newest .idx per bucket."""
    d = os.path.join(root, "Data/data")
    newest = {}
    for f in os.listdir(d):
        if f.endswith(".idx") and len(f) == 14:
            bucket, version = int(f[:2], 16), int(f[2:10], 16)
            if bucket not in newest or version > newest[bucket][0]:
                newest[bucket] = (version, f)
    idx = {}
    for _, f in newest.values():
        b = open(os.path.join(d, f), "rb").read()
        (version,) = struct.unpack_from("<H", b, 8)
        size_len, offs_len, key_len, offs_bits = b[12], b[13], b[14], b[15]
        assert version == 7 and (size_len, offs_len, key_len, offs_bits) == (4, 5, 9, 30), f
        (n,) = struct.unpack_from("<I", b, 0x20)
        for p in range(0x28, 0x28 + n, 18):
            key = b[p:p + 9]
            loc = int.from_bytes(b[p + 9:p + 14], "big")
            (size,) = struct.unpack_from("<I", b, p + 14)
            idx[key] = (loc >> 30, loc & ((1 << 30) - 1), size)
    return idx


def blte(data):
    assert data[:4] == b"BLTE", "not BLTE"
    (hsize,) = struct.unpack_from(">I", data, 4)
    if hsize == 0:
        chunks = [(len(data) - 8, None)]
        p = 8
    else:
        count = int.from_bytes(data[9:12], "big")  # after a flags byte
        chunks = [struct.unpack_from(">II", data, 12 + i * 24) for i in range(count)]
        p = hsize
    out = bytearray()
    for csize, _ in chunks:
        c = data[p:p + csize]
        p += csize
        mode = c[:1]
        if mode == b"N":
            out += c[1:]
        elif mode == b"Z":
            out += zlib.decompress(c[1:])
        else:
            raise ValueError(f"BLTE chunk mode {mode!r}")
    return bytes(out)


def read_file(root, idx, ekey_hex):
    archive, offset, size = idx[bytes.fromhex(ekey_hex)[:9]]
    with open(os.path.join(root, f"Data/data/data.{archive:03d}"), "rb") as fh:
        fh.seek(offset)
        raw = fh.read(size)
    return archive, blte(raw[30:])  # 30-byte local header before the BLTE data


def encoding_ekeys(enc):
    """Every encoded key in an encoding file's content-key pages."""
    assert enc[:2] == b"EN"
    ckey_len, ekey_len = enc[3], enc[4]
    cpage_kb = struct.unpack_from(">H", enc, 5)[0]
    cpages = struct.unpack_from(">I", enc, 9)[0]
    espec = struct.unpack_from(">I", enc, 18)[0]
    p = 22 + espec + cpages * (ckey_len + 16)
    for page in range(cpages):
        q, end = p + page * cpage_kb * 1024, p + (page + 1) * cpage_kb * 1024
        while q < end:
            count = enc[q]
            if count == 0:
                break
            q += 1 + 5 + ckey_len
            for _ in range(count):
                yield enc[q:q + ekey_len]
                q += ekey_len


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    root, products = args[0], args[1:]
    info = build_info(root)
    idx = read_indexes(root)
    need = {}
    for product in products:
        build = config(root, info[product]["Build Key"])
        enc_ekey = build["encoding"][1]
        archive, enc = read_file(root, idx, enc_ekey)
        need.setdefault(archive, 0)
        total = found = 0
        for ekey in encoding_ekeys(enc):
            total += 1
            hit = idx.get(ekey[:9])
            if hit:
                found += 1
                need[hit[0]] = need.get(hit[0], 0) + hit[2]
        print(f"{product}: {found} of {total} encoded keys stored locally", file=sys.stderr)
    size = sum(os.path.getsize(os.path.join(root, f"Data/data/data.{a:03d}")) for a in need)
    print(f"{len(need)} archives, {size / 1e9:.1f} GB (blocks used: {sum(need.values()) / 1e9:.1f} GB)",
          file=sys.stderr)
    for a in sorted(need):
        print(a)


if __name__ == "__main__":
    main()
