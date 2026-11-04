#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "${script_dir}/.." && pwd)"
artifact_root="${repo_dir}/artifacts/app-store-screenshots"
timestamp="$(date +%Y%m%d-%H%M%S)"
# The caller may name the run directory (it must not exist yet), the
# DerivedData and, for a Duo run, the result bundle.
run_dir="${APP_STORE_SCREENSHOT_RUN_DIR:-${artifact_root}/${timestamp}}"
derived_data_path="${APP_STORE_SCREENSHOT_DERIVED_DATA_PATH:-}"
duo_result_bundle="${APP_STORE_SCREENSHOT_RESULT_BUNDLE_PATH:-}"
test_identifier="OpenCastUITests/AppStoreScreenshotUITests/testAppStoreScreenshotSet"

# OS-pinned: bare names are ambiguous across installed runtimes.
iphone_destination="${IPHONE_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro Max,OS=27.2}"
ipad_destination="${IPAD_DESTINATION:-platform=iOS Simulator,name=iPad Pro 13-inch (M4),OS=27.2}"
capture_ipad="${CAPTURE_IPAD:-1}"

# Duo mode (CAPTURE_DUO=outer|inner): only the iPhone Duo, at the UDID
# destination its caller passes (DUO_DESTINATION="platform=iOS Simulator,id=<udid>";
# the Fastfile's Duo mode validates the device record first). The device must
# already be booted, posed and handed over by its driver: nothing here boots,
# shuts down, erases, rotates or poses it, and the status bar is never
# overridden. The capture proves the posed display by named-display frames
# before and after the test.
capture_duo="${CAPTURE_DUO:-}"
duo_destination="${DUO_DESTINATION:-}"
# The raw names the run must export, from the caller (the Fastfile lists them
# from the compositor's spec), separated by spaces or newlines.
duo_expected_shots="${DUO_EXPECTED_SHOTS:-}"
# The Duo's device-specific runtime carries the pinned version (preflight
# reads every OS= pin in this file).
duo_os_pin="OS=27.2"

if [[ -n "${duo_destination}" && -z "${capture_duo}" ]]; then
  printf 'DUO_DESTINATION names a Duo destination; a Duo capture needs CAPTURE_DUO=outer|inner.\n' >&2
  exit 64
fi

if [[ -e "${run_dir}" ]]; then
  printf 'Run directory %s already exists; each capture writes a fresh one.\n' "${run_dir}" >&2
  exit 64
fi
mkdir -p "${run_dir}"

derived_data_arguments=()
if [[ -n "${derived_data_path}" ]]; then
  derived_data_arguments=(-derivedDataPath "${derived_data_path}")
fi

run_capture() {
  local label="$1"
  local destination="$2"
  local result_bundle="${3:-${run_dir}/${label}.xcresult}"
  local attachments_dir="${run_dir}/${label}-attachments"
  local screenshots_dir="${run_dir}/${label}-screenshots"

  if [[ -e "${result_bundle}" ]]; then
    printf 'Result bundle %s already exists; each capture writes a fresh one.\n' "${result_bundle}" >&2
    exit 64
  fi

  # The shared OpenCast scheme skips the screenshot test (a scheme skip wins
  # over -only-testing); the dedicated screenshot scheme runs it.
  xcodebuild \
    -project "${repo_dir}/opencast.xcodeproj" \
    -scheme OpenCastAppStoreScreenshots \
    -destination "${destination}" \
    -only-testing:"${test_identifier}" \
    -parallel-testing-enabled NO \
    ${derived_data_arguments[@]+"${derived_data_arguments[@]}"} \
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
    # A Duo capture is its exports; without them the run failed.
    if [[ -n "${capture_duo}" ]]; then
      return 1
    fi
  fi
}

# One named-display frame: its path, then "<width> <height> <RGB maximum>".
# Runs inside a command substitution, where errexit does not apply, so each
# step's failure is returned explicitly and no earlier frame is ever re-read.
display_frame() {
  local udid="$1" display="$2" path="$3"
  rm -f "${path}"
  xcrun simctl io "${udid}" screenshot "--display=${display}" "${path}" >/dev/null || return 1
  magick identify -format '%w %h %[fx:max(maxima.r,max(maxima.g,maxima.b))]' "${path}" || return 1
}

# The inner display's frames are taken here, not by the test: XCTest's screen
# for the inner display is portrait and one pixel short of it (2006x2852). The
# test drives the UI and, at each frame it needs, writes
# "<NNNN>-<shot|probe>-<name>.request" into the cue directory (once; it keeps
# the files), then waits for "<base>.done" ("<width> <height> <RGB maximum>
# <sha256>") or "<base>.failed" (the reason). This loop answers each request
# with a named-display frame of LCD-1, checked at the display's native size
# and nonblack; a shot name asked for twice is refused. It ends when the test
# job ends; a failure it writes also fails the run.
# The inner run's processes: the test job and the frame worker in flight,
# each in its own process group; cleanup ends both groups and reaps them.
capture_job=""
frame_worker=""
end_inner_processes() {
  if [[ -n "${frame_worker}" ]]; then
    kill -TERM -- "-${frame_worker}" 2>/dev/null || true
    wait "${frame_worker}" 2>/dev/null || true
    frame_worker=""
  fi
  if [[ -n "${capture_job}" ]]; then
    kill -TERM -- "-${capture_job}" 2>/dev/null || true
    wait "${capture_job}" 2>/dev/null || true
  fi
}

# One LCD-1 frame under a host-side deadline (seconds): the reading in
# reading_file, or a failure after the worker's group is ended. A hung
# screenshot never holds the watcher past the deadline, so it always answers
# before the test's bound.
timed_display_frame() {
  local udid="$1" out="$2" deadline="$3" reading_file="$4"
  local started now status
  set -m
  display_frame "${udid}" LCD-1 "${out}" > "${reading_file}" 2>/dev/null &
  frame_worker=$!
  set +m
  started="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
  while kill -0 "${frame_worker}" 2>/dev/null; do
    now="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
    if awk -v now="${now}" -v started="${started}" -v deadline="${deadline}" 'BEGIN { exit !(now - started > deadline) }'; then
      kill -TERM -- "-${frame_worker}" 2>/dev/null || true
      wait "${frame_worker}" 2>/dev/null || true
      frame_worker=""
      return 2
    fi
    sleep 0.1
  done
  status=0
  wait "${frame_worker}" || status=$?
  frame_worker=""
  return "${status}"
}

serve_cues() {
  local udid="$1" job="$2" cue_dir="$3" shots_dir="$4" proof_dir="$5" expected="$6" deadline="$7"
  local request base kind name out reading width height maximum digest reason taken frame_status
  while :; do
    for request in "${cue_dir}"/*.request; do
      [[ -e "${request}" ]] || continue
      base="$(basename "${request}" .request)"
      [[ -e "${cue_dir}/${base}.done" || -e "${cue_dir}/${base}.failed" ]] && continue
      kind="$(cut -d- -f2 <<< "${base}")"
      name="${base#*-*-}"
      reason=""
      taken=0
      case "${kind}" in
        shot) out="${shots_dir}/${name}.png" ;;
        probe) out="${proof_dir}/${base}.png" ;;
        *) out=""; reason="unknown cue kind ${kind}" ;;
      esac
      if [[ -z "${reason}" && "${kind}" == shot && -e "${out}" ]]; then
        reason="shot ${name} was already taken"
      fi
      if [[ -z "${reason}" ]]; then
        taken=1
        frame_status=0
        timed_display_frame "${udid}" "${out}" "${deadline}" "${cue_dir}/${base}.reading" || frame_status=$?
        if [[ "${frame_status}" == 0 ]]; then
          reading="$(cat "${cue_dir}/${base}.reading")"
          read -r width height maximum <<< "${reading}"
          if [[ "${width}x${height}" != "${expected}" ]]; then
            reason="LCD-1 is ${width}x${height}, not ${expected}"
          elif ! awk -v value="${maximum}" 'BEGIN { exit !(value > 0) }'; then
            reason="LCD-1 is black (RGB maximum ${maximum})"
          fi
        elif [[ "${frame_status}" == 2 ]]; then
          reason="the LCD-1 frame took longer than ${deadline} s"
        else
          reason="the LCD-1 frame could not be saved or read"
        fi
      fi
      if [[ -z "${reason}" ]]; then
        digest="$(shasum -a 256 "${out}" | cut -c1-64)"
        printf '%s %s %s %s\n' "${width}" "${height}" "${maximum}" "${digest}" > "${cue_dir}/${base}.answer"
        mv "${cue_dir}/${base}.answer" "${cue_dir}/${base}.done"
      else
        # A refused frame never stands under its shot name.
        if [[ "${taken}" == 1 && -e "${out}" ]]; then
          mv "${out}" "${out%.png}.refused-${base%%-*}.png"
        fi
        printf '%s\n' "${reason}" > "${cue_dir}/${base}.answer"
        mv "${cue_dir}/${base}.answer" "${cue_dir}/${base}.failed"
        printf '%s %s\n' "${base}" "${reason}" >> "${cue_dir}/watcher-failures"
      fi
      printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${base}" \
        "xcrun simctl io ${udid} screenshot --display=LCD-1 ${out:-<none>}" "${reason:-${width}x${height} rgb-max ${maximum} sha256 ${digest}}" \
        >> "${cue_dir}/cues.tsv"
    done
    kill -0 "${job}" 2>/dev/null || break
    sleep 0.2
  done
}

# The exported raws of a Duo run: exactly the family's names the caller
# expects (DUO_EXPECTED_SHOTS), each at the display's native size and not
# black.
validate_duo_raws() {
  local family="$1" expected_size="$2" screenshots_dir="$3"
  local names name path reading width height maximum
  names="$(tr ' ' '\n' <<< "${duo_expected_shots}" | grep .)" || {
    printf 'No expected %s shots were named (DUO_EXPECTED_SHOTS).\n' "${family}" >&2
    return 1
  }
  for path in "${screenshots_dir}"/app_store_[0-9][0-9]_"${family}"_*.png; do
    [[ -e "${path}" ]] || continue
    name="$(basename "${path}" .png)"
    if ! grep -Fxq "${name}" <<< "${names}"; then
      printf 'This run exported %s, which is not an expected %s name.\n' "${name}" "${family}" >&2
      return 1
    fi
  done
  while IFS= read -r name; do
    path="${screenshots_dir}/${name}.png"
    if [[ ! -f "${path}" ]]; then
      printf 'This run exported no %s.\n' "${name}" >&2
      return 1
    fi
    reading="$(magick identify -format '%w %h %[fx:max(maxima.r,max(maxima.g,maxima.b))]' "${path}")" || return 1
    read -r width height maximum <<< "${reading}"
    if [[ "${width}x${height}" != "${expected_size}" ]] || ! awk -v value="${maximum}" 'BEGIN { exit !(value > 0) }'; then
      printf '%s is %sx%s with rgb-max %s; %s needs %s and nonblack.\n' "${name}" "${width}" "${height}" "${maximum}" "${family}" "${expected_size}" >&2
      return 1
    fi
  done <<< "${names}"
  printf 'raws (%s): %s files, each %s and nonblack\n' "${family}" "$(grep -c . <<< "${names}")" "${expected_size}"
}

# The pinned Duo, read from its one record in docs/build.md (the private pin
# source; this script ships without a device UDID): the line after "- iPhone
# Duo smoke device" holds `<UDID>` (<name>).
duo_pinned_record() {
  local build_doc="${repo_dir}/docs/build.md"
  [[ -f "${build_doc}" ]] || return 1
  sed -n '/^- iPhone Duo smoke device/{n;p;}' "${build_doc}" \
    | sed -nE 's/^  `([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})` \((.+)\)\.$/\1|\2/p'
}

# The destination's device record: the pinned UDID under the pinned name and
# no other record with that name, the Duo device type, the Duo's
# device-specific runtime at the pinned version, available, and already booted
# (a test command would boot it otherwise).
validate_duo_device() {
  local udid="$1" pinned_udid="$2" pinned_name="$3"
  local version="${duo_os_pin#OS=}"
  local runtime="com.apple.CoreSimulator.SimRuntime.iOS-${version//./-}-iPhone19-4"
  local expected actual runtime_version
  if [[ "${udid}" != "${pinned_udid}" ]]; then
    printf 'DUO_DESTINATION names %s; the pinned iPhone Duo (docs/build.md) is %s.\n' "${udid}" "${pinned_udid}" >&2
    return 1
  fi
  expected="${pinned_udid}|${pinned_name}|com.apple.CoreSimulator.SimDeviceType.iPhone-Duo|${runtime}|true|Booted"
  actual="$(xcrun simctl list devices -j | ruby -rjson -e '
    udid, name = ARGV
    records = JSON.parse(STDIN.read).fetch("devices").flat_map do |runtime, devices|
      devices.select { |device| device["udid"] == udid || device["name"] == name }.map { |device| device.merge("runtime" => runtime) }
    end
    print records.map { |r| [r["udid"], r["name"], r["deviceTypeIdentifier"], r["runtime"], r["isAvailable"], r["state"]].join("|") }.join(";")
  ' "${udid}" "${pinned_name}")" || return 1
  runtime_version="$(xcrun simctl list runtimes -j | ruby -rjson -e '
    runtime = JSON.parse(STDIN.read).fetch("runtimes").find { |r| r["identifier"] == ARGV.fetch(0) && r["isAvailable"] }
    print(runtime ? runtime["version"] : "")
  ' "${runtime}")" || return 1
  if [[ "${actual}" != "${expected}" || "${runtime_version}" != "${version}" ]]; then
    printf 'Duo device %s is %s on a runtime at version %s; expected %s at %s. The capture never boots, creates or substitutes a device.\n' \
      "${udid}" "${actual:-<no record>}" "${runtime_version:-<none>}" "${expected}" "${version}" >&2
    return 1
  fi
  printf 'Duo device %s: %s\n' "${udid}" "${actual}"
}

# Proves the handed-over display before (and again after) the test: the named
# display's frame at its native pixel size and not black. An all-black
# framebuffer can last minutes after a boot, so a black frame is polled at
# 5 s intervals, at most 60 times; a frame of the wrong size fails at once
# (the wrong pose or display). The first and last frames are kept.
prove_display() {
  local udid="$1" display="$2" expected="$3" phase="$4"
  local proof_dir="${run_dir}/display-proof"
  local log="${proof_dir}/${phase}.log"
  local first="${proof_dir}/${phase}-first.png"
  local frame="${proof_dir}/${phase}-poll.png"
  local attempt reading width height maximum
  local started=""

  mkdir -p "${proof_dir}"
  for attempt in $(seq 1 60); do
    if [[ "${capture_duo}" == inner ]]; then
      started="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
    fi
    if ! reading="$(display_frame "${udid}" "${display}" "${frame}")"; then
      printf 'DISPLAY PROOF FAILED (%s): the display %s frame could not be saved or read.\n' "${phase}" "${display}" | tee -a "${log}" >&2
      return 1
    fi
    read -r width height maximum <<< "${reading}"
    printf '%s attempt %s display %s: %sx%s rgb-max %s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${attempt}" "${display}" "${width}" "${height}" "${maximum}" >> "${log}"
    if [[ "${attempt}" == 1 ]]; then
      cp "${frame}" "${first}"
      if [[ "${capture_duo}" == inner ]]; then
        # The first frame's save-and-read latency, in seconds (the cue bound).
        perl -MTime::HiRes=time -e 'printf "%.3f\n", time - $ARGV[0]' "${started}" > "${proof_dir}/${phase}.latency"
      fi
    fi
    if [[ "${width}x${height}" != "${expected}" ]]; then
      mv "${frame}" "${proof_dir}/${phase}-last.png"
      printf 'DISPLAY PROOF FAILED (%s): display %s is %sx%s; the posed display gives %s.\n' \
        "${phase}" "${display}" "${width}" "${height}" "${expected}" | tee -a "${log}" >&2
      return 1
    fi
    if awk -v value="${maximum}" 'BEGIN { exit !(value > 0) }'; then
      mv "${frame}" "${proof_dir}/${phase}-last.png"
      printf 'display proof (%s): display %s %sx%s, rgb-max %s, after %s frame(s)\n' \
        "${phase}" "${display}" "${width}" "${height}" "${maximum}" "${attempt}" | tee -a "${log}"
      return 0
    fi
    sleep 5
  done
  mv "${frame}" "${proof_dir}/${phase}-last.png"
  printf 'DISPLAY PROOF FAILED (%s): display %s stayed black for 60 frames.\n' "${phase}" "${display}" | tee -a "${log}" >&2
  return 1
}

if [[ -n "${capture_duo}" ]]; then
  case "${capture_duo}" in
    outer)
      duo_display="LCD"
      duo_size="1398x2034"
      duo_family="duoOuter"
      ;;
    inner)
      duo_display="LCD-1"
      duo_size="2853x2007"
      duo_family="duoInner"
      ;;
    *)
      printf 'CAPTURE_DUO must be outer or inner, not %s.\n' "${capture_duo}" >&2
      exit 64
      ;;
  esac
  duo_udid_pattern='^platform=iOS Simulator,id=([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})$'
  if [[ ! "${duo_destination}" =~ ${duo_udid_pattern} ]]; then
    printf 'A Duo capture needs DUO_DESTINATION="platform=iOS Simulator,id=<udid>", not %s.\n' "${duo_destination:-<unset>}" >&2
    exit 64
  fi
  duo_udid="${BASH_REMATCH[1]}"
  if ! duo_pin="$(duo_pinned_record)" || [[ -z "${duo_pin}" ]]; then
    printf 'A Duo capture needs the pinned iPhone Duo record in docs/build.md.\n' >&2
    exit 64
  fi
  if [[ -z "$(tr -d ' \n' <<< "${duo_expected_shots}")" ]]; then
    printf 'A Duo capture needs DUO_EXPECTED_SHOTS, the raw names it must export.\n' >&2
    exit 64
  fi

  validate_duo_device "${duo_udid}" "${duo_pin%%|*}" "${duo_pin#*|}"
  prove_display "${duo_udid}" "${duo_display}" "${duo_size}" before
  # xcodebuild hands TEST_RUNNER_-prefixed variables to the test runner.
  export TEST_RUNNER_OPENCAST_SCREENSHOT_FAMILY="${duo_family}"
  if [[ "${capture_duo}" == inner ]]; then
    cue_dir="${run_dir}/cues"
    mkdir -p "${cue_dir}" "${run_dir}/duo_inner-screenshots"
    export TEST_RUNNER_OPENCAST_SCREENSHOT_CUE_DIR="${cue_dir}"
    # The test's wait for each answer: this loop's 0.2 s poll plus the frame
    # latency the display proof just measured, times ten, in whole seconds.
    # The host's own deadline per frame is that latency times ten, 2 s inside
    # the test's wait, so the host answers first even when a frame hangs.
    frame_latency="$(cat "${run_dir}/display-proof/before.latency")"
    export TEST_RUNNER_OPENCAST_SCREENSHOT_CUE_BOUND_SECONDS="$(awk -v latency="${frame_latency}" \
      'BEGIN { bound = (0.2 + latency) * 10; printf "%d", (bound == int(bound)) ? bound : int(bound) + 1 }')"
    frame_deadline="$(awk -v latency="${frame_latency}" 'BEGIN { printf "%.3f", latency * 10 }')"
    printf 'cue bound: %s s (poll 0.2 s + measured frame latency %s s, times 10); host frame deadline %s s\n' \
      "${TEST_RUNNER_OPENCAST_SCREENSHOT_CUE_BOUND_SECONDS}" "${frame_latency}" "${frame_deadline}" | tee "${cue_dir}/bound.txt"
    # The test job runs in its own process group (job control on for the
    # launch only), so cleanup can end it with every process it started.
    set -m
    run_capture "duo_inner" "${duo_destination}" "${duo_result_bundle:-${run_dir}/duo_inner.xcresult}" &
    capture_job=$!
    set +m
    # Nothing the inner run started outlives this script, however it ends.
    trap end_inner_processes EXIT
    trap 'exit 143' TERM HUP
    trap 'exit 130' INT
    serve_cues "${duo_udid}" "${capture_job}" "${cue_dir}" "${run_dir}/duo_inner-screenshots" "${run_dir}/display-proof" \
      "${duo_size}" "${frame_deadline}"
    set +e
    wait "${capture_job}"
    capture_status=$?
    set -e
    capture_job=""
    trap - EXIT TERM HUP INT
    if [[ "${capture_status}" != 0 ]]; then
      exit "${capture_status}"
    fi
    if [[ -s "${cue_dir}/watcher-failures" ]]; then
      printf 'The cue watcher refused frames:\n' >&2
      cat "${cue_dir}/watcher-failures" >&2
      exit 1
    fi
  else
    run_capture "duo_${capture_duo}" "${duo_destination}" "${duo_result_bundle:-${run_dir}/duo_${capture_duo}.xcresult}"
  fi
  validate_duo_raws "${duo_family}" "${duo_size}" "${run_dir}/duo_${capture_duo}-screenshots"
  prove_display "${duo_udid}" "${duo_display}" "${duo_size}" after
  printf 'App Store screenshot run: %s\n' "${run_dir}"
  exit 0
fi

if [[ -n "${duo_result_bundle}" ]]; then
  printf 'APP_STORE_SCREENSHOT_RESULT_BUNDLE_PATH names one bundle and applies only to a Duo capture.\n' >&2
  exit 64
fi

run_capture "iphone_6_9" "${iphone_destination}"

if [[ "${capture_ipad}" == "1" ]]; then
  run_capture "ipad_13" "${ipad_destination}"
fi

printf 'App Store screenshot run: %s\n' "${run_dir}"
