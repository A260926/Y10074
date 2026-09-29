#!/usr/bin/env python3
"""Validate the contents of the published Hjson .nupkg.

Fails (non-zero exit) if:
  * the package output directory holds anything other than exactly one .nupkg
  * the package contains entries outside the fixed expected allow-list
    (this also rejects stray test/assets fixtures and temporary files)
  * lib/ contains assets for a target framework other than the expected one(s)
  * LICENSE or the generated XML documentation is missing/empty
  * the nuspec declares any package dependency (cli/sample must not leak in)
  * the license is not packaged as the repo LICENSE file

Usage:
  package_gate.py --nupkg FILE --package-id ID --tfm TFM [--tfm TFM ...]
                  [--package-dir DIR] [--license-file FILE]
"""

import argparse
import posixpath
import sys
import zipfile
import xml.etree.ElementTree as ET

NUSPEC_NS = "http://schemas.microsoft.com/packaging/2012/06/nuspec.xsd"


def qname(tag: str) -> str:
    return f"{{{NUSPEC_NS}}}{tag}"


class Report:
    def __init__(self) -> None:
        self.failures: list[str] = []

    def check(self, condition: bool, name: str, detail: str = "") -> bool:
        if condition:
            print(f"PASS  {name}")
        else:
            message = f"FAIL  {name}" + (f" ({detail})" if detail else "")
            print(message)
            self.failures.append(message)
        return condition

    def info(self, name: str, detail: str) -> None:
        print(f"INFO  {name}: {detail}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--nupkg", required=True)
    parser.add_argument("--package-id", required=True)
    parser.add_argument("--tfm", action="append", default=[])
    parser.add_argument("--package-dir")
    parser.add_argument("--license-file")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    report = Report()

    if args.package_dir:
        import os

        entries = sorted(os.listdir(args.package_dir))
        nupkgs = [e for e in entries if e.endswith(".nupkg")]
        report.check(
            len(nupkgs) == 1,
            "package-dir/single-nupkg",
            f"found {nupkgs!r} plus {[e for e in entries if not e.endswith('.nupkg')]!r}",
        )
        report.check(
            entries == nupkgs,
            "package-dir/no-stray-files",
            f"unexpected files: {[e for e in entries if not e.endswith('.nupkg')]!r}",
        )

    try:
        archive = zipfile.ZipFile(args.nupkg)
        names = {info.filename for info in archive.infolist() if not info.filename.endswith("/")}
    except (OSError, zipfile.BadZipFile) as exc:
        print(f"FAIL  cannot open package: {exc}")
        return 1

    expected = {
        "_rels/.rels",
        "[Content_Types].xml",
        "package/services/metadata/core-properties/nuget.psmdcp",
        f"{args.package_id}.nuspec",
        "LICENSE",
        "README.md",
    }
    for tfm in args.tfm:
        expected.add(posixpath.join("lib", tfm, f"{args.package_id}.dll"))
        expected.add(posixpath.join("lib", tfm, f"{args.package_id}.xml"))

    report.check(names == expected, "entries/allow-list",
                 f"unexpected={sorted(names - expected)!r} missing={sorted(expected - names)!r}")

    lib_entries = sorted(n for n in names if n.startswith("lib/"))
    allowed_lib = {posixpath.join("lib", tfm, f) for tfm in args.tfm
                   for f in (f"{args.package_id}.dll", f"{args.package_id}.xml")}
    report.check(set(lib_entries) <= allowed_lib, "lib/expected-tfms-only",
                 f"lib entries: {lib_entries!r}")

    license_bytes = b""
    xml_bytes = b""
    try:
        license_bytes = archive.read("LICENSE")
    except KeyError:
        pass
    report.check(len(license_bytes.strip()) > 0, "LICENSE/present-and-non-empty")
    if args.license_file and license_bytes:
        with open(args.license_file, "rb") as handle:
            report.check(handle.read() == license_bytes,
                         "LICENSE/matches-repository-file", args.license_file)

    for tfm in args.tfm:
        xml_name = posixpath.join("lib", tfm, f"{args.package_id}.xml")
        try:
            xml_bytes = archive.read(xml_name)
        except KeyError:
            pass
        report.check(len(xml_bytes) > 0 and b"<doc" in xml_bytes,
                     f"xml-docs/{tfm}", xml_name)

    forbidden_markers = ("assets/", "_test.", "test.dll", "cli.dll", "sample.dll",
                         ".pdb", ".deps.json", "src/", "test/")
    leaked = sorted(n for n in names if any(marker in n for marker in forbidden_markers))
    report.check(not leaked, "no-test-assets-or-app-binaries", f"{leaked!r}")

    try:
        nuspec_root = ET.fromstring(archive.read(f"{args.package_id}.nuspec"))
    except (KeyError, ET.ParseError) as exc:
        report.check(False, "nuspec/parseable", str(exc))
        nuspec_root = None

    if nuspec_root is not None:
        metadata = nuspec_root.find(qname("metadata"))
        if metadata is None:
            report.check(False, "nuspec/metadata")
        else:
            identity = metadata.find(qname("id"))
            report.check(identity is not None and identity.text == args.package_id,
                         "nuspec/id", identity.text if identity is not None else "missing")
            version = metadata.find(qname("version"))
            report.check(version is not None and bool(version.text.strip()),
                         "nuspec/version-single-source",
                         version.text if version is not None else "missing")
            report.info("nuspec/version", version.text.strip() if version is not None and
                        version.text else "missing")
            license_el = metadata.find(qname("license"))
            report.check(
                license_el is not None and license_el.get("type") == "file"
                and (license_el.text or "").strip() == "LICENSE",
                "nuspec/license-file",
                ET.tostring(license_el, encoding="unicode") if license_el is not None else "missing",
            )
            dependencies = metadata.find(qname("dependencies"))
            dep_elements = []
            if dependencies is not None:
                dep_elements = dependencies.findall(qname("dependency"))
                for group in dependencies.findall(qname("group")):
                    dep_elements.extend(group.findall(qname("dependency")))
            report.check(
                not dep_elements,
                "nuspec/no-package-dependencies",
                ", ".join(ET.tostring(d, encoding="unicode") for d in dep_elements),
            )

    print()
    if report.failures:
        print(f"PACKAGE GATE FAILED: {len(report.failures)} check(s)")
        for failure in report.failures:
            print(f"  {failure}")
        return 1
    print("PACKAGE GATE PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
