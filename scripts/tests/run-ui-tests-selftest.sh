#!/usr/bin/env bash
#
# Focused self-tests for scripts/run-ui-tests.sh.
#
# Exercises the wrapper's inventory guard, exit aggregation, interruption teardown,
# incomplete-result handling, missing-expected-test detection, and the --jobs 1 path —
# all with fake xcodebuild/xcresulttool, so no simulator or real build is needed.
#
set -uo pipefail

tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scripts_dir="$(cd "${tests_dir}/.." && pwd)"
repo_dir="$(cd "${scripts_dir}/.." && pwd)"

RUNNER="${scripts_dir}/run-ui-tests.sh"
MOCK_XCB="${tests_dir}/mock_xcodebuild.py"
MOCK_XCR="${tests_dir}/mock_xcresulttool.py"
chmod +x "$MOCK_XCB" "$MOCK_XCR"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0; fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
check() { # desc  actual-expr...  (checks last cmd rc already captured by caller)
  if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (want '$1' got '$2')"; fi
}

run_wrapper() { # scenario out jobs... -> sets RC, OUTFILE
  local scenario="$1"; shift
  local out="$1"; shift
  OUTFILE="${out}.stdout"
  MOCK_SCENARIO="$scenario" \
  XCODEBUILD="$MOCK_XCB" XCRESULTTOOL="$MOCK_XCR" XCTESTRUN="fake.xctestrun" \
    bash "$RUNNER" --no-build --out "$out" "$@" >"$OUTFILE" 2>&1
  RC=$?
}

echo "== run-ui-tests self-tests =="

# ---- syntax ----
bash -n "$RUNNER" && ok "bash -n runner" || bad "bash -n runner"
python3 -m py_compile "$MOCK_XCB" "$MOCK_XCR" "${scripts_dir}/lib/xcresult-testcases.py" \
  && ok "py_compile mocks+extractor" || bad "py_compile"

# ---- 1. happy parallel path ----
run_wrapper pass "${work}/happy" --jobs 2
check 0 "$RC" "parallel happy path exits 0"
[[ -d "${work}/happy/shard1.xcresult" && -d "${work}/happy/shard2.xcresult" && -d "${work}/happy/serial.xcresult" ]] \
  && ok "all three bundles written" || bad "bundles missing"
grep -q "shard1: PASS" "$OUTFILE" && grep -q "serial: PASS" "$OUTFILE" \
  && ok "lane PASS lines present" || bad "missing PASS lines"
grep -q "wall-clock" "$OUTFILE" && ok "prints wall-clock summary" || bad "no wall-clock summary"

# ---- 2. failing shard -> nonzero, diagnostics retained ----
run_wrapper fail_shard2 "${work}/failing" --jobs 2
[[ "$RC" -ne 0 ]] && ok "failing shard exits nonzero" || bad "failing shard should be nonzero"
grep -q "shard2: FAIL" "$OUTFILE" && ok "shard2 reported FAIL" || bad "shard2 not reported failed"
grep -q "failed=" "$OUTFILE" && ok "names the failed test" || bad "did not name failed test"
[[ -f "${work}/failing/shard2.log" && -d "${work}/failing/shard2.xcresult" ]] \
  && ok "diagnostics (log+bundle) preserved on failure" || bad "diagnostics not preserved"

# ---- 3. incomplete result bundle -> nonzero ----
run_wrapper incomplete_shard1 "${work}/incomplete" --jobs 2
[[ "$RC" -ne 0 ]] && ok "incomplete bundle exits nonzero" || bad "incomplete should be nonzero"
grep -Eq "shard1: FAIL.*(incomplete|no result bundle)" "$OUTFILE" \
  && ok "incomplete bundle flagged" || bad "incomplete not flagged"

# ---- 4. missing expected test -> nonzero ----
run_wrapper missing_shard1 "${work}/missing" --jobs 2
[[ "$RC" -ne 0 ]] && ok "missing-expected-test exits nonzero" || bad "missing should be nonzero"
grep -q "missing=" "$OUTFILE" && ok "names the omitted test" || bad "omitted test not named"

# ---- 5. interruption -> teardown, nonzero, bundles dir preserved ----
# NB: send SIGTERM, not SIGINT — a shell's async background job inherits SIG_IGN for
# SIGINT (POSIX), so `kill -INT` on a backgrounded wrapper is a no-op. A real foreground
# Ctrl-C delivers SIGINT to the process group and is trapped normally.
MOCK_SCENARIO=hang XCODEBUILD="$MOCK_XCB" XCRESULTTOOL="$MOCK_XCR" XCTESTRUN="fake.xctestrun" \
  bash "$RUNNER" --no-build --out "${work}/intr" --jobs 2 >"${work}/intr.stdout" 2>&1 &
wpid=$!
for _ in $(seq 1 20); do  # wait until both mock lanes are in flight
  [[ "$(pgrep -f mock_xcodebuild.py | grep -c . || true)" -ge 2 ]] && break
  sleep 0.3
done
kill -TERM "$wpid" 2>/dev/null
wait "$wpid"; irc=$?
check 130 "$irc" "interrupt exits 130"
[[ -d "${work}/intr" ]] && ok "output dir preserved after interrupt" || bad "output dir gone"
sleep 0.5
[[ "$(pgrep -f mock_xcodebuild.py | grep -c . || true)" -eq 0 ]] \
  && ok "no orphaned lane processes after interrupt" || bad "orphaned lane processes remain"

# ---- 6. --jobs 1 serial fallback ----
run_wrapper pass "${work}/fallback" --jobs 1
check 0 "$RC" "serial fallback exits 0"
[[ -d "${work}/fallback/fallback.xcresult" ]] && ok "fallback bundle written" || bad "no fallback bundle"
[[ ! -e "${work}/fallback/shard1.xcresult" ]] && ok "fallback does not create shard bundles" || bad "unexpected shard bundle"
grep -q "fallback: PASS" "$OUTFILE" && ok "fallback PASS reported" || bad "fallback PASS missing"

# ---- 7. manifest drift guard ----
mkdir -p "${work}/src"
cat >"${work}/src/OpenCastUITests.swift" <<'SWIFT'
func testAlpha() {}
func testBeta() {}
func testGamma() {}
SWIFT
# 7a clean manifest
cat >"${work}/clean.txt" <<'MAN'
shard1 OpenCastUITests/OpenCastUITests/testAlpha
shard2 OpenCastUITests/OpenCastUITests/testBeta
serial OpenCastUITests/OpenCastUITests/testGamma
MAN
MANIFEST="${work}/clean.txt" SOURCE="${work}/src/OpenCastUITests.swift" bash "$RUNNER" --check >/dev/null 2>&1
check 0 "$?" "clean manifest passes --check"
# 7b unassigned source test
cat >"${work}/drift.txt" <<'MAN'
shard1 OpenCastUITests/OpenCastUITests/testAlpha
shard2 OpenCastUITests/OpenCastUITests/testBeta
MAN
MANIFEST="${work}/drift.txt" SOURCE="${work}/src/OpenCastUITests.swift" bash "$RUNNER" --check >"${work}/drift.out" 2>&1
[[ "$?" -ne 0 ]] && ok "unassigned source test fails --check" || bad "drift not caught"
grep -q "testGamma" "${work}/drift.out" && ok "names the unassigned test" || bad "unassigned test not named"
# 7c dead manifest reference
cat >"${work}/dead.txt" <<'MAN'
shard1 OpenCastUITests/OpenCastUITests/testAlpha
shard2 OpenCastUITests/OpenCastUITests/testBeta
serial OpenCastUITests/OpenCastUITests/testGamma
exclude OpenCastUITests/OpenCastUITests/testGhost
MAN
MANIFEST="${work}/dead.txt" SOURCE="${work}/src/OpenCastUITests.swift" bash "$RUNNER" --check >"${work}/dead.out" 2>&1
[[ "$?" -ne 0 ]] && ok "dead manifest ref fails --check" || bad "dead ref not caught"
grep -q "testGhost" "${work}/dead.out" && ok "names the dead reference" || bad "dead ref not named"

echo
echo "== $pass passed, $fail failed =="
[[ "$fail" -eq 0 ]]
