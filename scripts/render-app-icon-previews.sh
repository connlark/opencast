#!/usr/bin/env bash
#
# Renders the Settings › App Icon picker previews from the Icon Composer
# documents under OpenCast/Resources (AppIcon.icon plus every
# AppIcon<Name>.icon alternate). Light and Dark renditions are exported at
# 1024 px with Icon Composer's embedded ictool, downsampled to 60 pt @2x/@3x,
# and written as committed imagesets so builds never need Icon Composer.
# Re-run after editing any icon document; the output is byte-stable.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "${script_dir}/.." && pwd)"
resources_dir="${repo_dir}/OpenCast/Resources"
previews_dir="${resources_dir}/Assets.xcassets/AppIconPreviews"
ictool="${OPENCAST_ICTOOL:-/Applications/Xcode-27.0.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool}"
master_size=1024
point_size=60

if [[ ! -x "${ictool}" ]]; then
  printf 'render-app-icon-previews: Icon Composer'"'"'s ictool was not found at %s (override with OPENCAST_ICTOOL). `xcrun ictool` is a different tool and cannot export images.\n' "${ictool}" >&2
  exit 1
fi
if ! command -v magick >/dev/null 2>&1; then
  printf 'render-app-icon-previews: ImageMagick is required (brew install imagemagick).\n' >&2
  exit 1
fi

work_dir="$(mktemp -d /private/tmp/opencast-icon-previews.XXXXXX)"
trap 'rm -rf "${work_dir}"' EXIT

render_master() {
  local document="$1" rendition="$2" output="$3"
  "${ictool}" "${document}" --export-image --output-file "${output}" \
    --platform iOS --rendition "${rendition}" \
    --width "${master_size}" --height "${master_size}" --scale 1 >/dev/null
  if [[ ! -f "${output}" ]]; then
    printf 'render-app-icon-previews: ictool produced no %s rendition for %s.\n' "${rendition}" "${document}" >&2
    exit 1
  fi
}

downsample() {
  local master="$1" scale="$2" output="$3"
  local pixels=$((point_size * scale))
  # Lanczos from the 1024 master keeps the thin inner arc legible; stripping
  # metadata and date chunks keeps reruns byte-identical.
  magick "${master}" -filter Lanczos -resize "${pixels}x${pixels}" \
    -strip -define png:exclude-chunks=date,time "PNG32:${output}"
}

write_imageset_contents() {
  local imageset="$1" name="$2"
  cat > "${imageset}/Contents.json" <<JSON
{
  "images" : [
    {
      "filename" : "AppIconPreview-${name}-light@2x.png",
      "idiom" : "universal",
      "scale" : "2x"
    },
    {
      "filename" : "AppIconPreview-${name}-light@3x.png",
      "idiom" : "universal",
      "scale" : "3x"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "dark"
        }
      ],
      "filename" : "AppIconPreview-${name}-dark@2x.png",
      "idiom" : "universal",
      "scale" : "2x"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "dark"
        }
      ],
      "filename" : "AppIconPreview-${name}-dark@3x.png",
      "idiom" : "universal",
      "scale" : "3x"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON
}

mkdir -p "${previews_dir}"
cat > "${previews_dir}/Contents.json" <<'JSON'
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

rendered=0
for document in "${resources_dir}"/AppIcon*.icon; do
  bundle="$(basename "${document}" .icon)"
  # The primary document is AppIcon; the picker calls it Ember.
  name="${bundle#AppIcon}"
  name="${name:-Ember}"
  imageset="${previews_dir}/AppIconPreview-${name}.imageset"
  mkdir -p "${imageset}"
  for appearance in light dark; do
    rendition=Default
    [[ "${appearance}" == dark ]] && rendition=Dark
    master="${work_dir}/${bundle}-${rendition}.png"
    render_master "${document}" "${rendition}" "${master}"
    for scale in 2 3; do
      downsample "${master}" "${scale}" "${imageset}/AppIconPreview-${name}-${appearance}@${scale}x.png"
    done
  done
  write_imageset_contents "${imageset}" "${name}"
  rendered=$((rendered + 1))
  printf 'rendered %s -> %s\n' "${bundle}" "${imageset#"${repo_dir}"/}"
done

if [[ "${rendered}" -eq 0 ]]; then
  printf 'render-app-icon-previews: no AppIcon*.icon documents under %s.\n' "${resources_dir}" >&2
  exit 1
fi
