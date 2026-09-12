"""Create a private eval request from an exported app transcript, without tokens.

This copies only public episode text/timing and explicit episode metadata. The
original exported document stays local; provenance/auth tokens are never sent.
"""
import argparse
import hashlib
import json
from pathlib import Path


def prepare(transcript, title, podcast):
    segments = []
    end = 0
    for index, segment in enumerate(transcript["segments"]):
        start = max(end, segment["start"], 0)
        end = max(start, segment["end"])
        segments.append(dict(id=index, start=start, end=end, text=segment["text"]))
    fingerprint = hashlib.sha256(json.dumps(segments, sort_keys=True).encode()).hexdigest()
    return dict(
        schema_version=1, async_supported=True, request_id="word-boundary-eval",
        episode_id=transcript["episodeID"], podcast_id=transcript["podcastID"],
        episode_title=title, podcast_title=podcast,
        transcript=dict(language_code=transcript["languageCode"], audio_duration=transcript["audioDuration"],
                        fingerprint=fingerprint, updated_at=transcript["updatedAt"], state="completed",
                        segment_count=len(segments), model_identifier=transcript["modelIdentifier"]),
        segments=segments
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--transcript", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--title", required=True)
    parser.add_argument("--podcast", required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=False)
    source = json.loads(args.transcript.read_text())
    request = prepare(source, args.title, args.podcast)
    (args.out / "request.json").write_text(json.dumps(request, indent=2) + "\n")
    (args.out / "manifest.json").write_text(json.dumps(dict(fixtures=[dict(
        name="exact-upfirst", request="request.json", ground_truth={},
        provenance=dict(source_audio_sha256=source["sourceFileSHA256"],
                        transcript_sha256=hashlib.sha256(args.transcript.read_bytes()).hexdigest(),
                        labels="Unlabelled incident replay; not a holdout score")
    )]), indent=2) + "\n")
