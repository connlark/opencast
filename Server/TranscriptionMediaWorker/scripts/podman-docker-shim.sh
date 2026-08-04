#!/usr/bin/env bash
# Podman shim for wrangler container builds (house rule: Podman, never Docker
# Desktop). Two compatibility fixes for podman 6.x:
# - strip the buildx-only `--provenance` flag wrangler passes to `build`;
# - build in docker (v2s2) manifest format so the registry keeps docker
#   media types and the image config blob (== local image ID) survives push
#   intact. NOTE the manifest digest itself does NOT survive: podman
#   recompresses layers on push, so the tag re-digests even in v2s2
#   (verified 2026-08-04). Always resolve the registry's
#   docker-content-digest after pushing — procedure in ../README.md
#   ("Image rollout"). Wrangler quirk: `wrangler deploy`/build honors
#   WRANGLER_DOCKER_BIN, but `wrangler containers push` ignores it and
#   needs --path-to-docker pointed at this shim (yarn push:image).
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
