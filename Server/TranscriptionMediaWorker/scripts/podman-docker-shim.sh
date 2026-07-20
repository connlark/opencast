#!/usr/bin/env bash
# Podman shim for wrangler container builds (house rule: Podman, never Docker
# Desktop). Two compatibility fixes for podman 6.0.1:
# - strip the buildx-only `--provenance` flag wrangler passes to `build`;
# - build in docker (v2s2) manifest format so the image digest wrangler
#   records locally survives `podman push` unchanged (OCI images get
#   re-digested on push, which breaks wrangler's registry reference).
set -euo pipefail
subcommand="${1:-}"
args=()
for arg in "$@"; do
  case "$arg" in
    --provenance|--provenance=*) continue ;;
    *) args+=("$arg") ;;
  esac
done
if [[ "$subcommand" == "build" ]]; then
  args=("build" "--format=docker" "${args[@]:1}")
fi
exec podman "${args[@]}"
