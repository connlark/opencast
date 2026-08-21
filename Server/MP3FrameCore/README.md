# MP3FrameCore

Pure Rust MPEG-1/2/2.5 Layer III frame walker. It replaces the pinned ffmpeg
container's `probe` and `chunk` operations for ordinary podcast MP3s, so a
transcription job's media preparation runs entirely inside
`RemoteTranscriptionWorker`'s Durable Object.

No dependencies, `#![forbid(unsafe_code)]`, host and `wasm32-unknown-unknown`.
It touches no network, no storage and no clock: the Worker owns R2 ranged
reads, hashing, plan persistence and cancellation, and hands this crate bytes.

Cost is linear in the source and independent of the caller's read range: the
walker trims consumed bytes once per feed, never per frame. A per-frame
`Vec::drain` made the walk quadratic in the read range until 2026-08-19 —
measured at the production 8 MiB range, HH65 (174 MB) went **54.2 s → 1.42 s**
and a 163 MB 2 h 50 m episode **43.3 s → 0.80 s**, with byte-identical output
on every field including all chunk hashes. `Mp3Walker::trim_bytes_moved` is the
deterministic cost counter the walker tests pin (HH65 moved 2.26 TB before,
5.9 MB after), and `mp3-frame-diff` prints the walk's elapsed seconds so the
local differential gate catches a cost regression too.

## Contract

1. Ordinary MPEG-1/2/2.5 Layer III elementary streams, CBR or VBR.
2. Output is complete frames only — never junk, never a partial frame, never
   an ID3/APE/Xing/VBRI byte.
3. Bounded resynchronization. Anything outside the subset returns a stable
   `Mp3Error`, and the caller falls back to the container. Failures are never
   customer-facing errors.
4. Boundary selection is exact integer sample-clock arithmetic that reproduces
   `ffmpeg -ss S -i src -t 300 -c:a copy` frame for frame.

It is deliberately **not** an ffmpeg emulator. ffmpeg's MP3 parser resyncs on
the first header-shaped four bytes it sees and muxes the skipped bytes into
the packet; matching that would violate the frame-valid output requirement, so
those inputs fall back instead.

## Boundary rule

Derived from, and verified against, the pinned `pass0-9` image:

- first frame of chunk *i* = the last frame whose pts ≤ `i·298 s + start_time`;
- last frame = the last frame whose pts < that same target + 300 s;
- `start_time` is `start_pad + 528 + 1` samples when the Xing/Info tag carries
  a recognized LAME/Lavf/Lavc extension, else 0. It is load-bearing: DA009's
  576-sample encoder delay moves every chunk one frame later.

`actual_duration_seconds` deliberately reproduces `ffprobe`'s quantization —
per-frame durations rounded to six decimals, then summed — because the
gateway's manifest gate is pinned to those values. Summing exact rationals
instead gives 300.016 s where dp225 chunk 0 must report 300.011 s. Boundary
selection itself always uses the exact clock; mixing the two recreates
coverage bugs.

`canonical_duration` follows ffmpeg (`frames·spf − start_pad − end_pad` from a
trusted VBR tag) but is clamped to the frames actually walked, so a tag that
over-claims on a truncated object cannot produce a manifest the gateway must
reject.

## Verification

```sh
cargo test                                  # unit + walker integration + mutation sweep
cargo build --target wasm32-unknown-unknown # the target RTW ships
cargo build --release --bin mp3-frame-diff  # local differential CLI
./target/release/mp3-frame-diff FILE.mp3    # probe fields, chunk spans, chunk SHA-256
```

The differential CLI is local-only; RTW links the library, never the binary.

### Pinned-ffmpeg differential gate

The gate compares `mp3-frame-diff` output against chunks extracted by the
exact `pass0-9` image with `media_server.py`'s command line. Result on
2026-08-05, ffmpeg 9.0:

| Corpus | Result |
|---|---|
| dp225 (`eac2a37d…`, VBR/Xing, 9.8 MB) | 3/3 chunks byte-identical |
| DA009 (`c9b6bcdb…`, CBR/Info + LAME delay, 25.4 MB) | 11/11 chunks byte-identical |
| HH65 (`bd1144e7…`, near-cap 3 h 58 m, no VBR header, 2.5 MB ID3v2 + ID3v1 tail, 174 MB) | 49/49 chunks byte-identical |
| 13 synthetic variants: MPEG-1/2/2.5, 8–48 kHz, mono/stereo, 24–256 kbps, CBR/VBR, CRC, no-Xing, ID3v2+ID3v1 | 13/13 byte-identical |

Adversarial cases are classified rather than matched, because ffmpeg is
deliberately more permissive there:

| Case | ffmpeg 9 | This crate |
|---|---|---|
| VBR with no Xing header | estimates 652.629 s from bitrate | exact 700.029 s |
| 30 junk bytes mid-stream | muxes the junk into a packet | bounded resync, junk excluded → container fallback |
| Truncated final frame | may emit the partial frame | dropped |
| Two files concatenated | discards the Xing count, estimates | same trust guard, same duration |
| Free format | "Failed to find two consecutive MPEG audio frames" | `unsupported_free_format` |
| Layer II / AAC misnamed `.mp3` | rejects / false-syncs to 0.000 s | `no_mpeg_audio` |
| APEv2 or ID3v1 tail | strips at flush | full checked tag excluded |
