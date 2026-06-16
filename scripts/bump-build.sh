#!/usr/bin/env bash
# Increment CURRENT_PROJECT_VERSION (the build number) across every build
# configuration in opencast.xcodeproj/project.pbxproj.
#
# Usage:
#   scripts/bump-build.sh           # bump by 1
#   scripts/bump-build.sh 42        # set explicitly to 42
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "${script_dir}/.." && pwd)
pbxproj="${repo_root}/opencast.xcodeproj/project.pbxproj"

if [[ ! -f "${pbxproj}" ]]; then
  echo "error: ${pbxproj} not found" >&2
  exit 1
fi

mapfile -t versions < <(grep -E '^[[:space:]]*CURRENT_PROJECT_VERSION = [0-9]+;' "${pbxproj}" \
  | sed -E 's/.*CURRENT_PROJECT_VERSION = ([0-9]+);.*/\1/')

if [[ ${#versions[@]} -eq 0 ]]; then
  echo "error: no CURRENT_PROJECT_VERSION entries found in ${pbxproj}" >&2
  exit 1
fi

current=${versions[0]}
for v in "${versions[@]}"; do
  if [[ "${v}" != "${current}" ]]; then
    echo "error: CURRENT_PROJECT_VERSION values are out of sync: ${versions[*]}" >&2
    echo "       fix manually before re-running this script" >&2
    exit 1
  fi
done

if [[ $# -ge 1 ]]; then
  next=$1
  if ! [[ "${next}" =~ ^[0-9]+$ ]]; then
    echo "error: explicit build number must be a non-negative integer, got: ${next}" >&2
    exit 1
  fi
else
  next=$((current + 1))
fi

# In-place edit; matches both leading-tab and leading-space indentation.
sed -i '' -E "s/^([[:space:]]*)CURRENT_PROJECT_VERSION = ${current};/\1CURRENT_PROJECT_VERSION = ${next};/" "${pbxproj}"

# Verify every occurrence was updated.
mapfile -t after < <(grep -E '^[[:space:]]*CURRENT_PROJECT_VERSION = [0-9]+;' "${pbxproj}" \
  | sed -E 's/.*CURRENT_PROJECT_VERSION = ([0-9]+);.*/\1/')

for v in "${after[@]}"; do
  if [[ "${v}" != "${next}" ]]; then
    echo "error: post-edit values not all ${next}: ${after[*]}" >&2
    exit 1
  fi
done

echo "build: ${current} -> ${next} (${#after[@]} configurations updated)"
