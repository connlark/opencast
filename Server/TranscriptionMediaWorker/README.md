# OpenCast Transcription Media Worker

Self-hostable private Cloudflare Worker and pinned ffmpeg container for media
probe/chunk operations. It is reachable only through a service binding, with
no routes and no workers.dev exposure. The container runs without Internet
access and receives only R2-backed media URLs from the Worker.

The three checked-in Wrangler JSONC files are public templates for development,
prod-staging, and production. Replace the account hash, image tag/digest,
Worker names, and bucket names with your own isolated resources.

## Setup and Commands

```sh
yarn install
yarn typecheck
yarn build:image
yarn deploy:dry-run
```

Build and push the image with Podman using
`scripts/podman-docker-shim.sh`, then pin the pushed registry digest in all
three configs before deployment. Keep each lane on its matching private R2
bucket and service binding.

Preserve request caps, path validation, Durable Object isolation,
`enableInternet = false`, and the R2-only egress mapping. Never add public
routes, generic outbound network access, customer media, object listings, or
Cloudflare credentials to this repository.
