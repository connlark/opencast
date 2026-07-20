#!/usr/bin/env bash
# Idempotent development-lane provisioning for a self-hosted deployment.
# Creates or verifies: D1 database, private R2 bucket + lifecycle rules, D1
# migrations, secrets presence, and dry-run deploys for both workers. Fails
# on unexpected existing resources rather than adopting them. Container image
# build/push goes through Podman (scripts/podman-docker-shim.sh); deploys are
# separate, explicit steps printed at the end.
set -euo pipefail
cd "$(dirname "$0")/.."

DB_NAME="your-remote-transcription-db"
BUCKET="your-remote-transcription-audio"
MEDIA_DIR="../TranscriptionMediaWorker"

echo "== D1: $DB_NAME"
if ! yarn --silent wrangler d1 info "$DB_NAME" >/dev/null 2>&1; then
  yarn --silent wrangler d1 create "$DB_NAME"
fi
DB_ID=$(yarn --silent wrangler d1 info "$DB_NAME" --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["uuid"])')
if ! grep -q "database_id = \"$DB_ID\"" wrangler.toml; then
  echo "FATAL: wrangler.toml database_id does not match the live database ($DB_ID)." >&2
  echo "Refusing to adopt an unexpected database; update wrangler.toml deliberately." >&2
  exit 1
fi

echo "== R2: $BUCKET"
if ! yarn --silent wrangler r2 bucket info "$BUCKET" >/dev/null 2>&1; then
  yarn --silent wrangler r2 bucket create "$BUCKET"
elif ! yarn --silent wrangler r2 bucket lifecycle list "$BUCKET" 2>/dev/null | grep -q "scratch-raw-one-day"; then
  echo "FATAL: bucket $BUCKET exists but lacks our lifecycle rules." >&2
  echo "Refusing to adopt an unexpected bucket." >&2
  exit 1
fi
yarn --silent wrangler r2 bucket lifecycle set "$BUCKET" --file r2-lifecycle.json --force

echo "== R2: verifying no public dev-url"
if ! yarn --silent wrangler r2 bucket dev-url get "$BUCKET" 2>/dev/null | grep -q "disabled"; then
  echo "FATAL: bucket $BUCKET has a public r2.dev endpoint; disable it." >&2
  exit 1
fi

echo "== D1 migrations"
yarn --silent wrangler d1 migrations apply "$DB_NAME" --remote

echo "== Secrets (names only; set any missing with 'yarn wrangler secret put <NAME>')"
for name in DEV_BEARER_TOKEN URL_ENCRYPTION_KEY; do
  if yarn --silent wrangler secret list 2>/dev/null | grep -q "\"$name\""; then
    echo "  $name: present"
  else
    echo "  $name: MISSING"
  fi
done
echo "  (Optional exact-upload probe: set scoped R2_S3_ACCESS_KEY_ID / R2_S3_SECRET_ACCESS_KEY secrets.)"

echo "== Dry runs"
yarn --silent wrangler deploy --dry-run --outdir dist >/dev/null && echo "  gateway dry-run OK"
(cd "$MEDIA_DIR" && yarn --silent wrangler deploy --dry-run --outdir dist >/dev/null && echo "  media dry-run OK")

cat <<'NEXT'
== Provisioned. Deploy order (explicit, not automated here):
  1. cd ../TranscriptionMediaWorker
     podman build --no-cache --format=docker --platform=linux/amd64 \
       -t registry.cloudflare.com/REPLACE_WITH_ACCOUNT_HASH/your-transcription-media-container:REPLACE_WITH_TAG container
     PATH=<shim on PATH> yarn wrangler containers push registry.cloudflare.com/REPLACE_WITH_ACCOUNT_HASH/your-transcription-media-container:REPLACE_WITH_TAG
     # bump the image tag in wrangler.jsonc, then:
     yarn wrangler deploy
  2. cd ../RemoteTranscriptionWorker && yarn wrangler deploy
NEXT
