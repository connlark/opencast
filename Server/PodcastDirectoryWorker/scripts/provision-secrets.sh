#!/usr/bin/env bash
# Provisions the Podcast Index credentials for every Wrangler lane of
# the podcast directory Worker. Idempotent; secret values are read from
# single-value key files and are never printed. CI never runs this (it
# needs the private key material, which CI removes before any repo code
# executes).
set -euo pipefail
cd "$(dirname "$0")/.."

repo_root="$(git rev-parse --show-toplevel)"
KEY_FILE="${OPENCAST_PODCAST_INDEX_KEY_FILE:-$repo_root/keys/podcastindex_org}"
SECRET_FILE="${OPENCAST_PODCAST_INDEX_SECRET_FILE:-$repo_root/keys/podcastindex_org_secret}"

fail() {
  echo "FATAL: $1" >&2
  exit 1
}

[[ -f "$KEY_FILE" ]] \
  || fail "$KEY_FILE is missing (set OPENCAST_PODCAST_INDEX_KEY_FILE to your API key file)"
[[ -f "$SECRET_FILE" ]] \
  || fail "$SECRET_FILE is missing (set OPENCAST_PODCAST_INDEX_SECRET_FILE to your API secret file)"

api_key="$(<"$KEY_FILE")"
api_secret="$(<"$SECRET_FILE")"

# Shape checks: one bare value per file, nothing labeled or multi-line.
[[ "$api_key" =~ ^[A-Z0-9]{20}$ ]] \
  || fail "the key file must hold exactly one 20-character Podcast Index API key"
[[ "$api_secret" =~ ^[!-~]{30,64}$ ]] \
  || fail "the secret file must hold exactly one Podcast Index API secret"

# Live authenticated no-op: the static categories list proves the pair
# works without sending any query text.
auth_date="$(date +%s)"
auth_token="$(printf '%s%s%s' "$api_key" "$api_secret" "$auth_date" | shasum -a 1 | cut -d' ' -f1)"
status="$(curl -s -o /dev/null -w '%{http_code}' \
  -H "User-Agent: OpenCast-Directory/1 (+https://opencast.mobile)" \
  -H "X-Auth-Key: $api_key" \
  -H "X-Auth-Date: $auth_date" \
  -H "Authorization: $auth_token" \
  "https://api.podcastindex.org/api/1.0/categories/list")"
[[ "$status" == "200" ]] \
  || fail "live Podcast Index authentication check failed (HTTP $status)"
echo "Live Podcast Index authentication check passed."

put_secret() {
  local name="$1" value="$2"
  shift 2
  printf '%s' "$value" | yarn wrangler secret put "$name" "$@"
}

for lane_args in "" "--env prod-staging" "--env production"; do
  lane_label="${lane_args:-default}"
  echo "== Provisioning secrets ($lane_label)"
  # shellcheck disable=SC2086
  put_secret PODCAST_INDEX_API_KEY "$api_key" $lane_args
  # shellcheck disable=SC2086
  put_secret PODCAST_INDEX_API_SECRET "$api_secret" $lane_args
done

for lane_args in "" "--env prod-staging" "--env production"; do
  lane_label="${lane_args:-default}"
  echo "== Secrets ($lane_label; names only)"
  # shellcheck disable=SC2086
  lane_secrets="$(yarn wrangler secret list $lane_args 2>/dev/null || echo '[]')"
  for name in PODCAST_INDEX_API_KEY PODCAST_INDEX_API_SECRET; do
    if echo "$lane_secrets" | grep -q "\"$name\""; then
      echo "  $name: present"
    else
      echo "  $name: MISSING"
    fi
  done
done

cat <<'NEXT'
Next steps (deploys are deliberate, not automated here):
  yarn deploy                  # development lane
  yarn deploy:prod-staging     # flip PUBLIC_PODCAST_DIRECTORY_ENABLED first
  yarn deploy:production       # after prod-staging QA passes
NEXT
