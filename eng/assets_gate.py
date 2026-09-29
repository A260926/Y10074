#!/usr/bin/env python3
"""Verify that every fixture under test/assets is discoverable by the test
project (copied next to the built test assembly) and that none of them leaks
into a published .nupkg.

Usage:
  assets_gate.py --source-dir DIR --test-output-dir DIR --nupkg FILE
"""

import argparse
import os
import posixpath
import sys
import zipfile


def relative_files(root: str) -> set[str]:
    result: set[str] = set()
    for base, _dirs, files in os.walk(root):
        for name in files:
            full = os.path.join(base, name)
            result.add(os.path.relpath(full, root).replace(os.sep, "/"))
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-dir", required=True)
    parser.add_argument("--test-output-dir", required=True)
    parser.add_argument("--nupkg", required=True)
    args = parser.parse_args()

    failures: list[str] = []

    source = relative_files(args.source_dir)
    copied = relative_files(args.test_output_dir)
    print(f"INFO  source fixtures: {len(source)}")

    missing = sorted(source - copied)
    if missing:
        failures.append(f"not discovered by test project: {missing!r}")
        print(f"FAIL  all fixtures copied to test output ({len(missing)} missing)")
    else:
        print(f"PASS  all {len(source)} test/assets fixtures copied to test output")

    with zipfile.ZipFile(args.nupkg) as archive:
        packaged = {i.filename for i in archive.infolist() if not i.filename.endswith("/")}
    packaged_assets = sorted(
        n for n in packaged
        if "/assets/" in posixpath.dirname(n)
        or n.startswith("assets/")
        or n.endswith(("_test.hjson", "_test.json", "_result.hjson", "_result.json"))
    )
    if packaged_assets:
        failures.append(f"fixtures inside package: {packaged_assets!r}")
        print("FAIL  no test fixture inside package")
    else:
        print("PASS  no test fixture inside package")

    if failures:
        print()
        for failure in failures:
            print(f"  FAIL {failure}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
