#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "${script_dir}/.." && pwd)"
artifact_root="${repo_dir}/artifacts/ui-smoke"
timestamp="$(date +%Y%m%d-%H%M%S)"
result_bundle="${artifact_root}/OpenCastPadSmoke-${timestamp}.xcresult"
attachments_dir="${artifact_root}/OpenCastPadSmoke-${timestamp}-attachments"
ipad_udid="${OPENCAST_IPAD_SIMULATOR_ID:-}"

if [[ -z "${ipad_udid}" ]]; then
  printf 'Set OPENCAST_IPAD_SIMULATOR_ID to an available iPad simulator UDID.\n' >&2
  exit 2
fi

mkdir -p "${artifact_root}"
rm -rf "${result_bundle}" "${attachments_dir}"

xcodebuild \
  -project "${repo_dir}/opencast.xcodeproj" \
  -scheme OpenCast \
  -destination "platform=iOS Simulator,id=${ipad_udid}" \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-device-destinations 1 \
  -only-testing:OpenCastUITests/OpenCastPadUITests/testSeededPadSmokeScreenshots \
  -resultBundlePath "${result_bundle}" \
  test

mkdir -p "${attachments_dir}"
if xcrun xcresulttool export attachments --path "${result_bundle}" --output-path "${attachments_dir}"; then
  printf 'iPad smoke result bundle: %s\n' "${result_bundle}"
  printf 'Screenshot attachments: %s\n' "${attachments_dir}"
  printf 'Attachment manifest: %s\n' "${attachments_dir}/manifest.json"
else
  printf 'iPad smoke result bundle: %s\n' "${result_bundle}"
  printf 'Attachment export failed. Extract manually with:\n'
  printf 'xcrun xcresulttool export attachments --path %q --output-path %q\n' "${result_bundle}" "${attachments_dir}"
fi
