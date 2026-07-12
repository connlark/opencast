#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "${script_dir}/.." && pwd)"
config_file="${repo_dir}/.xcodebuildmcp/config.yaml"
artifact_root="${repo_dir}/artifacts/ipad-ui-warmup"
timestamp="$(date +%Y%m%d-%H%M%S)"
result_bundle="${artifact_root}/OpenCastIPadUIWarmup-${timestamp}.xcresult"
derived_data="${OPENCAST_WARMUP_DERIVED_DATA:-${artifact_root}/DerivedData}"

device_id="${OPENCAST_DEVICE_ID:-}"
if [[ -z "${device_id}" && -f "${config_file}" ]]; then
  device_id="$(awk -F ': *' '/deviceId:/ { print $2; exit }' "${config_file}")"
fi

if [[ -z "${device_id}" ]]; then
  printf 'Set OPENCAST_DEVICE_ID to the iPad UDID, or add deviceId to %s.\n' "${config_file}" >&2
  exit 2
fi

test_identifier="${OPENCAST_WARMUP_TEST:-OpenCastUITests/OpenCastPadUITests/testSeededPadEpisodeTapShowsDetailBehindNowPlaying}"
unlock_wait_seconds="${OPENCAST_UNLOCK_WAIT_SECONDS:-0}"

mkdir -p "${artifact_root}"

printf '\nOpenCast iPad UI test warmup\n'
printf 'Repo: %s\n' "${repo_dir}"
printf 'Device: %s\n' "${device_id}"
printf 'Test: %s\n' "${test_identifier}"
printf 'Derived data: %s\n' "${derived_data}"
printf 'Result bundle: %s\n\n' "${result_bundle}"

printf 'Preparing the UI test build first, then starting XCTest immediately.\n\n'
set -x
xcodebuild \
  -project "${repo_dir}/opencast.xcodeproj" \
  -scheme OpenCast \
  -destination "platform=iOS,id=${device_id}" \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-device-destinations 1 \
  -derivedDataPath "${derived_data}" \
  build-for-testing
set +x

products_dir="${derived_data}/Build/Products"
xctestrun_file=""
if [[ -d "${products_dir}" ]]; then
  xctestrun_file="$(
    find "${products_dir}" -maxdepth 1 -type f -name '*.xctestrun' -print |
      sort |
      tail -n 1
  )"
fi

if [[ -z "${xctestrun_file}" ]]; then
  printf 'No .xctestrun file was produced under %s.\n' "${products_dir}" >&2
  exit 3
fi

printf '\nPrepared XCTest run file: %s\n\n' "${xctestrun_file}"

if [[ "${unlock_wait_seconds}" != "0" ]]; then
  printf 'READY: unlock the iPad now. XCTest will start in %s seconds.\n' "${unlock_wait_seconds}"
  sleep "${unlock_wait_seconds}"
fi

set -x
xcodebuild \
  test-without-building \
  -xctestrun "${xctestrun_file}" \
  -destination "platform=iOS,id=${device_id}" \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-device-destinations 1 \
  -only-testing:"${test_identifier}" \
  -resultBundlePath "${result_bundle}"
