# WorkerDatabaseCore

Shared invocation-owned PostgreSQL transport. This crate has no Worker entrypoint, bindings or deployment.

- `lifecycle`: driver ownership, deadlines, cancellation and failure outcomes.
- `statement`: owned typed values, exact-f64 integer bounds, and explicit
  affected-row rules; debug output redacts SQL and bindings.
- `database` / `socket`: wasm-only typed unnamed operations, transaction and
  transport cleanup, enabled by `postgres`.

Default features are empty: a consumer that does not enable `postgres` resolves
no PostgreSQL driver. `postgres` pins the already-reviewed
`tokio-postgres =0.7.18` with default features disabled and `js` enabled. The
wasm `worker =0.8.7` and Tokio I/O traits are optional. No thread runtime or ORM.
NotificationsWorker's dependency enables `postgres`, and FeedPollingWorker
reaches the crate through NotificationsWorker; host tests and clippy of both
therefore compile the driver.

The production descriptor executor submits typed unnamed BEGIN, the backend's
mandatory gate, ordered application statements and COMMIT. Every reply drains;
an early SQL error cannot be hidden by COMMIT reporting rollback. First polling
stays in input order even beyond 32 statements. A failed BEGIN or uncertain
commit/count is Unknown. A gate lock timeout is NotCommitted and retryable at
the semantic boundary; the executor never retries it itself. Per-statement and
transaction timings contain no SQL or values. The semantic backend closes each
storage segment before external I/O and supplies the read decoders and witnesses.
`cap_deadline` lowers a segment's window to the enclosing operation's absolute
deadline; the window only ever shrinks, never replaces the caller's budget.

Run host lifecycle tests with and without features and the wasm checks after
changes. Cargo feature checks must run
per Worker manifest because features are additive. Clippy rejects named and
simple-query application APIs.

```sh
cargo test --locked --manifest-path Server/WorkerDatabaseCore/Cargo.toml
cargo test --locked --manifest-path Server/WorkerDatabaseCore/Cargo.toml --features postgres
cargo check --locked --manifest-path Server/WorkerDatabaseCore/Cargo.toml --target wasm32-unknown-unknown --features postgres
```
