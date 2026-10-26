# OpenCast Model Gateway Worker

Self-hostable, read-only Cloudflare Worker code for serving signed transcription
model manifests and model assets from R2. Yarn is the command surface for
Wrangler.

This public copy contains no deployed Worker names, routes, R2 bucket names,
Cloudflare resource IDs, or manifest-signing private key.

## Setup

Install dependencies and copy the public config template:

```sh
yarn install
cp wrangler.example.toml wrangler.toml
```

Create your own R2 bucket, replace the placeholder bucket and route names, and
keep `PUBLIC_MODEL_GATEWAY_ENABLED` set to `false` until the signed manifests
and every referenced object are present.

The manifest-signing key is a local input, not a deployed Worker secret. Create
a new key outside this checkout and keep it in a password manager or secret
store:

```sh
umask 077
openssl rand -hex 32 > /secure/path/model-manifest-signing-key.hex
cargo run --bin derive_manifest_public_key -- /secure/path/model-manifest-signing-key.hex
```

Set `OPENCAST_MODEL_MANIFEST_SIGNING_KEY_HEX` only in the local process that
runs `generate_manifest`, `merge_manifests`, or `sign_manifest`; never commit
the value or the key file. Configure clients with the corresponding public key.

The generic upload helper accepts `BUCKET`, `MODEL_DIR`, `TOKENIZER_DIR`, and
other path overrides. For example:

```sh
BUCKET=your-model-bucket scripts/upload-large-v3-assets.sh
```

## Commands

```sh
yarn test
yarn typecheck
yarn deploy:dry-run
```

Run locally after creating `wrangler.toml`:

```sh
yarn dev
```

## Analysis Policy

The app's on-device ad detection and Chapters & Summary read their prompts,
response schemas, model entries, timeouts and limits from one signed JSON
document, the analysis policy bundle. The gateway serves it from R2 under
`POLICY_OBJECT_PREFIX`:

- `GET` / `HEAD /v1/policies/analysis` and `/v1/policies/analysis.sig`
- `GET` / `HEAD /v1/policies/analysis/{version}.json` and `.json.sig`

The current signature is a detached Ed25519 envelope (same key as the model
manifest) that also names the bundle it signs: `bundle_version` and the
SHA-256 of its exact bytes. The app reads that signature, fetches
`/v1/policies/analysis/{bundle_version}.json`, checks the digest and verifies
the signature over those bytes, so a signature can never be paired with
another generation's bundle. Versioned documents are immutable and edge
cached; the current signature and `/v1/policies/analysis` are `no-cache`, so a
publish is visible at once. The app verifies the signature against its pinned
key, rejects a bundle that needs a newer app build, rejects the whole bundle
when any value is outside its hard bounds, and then falls back to the copy
baked into the build. A bundle may only tighten what was qualified.

`manifests/analysis-policy.schema.json` states the document and the bounds;
`manifests/analysis-policy/vN.json` and `.sig` are the checked-in bundles the
trial proxy embeds at build time. `tests/analysis_policy.rs` fails if a schema
bound and a worker constant part ways, or if a checked-in bundle, the app's
baked copy or the test fixtures differ from what the generator produces.

`generate_policy` builds the bundle from the analysis workers' own constants,
prompt file and schemas (host-only path dependencies on `AdAnalysisWorker` and
`TranscriptAnalysisWorker`); the provider wire facts, key pages, trial block
and notice start are named constants in `src/analysis_policy.rs`. Bump
`--bundle-version` for every content change; the app never moves to a lower
version. Sign with the same local key as the manifests:

```sh
OPENCAST_MODEL_MANIFEST_SIGNING_KEY_HEX="$(tr -d '\n' < /secure/path/model-manifest-signing-key.hex)" \
cargo run --bin generate_policy -- \
  --bundle-version 1 \
  --generated-at 2026-10-24T00:00:00Z \
  --min-app-build 301 \
  --output manifests/analysis-policy/v1.json \
  --signature-output manifests/analysis-policy/v1.json.sig \
  --signature-key-id your-signing-key-id \
  --swift-baked-output ../../Packages/OpenCastAnalysis/Sources/OpenCastAnalysis/Policy/BakedAnalysisPolicy.swift \
  --swift-test-fixtures-output ../../Packages/OpenCastAnalysis/Tests/OpenCastAnalysisTests/Policy/AnalysisPolicyTestFixtures.swift
```

`--swift-baked-output` rewrites the copy the app ships with; only do that for
the version the next build should carry. The test fixtures are signed with a
throwaway key derived from a public label, never the deployment key. Bundle
timestamps must be canonical UTC (`2026-10-24T00:00:00Z`).

`verify_policy` re-checks a signed bundle the way the app does and reports
whether it still matches the generator:

```sh
cargo run --bin verify_policy -- \
  --input manifests/analysis-policy/v1.json \
  --signature manifests/analysis-policy/v1.json.sig
```

Publish a version with `POLICY_VERSION=1 BUCKET=your-model-bucket
./scripts/upload-analysis-policy.sh`. The script runs `verify_policy`, then
`scripts/analysis-policy-publisher.mjs` writes the versioned bundle and
signature with conditional creates (a version already holding different bytes
aborts the publish before anything current changes), reads both back, writes
`current.json` and flips `current.json.sig` last, so every client keeps
verifying the previous version until the flip and a rerun is safe.

## Security Defaults

- Keep the gateway read-only.
- Keep it disabled until the R2 objects and signed manifests are complete.
- Keep the Ed25519 private key outside the repository and outside Worker
  secrets; only the public verification key belongs in clients.
- Preserve range validation, object-prefix handling, and response limits.
- Do not commit signing keys, Cloudflare credentials, private bucket names, or
  local model payloads that are not covered by the public repository's LFS
  policy.
