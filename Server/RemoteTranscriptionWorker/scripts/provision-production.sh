#!/usr/bin/env bash
# Idempotent production provisioning/readback for a self-hosted deployment.
# Creates or verifies
# isolated gateway + purchase D1 databases and the private R2 bucket, applies
# migrations/lifecycle rules, prints a secret-name-only scoreboard, and runs
# all three deployment dry-runs. Customer flags remain off in wrangler.toml.
set -euo pipefail
cd "$(dirname "$0")/.."

GW_DB_NAME="your-remote-transcription-db-production"
PW_DB_NAME="your-purchase-db-production"
BUCKET="your-remote-transcription-audio-production"
PURCHASE_DIR="../PurchaseWorker"
MEDIA_DIR="../TranscriptionMediaWorker"

echo "== Production configuration posture"
grep -q 'PUBLIC_REMOTE_TRANSCRIPTION_ENABLED = "false"' wrangler.toml
grep -q 'PURCHASES_ENABLED = "false"' wrangler.toml
grep -q 'pattern = "remote-transcription.example.com"' wrangler.toml
grep -q 'custom_domain = true' wrangler.toml
grep -q 'workers_dev = false' "$PURCHASE_DIR/wrangler.toml"
grep -q '"workers_dev": false' "$MEDIA_DIR/wrangler.production.jsonc"
echo "  both flags off; custom domain present; private workers have workers.dev disabled"

echo "== D1 (gateway): $GW_DB_NAME"
if ! yarn wrangler d1 info "$GW_DB_NAME" >/dev/null 2>&1; then
  yarn wrangler d1 create "$GW_DB_NAME"
fi
GW_DB_ID=$(yarn wrangler d1 info "$GW_DB_NAME" --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["uuid"])')
if ! grep -q "database_id = \"$GW_DB_ID\"" wrangler.toml; then
  echo "FATAL: production gateway D1 id is $GW_DB_ID but wrangler.toml differs." >&2
  echo "Patch the production database_id deliberately, then rerun." >&2
  exit 1
fi

echo "== D1 (purchase): $PW_DB_NAME"
if ! (cd "$PURCHASE_DIR" && yarn wrangler d1 info "$PW_DB_NAME" >/dev/null 2>&1); then
  (cd "$PURCHASE_DIR" && yarn wrangler d1 create "$PW_DB_NAME")
fi
PW_DB_ID=$(cd "$PURCHASE_DIR" && yarn wrangler d1 info "$PW_DB_NAME" --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["uuid"])')
if ! grep -q "database_id = \"$PW_DB_ID\"" "$PURCHASE_DIR/wrangler.toml"; then
  echo "FATAL: production PurchaseWorker D1 id is $PW_DB_ID but wrangler.toml differs." >&2
  echo "Patch the production database_id deliberately, then rerun." >&2
  exit 1
fi

echo "== R2: $BUCKET"
if ! yarn wrangler r2 bucket info "$BUCKET" >/dev/null 2>&1; then
  yarn wrangler r2 bucket create "$BUCKET"
elif ! yarn wrangler r2 bucket lifecycle list "$BUCKET" 2>/dev/null | grep -q "scratch-raw-one-day"; then
  echo "FATAL: existing bucket lacks OpenCast lifecycle rules; refusing adoption." >&2
  exit 1
fi
yarn wrangler r2 bucket lifecycle set "$BUCKET" --file r2-lifecycle.json --force
LIFECYCLE=$(yarn wrangler r2 bucket lifecycle list "$BUCKET" 2>/dev/null)
for rule in scratch-raw-one-day scratch-uploads-one-day scratch-chunks-one-day scratch-responses-one-day results-seven-days abort-multipart-one-day; do
  if ! echo "$LIFECYCLE" | grep -q "$rule"; then
    echo "FATAL: lifecycle rule $rule missing after apply." >&2
    exit 1
  fi
done
echo "  exact six named lifecycle rules present"

echo "== R2: verifying no public r2.dev URL"
if ! yarn wrangler r2 bucket dev-url get "$BUCKET" 2>/dev/null | grep -q "disabled"; then
  echo "FATAL: bucket has a public r2.dev endpoint; disable it." >&2
  exit 1
fi
echo "  private"

echo "== D1 migrations"
yarn wrangler d1 migrations apply "$GW_DB_NAME" --remote --env production
(cd "$PURCHASE_DIR" && yarn wrangler d1 migrations apply "$PW_DB_NAME" --remote --env production)

echo "== Gateway production secrets (names only)"
GW_SECRETS=$(yarn wrangler secret list --env production 2>/dev/null || echo "[]")
for name in URL_ENCRYPTION_KEY CHALLENGE_SOURCE_HASH_KEY R2_S3_ACCESS_KEY_ID R2_S3_SECRET_ACCESS_KEY PUSHOVER_APP_TOKEN PUSHOVER_USER_KEY; do
  if echo "$GW_SECRETS" | grep -q "\"$name\""; then
    echo "  $name: present"
  else
    echo "  $name: MISSING"
  fi
done
if echo "$GW_SECRETS" | grep -q '"DEV_BEARER_TOKEN"'; then
  echo "FATAL: DEV_BEARER_TOKEN is forbidden on production." >&2
  exit 1
fi

echo "== PurchaseWorker production secrets (names only)"
PW_SECRETS=$(cd "$PURCHASE_DIR" && yarn wrangler secret list --env production 2>/dev/null || echo "[]")
for name in APP_TX_HMAC_KEY APP_TX_ENCRYPTION_KEY APPLE_IAP_KEY_ID APPLE_IAP_ISSUER_ID APPLE_IAP_PRIVATE_KEY PUSHOVER_APP_TOKEN PUSHOVER_USER_KEY; do
  if echo "$PW_SECRETS" | grep -q "\"$name\""; then
    echo "  $name: present"
  else
    echo "  $name: MISSING"
  fi
done

echo "== Dry runs"
yarn wrangler deploy --dry-run --outdir dist-production --env production >/dev/null
echo "  gateway production dry-run OK"
(cd "$PURCHASE_DIR" && yarn wrangler deploy --dry-run --outdir dist-production --env production >/dev/null)
echo "  purchase production dry-run OK"
(cd "$MEDIA_DIR" && yarn wrangler deploy --dry-run --outdir dist-production -c wrangler.production.jsonc >/dev/null)
echo "  media production dry-run OK"

cat <<'NEXT'
== Provisioned. Deploy order:
  1. cd ../PurchaseWorker && yarn deploy:production
     yarn wrangler triggers deploy --env production
  2. cd ../TranscriptionMediaWorker && yarn deploy:production
  3. cd ../RemoteTranscriptionWorker && yarn deploy:production
     yarn wrangler triggers deploy --env production
NEXT
