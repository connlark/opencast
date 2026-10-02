#!/usr/bin/env bash
#
# Focused self-tests for scripts/run-ci-simulator-tests.sh.
#
# Exercises the warm-up order, the attempt classification, the single infrastructure
# retry, and the cases that must never retry (a real test failure, a mixed failure, a
# failed build) — all with fake xcodebuild/simctl/xcresulttool, so no simulator or
# real build is needed.
#
set -uo pipefail

tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scripts_dir="$(cd "${tests_dir}/.." && pwd)"

RUNNER="${scripts_dir}/run-ci-simulator-tests.sh"
MOCK="${tests_dir}/mock_ci_simulator_tools.py"
chmod +x "$MOCK"

# CI runs the runner with the macOS system shell (bash 3.2), whatever newer
# bash is first on a developer's PATH. Test with that shell when it exists.
RUNNER_SHELL="${RUNNER_SHELL:-/bin/bash}"
[[ -x "$RUNNER_SHELL" ]] || RUNNER_SHELL="bash"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Every tool is mocked; never write bytecode in the repo or wait on a real launch.
export PYTHONPYCACHEPREFIX="${work}/pycache"
export WARM_LAUNCH_SECONDS=0

pass=0; fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
check() { if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (want '$1' got '$2')"; fi; }

run_case() { # name scenario [VAR=value...] -> sets RC, OUT, CALLS, SUMMARY, OUTPUTS
  local name="$1" scenario="$2"; shift 2
  OUT="${work}/${name}"
  CALLS="${work}/${name}.calls"
  SUMMARY="${work}/${name}.summary.md"
  OUTPUTS="${work}/${name}.outputs"
  : >"$CALLS"; : >"$SUMMARY"; : >"$OUTPUTS"
  env "$@" MOCK_SCENARIO="$scenario" MOCK_CALLS="$CALLS" \
    XCODEBUILD="python3 $MOCK xcodebuild" SIMCTL="python3 $MOCK simctl" \
    XCRESULTTOOL="python3 $MOCK xcresulttool" \
    GITHUB_STEP_SUMMARY="$SUMMARY" GITHUB_OUTPUT="$OUTPUTS" \
    "$RUNNER_SHELL" "$RUNNER" --udid mock-simulator --name lane --out "$OUT" -- \
      -only-testing:OpenCastTests -only-testing:OpenCastUITests/OpenCastUITests/testSmoke \
      >"${work}/${name}.stdout" 2>&1
  RC=$?
}

test_calls() { grep -c '^xcodebuild test-without-building' "$CALLS" || true; }
call_order() { awk '{ print ($1 == "xcodebuild" ? $2 : "simctl-" $2) }' "$CALLS" | tr '\n' ' '; }

echo "== run-ci-simulator-tests self-tests =="

"$RUNNER_SHELL" -n "$RUNNER" && ok "runner parses under ${RUNNER_SHELL}" || bad "runner parses under ${RUNNER_SHELL}"
python3 -m py_compile "$MOCK" && ok "py_compile mock" || bad "py_compile mock"

# ---- 1. clean pass: warm-up order, one attempt, selection passed through ----
run_case clean pass
check 0 "$RC" "clean pass exits 0"
check 1 "$(test_calls)" "clean pass runs one attempt"
check "simctl-boot simctl-bootstatus build-for-testing simctl-boot simctl-bootstatus simctl-install simctl-launch simctl-terminate test-without-building " \
  "$(call_order)" "boot, build, warm-launch, then test"
grep -q -- 'simctl launch mock-simulator example.opencast.mock --opencast-ui-testing' "$CALLS" \
  && ok "warm-up launch uses the UI-testing store" || bad "warm-up launch arguments"
grep -q -- '-collect-test-diagnostics never .*-only-testing:OpenCastTests -only-testing:OpenCastUITests/OpenCastUITests/testSmoke' "$CALLS" \
  && ok "selection and diagnostics flag reach xcodebuild" || bad "selection not passed through"
grep -q '^retried=false$' "$OUTPUTS" && ok "reports retried=false" || bad "retried output missing"
grep -q '| 1 | passed |' "$SUMMARY" && ok "summary records the passing attempt" || bad "summary row missing"
[[ -d "${OUT}/lane.xcresult" && ! -e "${OUT}/lane-attempt1.xcresult" ]] \
  && ok "one bundle, no attempt-1 copy" || bad "unexpected bundles"

# ---- 2. launch timeout, then pass: exactly one retry, evidence kept ----
run_case launch launch_timeout,pass
check 0 "$RC" "launch timeout then pass exits 0"
check 2 "$(test_calls)" "launch timeout retries once"
grep -q '| 1 | infrastructure | launch timeout' "$SUMMARY" && grep -q '| 2 | passed |' "$SUMMARY" \
  && ok "summary records both attempts" || bad "summary rows wrong"
grep -q '^retried=true$' "$OUTPUTS" && ok "reports retried=true" || bad "retried output missing"
[[ -d "${OUT}/lane-attempt1.xcresult" && -s "${OUT}/lane-attempt1.log" && -d "${OUT}/lane.xcresult" ]] \
  && ok "attempt-1 bundle and log preserved" || bad "attempt-1 evidence missing"
grep -q '^simctl shutdown mock-simulator$' "$CALLS" && ok "simulator rebooted before the retry" || bad "no shutdown before retry"

# ---- 3. runner never initialized (no tests), then pass ----
run_case axload ax_timeout,pass
check 0 "$RC" "accessibility-load timeout then pass exits 0"
check 2 "$(test_calls)" "accessibility-load timeout retries once"
grep -q 'no tests executed (accessibility load timeout)' "$SUMMARY" && ok "names the signature" || bad "signature not named"

# ---- 4. no result bundle at all, then pass ----
run_case nobundle no_bundle,pass
check 0 "$RC" "missing bundle then pass exits 0"
check 2 "$(test_calls)" "missing bundle retries once"

# ---- 5. a real failure is never retried ----
run_case real real_failure,pass
[[ "$RC" -ne 0 ]] && ok "real failure exits nonzero" || bad "real failure should be nonzero"
check 1 "$(test_calls)" "real failure is not retried"
grep -q '| 1 | failed | 1 of 3 tests failed' "$SUMMARY" && ok "summary records the failure" || bad "failure row missing"
grep -q '^retried=false$' "$OUTPUTS" && ok "real failure reports retried=false" || bad "retried output wrong"

# ---- 6. a launch signature next to a real failure is still a failure ----
run_case mixed mixed,pass
[[ "$RC" -ne 0 ]] && ok "mixed failure exits nonzero" || bad "mixed failure should be nonzero"
check 1 "$(test_calls)" "mixed failure is not retried"

# ---- 7. infrastructure twice fails after exactly two attempts ----
run_case twice launch_timeout,launch_timeout,pass
[[ "$RC" -ne 0 ]] && ok "second infrastructure attempt exits nonzero" || bad "should be nonzero"
check 2 "$(test_calls)" "never a third attempt"
grep -q '| 2 | infrastructure |' "$SUMMARY" && ok "summary records the second infrastructure attempt" || bad "row missing"

# ---- 8. zero tests with a zero exit is not a pass ----
run_case zero zero_tests,zero_tests
[[ "$RC" -ne 0 ]] && ok "zero executed tests exits nonzero" || bad "zero tests must not pass"
check 2 "$(test_calls)" "zero tests retried once"

# ---- 9. a failed build is never retried and never tested ----
run_case build pass MOCK_BUILD_FAILS=1
check 65 "$RC" "failed build returns the build's exit code"
check 0 "$(test_calls)" "failed build runs no tests"
grep -q '| build | failed |' "$SUMMARY" && ok "summary records the failed build" || bad "build row missing"
grep -q '^simctl launch' "$CALLS" && bad "failed build must not warm-launch" || ok "no warm-up launch after a failed build"

# ---- 10. warm-up is best effort ----
run_case warm pass MOCK_SIMCTL_FAIL=launch,bootstatus
check 0 "$RC" "failed warm-up still runs and passes the tests"
check 1 "$(test_calls)" "failed warm-up does not add an attempt"
grep -q 'warning: warm-up launch failed' "${work}/warm.stdout" && ok "warm-up failure is reported" || bad "no warm-up warning"

# ---- 11. argument validation ----
"$RUNNER_SHELL" "$RUNNER" --udid mock --name lane --out "${work}/args" >/dev/null 2>&1
check 2 "$?" "missing selection is a usage error"

echo
echo "passed=${pass} failed=${fail}"
[[ "$fail" -eq 0 ]]
