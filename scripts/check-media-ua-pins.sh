#!/bin/bash
# The media User-Agent ("OpenCast-Media/1 (+https://opencast.mobile)") is a
# deliberate byte-level contract across three languages: the device
# downloader (Swift), the transcription backend's origin fetch (Rust), and
# the benchmark harness (Python) must present the same UA so all three fetch
# the same origin representation. Nothing enforced that before Phase 10 H —
# the literals could drift silently. Any future UA flip (the CBC/Akamai
# URL-bearing-UA concern) must edit all three sites and this script's
# expectation together, with a transition plan for in-field app binaries.
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"

expected='OpenCast-Media/1 (+https://opencast.mobile)'

swift_site="OpenCast/Data/Stores/OpenCastMediaRequestProfile.swift"
rust_site="Server/RemoteTranscriptionWorker/src/origin.rs"
python_site="scripts/remote-transcription-benchmark/run_benchmark.py"

status=0

check_site() {
  local file="$1"
  local pattern="$2"
  local extracted
  extracted="$(sed -nE "$pattern" "$repo_dir/$file" | head -1)"
  if [[ -z "$extracted" ]]; then
    echo "FAIL: $file no longer contains the media user-agent literal (pattern drift?)" >&2
    status=1
  elif [[ "$extracted" != "$expected" ]]; then
    echo "FAIL: $file media user-agent drifted:" >&2
    echo "  expected: $expected" >&2
    echo "  found:    $extracted" >&2
    status=1
  fi
}

check_site "$swift_site" 's/^ *static let userAgent = "(.*)"$/\1/p'
check_site "$rust_site" 's/^pub const MEDIA_USER_AGENT: &str = "(.*)";$/\1/p'
check_site "$python_site" 's/^USER_AGENT = "(.*)"$/\1/p'

if [[ "$status" -eq 0 ]]; then
  echo "PASS: media user-agent byte-identical across Swift, Rust, and Python sites"
fi
exit "$status"
