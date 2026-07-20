# opencast Website (`opencast-website`)

Unified marketing + support/privacy site: Next.js (App Router, TypeScript), HeroUI v3, Tailwind CSS v4, and Lucide icons, built with `output: "export"`. A thin Cloudflare Worker (`worker/index.ts`) fronts the static assets in `out/` and encodes host-based behavior for **both** custom domains.

## Hostnames and routes

One worker, two hostnames (Workers Custom Domains):

| Host | Path | Behavior |
|---|---|---|
| `opencast.mobile` | `/` | Home page |
| `opencast.mobile` | `/support`, `/privacy` | Served directly |
| `opencast.mobile` | `/app-store` | 302 → App Store listing |
| `opencast.mobile` | anything else | 302 → `/` |
| `support.opencast.mobile` | `/` | Support page body |
| `support.opencast.mobile` | `/support`, `/privacy` | Served directly (App Store support/privacy URLs) |
| `support.opencast.mobile` | `/health` | `200 ok` |
| `support.opencast.mobile` | anything else | 404 with support page body |
| both | non-GET/HEAD | 405 |

These URLs are referenced by `OpenCast/App/OpenCastConstants.swift` and `fastlane/metadata/en-US/{marketing_url,privacy_url,support_url}.txt` — do not change semantics without checking those.

## Build / develop / deploy

Yarn 1.22.22 only (never npm/npx; no `package-lock.json`).

```bash
yarn dev        # next dev (Next routes only, no worker logic)
yarn build      # next build → static export in out/
yarn sync-screenshots # regenerate committed responsive assets from fastlane output
yarn preview    # next build && wrangler dev :8787 (full worker behavior)
yarn deploy     # sync screenshots, build, and deploy both custom domains
yarn typecheck  # app tsc + worker tsc
yarn lint
```

Test the support host locally with `curl -H "Host: support.opencast.mobile" http://localhost:8787/...` against `yarn preview`.

## Layout notes

- `worker/index.ts` — the entire dynamic surface (~60 lines). HTML responses get `cache-control: public, max-age=300`.
- `wrangler.jsonc` `run_worker_first` — any **new top-level `public/` file or directory must be added to the negation list**, or the support host will swallow it into its 404 handling. `/_next/*` must stay negated.
- `public/_headers` — immutable caching for `/_next/static/*`.
- `vendor/apple-app-store-badges/` — Apple's official badge pack; `public/badges/app-store-badge.svg` is the white US-UK lockup used as the App Store CTA.
- `public/screenshots/` — committed, content-hashed AVIF/WebP screenshots plus 2x PNG fallbacks, generated from the pinned fastlane renders by `scripts/sync-screenshots.mjs`.
- Copy on the support/privacy pages is the App Store–facing support contract and privacy policy (effective date June 21, 2026); change wording deliberately.
