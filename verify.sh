#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$SCRIPT_DIR
cd "$REPO_ROOT"
export PYTHONDONTWRITEBYTECODE=1

ARTIFACTS=$REPO_ROOT/artifacts
LOG_DIR=$ARTIFACTS/logs
SUMMARY=$ARTIFACTS/verification-summary.txt
LIBRARY=$REPO_ROOT/Hjson/Hjson.csproj
HELPER=$REPO_ROOT/build/verify-package.py
NUGET_PACKAGES=$ARTIFACTS/nuget-packages
export NUGET_PACKAGES

STAGES=(
  RESTORE
  FORMAT
  BUILD
  TEST
  FIXTURES
  PROJECT-GUARDS
  PACKAGE-A
  PACKAGE-GUARD
  NEGATIVE-GUARD
  CLEANUP
  PACKAGE-B
  REPRODUCIBLE
)

declare -a STAGE_STATUS
declare -a STAGE_DETAIL

CURRENT_STAGE=STARTUP
PACKAGE_ID=""
PACKAGE_VERSION=""
PACKAGE_FRAMEWORKS=()
COMMIT=""
FINAL_PACKAGE=SKIP
HASH_A=SKIP
HASH_B=SKIP

for ((stage_index = 0; stage_index < ${#STAGES[@]}; stage_index++)); do
  STAGE_STATUS[$stage_index]=SKIP
  STAGE_DETAIL[$stage_index]=""
done

stage_index_of() {
  local wanted=$1
  local index
  for ((index = 0; index < ${#STAGES[@]}; index++)); do
    if [[ "${STAGES[$index]}" == "$wanted" ]]; then
      printf '%s\n' "$index"
      return 0
    fi
  done
  return 1
}

set_stage_status() {
  local stage=$1
  local status=$2
  local index
  index=$(stage_index_of "$stage")
  STAGE_STATUS[$index]=$status
}

set_stage_detail() {
  local stage=$1
  local detail=$2
  local index
  index=$(stage_index_of "$stage")
  STAGE_DETAIL[$index]=$detail
}

stage_log_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

write_summary() {
  mkdir -p "$ARTIFACTS"
  {
    echo "HJSON VERIFICATION SUMMARY"
    for ((stage_index = 0; stage_index < ${#STAGES[@]}; stage_index++)); do
      stage=${STAGES[$stage_index]}
      detail=${STAGE_DETAIL[$stage_index]}
      if [[ -n "$detail" ]]; then
        printf '%-16s %-4s %s\n' "$stage" "${STAGE_STATUS[$stage_index]}" "$detail"
      else
        printf '%-16s %-4s\n' "$stage" "${STAGE_STATUS[$stage_index]}"
      fi
    done
    echo "PACKAGE_A_HASH   $HASH_A"
    echo "PACKAGE_B_HASH   $HASH_B"
    echo "FINAL_PACKAGE    $FINAL_PACKAGE"
    echo "FAILED_STAGE     ${CURRENT_STAGE:-NONE}"
  } > "$SUMMARY"
}

finish_failure() {
  local exit_code=$?
  if [[ "$CURRENT_STAGE" != STARTUP ]]; then
    local failed_index
    failed_index=$(stage_index_of "$CURRENT_STAGE")
    STAGE_STATUS[$failed_index]=FAIL
    STAGE_DETAIL[$failed_index]="see logs/$(stage_log_name "$CURRENT_STAGE").log"
  fi
  write_summary
  echo "Verification failed at $CURRENT_STAGE. See $SUMMARY and $LOG_DIR." >&2
  exit "$exit_code"
}
trap finish_failure ERR

run_stage() {
  CURRENT_STAGE=$1
  shift
  set_stage_status "$CURRENT_STAGE" RUNNING
  "$@" > "$LOG_DIR/$(stage_log_name "$CURRENT_STAGE").log" 2>&1
  set_stage_status "$CURRENT_STAGE" PASS
}

record_failure() {
  local stage=$1
  local message=$2
  CURRENT_STAGE=$stage
  set_stage_status "$stage" FAIL
  set_stage_detail "$stage" "$message"
  write_summary
  echo "Verification failed at $stage: $message" >&2
  exit 1
}

run_expected_failure() {
  local output
  local status=0
  trap - ERR
  set +e
  output=$("$@" 2>&1)
  status=$?
  set -e
  trap finish_failure ERR
  if [[ "$status" -eq 0 ]]; then
    return 1
  fi
  if ! grep -q "Package output directory contains extra files" <<< "$output"; then
    return 1
  fi
  printf '%s\n' "$output"
}

check_fixtures() {
  local copied_assets=0
  local output_dir
  while IFS= read -r -d '' output_dir; do
    copied_assets=$((copied_assets + 1))
    python3 "$HELPER" check-assets \
      --assets "$REPO_ROOT/test/assets" \
      --output-assets "$output_dir"
  done < <(find "$REPO_ROOT/test/bin/Release" -mindepth 2 -maxdepth 2 -type d -name assets -print0 | sort -z)

  if [[ "$copied_assets" -eq 0 ]]; then
    echo "No copied test/assets directories were found" >&2
    return 1
  fi
}

read_package_metadata() {
  python3 - "$LIBRARY" <<'PY'
import sys
from pathlib import Path
from xml.etree import ElementTree as ET

project = Path(sys.argv[1])
root = ET.fromstring(project.read_bytes().lstrip(b"\xef\xbb\xbf"))

def value(name):
    for element in root.iter():
        if element.tag.rsplit("}", 1)[-1] == name and element.text:
            return element.text.strip()
    return ""

package_id = value("PackageId") or value("AssemblyName")
frameworks = value("TargetFrameworks") or value("TargetFramework")
print(package_id)
print(value("Version"))
for framework in frameworks.split(";"):
    if framework:
        print(framework)
PY
}

clean_extra_file() {
  python3 - "$ARTIFACTS/package-a/verify-extra.txt" <<'PY'
import sys
from pathlib import Path

extra = Path(sys.argv[1])
extra.unlink(missing_ok=True)
if extra.exists():
    raise SystemExit(f"failed to remove {extra}")
PY
}

python3 - "$ARTIFACTS" <<'PY'
import shutil
import sys
from pathlib import Path

artifacts = Path(sys.argv[1])
if artifacts.exists():
    for child in artifacts.iterdir():
        if child.is_dir():
            shutil.rmtree(child)
        else:
            child.unlink()
artifacts.mkdir(parents=True, exist_ok=True)
(artifacts / "logs").mkdir()
PY

write_summary

run_stage RESTORE dotnet restore Hjson.slnx
run_stage FORMAT dotnet format Hjson.slnx --no-restore --verify-no-changes --verbosity minimal
run_stage BUILD dotnet build Hjson.slnx --no-restore -c Release
run_stage TEST dotnet test Hjson.slnx --no-restore --no-build -c Release --verbosity minimal
run_stage FIXTURES check_fixtures
run_stage PROJECT-GUARDS python3 "$HELPER" check-project --repository "$REPO_ROOT" --library "$LIBRARY"

METADATA_LINES=()
while IFS= read -r metadata_line; do
  METADATA_LINES+=("$metadata_line")
done < <(read_package_metadata)
PACKAGE_ID=${METADATA_LINES[0]}
PACKAGE_VERSION=${METADATA_LINES[1]}
PACKAGE_FRAMEWORKS=("${METADATA_LINES[@]:2}")
if [[ -z "$PACKAGE_ID" || -z "$PACKAGE_VERSION" || ${#PACKAGE_FRAMEWORKS[@]} -eq 0 ]]; then
  record_failure PROJECT-GUARDS "could not read package identity from the single library project"
fi
COMMIT=$(git -C "$REPO_ROOT" rev-parse HEAD)
PACKAGE_NAME=$PACKAGE_ID.$PACKAGE_VERSION.nupkg

run_stage PACKAGE-A dotnet pack "$LIBRARY" \
  --no-restore --no-build -c Release \
  -o "$ARTIFACTS/package-a" \
  -p:RepositoryCommit="$COMMIT"

run_stage PACKAGE-GUARD python3 "$HELPER" check-package \
  --repository "$REPO_ROOT" \
  --library "$LIBRARY" \
  --output-dir "$ARTIFACTS/package-a" \
  --tested-output "$REPO_ROOT/Hjson/bin/Release" \
  --commit "$COMMIT" \
  --write-hash "$ARTIFACTS/package-a.sha256"

printf 'this temporary file must be rejected by the package gate\n' > "$ARTIFACTS/package-a/verify-extra.txt"
CURRENT_STAGE=NEGATIVE-GUARD
set_stage_status "$CURRENT_STAGE" RUNNING
if ! run_expected_failure python3 "$HELPER" check-package \
  --repository "$REPO_ROOT" \
  --library "$LIBRARY" \
  --output-dir "$ARTIFACTS/package-a" \
  --tested-output "$REPO_ROOT/Hjson/bin/Release" \
  --commit "$COMMIT" \
  > "$LOG_DIR/negative-guard.log" 2>&1; then
  record_failure NEGATIVE-GUARD "extra package output file was not rejected"
fi
set_stage_status NEGATIVE-GUARD PASS
set_stage_detail NEGATIVE-GUARD "rejected intentionally added file"

run_stage CLEANUP clean_extra_file

run_stage PACKAGE-B dotnet pack "$LIBRARY" \
  --no-restore --no-build -c Release \
  -o "$ARTIFACTS/package-b" \
  -p:RepositoryCommit="$COMMIT"

run_stage REPRODUCIBLE python3 "$HELPER" check-package \
  --repository "$REPO_ROOT" \
  --library "$LIBRARY" \
  --output-dir "$ARTIFACTS/package-b" \
  --tested-output "$REPO_ROOT/Hjson/bin/Release" \
  --commit "$COMMIT" \
  --write-hash "$ARTIFACTS/package-b.sha256"

HASH_A=$(awk '{print $1}' "$ARTIFACTS/package-a.sha256")
HASH_B=$(awk '{print $1}' "$ARTIFACTS/package-b.sha256")
if [[ "$HASH_A" != "$HASH_B" ]]; then
  record_failure REPRODUCIBLE "normalized package hashes differ"
fi
set_stage_detail REPRODUCIBLE "$HASH_A"
FINAL_PACKAGE=$ARTIFACTS/package-a/$PACKAGE_NAME
CURRENT_STAGE=NONE

write_summary
echo "Verification passed. Summary: $SUMMARY"
