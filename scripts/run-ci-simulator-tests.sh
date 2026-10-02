#!/usr/bin/env bash
#
# run-ci-simulator-tests.sh — one simulator test selection, the way CI runs it.
#
# Warms the simulator (boot, wait for boot to finish), builds for testing, launches the
# built app once so SpringBoard and the accessibility loader are up, then runs the
# selection with `test-without-building`.
#
# An attempt is classified from its result bundle:
#   passed          tests ran and none failed
#   infrastructure  no tests ran, or every recorded failure is one of the two runner
#                   launch signatures below
#   failed          tests ran and at least one failed for any other reason
#
# An infrastructure attempt is recorded in the job summary and the selection runs
# exactly once more on a rebooted simulator. A failed attempt is never retried, a
# failed build is never retried, and a second infrastructure attempt fails the run.
#
# Usage:
#   scripts/run-ci-simulator-tests.sh --udid UDID --name LABEL --out DIR \
#       [--derived-data DIR] -- -only-testing:Target/Suite [...]
#
# Writes DIR/LABEL.xcresult and DIR/LABEL.log for the final attempt, and
# DIR/LABEL-attempt1.xcresult plus DIR/LABEL-attempt1.log when a retry happened.
#
# Env overrides (also used by the self-tests to inject fakes):
#   XCODEBUILD             xcodebuild command (default: xcodebuild)
#   XCRESULTTOOL           xcresulttool command (default: xcrun xcresulttool)
#   SIMCTL                 simctl command (default: xcrun simctl)
#   WARM_LAUNCH_SECONDS    how long the warm-up launch stays up (default: 5)
#   SIMULATOR_STEP_TIMEOUT seconds allowed for each simctl warm-up step (default: 300)
#   GITHUB_STEP_SUMMARY    appended with the attempt table when set
#   GITHUB_OUTPUT          receives retried=true|false when set
#
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "${script_dir}/.." && pwd)"

XCODEBUILD="${XCODEBUILD:-xcodebuild}"
XCRESULTTOOL="${XCRESULTTOOL:-xcrun xcresulttool}"
SIMCTL="${SIMCTL:-xcrun simctl}"
WARM_LAUNCH_SECONDS="${WARM_LAUNCH_SECONDS:-5}"
SIMULATOR_STEP_TIMEOUT="${SIMULATOR_STEP_TIMEOUT:-300}"

UDID=""
NAME=""
OUT=""
DERIVED_DATA=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid) UDID="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --derived-data) DERIVED_DATA="$2"; shift 2 ;;
    --) shift; break ;;
    -h|--help) sed -n '2,34p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "run-ci-simulator-tests: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

if [[ -z "$UDID" || -z "$NAME" || -z "$OUT" || $# -eq 0 ]]; then
  echo "run-ci-simulator-tests: --udid, --name, --out and a test selection after -- are required" >&2
  exit 2
fi

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
DERIVED_DATA="${DERIVED_DATA:-${OUT}/DerivedData}"
BUNDLE="${OUT}/${NAME}.xcresult"
LOG="${OUT}/${NAME}.log"
SELECTION=("$@")
DESTINATION="platform=iOS Simulator,id=${UDID}"

say() { printf 'run-ci-simulator-tests: %s\n' "$*"; }

# macOS ships no `timeout`; perl's alarm bounds a simctl step that would otherwise
# hold the job until its own timeout on a runner whose simulator never comes up.
bounded() {
  perl -e 'alarm shift; exec @ARGV or exit 127' "$SIMULATOR_STEP_TIMEOUT" "$@"
}

# Warm-up is best effort: a step that fails here is reported and the tests still run,
# because the attempt classification below is what decides the outcome.
warm_simulator() {
  bounded ${SIMCTL} boot "$UDID" >/dev/null 2>&1 || true
  bounded ${SIMCTL} bootstatus "$UDID" -b || say "warning: bootstatus did not complete"

  local app bundle_id
  app="$(find "${DERIVED_DATA}/Build/Products" -maxdepth 2 -type d -name 'OpenCast.app' \
    -path '*-iphonesimulator/*' 2>/dev/null | sort | head -n 1)"
  if [[ -z "$app" ]]; then
    say "warning: no built OpenCast.app to warm-launch"
    return 0
  fi
  bundle_id="$(python3 -c 'import plistlib, sys
with open(sys.argv[1], "rb") as source:
    print(plistlib.load(source)["CFBundleIdentifier"])' "${app}/Info.plist" 2>/dev/null || true)"
  if [[ -z "$bundle_id" ]]; then
    say "warning: could not read the bundle identifier of ${app}"
    return 0
  fi

  # The UI-testing flags keep the warm-up launch on an in-memory seeded store, so it
  # leaves nothing in the container for the hosted unit tests to find.
  if bounded ${SIMCTL} install "$UDID" "$app" &&
     bounded ${SIMCTL} launch "$UDID" "$bundle_id" --opencast-ui-testing --opencast-seed-ui-library; then
    sleep "$WARM_LAUNCH_SECONDS"
    bounded ${SIMCTL} terminate "$UDID" "$bundle_id" >/dev/null 2>&1 || true
    say "warm-up launch of ${bundle_id} finished"
  else
    say "warning: warm-up launch failed"
  fi
}

# Prints "<outcome>\t<reason>" for the attempt whose bundle and log are given.
classify_attempt() {
  local exit_code="$1" bundle="$2" log="$3" summary="${2%.xcresult}-summary.json"
  ${XCRESULTTOOL} get test-results summary --path "$bundle" --format json >"$summary" 2>/dev/null || rm -f "$summary"
  EXIT_CODE="$exit_code" SUMMARY_PATH="$summary" LOG_PATH="$log" python3 - <<'PY'
import json
import os

SIGNATURES = (
    ("launch timeout", "Timed out while launching application via Xcode"),
    ("accessibility load timeout", "Timed out waiting for AX loaded notification"),
)


def signature(text):
    for label, needle in SIGNATURES:
        if needle in text:
            return label
    return None


def log_signature():
    try:
        with open(os.environ["LOG_PATH"], encoding="utf-8", errors="replace") as source:
            return signature(source.read())
    except OSError:
        return None


def classify():
    try:
        with open(os.environ["SUMMARY_PATH"], encoding="utf-8") as source:
            summary = json.load(source)
    except (OSError, ValueError):
        return "infrastructure", "no readable result bundle"

    total = summary.get("totalTestCount") or 0
    failed = summary.get("failedTests") or 0
    if total == 0:
        return "infrastructure", "no tests executed" + (
            f" ({log_signature()})" if log_signature() else "")
    if failed == 0:
        if os.environ["EXIT_CODE"] == "0":
            return "passed", f"{summary.get('passedTests', 0)} passed"
        found = log_signature()
        if found:
            return "infrastructure", f"{found} with no failed test"
        return "failed", f"xcodebuild exited {os.environ['EXIT_CODE']} with no failed test"

    failures = summary.get("testFailures") or []
    labels = [signature(failure.get("failureText", "")) for failure in failures]
    if failures and all(labels):
        return "infrastructure", f"{labels[0]} in {failed} of {total} tests"
    return "failed", f"{failed} of {total} tests failed"


print("\t".join(classify()))
PY
}

ATTEMPT_ROWS=()
record() { # attempt outcome reason
  ATTEMPT_ROWS+=("| $1 | $2 | $3 |")
  say "attempt $1: $2 ($3)"
}

publish() { # retried
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      printf '### %s: attempts\n\n| Attempt | Outcome | Detail |\n| ---: | --- | --- |\n' "$NAME"
      printf '%s\n' "${ATTEMPT_ROWS[@]}"
      printf '\n'
    } >>"$GITHUB_STEP_SUMMARY"
  fi
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'retried=%s\n' "$1" >>"$GITHUB_OUTPUT"
  fi
}

run_attempt() { # sets ATTEMPT_EXIT
  rm -rf "$BUNDLE"
  set +e
  ${XCODEBUILD} test-without-building \
    -project "${repo_dir}/opencast.xcodeproj" \
    -scheme OpenCast \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA" \
    -parallel-testing-enabled NO \
    -maximum-concurrent-test-device-destinations 1 \
    -collect-test-diagnostics never \
    -resultBundlePath "$BUNDLE" \
    "${SELECTION[@]}" 2>&1 | tee -a "$LOG"
  ATTEMPT_EXIT="${PIPESTATUS[0]}"
  set -e
}

: >"$LOG"
bounded ${SIMCTL} boot "$UDID" >/dev/null 2>&1 || true
bounded ${SIMCTL} bootstatus "$UDID" -b || say "warning: bootstatus did not complete"

set +e
${XCODEBUILD} build-for-testing \
  -project "${repo_dir}/opencast.xcodeproj" \
  -scheme OpenCast \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" 2>&1 | tee -a "$LOG"
build_exit="${PIPESTATUS[0]}"
set -e
if [[ "$build_exit" -ne 0 ]]; then
  record build failed "build-for-testing exited ${build_exit}"
  publish false
  exit "$build_exit"
fi

# A classifier that printed nothing is treated as a failure, never as a retry.
classify() { # sets outcome, reason
  outcome=""; reason=""
  IFS=$'\t' read -r outcome reason < <(classify_attempt "$ATTEMPT_EXIT" "$BUNDLE" "$LOG") || true
  if [[ -z "$outcome" ]]; then
    outcome="failed"; reason="attempt could not be classified"
  fi
}

warm_simulator
run_attempt
classify
record 1 "$outcome" "$reason"

retried=false
if [[ "$outcome" == "infrastructure" ]]; then
  retried=true
  rm -rf "${OUT}/${NAME}-attempt1.xcresult"
  [[ -d "$BUNDLE" ]] && mv "$BUNDLE" "${OUT}/${NAME}-attempt1.xcresult"
  mv "$LOG" "${OUT}/${NAME}-attempt1.log"
  : >"$LOG"
  bounded ${SIMCTL} shutdown "$UDID" >/dev/null 2>&1 || true
  warm_simulator
  run_attempt
  classify
  record 2 "$outcome" "$reason"
fi

publish "$retried"
if [[ "$outcome" == "passed" ]]; then
  exit 0
fi
[[ "$ATTEMPT_EXIT" -ne 0 ]] && exit "$ATTEMPT_EXIT"
exit 1
