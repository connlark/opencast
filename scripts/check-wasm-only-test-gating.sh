#!/bin/bash
# Fails when a module that a Rust worker's lib.rs declares wasm-only (no test
# arm) contains #[cfg(test)] — such tests never compile on any lane: host
# `cargo test` skips the module, wasm `cargo check --lib` never compiles test
# code. (High 1: this recurred twice before this tripwire existed.)
#
# Dependency-free by design (grep/awk only) so it stays fast inside
# scripts/preflight.sh and the server CI workflow.
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
status=0

for lib in "$repo_dir"/Server/*/src/lib.rs; do
  [[ -f "$lib" ]] || continue
  crate_dir="$(dirname "$lib")"

  while IFS= read -r module; do
    [[ -n "$module" ]] || continue
    # A directory module's tests can hide in any child file, not just
    # mod.rs — walk the whole subtree (Phase 10 K hardening).
    candidates=()
    [[ -f "$crate_dir/$module.rs" ]] && candidates+=("$crate_dir/$module.rs")
    if [[ -d "$crate_dir/$module" ]]; then
      while IFS= read -r child; do
        candidates+=("$child")
      done < <(find "$crate_dir/$module" -type f -name '*.rs' | sort)
    fi
    for candidate in "${candidates[@]}"; do
      if grep -q '#\[cfg(test)\]' "$candidate"; then
        echo "FAIL: wasm-only module '$module' contains #[cfg(test)] ($candidate)" >&2
        echo "      Host cargo test never compiles it. Gate the module" >&2
        echo "      #[cfg(any(target_arch = \"wasm32\", test))] in lib.rs, or move the" >&2
        echo "      tests into a host-gated module (see subscription_payloads.rs)." >&2
        status=1
      fi
    done
  done < <(awk '
    # Same-line form: #[cfg(target_arch = "wasm32")] mod x;  (Phase 10 K)
    /^[[:space:]]*#\[cfg\(.*\)\][[:space:]]*(pub([(][^)]*[)])?[[:space:]]+)?mod[[:space:]]+[A-Za-z0-9_]+;/ {
      attr = $0
      sub(/\][^]]*$/, "]", attr)
      gsub(/[[:space:]]/, "", attr)
      if (attr ~ /target_arch="wasm32"/ && attr !~ /test/) {
        name = $0
        sub(/^[[:space:]]*#\[cfg\(.*\)\][[:space:]]*(pub([(][^)]*[)])?[[:space:]]+)?mod[[:space:]]+/, "", name)
        sub(/;.*/, "", name)
        print name
      }
      wasm_only = 0
      next
    }
    /^[[:space:]]*#\[cfg\(/ {
      attr = $0
      gsub(/[[:space:]]/, "", attr)
      wasm_only = (attr ~ /target_arch="wasm32"/ && attr !~ /test/)
      next
    }
    /^[[:space:]]*(pub([(][^)]*[)])?[[:space:]]+)?mod[[:space:]]+[A-Za-z0-9_]+;/ {
      if (wasm_only) {
        name = $0
        sub(/^[[:space:]]*(pub([(][^)]*[)])?[[:space:]]+)?mod[[:space:]]+/, "", name)
        sub(/;.*/, "", name)
        print name
      }
      wasm_only = 0
      next
    }
    { wasm_only = 0 }
  ' "$lib")
done

if [[ "$status" -eq 0 ]]; then
  echo "PASS: no wasm-only module contains #[cfg(test)]"
fi
exit "$status"
