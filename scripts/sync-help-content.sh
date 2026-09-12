#!/usr/bin/env bash
# Mirrors the website's canonical help document into the app bundle fallback.
# Run after editing Server/Website/public/app/help/v1.json; preflight fails
# while the two files differ.
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_file="${repo_dir}/Server/Website/public/app/help/v1.json"
bundled_file="${repo_dir}/OpenCast/Resources/HelpContent.json"

cp "${source_file}" "${bundled_file}"
printf 'Synced %s -> %s\n' "${source_file#"${repo_dir}/"}" "${bundled_file#"${repo_dir}/"}"
