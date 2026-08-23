# OpenCast Podcast Directory Worker

Self-hostable Rust Cloudflare Worker that proxies Podcast Index for OpenCast's
podcast-discovery supplement. Apple remains the ranking and display-metadata
authority; this Worker provides fallback search, feed-resolution checks, and
gap filling. The app never contacts Podcast Index directly.

This public copy contains no deployed Worker names, live routes, Cloudflare
account resources, or Podcast Index credentials.

## Setup

Install dependencies and copy the public configuration template:

```sh
yarn install
cp wrangler.example.toml wrangler.toml
```

Replace the `your-...` Worker names and `directory.example.com` route with
values from your own Cloudflare account and domain. The rate-limit namespace
IDs `1001` and `1002` are schema-valid public examples: choose positive-integer
strings unused by other rate-limit bindings in your account. Use different IDs
per environment if you do not want counters shared across lanes.

Keep `PUBLIC_PODCAST_DIRECTORY_ENABLED` set to `false` until the route,
credentials, and both rate-limit bindings are configured.

Set the two Podcast Index credentials with Wrangler; never commit their
values:

```sh
yarn wrangler secret put PODCAST_INDEX_API_KEY
yarn wrangler secret put PODCAST_INDEX_API_SECRET
```

Repeat the commands with `--env prod-staging` or `--env production` for those
environments.

## Commands

```sh
yarn test
yarn typecheck
yarn test:integration
yarn deploy:dry-run
```

Run locally after creating `wrangler.toml`:

```sh
yarn dev
```

## API

- `POST /v1/search` accepts a bounded JSON query and returns normalized
  directory entries.
- `GET /v1/podcasts/by-apple-id/{id}` resolves Podcast Index metadata for a
  positive Apple podcast ID.
- `GET /v1/health` reports service availability without contacting the
  upstream provider.

Successful responses use version 1 of the public envelope. Raw Podcast Index
responses are not exposed; the app fetches and validates candidate RSS feeds
before subscribing.

## Security and Privacy Defaults

- Keep the public service flag disabled until deployment is complete.
- Keep Podcast Index credentials in Worker secrets and out of responses and
  logs.
- Preserve request validation, body and response-size caps, upstream timeouts,
  response normalization, and both rate-limit bindings.
- Preserve hashed cache keys and structured logs that omit search text.
- Do not add arbitrary upstream proxy routes or persist search queries.

Podcast Index attribution remains visible in the app's discovery surfaces.
