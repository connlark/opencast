# OpenCast Share Worker

Serves shared episode links: `https://<host>/e/<token>?t=754`. The token is the
whole episode reference (audio URL, titles, artwork, feed URL, guid, duration,
publish date), compressed into the URL by the app. The Worker decodes it,
server-renders a page with Open Graph tags so messengers show a card (Messages
shows a Play button), and hydrates a small web player. Nothing is stored: no
database, no KV, no secrets.

This public copy contains no deployed Worker names, live routes, or Cloudflare
account resources. `wrangler.jsonc` is a placeholder template.

TypeScript, built with Vite and `@cloudflare/vite-plugin`. The page is written
against React's types and ships `preact/compat` (about 11 KB gzipped), styled
with Tailwind v4 and the system font stack.

## Routes

| Path | Behaviour |
|---|---|
| `GET/HEAD /e/<token>` | Decodes the token and renders the page (200), or a branded 404 when the token is invalid. `?t=` is the start time in seconds or `1h2m3s` form. |
| `GET/HEAD /e/<token>/download` | Streams the enclosure back with `Content-Disposition: attachment` so browsers save it. Range passthrough, audio/octet-stream only, 1 GiB cap, 10 s header timeout, 20 downloads per minute per client (IPv6 counted per /64). |
| `/e/_/*` | Client assets (`entry.js`, `entry.css`), served by the assets binding before the Worker runs. |
| `/e/` | 302 to the marketing site. |
| anything else | 404. Only GET and HEAD are allowed (405 otherwise). |

Every response carries `x-robots-tag: noindex`. Pages send a strict
`Content-Security-Policy`, `Referrer-Policy: strict-origin-when-cross-origin`
(podcast hosts see the origin, never the token), and `Cache-Control:
public, max-age=300`.

## Wire format (version `1`)

- Tuple of eight fields joined with `\n`: audio URL, episode title, podcast
  title, artwork URL, feed URL, guid, duration seconds, publish Unix seconds.
- Raw DEFLATE (no zlib header), level 9, windowBits −15, memLevel 9, with the
  preset dictionary in `src/shared/dictionary.ts` installed before any input.
- base64url without padding, prefixed with the version character `1`. At most
  4096 characters; the tuple inflates to at most 16 KiB.

The app's encoder (`Packages/OpenCastCore/Sources/OpenCastCore/EpisodeShareTokenEncoder.swift`)
is the reference. Its test vectors live in
`Packages/OpenCastCore/Tests/OpenCastCoreTests/Fixtures/EpisodeShareTokenVectors.json`;
this Worker's tests decode every one of them. Changing the tuple, the
compression parameters, or the dictionary requires a new version character, and
the decoder keeps every shipped version.

## Build and test

One install at the repository root, then address the package by name:

```sh
yarn install
yarn workspace opencast-share-worker dev                 # vite dev server running the Worker in workerd
yarn workspace opencast-share-worker typecheck
yarn workspace opencast-share-worker test                # Node: decoder vectors, page head, config contracts
yarn workspace opencast-share-worker test:integration    # builds, then runs the built Worker in workerd
node Server/ShareWorker/scripts/mint-link.mjs --audio https://example.com/a.mp3 --title "Episode" --t 30
```

`vite build` writes `dist/<lane>/client/` and `dist/<lane>/<worker>/` (the
Worker bundle and a flattened `wrangler.json`; `<worker>` is the top-level
Worker name with underscores), and points
`.wrangler/deploy/config.json` at that config. Always build and deploy through
the package scripts, which run both steps under the same `CLOUDFLARE_ENV`;
never combine `--env` with an explicit `-c` on the generated config.

`@cloudflare/vite-plugin` pins wrangler, miniflare and workerd exactly, and
those pins must equal the repository's catalog versions (`test/unit/toolchain.spec.mjs`
fails on drift). Bump the plugin and the catalog together.

## Deploy

`wrangler.jsonc` defines three lanes: the top level (development),
`prod-staging`, and `production`. Only `production` has a route, the
`example.com/e/*` zone route that the production deploy creates, and it never
runs on `workers.dev`. Every lane in the template ships off `workers.dev`; to
preview the development or prod-staging lane there, set `"workers_dev": true`
in that lane. Replace the `your-share-worker` names and the `example.com` route
with your own, then:

```sh
yarn workspace opencast-share-worker login
yarn workspace opencast-share-worker deploy:dry-run
yarn workspace opencast-share-worker deploy                 # development lane
yarn workspace opencast-share-worker deploy:prod-staging
yarn workspace opencast-share-worker deploy:production      # creates the zone route
```

There are no secrets to provision. Each lane has its own rate-limit
`namespace_id`. The template's `1003`, `1004`, and `1005` are schema-valid
examples; the ids are account-wide counters, so pick positive-integer strings
unused by other rate-limit bindings in your account.

The page's canonical URL, the not-found page, the `/e/` redirect, and the
download user agent point at `https://opencast.mobile` (`src/shared/urls.ts`,
`src/worker/download.ts`), and the app mints links on that origin
(`OpenCast/App/OpenCastConstants.swift`). Change them together to serve links
from your own site.

First deploy on a zone:

1. Turn off Rocket Loader, Email Address Obfuscation, and Web Analytics
   auto-injection for `/e/*` with a Configuration Rule (`rocket_loader: false`,
   `email_obfuscation: false`, `disable_rum: true`). All three inject scripts
   or rewrite the HTML; podcast titles often contain email-shaped strings, and
   the page promises no analytics.
2. `curl -sI https://<host>/e/<token>` returns `200 text/html` from this Worker,
   and the rest of the site is unchanged.
3. `curl -sI https://<host>/e/_/entry.js?v=x` returns JavaScript with
   `Cache-Control: public, max-age=31536000, immutable`.
4. `curl -s https://<host>/e/<token> | grep -cE 'cdn-cgi|cloudflareinsights'`
   prints `0`, even for a link whose title contains an email address.
5. Paste a link into Messages: the card shows the artwork and a Play button.

## Privacy

- The page loads artwork and audio directly from the podcast host, which sees
  the recipient's IP address and user agent, as with any podcast app.
- Only the explicit Download button goes through the Worker. Those requests
  reach the host from Cloudflare with the `opencast-share/1` user agent, so
  IAB-style download counting collapses them into one listener; plays from the
  page count normally. The proxy never caches (`cacheTtl: -1`).
- No cookies, analytics, third-party scripts, or fonts. `localStorage` holds
  only the resume position.
- The token is the URL, and Workers Logs attaches the request URL to every
  log event even with invocation logs off, so observability is off in every
  lane and nothing about a request is stored. The code's own log lines (event
  names, status codes, upstream hostnames) appear only in a live
  `wrangler tail`.
- Links cannot expire or be revoked; they reveal a public episode and a
  timestamp, not who shared it.

## React instead of Preact

Not maintained as a build, but the source is plain React: add `react` and
`react-dom`, delete the entries in `alias.ts`, and replace
`preact-render-to-string` with `renderToString` from `react-dom/server` in
`src/worker/render.ts`. The client bundle grows from about 11 KB to about 72 KB
gzipped.
