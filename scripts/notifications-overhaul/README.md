# Notification contract fixture harness

Local test tools only. No shipped entrypoint, remote binding, migration, credential, inference call or APNs connection. These executable **contract oracles** validate the proposed rules; they do not establish implementation of a production notification service. Actual current Rust compatibility helpers and packaged-worker tests provide separate baseline evidence.

Use the repository's Node 26 / Yarn 4 installation. No install, new runtime or dependency is needed.

```sh
node --test scripts/notifications-overhaul/*.test.mjs
node scripts/notifications-overhaul/generate.mjs
cargo test --locked --manifest-path Server/NotificationsWorker/Cargo.toml
```

The phase-zero prototype schema, publication/recovery runtime, binding compile
probe and legacy baseline collector were retired after production cutover. Their
historical results remain in Git history. They are no
longer an alternate executable model or a supported way to query production.
Use `Server/NotificationsWorker/tests/storage-cleanup.mjs`,
`delivery-runtime.mjs`, `observation-runtime.mjs` and the FeedPolling runtime
suites for actual D1/R2/Queue publication, cancellation and recovery behavior.

Optional interactive RSS surface:

```sh
node scripts/notifications-overhaul/serve.mjs
```

The printed ephemeral `127.0.0.1` address serves `/F02.xml?phase=baseline`, `/F02.xml`, other IDs from `fixtures.mjs`, and `/100000.xml[.gz]`. F17 truncates the XML tail; F18 provides an interrupted tail, and the actual request-abort proof remains the existing cancellation harness; F19 leaves the response stalled until the consumer cancels. F20 returns 304. Otherwise ETag/If-None-Match exercise conditional fetch. Stop with Ctrl-C. Do not point a production Worker at this server; fixture consumers use an injected transport because loopback URLs are correctly denied by production feed policy.

`Clock.advance()` provides deterministic deadlines. `Faults.hit()` throws once at a named crash point. `FakeAPNs` supplies ordered HTTP outcomes, timeout and accepted-but-response-lost outcomes and records attempts. No valid signing credentials are used. For later integration, adapt those fixtures to the production Rust implementation rather than treating the reference models as deployed policy.

Package/test the current Worker separately (outside restricted sandbox where needed):

```sh
WRANGLER_LOG_PATH=/private/tmp/opencast-notifications-wrangler.log \
  yarn workspace @opencast/notifications-worker deploy:dry-run --env prod-staging
node Server/NotificationsWorker/tests/observation-runtime.mjs
node Server/NotificationsWorker/tests/feed-cancellation-runtime.mjs
```

`aggregate.mjs` accepts an aggregate usage/rate worksheet and marks absent
dimensions unavailable. It is also imported by the current polling cost model.
The retained RSS generators, deterministic policy models and wire fixtures use
synthetic data and make no production calls. Stable scenario IDs and expected
assertions live beside each fixture. They do not require the retired schema.
