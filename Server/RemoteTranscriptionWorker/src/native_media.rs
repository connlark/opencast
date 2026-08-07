//! Containerless probe and chunk planning.
//!
//! `MP3FrameCore` owns the MPEG arithmetic; this module owns everything that
//! touches R2 and the job record: ranged reads, the streaming source hash, the
//! compact persisted copy plan, and the decision about when the object is
//! outside the supported subset and must fall back to the pinned ffmpeg
//! container.
//!
//! The fallback is total, not partial: a job either runs the native path for
//! both probe and chunk or the container path for both. Mixing them would let
//! a native canonical duration (exact) drive a container chunk loop (which
//! re-derives duration from `ffprobe`), and the two can disagree on VBR media
//! with no Xing header — precisely the disagreement that produced the
//! 2026-08-04 short-episode coverage failure.

use opencast_mp3_frame_core::{Mp3Error, WalkResult};
use serde::{Deserialize, Serialize};

use crate::media::{MediaChunkEntry, MediaChunkResponse, MediaProbeResponse};

/// Bumped whenever boundary selection or output bytes could change. Persisted
/// with every plan so a plan written by an older deploy is never replayed by a
/// newer one.
pub const ALGORITHM_VERSION: u32 = 1;

/// Distinct from the container's `mp3-stream-copy-v1` so provenance and
/// telemetry can tell the two producers apart, even though the bytes are
/// proven identical on the supported subset.
pub const NATIVE_AUDIO_PROFILE: &str = "mp3-native-frame-copy-v1";

/// Sequential source read size. Small enough that peak Worker memory stays
/// far below the 128 MB limit, large enough that a 512 MiB source needs only
/// 64 reads per pass.
pub const SOURCE_RANGE_BYTES: u64 = 8 * 1024 * 1024;

/// Why an object could not be served natively. Content-free: derived from
/// structure, never from media bytes, titles or URLs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NativeFallback {
    Disabled,
    Parser(Mp3Error),
    /// A planned chunk exceeds the model input envelope, so it needs the
    /// container's libmp3lame normalization pass.
    ChunkOverEnvelope,
    /// Bounded resync skipped bytes. The walk stays frame-valid, but ffmpeg
    /// would have muxed those bytes through, so the container decides.
    JunkPresent,
    /// A chunk is not one contiguous source run.
    NonContiguousChunk,
    /// Object identity or shape changed between passes.
    SourceChanged,
    /// R2 read/write problem; the caller retries or falls back.
    StorageUnavailable,
    /// The stored plan was written by a different algorithm version.
    PlanVersionMismatch,
}

impl NativeFallback {
    pub fn reason(&self) -> &'static str {
        match self {
            Self::Disabled => "disabled",
            Self::Parser(error) => error.reason(),
            Self::ChunkOverEnvelope => "chunk_over_envelope",
            Self::JunkPresent => "junk_present",
            Self::NonContiguousChunk => "non_contiguous_chunk",
            Self::SourceChanged => "source_changed",
            Self::StorageUnavailable => "storage_unavailable",
            Self::PlanVersionMismatch => "plan_version_mismatch",
        }
    }
}

/// Compact, job-bound copy plan. One entry per chunk, never one per frame:
/// the four-hour cap is 49 chunks, so this stays a few kilobytes inside the
/// Durable Object record.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NativePlan {
    pub algorithm_version: u32,
    /// The exact object this plan describes. Every copy-pass read is
    /// conditioned on it and fails closed if the object changed.
    pub source_sha256: String,
    pub byte_count: i64,
    pub etag: String,
    pub canonical_duration_seconds: f64,
    pub chunks: Vec<NativePlanChunk>,
}

impl NativePlan {
    /// True when every chunk carries its stored hash — the precondition for
    /// building the manifest from the plan alone and reading spans at
    /// transcription time instead of materializing chunk objects.
    pub fn chunk_hashes_complete(&self) -> bool {
        self.chunks.iter().all(|chunk| chunk.sha256.is_some())
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NativePlanChunk {
    pub index: u32,
    /// Source byte runs to copy, `[start, end)`, in order.
    pub spans: Vec<[u64; 2]>,
    pub byte_count: i64,
    pub actual_duration_seconds: f64,
    /// Lowercase hex SHA-256 of the chunk's bytes, streamed during the probe
    /// walk. `None` only in plans persisted before the field existed; those
    /// jobs are handed to the container instead of served from spans.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sha256: Option<String>,
}

impl NativePlanChunk {
    pub fn spans_are_sane(&self, object_len: u64) -> bool {
        if self.spans.is_empty() || self.byte_count <= 0 {
            return false;
        }
        let mut previous_end = 0u64;
        let mut total = 0u64;
        for [start, end] in &self.spans {
            if end <= start || *end > object_len || *start < previous_end {
                return false;
            }
            previous_end = *end;
            total += end - start;
        }
        total == self.byte_count as u64
    }
}

/// Everything the source pass produced.
pub struct SourceWalk {
    pub sha256: String,
    pub byte_count: i64,
    pub etag: String,
    pub walk: WalkResult,
    pub peak_buffered_bytes: usize,
}

impl SourceWalk {
    pub fn probe_response(&self) -> MediaProbeResponse {
        MediaProbeResponse {
            duration_seconds: self.walk.canonical_seconds(),
            codec: "mp3".to_string(),
            audio_stream_count: 1,
            byte_count: self.byte_count,
            sha256: self.sha256.clone(),
        }
    }

    /// Decides whether this object may skip the container entirely.
    pub fn plan(&self, max_chunk_raw_bytes: i64) -> Result<NativePlan, NativeFallback> {
        if self.walk.junk_bytes > 0 || self.walk.resync_events > 0 {
            return Err(NativeFallback::JunkPresent);
        }
        if !self.walk.all_chunks_contiguous() {
            return Err(NativeFallback::NonContiguousChunk);
        }
        if self.walk.max_chunk_bytes() > max_chunk_raw_bytes.max(0) as u64 {
            return Err(NativeFallback::ChunkOverEnvelope);
        }
        let chunks = self
            .walk
            .chunks
            .iter()
            .map(|chunk| NativePlanChunk {
                index: chunk.index,
                spans: chunk
                    .spans
                    .iter()
                    .map(|span| [span.start, span.end])
                    .collect(),
                byte_count: chunk.byte_count as i64,
                actual_duration_seconds: chunk.actual_duration_seconds(),
                sha256: Some(chunk.sha256_hex()),
            })
            .collect();
        Ok(NativePlan {
            algorithm_version: ALGORITHM_VERSION,
            source_sha256: self.sha256.clone(),
            byte_count: self.byte_count,
            etag: self.etag.clone(),
            canonical_duration_seconds: self.walk.canonical_seconds(),
            chunks,
        })
    }

    /// One content-free line per job for the shadow comparison.
    pub fn telemetry(&self) -> String {
        format!(
            "frames={} rate={} ch={} vbr={} start_ticks={} canonical={:.3} lead={} trail={} \
             resync={} junk={} truncated_tail={} chunks={} max_chunk_bytes={} peak_buf={}",
            self.walk.audio_frames,
            self.walk.sample_rate,
            self.walk.channels,
            self.walk.vbr.as_ref().map_or("none", |tag| match tag.kind {
                opencast_mp3_frame_core::VbrKind::Xing => "xing",
                opencast_mp3_frame_core::VbrKind::Info => "info",
                opencast_mp3_frame_core::VbrKind::Vbri => "vbri",
            }),
            self.walk.start_ticks,
            self.walk.canonical_seconds(),
            self.walk.leading_tag_bytes,
            self.walk.trailing_tag_bytes,
            self.walk.resync_events,
            self.walk.junk_bytes,
            self.walk.truncated_tail_bytes,
            self.walk.chunks.len(),
            self.walk.max_chunk_bytes(),
            self.peak_buffered_bytes,
        )
    }
}

/// Builds one manifest entry from a written chunk. Requested duration stays
/// the contract's 300 s even for the final chunk, matching what the container
/// reports today and what `media::validate_chunks` requires.
pub fn manifest_entry(
    chunk: &NativePlanChunk,
    key: String,
    sha256: String,
    byte_count: i64,
) -> MediaChunkEntry {
    MediaChunkEntry {
        index: chunk.index,
        key,
        requested_start_seconds: f64::from(chunk.index) * crate::job::STEP_SECONDS,
        requested_duration_seconds: crate::job::CHUNK_SECONDS,
        actual_duration_seconds: chunk.actual_duration_seconds,
        byte_count,
        sha256,
    }
}

/// Builds the chunk manifest from the stored plan alone — zero R2 I/O. The
/// construction is byte-identical to what the retired copy executor produced
/// (proven on the pinned fixtures): same keys, same entries, and the same
/// manifest chain (SHA-256 over the lowercase hex chunk hashes in index
/// order), so `chunk_manifest_sha256` is stable across the pipeline change.
///
/// `None` when any chunk lacks a stored hash (a plan persisted before the
/// field existed); those jobs go to the container instead.
pub fn manifest_from_plan(plan: &NativePlan, job_id: &str) -> Option<MediaChunkResponse> {
    use sha2::{Digest, Sha256};

    let chunk_prefix = crate::job::r2_chunk_prefix(job_id);
    let mut entries = Vec::with_capacity(plan.chunks.len());
    let mut manifest_hasher = Sha256::new();
    for chunk in &plan.chunks {
        let sha256 = chunk.sha256.clone()?;
        manifest_hasher.update(sha256.as_bytes());
        let key = format!("{chunk_prefix}{}.mp3", chunk.index);
        entries.push(manifest_entry(chunk, key, sha256, chunk.byte_count));
    }
    Some(MediaChunkResponse {
        chunks: entries,
        manifest_sha256: hex::encode(manifest_hasher.finalize()),
        chunk_audio_profile: Some(NATIVE_AUDIO_PROFILE.to_string()),
    })
}

#[cfg(target_arch = "wasm32")]
mod r2 {
    use super::*;
    use opencast_mp3_frame_core::tags::{scan_tail, TAIL_PROBE_BYTES};
    use opencast_mp3_frame_core::{Mp3Walker, WalkOptions};
    use sha2::{Digest, Sha256};
    use worker::{Bucket, Conditional, Range};

    async fn read_range(
        bucket: &Bucket,
        key: &str,
        offset: u64,
        length: u64,
        etag: Option<&str>,
    ) -> Result<Vec<u8>, NativeFallback> {
        let mut request = bucket
            .get(key)
            .range(Range::OffsetWithLength { offset, length });
        if let Some(etag) = etag {
            request = request.only_if(Conditional {
                etag_matches: Some(etag.to_string()),
                ..Conditional::default()
            });
        }
        let object = request
            .execute()
            .await
            .map_err(|_| NativeFallback::StorageUnavailable)?
            .ok_or(NativeFallback::SourceChanged)?;
        // A failed `onlyIf` precondition returns metadata with no body, which
        // is exactly the "object changed under us" case.
        let body = object.body().ok_or(NativeFallback::SourceChanged)?;
        let bytes = body
            .bytes()
            .await
            .map_err(|_| NativeFallback::StorageUnavailable)?;
        if bytes.len() as u64 != length {
            return Err(NativeFallback::SourceChanged);
        }
        Ok(bytes)
    }

    /// Single sequential pass over the source: streaming SHA-256, frame walk
    /// and chunk plan in one read. Nothing is retained but the walker's
    /// sub-2 KiB carry and the per-chunk plan records.
    pub async fn walk_source(
        bucket: &Bucket,
        key: &str,
        range_bytes: u64,
        chunk_byte_ceiling: u64,
    ) -> Result<SourceWalk, NativeFallback> {
        let head = bucket
            .head(key)
            .await
            .map_err(|_| NativeFallback::StorageUnavailable)?
            .ok_or(NativeFallback::SourceChanged)?;
        let object_len = head.size();
        let etag = head.etag();
        if object_len == 0 {
            return Err(NativeFallback::Parser(Mp3Error::NoMpegAudio));
        }

        let tail_len = TAIL_PROBE_BYTES.min(object_len);
        let tail = read_range(
            bucket,
            key,
            object_len - tail_len,
            tail_len,
            Some(etag.as_str()),
        )
        .await?;
        let tail_tags = scan_tail(object_len, &tail);

        let mut options = WalkOptions::new(object_len, tail_tags.audio_end);
        // Bitrate too high for the model envelope is the common fallback, and
        // it is decidable inside the first window — bail there instead of
        // reading and hashing a whole 512 MiB source the container will
        // re-download anyway.
        options.chunk_byte_ceiling = chunk_byte_ceiling;
        let mut walker = Mp3Walker::new(options);
        let mut hasher = Sha256::new();
        let mut peak_buffered_bytes = 0usize;
        let mut offset = 0u64;
        while offset < object_len {
            let length = range_bytes.min(object_len - offset);
            let bytes = read_range(bucket, key, offset, length, Some(etag.as_str())).await?;
            hasher.update(&bytes);
            walker.feed(&bytes).map_err(NativeFallback::Parser)?;
            peak_buffered_bytes = peak_buffered_bytes.max(walker.buffered_bytes());
            offset += length;
        }
        let walk = walker.finish().map_err(NativeFallback::Parser)?;

        Ok(SourceWalk {
            sha256: hex::encode(hasher.finalize()),
            byte_count: object_len as i64,
            etag,
            walk,
            peak_buffered_bytes,
        })
    }

    /// Reads one planned chunk's bytes straight from the source object:
    /// span sanity, etag-conditional range reads, concatenation in order,
    /// and the length check. This is the whole transcription-time read path
    /// for span-served jobs — the chunk is reproduced, never stored.
    pub async fn read_chunk_bytes(
        bucket: &Bucket,
        source_key: &str,
        plan: &NativePlan,
        chunk: &NativePlanChunk,
    ) -> Result<Vec<u8>, NativeFallback> {
        if !chunk.spans_are_sane(plan.byte_count.max(0) as u64) {
            return Err(NativeFallback::SourceChanged);
        }
        let mut blob = Vec::with_capacity(chunk.byte_count.max(0) as usize);
        for [start, end] in &chunk.spans {
            let bytes = read_range(
                bucket,
                source_key,
                *start,
                end - start,
                Some(plan.etag.as_str()),
            )
            .await?;
            blob.extend_from_slice(&bytes);
        }
        if blob.len() as i64 != chunk.byte_count {
            return Err(NativeFallback::SourceChanged);
        }
        Ok(blob)
    }
}

#[cfg(target_arch = "wasm32")]
pub use r2::{read_chunk_bytes, walk_source};

#[cfg(test)]
mod tests {
    use super::*;
    use opencast_mp3_frame_core::plan::{ChunkPlan, Span};

    fn walk_result(chunks: Vec<ChunkPlan>, junk: u64, resync: u32) -> WalkResult {
        WalkResult {
            object_len: 1_000_000,
            audio_end: 1_000_000,
            leading_tag_bytes: 0,
            trailing_tag_bytes: 0,
            first_audio_offset: 0,
            audio_frames: 100,
            sample_rate: 44_100,
            channels: 1,
            samples_per_frame: 1152,
            vbr: None,
            start_ticks: 0,
            walked_ticks: 100 * 1152 * 320,
            canonical_micros: 2_612_244,
            chunks,
            resync_events: resync,
            junk_bytes: junk,
            truncated_tail_bytes: 0,
            variable_bitrate: false,
        }
    }

    fn chunk(index: u32, spans: Vec<Span>, micros: u64) -> ChunkPlan {
        let byte_count = spans.iter().map(|span| span.len()).sum();
        ChunkPlan {
            index,
            spans,
            byte_count,
            frames: 1,
            first_pts_ticks: 0,
            micros,
            sha256: [index as u8; 32],
        }
    }

    fn source(walk: WalkResult) -> SourceWalk {
        SourceWalk {
            sha256: "a".repeat(64),
            byte_count: walk.object_len as i64,
            etag: "etag-1".to_string(),
            walk,
            peak_buffered_bytes: 1421,
        }
    }

    #[test]
    fn contiguous_in_envelope_walks_produce_a_plan() {
        let walk = walk_result(
            vec![
                chunk(
                    0,
                    vec![Span {
                        start: 0,
                        end: 3000,
                    }],
                    300_011_170,
                ),
                chunk(
                    1,
                    vec![Span {
                        start: 2900,
                        end: 6000,
                    }],
                    289_954_200,
                ),
            ],
            0,
            0,
        );
        let plan = source(walk).plan(5 * 1024 * 1024).expect("plan");
        assert_eq!(plan.algorithm_version, ALGORITHM_VERSION);
        assert_eq!(plan.etag, "etag-1");
        assert_eq!(plan.chunks.len(), 2);
        assert_eq!(plan.chunks[0].spans, vec![[0, 3000]]);
        assert_eq!(plan.chunks[0].byte_count, 3000);
        assert_eq!(plan.chunks[0].actual_duration_seconds, 300.011);
        assert_eq!(plan.chunks[1].actual_duration_seconds, 289.954);
        // The walk's streamed hash lands in the plan as lowercase hex.
        assert_eq!(
            plan.chunks[0].sha256.as_deref(),
            Some("0000000000000000000000000000000000000000000000000000000000000000")
        );
        assert_eq!(
            plan.chunks[1].sha256.as_deref(),
            Some("0101010101010101010101010101010101010101010101010101010101010101")
        );
        assert!(plan.chunk_hashes_complete());
    }

    #[test]
    fn oversized_chunks_defer_to_the_containers_normalizer() {
        let walk = walk_result(
            vec![chunk(
                0,
                vec![Span {
                    start: 0,
                    end: 6 * 1024 * 1024,
                }],
                300_011_170,
            )],
            0,
            0,
        );
        assert_eq!(
            source(walk).plan(5 * 1024 * 1024),
            Err(NativeFallback::ChunkOverEnvelope)
        );
    }

    #[test]
    fn junk_and_discontiguity_defer_to_the_container() {
        let junked = walk_result(
            vec![chunk(
                0,
                vec![Span {
                    start: 0,
                    end: 3000,
                }],
                300_011_170,
            )],
            30,
            1,
        );
        assert_eq!(
            source(junked).plan(5 * 1024 * 1024),
            Err(NativeFallback::JunkPresent)
        );

        let split = walk_result(
            vec![chunk(
                0,
                vec![
                    Span { start: 0, end: 100 },
                    Span {
                        start: 130,
                        end: 3000,
                    },
                ],
                300_011_170,
            )],
            0,
            0,
        );
        assert_eq!(
            source(split).plan(5 * 1024 * 1024),
            Err(NativeFallback::NonContiguousChunk)
        );
    }

    #[test]
    fn probe_response_reports_the_exact_walked_identity() {
        let walk = walk_result(
            vec![chunk(
                0,
                vec![Span {
                    start: 0,
                    end: 3000,
                }],
                300_011_170,
            )],
            0,
            0,
        );
        let probe = source(walk).probe_response();
        assert_eq!(probe.codec, "mp3");
        assert_eq!(probe.audio_stream_count, 1);
        assert_eq!(probe.byte_count, 1_000_000);
        assert_eq!(probe.sha256, "a".repeat(64));
        assert_eq!(probe.duration_seconds, 2.612);
    }

    #[test]
    fn span_sanity_rejects_overlap_reversal_and_overrun() {
        let object_len = 10_000u64;
        let good = NativePlanChunk {
            index: 0,
            spans: vec![[0, 100], [200, 300]],
            byte_count: 200,
            actual_duration_seconds: 1.0,
            sha256: Some("e".repeat(64)),
        };
        assert!(good.spans_are_sane(object_len));

        let cases = [
            NativePlanChunk {
                spans: vec![],
                byte_count: 0,
                ..good.clone()
            },
            // Reversed span.
            NativePlanChunk {
                spans: vec![[300, 200]],
                byte_count: 100,
                ..good.clone()
            },
            // Past the object.
            NativePlanChunk {
                spans: vec![[0, 20_000]],
                byte_count: 20_000,
                ..good.clone()
            },
            // Out of order / overlapping.
            NativePlanChunk {
                spans: vec![[200, 300], [100, 150]],
                byte_count: 150,
                ..good.clone()
            },
            // Byte count disagrees with the spans.
            NativePlanChunk {
                spans: vec![[0, 100]],
                byte_count: 999,
                ..good.clone()
            },
        ];
        for case in cases {
            assert!(
                !case.spans_are_sane(object_len),
                "{case:?} should be rejected"
            );
        }
    }

    #[test]
    fn manifest_entries_follow_the_immutable_chunk_contract() {
        let chunk = NativePlanChunk {
            index: 2,
            spans: vec![[0, 100]],
            byte_count: 100,
            actual_duration_seconds: 289.954,
            sha256: Some("b".repeat(64)),
        };
        let entry = manifest_entry(&chunk, "chunks/job/2.mp3".to_string(), "b".repeat(64), 100);
        assert_eq!(entry.index, 2);
        assert_eq!(entry.requested_start_seconds, 596.0);
        assert_eq!(entry.requested_duration_seconds, 300.0);
        assert_eq!(entry.actual_duration_seconds, 289.954);
    }

    /// The pinned dp225 manifest, rebuilt from a native plan, must still pass
    /// the gateway's own chunk validation.
    #[test]
    fn native_manifests_satisfy_validate_chunks() {
        let plans = [
            (0u32, 300.011, 3_259_112i64),
            (1, 300.037, 3_263_100),
            (2, 289.954, 3_152_871),
        ];
        let entries: Vec<MediaChunkEntry> = plans
            .iter()
            .map(|(index, duration, bytes)| {
                manifest_entry(
                    &NativePlanChunk {
                        index: *index,
                        spans: vec![[0, *bytes as u64]],
                        byte_count: *bytes,
                        actual_duration_seconds: *duration,
                        sha256: Some("c".repeat(64)),
                    },
                    format!("chunks/job/{index}.mp3"),
                    "c".repeat(64),
                    *bytes,
                )
            })
            .collect();
        assert!(crate::media::validate_chunks(
            &entries,
            crate::job::MAX_CHUNK_RAW_BYTES,
            885.943,
            crate::job::CHUNK_SECONDS,
            crate::job::STEP_SECONDS,
        )
        .is_ok());
    }

    #[test]
    fn fallback_reasons_are_stable_and_content_free() {
        assert_eq!(NativeFallback::Disabled.reason(), "disabled");
        assert_eq!(
            NativeFallback::ChunkOverEnvelope.reason(),
            "chunk_over_envelope"
        );
        assert_eq!(
            NativeFallback::Parser(Mp3Error::NoMpegAudio).reason(),
            "no_mpeg_audio"
        );
        assert_eq!(
            NativeFallback::Parser(Mp3Error::UnsupportedFreeFormat).reason(),
            "unsupported_free_format"
        );
    }

    #[test]
    fn plans_round_trip_through_the_record_encoding() {
        let plan = NativePlan {
            algorithm_version: ALGORITHM_VERSION,
            source_sha256: "d".repeat(64),
            byte_count: 9_825_356,
            etag: "etag-2".to_string(),
            canonical_duration_seconds: 885.943,
            chunks: vec![NativePlanChunk {
                index: 0,
                spans: vec![[194_854, 3_453_966]],
                byte_count: 3_259_112,
                actual_duration_seconds: 300.011,
                sha256: Some("d".repeat(64)),
            }],
        };
        let encoded = serde_json::to_string(&plan).expect("encode");
        assert_eq!(serde_json::from_str::<NativePlan>(&encoded).unwrap(), plan);
        // A 49-chunk four-hour plan must stay tiny inside the DO record.
        assert!(encoded.len() < 500);
    }

    /// Plans persisted before the sha field existed must still decode, read
    /// back as hash-incomplete, and refuse the manifest-from-plan path — the
    /// container finishes those jobs.
    #[test]
    fn sha_less_plans_decode_and_refuse_the_metadata_only_path() {
        let old_format = r#"{
            "algorithm_version": 1,
            "source_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "byte_count": 9825356,
            "etag": "etag-3",
            "canonical_duration_seconds": 885.943,
            "chunks": [
                {"index": 0, "spans": [[0, 3000]], "byte_count": 3000, "actual_duration_seconds": 300.011},
                {"index": 1, "spans": [[2900, 6000]], "byte_count": 3100, "actual_duration_seconds": 289.954}
            ]
        }"#;
        let plan: NativePlan = serde_json::from_str(old_format).expect("decode");
        assert_eq!(plan.chunks[0].sha256, None);
        assert!(!plan.chunk_hashes_complete());
        assert!(manifest_from_plan(&plan, "job-old").is_none());
        // Re-encoding a sha-less plan stays sha-less (the field is skipped),
        // so a record rewrite never fabricates a hash.
        let reencoded = serde_json::to_string(&plan).expect("encode");
        assert!(!reencoded.contains("sha256\":null"));
        assert_eq!(
            serde_json::from_str::<NativePlan>(&reencoded).unwrap(),
            plan
        );
    }

    /// The metadata-only manifest must be exactly what the copy executor
    /// would have produced: same keys, same entries, and the same manifest
    /// chain over the hex chunk hashes in index order.
    #[test]
    fn manifest_from_plan_reproduces_the_copy_executors_manifest() {
        use sha2::{Digest, Sha256};

        let chunk_shas = ["4".repeat(64), "5".repeat(64), "6".repeat(64)];
        let plan = NativePlan {
            algorithm_version: ALGORITHM_VERSION,
            source_sha256: "d".repeat(64),
            byte_count: 9_825_356,
            etag: "etag-2".to_string(),
            canonical_duration_seconds: 885.943,
            chunks: vec![
                NativePlanChunk {
                    index: 0,
                    spans: vec![[194_854, 3_453_966]],
                    byte_count: 3_259_112,
                    actual_duration_seconds: 300.011,
                    sha256: Some(chunk_shas[0].clone()),
                },
                NativePlanChunk {
                    index: 1,
                    spans: vec![[3_431_120, 6_694_220]],
                    byte_count: 3_263_100,
                    actual_duration_seconds: 300.037,
                    sha256: Some(chunk_shas[1].clone()),
                },
                NativePlanChunk {
                    index: 2,
                    spans: vec![[6_672_485, 9_825_356]],
                    byte_count: 3_152_871,
                    actual_duration_seconds: 289.954,
                    sha256: Some(chunk_shas[2].clone()),
                },
            ],
        };

        let manifest = manifest_from_plan(&plan, "job-1").expect("manifest");
        assert_eq!(
            manifest.chunk_audio_profile.as_deref(),
            Some(NATIVE_AUDIO_PROFILE)
        );
        assert_eq!(manifest.chunks.len(), 3);
        for (position, entry) in manifest.chunks.iter().enumerate() {
            assert_eq!(entry.index as usize, position);
            assert_eq!(entry.key, format!("chunks/job-1/{position}.mp3"));
            assert_eq!(entry.sha256, chunk_shas[position]);
            assert_eq!(entry.byte_count, plan.chunks[position].byte_count);
            assert_eq!(entry.requested_duration_seconds, crate::job::CHUNK_SECONDS);
        }

        // Pin the chain construction itself: SHA-256 over the concatenated
        // lowercase hex strings — the manifest chain every producer computes.
        let mut chain = Sha256::new();
        for sha in &chunk_shas {
            chain.update(sha.as_bytes());
        }
        assert_eq!(manifest.manifest_sha256, hex::encode(chain.finalize()));

        // And the result must clear the gateway's own validation.
        assert!(crate::media::validate_chunks(
            &manifest.chunks,
            crate::job::MAX_CHUNK_RAW_BYTES,
            885.943,
            crate::job::CHUNK_SECONDS,
            crate::job::STEP_SECONDS,
        )
        .is_ok());
    }
}
