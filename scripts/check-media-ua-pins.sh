#!/bin/bash
# The media User-Agent ("OpenCast-Media/1 (+https://opencast.mobile)") is a
# deliberate byte-level contract across three languages: the device
# downloader (Swift), the transcription backend's origin fetch (Rust), and
# the benchmark harness (Python) must present the same UA so all three fetch
# the same origin representation. Nothing enforced that before this guard —
# the literals could drift silently. Any future UA flip (the CBC/Akamai
# URL-bearing-UA concern) must edit all three sites and this script's
# expectation together, with a transition plan for in-field app binaries.
#
# The original script pinned only the three constant
# DECLARATIONS (via `head -1`, so a shadowed second declaration hid), not the
# REQUEST SITES — a raw literal in the downloader's setValue, job_do's header
# set, or the benchmark's header dict would have passed unnoticed. Now:
# every declaration must match exactly once, every request site must
# reference its named constant, and the raw literal may exist nowhere else.
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"

expected='OpenCast-Media/1 (+https://opencast.mobile)'

swift_decl="OpenCast/Data/Stores/OpenCastMediaRequestProfile.swift"
rust_decl="Server/RemoteTranscriptionWorker/src/origin.rs"
python_decl="scripts/remote-transcription-benchmark/run_benchmark.py"

swift_use="OpenCast/Data/Stores/URLSessionEpisodeAudioDownloader.swift"
rust_use="Server/RemoteTranscriptionWorker/src/job_do.rs"
python_use="$python_decl"

status=0

fail() {
  echo "FAIL: $1" >&2
  status=1
}

# --- Declarations: exactly one match per site, byte-identical value. --------

check_declaration() {
  local file="$1"
  local pattern="$2"
  local matches
  matches="$(sed -nE "$pattern" "$file")"
  local count
  count="$(printf '%s' "$matches" | grep -c . || true)"
  if [[ "$count" -eq 0 ]]; then
    fail "$file no longer contains the media user-agent declaration (pattern drift?)"
  elif [[ "$count" -gt 1 ]]; then
    fail "$file declares the media user-agent $count times; a shadowed duplicate can hide drift"
  elif [[ "$matches" != "$expected" ]]; then
    fail "$file media user-agent drifted:
  expected: $expected
  found:    $matches"
  fi
}

check_declaration "$swift_decl" 's/^ *static let userAgent = "(.*)"$/\1/p'
check_declaration "$rust_decl" 's/^pub const MEDIA_USER_AGENT: &str = "(.*)";$/\1/p'
check_declaration "$python_decl" 's/^USER_AGENT = "(.*)"$/\1/p'

# --- Request sites: every UA header set must reference the named constant. --

# Swift downloader: the User-Agent header must come from the profile.
if ! grep -q 'forHTTPHeaderField: "User-Agent"' "$swift_use"; then
  fail "$swift_use no longer sets a User-Agent header (request-site drift?)"
elif grep 'forHTTPHeaderField: "User-Agent"' "$swift_use" \
    | grep -qv 'OpenCastMediaRequestProfile\.userAgent'; then
  fail "$swift_use sets a User-Agent that is not OpenCastMediaRequestProfile.userAgent"
fi

# Rust origin fetch: every user-agent header set must use the named constant.
if ! grep -q '"user-agent"' "$rust_use"; then
  fail "$rust_use no longer sets a user-agent header (request-site drift?)"
elif grep '"user-agent"' "$rust_use" | grep -qv 'MEDIA_USER_AGENT'; then
  fail "$rust_use sets a user-agent that is not origin::MEDIA_USER_AGENT"
fi

# Python benchmark: the media fetches must reference the USER_AGENT constant
# (the separate "OpenCast-Benchmark/…" UA on worker-API calls is a different,
# deliberate identity — the raw-literal sweep below still catches any media
# literal pasted into a header dict).
if ! grep -q '"user-agent": USER_AGENT' "$python_use"; then
  fail "$python_use media fetches no longer reference the USER_AGENT constant"
fi

# --- Raw-literal sweep: the UA bytes may exist only at the three
# declarations (and inside this script). A literal anywhere else is an
# unpinned request site waiting to drift. -----------------------------------

allowed_literal_files="$swift_decl
$rust_decl
$python_decl
scripts/check-media-ua-pins.sh"

stray="$(grep -rln --include='*.swift' --include='*.rs' --include='*.py' \
  --include='*.ts' --include='*.js' --include='*.mjs' --include='*.sh' \
  --exclude-dir=node_modules --exclude-dir=target --exclude-dir=build \
  --exclude-dir=dist --exclude-dir=.git \
  'OpenCast-Media/' . | sed 's|^\./||' | grep -Fxv "$allowed_literal_files" || true)"
if [[ -n "$stray" ]]; then
  fail "raw media user-agent literal outside the pinned declarations:
$stray"
fi

if [[ "$status" -eq 0 ]]; then
  echo "PASS: media user-agent pinned at declarations, request sites, and literal sweep"
fi
exit "$status"
