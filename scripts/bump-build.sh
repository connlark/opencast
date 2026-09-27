#!/usr/bin/env bash
# Increment CURRENT_PROJECT_VERSION (the build number) across every build
# configuration in opencast.xcodeproj/project.pbxproj.
#
# Usage:
#   scripts/bump-build.sh           # bump by 1
#   scripts/bump-build.sh 42        # set explicitly to 42
set -euo pipefail

if [[ $# -gt 1 ]]; then
  echo "usage: scripts/bump-build.sh [build-number]" >&2
  exit 64
fi

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "${script_dir}/.." && pwd)
pbxproj=${OPENCAST_PBXPROJ_PATH:-"${repo_root}/opencast.xcodeproj/project.pbxproj"}

if [[ ! -f "${pbxproj}" ]]; then
  echo "error: ${pbxproj} not found" >&2
  exit 1
fi

versions=()
while IFS= read -r version; do
  versions+=("${version}")
done < <(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION = ([0-9]+);[[:space:]]*$/\1/p' "${pbxproj}")

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
  next=$((10#${current} + 1))
fi

# Stage and verify the edit before replacing the project. Avoid sed -i, whose
# arguments differ between BSD sed and GNU sed (including Homebrew's version).
temporary=$(mktemp "${pbxproj}.XXXXXX")
trap 'rm -f "${temporary}"' EXIT
cp -p "${pbxproj}" "${temporary}"
sed -E "s/^([[:space:]]*)CURRENT_PROJECT_VERSION = ${current};/\1CURRENT_PROJECT_VERSION = ${next};/" "${pbxproj}" > "${temporary}"

# Verify every occurrence was updated.
after=()
while IFS= read -r version; do
  after+=("${version}")
done < <(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION = ([0-9]+);[[:space:]]*$/\1/p' "${temporary}")

if [[ ${#after[@]} -ne ${#versions[@]} ]]; then
  echo "error: CURRENT_PROJECT_VERSION entry count changed during edit" >&2
  exit 1
fi

for v in "${after[@]}"; do
  if [[ "${v}" != "${next}" ]]; then
    echo "error: post-edit values not all ${next}: ${after[*]}" >&2
    exit 1
  fi
done

mv "${temporary}" "${pbxproj}"
echo "build: ${current} -> ${next} (${#after[@]} configurations updated)"
