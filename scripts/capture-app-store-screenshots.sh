#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "${script_dir}/.." && pwd)"
artifact_root="${repo_dir}/artifacts/app-store-screenshots"
timestamp="$(date +%Y%m%d-%H%M%S)"
run_dir="${artifact_root}/${timestamp}"
test_identifier="OpenCastUITests/AppStoreScreenshotUITests/testAppStoreScreenshotSet"

iphone_destination="${IPHONE_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro Max}"
ipad_destination="${IPAD_DESTINATION:-platform=iOS Simulator,name=iPad Pro 13-inch (M4)}"
capture_ipad="${CAPTURE_IPAD:-1}"

mkdir -p "${run_dir}"

run_capture() {
  local label="$1"
  local destination="$2"
  local result_bundle="${run_dir}/${label}.xcresult"
  local attachments_dir="${run_dir}/${label}-attachments"
  local screenshots_dir="${run_dir}/${label}-screenshots"

  rm -rf "${result_bundle}" "${attachments_dir}" "${screenshots_dir}"

  xcodebuild \
    -project "${repo_dir}/opencast.xcodeproj" \
    -scheme OpenCast \
    -destination "${destination}" \
    -only-testing:"${test_identifier}" \
    -resultBundlePath "${result_bundle}" \
    OPENCAST_INCLUDE_APP_STORE_SCREENSHOT_FIXTURES=YES \
    'OPENCAST_APP_STORE_SCREENSHOT_FIXTURE_OUTPUT_DIR=$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/AppStoreScreenshots/Artwork' \
    test

  mkdir -p "${attachments_dir}" "${screenshots_dir}"
  if xcrun xcresulttool export attachments --path "${result_bundle}" --output-path "${attachments_dir}"; then
    ruby -rjson -rfileutils -e '
      manifest_path, attachments_dir, screenshots_dir = ARGV
      JSON.parse(File.read(manifest_path)).each do |test|
        test.fetch("attachments", []).each do |attachment|
          exported = attachment.fetch("exportedFileName")
          suggested = attachment.fetch("suggestedHumanReadableName", exported)
          stable = suggested.sub(/_\d+_[0-9A-F-]+\.png\z/, ".png")
          FileUtils.cp(File.join(attachments_dir, exported), File.join(screenshots_dir, stable))
        end
      end
    ' "${attachments_dir}/manifest.json" "${attachments_dir}" "${screenshots_dir}"
    printf '%s result bundle: %s\n' "${label}" "${result_bundle}"
    printf '%s exported screenshots: %s\n' "${label}" "${screenshots_dir}"
    printf '%s attachment manifest: %s\n' "${label}" "${attachments_dir}/manifest.json"
  else
    printf '%s result bundle: %s\n' "${label}" "${result_bundle}"
    printf '%s attachment export failed. Extract manually with:\n' "${label}"
    printf 'xcrun xcresulttool export attachments --path %q --output-path %q\n' "${result_bundle}" "${attachments_dir}"
  fi
}

run_capture "iphone_6_9" "${iphone_destination}"

if [[ "${capture_ipad}" == "1" ]]; then
  run_capture "ipad_13" "${ipad_destination}"
fi

printf 'App Store screenshot run: %s\n' "${run_dir}"
