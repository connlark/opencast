#!/usr/bin/env bash
# Advance OpenCast's year.month.build marketing version across every Xcode
# build configuration. This does not change CURRENT_PROJECT_VERSION.
#
# Usage:
#   scripts/bump-version.sh build  # 2026.7.1 -> 2026.7.2
#   scripts/bump-version.sh month  # 2026.7.2 -> 2026.8.1
#   scripts/bump-version.sh year   # 2026.8.1 -> 2027.1.1
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: scripts/bump-version.sh {build|month|year}

  build  Increment the third component.
  month  Increment the month and reset build to 1. December rolls into January.
  year   Increment the year and reset month and build to 1.

This changes MARKETING_VERSION only. Use scripts/bump-build.sh to increment
the internal App Store/TestFlight build number (CURRENT_PROJECT_VERSION).
EOF
}

if [[ $# -ne 1 ]]; then
  usage
  exit 64
fi

component=$1
case "${component}" in
  build|month|year) ;;
  *)
    echo "error: unknown version component: ${component}" >&2
    usage
    exit 64
    ;;
esac

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "${script_dir}/.." && pwd)
pbxproj=${OPENCAST_PBXPROJ_PATH:-"${repo_root}/opencast.xcodeproj/project.pbxproj"}

if [[ ! -f "${pbxproj}" ]]; then
  echo "error: ${pbxproj} not found" >&2
  exit 1
fi

versions=$(sed -nE 's/^[[:space:]]*MARKETING_VERSION = ([^;]+);[[:space:]]*$/\1/p' "${pbxproj}")
if [[ -z "${versions}" ]]; then
  echo "error: no MARKETING_VERSION entries found in ${pbxproj}" >&2
  exit 1
fi

unique_versions=$(printf '%s\n' "${versions}" | sort -u)
unique_count=$(printf '%s\n' "${unique_versions}" | wc -l | tr -d '[:space:]')
if [[ "${unique_count}" -ne 1 ]]; then
  echo "error: MARKETING_VERSION values are out of sync:" >&2
  printf '       %s\n' ${unique_versions} >&2
  echo "       fix them manually before re-running this script" >&2
  exit 1
fi

current=${unique_versions}
if [[ ! "${current}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "error: expected MARKETING_VERSION in year.month.build form, got: ${current}" >&2
  exit 1
fi

year=$((10#${BASH_REMATCH[1]}))
month=$((10#${BASH_REMATCH[2]}))
build=$((10#${BASH_REMATCH[3]}))

if (( year < 1 || month < 1 || month > 12 || build < 1 )); then
  echo "error: invalid year.month.build MARKETING_VERSION: ${current}" >&2
  exit 1
fi

case "${component}" in
  build)
    build=$((build + 1))
    ;;
  month)
    build=1
    if (( month == 12 )); then
      year=$((year + 1))
      month=1
    else
      month=$((month + 1))
    fi
    ;;
  year)
    year=$((year + 1))
    month=1
    build=1
    ;;
esac

next="${year}.${month}.${build}"
entry_count=$(printf '%s\n' "${versions}" | wc -l | tr -d '[:space:]')

# macOS sed syntax; matches both leading-tab and leading-space indentation.
sed -i '' -E \
  "s/^([[:space:]]*)MARKETING_VERSION = ${current};/\\1MARKETING_VERSION = ${next};/" \
  "${pbxproj}"

after=$(sed -nE 's/^[[:space:]]*MARKETING_VERSION = ([^;]+);[[:space:]]*$/\1/p' "${pbxproj}")
after_count=$(printf '%s\n' "${after}" | wc -l | tr -d '[:space:]')
if [[ "${after_count}" -ne "${entry_count}" ]] || printf '%s\n' "${after}" | grep -Fvxq "${next}"; then
  echo "error: post-edit MARKETING_VERSION values are not all ${next}" >&2
  exit 1
fi

echo "marketing version: ${current} -> ${next} (${entry_count} configurations updated)"
