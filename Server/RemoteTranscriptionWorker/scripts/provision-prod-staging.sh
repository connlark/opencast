#!/usr/bin/env bash
# Idempotent prod-staging provisioning for a self-hosted deployment using
# production App Attest + Sandbox StoreKit. Creates or verifies the
# isolated gateway D1, purchase D1, private R2 bucket + lifecycle, applies
# migrations, checks secrets presence (names only — values never printed),
# fail-closed checks (no dev bearer secret on this lane, no public r2.dev),
# and dry-run deploys for all three workers. Deploys are separate explicit
# steps printed at the end (order matters: PurchaseWorker before the gateway
# that binds it).
set -euo pipefail
cd "$(dirname "$0")/.."

GW_DB_NAME="your-remote-transcription-db-prod-staging"
PW_DB_NAME="your-purchase-db-prod-staging"
BUCKET="your-remote-transcription-audio-prod-staging"
PURCHASE_DIR="../PurchaseWorker"
MEDIA_DIR="../TranscriptionMediaWorker"

echo "== D1 (gateway): $GW_DB_NAME"
if ! yarn --silent wrangler d1 info "$GW_DB_NAME" >/dev/null 2>&1; then
  yarn --silent wrangler d1 create "$GW_DB_NAME"
fi
GW_DB_ID=$(yarn --silent wrangler d1 info "$GW_DB_NAME" --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["uuid"])')
if ! grep -q "database_id = \"$GW_DB_ID\"" wrangler.toml; then
  echo "FATAL: wrangler.toml prod-staging database_id does not match the live database ($GW_DB_ID)." >&2
  echo "Refusing to adopt an unexpected database; update wrangler.toml deliberately." >&2
  exit 1
fi

echo "== D1 (purchase): $PW_DB_NAME"
if ! (cd "$PURCHASE_DIR" && yarn --silent wrangler d1 info "$PW_DB_NAME" >/dev/null 2>&1); then
  (cd "$PURCHASE_DIR" && yarn --silent wrangler d1 create "$PW_DB_NAME")
fi
PW_DB_ID=$(cd "$PURCHASE_DIR" && yarn --silent wrangler d1 info "$PW_DB_NAME" --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["uuid"])')
if ! grep -q "database_id = \"$PW_DB_ID\"" "$PURCHASE_DIR/wrangler.toml"; then
  echo "FATAL: PurchaseWorker wrangler.toml prod-staging database_id does not match ($PW_DB_ID)." >&2
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
yarn --silent wrangler d1 migrations apply "$GW_DB_NAME" --remote --env prod-staging
(cd "$PURCHASE_DIR" && yarn --silent wrangler d1 migrations apply "$PW_DB_NAME" --remote --env prod-staging)

echo "== Gateway secrets (names only; set missing with 'yarn wrangler secret put <NAME> --env prod-staging')"
GW_SECRETS=$(yarn --silent wrangler secret list --env prod-staging 2>/dev/null || echo "[]")
for name in URL_ENCRYPTION_KEY CHALLENGE_SOURCE_HASH_KEY; do
  if echo "$GW_SECRETS" | grep -q "\"$name\""; then
    echo "  $name: present"
  else
    echo "  $name: MISSING"
  fi
done

echo "== Fail-closed: dev bearer must NOT exist on prod-staging"
if echo "$GW_SECRETS" | grep -q '"DEV_BEARER_TOKEN"'; then
  echo "FATAL: DEV_BEARER_TOKEN secret exists on the prod-staging gateway; delete it." >&2
  exit 1
fi
echo "  ok"

echo "== PurchaseWorker secrets (names only)"
PW_SECRETS=$(cd "$PURCHASE_DIR" && yarn --silent wrangler secret list --env prod-staging 2>/dev/null || echo "[]")
for name in APP_TX_HMAC_KEY APP_TX_ENCRYPTION_KEY APPLE_IAP_KEY_ID APPLE_IAP_ISSUER_ID APPLE_IAP_PRIVATE_KEY; do
  if echo "$PW_SECRETS" | grep -q "\"$name\""; then
    echo "  $name: present"
  else
    echo "  $name: MISSING"
  fi
done
echo "  (Set the APPLE_IAP_* trio from your In-App Purchase key; reconciliation fails closed until configured.)"

echo "== Dry runs"
yarn --silent wrangler deploy --dry-run --outdir dist --env prod-staging >/dev/null && echo "  gateway prod-staging dry-run OK"
(cd "$PURCHASE_DIR" && yarn --silent wrangler deploy --dry-run --outdir dist-prod-staging --env prod-staging >/dev/null && echo "  purchase prod-staging dry-run OK")
(cd "$MEDIA_DIR" && yarn --silent wrangler deploy --dry-run --outdir dist -c wrangler.prod-staging.jsonc >/dev/null && echo "  media prod-staging dry-run OK")

cat <<'NEXT'
== Provisioned. Deploy order (explicit, not automated here):
  1. cd ../PurchaseWorker && yarn deploy:prod-staging
     # then verify the reconciliation cron actually applied (repo memory:
     # changed crons may need 'yarn wrangler triggers deploy --env prod-staging')
  2. cd ../TranscriptionMediaWorker && yarn wrangler deploy -c wrangler.prod-staging.jsonc
     # use the reviewed container image pinned in the prod-staging config
  3. cd ../RemoteTranscriptionWorker && yarn wrangler deploy --env prod-staging
NEXT
