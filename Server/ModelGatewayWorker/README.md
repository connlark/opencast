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

## Security Defaults

- Keep the gateway read-only.
- Keep it disabled until the R2 objects and signed manifests are complete.
- Keep the Ed25519 private key outside the repository and outside Worker
  secrets; only the public verification key belongs in clients.
- Preserve range validation, object-prefix handling, and response limits.
- Do not commit signing keys, Cloudflare credentials, private bucket names, or
  local model payloads that are not covered by the public repository's LFS
  policy.
