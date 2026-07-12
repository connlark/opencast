#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../" && pwd)"
WORKER_DIR="$ROOT/Server/ModelGatewayWorker"
MODEL_ID="${MODEL_ID:-openai_whisper-large-v3-v20240930_626MB}"
VERSION="${VERSION:-20240930_626MB-v1}"
TOKENIZER_ID="${TOKENIZER_ID:-openai_whisper-large-v3}"
PREFIX="${PREFIX:-opencast/models}"
BUCKET="${BUCKET:-public}"
MODEL_DIR="${MODEL_DIR:-"$ROOT/Packages/OpenCastTranscription/Sources/OpenCastTranscription/Resources/Models/$MODEL_ID"}"
TOKENIZER_DIR="${TOKENIZER_DIR:-"$ROOT/Packages/OpenCastTranscription/Sources/OpenCastTranscription/Resources/Tokenizers/$TOKENIZER_ID"}"
MANIFEST="$WORKER_DIR/manifests/$MODEL_ID@$VERSION.json"
CURRENT_MANIFEST="$WORKER_DIR/manifests/current.json"
MANIFEST_SIGNATURE="$MANIFEST.sig"
CURRENT_MANIFEST_SIGNATURE="$CURRENT_MANIFEST.sig"
MAX_WRANGLER_OBJECT_BYTES=314572800

if [[ ! -f "$MANIFEST" || ! -f "$CURRENT_MANIFEST" || ! -f "$MANIFEST_SIGNATURE" || ! -f "$CURRENT_MANIFEST_SIGNATURE" ]]; then
  echo "Missing generated manifests or signatures. Run cargo run --bin generate_manifest with signature outputs first." >&2
  exit 1
fi
if [[ ! -d "$MODEL_DIR" || ! -d "$TOKENIZER_DIR" ]]; then
  echo "Missing model payload directories. Set MODEL_DIR and TOKENIZER_DIR to local payload roots." >&2
  exit 1
fi

file_size_bytes() {
  local path="$1"
  if stat -f %z "$path" >/dev/null 2>&1; then
    stat -f %z "$path"
  else
    stat -c %s "$path"
  fi
}

preflight_tree() {
  local local_root="$1"
  local oversized=()
  while IFS= read -r -d '' file; do
    local size
    size="$(file_size_bytes "$file")"
    if (( size > MAX_WRANGLER_OBJECT_BYTES )); then
      oversized+=("$file")
    fi
  done < <(find "$local_root" -type f -print0)

  if (( ${#oversized[@]} > 0 )) && [[ "${SKIP_LARGE_OBJECTS:-0}" != "1" ]]; then
    echo "Wrangler remote object uploads are limited to 300 MiB." >&2
    echo "Upload these files through R2 multipart upload, then rerun with SKIP_LARGE_OBJECTS=1:" >&2
    printf '  %s\n' "${oversized[@]}" >&2
    exit 1
  fi
}

put_object() {
  local local_path="$1"
  local object_key="$2"
  local content_type="application/octet-stream"
  local size
  size="$(file_size_bytes "$local_path")"
  if (( size > MAX_WRANGLER_OBJECT_BYTES )); then
    if [[ "${SKIP_LARGE_OBJECTS:-0}" == "1" ]]; then
      echo "Skipping large object that requires multipart upload: $object_key" >&2
      return 0
    fi
    echo "Object exceeds Wrangler remote upload limit: $local_path" >&2
    exit 1
  fi

  local lower_path
  lower_path="$(printf '%s' "$local_path" | tr '[:upper:]' '[:lower:]')"
  if [[ "$lower_path" == *.json || "$lower_path" == *.json.sig ]]; then
    content_type="application/json; charset=utf-8"
  fi

  yarn wrangler r2 object put "$BUCKET/$object_key" \
    --file "$local_path" \
    --content-type "$content_type" \
    --remote
}

put_tree() {
  local local_root="$1"
  local component="$2"
  find "$local_root" -type f -print0 | while IFS= read -r -d '' file; do
    local relative="${file#"$local_root"/}"
    put_object "$file" "$PREFIX/releases/$MODEL_ID/$VERSION/$component/$relative"
  done
}

cd "$WORKER_DIR"
preflight_tree "$MODEL_DIR"
preflight_tree "$TOKENIZER_DIR"
put_tree "$MODEL_DIR" "model"
put_tree "$TOKENIZER_DIR" "tokenizer"
put_object "$MANIFEST" "$PREFIX/manifests/$MODEL_ID@$VERSION.json"
put_object "$MANIFEST_SIGNATURE" "$PREFIX/manifests/$MODEL_ID@$VERSION.json.sig"
put_object "$CURRENT_MANIFEST" "$PREFIX/manifests/current.json"
put_object "$CURRENT_MANIFEST_SIGNATURE" "$PREFIX/manifests/current.json.sig"
