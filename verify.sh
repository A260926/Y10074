#!/usr/bin/env bash
# (written for bash 3.2, the version shipped with macOS)
#
# verify.sh - single entry point that proves source, test assets and the
# published NuGet package all come from the same working tree/commit.
#
# Pipeline (fixed order):
#   restore -> format -> build -> test -> pack-a -> pack-b
#   -> package-gate -> gate-negative-self-test -> assets-gate -> reproducible
#
# Any stage failure exits non-zero immediately. A summary with the fixed
# stage ordering (PASS / FAIL / SKIP) is always written to
# artifacts/verification-summary.txt.
#
# After "dotnet restore" every .NET command runs --no-restore and the script
# sets the SDK offline knobs, so the rest of the pipeline works without
# network access.
#
# Run from any working directory: ./verify.sh

set -u -o pipefail

# --- always operate from the repository root -------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"
cd "$ROOT_DIR"

export DOTNET_NOLOGO=1
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export MSBUILDDISABLENODEREUSE=1

ARTIFACTS_DIR="$ROOT_DIR/artifacts"
LOG_DIR="$ARTIFACTS_DIR/logs"
SUMMARY_FILE="$ARTIFACTS_DIR/verification-summary.txt"
PACK_A_DIR="$ARTIFACTS_DIR/package-a"
PACK_B_DIR="$ARTIFACTS_DIR/package-b"
GATE_PROBE_DIR="$ARTIFACTS_DIR/gate-negative-probe"
SOLUTION="Hjson.slnx"
LIB_PROJECT="Hjson/Hjson.csproj"
TEST_PROJECT="test/test.csproj"
TEST_ASSETS_SOURCE="test/assets"
ENG_DIR="$ROOT_DIR/eng"

STAGES=(
  "restore"
  "format"
  "build"
  "test"
  "pack-a"
  "pack-b"
  "package-gate"
  "gate-negative-self-test"
  "assets-gate"
  "reproducible"
)

STAGE_COUNT=${#STAGES[@]}
STAGE_STATUS=()
STAGE_DETAIL=()
for ((i = 0; i < STAGE_COUNT; i++)); do
  STAGE_STATUS[$i]="SKIP"
  STAGE_DETAIL[$i]=""
done

stage_index() {
  local wanted="$1" i
  for ((i = 0; i < STAGE_COUNT; i++)); do
    if [[ "${STAGES[$i]}" == "$wanted" ]]; then
      echo "$i"
      return 0
    fi
  done
  return 1
}

set_stage() {
  local stage="$1" status="$2" detail="${3:-}" i
  i="$(stage_index "$stage")"
  STAGE_STATUS[$i]="$status"
  STAGE_DETAIL[$i]="$detail"
}

FAILED_STAGE=""
EXIT_CODE=0

write_summary() {
  {
    echo "Hjson verification summary"
    echo "generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "commit: $(git rev-parse HEAD 2>/dev/null || echo unknown)"
    if [[ -n "${PACKAGE_VERSION:-}" ]]; then
      echo "package: ${PACKAGE_ID:-Hjson}.$PACKAGE_VERSION.nupkg"
    fi
    if [[ -n "${CANON_HASH_A:-}" ]]; then
      echo "canonical-hash: $CANON_HASH_A"
    fi
    echo
    printf '%-26s %-5s %s\n' "STAGE" "STATE" "DETAIL"
    for ((i = 0; i < STAGE_COUNT; i++)); do
      printf '%-26s %-5s %s\n' "${STAGES[$i]}" "${STAGE_STATUS[$i]}" "${STAGE_DETAIL[$i]}"
    done
    echo
    if [[ -n "$FAILED_STAGE" ]]; then
      echo "FAILED_STAGE: $FAILED_STAGE"
      echo "RESULT: FAIL"
    else
      echo "FAILED_STAGE: -"
      echo "RESULT: PASS"
    fi
  } > "$SUMMARY_FILE"
}

on_exit() {
  local code=$?
  if [[ -z "$FAILED_STAGE" && $code -ne 0 ]]; then
    # Failure outside of a tracked stage (or interrupted command).
    FAILED_STAGE="${CURRENT_STAGE:-unknown}"
    if [[ -n "${CURRENT_STAGE:-}" ]]; then
      set_stage "$CURRENT_STAGE" FAIL "aborted; see artifacts/logs"
    fi
  fi
  write_summary
  if [[ -n "$FAILED_STAGE" ]]; then
    echo
    echo "verification FAILED at stage: $FAILED_STAGE (exit $code)" >&2
    echo "summary: $SUMMARY_FILE" >&2
  fi
}
trap on_exit EXIT

run_stage() {
  local stage="$1"
  shift
  CURRENT_STAGE="$stage"
  local log_file="$LOG_DIR/$stage.log"
  echo "==> [$stage] $*"
  if "$@" >"$log_file" 2>&1; then
    set_stage "$stage" PASS
    echo "    PASS (log: artifacts/logs/$stage.log)"
  else
    local code=$?
    set_stage "$stage" FAIL "exit $code; see artifacts/logs/$stage.log"
    FAILED_STAGE="$stage"
    EXIT_CODE=$code
    echo "    FAIL (exit $code, log: artifacts/logs/$stage.log)" >&2
    tail -n 30 "$log_file" >&2 || true
    exit "$code"
  fi
}

# Small inline checks that do not need a log file of their own.
record_stage() {
  local stage="$1" status="$2" detail="${3:-}"
  set_stage "$stage" "$status" "$detail"
  echo "==> [$stage] $status $detail"
  if [[ "$status" == "FAIL" ]]; then
    FAILED_STAGE="$stage"
    EXIT_CODE=1
    exit 1
  fi
}

# --- fresh, isolated artifact tree -----------------------------------------
mkdir -p "$LOG_DIR"
if [[ -e "$PACK_A_DIR" || -e "$PACK_B_DIR" || -e "$GATE_PROBE_DIR" ]]; then
  find "$ARTIFACTS_DIR" -mindepth 1 -maxdepth 1 \
    \( -name package-a -o -name package-b -o -name gate-negative-probe \) \
    -exec rm -rf {} +
fi
mkdir -p "$PACK_A_DIR" "$PACK_B_DIR" "$LOG_DIR"

# --- stage: restore (only stage allowed to use the network) -----------------
run_stage restore dotnet restore "$SOLUTION"

# From here on the pipeline must run offline: every dotnet invocation uses
# --no-restore, and an unreachable proxy is exported as a guard so any
# unexpected HTTP attempt fails loudly instead of silently reaching out.
DOTNET_OFFLINE=(--no-restore)
export http_proxy="http://127.0.0.1:9" https_proxy="http://127.0.0.1:9"
export HTTP_PROXY="$http_proxy" HTTPS_PROXY="$https_proxy"
export no_proxy="" NO_PROXY=""

# --- stage: format ----------------------------------------------------------
run_stage format dotnet format "$SOLUTION" --verify-no-changes --no-restore

# --- stage: release build ---------------------------------------------------
run_stage build dotnet build "$SOLUTION" --configuration Release "${DOTNET_OFFLINE[@]}"

# --- stage: test ------------------------------------------------------------
run_stage test dotnet test "$TEST_PROJECT" --configuration Release --no-build

# --- locate single build outputs (single target framework) ------------------
TFM_DIRS=()
while IFS= read -r dir; do TFM_DIRS+=("$dir"); done < <(
  find "$ROOT_DIR/Hjson/bin/Release" -mindepth 1 -maxdepth 1 -type d)
if [[ ${#TFM_DIRS[@]} -ne 1 ]]; then
  record_stage build FAIL \
    "expected exactly one target framework output, found: ${TFM_DIRS[*]:-none}"
fi
TFM_DIR="${TFM_DIRS[0]}"
if [[ ! -f "$TFM_DIR/Hjson.xml" ]]; then
  record_stage build FAIL "no single TFM output with Hjson.xml under Hjson/bin/Release"
fi
TARGET_TFM="$(basename "$TFM_DIR")"
TEST_TFM_DIR="$ROOT_DIR/test/bin/Release/$TARGET_TFM"

PACKAGE_ID="$(python3 - "$LIB_PROJECT" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8-sig").read()
match = re.search(r"<PackageId>\s*([^<]+?)\s*</PackageId>", text)
print(match.group(1) if match else "Hjson")
PY
)"
if ! PACKAGE_VERSION="$("$ENG_DIR/read_version.sh" 2>"$LOG_DIR/read-version.log")"; then
  record_stage pack-a FAIL "could not read single <Version> from $LIB_PROJECT"
fi
if [[ -z "$PACKAGE_VERSION" ]]; then
  record_stage pack-a FAIL "could not read single <Version> from $LIB_PROJECT"
fi
NUPKG_NAME="${PACKAGE_ID}.${PACKAGE_VERSION}.nupkg"

# --- stage: pack twice into isolated output directories ---------------------
run_stage pack-a dotnet pack "$LIB_PROJECT" --configuration Release --no-build \
  -o "$PACK_A_DIR"
run_stage pack-b dotnet pack "$LIB_PROJECT" --configuration Release --no-build \
  -o "$PACK_B_DIR"

NUPKG_A="$PACK_A_DIR/$NUPKG_NAME"
NUPKG_B="$PACK_B_DIR/$NUPKG_NAME"
[[ -f "$NUPKG_A" ]] || { record_stage pack-a FAIL "missing $NUPKG_NAME in package-a"; }
[[ -f "$NUPKG_B" ]] || { record_stage pack-b FAIL "missing $NUPKG_NAME in package-b"; }
set_stage pack-a PASS "$NUPKG_NAME"
set_stage pack-b PASS "$NUPKG_NAME"

# --- stage: package content gate --------------------------------------------
run_stage package-gate python3 "$ENG_DIR/package_gate.py" \
  --nupkg "$NUPKG_A" \
  --package-dir "$PACK_A_DIR" \
  --package-id "$PACKAGE_ID" \
  --tfm "$TARGET_TFM" \
  --license-file "$ROOT_DIR/LICENSE"

# --- stage: intentional negative self-test ----------------------------------
# Drop a stray file into a throwaway copy of the package output; the gate
# must reject it. Then remove the probe and prove the clean tree passes,
# showing detection works and the pipeline recovers for the remaining stages.
CURRENT_STAGE="gate-negative-self-test"
mkdir -p "$GATE_PROBE_DIR"
cp "$NUPKG_A" "$GATE_PROBE_DIR/$NUPKG_NAME"
echo "temporary file that must never ship" > "$GATE_PROBE_DIR/stray.tmp"
NEG_LOG="$LOG_DIR/gate-negative-self-test.log"
echo "==> [gate-negative-self-test] stray file probe (gate is expected to fail)"
if python3 "$ENG_DIR/package_gate.py" \
    --nupkg "$GATE_PROBE_DIR/$NUPKG_NAME" \
    --package-dir "$GATE_PROBE_DIR" \
    --package-id "$PACKAGE_ID" \
    --tfm "$TARGET_TFM" \
    --license-file "$ROOT_DIR/LICENSE" >"$NEG_LOG" 2>&1; then
  record_stage gate-negative-self-test FAIL \
    "gate accepted output dir containing stray.tmp"
fi
if ! grep -q "no-stray-files" "$NEG_LOG"; then
  record_stage gate-negative-self-test FAIL \
    "gate failed but not because of the stray file"
fi
find "$ARTIFACTS_DIR" -mindepth 1 -maxdepth 1 -name gate-negative-probe -exec rm -rf {} +
if [[ -e "$GATE_PROBE_DIR" ]]; then
  record_stage gate-negative-self-test FAIL "cleanup of probe dir failed"
fi
set_stage gate-negative-self-test PASS "stray file correctly rejected; probe cleaned"
echo "    PASS stray file rejected and probe cleaned"

# --- stage: every test/assets fixture is discovered, none is packaged -------
run_stage assets-gate python3 "$ENG_DIR/assets_gate.py" \
  --source-dir "$ROOT_DIR/$TEST_ASSETS_SOURCE" \
  --test-output-dir "$TEST_TFM_DIR/assets" \
  --nupkg "$NUPKG_A"

# --- stage: reproducible packages -------------------------------------------
CANON_HASH_A="$(python3 "$ENG_DIR/canonical_nupkg.py" "$NUPKG_A" | awk '{print $1}')"
CANON_HASH_B="$(python3 "$ENG_DIR/canonical_nupkg.py" "$NUPKG_B" | awk '{print $1}')"
{
  echo "package-a: $CANON_HASH_A  $NUPKG_A"
  echo "package-b: $CANON_HASH_B  $NUPKG_B"
} > "$LOG_DIR/reproducible.log"
if [[ -z "$CANON_HASH_A" || "$CANON_HASH_A" != "$CANON_HASH_B" ]]; then
  record_stage reproducible FAIL \
    "hash mismatch a=$CANON_HASH_A b=$CANON_HASH_B"
fi
record_stage reproducible PASS "a==b $CANON_HASH_A (artifacts/logs/reproducible.log)"

FAILED_STAGE=""
EXIT_CODE=0
echo
echo "verification PASSED: $NUPKG_NAME"
echo "canonical hash (both packages): $CANON_HASH_A"
echo "summary: $SUMMARY_FILE"
exit 0
