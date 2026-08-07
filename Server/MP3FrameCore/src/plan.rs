//! Chunk-window planning over an exact integer sample clock.
//!
//! Reproduces what `ffmpeg -ss S -i src -t 300 -c:a copy` selects, without
//! seeking: for requested start `S`, the first emitted frame is the *last*
//! frame whose demux timestamp is at or before `S + stream_start_time`, and
//! emission stops at the first frame at or after that same target plus 300 s.
//! `stream_start_time` is not decorative — DA009's LAME encoder delay moves
//! every chunk one frame later than a naive zero-origin floor would.
//!
//! Windows overlap by 2 s, so at most two are open at once; the planner keeps
//! O(1) state per open window and one record per finished chunk rather than
//! one record per frame.

use crate::sha256::Sha256;
use crate::{micros_to_seconds_q3, Mp3Error, MAX_CHUNKS, STEP_SECONDS};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Span {
    pub start: u64,
    /// Exclusive.
    pub end: u64,
}

impl Span {
    pub fn len(&self) -> u64 {
        self.end - self.start
    }

    pub fn is_empty(&self) -> bool {
        self.end == self.start
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChunkPlan {
    pub index: u32,
    /// Source byte runs to copy, in order. One entry for every normal input;
    /// more only when a bounded resync skipped junk inside the window.
    pub spans: Vec<Span>,
    pub byte_count: u64,
    pub frames: u64,
    pub first_pts_ticks: u64,
    /// Sum of `ffprobe`-quantized per-frame durations, in microseconds.
    pub micros: u64,
    /// SHA-256 of the chunk's bytes, streamed frame by frame during the walk.
    /// Must equal a digest of the concatenated span bytes.
    pub sha256: [u8; 32],
}

impl ChunkPlan {
    /// Lowercase hex of [`Self::sha256`], the manifest's string encoding.
    pub fn sha256_hex(&self) -> String {
        crate::sha256::hex(&self.sha256)
    }

    /// The contract's requested start: exactly `index * 298 s`, independent
    /// of which physical frame was selected.
    pub fn requested_start_seconds(&self) -> f64 {
        f64::from(self.index) * STEP_SECONDS as f64
    }

    /// Manifest `actual_duration_seconds`, quantized the way the container's
    /// `measured_audio_duration()` + `quantized()` pipeline quantizes it.
    pub fn actual_duration_seconds(&self) -> f64 {
        micros_to_seconds_q3(self.micros)
    }
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct FrameRef {
    pub offset: u64,
    pub len: u64,
    pub pts: u64,
    pub micros: u64,
}

#[derive(Debug)]
struct OpenChunk {
    index: u32,
    spans: Vec<Span>,
    byte_count: u64,
    frames: u64,
    first_pts_ticks: u64,
    micros: u64,
    hasher: Sha256,
}

impl OpenChunk {
    fn new(index: u32, frame: FrameRef, payload: &[u8]) -> Self {
        let mut hasher = Sha256::new();
        hasher.update(payload);
        Self {
            index,
            spans: vec![Span {
                start: frame.offset,
                end: frame.offset + frame.len,
            }],
            byte_count: frame.len,
            frames: 1,
            first_pts_ticks: frame.pts,
            micros: frame.micros,
            hasher,
        }
    }

    fn push(
        &mut self,
        frame: FrameRef,
        payload: &[u8],
        max_spans: usize,
        ceiling: u64,
    ) -> Result<(), Mp3Error> {
        if self.byte_count + frame.len > ceiling {
            return Err(Mp3Error::ChunkOverEnvelope);
        }
        match self.spans.last_mut() {
            Some(last) if last.end == frame.offset => last.end += frame.len,
            _ => {
                if self.spans.len() >= max_spans {
                    return Err(Mp3Error::PlanTooLarge);
                }
                self.spans.push(Span {
                    start: frame.offset,
                    end: frame.offset + frame.len,
                });
            }
        }
        self.byte_count += frame.len;
        self.frames += 1;
        self.micros += frame.micros;
        self.hasher.update(payload);
        Ok(())
    }

    fn into_plan(self) -> ChunkPlan {
        ChunkPlan {
            index: self.index,
            spans: self.spans,
            byte_count: self.byte_count,
            frames: self.frames,
            first_pts_ticks: self.first_pts_ticks,
            micros: self.micros,
            sha256: self.hasher.finalize(),
        }
    }
}

#[derive(Debug)]
pub(crate) struct Planner {
    start_ticks: u64,
    chunk_ticks: u64,
    step_ticks: u64,
    max_spans_per_chunk: usize,
    chunk_byte_ceiling: u64,
    next_open: u32,
    candidate: Option<FrameRef>,
    /// The candidate frame's payload bytes (≤ [`crate::header::MAX_FRAME_BYTES`]).
    /// Windows open from a *stored past* frame whose buffer bytes the walker
    /// has already trimmed, so its hash input has to be retained here.
    candidate_bytes: Vec<u8>,
    open: Vec<OpenChunk>,
    done: Vec<ChunkPlan>,
}

impl Planner {
    pub(crate) fn new(
        start_ticks: u64,
        chunk_ticks: u64,
        step_ticks: u64,
        max_spans_per_chunk: usize,
        chunk_byte_ceiling: u64,
    ) -> Self {
        Self {
            start_ticks,
            chunk_ticks,
            step_ticks,
            max_spans_per_chunk,
            chunk_byte_ceiling,
            next_open: 0,
            candidate: None,
            candidate_bytes: Vec::new(),
            open: Vec::new(),
            done: Vec::new(),
        }
    }

    fn target_ticks(&self, index: u32) -> Result<u64, Mp3Error> {
        u64::from(index)
            .checked_mul(self.step_ticks)
            .and_then(|offset| offset.checked_add(self.start_ticks))
            .ok_or(Mp3Error::Overflow)
    }

    pub(crate) fn push_frame(&mut self, frame: FrameRef, payload: &[u8]) -> Result<(), Mp3Error> {
        // 1. Any window whose requested start this frame has now passed takes
        //    the previously stored candidate as its first frame — that is the
        //    "last packet at or before the target" rule.
        loop {
            let target = self.target_ticks(self.next_open)?;
            if frame.pts <= target {
                break;
            }
            let Some(candidate) = self.candidate else {
                break;
            };
            if self.done.len() + self.open.len() >= MAX_CHUNKS as usize {
                return Err(Mp3Error::PlanTooLarge);
            }
            let opened = OpenChunk::new(self.next_open, candidate, &self.candidate_bytes);
            if opened.byte_count > self.chunk_byte_ceiling {
                return Err(Mp3Error::ChunkOverEnvelope);
            }
            self.open.push(opened);
            self.next_open += 1;
        }

        // 2. Remember this frame as the newest candidate for the next window.
        if frame.pts <= self.target_ticks(self.next_open)? {
            self.candidate = Some(frame);
            self.candidate_bytes.clear();
            self.candidate_bytes.extend_from_slice(payload);
        }

        // 3. Close every window whose 300 s has elapsed, then extend the rest.
        while let Some(open) = self.open.first() {
            let end = self
                .target_ticks(open.index)?
                .checked_add(self.chunk_ticks)
                .ok_or(Mp3Error::Overflow)?;
            if frame.pts < end {
                break;
            }
            let closed = self.open.remove(0);
            self.done.push(closed.into_plan());
        }
        for open in &mut self.open {
            open.push(
                frame,
                payload,
                self.max_spans_per_chunk,
                self.chunk_byte_ceiling,
            )?;
        }
        Ok(())
    }

    /// Closes the walk and returns exactly `chunk_count` plans.
    ///
    /// A window whose requested start lies past the final frame degenerates to
    /// that final frame, which is what a seek past the end produces today.
    pub(crate) fn finish(mut self, chunk_count: u32) -> Result<Vec<ChunkPlan>, Mp3Error> {
        if chunk_count > MAX_CHUNKS {
            return Err(Mp3Error::PlanTooLarge);
        }
        for open in self.open.drain(..) {
            self.done.push(open.into_plan());
        }
        while (self.done.len() as u32) < chunk_count {
            let index = self.done.len() as u32;
            let candidate = self.candidate.ok_or(Mp3Error::NoMpegAudio)?;
            self.done
                .push(OpenChunk::new(index, candidate, &self.candidate_bytes).into_plan());
        }
        self.done.truncate(chunk_count as usize);
        for (position, plan) in self.done.iter().enumerate() {
            if plan.index as usize != position {
                return Err(Mp3Error::PlanTooLarge);
            }
        }
        Ok(self.done)
    }
}

/// Chunk count for a canonical duration, matching the container's
/// `while start < duration` loop over 298 s steps.
///
/// The exact walk is quantized to milliseconds first, because the count has
/// to agree with `eta::expected_chunk_count` and `media::validate_chunks`,
/// both of which see only the reported three-decimal duration. Without it, a
/// source whose exact duration sits a few hundred microseconds past a 298 s
/// multiple would plan one more chunk than the gateway believes exists, and
/// that extra chunk's valid interval would be empty — a rejected manifest.
pub fn chunk_count_for(canonical_micros: u64) -> u32 {
    let step_micros = STEP_SECONDS * 1_000;
    let count = crate::quantize_micros_to_millis(canonical_micros).div_ceil(step_micros);
    (count.max(1).min(u64::from(u32::MAX))) as u32
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::TICKS_PER_SECOND;

    /// Deterministic synthetic source byte for an absolute offset, so tests
    /// can rebuild any span's bytes without materializing the whole stream.
    fn source_byte(offset: u64) -> u8 {
        (offset % 251) as u8
    }

    fn source_bytes(start: u64, end: u64) -> Vec<u8> {
        (start..end).map(source_byte).collect()
    }

    fn span_digest(spans: &[Span]) -> [u8; 32] {
        let mut concat = Vec::new();
        for span in spans {
            concat.extend(source_bytes(span.start, span.end));
        }
        crate::sha256::digest(&concat)
    }

    /// Drives the planner with a synthetic constant-rate stream.
    fn plan(
        frames: u64,
        frame_bytes: u64,
        ticks_per_frame: u64,
        micros_per_frame: u64,
        start_ticks: u64,
        chunk_count: u32,
    ) -> Vec<ChunkPlan> {
        let mut planner = Planner::new(start_ticks, CHUNK_TICKS, STEP_TICKS, 8, u64::MAX);
        for index in 0..frames {
            let offset = index * frame_bytes;
            planner
                .push_frame(
                    FrameRef {
                        offset,
                        len: frame_bytes,
                        pts: index * ticks_per_frame,
                        micros: micros_per_frame,
                    },
                    &source_bytes(offset, offset + frame_bytes),
                )
                .expect("push");
        }
        planner.finish(chunk_count).expect("finish")
    }

    const CHUNK_TICKS: u64 = 300 * TICKS_PER_SECOND;
    const STEP_TICKS: u64 = 298 * TICKS_PER_SECOND;
    const MPEG1_44100_TICKS: u64 = 1152 * 320;

    #[test]
    fn dp225_window_selection_matches_the_pinned_ffmpeg_spans() {
        // 33915 frames at 44.1 kHz, no encoder delay: the pinned three-chunk
        // regression (frame counts 11485 / 11486 / 11100).
        let plans = plan(33_915, 1, MPEG1_44100_TICKS, 26_122, 0, 3);
        assert_eq!(plans.len(), 3);
        assert_eq!(plans[0].frames, 11_485);
        assert_eq!(plans[1].frames, 11_486);
        assert_eq!(plans[2].frames, 11_100);
        assert_eq!(plans[0].first_pts_ticks, 0);
        assert_eq!(plans[1].first_pts_ticks, 11_407 * MPEG1_44100_TICKS);
        assert_eq!(plans[2].first_pts_ticks, 22_815 * MPEG1_44100_TICKS);
        assert_eq!(plans[0].actual_duration_seconds(), 300.011);
        assert_eq!(plans[1].actual_duration_seconds(), 300.037);
        assert_eq!(plans[2].actual_duration_seconds(), 289.954);
        for (index, chunk) in plans.iter().enumerate() {
            assert_eq!(chunk.spans.len(), 1);
            assert_eq!(chunk.requested_start_seconds(), index as f64 * 298.0);
        }
    }

    #[test]
    fn encoder_delay_moves_every_window_one_frame_later() {
        // DA009: start_skip_samples 1105 → 353_600 ticks.
        let plans = plan(121_736, 1, MPEG1_44100_TICKS, 26_122, 353_600, 11);
        assert_eq!(plans.len(), 11);
        let firsts: Vec<u64> = plans
            .iter()
            .map(|plan| plan.first_pts_ticks / MPEG1_44100_TICKS)
            .collect();
        assert_eq!(
            firsts,
            vec![
                0, 11_408, 22_816, 34_224, 45_632, 57_040, 68_447, 79_855, 91_263, 102_671, 114_079
            ]
        );
        let counts: Vec<u64> = plans.iter().map(|plan| plan.frames).collect();
        assert_eq!(
            counts,
            vec![
                11_486, 11_486, 11_485, 11_485, 11_485, 11_485, 11_486, 11_486, 11_485, 11_485,
                7_657
            ]
        );

        // Without the encoder delay every window would start a frame earlier.
        let naive = plan(121_736, 1, MPEG1_44100_TICKS, 26_122, 0, 11);
        assert_eq!(naive[1].first_pts_ticks / MPEG1_44100_TICKS, 11_407);
    }

    #[test]
    fn seams_overlap_and_windows_stay_contiguous() {
        let plans = plan(33_915, 200, MPEG1_44100_TICKS, 26_122, 0, 3);
        for pair in plans.windows(2) {
            let previous_end = pair[0].spans[0].end;
            let next_start = pair[1].spans[0].start;
            assert!(next_start < previous_end, "seam must overlap");
        }
        // Every frame of the source is covered by at least one chunk.
        assert_eq!(plans[0].spans[0].start, 0);
        assert_eq!(plans[2].spans[0].end, 33_915 * 200);
    }

    #[test]
    fn single_frame_sources_still_produce_one_chunk() {
        let plans = plan(1, 417, MPEG1_44100_TICKS, 26_122, 0, 1);
        assert_eq!(plans.len(), 1);
        assert_eq!(plans[0].frames, 1);
        assert_eq!(plans[0].byte_count, 417);
    }

    #[test]
    fn windows_past_the_final_frame_degenerate_to_that_frame() {
        // Ask for four chunks from a source that only fills one.
        let plans = plan(100, 417, MPEG1_44100_TICKS, 26_122, 0, 4);
        assert_eq!(plans.len(), 4);
        assert_eq!(plans[0].frames, 100);
        for trailing in &plans[1..] {
            assert_eq!(trailing.frames, 1);
            assert_eq!(trailing.first_pts_ticks, 99 * MPEG1_44100_TICKS);
        }
    }

    #[test]
    fn resync_gaps_become_separate_copy_spans() {
        let mut planner = Planner::new(0, CHUNK_TICKS, STEP_TICKS, 8, u64::MAX);
        for index in 0..10u64 {
            // Insert a 30-byte junk gap before frame 5.
            let gap = if index >= 5 { 30 } else { 0 };
            let offset = index * 417 + gap;
            planner
                .push_frame(
                    FrameRef {
                        offset,
                        len: 417,
                        pts: index * MPEG1_44100_TICKS,
                        micros: 26_122,
                    },
                    &source_bytes(offset, offset + 417),
                )
                .expect("push");
        }
        let plans = planner.finish(1).expect("finish");
        assert_eq!(plans[0].spans.len(), 2);
        assert_eq!(plans[0].byte_count, 10 * 417);
        assert_eq!(
            plans[0].spans[0],
            Span {
                start: 0,
                end: 5 * 417
            }
        );
        assert_eq!(plans[0].spans[1].start, 5 * 417 + 30);
        // The streamed hash skips the junk exactly as the spans do.
        assert_eq!(plans[0].sha256, span_digest(&plans[0].spans));
    }

    /// The streamed per-chunk hash must equal a digest of the concatenated
    /// span bytes for every window shape: seam-overlapped neighbors,
    /// degenerate trailing windows, and multi-span resync survivors (covered
    /// in `resync_gaps_become_separate_copy_spans`).
    #[test]
    fn streamed_hashes_equal_span_concat_digests() {
        // Seam overlap: 2 s of frames belong to two open windows at once, so
        // one payload feeds two hashers.
        let overlapping = plan(33_915, 200, MPEG1_44100_TICKS, 26_122, 0, 3);
        for chunk in &overlapping {
            assert_eq!(
                chunk.sha256,
                span_digest(&chunk.spans),
                "chunk {} hash diverged from its spans",
                chunk.index
            );
        }

        // Encoder delay: window starts shift one frame later; hashes must
        // track the shifted selection, not the naive one.
        let delayed = plan(121_736, 100, MPEG1_44100_TICKS, 26_122, 353_600, 11);
        for chunk in &delayed {
            assert_eq!(
                chunk.sha256,
                span_digest(&chunk.spans),
                "chunk {}",
                chunk.index
            );
        }

        // Degenerate trailing windows hash the stored candidate frame.
        let degenerate = plan(100, 417, MPEG1_44100_TICKS, 26_122, 0, 4);
        let last_frame = span_digest(&[Span {
            start: 99 * 417,
            end: 100 * 417,
        }]);
        for trailing in &degenerate[1..] {
            assert_eq!(trailing.sha256, last_frame);
        }
        assert_eq!(degenerate[0].sha256, span_digest(&degenerate[0].spans));
    }

    #[test]
    fn span_and_chunk_caps_fail_closed() {
        let mut planner = Planner::new(0, CHUNK_TICKS, STEP_TICKS, 2, u64::MAX);
        for index in 0..10u64 {
            let result = planner.push_frame(
                FrameRef {
                    offset: index * 1000,
                    len: 417,
                    pts: index * MPEG1_44100_TICKS,
                    micros: 26_122,
                },
                &[0u8; 417],
            );
            if index >= 2 {
                assert_eq!(result, Err(Mp3Error::PlanTooLarge));
                return;
            }
            result.expect("push");
        }
        panic!("span cap never tripped");
    }

    #[test]
    fn chunk_counts_track_the_containers_loop() {
        assert_eq!(chunk_count_for(885_943_000), 3);
        assert_eq!(chunk_count_for(3_180_000_000), 11);
        assert_eq!(chunk_count_for(596_000_000), 2);
        assert_eq!(chunk_count_for(1), 1);
        assert_eq!(chunk_count_for(0), 1);
        assert_eq!(chunk_count_for(14_400_000_000), 49);
        // HH65: exact walk 14313.325714 s, reported 14313.326 s.
        assert_eq!(chunk_count_for(14_313_325_714), 49);
    }

    /// Sub-millisecond overshoot of a step boundary must not invent a chunk
    /// the gateway would reject: 596.0004 s reports as 596.000, and a third
    /// window starting at 596 s would have an empty valid interval.
    #[test]
    fn chunk_counts_follow_the_reported_duration_not_the_exact_walk() {
        // 596_000_500 is a tie and 596000 ms is even, so half-even keeps it.
        for micros in [596_000_001u64, 596_000_400, 596_000_499, 596_000_500] {
            assert_eq!(chunk_count_for(micros), 2, "{micros}");
            assert_eq!(crate::micros_to_seconds_q3(micros), 596.0);
        }
        for micros in [596_000_501u64, 596_001_000] {
            assert_eq!(chunk_count_for(micros), 3, "{micros}");
            assert!(crate::micros_to_seconds_q3(micros) > 596.0);
        }
    }

    /// The planner's count must equal what `eta::expected_chunk_count` and
    /// `media::validate_chunks` compute from the reported f64 duration.
    #[test]
    fn chunk_counts_agree_with_the_gateways_float_arithmetic() {
        for millis in (0..14_400_000u64).step_by(997) {
            let micros = millis * 1_000;
            let reported = crate::micros_to_seconds_q3(micros);
            let gateway = ((reported / STEP_SECONDS as f64).ceil() as u32).max(1);
            assert_eq!(chunk_count_for(micros), gateway, "{reported}");
        }
    }

    /// A source longer than the four-hour cap must fail closed rather than
    /// silently emit a plan that stops covering the audio. Compressed windows
    /// stand in for 64 real 300 s chunks so the test stays cheap.
    #[test]
    fn oversized_plans_are_refused_rather_than_truncated() {
        let mut planner = Planner::new(0, 2_000, 1_000, 8, u64::MAX);
        let mut error = None;
        for index in 0..500u64 {
            if let Err(failure) = planner.push_frame(
                FrameRef {
                    offset: index * 417,
                    len: 417,
                    pts: index * 1_000,
                    micros: 26_122,
                },
                &[0u8; 417],
            ) {
                error = Some(failure);
                break;
            }
        }
        assert_eq!(error, Some(Mp3Error::PlanTooLarge));

        // finish() refuses an out-of-range count even when the walk was short.
        let mut short = Planner::new(0, CHUNK_TICKS, STEP_TICKS, 8, u64::MAX);
        short
            .push_frame(
                FrameRef {
                    offset: 0,
                    len: 417,
                    pts: 0,
                    micros: 26_122,
                },
                &[0u8; 417],
            )
            .expect("push");
        assert_eq!(short.finish(MAX_CHUNKS + 1), Err(Mp3Error::PlanTooLarge));
    }
}
