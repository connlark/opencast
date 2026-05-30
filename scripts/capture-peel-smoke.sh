#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "${script_dir}/.." && pwd)"
artifact_root="${repo_dir}/artifacts/peel-smoke"
timestamp="$(date +%Y%m%d-%H%M%S)"
artifact_dir="${artifact_root}/${timestamp}"
manifest="${artifact_dir}/manifest.json"
result_bundle="${artifact_dir}/peel-focused.xcresult"
attachments_dir="${artifact_dir}/attachments"
normal_recording="${artifact_dir}/normal.mp4"
reduce_recording="${artifact_dir}/reduce-motion.mp4"
simulator_name="${OPENCAST_PEEL_SMOKE_SIMULATOR_NAME:-iPhone 17}"

tests=(
  "OpenCastUITests/OpenCastUITests/testSeededNowPlayingArtworkPeelsOpenSoundLabPanel"
  "OpenCastUITests/OpenCastUITests/testSeededNowPlayingArtworkPeelClosesSoundLabPanel"
  "OpenCastUITests/OpenCastUITests/testSeededNowPlayingArtworkTapClosesSoundLabPanel"
  "OpenCastUITests/OpenCastUITests/testSeededNowPlayingArtworkTapOpensSoundLabPanel"
  "OpenCastUITests/OpenCastUITests/testSeededNowPlayingCanDismissFromContentArea"
  "OpenCastUITests/OpenCastUITests/testSeededNowPlayingArtworkPeelDragDoesNotDismissOrMoveCard"
  "OpenCastUITests/OpenCastUITests/testSeededNowPlayingColorCheckerArtworkPeelScreenshots"
  "OpenCastUITests/OpenCastUITests/testSeededNowPlayingPlaceholderArtworkPeelScreenshots"
)

mkdir -p "${artifact_dir}"
rm -rf "${result_bundle}" "${attachments_dir}"

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  printf '%s' "${value}"
}

append_manifest() {
  local key="$1"
  local value="$2"
  printf '%s=%s\n' "${key}" "${value}" >> "${artifact_dir}/manifest.env"
}

select_simulator_udid() {
  xcrun simctl list devices available | awk -F '[()]' -v simulator_name="${simulator_name}" '
    {
      name = $1
      sub(/^[[:space:]]+/, "", name)
      sub(/[[:space:]]+$/, "", name)
      if (name == simulator_name) {
        print $2
        exit
      }
    }
  '
}

boot_simulator() {
  local udid="$1"
  xcrun simctl boot "${udid}" 2>/dev/null || true
  xcrun simctl bootstatus "${udid}" -b
}

set_reduce_motion() {
  local udid="$1"
  local enabled="$2"
  xcrun simctl spawn "${udid}" defaults write com.apple.Accessibility ReduceMotionEnabled -bool "${enabled}" 2>/dev/null || true
  xcrun simctl spawn "${udid}" defaults write com.apple.Accessibility reduceMotionEnabled -bool "${enabled}" 2>/dev/null || true
}

run_xcodebuild_tests() {
  local bundle_path="$1"
  shift
  local only_testing=()
  local test_name
  for test_name in "$@"; do
    only_testing+=("-only-testing:${test_name}")
  done

  OPENCAST_ATTACH_PEEL_SCREENSHOTS=1 xcodebuild \
    -project "${repo_dir}/opencast.xcodeproj" \
    -scheme OpenCast \
    -destination "platform=iOS Simulator,name=${simulator_name}" \
    -parallel-testing-enabled NO \
    -maximum-concurrent-test-simulator-destinations 1 \
    -resultBundlePath "${bundle_path}" \
    test \
    "${only_testing[@]}"
}

stop_recording() {
  local pid="$1"
  if kill -0 "${pid}" 2>/dev/null; then
    kill -INT "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
  fi
}

make_contact_sheets() {
  local recording="$1"
  local prefix="$2"
  if [[ ! -s "${recording}" ]]; then
    append_manifest "${prefix}_recording_status" "missing-or-empty"
    return
  fi

  if ffmpeg -y -hide_banner -loglevel error -i "${recording}" -vf "fps=1,scale=260:-1,tile=5x5" -frames:v 1 "${artifact_dir}/${prefix}-sheet.png"; then
    append_manifest "${prefix}_sheet" "${artifact_dir}/${prefix}-sheet.png"
  else
    append_manifest "${prefix}_sheet" "failed"
  fi

  if ffmpeg -y -hide_banner -loglevel error -sseof -6.0 -i "${recording}" -vf "fps=12,scale=260:-1,tile=5x5" -frames:v 1 "${artifact_dir}/${prefix}-transition-sheet.png"; then
    append_manifest "${prefix}_transition_sheet" "${artifact_dir}/${prefix}-transition-sheet.png"
  else
    append_manifest "${prefix}_transition_sheet" "failed"
  fi
}

record_test_run() {
  local udid="$1"
  local recording="$2"
  local bundle_path="$3"
  local reduce_motion="$4"

  rm -f "${recording}"
  set_reduce_motion "${udid}" "${reduce_motion}"
  xcrun simctl io "${udid}" recordVideo "${recording}" >/dev/null 2>&1 &
  local recording_pid="$!"
  sleep 2
  run_xcodebuild_tests "${bundle_path}" "OpenCastUITests/OpenCastUITests/testSeededNowPlayingArtworkPeelsOpenSoundLabPanel" || {
    stop_recording "${recording_pid}"
    return 1
  }
  stop_recording "${recording_pid}"
  sleep 1
}

udid="$(select_simulator_udid)"
if [[ -z "${udid}" ]]; then
  printf 'Could not find an available %s simulator.\n' "${simulator_name}" >&2
  exit 1
fi

append_manifest "artifact_dir" "${artifact_dir}"
append_manifest "simulator_udid" "${udid}"
append_manifest "simulator_name" "${simulator_name}"

cleanup() {
  set_reduce_motion "${udid}" "NO"
}
trap cleanup EXIT

boot_simulator "${udid}"
set_reduce_motion "${udid}" "NO"

if run_xcodebuild_tests "${result_bundle}" "${tests[@]}"; then
  append_manifest "focused_tests" "passed"
else
  append_manifest "focused_tests" "failed"
fi

mkdir -p "${attachments_dir}"
if xcrun xcresulttool export attachments --path "${result_bundle}" --output-path "${attachments_dir}"; then
  append_manifest "attachments" "${attachments_dir}"
else
  append_manifest "attachments" "export-failed"
fi

if record_test_run "${udid}" "${normal_recording}" "${artifact_dir}/normal-recorded.xcresult" "NO"; then
  append_manifest "normal_recording" "${normal_recording}"
else
  append_manifest "normal_recording" "failed"
fi
make_contact_sheets "${normal_recording}" "normal"

if record_test_run "${udid}" "${reduce_recording}" "${artifact_dir}/reduce-motion-recorded.xcresult" "YES"; then
  append_manifest "reduce_motion_recording" "${reduce_recording}"
else
  append_manifest "reduce_motion_recording" "failed"
fi
make_contact_sheets "${reduce_recording}" "reduce-motion"

if [[ -x "${repo_dir}/scripts/analyze-peel-color-smoke.py" ]]; then
  if "${repo_dir}/scripts/analyze-peel-color-smoke.py" "${attachments_dir}" > "${artifact_dir}/color-analysis.json"; then
    append_manifest "color_analysis" "${artifact_dir}/color-analysis.json"
  else
    append_manifest "color_analysis" "failed"
  fi
fi

{
  printf '{\n'
  first=1
  while IFS='=' read -r key value; do
    [[ -n "${key}" ]] || continue
    if [[ "${first}" -eq 0 ]]; then
      printf ',\n'
    fi
    first=0
    printf '  "%s": "%s"' "$(json_escape "${key}")" "$(json_escape "${value}")"
  done < "${artifact_dir}/manifest.env"
  printf '\n}\n'
} > "${manifest}"

printf 'Peel smoke artifacts: %s\n' "${artifact_dir}"
printf 'Manifest: %s\n' "${manifest}"
