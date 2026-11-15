#!/usr/bin/env bash
#
# Turns a short source sound into a bundled skip sound
# (OpenCast/Resources/SkipSounds/<id>.m4a). The recipe, in order: the first
# audio stream only, resampled to 44.1 kHz with the source's channels kept;
# leading and trailing silence trimmed where the sample peak first and last
# reaches -45 dBFS; a 10 ms linear fade at each end; one linear gain that puts
# the sound at the set's loudness; Apple AAC-LC at 128 kb/s; every metadata
# item stripped.
#
# Usage: scripts/encode-skip-sound.sh SOURCE OUTPUT.m4a [TARGET_LUFS]
#
# The loudness every sound is matched on is its maximum momentary loudness
# (EBU R128 M: ITU-R BS.1770 K-weighting over a 400 ms window, read every
# 100 ms). Integrated loudness is built from whole 400 ms gating blocks, and a
# sound this short has none or one, so it gives no stable reading. TARGET_LUFS
# defaults to -20. To relevel the set, rerun every sound with the same new
# target; never limit or clip one sound to make it fit.
#
# The encoded file is measured, not the intermediate (AAC moves peaks). The
# script fails, and writes nothing, when the encoded true peak is above
# -3 dBTP (lower the whole set's target), when its loudness misses the target
# by more than 0.3 LU, or when AVFoundation finds a metadata item in it or
# AVAudioPlayer cannot open it. Needs macOS (afconvert, swift) and ffmpeg.
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  printf 'usage: %s SOURCE OUTPUT.m4a [TARGET_LUFS]\n' "$(basename "$0")" >&2
  exit 2
fi
source_file="$1"
output_file="$2"
target="${3:--20}"
true_peak_ceiling=-3
loudness_tolerance=0.3

for tool in ffmpeg ffprobe afconvert swift shasum; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    printf 'encode-skip-sound: %s is required.\n' "${tool}" >&2
    exit 1
  fi
done
if [[ ! -f "${source_file}" ]]; then
  printf 'encode-skip-sound: no source file at %s.\n' "${source_file}" >&2
  exit 1
fi

work_dir="$(mktemp -d /private/tmp/opencast-skip-sound.XXXXXX)"
trap 'rm -rf "${work_dir}"' EXIT

quiet=(-nostdin -hide_banner -loglevel error -y)
# No tags, no chapters, and no encoder strings ("Lavf", "Lavc") in any file
# written here.
bare=(-map_metadata -1 -map_chapters -1 -fflags +bitexact -flags:a +bitexact)
# Trailing silence is trimmed by trimming the reversed sound's leading
# silence, and the fade-out is the reversed sound's fade-in, so neither needs
# the sound's length.
edge='silenceremove=start_periods=1:start_threshold=-45dB:detection=peak'
shape="aresample=44100,${edge},areverse,${edge},afade=t=in:d=0.01,areverse,afade=t=in:d=0.01"

# Prints the maximum momentary loudness (LUFS) and the true peak (dBTP). One
# second of trailing silence lets the 400 ms window close over a sound shorter
# than the window.
measure() {
  local file="$1" log="${work_dir}/measure.log" momentary_max true_peak
  momentary_max="$(ffmpeg -nostdin -hide_banner -nostats -i "${file}" -map 0:a:0 \
    -af 'apad=pad_dur=1,ebur128=metadata=1:peak=true,ametadata=mode=print:key=lavfi.r128.M:file=-' \
    -f null - 2>"${log}" \
    | awk -F= '/^lavfi\.r128\.M=/ { v = $2 + 0; if (!seen || v > max) { max = v; seen = 1 } } END { if (seen) printf "%.2f", max }')"
  true_peak="$(awk '/^ *Peak:/ { peak = $2 } END { print peak }' "${log}")"
  if [[ -z "${momentary_max}" || -z "${true_peak}" ]]; then
    printf 'encode-skip-sound: could not measure %s.\n' "${file}" >&2
    exit 1
  fi
  printf '%s %s\n' "${momentary_max}" "${true_peak}"
}

shaped="${work_dir}/shaped.wav"
ffmpeg "${quiet[@]}" -i "${source_file}" -map 0:a:0 -af "${shape}" -c:a pcm_f32le "${bare[@]}" "${shaped}"
shaped_duration="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "${shaped}")"
if ! awk -v d="${shaped_duration}" 'BEGIN { exit !(d > 0.02) }'; then
  printf 'encode-skip-sound: nothing in %s reaches -45 dBFS.\n' "${source_file}" >&2
  exit 1
fi

shaped_measure="$(measure "${shaped}")"
read -r shaped_loudness _ <<<"${shaped_measure}"
gain="$(awk -v t="${target}" -v m="${shaped_loudness}" 'BEGIN { printf "%.2f", t - m }')"

leveled="${work_dir}/leveled.wav"
ffmpeg "${quiet[@]}" -i "${shaped}" -af "volume=${gain}dB" -c:a pcm_f32le "${bare[@]}" "${leveled}"
# Apple's encoder output moves by a few bytes with the size of its process
# environment (one added variable was enough), so it runs with an empty one
# and a rerun on the same macOS reproduces the file byte for byte.
env -i afconvert "${leveled}" -o "${work_dir}/encoded.m4a" -f m4af -d aac -b 128000 -s 2 -q 127
# afconvert records the encoder delay as an iTunSMPB metadata item. The copy
# turns it into an edit list, so playback stays sample-accurate with no items.
encoded="${work_dir}/skip-sound.m4a"
ffmpeg "${quiet[@]}" -i "${work_dir}/encoded.m4a" -map 0:a:0 -c copy "${bare[@]}" "${encoded}"

encoded_measure="$(measure "${encoded}")"
read -r loudness true_peak <<<"${encoded_measure}"
if ! awk -v p="${true_peak}" -v c="${true_peak_ceiling}" 'BEGIN { exit !(p <= c) }'; then
  printf 'encode-skip-sound: true peak %s dBTP is above %s dBTP at %s LUFS; lower the whole set'"'"'s target.\n' \
    "${true_peak}" "${true_peak_ceiling}" "${target}" >&2
  exit 1
fi
if ! awk -v l="${loudness}" -v t="${target}" -v tol="${loudness_tolerance}" 'BEGIN { d = l - t; if (d < 0) d = -d; exit !(d <= tol) }'; then
  printf 'encode-skip-sound: encoded loudness %s LUFS misses the %s LUFS target.\n' "${loudness}" "${target}" >&2
  exit 1
fi

cat > "${work_dir}/check.swift" <<'SWIFT'
import AVFoundation

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let metadata = try await AVURLAsset(url: url).load(.metadata)
if !metadata.isEmpty {
    print("\(metadata.count) metadata items: \(metadata.map { $0.identifier?.rawValue ?? "?" })")
    exit(1)
}
let player = try AVAudioPlayer(contentsOf: url)
print(String(format: "%.3f %d %.0f", player.duration, player.numberOfChannels, player.format.sampleRate))
SWIFT
if ! player_report="$(swift "${work_dir}/check.swift" "${encoded}" 2>&1)"; then
  printf 'encode-skip-sound: AVFoundation check failed: %s\n' "${player_report}" >&2
  exit 1
fi
read -r duration channels sample_rate <<<"$(printf '%s\n' "${player_report}" | tail -n 1)"

mkdir -p "$(dirname "${output_file}")"
cp "${encoded}" "${output_file}"
printf '%s: %s s, %s ch, %s Hz, %s bytes; %s LUFS max momentary (gain %s dB), true peak %s dBTP; source SHA-256 %s\n' \
  "${output_file}" "${duration}" "${channels}" "${sample_rate}" "$(wc -c < "${output_file}" | tr -d ' ')" \
  "${loudness}" "${gain}" "${true_peak}" "$(shasum -a 256 "${source_file}" | awk '{ print $1 }')"
