#!/usr/bin/env python3
"""Generate committed golden fixtures for the remote stitch contract.

The normal manifest/results mode emits the full self-owned bakeoff fixture.
The input-fixture mode regenerates an embedded fixture without repeating model
inference. The debug-results mode extracts only exact words intersecting seam
windows from preserved R2 model responses, keeping operational transcript
content outside the repository while pinning observed seam regressions.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from functools import cache
from pathlib import Path

from evaluate import normalized_tokens


PIPELINE_VERSION = "stitch-v2"
DEDUPE_EPSILON_SECONDS = 0.9


def normalized_transcript_sha256(text: str) -> str:
    return hashlib.sha256(" ".join(normalized_tokens(text)).encode("utf-8")).hexdigest()


def native_chunk_payload(payload: dict) -> dict:
    """Return chunk-local segments in the worker's persisted response shape."""
    result = payload.get("result", payload)
    segments = result.get("segments")
    if not isinstance(segments, list):
        raise SystemExit("expected segments[].words in the Workers AI response")
    out_segments = []
    for segment in segments:
        words = [
            {
                "text": str(word.get("word", word.get("text", ""))).strip(),
                "start": float(word["start"]),
                "end": float(word["end"]),
            }
            for word in segment.get("words", [])
        ]
        out_segments.append(
            {
                "start": float(segment["start"]),
                "end": float(segment["end"]),
                "text": str(segment.get("text", "")).strip(),
                "words": words,
            }
        )
    return {"segments": out_segments}


def midpoint(word: dict) -> float:
    return (word["start"] + word["end"]) / 2


def interval_gap(left: dict, right: dict) -> float:
    return max(right["start"] - left["end"], left["start"] - right["end"], 0.0)


def normalized_word_text(word: dict) -> str:
    return " ".join(normalized_tokens(word["text"]))


def seam_word_refs(
    chunk: dict,
    chunk_position: int,
    window_start: float,
    window_end: float,
) -> list[dict]:
    offset = chunk["requested_start_seconds"]
    refs = []
    for segment_index, segment in enumerate(chunk["response"]["segments"]):
        for word_index, local_word in enumerate(segment["words"]):
            word = {
                "text": local_word["text"],
                "start": local_word["start"] + offset,
                "end": local_word["end"] + offset,
            }
            if word["end"] < window_start or word["start"] > window_end:
                continue
            refs.append(
                {
                    "location": (chunk_position, segment_index, word_index),
                    "word": word,
                    "normalized": normalized_word_text(word),
                    "midpoint": midpoint(word),
                }
            )
    return refs


def ordered_matches(left: list[dict], right: list[dict]) -> tuple[tuple[int, int], ...]:
    """Maximum-cardinality, minimum-skew monotonic word alignment."""

    def can_match(left_ref: dict, right_ref: dict) -> bool:
        return (
            bool(left_ref["normalized"])
            and left_ref["normalized"] == right_ref["normalized"]
            and abs(left_ref["midpoint"] - right_ref["midpoint"])
            <= DEDUPE_EPSILON_SECONDS
            and interval_gap(left_ref["word"], right_ref["word"])
            <= DEDUPE_EPSILON_SECONDS
        )

    @cache
    def align(left_index: int, right_index: int) -> tuple[int, float, tuple[tuple[int, int], ...]]:
        if left_index == len(left) or right_index == len(right):
            return 0, 0.0, ()

        options = []
        if can_match(left[left_index], right[right_index]):
            matches, cost, pairs = align(left_index + 1, right_index + 1)
            options.append(
                (
                    matches + 1,
                    cost + abs(left[left_index]["midpoint"] - right[right_index]["midpoint"]),
                    ((left_index, right_index),) + pairs,
                )
            )
        options.append(align(left_index + 1, right_index))
        options.append(align(left_index, right_index + 1))

        best = options[0]
        for candidate in options[1:]:
            if candidate[0] > best[0] or (
                candidate[0] == best[0] and candidate[1] < best[1]
            ):
                best = candidate
        return best

    return align(0, 0)[2]


def seam_duplicate_drops(chunks: list[dict], overlap_seconds: float) -> set[tuple[int, int, int]]:
    drops: set[tuple[int, int, int]] = set()
    for left_position, (left_chunk, right_chunk) in enumerate(zip(chunks, chunks[1:])):
        seam_start = right_chunk["requested_start_seconds"]
        seam_end = seam_start + overlap_seconds
        boundary = seam_start + overlap_seconds / 2
        left = seam_word_refs(left_chunk, left_position, seam_start, seam_end)
        right = seam_word_refs(right_chunk, left_position + 1, seam_start, seam_end)
        for left_index, right_index in ordered_matches(left, right):
            left_ref = left[left_index]
            right_ref = right[right_index]
            left_is_owned = left_ref["midpoint"] < boundary
            right_is_owned = right_ref["midpoint"] >= boundary
            if not (left_is_owned and right_is_owned):
                continue
            consensus_midpoint = (left_ref["midpoint"] + right_ref["midpoint"]) / 2
            drops.add(
                right_ref["location"]
                if consensus_midpoint < boundary
                else left_ref["location"]
            )
    return drops


def stitch(
    chunks: list[dict], overlap_seconds: float
) -> tuple[list[dict], list[dict], int]:
    """Apply stitch-v2 ownership, seam dedupe, and monotonic repair."""
    boundaries = [
        chunk["requested_start_seconds"] + overlap_seconds / 2 for chunk in chunks[1:]
    ]
    duplicate_drops = seam_duplicate_drops(chunks, overlap_seconds)
    owned_segments: list[dict] = []
    previous_start: float | None = None

    for chunk_position, chunk in enumerate(chunks):
        lower = boundaries[chunk_position - 1] if chunk_position > 0 else None
        upper = boundaries[chunk_position] if chunk_position < len(boundaries) else None
        offset = chunk["requested_start_seconds"]
        for segment_index, local_segment in enumerate(chunk["response"]["segments"]):
            owned = []
            for word_index, local_word in enumerate(local_segment["words"]):
                word = {
                    "text": local_word["text"].strip(),
                    "start": local_word["start"] + offset,
                    "end": local_word["end"] + offset,
                }
                word_midpoint = midpoint(word)
                if lower is not None and word_midpoint < lower:
                    continue
                if upper is not None and word_midpoint >= upper:
                    continue
                if (chunk_position, segment_index, word_index) in duplicate_drops:
                    continue
                if previous_start is not None and word["start"] + 0.001 < previous_start:
                    if previous_start - word["start"] > overlap_seconds:
                        raise SystemExit("golden input contains a backward jump beyond the overlap")
                    word["start"] = previous_start
                    word["end"] = max(word["end"], word["start"])
                previous_start = word["start"]
                owned.append(word)
            if not owned:
                continue
            owned_segments.append(
                {
                    "chunk_index": chunk["index"],
                    "start": max(local_segment["start"] + offset, owned[0]["start"]),
                    "end": owned[-1]["end"],
                    "text": " ".join(word["text"] for word in owned),
                    "words": owned,
                }
            )

    stitched_segments = [
        {"id": new_id, **segment} for new_id, segment in enumerate(owned_segments)
    ]
    all_words = [word for segment in stitched_segments for word in segment["words"]]
    seams = []
    for boundary_index, boundary in enumerate(boundaries):
        left_words = [word for word in all_words if midpoint(word) < boundary]
        right_words = [word for word in all_words if midpoint(word) >= boundary]
        left_end = left_words[-1]["end"] if left_words else None
        right_start = right_words[0]["start"] if right_words else None
        seams.append(
            {
                "after_chunk_index": boundary_index,
                "before_chunk_index": boundary_index + 1,
                "overlap_start_seconds": boundary - overlap_seconds / 2,
                "ownership_boundary_seconds": boundary,
                "left_word_end_seconds": left_end,
                "right_word_start_seconds": right_start,
                "boundary_gap_seconds": (right_start - left_end)
                if left_end is not None and right_start is not None
                else None,
                "left_kept_word_count": len(left_words),
                "right_kept_word_count": len(right_words),
            }
        )
    return stitched_segments, seams, len(duplicate_drops)


def finalize_fixture(fixture: dict) -> dict:
    fixture["schema_version"] = 2
    contract = fixture["contract"]
    contract["ownership"] = "native-word timestamp-midpoint at seam start + overlap/2"
    contract["seam_dedupe"] = (
        "ordered one-to-one normalized-word match inside overlap; interval gap and midpoint "
        "skew <= epsilon; retain the chunk owning the copies' consensus midpoint"
    )
    contract["dedupe_epsilon_seconds"] = DEDUPE_EPSILON_SECONDS
    contract["pipeline_version"] = PIPELINE_VERSION
    contract["normalization"] = (
        "lowercase; strip [\\u2018\\u2019']; collapse (\\d),(\\d); "
        "non-[a-z0-9 ] to space; split on whitespace; join with single spaces"
    )
    segments, seams, deduplicated_word_count = stitch(
        fixture["chunks"], float(contract["overlap_seconds"])
    )
    stitched_text = " ".join(
        word["text"] for segment in segments for word in segment["words"]
    )
    fixture["expected"] = {
        "segments": segments,
        "seams": seams,
        "stitched_word_count": sum(len(segment["words"]) for segment in segments),
        "deduplicated_word_count": deduplicated_word_count,
        "normalized_transcript_sha256": normalized_transcript_sha256(stitched_text),
    }
    return fixture


def fixture_from_manifest(manifest_path: Path, results_dir: Path) -> dict:
    manifest = json.loads(manifest_path.read_text())
    chunking = manifest["chunking"]
    source = manifest["source"]
    chunks = []
    for entry in sorted(manifest["chunks"], key=lambda chunk: chunk["index"]):
        response_path = results_dir / f"chunk-{entry['index']:04d}.json"
        chunks.append(
            {
                "index": entry["index"],
                "requested_start_seconds": float(entry["requestedStartSeconds"]),
                "requested_duration_seconds": float(entry["requestedDurationSeconds"]),
                "actual_duration_seconds": float(entry["actualDurationSeconds"]),
                "byte_count": entry["byteCount"],
                "sha256": entry["sha256"],
                "response": native_chunk_payload(json.loads(response_path.read_text())),
            }
        )
    return finalize_fixture(
        {
            "contract": {
                "chunk_seconds": float(chunking["chunkSeconds"]),
                "overlap_seconds": float(chunking["overlapSeconds"]),
                "step_seconds": float(chunking["stepSeconds"]),
            },
            "source": {
                "file_name": source["fileName"],
                "sha256": source["sha256"],
                "byte_count": source["byteCount"],
                "duration_seconds": source["durationSeconds"],
            },
            "model": "@cf/openai/whisper-large-v3-turbo",
            "chunks": chunks,
        }
    )


def filtered_debug_payload(
    payload: dict,
    chunk_index: int,
    chunk_count: int,
    step_seconds: float,
    overlap_seconds: float,
) -> dict:
    response = native_chunk_payload(payload)
    windows = []
    if chunk_index > 0:
        windows.append((0.0, overlap_seconds))
    if chunk_index + 1 < chunk_count:
        windows.append((step_seconds, step_seconds + overlap_seconds))
    segments = []
    for segment in response["segments"]:
        words = [
            word
            for word in segment["words"]
            if any(word["end"] >= start and word["start"] <= end for start, end in windows)
        ]
        if not words:
            continue
        segments.append(
            {
                "start": max(segment["start"], words[0]["start"]),
                "end": words[-1]["end"],
                "text": " ".join(word["text"] for word in words),
                "words": words,
            }
        )
    return {"segments": segments}


def fixture_from_debug_results(results_dir: Path, job_id: str) -> dict:
    response_paths = sorted(
        (path for path in results_dir.glob("*.json") if path.stem.isdigit()),
        key=lambda path: int(path.stem),
    )
    if not response_paths or [int(path.stem) for path in response_paths] != list(
        range(len(response_paths))
    ):
        raise SystemExit("debug results must be contiguous <index>.json files starting at zero")
    chunk_seconds = 300.0
    overlap_seconds = 2.0
    step_seconds = chunk_seconds - overlap_seconds
    chunks = []
    for path in response_paths:
        index = int(path.stem)
        raw = path.read_bytes()
        payload = json.loads(raw)
        chunks.append(
            {
                "index": index,
                "requested_start_seconds": index * step_seconds,
                "raw_response_sha256": hashlib.sha256(raw).hexdigest(),
                "response": filtered_debug_payload(
                    payload,
                    index,
                    len(response_paths),
                    step_seconds,
                    overlap_seconds,
                ),
            }
        )
    return finalize_fixture(
        {
            "contract": {
                "chunk_seconds": chunk_seconds,
                "overlap_seconds": overlap_seconds,
                "step_seconds": step_seconds,
            },
            "source": {
                "debug_job_id": job_id,
                "r2_prefix": f"debug/{job_id}/",
                "response_count": len(response_paths),
                "scope": "exact model words intersecting the job's overlap windows",
            },
            "model": "@cf/openai/whisper-large-v3-turbo",
            "chunks": chunks,
        }
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sources = parser.add_mutually_exclusive_group(required=True)
    sources.add_argument("--manifest", type=Path)
    sources.add_argument("--input-fixture", type=Path)
    sources.add_argument("--debug-results-dir", type=Path)
    parser.add_argument("--results-dir", type=Path)
    parser.add_argument("--debug-job-id")
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()

    if arguments.manifest:
        if arguments.results_dir is None:
            parser.error("--manifest requires --results-dir")
        fixture = fixture_from_manifest(arguments.manifest, arguments.results_dir)
    elif arguments.input_fixture:
        fixture = finalize_fixture(json.loads(arguments.input_fixture.read_text()))
    else:
        if not arguments.debug_job_id:
            parser.error("--debug-results-dir requires --debug-job-id")
        fixture = fixture_from_debug_results(
            arguments.debug_results_dir, arguments.debug_job_id
        )

    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(fixture, separators=(",", ":"), allow_nan=False))
    print(
        f"wrote {arguments.output} chunks={len(fixture['chunks'])} "
        f"segments={len(fixture['expected']['segments'])} "
        f"words={fixture['expected']['stitched_word_count']} "
        f"deduped={fixture['expected']['deduplicated_word_count']} "
        f"normalized_sha={fixture['expected']['normalized_transcript_sha256']}"
    )


if __name__ == "__main__":
    main()
