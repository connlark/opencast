#!/bin/bash
# The Yarn 4 workspace migration (2026-08-14) left the RemoteTranscription
# provisioning scripts carrying Yarn 1 flags. CI never executes them (they
# need live Cloudflare credentials, which the lane deliberately does not
# hold), so the breakage would have surfaced only on the next real
# provisioning run. Fail fast instead: syntax-check every tracked shell
# script and enforce the workspace invariants that a Yarn 1 relapse would
# violate. notes/ is exempt from the pattern ban — historical records quote
# the old commands.
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"
self="scripts/$(basename "$0")"
status=0

# 1. Every tracked shell script must parse under its own interpreter.
while IFS= read -r -d '' script; do
  interpreter=bash
  head -n1 "$script" | grep -q zsh && interpreter=zsh
  if ! command -v "$interpreter" >/dev/null 2>&1; then
    echo "note: $interpreter unavailable; skipping syntax check for $script"
    continue
  fi
  if ! "$interpreter" -n "$script"; then
    echo "FAIL: $script does not parse under $interpreter" >&2
    status=1
  fi
done < <(git ls-files -z -- '*.sh')

# 2. Yarn 1 invocation patterns are hard errors (--cwd, --silent) or renamed
#    (--frozen-lockfile -> --immutable) under Yarn 4.
if git grep -nE 'yarn --(cwd|silent)|--frozen-lockfile' -- ':!notes' ":!$self"; then
  echo "FAIL: Yarn 1 invocation patterns found (use yarn workspace <name> …," >&2
  echo "      plain yarn wrangler …, or --immutable)" >&2
  status=1
fi

# fastlane/ is exempt from the workspace-shape checks: it never ships to the
# OSS repo, so the screenshot compositor lives outside the workspace as a
# standalone Yarn project (own pin and lockfile) to keep the shipped
# workspace byte-identical and installable in the public copy.

# 3. Exactly one lockfile inside the workspace, owned by the root.
extra_locks="$(git ls-files -- '*yarn.lock' ':!fastlane' | grep -v '^yarn.lock$' || true)"
if [[ -n "$extra_locks" ]]; then
  printf 'FAIL: child lockfiles are gone since the workspace migration:\n%s\n' \
    "$extra_locks" >&2
  status=1
fi

# 4. The root manifest owns the Yarn pin and Node floor; workspace manifests
#    must not redeclare them.
while IFS= read -r manifest; do
  [[ "$manifest" == "package.json" ]] && continue
  for key in packageManager engines; do
    if grep -q "\"$key\"" "$manifest"; then
      echo "FAIL: $manifest declares \"$key\"; the workspace root owns it" >&2
      status=1
    fi
  done
done < <(git ls-files -- '*package.json' ':!fastlane')

if [[ "$status" -eq 0 ]]; then
  echo "PASS: shell scripts parse; no Yarn 1 patterns; single root lockfile; root-owned Yarn pin and Node floor"
fi
exit "$status"
