# Remote transcription bakeoff tools

These scripts reproduce a byte-stable corpus preparation and Workers AI
request path for self-hosted evaluation.
They deliberately keep audio, credentials, full transcripts, and operational
logs outside the repository.

## Prepare frame-valid chunks

```sh
python3 scripts/remote-transcription-bakeoff/make_chunks.py \
  --input /path/to/pinned.mp3 \
  --output-dir /private/tmp/opencast-transcription-bakeoff/chunks \
  --chunk-seconds 300 \
  --overlap-seconds 2
```

The command writes `manifest.json` alongside the chunks. Each entry records
the pinned source hash, requested absolute offset, actual encoded duration,
codec details, extraction command, byte count, and chunk SHA-256.

## Run Workers AI

```sh
python3 scripts/remote-transcription-bakeoff/workers_ai.py \
  --manifest /private/tmp/opencast-transcription-bakeoff/chunks/manifest.json \
  --output-dir /private/tmp/opencast-transcription-bakeoff/results/large-v3-turbo \
  --model @cf/openai/whisper-large-v3-turbo
```

The driver obtains the current credential and account metadata from the
already-authenticated Wrangler session and runs Wrangler in an automatically
deleted temporary working directory. It never puts credentials or account IDs
in its console or result files. Raw model outputs stay under the requested
temporary output directory; the console and `run.json` contain timing and
request metadata only.

## Stitch and evaluate

```sh
python3 scripts/remote-transcription-bakeoff/evaluate.py \
  --manifest /private/tmp/opencast-transcription-bakeoff/chunks/manifest.json \
  --truth /path/to/pinned-reference.json \
  --local-baseline /path/to/exact-source-local-tiny.json \
  --candidate large=/private/tmp/opencast-transcription-bakeoff/results/large/run.json \
  --output /private/tmp/opencast-transcription-bakeoff/evaluation.json
```

Evaluation uses timestamp-midpoint ownership across the encoded overlap, audits
every seam, computes normalized WER and repetition/timestamp metrics, and emits
only metrics plus hashes. It does not place transcript text in the repository.

## Regenerate stitch fixtures

The committed full fixture embeds its raw model chunks, so contract-only
changes can regenerate it without another inference run:

```sh
python3 scripts/remote-transcription-bakeoff/make_golden_fixtures.py \
  --input-fixture Packages/OpenCastTranscription/Tests/OpenCastTranscriptionTests/Fixtures/RemoteTranscriptionGoldenStitch.json \
  --output Packages/OpenCastTranscription/Tests/OpenCastTranscriptionTests/Fixtures/RemoteTranscriptionGoldenStitch.json
```

For preserved stitch-debug responses named `<index>.json`, generate the
metadata-minimized regression fixture with only exact words intersecting the
2-second overlap windows:

```sh
python3 scripts/remote-transcription-bakeoff/make_golden_fixtures.py \
  --debug-results-dir /path/to/responses \
  --debug-job-id job-example \
  --output Packages/OpenCastTranscription/Tests/OpenCastTranscriptionTests/Fixtures/RemoteTranscriptionSeamDuplicateStitch.json
```

Each extracted chunk records the raw response SHA-256. The v2 generator aligns
normalized overlap words one-to-one within the pinned 0.9-second epsilon and
keeps the copy selected by the pair's consensus timestamp midpoint.

Re-vet every generated fixture before committing it. It must contain no URLs,
account/install identifiers, job history, credentials, or customer media.
