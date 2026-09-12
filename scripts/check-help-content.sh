#!/usr/bin/env bash
# The bundled help fallback must match the website's canonical document byte
# for byte so the app never ships stale or hand-edited copy.
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_file="${repo_dir}/Server/Website/public/app/help/v1.json"
bundled_file="${repo_dir}/OpenCast/Resources/HelpContent.json"

if ! cmp -s "${source_file}" "${bundled_file}"; then
  printf 'Bundled help content differs from Server/Website/public/app/help/v1.json; run scripts/sync-help-content.sh\n' >&2
  exit 1
fi
printf 'PASS: bundled help content matches the website document\n'
