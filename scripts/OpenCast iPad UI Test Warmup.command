#!/usr/bin/env bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "${script_dir}/.." && pwd)"
warmup_script="${repo_dir}/scripts/run-ipad-ui-test-warmup.sh"

cd "${repo_dir}" || exit 1
"${warmup_script}"
status=$?

printf '\nOpenCast iPad UI warmup finished with status %s.\n' "${status}"
printf 'Press Return to close this window.'
read -r _
exit "${status}"
