#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "${script_dir}/.." && pwd)"

ui_tests_blueprint_id="A1000000000000000000001D"
app_tests_blueprint_id="A10000000000000000000018"
status=0

check_parallelizable() {
  local scheme_path="$1"
  local blueprint_id="$2"
  local expected="$3"
  local description="$4"
  local actual

  actual="$(
    xmllint \
      --xpath "string(//TestableReference[BuildableReference/@BlueprintIdentifier='${blueprint_id}']/@parallelizable)" \
      "${scheme_path}" \
      2>/dev/null
  )"

  if [[ "${actual}" != "${expected}" ]]; then
    printf '%s: expected %s parallelizable = "%s", found "%s"\n' \
      "${scheme_path#${repo_dir}/}" \
      "${description}" \
      "${expected}" \
      "${actual:-<missing>}"
    status=1
  fi
}

check_parallelizable \
  "${repo_dir}/opencast.xcodeproj/xcshareddata/xcschemes/OpenCast.xcscheme" \
  "${app_tests_blueprint_id}" \
  "YES" \
  "OpenCastTests"

check_parallelizable \
  "${repo_dir}/opencast.xcodeproj/xcshareddata/xcschemes/OpenCast.xcscheme" \
  "${ui_tests_blueprint_id}" \
  "NO" \
  "OpenCastUITests"

check_parallelizable \
  "${repo_dir}/opencast.xcodeproj/xcshareddata/xcschemes/OpenCastAppStoreScreenshots.xcscheme" \
  "${ui_tests_blueprint_id}" \
  "NO" \
  "OpenCastUITests"

check_parallelizable \
  "${repo_dir}/opencast.xcodeproj/xcshareddata/xcschemes/OpenCastNotificationsInternal.xcscheme" \
  "${app_tests_blueprint_id}" \
  "YES" \
  "OpenCastTests"

check_parallelizable \
  "${repo_dir}/opencast.xcodeproj/xcshareddata/xcschemes/OpenCastNotificationsInternal.xcscheme" \
  "${ui_tests_blueprint_id}" \
  "NO" \
  "OpenCastUITests"

if [[ "${status}" -ne 0 ]]; then
  printf '\nXcode can rewrite autocreated test-plan scheme metadata. Re-add the missing parallelizable attribute before committing.\n'
fi

exit "${status}"
