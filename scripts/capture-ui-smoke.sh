#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "${script_dir}/.." && pwd)"
artifact_root="${repo_dir}/artifacts/ui-smoke"
timestamp="$(date +%Y%m%d-%H%M%S)"
result_bundle="${artifact_root}/OpenCastUISmoke-${timestamp}.xcresult"
attachments_dir="${artifact_root}/OpenCastUISmoke-${timestamp}-attachments"

mkdir -p "${artifact_root}"
rm -rf "${result_bundle}" "${attachments_dir}"

xcodebuild \
  -project "${repo_dir}/opencast.xcodeproj" \
  -scheme OpenCast \
  -destination "platform=iOS Simulator,name=iPhone 17" \
  -only-testing:OpenCastUITests/OpenCastUITests/testSeededCompactSmokeScreenshots \
  -only-testing:OpenCastUITests/OpenCastUITests/testSeededCompletedDownloadSmokeScreenshots \
  -only-testing:OpenCastUITests/OpenCastUITests/testSeededEpisodeProgressRestoresMiniPlayerAndShowsRows \
  -only-testing:OpenCastUITests/OpenCastUITests/testSeededLightNowPlayingScreenshot \
  -resultBundlePath "${result_bundle}" \
  test

mkdir -p "${attachments_dir}"
if xcrun xcresulttool export attachments --path "${result_bundle}" --output-path "${attachments_dir}"; then
  printf 'UI smoke result bundle: %s\n' "${result_bundle}"
  printf 'Screenshot attachments: %s\n' "${attachments_dir}"
  printf 'Attachment manifest: %s\n' "${attachments_dir}/manifest.json"
else
  printf 'UI smoke result bundle: %s\n' "${result_bundle}"
  printf 'Attachment export failed. Extract manually with:\n'
  printf 'xcrun xcresulttool export attachments --path %q --output-path %q\n' "${result_bundle}" "${attachments_dir}"
fi
