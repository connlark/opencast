#!/usr/bin/env python3
"""Media container server: probe and frame-valid MP3 chunking only.

Runs inside the no-internet Container. The only egress is plain HTTP to
`r2.internal`, which the controlling Worker translates into private R2
bucket calls scoped to the job scratch prefixes. No model, no customer
route, no other network.

The preferred chunk contract is the immutable bakeoff contract (see
scripts/remote-transcription-bakeoff/make_chunks.py): ffmpeg input-side time
seek plus MP3 stream copy on valid packet/frame boundaries, 300 s requested
chunks, 2 s overlap, 298 s step, metadata stripped, bitexact, no Xing/ID3.
Chunks above the proven model-input envelope are deterministically normalized
to the pinned speech profile before upload.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import signal
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
from decimal import Decimal
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

# Overridable only for the local podman harness; in production the Worker's
# outbound handler intercepts the plain hostname.
R2_BASE = os.environ.get("R2_BASE", "http://r2.internal")
PORT = 8080
MAX_SOURCE_BYTES = 512 * 1024 * 1024
STREAM_COPY_PROFILE = "mp3-stream-copy-v1"
NORMALIZED_PROFILE = "mp3-cbr-128k-mono-44100-v1"
MIXED_PROFILE = "mp3-mixed-stream-copy-and-cbr-128k-mono-44100-v1"

# Deadlines are deliberately generous — legitimate media runs long (hours of
# audio up to the 512 MiB source cap) and the budgets exist to convert a hung
# socket or wedged subprocess into a clean MediaError, never to police real
# work. subprocess.run kills the child on expiry and every op runs inside a
# TemporaryDirectory, so a timeout leaves no stray process or temp file.
URLOPEN_TIMEOUT_SECONDS = 60.0  # socket connect/read inactivity
DOWNLOAD_DEADLINE_SECONDS = 1800.0  # wall clock for a full 512 MiB source
FFPROBE_TIMEOUT_SECONDS = 300.0
FFMPEG_TIMEOUT_SECONDS = 900.0  # per invocation (one ~300 s window each)


class MediaError(Exception):
    def __init__(self, status: int, code: str):
        super().__init__(code)
        self.status = status
        self.code = code


def quantized(value: float | str) -> float:
    return float(Decimal(str(value)).quantize(Decimal("0.001")))


def timeout_shaped(error: urllib.error.URLError) -> bool:
    return isinstance(getattr(error, "reason", None), TimeoutError)


def download_source(source_key: str, destination: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    total = 0
    deadline = time.monotonic() + DOWNLOAD_DEADLINE_SECONDS
    expected_length: int | None = None
    try:
        with urllib.request.urlopen(
            f"{R2_BASE}/{source_key}", timeout=URLOPEN_TIMEOUT_SECONDS
        ) as response, destination.open("wb") as out:
            # The R2 outbound handler sets content-length from object.size, so
            # a short read is a truncation, not the object's true length.
            # CPython's bounded read() returns b"" on a premature EOF without
            # raising, so without this check the truncated prefix's hash/count
            # would be returned as the object identity and terminally blame a
            # healthy device (source/upload identity mismatch).
            content_length = response.headers.get("content-length")
            if content_length is not None:
                try:
                    expected_length = int(content_length)
                except ValueError:
                    expected_length = None
            while True:
                if time.monotonic() > deadline:
                    raise MediaError(504, "source_download_timeout")
                block = response.read(1024 * 1024)
                if not block:
                    break
                digest.update(block)
                total += len(block)
                if total > MAX_SOURCE_BYTES:
                    raise MediaError(413, "source_too_large")
                out.write(block)
    except TimeoutError as error:
        raise MediaError(504, "source_download_timeout") from error
    except urllib.error.URLError as error:
        if timeout_shaped(error):
            raise MediaError(504, "source_download_timeout") from error
        raise
    if total == 0:
        raise MediaError(404, "source_missing")
    if expected_length is not None and total != expected_length:
        # 502 (not 4xx) so the gateway classifies it Retryable and re-fetches
        # rather than terminally failing the job (TMW-1).
        raise MediaError(502, "source_truncated")
    return digest.hexdigest(), total


def upload(key: str, path: Path) -> None:
    request = urllib.request.Request(
        f"{R2_BASE}/{key}",
        data=path.read_bytes(),
        method="PUT",
        headers={"content-type": "application/octet-stream"},
    )
    try:
        with urllib.request.urlopen(request, timeout=URLOPEN_TIMEOUT_SECONDS) as response:
            if response.status != 200:
                raise MediaError(502, "chunk_upload_failed")
    except TimeoutError as error:
        raise MediaError(504, "chunk_upload_timeout") from error
    except urllib.error.URLError as error:
        if timeout_shaped(error):
            raise MediaError(504, "chunk_upload_timeout") from error
        raise


def ffprobe(path: Path) -> dict:
    try:
        completed = subprocess.run(
            [
                "ffprobe", "-hide_banner", "-loglevel", "error",
                # Local file only: the input is always a temp path, so pin the
                # protocol allow-list to `file`. This forecloses ffmpeg's
                # remote/playlist protocol surface on untrusted media even
                # though the container also runs with no internet (TMW-4a).
                "-protocol_whitelist", "file",
                "-show_format", "-show_streams", "-of", "json", str(path),
            ],
            capture_output=True,
            text=True,
            timeout=FFPROBE_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as error:
        raise MediaError(504, "probe_timeout") from error
    if completed.returncode != 0:
        raise MediaError(422, "probe_failed")
    return json.loads(completed.stdout)


def measured_audio_duration(path: Path) -> float:
    """Demux-level duration of the first audio stream: the sum of its packet
    durations.

    Chunks are written without Xing headers (bitexact bakeoff contract), so
    ffprobe's format.duration falls back to a filesize/bitrate estimate that
    is off by up to ±10% on VBR media — enough to trip the gateway's chunk
    coverage validation (2026-08-04 short-episode bug) and to misplace
    stitch intervals. Packet enumeration reads every frame header without
    decoding and is exact.
    """
    try:
        completed = subprocess.run(
            [
                "ffprobe", "-hide_banner", "-loglevel", "error",
                "-protocol_whitelist", "file",
                "-select_streams", "a:0",
                "-show_entries", "packet=duration_time",
                "-of", "csv=p=0", str(path),
            ],
            capture_output=True,
            text=True,
            timeout=FFPROBE_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as error:
        raise MediaError(504, "probe_timeout") from error
    if completed.returncode != 0:
        raise MediaError(422, "probe_failed")
    total = 0.0
    counted = False
    for token in completed.stdout.split():
        value = token.strip().rstrip(",")
        if not value or value == "N/A":
            continue
        try:
            total += float(value)
        except ValueError:
            continue
        counted = True
    if not counted or total <= 0.0:
        raise MediaError(422, "probe_failed")
    return total


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
    try:
        completed = subprocess.run(
            [
                "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                "-protocol_whitelist", "file",
                "-ss", f"{start:.3f}", "-i", str(source), "-t", f"{duration:.3f}",
                "-map", "0:a:0", "-vn", "-c:a", "copy",
                "-map_metadata", "-1", "-map_chapters", "-1",
                "-fflags", "+bitexact", "-write_xing", "0", "-id3v2_version", "0",
                str(out),
            ],
            capture_output=True,
            text=True,
            timeout=FFMPEG_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as error:
        raise MediaError(504, "chunk_extraction_timeout") from error
    if completed.returncode != 0 or not out.exists():
        raise MediaError(422, "chunk_extraction_failed")


def normalize_chunk(source: Path, out: Path, start: float, duration: float) -> None:
    try:
        completed = subprocess.run(
            [
                "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                "-protocol_whitelist", "file",
                "-ss", f"{start:.3f}", "-i", str(source), "-t", f"{duration:.3f}",
                "-map", "0:a:0", "-vn", "-ac", "1", "-ar", "44100",
                "-c:a", "libmp3lame", "-b:a", "128k",
                "-map_metadata", "-1", "-map_chapters", "-1",
                "-fflags", "+bitexact", "-write_xing", "0", "-id3v2_version", "0",
                str(out),
            ],
            capture_output=True,
            text=True,
            timeout=FFMPEG_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as error:
        raise MediaError(504, "chunk_normalization_timeout") from error
    if completed.returncode != 0 or not out.exists():
        # Probe and stream-copy already established that this is readable MP3.
        # A missing encoder or a failed re-encode is service infrastructure,
        # not an unsupported customer media format.
        raise MediaError(500, "chunk_normalization_failed")


def extract_bounded_chunk(
    source: Path,
    out: Path,
    start: float,
    duration: float,
    max_chunk_raw_bytes: int,
) -> str:
    extract_chunk(source, out, start, duration)
    if 0 < out.stat().st_size <= max_chunk_raw_bytes:
        return STREAM_COPY_PROFILE

    out.unlink(missing_ok=True)
    normalize_chunk(source, out, start, duration)
    if out.stat().st_size <= 0 or out.stat().st_size > max_chunk_raw_bytes:
        out.unlink(missing_ok=True)
        raise MediaError(413, "normalized_chunk_too_large")
    return NORMALIZED_PROFILE


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
        audio_profiles = set()
        start = 0.0
        index = 0
        while start < duration:
            out = workpath / f"chunk-{index:04d}.mp3"
            audio_profiles.add(extract_bounded_chunk(
                source,
                out,
                quantized(start),
                quantized(chunk_seconds),
                max_chunk_raw_bytes,
            ))
            byte_count = out.stat().st_size
            actual_duration = measured_audio_duration(out)
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

        if audio_profiles == {STREAM_COPY_PROFILE}:
            profile = STREAM_COPY_PROFILE
        elif audio_profiles == {NORMALIZED_PROFILE}:
            profile = NORMALIZED_PROFILE
        else:
            profile = MIXED_PROFILE
        return {
            "chunks": chunks,
            "manifest_sha256": manifest_hasher.hexdigest(),
            "chunk_audio_profile": profile,
        }


class Handler(BaseHTTPRequestHandler):
    server_version = "OpenCastMedia/1"

    def do_POST(self):  # noqa: N802 (stdlib naming)
        try:
            # The framing read is inside the try so a missing/non-numeric
            # content-length (e.g. chunked encoding) becomes a clean 400
            # instead of a KeyError-driven generic 500 (or, for a non-numeric
            # header, no response at all).
            raw_length = self.headers.get("content-length")
            if raw_length is None:
                raise MediaError(400, "content_length_required")
            try:
                length = int(raw_length)
            except ValueError as error:
                raise MediaError(400, "invalid_content_length") from error
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


def serve() -> None:
    server = HTTPServer(("0.0.0.0", PORT), Handler)

    # This process is PID 1, and the kernel applies no default signal
    # disposition to PID 1: without an explicit handler SIGTERM is discarded.
    # The Container SDK's `sleepAfter` stop is exactly that signal, so an
    # unhandled SIGTERM means the instance never sleeps and bills until
    # something SIGKILLs it. `shutdown` must run off the serving thread —
    # calling it from the handler (which interrupts `serve_forever`)
    # deadlocks.
    def request_shutdown(signum: int, _frame: object) -> None:
        del signum
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, request_shutdown)
    signal.signal(signal.SIGINT, request_shutdown)
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    serve()
