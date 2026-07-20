#!/usr/bin/env python3
"""Create deterministic, frame-valid audio chunks and an audit manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
from decimal import Decimal
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def probe(path: Path) -> dict:
    completed = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            (
                "format=duration,size,bit_rate,format_name:"
                "stream=index,codec_name,codec_type,sample_rate,channels,"
                "channel_layout,bit_rate,start_time,duration"
            ),
            "-of",
            "json",
            str(path),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    payload = json.loads(completed.stdout)
    audio_streams = [
        stream for stream in payload.get("streams", []) if stream.get("codec_type") == "audio"
    ]
    if len(audio_streams) != 1:
        raise SystemExit(f"expected exactly one audio stream in {path}, found {len(audio_streams)}")
    return {"format": payload["format"], "audioStream": audio_streams[0]}


def decimal_text(value: Decimal) -> str:
    return f"{value.quantize(Decimal('0.001')):.3f}"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--chunk-seconds", type=Decimal, default=Decimal("300"))
    parser.add_argument("--overlap-seconds", type=Decimal, default=Decimal("2"))
    args = parser.parse_args()

    source = args.input.resolve(strict=True)
    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    if args.chunk_seconds <= 0:
        raise SystemExit("--chunk-seconds must be positive")
    if args.overlap_seconds < 0 or args.overlap_seconds >= args.chunk_seconds:
        raise SystemExit("--overlap-seconds must be nonnegative and smaller than the chunk length")

    source_probe = probe(source)
    source_duration = Decimal(source_probe["format"]["duration"])
    step = args.chunk_seconds - args.overlap_seconds
    chunks: list[dict] = []
    start = Decimal("0")
    index = 0
    while start < source_duration:
        requested_duration = min(args.chunk_seconds, source_duration - start)
        if requested_duration < Decimal("0.05"):
            break
        name = f"chunk-{index:04d}-start-{decimal_text(start).replace('.', '_')}.mp3"
        destination = output_dir / name
        command = [
            "ffmpeg",
            "-nostdin",
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-ss",
            decimal_text(start),
            "-i",
            str(source),
            "-t",
            decimal_text(requested_duration),
            "-map",
            "0:a:0",
            "-vn",
            "-c:a",
            "copy",
            "-map_metadata",
            "-1",
            "-map_chapters",
            "-1",
            "-fflags",
            "+bitexact",
            "-write_xing",
            "0",
            "-id3v2_version",
            "0",
            str(destination),
        ]
        subprocess.run(command, check=True)
        chunk_probe = probe(destination)
        chunks.append(
            {
                "index": index,
                "path": str(destination),
                "fileName": destination.name,
                "requestedStartSeconds": float(start),
                "requestedDurationSeconds": float(requested_duration),
                "actualDurationSeconds": float(chunk_probe["format"]["duration"]),
                "byteCount": destination.stat().st_size,
                "sha256": sha256(destination),
                "format": chunk_probe,
                "extractionCommand": command,
            }
        )
        index += 1
        start += step

    manifest = {
        "schemaVersion": 1,
        "source": {
            "path": str(source),
            "fileName": source.name,
            "byteCount": source.stat().st_size,
            "sha256": sha256(source),
            "durationSeconds": float(source_duration),
            "format": source_probe,
        },
        "chunking": {
            "chunkSeconds": float(args.chunk_seconds),
            "overlapSeconds": float(args.overlap_seconds),
            "stepSeconds": float(step),
            "boundaryMethod": "ffmpeg time seek plus MP3 stream copy on valid packet/frame boundaries",
        },
        "chunks": chunks,
    }
    manifest_path = output_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(
        f"wrote {manifest_path} chunks={len(chunks)} "
        f"source_sha256={manifest['source']['sha256']}"
    )


if __name__ == "__main__":
    main()
