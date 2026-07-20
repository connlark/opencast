#!/usr/bin/env python3
"""Evaluate and stitch timestamped remote-transcription bakeoff outputs.

The evaluator intentionally emits metrics and hashes, not transcript text. Raw
model responses and reconstructed transcripts stay in the caller's temporary
workspace.
"""

from __future__ import annotations

import argparse
import bisect
import hashlib
import json
import math
import re
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path


NEURONS_PER_AUDIO_MINUTE = {
    "@cf/openai/whisper": 41.14,
    "@cf/openai/whisper-large-v3-turbo": 46.63,
    "@cf/deepgram/nova-3": 472.73,
}
WORKERS_AI_DOLLARS_PER_THOUSAND_NEURONS = 0.011


@dataclass(frozen=True)
class Word:
    token: str
    start: float
    end: float

    @property
    def midpoint(self) -> float:
        return (self.start + self.end) / 2


def normalized_tokens(text: str) -> list[str]:
    text = text.lower()
    text = re.sub(r"[‘’']", "", text)
    text = re.sub(r"(\d),(\d)", r"\1\2", text)
    text = re.sub(r"[^a-z0-9 ]+", " ", text)
    return text.split()


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def expand_word(text: str, start: float, end: float) -> list[Word]:
    tokens = normalized_tokens(text)
    if not tokens:
        return []
    if not math.isfinite(start) or not math.isfinite(end):
        return []
    if end < start:
        start, end = end, start
    width = (end - start) / len(tokens)
    return [
        Word(token, start + width * index, start + width * (index + 1))
        for index, token in enumerate(tokens)
    ]


def document_words(document: dict) -> list[Word]:
    words: list[Word] = []
    for segment in document.get("segments", []):
        native_words = segment.get("words")
        if isinstance(native_words, list) and native_words:
            for word in native_words:
                words.extend(
                    expand_word(
                        str(word.get("word", "")),
                        float(word.get("start", 0)),
                        float(word.get("end", word.get("start", 0))),
                    )
                )
            continue
        segment_tokens = normalized_tokens(str(segment.get("text", "")))
        if not segment_tokens:
            continue
        start = float(segment.get("start", 0))
        end = float(segment.get("end", start))
        width = max(0.0, end - start) / len(segment_tokens)
        words.extend(
            Word(token, start + width * index, start + width * (index + 1))
            for index, token in enumerate(segment_tokens)
        )
    return words


def remote_word_objects(payload: dict) -> tuple[list[dict], int, str]:
    result = payload.get("result", {})
    if isinstance(result.get("words"), list):
        return result["words"], 0, "result.words"
    if isinstance(result.get("segments"), list):
        segments = result["segments"]
        return (
            [word for segment in segments for word in segment.get("words", [])],
            len(segments),
            "result.segments[].words",
        )
    try:
        alternatives = result["results"]["channels"][0]["alternatives"]
        words = alternatives[0]["words"]
        return words, 0, "result.results.channels[].alternatives[].words"
    except (KeyError, IndexError, TypeError):
        raise ValueError("unrecognized Workers AI transcription response") from None


def remote_chunk_words(payload: dict, offset: float) -> tuple[list[Word], int, str]:
    native_words, native_segment_count, word_path = remote_word_objects(payload)
    words: list[Word] = []
    for native in native_words:
        native_start = native.get("start")
        native_end = native.get("end")
        start = float(native_start) if native_start is not None else 0.0
        end = float(native_end) if native_end is not None else start
        words.extend(
            expand_word(
                str(native.get("word", native.get("punctuated_word", ""))),
                start + offset,
                end + offset,
            )
        )
    return words, native_segment_count, word_path


def percentile(values: list[float], proportion: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * proportion
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def round_optional(value: float | None, digits: int = 6) -> float | None:
    return round(value, digits) if value is not None else None


def wer(reference: list[str], hypothesis: list[str]) -> dict:
    if not reference:
        raise ValueError("empty WER reference")
    try:
        import numpy as np

        vocabulary = {word: index for index, word in enumerate(dict.fromkeys(reference + hypothesis))}
        ref = np.array([vocabulary[word] for word in reference], dtype=np.int32)
        hyp = np.array([vocabulary[word] for word in hypothesis], dtype=np.int32)
        columns = len(hyp)
        column_indexes = np.arange(1, columns + 1, dtype=np.int32)
        previous = np.arange(columns + 1, dtype=np.int32)
        current = np.empty_like(previous)
        shifted = np.empty(columns + 1, dtype=np.int32)
        for row in range(1, len(ref) + 1):
            candidates = np.minimum(
                previous[:-1] + (hyp != ref[row - 1]),
                previous[1:] + 1,
            )
            shifted[0] = row
            np.subtract(candidates, column_indexes, out=shifted[1:])
            np.minimum.accumulate(shifted, out=shifted)
            current[0] = row
            np.add(shifted[1:], column_indexes, out=current[1:])
            previous, current = current, previous
        distance = int(previous[-1])
    except ImportError:
        previous = list(range(len(hypothesis) + 1))
        for row, ref_word in enumerate(reference, 1):
            current = [row] + [0] * len(hypothesis)
            for column, hyp_word in enumerate(hypothesis, 1):
                current[column] = min(
                    previous[column] + 1,
                    current[column - 1] + 1,
                    previous[column - 1] + (ref_word != hyp_word),
                )
            previous = current
        distance = previous[-1]
    return {
        "editDistance": distance,
        "referenceWords": len(reference),
        "hypothesisWords": len(hypothesis),
        "wer": round(distance / len(reference), 6),
    }


def edit_breakdown(reference: list[str], hypothesis: list[str]) -> dict:
    rows = len(reference) + 1
    columns = len(hypothesis) + 1
    distances = [[0] * columns for _ in range(rows)]
    operations = [[""] * columns for _ in range(rows)]
    for row in range(1, rows):
        distances[row][0] = row
        operations[row][0] = "deletion"
    for column in range(1, columns):
        distances[0][column] = column
        operations[0][column] = "insertion"
    for row in range(1, rows):
        for column in range(1, columns):
            if reference[row - 1] == hypothesis[column - 1]:
                distances[row][column] = distances[row - 1][column - 1]
                operations[row][column] = "match"
                continue
            choices = (
                (distances[row - 1][column - 1] + 1, "substitution"),
                (distances[row - 1][column] + 1, "deletion"),
                (distances[row][column - 1] + 1, "insertion"),
            )
            distances[row][column], operations[row][column] = min(choices)
    counts = {"match": 0, "substitution": 0, "deletion": 0, "insertion": 0}
    row, column = len(reference), len(hypothesis)
    while row or column:
        operation = operations[row][column]
        counts[operation] += 1
        if operation in {"match", "substitution"}:
            row -= 1
            column -= 1
        elif operation == "deletion":
            row -= 1
        else:
            column -= 1
    counts["editDistance"] = distances[-1][-1]
    return counts


def repetition_screen(tokens: list[str], maximum_ngram: int = 5, minimum_repeats: int = 4) -> dict:
    findings: list[dict] = []
    for size in range(1, maximum_ngram + 1):
        best_run = 0
        best_index: int | None = None
        index = 0
        while index + size <= len(tokens):
            gram = tokens[index : index + size]
            run = 1
            cursor = index + size
            while cursor + size <= len(tokens) and tokens[cursor : cursor + size] == gram:
                run += 1
                cursor += size
            if run > best_run:
                best_run = run
                best_index = index
            index = index + size * run if run > 1 else index + 1
        if best_run >= minimum_repeats:
            findings.append({"n": size, "repeats": best_run, "atWordIndex": best_index})
    return {"clean": not findings, "loopFindings": findings}


def longest_common_contiguous(left: list[str], right: list[str]) -> int:
    if not left or not right:
        return 0
    previous = [0] * (len(right) + 1)
    longest = 0
    for left_word in left:
        current = [0] * (len(right) + 1)
        for index, right_word in enumerate(right, 1):
            if left_word == right_word:
                current[index] = previous[index - 1] + 1
                longest = max(longest, current[index])
        previous = current
    return longest


def suffix_prefix_duplicate(left: list[str], right: list[str], maximum: int = 16) -> int:
    for length in range(min(maximum, len(left), len(right)), 0, -1):
        if left[-length:] == right[:length]:
            return length
    return 0


def timestamp_health(words: list[Word], lower: float, upper: float) -> dict:
    invalid_ranges = sum(word.end < word.start for word in words)
    nonfinite = sum(not math.isfinite(word.start) or not math.isfinite(word.end) for word in words)
    reversals = sum(words[index].start + 0.001 < words[index - 1].start for index in range(1, len(words)))
    out_of_bounds = sum(word.start < lower - 0.25 or word.end > upper + 2 for word in words)
    return {
        "invalidRanges": invalid_ranges,
        "nonfiniteValues": nonfinite,
        "startOrderReversals": reversals,
        "outOfBoundsWords": out_of_bounds,
        "firstWordStartSeconds": round_optional(words[0].start if words else None),
        "lastWordEndSeconds": round_optional(words[-1].end if words else None),
    }


def stitch_chunks(chunks: list[tuple[dict, list[Word]]], overlap_seconds: float) -> tuple[list[Word], list[dict]]:
    stitched: list[Word] = []
    seams: list[dict] = []
    for index, (chunk, words) in enumerate(chunks):
        if index == 0:
            stitched = list(words)
            continue
        seam_start = float(chunk["requestedStartSeconds"])
        ownership_boundary = seam_start + overlap_seconds / 2
        independent_left = [word for word in stitched if seam_start - 8 <= word.midpoint <= seam_start + overlap_seconds + 8]
        independent_right = [word for word in words if seam_start - 0.25 <= word.midpoint <= seam_start + overlap_seconds + 8]
        cross_chunk_match = longest_common_contiguous(
            [word.token for word in independent_left],
            [word.token for word in independent_right],
        )
        left = [word for word in stitched if word.midpoint < ownership_boundary]
        right = [word for word in words if word.midpoint >= ownership_boundary]
        duplicate_words = suffix_prefix_duplicate(
            [word.token for word in left],
            [word.token for word in right],
        )
        left_end = left[-1].end if left else None
        right_start = right[0].start if right else None
        gap = right_start - left_end if left_end is not None and right_start is not None else None
        start_order_reversal = bool(
            left and right and right[0].start + 0.001 < left[-1].start
        )
        seam = {
            "afterChunkIndex": chunks[index - 1][0]["index"],
            "beforeChunkIndex": chunk["index"],
            "overlapStartSeconds": round(seam_start, 6),
            "ownershipBoundarySeconds": round(ownership_boundary, 6),
            "crossChunkLongestExactMatchWords": cross_chunk_match,
            "duplicateWordsAfterStitch": duplicate_words,
            "boundaryGapSeconds": round_optional(gap),
            "leftWordEndSeconds": round_optional(left_end),
            "rightWordStartSeconds": round_optional(right_start),
            "timestampStartOrderReversal": start_order_reversal,
        }
        seams.append(seam)
        stitched = left + right
    return stitched, seams


def enrich_seams(seams: list[dict], stitched: list[Word], truth: list[Word]) -> None:
    for seam in seams:
        boundary = seam["ownershipBoundarySeconds"]
        reference_window = [word.token for word in truth if boundary - 5 <= word.midpoint <= boundary + 5]
        candidate_window = [word.token for word in stitched if boundary - 5 <= word.midpoint <= boundary + 5]
        local_edits = edit_breakdown(reference_window, candidate_window)
        gap = seam["boundaryGapSeconds"]
        reference_words_in_gap = 0
        if gap is not None and gap > 0:
            reference_words_in_gap = sum(
                seam["leftWordEndSeconds"] <= word.midpoint <= seam["rightWordStartSeconds"]
                for word in truth
            )
        seam["tenSecondReferenceWords"] = len(reference_window)
        seam["tenSecondCandidateWords"] = len(candidate_window)
        seam["tenSecondAlignment"] = local_edits
        seam["referenceWordsInEstimatedBoundaryGap"] = reference_words_in_gap
        seam["omissionFlag"] = bool(gap is not None and gap > 1.5 and reference_words_in_gap > 0)
        seam["duplicateFlag"] = seam["duplicateWordsAfterStitch"] >= 3
        seam["discontinuityFlag"] = bool(
            seam["timestampStartOrderReversal"]
            or seam["omissionFlag"]
            or seam["duplicateFlag"]
        )


def timing_drift(reference: list[Word], hypothesis: list[Word]) -> dict:
    reference_index: dict[tuple[str, str, str], list[float]] = defaultdict(list)
    for index in range(len(reference) - 2):
        gram = tuple(word.token for word in reference[index : index + 3])
        reference_index[gram].append(reference[index + 1].midpoint)
    unique_reference = {gram: times[0] for gram, times in reference_index.items() if len(times) == 1}
    signed: list[float] = []
    for index in range(len(hypothesis) - 2):
        gram = tuple(word.token for word in hypothesis[index : index + 3])
        reference_time = unique_reference.get(gram)
        if reference_time is None:
            continue
        delta = hypothesis[index + 1].midpoint - reference_time
        if abs(delta) <= 15:
            signed.append(delta)
    absolute = [abs(value) for value in signed]
    return {
        "method": "unique normalized trigram anchors within 15 seconds",
        "anchorCount": len(signed),
        "signedMedianSeconds": round_optional(percentile(signed, 0.5)),
        "absoluteMedianSeconds": round_optional(percentile(absolute, 0.5)),
        "absoluteP95Seconds": round_optional(percentile(absolute, 0.95)),
        "absoluteMaximumSeconds": round_optional(max(absolute) if absolute else None),
    }


def transcript_metrics(words: list[Word], truth_words: list[Word], audio_duration: float) -> dict:
    tokens = [word.token for word in words]
    reference_tokens = [word.token for word in truth_words]
    normalized_sha = hashlib.sha256(" ".join(tokens).encode("utf-8")).hexdigest()
    return {
        "normalizedTranscriptSHA256": normalized_sha,
        "wordErrorRate": wer(reference_tokens, tokens),
        "repetition": repetition_screen(tokens),
        "timestampHealth": timestamp_health(words, 0, audio_duration),
        "timingDrift": timing_drift(truth_words, words),
    }


def evaluate_local(path: Path, truth_words: list[Word], source_sha: str, audio_duration: float) -> dict:
    document = json.loads(path.read_text())
    if document.get("sourceFileSHA256") != source_sha:
        raise ValueError(f"local baseline source hash does not match corpus: {path}")
    words = document_words(document)
    metrics = transcript_metrics(words, truth_words, audio_duration)
    metrics.update(
        {
            "artifactPath": str(path),
            "artifactSHA256": file_sha256(path),
            "modelIdentifier": document.get("modelIdentifier"),
            "modelVersion": document.get("modelVersion"),
            "modelTreeSHA256": document.get("modelTreeSHA256"),
            "nativeSegmentCount": len(document.get("segments", [])),
            "timings": document.get("timings", {}),
        }
    )
    return metrics


def evaluate_remote(
    run_path: Path,
    manifest: dict,
    truth_words: list[Word],
    local_wer: float,
    overlap_seconds: float,
) -> dict:
    run = json.loads(run_path.read_text())
    if run.get("sourceSHA256") != manifest["source"]["sha256"]:
        raise ValueError(f"run source hash does not match manifest: {run_path}")
    manifest_by_index = {chunk["index"]: chunk for chunk in manifest["chunks"]}
    chunks: list[tuple[dict, list[Word]]] = []
    native_segment_count = 0
    word_paths: set[str] = set()
    per_chunk_health: list[dict] = []
    for record in sorted(run["records"], key=lambda value: value["chunkIndex"]):
        if not record.get("success"):
            raise ValueError(f"failed request is not evaluable: {record['chunkIndex']}")
        chunk = manifest_by_index[record["chunkIndex"]]
        if record.get("chunkSHA256") != chunk["sha256"]:
            raise ValueError(f"chunk hash does not match manifest: {record['chunkIndex']}")
        raw_path = Path(record["rawOutputPath"])
        payload = json.loads(raw_path.read_text())
        words, segment_count, word_path = remote_chunk_words(
            payload,
            float(chunk["requestedStartSeconds"]),
        )
        native_segment_count += segment_count
        word_paths.add(word_path)
        lower = float(chunk["requestedStartSeconds"])
        upper = lower + float(chunk["actualDurationSeconds"])
        per_chunk_health.append(
            {
                "chunkIndex": chunk["index"],
                **timestamp_health(words, lower, upper),
            }
        )
        chunks.append((chunk, words))
    stitched, seams = stitch_chunks(chunks, overlap_seconds)
    enrich_seams(seams, stitched, truth_words)
    audio_duration = float(manifest["source"]["durationSeconds"])
    metrics = transcript_metrics(stitched, truth_words, audio_duration)
    candidate_wer = metrics["wordErrorRate"]["wer"]
    request_audio_seconds = sum(float(record["audioDurationSeconds"]) for record in run["records"])
    total_wall = sum(float(record["wallSecondsIncludingUpload"]) for record in run["records"])
    request_count = sum(int(record["requestCount"]) for record in run["records"])
    retry_count = sum(int(record["retryCount"]) for record in run["records"])
    model = run["model"]
    estimated_neurons = request_audio_seconds / 60 * NEURONS_PER_AUDIO_MINUTE[model]
    exact_backend_cost = estimated_neurons / 1000 * WORKERS_AI_DOLLARS_PER_THOUSAND_NEURONS
    metrics.update(
        {
            "runPath": str(run_path),
            "runSHA256": file_sha256(run_path),
            "model": model,
            "relativeWERImprovementVersusLocalTiny": round((local_wer - candidate_wer) / local_wer, 6),
            "nativeSegmentCount": native_segment_count,
            "nativeWordTimestampPath": sorted(word_paths),
            "requestMetrics": {
                "logicalChunkCount": len(run["records"]),
                "requestCountIncludingRetries": request_count,
                "retryCount": retry_count,
                "failureCount": sum(not record["success"] for record in run["records"]),
                "requestAudioSecondsIncludingOverlap": round(request_audio_seconds, 6),
                "wallSecondsIncludingUpload": round(total_wall, 6),
                "sequentialRTFAgainstRequestAudio": round(total_wall / request_audio_seconds, 6),
                "sequentialRTFAgainstSourceDuration": round(total_wall / audio_duration, 6),
                "publishedRoundedCostDollars": round(float(run["estimatedPublishedCostDollars"]), 6),
                "pricingNeuronEstimate": round(estimated_neurons, 3),
                "pricingDerivedCostDollars": round(exact_backend_cost, 6),
                "observedBilledNeurons": None,
            },
            "perChunkTimestampHealth": per_chunk_health,
            "seams": {
                "count": len(seams),
                "duplicateFlagCount": sum(seam["duplicateFlag"] for seam in seams),
                "omissionFlagCount": sum(seam["omissionFlag"] for seam in seams),
                "discontinuityFlagCount": sum(seam["discontinuityFlag"] for seam in seams),
                "minimumCrossChunkExactMatchWords": min(
                    (seam["crossChunkLongestExactMatchWords"] for seam in seams),
                    default=None,
                ),
                "audits": seams,
            },
        }
    )
    return metrics


def parse_candidate(value: str) -> tuple[str, Path]:
    if "=" not in value:
        raise argparse.ArgumentTypeError("candidate must be LABEL=/path/to/run.json")
    label, path = value.split("=", 1)
    if not label:
        raise argparse.ArgumentTypeError("candidate label must not be empty")
    return label, Path(path)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--truth", required=True, type=Path)
    parser.add_argument("--local-baseline", required=True, type=Path)
    parser.add_argument("--candidate", action="append", required=True, type=parse_candidate)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    manifest = json.loads(args.manifest.read_text())
    truth_document = json.loads(args.truth.read_text())
    truth_words = document_words(truth_document)
    source_sha = manifest["source"]["sha256"]
    audio_duration = float(manifest["source"]["durationSeconds"])
    overlap_seconds = float(manifest["chunking"]["overlapSeconds"])
    local = evaluate_local(args.local_baseline, truth_words, source_sha, audio_duration)
    candidates = {
        label: evaluate_remote(
            run_path,
            manifest,
            truth_words,
            local["wordErrorRate"]["wer"],
            overlap_seconds,
        )
        for label, run_path in args.candidate
    }
    output = {
        "schemaVersion": 1,
        "source": {
            "sha256": source_sha,
            "byteCount": manifest["source"]["byteCount"],
            "durationSeconds": audio_duration,
            "manifestPath": str(args.manifest),
            "manifestSHA256": file_sha256(args.manifest),
        },
        "truth": {
            "artifactPath": str(args.truth),
            "artifactSHA256": file_sha256(args.truth),
            "kind": "pinned mlx-whisper large-v3 comparative reference",
            "wordCount": len(truth_words),
        },
        "stitching": {
            "method": "timestamp-midpoint ownership across the encoded overlap",
            "overlapSeconds": overlap_seconds,
        },
        "localTiny": local,
        "candidates": candidates,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, indent=2, sort_keys=True) + "\n")
    print(
        json.dumps(
            {
                "output": str(args.output),
                "localTinyWER": local["wordErrorRate"]["wer"],
                "candidates": {
                    label: {
                        "wer": result["wordErrorRate"]["wer"],
                        "relativeImprovement": result["relativeWERImprovementVersusLocalTiny"],
                        "wallSeconds": result["requestMetrics"]["wallSecondsIncludingUpload"],
                        "discontinuityFlags": result["seams"]["discontinuityFlagCount"],
                    }
                    for label, result in candidates.items()
                },
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
