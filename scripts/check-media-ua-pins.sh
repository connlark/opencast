#!/bin/bash
# The media request profile is a byte-level contract across three languages:
# the device downloader (Swift), the transcription backend's origin fetch
# (Rust), and the benchmark harness (Python) present the same URL-free
# User-Agent with identity encoding, so all three fetch the same origin
# representation. The app declares the profile number when it creates a
# transcription job and the backend fetches with that profile's User-Agent;
# jobs that declare nothing come from app versions that still download with
# the legacy profile-1 value, which only the backend keeps, until those
# versions age out.
#
# Every declaration must match exactly once (a shadowed duplicate can hide
# drift), every request site must use its named constant or the backend's
# per-job selector, and the raw literals may exist nowhere else. Changing the
# profile edits every site and this script's expectations together, keeps the
# previous value as the backend's legacy User-Agent, and ships the backend
# before the app.
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"

expected_profile='2'
expected="OpenCast-Media/${expected_profile}"
expected_legacy='OpenCast-Media/1 (+https://opencast.mobile)'
expected_encoding='identity'

swift_decl="OpenCast/Data/Stores/OpenCastMediaRequestProfile.swift"
rust_decl="Server/RemoteTranscriptionWorker/src/origin.rs"
python_decl="scripts/remote-transcription-benchmark/run_benchmark.py"
spec_decl="Server/RemoteTranscriptionWorker/test/integration.spec.mjs"

swift_use="OpenCast/Data/Stores/URLSessionEpisodeAudioDownloader.swift"
swift_create="OpenCast/Data/Stores/RemoteTranscriptionJobRunner.swift"
rust_use="Server/RemoteTranscriptionWorker/src/job_do.rs"
python_use="$python_decl"

status=0

fail() {
  echo "FAIL: $1" >&2
  status=1
}

if [[ "$expected" == *"://"* ]]; then
  fail "the media user-agent must stay URL-free: $expected"
fi

# --- Declarations: exactly one match per site, byte-identical value. --------

check_declaration() {
  local file="$1"
  local pattern="$2"
  local want="$3"
  local label="$4"
  local matches
  matches="$(sed -nE "$pattern" "$file")"
  local count
  count="$(printf '%s' "$matches" | grep -c . || true)"
  if [[ "$count" -eq 0 ]]; then
    fail "$file no longer contains the $label declaration (pattern drift?)"
  elif [[ "$count" -gt 1 ]]; then
    fail "$file declares the $label $count times; a shadowed duplicate can hide drift"
  elif [[ "$matches" != "$want" ]]; then
    fail "$file $label drifted:
  expected: $want
  found:    $matches"
  fi
}

check_declaration "$swift_decl" 's/^ *static let userAgent = "(.*)"$/\1/p' "$expected" "media user-agent"
check_declaration "$rust_decl" 's/^pub const MEDIA_USER_AGENT: &str = "(.*)";$/\1/p' "$expected" "media user-agent"
check_declaration "$python_decl" 's/^USER_AGENT = "(.*)"$/\1/p' "$expected" "media user-agent"
check_declaration "$spec_decl" 's/^const MEDIA_USER_AGENT = "(.*)";$/\1/p' "$expected" "media user-agent"

check_declaration "$swift_decl" 's/^ *static let version = (.*)$/\1/p' "$expected_profile" "media profile"
check_declaration "$rust_decl" 's/^pub const MEDIA_PROFILE: u32 = (.*);$/\1/p' "$expected_profile" "media profile"
check_declaration "$python_decl" 's/^MEDIA_PROFILE = (.*)$/\1/p' "$expected_profile" "media profile"
check_declaration "$spec_decl" 's/^const MEDIA_PROFILE = (.*);$/\1/p' "$expected_profile" "media profile"

check_declaration "$swift_decl" 's/^ *static let acceptEncoding = "(.*)"$/\1/p' "$expected_encoding" "media accept-encoding"
check_declaration "$rust_decl" 's/^pub const MEDIA_ACCEPT_ENCODING: &str = "(.*)";$/\1/p' "$expected_encoding" "media accept-encoding"

check_declaration "$rust_decl" 's/^pub const LEGACY_MEDIA_USER_AGENT: &str = "(.*)";$/\1/p' "$expected_legacy" "legacy media user-agent"
check_declaration "$spec_decl" 's/^const LEGACY_MEDIA_USER_AGENT = "(.*)";$/\1/p' "$expected_legacy" "legacy media user-agent"

# --- Request sites: every header set must reference the named constant. -----

# Swift downloader: both media headers must come from the profile.
if ! grep -q 'forHTTPHeaderField: "User-Agent"' "$swift_use"; then
  fail "$swift_use no longer sets a User-Agent header (request-site drift?)"
elif grep 'forHTTPHeaderField: "User-Agent"' "$swift_use" \
    | grep -qv 'OpenCastMediaRequestProfile\.userAgent'; then
  fail "$swift_use sets a User-Agent that is not OpenCastMediaRequestProfile.userAgent"
fi
if ! grep 'forHTTPHeaderField: "Accept-Encoding"' "$swift_use" \
    | grep -q 'OpenCastMediaRequestProfile\.acceptEncoding'; then
  fail "$swift_use no longer sets Accept-Encoding from OpenCastMediaRequestProfile.acceptEncoding"
fi

# Swift job create: the app declares the profile it downloads with, or the
# backend falls back to the legacy User-Agent for its origin fetch.
if ! grep -q 'mediaProfile: OpenCastMediaRequestProfile\.version' "$swift_create"; then
  fail "$swift_create no longer declares mediaProfile: OpenCastMediaRequestProfile.version on create"
fi

# Rust origin fetch: every user-agent header set must use the per-job
# selector, and the encoding must be the named constant.
rust_ua_sites="$(grep -c '"user-agent"' "$rust_use" || true)"
rust_ua_selected="$(grep -A2 '"user-agent"' "$rust_use" \
  | grep -c 'crate::origin::media_user_agent(record\.media_profile)' || true)"
if [[ "$rust_ua_sites" -eq 0 ]]; then
  fail "$rust_use no longer sets a user-agent header (request-site drift?)"
elif [[ "$rust_ua_selected" -ne "$rust_ua_sites" ]]; then
  fail "$rust_use sets a user-agent that is not origin::media_user_agent(record.media_profile)"
fi
if grep '"accept-encoding"' "$rust_use" | grep -qv 'MEDIA_ACCEPT_ENCODING'; then
  fail "$rust_use sets an accept-encoding that is not origin::MEDIA_ACCEPT_ENCODING"
fi

# Python benchmark: the media fetches must reference the USER_AGENT constant
# and its job create must declare the profile (the separate
# "OpenCast-Benchmark/…" UA on worker-API calls is a different, deliberate
# identity — the raw-literal sweep below still catches any media literal
# pasted into a header dict).
if ! grep -q '"user-agent": USER_AGENT' "$python_use"; then
  fail "$python_use media fetches no longer reference the USER_AGENT constant"
fi
if ! grep -q '"media_profile": MEDIA_PROFILE' "$python_use"; then
  fail "$python_use job create no longer declares media_profile: MEDIA_PROFILE"
fi

# --- Raw-literal sweep: media user-agent bytes may exist only at the
# declarations (and inside this script); the legacy value only in the
# backend and the suite that checks its selection. -------------------------

sweep() {
  grep -rlF --include='*.swift' --include='*.rs' --include='*.py' \
    --include='*.ts' --include='*.js' --include='*.mjs' --include='*.sh' \
    --exclude-dir=node_modules --exclude-dir=target --exclude-dir=build \
    --exclude-dir=dist --exclude-dir=.git \
    "$1" . | sed 's|^\./||' | sort
}

allowed_literal_files="$swift_decl
$rust_decl
$python_decl
$spec_decl
scripts/check-media-ua-pins.sh"

stray="$(sweep 'OpenCast-Media/' | grep -Fxv "$allowed_literal_files" || true)"
if [[ -n "$stray" ]]; then
  fail "raw media user-agent literal outside the pinned declarations:
$stray"
fi

allowed_legacy_files="$rust_decl
$spec_decl
scripts/check-media-ua-pins.sh"

stray_legacy="$(sweep "$expected_legacy" | grep -Fxv "$allowed_legacy_files" || true)"
if [[ -n "$stray_legacy" ]]; then
  fail "legacy media user-agent outside the backend's per-job selection:
$stray_legacy"
fi

if [[ "$status" -eq 0 ]]; then
  echo "PASS: media profile $expected_profile ($expected) pinned at declarations, request sites, and literal sweep; legacy value backend-only"
fi
exit "$status"
