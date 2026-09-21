# Owned notification fixtures

All credentials and `*.example.invalid` URLs are synthetic. `wire.json` pins the legacy enrollment/payload contract and proposed completion shape; it contains **no valid credential or usable APNs token**. The host Rust compatibility test exercises the production renderer/identity/binding helpers against it. Shared known-answer vectors pin JSON-array identifiers, canonical UTF-8 envelope bytes/digest and the legacy collapse key in Rust and JavaScript. Negative ingress vectors pin duplicate-key, unknown-key and future-skew rejection for a future validator; they are not proof of a shipped ingress implementation.

RSS is generated deterministically by `../generate.mjs`, with scenario expectations in `../fixtures.mjs`; large output stays under `/private/tmp`. `../serve.mjs` exposes only a loopback server and never fetches a publisher. Run the scripts from repository root; see the [runner guide](../README.md).
