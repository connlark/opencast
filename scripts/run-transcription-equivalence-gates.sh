#!/bin/zsh
# Whisper-perf J3: numerical-equivalence guard for the transcription decode
# host paths. Runs the D2 certify-or-fallback timestamp-filter suite and the
# D3 CPU greedy-sampler suite at pinned fuzz iteration counts.
#
# Run before a release and after any macOS/Xcode/iOS SDK bump or WhisperKit
# fork change: these suites are the standing check that BNNS/vDSP reductions
# still agree with the exact upstream pipeline (the D2 margin has ~90x
# headroom over the worst observed BNNS disagreement; an OS shift that eats
# into it surfaces here first).
#
# Override the pinned counts with OPENCAST_D2_FUZZ_ITERATIONS /
# OPENCAST_D3_FUZZ_ITERATIONS if a deeper sweep is wanted.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
D2_ITERATIONS="${OPENCAST_D2_FUZZ_ITERATIONS:-20000}"
D3_ITERATIONS="${OPENCAST_D3_FUZZ_ITERATIONS:-20000}"

echo "==> Transcription equivalence gates (D2=$D2_ITERATIONS, D3=$D3_ITERATIONS iterations)"
OPENCAST_D2_FUZZ_ITERATIONS="$D2_ITERATIONS" \
OPENCAST_D3_FUZZ_ITERATIONS="$D3_ITERATIONS" \
swift test --package-path "$REPO_ROOT/Packages/OpenCastTranscription" \
  --filter "TimestampFilterDecisionEquivalenceTests|GreedySamplerEquivalenceTests"

echo "==> Transcription equivalence gates passed"
