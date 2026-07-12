#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "${script_dir}/../.." && pwd)
version_script="${repo_root}/scripts/bump-version.sh"
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/opencast-bump-version.XXXXXX")
trap 'rm -rf "${tmp_dir}"' EXIT
fixture="${tmp_dir}/project.pbxproj"

write_fixture() {
  local version=$1
  printf '\t\tMARKETING_VERSION = %s;\n        MARKETING_VERSION = %s;\n' \
    "${version}" "${version}" > "${fixture}"
}

assert_version() {
  local expected=$1
  local actual
  actual=$(sed -nE 's/^[[:space:]]*MARKETING_VERSION = ([^;]+);/\1/p' "${fixture}" | sort -u)
  if [[ "${actual}" != "${expected}" ]]; then
    echo "error: expected ${expected}, got ${actual}" >&2
    exit 1
  fi
}

write_fixture 2026.7.1
OPENCAST_PBXPROJ_PATH="${fixture}" "${version_script}" build >/dev/null
assert_version 2026.7.2

OPENCAST_PBXPROJ_PATH="${fixture}" "${version_script}" month >/dev/null
assert_version 2026.8.1

OPENCAST_PBXPROJ_PATH="${fixture}" "${version_script}" year >/dev/null
assert_version 2027.1.1

write_fixture 2026.12.4
OPENCAST_PBXPROJ_PATH="${fixture}" "${version_script}" month >/dev/null
assert_version 2027.1.1

printf '\tMARKETING_VERSION = 2026.7.1;\n\tMARKETING_VERSION = 2026.7.2;\n' > "${fixture}"
if OPENCAST_PBXPROJ_PATH="${fixture}" "${version_script}" build >/dev/null 2>&1; then
  echo "error: out-of-sync versions should be rejected" >&2
  exit 1
fi

echo "bump-version self-test passed"
