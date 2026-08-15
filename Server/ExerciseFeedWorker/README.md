# ExerciseFeedWorker

Mutable RSS fixture for the two-device episode-identity exercise, using
`https://graft.example.com/feed.xml` as its public placeholder URL
(`OpenCastUITests/SyncBehaviorsDeviceE2EUITests`, C/D steps).

The feed ("The Grafted Podcast", three episodes reusing the seed podcast's
public MP3s) has two GUID generations selected by KV state:

| State | GUIDs |
| ----- | ----- |
| `v1` (default) | `urn:castgraft:legacy:00X` |
| `v2` | `urn:castgraft:modern:00X` |

Titles, enclosures, and dates never change, so a v1→v2 flip reproduces the
guid-rotation legacy state that changes every episode ID while the audio-URL
and title identity tiers still match — the exact input to refresh-time
reconciliation and the "Merge Duplicate Episodes" sweep.

## Endpoints

- `GET /feed.xml` — the feed for the current state; `ETag: "graft-v1|v2"`,
  honors `If-None-Match` with 304.
- `GET /state` — current state, plain text.
- `POST /state/v1` / `POST /state/v2` — flip, requires
  `Authorization: Bearer $ADMIN_TOKEN`.

## Deploy

```sh
cp wrangler.example.toml wrangler.toml
# Replace the example Worker name, route, and KV namespace ID first.
yarn install         # workspace install at the repository root (any directory works)
yarn deploy          # single lane; custom domain rides the route config
yarn wrangler secret put ADMIN_TOKEN   # regenerate per exercise session
```

The orchestrator flips state between the C01 (seed history under legacy IDs)
and C02 (merge) steps, and polls `GET /state` / the feed ETag until the flip
is visible before proceeding.

**Caveat:** KV writes are visible immediately only at the colo that served
the `POST`; other locations can lag up to ~60 s. Polling `GET /state` proves
the flip is visible at the *orchestrator's* colo, which only implies the
devices' colo when they share a network path. Run the orchestrator from the
same network as the devices under test to minimize that ambiguity.
