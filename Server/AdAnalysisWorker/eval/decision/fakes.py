"""Test helpers: synthetic requests with SPARSE ids (never id arithmetic)."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path


def request(durations, *, ids=None, texts=None, title="Show", episode="Episode", gap=0.0, audio=None):
    ids = ids or [7 + 10 * i for i in range(len(durations))]
    segments, t = [], 0.0
    for n, (sid, d) in enumerate(zip(ids, durations)):
        text = texts[n] if texts else f"segment {n} words here for the test number {n} please"
        segments.append({"id": sid, "start": round(t, 3), "end": round(t + d, 3), "text": text})
        t += d + gap
    return {
        "schema_version": 1,
        "request_id": "fake",
        "episode_id": "fake-episode",
        "podcast_id": "fake-podcast",
        "episode_title": episode,
        "podcast_title": title,
        "transcript": {
            "language_code": "en",
            "audio_duration": audio if audio is not None else round(t, 3),
            "fingerprint": "fake",
            "updated_at": "2026-10-17T00:00:00Z",
            "state": "completed",
            "segment_count": len(segments),
        },
        "segments": segments,
    }


def manifest(directory, fixtures):
    """Write a manifest + request files; fixtures = [(name, request, truth)]."""
    directory = Path(directory)
    (directory / "requests").mkdir(parents=True, exist_ok=True)
    entries = []
    for name, req, truth in fixtures:
        path = directory / "requests" / f"{name}.json"
        path.write_text(json.dumps(req))
        entries.append({
            "name": name,
            "request": f"requests/{name}.json",
            "request_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "ground_truth": truth,
        })
    target = directory / "manifest.json"
    target.write_text(json.dumps({"fixtures": entries}))
    return target
