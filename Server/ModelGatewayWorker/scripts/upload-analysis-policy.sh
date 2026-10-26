#!/usr/bin/env bash
# Publishes one signed analysis policy bundle version to R2.
#
# The app reads the current signature, whose envelope names a bundle version
# and its SHA-256, then fetches that version's immutable bundle. So the
# versioned bundle and signature go up first, each with a conditional create
# that only lands if the key is absent, and the current signature flips last;
# until the flip every client keeps verifying the previous version. A version
# is immutable: if it already holds different bytes the publish aborts before
# touching current, and if it holds the same bytes a rerun is a no-op. Two
# publishers racing on one version cannot both win. The bucket is shared by
# every Worker environment, so a publish reaches each environment that routes
# /v1/policies/analysis.
#
#   POLICY_VERSION=1 ./scripts/upload-analysis-policy.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../" && pwd)"
WORKER_DIR="$ROOT/Server/ModelGatewayWorker"
POLICY_VERSION="${POLICY_VERSION:?set POLICY_VERSION to the bundle version to publish}"
if [[ ! "$POLICY_VERSION" =~ ^[1-9][0-9]*$ ]]; then
  echo "POLICY_VERSION must be a positive integer without leading zeros." >&2
  exit 1
fi
PREFIX="${PREFIX:-opencast/policies}"
BUCKET="${BUCKET:-public}"
BUNDLE="$WORKER_DIR/manifests/analysis-policy/v$POLICY_VERSION.json"
SIGNATURE="$BUNDLE.sig"

if [[ ! -f "$BUNDLE" || ! -f "$SIGNATURE" ]]; then
  echo "Missing $BUNDLE or its signature. Run generate_policy with --signature-output first." >&2
  exit 1
fi

cd "$WORKER_DIR"
# Never publish what the app would reject: the signature must name exactly
# these bytes, and their version must be the one the object keys use.
report="$(cargo run --quiet --locked --bin verify_policy -- --input "$BUNDLE" --signature "$SIGNATURE")"
printf '%s\n' "$report"
signed_version="$(printf '%s\n' "$report" | sed -nE 's/^bundle_version ([0-9]+) .*/\1/p')"
if [[ "$signed_version" != "$POLICY_VERSION" ]]; then
  echo "The bundle is version ${signed_version:-unknown}, not POLICY_VERSION=$POLICY_VERSION; nothing published." >&2
  exit 1
fi

# Conditional creates for the versioned objects, then current, then the flip
# (see analysis-policy-publisher.mjs). Exits non-zero, before anything current
# changes, if the version already holds different bytes.
node "$WORKER_DIR/scripts/analysis-policy-publisher.mjs" \
  --version "$POLICY_VERSION" \
  --bundle "$BUNDLE" \
  --signature "$SIGNATURE" \
  --bucket "$BUCKET" \
  --prefix "$PREFIX"
