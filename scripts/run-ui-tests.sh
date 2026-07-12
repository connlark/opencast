#!/usr/bin/env bash
#
# run-ui-tests.sh — explicit two-destination shard runner for OpenCastUITests.
#
# Builds the test bundle once, then runs the parallel-safe seeded iPhone UI tests as
# two concurrent `test-without-building` shards on two distinct iPhone 17 / iOS 26.5
# simulators, followed by a serial tail for timing-sensitive tests. Each lane gets its
# own result bundle, log, and TMPDIR. The wrapper fails (nonzero) if any lane fails, is
# interrupted, produces an incomplete result bundle, or omits an assigned test.
#
# This deliberately avoids Xcode's cloned-simulator parallel workers (which can deny the
# xctrunner launch and hang); the shared schemes stay parallelizable="NO".
#
# Usage:
#   scripts/run-ui-tests.sh                 # build once, 2 shards + serial tail
#   scripts/run-ui-tests.sh --jobs 1        # serial fallback: whole routine inventory, one sim
#   scripts/run-ui-tests.sh --check         # manifest/source inventory drift guard only (no build)
#   scripts/run-ui-tests.sh --out DIR       # write bundles/logs under DIR
#   scripts/run-ui-tests.sh --no-build      # reuse XCTESTRUN from env (skip build-for-testing + boot)
#
# Env overrides (also used by the self-tests to inject fakes):
#   SIM_A, SIM_B            simulator UDIDs (SIM_A required; SIM_B required for two jobs)
#   XCODEBUILD             xcodebuild command (default: xcodebuild)
#   XCRESULTTOOL          xcresulttool command (default: xcrun xcresulttool)
#   XCTESTRUN             prebuilt .xctestrun path (required with --no-build)
#   SIMCTL                simctl command (default: xcrun simctl)
#
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "${script_dir}/.." && pwd)"

MANIFEST="${MANIFEST:-${repo_dir}/scripts/ui-test-shards.txt}"
SOURCE="${SOURCE:-${repo_dir}/OpenCastUITests/OpenCastUITests.swift}"
EXTRACTOR="${script_dir}/lib/xcresult-testcases.py"

SIM_A="${SIM_A:-}"
SIM_B="${SIM_B:-}"
XCODEBUILD="${XCODEBUILD:-xcodebuild}"
XCRESULTTOOL="${XCRESULTTOOL:-xcrun xcresulttool}"
SIMCTL="${SIMCTL:-xcrun simctl}"

JOBS=2
CHECK_ONLY=0
NO_BUILD=0
OUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --jobs) JOBS="$2"; shift 2 ;;
    --check) CHECK_ONLY=1; shift ;;
    --no-build) NO_BUILD=1; shift ;;
    --out) OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "run-ui-tests: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Manifest / inventory helpers
# ---------------------------------------------------------------------------

# Emit the test identifiers assigned to a lane (shard1|shard2|serial|exclude).
lane_ids() { awk -v lane="$1" '$1==lane {print $2}' "$MANIFEST"; }

# The routine iPhone inventory = every lane except `exclude`.
routine_ids() { awk '$1=="shard1"||$1=="shard2"||$1=="serial" {print $2}' "$MANIFEST"; }

# Guard: every test method in the source file is assigned to exactly one lane, and every
# manifest identifier still exists in the source. Prints drift and returns nonzero on any.
check_manifest() {
  local status=0
  local src manifest_methods dups

  src="$(grep -oE 'func (test[A-Za-z0-9_]+)\(' "$SOURCE" | sed -E 's/func //; s/\($//' | sort -u)"
  # method name (last path component) for every assigned lane entry
  manifest_methods="$(awk '$1=="shard1"||$1=="shard2"||$1=="serial"||$1=="exclude" {n=split($2,a,"/"); print a[n]}' "$MANIFEST" | sort)"

  dups="$(printf '%s\n' "$manifest_methods" | uniq -d)"
  if [[ -n "$dups" ]]; then
    printf 'manifest: test assigned to multiple lanes:\n%s\n' "$dups" >&2
    status=1
  fi

  local unassigned
  unassigned="$(comm -23 <(printf '%s\n' "$src") <(printf '%s\n' "$manifest_methods" | sort -u) || true)"
  if [[ -n "$unassigned" ]]; then
    printf 'manifest: source tests missing from manifest (assign to a shard/serial/exclude lane):\n%s\n' "$unassigned" >&2
    status=1
  fi

  local dead
  dead="$(comm -13 <(printf '%s\n' "$src") <(printf '%s\n' "$manifest_methods" | sort -u) || true)"
  if [[ -n "$dead" ]]; then
    printf 'manifest: manifest references tests not in source:\n%s\n' "$dead" >&2
    status=1
  fi

  if [[ "$status" -eq 0 ]]; then
    local nshard1 nshard2 nserial nexcl
    nshard1=$(lane_ids shard1 | grep -c . || true)
    nshard2=$(lane_ids shard2 | grep -c . || true)
    nserial=$(lane_ids serial | grep -c . || true)
    nexcl=$(lane_ids exclude | grep -c . || true)
    echo "manifest OK: shard1=${nshard1} shard2=${nshard2} serial=${nserial} exclude=${nexcl} (source=$(printf '%s\n' "$src" | grep -c .))"
  fi
  return "$status"
}

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  check_manifest
  exit $?
fi

if [[ -z "$SIM_A" ]]; then
  echo "run-ui-tests: set SIM_A to an available iPhone simulator UDID" >&2
  exit 2
fi
if [[ "$JOBS" -ge 2 && -z "$SIM_B" ]]; then
  echo "run-ui-tests: set SIM_B to a second available iPhone simulator UDID, or use --jobs 1" >&2
  exit 2
fi

# Validate the manifest before doing any expensive work; a drifted manifest must not run.
check_manifest >/dev/null || { echo "run-ui-tests: manifest drift; run --check" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Run setup
# ---------------------------------------------------------------------------

if [[ -z "$OUT" ]]; then
  OUT="${repo_dir}/artifacts/ui-tests/run-$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$OUT"

# Lane bookkeeping (bash 3.2: no associative arrays — use parallel indexed arrays).
LANE_NAMES=()
LANE_PIDS=()
LANE_RC=()
LANE_SIM=()
LANE_START=()
LANE_END=()

overall_rc=0
interrupted=0

kill_lanes() {
  local i pid
  for i in "${!LANE_PIDS[@]}"; do
    pid="${LANE_PIDS[$i]}"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      pkill -TERM -P "$pid" 2>/dev/null || true
    fi
  done
}
cleanup() {
  kill_lanes
  # Preserve result bundles and logs; only remove scratch TMPDIRs.
  rm -rf "${OUT}"/tmp-* 2>/dev/null || true
}
# Kill lanes immediately on interrupt so the pending waits return instead of hanging.
on_interrupt() {
  interrupted=1
  echo >&2
  echo "run-ui-tests: interrupted — tearing down lanes, preserving bundles/logs" >&2
  kill_lanes
}
trap on_interrupt INT TERM
trap cleanup EXIT

# Wait for a lane's pid, but stay responsive to signals. Bash does not run a trap while
# blocked in `wait <pid>` until that child exits, so poll instead and reap once it's gone.
# Echoes nothing; returns the child's exit code (or 130 if we were interrupted first).
join_lane() {
  local pid="$1" rc=0
  while kill -0 "$pid" 2>/dev/null; do
    [[ "$interrupted" -eq 1 ]] && return 130
    sleep 0.2 || true
  done
  wait "$pid" || rc=$?
  return "$rc"
}

# Launch one lane's `test-without-building` in the background; record its PID.
# Args: lane_name sim_udid
launch_lane() {
  local lane="$1" sim="$2"
  local bundle="${OUT}/${lane}.xcresult"
  local log="${OUT}/${lane}.log"
  local tmp="${OUT}/tmp-${lane}"
  mkdir -p "$tmp"

  local only_args=()
  local id
  while IFS= read -r id; do
    [[ -n "$id" ]] && only_args+=( "-only-testing:${id}" )
  done < <(lane_ids "$lane")

  # `serial` is the tail lane's manifest name; for --jobs 1 the caller passes an explicit
  # id list via ROUTINE_LANE, handled by the caller below.
  (
    export TMPDIR="$tmp"
    exec ${XCODEBUILD} test-without-building \
      -xctestrun "$XCTESTRUN" \
      -destination "platform=iOS Simulator,id=${sim}" \
      -parallel-testing-enabled NO \
      -maximum-concurrent-test-device-destinations 1 \
      -resultBundlePath "$bundle" \
      "${only_args[@]}"
  ) >"$log" 2>&1 &

  local idx="${#LANE_NAMES[@]}"
  LANE_NAMES[$idx]="$lane"
  LANE_PIDS[$idx]="$!"
  LANE_SIM[$idx]="$sim"
  LANE_RC[$idx]=""
  LANE_START[$idx]="$(date +%s)"
  LANE_END[$idx]=""
}

# Verify a finished lane: complete bundle, exact expected inventory, zero failures.
# Args: lane_name expected_ids_file   Returns 0 pass / 1 fail; prints a one-line summary.
verify_lane() {
  local lane="$1" expected_file="$2"
  local bundle="${OUT}/${lane}.xcresult"
  local log="${OUT}/${lane}.log"
  local tree parsed

  if [[ ! -e "$bundle" ]]; then
    echo "  ${lane}: FAIL — no result bundle (incomplete/crashed); see ${log#${repo_dir}/}"
    return 1
  fi
  if ! tree="$(${XCRESULTTOOL} get test-results tests --path "$bundle" 2>>"$log")"; then
    echo "  ${lane}: FAIL — result bundle unreadable (incomplete); see ${log#${repo_dir}/}"
    return 1
  fi
  parsed="$(printf '%s' "$tree" | python3 "$EXTRACTOR")" || {
    echo "  ${lane}: FAIL — could not parse result bundle; see ${log#${repo_dir}/}"
    return 1
  }
  if [[ -z "$parsed" ]]; then
    echo "  ${lane}: FAIL — result bundle contains no test cases (incomplete)"
    return 1
  fi

  local executed failed_ids missing extra
  executed="$(printf '%s\n' "$parsed" | cut -f2 | sort -u)"
  failed_ids="$(printf '%s\n' "$parsed" | awk -F'\t' '$1!="Passed" && $1!="Skipped" && $1!="Expected Failure" {print $2}' | sort -u)"
  local expected
  expected="$(sort -u "$expected_file")"

  missing="$(comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$executed") || true)"
  extra="$(comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$executed") || true)"

  local n_exp n_exec n_fail
  n_exp="$(printf '%s\n' "$expected" | grep -c . || true)"
  n_exec="$(printf '%s\n' "$executed" | grep -c . || true)"
  n_fail="$(printf '%s\n' "$failed_ids" | grep -c . || true)"

  local rc=0 note=""
  if [[ -n "$missing" ]]; then note+=" missing=$(printf '%s' "$missing" | tr '\n' ',' )"; rc=1; fi
  if [[ -n "$extra" ]];   then note+=" unexpected=$(printf '%s' "$extra" | tr '\n' ',')"; rc=1; fi
  if [[ "$n_fail" -gt 0 ]]; then note+=" failed=$(printf '%s' "$failed_ids" | tr '\n' ',')"; rc=1; fi

  if [[ "$rc" -eq 0 ]]; then
    echo "  ${lane}: PASS — ${n_exec}/${n_exp} tests, 0 failures"
  else
    echo "  ${lane}: FAIL — exec ${n_exec}/${n_exp}${note}; see ${log#${repo_dir}/}"
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# Build once (skippable for tests / reuse)
# ---------------------------------------------------------------------------

if [[ "$NO_BUILD" -eq 1 ]]; then
  : "${XCTESTRUN:?--no-build requires XCTESTRUN=<path to .xctestrun>}"
else
  echo "run-ui-tests: booting simulators ${SIM_A} $([[ "$JOBS" -ge 2 ]] && echo "+ ${SIM_B}")"
  ${SIMCTL} boot "$SIM_A" 2>/dev/null || true
  [[ "$JOBS" -ge 2 ]] && { ${SIMCTL} boot "$SIM_B" 2>/dev/null || true; }

  echo "run-ui-tests: build-for-testing (once)…"
  ${XCODEBUILD} build-for-testing \
    -project "${repo_dir}/opencast.xcodeproj" \
    -scheme OpenCast \
    -destination "platform=iOS Simulator,id=${SIM_A}" \
    -derivedDataPath "${OUT}/dd" \
    -quiet >"${OUT}/build.log" 2>&1 || {
      echo "run-ui-tests: build-for-testing failed; see ${OUT#${repo_dir}/}/build.log" >&2
      exit 1
    }
  XCTESTRUN="$(ls "${OUT}/dd/Build/Products/"*.xctestrun 2>/dev/null | head -1)"
  [[ -n "${XCTESTRUN:-}" ]] || { echo "run-ui-tests: no .xctestrun produced" >&2; exit 1; }
fi

# ---------------------------------------------------------------------------
# Run lanes
# ---------------------------------------------------------------------------

echo "run-ui-tests: results under ${OUT#${repo_dir}/}"

if [[ "$JOBS" -eq 1 ]]; then
  # Serial fallback: whole routine inventory on one simulator, one bundle.
  routine_ids | sort -u > "${OUT}/expected-serial-fallback.txt"
  local_only=()
  while IFS= read -r id; do [[ -n "$id" ]] && local_only+=( "-only-testing:${id}" ); done < <(routine_ids)
  bundle="${OUT}/fallback.xcresult"; log="${OUT}/fallback.log"; tmp="${OUT}/tmp-fallback"; mkdir -p "$tmp"
  echo "run-ui-tests: serial fallback — $(routine_ids | grep -c .) tests on ${SIM_A}"
  start=$(date +%s)
  ( export TMPDIR="$tmp"
    exec ${XCODEBUILD} test-without-building -xctestrun "$XCTESTRUN" \
      -destination "platform=iOS Simulator,id=${SIM_A}" \
      -parallel-testing-enabled NO -maximum-concurrent-test-device-destinations 1 \
      -resultBundlePath "$bundle" "${local_only[@]}" ) >"$log" 2>&1 &
  fpid=$!
  LANE_PIDS[0]="$fpid"   # track for interrupt teardown
  if join_lane "$fpid"; then frc=0; else frc=$?; fi
  [[ "$interrupted" -eq 1 ]] && { echo "run-ui-tests: aborted by interrupt" >&2; exit 130; }
  end=$(date +%s)
  [[ "$frc" -ne 0 ]] && { echo "  fallback: xcodebuild exit ${frc}"; overall_rc=1; }
  verify_lane "fallback" "${OUT}/expected-serial-fallback.txt" || overall_rc=1
  echo "run-ui-tests: fallback wall-clock $((end-start))s"
else
  # Parallel: shard1 on SIM_A, shard2 on SIM_B, concurrently; serial tail after, alone.
  lane_ids shard1 | sort -u > "${OUT}/expected-shard1.txt"
  lane_ids shard2 | sort -u > "${OUT}/expected-shard2.txt"
  lane_ids serial | sort -u > "${OUT}/expected-serial.txt"

  parallel_start=$(date +%s)
  launch_lane shard1 "$SIM_A"
  launch_lane shard2 "$SIM_B"

  # Wait for both shards (record each rc), staying responsive to interrupts.
  for i in "${!LANE_PIDS[@]}"; do
    if join_lane "${LANE_PIDS[$i]}"; then LANE_RC[$i]=0; else LANE_RC[$i]=$?; fi
    LANE_END[$i]=$(date +%s)
  done
  parallel_end=$(date +%s)

  [[ "$interrupted" -eq 1 ]] && { echo "run-ui-tests: aborted by interrupt" >&2; exit 130; }

  # Serial tail runs alone, after the shards, so timing probes see no contention.
  serial_start=$(date +%s)
  if [[ -s "${OUT}/expected-serial.txt" ]]; then
    launch_lane serial "$SIM_A"
    last=$(( ${#LANE_PIDS[@]} - 1 ))
    if join_lane "${LANE_PIDS[$last]}"; then LANE_RC[$last]=0; else LANE_RC[$last]=$?; fi
    LANE_END[$last]=$(date +%s)
  fi
  serial_end=$(date +%s)
  [[ "$interrupted" -eq 1 ]] && { echo "run-ui-tests: aborted by interrupt" >&2; exit 130; }

  # ---- verification + merged summary ----
  echo
  echo "run-ui-tests: lane results"
  for i in "${!LANE_NAMES[@]}"; do
    lane="${LANE_NAMES[$i]}"
    [[ "${LANE_RC[$i]}" -ne 0 ]] && { echo "  ${lane}: xcodebuild exit ${LANE_RC[$i]}"; overall_rc=1; }
    verify_lane "$lane" "${OUT}/expected-${lane}.txt" || overall_rc=1
  done

  shard_wall=$((parallel_end - parallel_start))
  serial_wall=$((serial_end - serial_start))
  echo
  echo "run-ui-tests: wall-clock — shards(parallel)=${shard_wall}s serial-tail=${serial_wall}s total=$((shard_wall + serial_wall))s"
fi

echo
if [[ "$overall_rc" -eq 0 ]]; then
  echo "run-ui-tests: PASS (bundles: ${OUT#${repo_dir}/})"
else
  echo "run-ui-tests: FAIL — see per-lane logs under ${OUT#${repo_dir}/}" >&2
fi
exit "$overall_rc"
