#!/bin/bash
# Fails when Rust test code sits inside a wasm-only module — such tests never
# compile on any lane: host `cargo test` skips the module, wasm `cargo check`
# never compiles test code. (High 1: this recurred twice before this tripwire
# existed.)
#
# The first version only enumerated lib.rs-declared
# modules and read `not(test)` as a test arm):
#   - every .rs file in every Server crate is scanned, including INLINE
#     wasm-only `mod x { … }` blocks (the sweeper.rs `mod runtime` shape);
#   - `not(test)` no longer reads as test-reachable;
#   - wasm-only `mod x;` declarations are resolved from any file, not just
#     lib.rs, and an unresolvable module fails loud;
#   - multi-line `#[cfg(…)]` attributes are accumulated; `#[path]` and
#     unbalanced braces fail loud rather than pass silent.
# Python stdlib only (preflight already depends on python3 for the oss-sync
# checks); still network-free and fast.
set -euo pipefail
exec python3 "$(cd "$(dirname "$0")" && pwd)/check-wasm-only-test-gating.py"
