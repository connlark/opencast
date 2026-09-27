#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "${script_dir}/../.." && pwd)
build_script="${repo_root}/scripts/bump-build.sh"
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/opencast-bump-build.XXXXXX")
trap 'rm -rf "${tmp_dir}"' EXIT
fixture="${tmp_dir}/project.pbxproj"

write_fixture() {
  printf '\t\tCURRENT_PROJECT_VERSION = %s;\n        CURRENT_PROJECT_VERSION = %s;  \n\tMARKETING_VERSION = 2026.9.3;\n' \
    "$1" "$1" > "${fixture}"
}

bump() {
  OPENCAST_PBXPROJ_PATH="${fixture}" "${BASH}" "${build_script}" "$@"
}

assert_version() {
  cp "${fixture}" "${tmp_dir}/actual"
  write_fixture "$1"
  cmp "${fixture}" "${tmp_dir}/actual"
}

assert_rejected_without_changes() {
  cp "${fixture}" "${tmp_dir}/before"
  if bump "$@" >"${tmp_dir}/error.log" 2>&1; then
    echo "error: invalid build bump should be rejected" >&2
    exit 1
  fi
  cmp "${fixture}" "${tmp_dir}/before"
}

write_fixture 279
output=$(bump)
[[ "${output}" == 'build: 279 -> 280 (2 configurations updated)' ]]
assert_version 280

bump 285 >/dev/null
assert_version 285

write_fixture 009
bump >/dev/null
assert_version 10

write_fixture 0
bump >/dev/null
assert_version 1

assert_rejected_without_changes invalid
assert_rejected_without_changes -1
assert_rejected_without_changes 2 3

printf '\tCURRENT_PROJECT_VERSION = 279;\n\tCURRENT_PROJECT_VERSION = 280;\n' > "${fixture}"
assert_rejected_without_changes

printf '\tMARKETING_VERSION = 2026.9.3;\n' > "${fixture}"
assert_rejected_without_changes

echo "bump-build self-test passed"
