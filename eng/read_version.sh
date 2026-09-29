#!/usr/bin/env bash
# Print the package version from its single source: <Version> in
# Hjson/Hjson.csproj. Works regardless of the caller's working directory.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 - "$ROOT_DIR/Hjson/Hjson.csproj" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8-sig").read()
matches = re.findall(r"<Version>\s*([^<]+?)\s*</Version>", text)
if len(matches) != 1:
    raise SystemExit(f"expected exactly one <Version> in {sys.argv[1]}, found {len(matches)}")
print(matches[0])
PY
