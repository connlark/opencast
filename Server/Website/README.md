# opencast Website (`opencast-website`)

Unified marketing + support/privacy site: Next.js (App Router, TypeScript), HeroUI v3, Tailwind CSS v4, and Lucide icons, built with `output: "export"`. A thin Cloudflare Worker (`worker/index.ts`) fronts the static assets in `out/` and encodes host-based behavior for **both** custom domains.

## Hostnames and routes

One worker, two hostnames (Workers Custom Domains):

| Host | Path | Behavior |
|---|---|---|
| `opencast.mobile` | `/` | Home page |
| `opencast.mobile` | `/support`, `/privacy` | Served directly |
| `opencast.mobile` | `/app-store` | 302 → App Store listing |
| `opencast.mobile` | `/testflight` | TestFlight landing page |
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
yarn sync-brand-assets # regenerate icons + social card from the app icon (macOS + Xcode)
yarn preview    # next build && wrangler dev :8787 (full worker behavior)
yarn deploy     # sync screenshots, build, and deploy both custom domains
yarn typecheck  # app tsc + worker tsc
yarn lint
```

`yarn preview` exercises the marketing host. It does **not** exercise the
support host: wrangler 4.111.0's dev proxy rewrites the worker's `request.url`
host to the local address, so `url.hostname === "support.opencast.mobile"` never
matches locally and every request falls through to the marketing branch (a
`Host:` header or `curl --resolve` does not change this). Verify support-host
behavior against the deployed site instead — `curl -s https://support.opencast.mobile/health`
should print `ok`, and an unknown path should return 404 with the support body.

## Appearance

The site follows the operating system's light/dark preference. There is no theme
toggle and no persisted override.

- All theme tokens live in one unlayered `:root` block in `src/app/globals.css`,
  with a single `@media (prefers-color-scheme: dark)` override. Being unlayered,
  they outrank `@heroui/styles`, which keys its own dark values on `.dark` /
  `[data-theme="dark"]` — selectors this site never sets. Keep every token
  declaration on `:root`: HeroUI's derived tokens are `color-mix()` chains that
  resolve against the element's own custom properties.
- The dark block mirrors the token set `@heroui/styles@3.2.2` declares at
  `dist/themes/default/variables.css:177-293`. Re-diff that block on upgrade.
- `color-scheme: light dark` on `:root` is deliberate; it replaces HeroUI's
  hardcoded `color-scheme: light` so native scrollbars and form controls follow
  the system too.
- HeroUI 3.2.2's `dark:` Tailwind variant has a broken `prefers-color-scheme`
  fallback (`dist/variants/index.css:97` has a stray trailing `&`), so `dark:*`
  utilities silently do nothing here. Use tokens, not `dark:` utilities.
- Brand orange (`#F9730E`) and gold (`#FEC44C`) are display colors: on the warm
  off-white surfaces they measure 2.63:1 and 1.49:1, below even the 3:1 UI bar.
  Light mode uses darkened, hue-matched functional variants (`--accent`,
  `--accent-display`, `--accent-gold`) for anything that carries meaning; dark
  mode uses the literal brand hexes, which clear AA on navy.
- `viewport.themeColor` in `src/app/layout.tsx` carries one value per scheme and
  must track `--background`.

## Brand assets

`scripts/sync-brand-assets.mjs` is the only way these files should change — do
not hand-edit the generated output.

- Source of truth: `OpenCast/Resources/AppIcon.icon`, the same Icon Composer
  document that produces the shipping iOS app icon.
- Requires **macOS with Xcode 26+**, because the renderer is Icon Composer's
  embedded `ictool` at
  `/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool`.
  (`xcrun ictool` is a different tool and cannot export images.) The generated
  files are committed, so `yarn build` and `yarn deploy` do not need Xcode.
- It renders the iOS `Default` and `Dark` renditions at 1024px into a temp
  directory and downscales with Lanczos — rendering natively at 32px loses the
  thin inner arc of the mark. Nothing 1024px is committed.
- Outputs: `public/brand/icon-{light,dark}-{32,192}.png` (Default rendition for
  light UI, Dark rendition for dark UI), `public/brand/apple-touch-icon-180.png`
  (Default rendition, flattened onto the icon's own gradient because iOS
  composites transparent corners against white), and `public/opengraph-image.jpg`
  (1200×630, built from the Default render plus the committed Now Playing
  screenshot). Promotional artwork always uses the Default rendition.
- The social card crops the device out of the 464px framed screenshot using
  `DEVICE_CROP`; re-measure it if the fastlane frame template changes.

## Layout notes

- `worker/index.ts` — the entire dynamic surface (~60 lines). HTML responses get `cache-control: public, max-age=300`.
- `wrangler.jsonc` `run_worker_first` — any **new top-level `public/` file or directory must be added to the negation list**, or the support host will swallow it into its 404 handling. `/_next/*` must stay negated.
- `public/_headers` — immutable caching for `/_next/static/*`.
- `vendor/apple-app-store-badges/` — Apple's official badge pack, stored in Git LFS (`git lfs pull` before copying, or you will ship a 130-byte pointer). `public/badges/app-store-badge-black.svg` and `-white.svg` are verbatim copies of the US-UK lockups; `AppStoreBadge.tsx` picks between them with `<picture>` per Apple's guidance (black on light, white on dark).
- `public/brand/` — generated app-icon renditions; see [Brand assets](#brand-assets).
- `public/screenshots/` — committed, content-hashed AVIF/WebP screenshots plus 2x PNG fallbacks, generated from the pinned fastlane renders by `scripts/sync-screenshots.mjs`.
- Copy on the support/privacy pages is the App Store–facing support contract and privacy policy (effective date June 21, 2026); change wording deliberately.
