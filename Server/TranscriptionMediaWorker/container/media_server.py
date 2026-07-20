#!/usr/bin/env python3
"""Media container server: probe and frame-valid MP3 chunking only.

Runs inside the no-internet Container. The only egress is plain HTTP to
`r2.internal`, which the controlling Worker translates into private R2
bucket calls scoped to the job scratch prefixes. No model, no customer
route, no other network.

The chunk contract is the immutable bakeoff contract (see
scripts/remote-transcription-bakeoff/make_chunks.py): ffmpeg input-side time
seek plus MP3 stream copy on valid packet/frame boundaries, 300 s requested
chunks, 2 s overlap, 298 s step, metadata stripped, bitexact, no Xing/ID3.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import urllib.request
from decimal import Decimal
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

# Overridable only for the local podman harness; in production the Worker's
# outbound handler intercepts the plain hostname.
R2_BASE = os.environ.get("R2_BASE", "http://r2.internal")
PORT = 8080
MAX_SOURCE_BYTES = 512 * 1024 * 1024


class MediaError(Exception):
    def __init__(self, status: int, code: str):
        super().__init__(code)
        self.status = status
        self.code = code


def quantized(value: float | str) -> float:
    return float(Decimal(str(value)).quantize(Decimal("0.001")))


def download_source(source_key: str, destination: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    total = 0
    with urllib.request.urlopen(f"{R2_BASE}/{source_key}") as response, destination.open("wb") as out:
        while True:
            block = response.read(1024 * 1024)
            if not block:
                break
            digest.update(block)
            total += len(block)
            if total > MAX_SOURCE_BYTES:
                raise MediaError(413, "source_too_large")
            out.write(block)
    if total == 0:
        raise MediaError(404, "source_missing")
    return digest.hexdigest(), total


def upload(key: str, path: Path) -> None:
    request = urllib.request.Request(
        f"{R2_BASE}/{key}",
        data=path.read_bytes(),
        method="PUT",
        headers={"content-type": "application/octet-stream"},
    )
    with urllib.request.urlopen(request) as response:
        if response.status != 200:
            raise MediaError(502, "chunk_upload_failed")


def ffprobe(path: Path) -> dict:
    completed = subprocess.run(
        [
            "ffprobe", "-hide_banner", "-loglevel", "error",
            "-show_format", "-show_streams", "-of", "json", str(path),
        ],
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise MediaError(422, "probe_failed")
    return json.loads(completed.stdout)


def probe(payload: dict) -> dict:
    source_key = payload["source_key"]
    with tempfile.TemporaryDirectory(prefix="opencast-media-") as workdir:
        source = Path(workdir) / "source"
        sha256, byte_count = download_source(source_key, source)
        info = ffprobe(source)
        audio_streams = [
            stream for stream in info.get("streams", [])
            if stream.get("codec_type") == "audio"
        ]
        if not audio_streams:
            raise MediaError(422, "unsupported_media_type")
        duration = float(info.get("format", {}).get("duration", 0.0))
        return {
            "duration_seconds": quantized(duration),
            "codec": audio_streams[0].get("codec_name", "unknown"),
            "audio_stream_count": len(audio_streams),
            "byte_count": byte_count,
            "sha256": sha256,
        }


def extract_chunk(source: Path, out: Path, start: float, duration: float) -> None:
    # Exact bakeoff command: input-side time seek + MP3 stream copy on valid
    # packet/frame boundaries, metadata stripped, deterministic output.
    completed = subprocess.run(
        [
            "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-ss", f"{start:.3f}", "-i", str(source), "-t", f"{duration:.3f}",
            "-map", "0:a:0", "-vn", "-c:a", "copy",
            "-map_metadata", "-1", "-map_chapters", "-1",
            "-fflags", "+bitexact", "-write_xing", "0", "-id3v2_version", "0",
            str(out),
        ],
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0 or not out.exists():
        raise MediaError(422, "chunk_extraction_failed")


def chunk(payload: dict) -> dict:
    source_key = payload["source_key"]
    chunk_prefix = payload["chunk_prefix"]
    chunk_seconds = float(payload.get("chunk_seconds", 300.0))
    overlap_seconds = float(payload.get("overlap_seconds", 2.0))
    max_chunk_raw_bytes = int(payload.get("max_chunk_raw_bytes", 5 * 1024 * 1024))
    step_seconds = chunk_seconds - overlap_seconds
    if step_seconds <= 0:
        raise MediaError(400, "invalid_chunk_contract")

    with tempfile.TemporaryDirectory(prefix="opencast-media-") as workdir:
        workpath = Path(workdir)
        source = workpath / "source"
        _, _ = download_source(source_key, source)
        info = ffprobe(source)
        duration = float(info.get("format", {}).get("duration", 0.0))
        if duration <= 0:
            raise MediaError(422, "probe_failed")

        chunks = []
        manifest_hasher = hashlib.sha256()
        start = 0.0
        index = 0
        while start < duration:
            out = workpath / f"chunk-{index:04d}.mp3"
            extract_chunk(source, out, quantized(start), quantized(chunk_seconds))
            byte_count = out.stat().st_size
            if byte_count <= 0:
                raise MediaError(422, "chunk_extraction_failed")
            if byte_count > max_chunk_raw_bytes:
                # Pass 0 rejects oversized stream-copy chunks to local
                # fallback rather than widening the proven AI envelope.
                raise MediaError(413, "chunk_too_large")
            chunk_info = ffprobe(out)
            actual_duration = float(chunk_info.get("format", {}).get("duration", 0.0))
            sha256 = hashlib.sha256(out.read_bytes()).hexdigest()
            key = f"{chunk_prefix}{index}.mp3"
            upload(key, out)
            out.unlink()
            manifest_hasher.update(sha256.encode("ascii"))
            chunks.append(
                {
                    "index": index,
                    "key": key,
                    "requested_start_seconds": quantized(start),
                    "requested_duration_seconds": quantized(chunk_seconds),
                    "actual_duration_seconds": quantized(actual_duration),
                    "byte_count": byte_count,
                    "sha256": sha256,
                }
            )
            index += 1
            start += step_seconds

        return {"chunks": chunks, "manifest_sha256": manifest_hasher.hexdigest()}


class Handler(BaseHTTPRequestHandler):
    server_version = "OpenCastMedia/1"

    def do_POST(self):  # noqa: N802 (stdlib naming)
        length = int(self.headers.get("content-length", "0"))
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
            if self.path == "/probe":
                body = probe(payload)
            elif self.path == "/chunk":
                body = chunk(payload)
            else:
                raise MediaError(404, "not_found")
            encoded = json.dumps(body).encode("utf-8")
            self.send_response(200)
        except MediaError as error:
            encoded = json.dumps({"error": error.code}).encode("utf-8")
            self.send_response(error.status)
        except Exception as error:  # noqa: BLE001 — fail closed
            # Detail carries only exception type/message; keys are random job
            # IDs, so no content identifiers can appear here.
            encoded = json.dumps({
                "error": "media_internal_error",
                "detail": f"{type(error).__name__}: {error}"[:200],
            }).encode("utf-8")
            self.send_response(500)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self):  # noqa: N802
        if self.path == "/health":
            body = json.dumps({
                "message": "ok",
                "ffmpeg": shutil.which("ffmpeg") is not None,
            }).encode("utf-8")
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()

    def log_message(self, format, *args):  # noqa: A002 — silence request logs
        pass


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
