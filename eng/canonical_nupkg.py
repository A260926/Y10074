#!/usr/bin/env python3
"""Compute a canonical SHA-256 hash of a .nupkg.

A .nupkg is a ZIP container. Two packages built from the same source and
commit can differ byte-for-byte solely because of volatile ZIP container
metadata (entry timestamps, field ordering produced by the packer).

The canonical hash intentionally keeps every payload-relevant property
(entry names in sorted order, uncompressed size, and SHA-256 of each
entry's bytes, including Hjson.nuspec) and ignores only the ZIP framing
metadata. It therefore does NOT make the .nupkg metadata irrelevant: any
change to the nuspec, the embedded XML docs, binaries, or extra/missing
entries changes the hash.

Usage: canonical_nupkg.py PATH-TO-NUPKG
Prints "<sha256>  <basename>" and exits non-zero on error.
"""

import hashlib
import sys
import zipfile


def canonical_hash(path: str) -> str:
    digest = hashlib.sha256()
    with zipfile.ZipFile(path) as archive:
        infos = sorted(archive.infolist(), key=lambda info: info.filename)
        names = [info.filename for info in infos]
        if len(names) != len(set(names)):
            raise ValueError("duplicate zip entry names in package")
        for info in infos:
            if info.filename.endswith("/"):
                continue
            payload = archive.read(info.filename)
            digest.update(b"entry:")
            digest.update(info.filename.replace("\\", "/").encode("utf-8"))
            digest.update(b"\0size:")
            digest.update(str(len(payload)).encode("ascii"))
            digest.update(b"\0sha256:")
            digest.update(hashlib.sha256(payload).digest())
            digest.update(b"\n")
    return digest.hexdigest()


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} PATH-TO-NUPKG", file=sys.stderr)
        return 2
    try:
        print(f"{canonical_hash(argv[1])}  {argv[1]}")
    except (OSError, zipfile.BadZipFile, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
