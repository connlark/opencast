//! Intra-chunk transcript gap repair (2026-09-16 missing-ad-read incident).
//!
//! `@cf/openai/whisper-large-v3-turbo` occasionally skips tens of seconds of
//! speech that follows a pause or music sting. A decoder-window alignment
//! effect is the working explanation; the provider's internals are not
//! observed directly. On the incident chunk the exact bytes lost the
//! first 26.7 s of a host-read ad on four of five replays, and the outcome
//! flips with sub-second changes to the window alignment — a chunk cut
//! 1.7 KiB earlier transcribed fully, `vad_filter` alone lost 30 s. What was
//! stable across every replay: a retry window whose start is anchored at (or
//! up to ~3 s after) the last transcribed word's end transcribed the skipped
//! passage, with or without VAD, while a window starting 1.1 s *before* that
//! word's end skipped again.
//!
//! So the repair is reactive and anchored. After a chunk's model response is
//! in hand, find word-timeline holes at least `min_gap_seconds` long
//! (leading, interior, trailing), re-transcribe a window that starts at the
//! hole and runs a few seconds past it, and splice in only the words that lie
//! wholly inside the hole. The incident's music controls returned empty;
//! this is not a general hallucination guarantee. An empty repair is retried
//! once from a later anchor, then left unresolved.
//!
//! Everything here is pure and host-testable. `job_do` owns the model calls,
//! the spend budget, and persistence; a repair never fails a chunk.

use serde::Serialize;

use opencast_mp3_frame_core::header::{header_at, FrameHeader};

use crate::ai::{WhisperResponse, WhisperSegment, WhisperWord};

/// Provenance version written into the stored chunk response.
pub const REPAIR_VERSION: u32 = 2;
/// Default hole length that triggers a repair. Podcast speech pauses are
/// rarely above 2–3 s; the incident's partial skips ran 7–27 s.
pub const DEFAULT_MIN_GAP_SECONDS: f64 = 5.0;
/// Model calls per chunk, all holes and attempts included.
pub const MAX_CALLS_PER_CHUNK: u32 = 6;
/// Anchored attempts per hole before it is left unresolved.
pub const MAX_ATTEMPTS_PER_GAP: u32 = 2;
/// Later attempts anchor this much further into the hole.
pub const ATTEMPT_OFFSET_SECONDS: f64 = 1.5;
/// The window runs this far past the hole so the model sees speech resume;
/// those words duplicate existing ones and are dropped by the splice.
pub const TAIL_PAD_SECONDS: f64 = 3.0;
/// Windows shorter than this are not worth a call.
pub const MIN_WINDOW_SECONDS: f64 = 2.0;
/// Spliced words must sit this far inside the hole on both sides, so a
/// conservative boundary policy reduces overlap but can omit real edge
/// words and cannot rule out duplicates under larger timestamp drift.
pub const SPLICE_INSET_SECONDS: f64 = 0.1;
/// Whisper's own hallucination thresholds, applied per repair segment.
pub const NO_SPEECH_THRESHOLD: f64 = 0.6;
pub const LOGPROB_THRESHOLD: f64 = -1.0;
pub const COMPRESSION_RATIO_THRESHOLD: f64 = 2.4;
/// Two hole starts within this distance are the same hole for attempt
/// bookkeeping.
const GAP_IDENTITY_TOLERANCE_SECONDS: f64 = 0.25;
/// Bounded byte-wise resync while locating frames inside a chunk.
const MAX_RESYNC_BYTES: usize = 64 * 1024;

/// Per-job service-spend cap on repair audio: generous against the observed
/// two-to-three holes per episode, small against the job's own audio.
pub fn job_audio_cap_seconds(canonical_duration_seconds: f64) -> f64 {
    (0.15 * canonical_duration_seconds.max(0.0)).max(120.0)
}

/// A hole in one chunk's word timeline, chunk-relative seconds.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Gap {
    pub start: f64,
    pub end: f64,
}

impl Gap {
    pub fn length(&self) -> f64 {
        self.end - self.start
    }
}

/// Sorted `(start, end)` of every usable word in the response.
pub fn word_timeline(response: &WhisperResponse) -> Vec<(f64, f64)> {
    let mut timeline: Vec<(f64, f64)> = response
        .segments
        .iter()
        .flat_map(|segment| segment.words.iter())
        .filter(|word| !word.word.trim().is_empty())
        .filter(|word| word.start.is_finite() && word.end.is_finite() && word.end >= word.start)
        .map(|word| (word.start, word.end))
        .collect();
    timeline.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    timeline
}

/// Holes at least `min_gap_seconds` long: from the chunk start to the first
/// word, between consecutive words, and from the last word to the chunk end.
pub fn detect_gaps(
    response: &WhisperResponse,
    chunk_duration_seconds: f64,
    min_gap_seconds: f64,
) -> Vec<Gap> {
    if !chunk_duration_seconds.is_finite() || chunk_duration_seconds <= 0.0 {
        return Vec::new();
    }
    let min_gap = if min_gap_seconds.is_finite() && min_gap_seconds > 0.0 {
        min_gap_seconds
    } else {
        DEFAULT_MIN_GAP_SECONDS
    };
    let mut gaps = Vec::new();
    let mut cursor = 0.0f64;
    for (start, end) in word_timeline(response) {
        if start - cursor >= min_gap {
            gaps.push(Gap {
                start: cursor,
                end: start,
            });
        }
        cursor = cursor.max(end);
    }
    if chunk_duration_seconds - cursor >= min_gap {
        gaps.push(Gap {
            start: cursor,
            end: chunk_duration_seconds,
        });
    }
    gaps
}

/// The audio window one attempt re-transcribes, chunk-relative seconds.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Window {
    pub start: f64,
    pub end: f64,
}

impl Window {
    pub fn length(&self) -> f64 {
        self.end - self.start
    }
}

/// Attempt `attempt` (0-based) on `gap`: anchored at the hole start, moved
/// later by `ATTEMPT_OFFSET_SECONDS` per attempt, running `TAIL_PAD_SECONDS`
/// past the hole but never past the chunk.
pub fn plan_window(gap: &Gap, attempt: u32, chunk_duration_seconds: f64) -> Option<Window> {
    let start = gap.start + f64::from(attempt) * ATTEMPT_OFFSET_SECONDS;
    let end = (gap.end + TAIL_PAD_SECONDS).min(chunk_duration_seconds);
    if !start.is_finite() || !end.is_finite() || end - start < MIN_WINDOW_SECONDS {
        return None;
    }
    Some(Window { start, end })
}

/// Attempt bookkeeping across the bounded per-chunk loop. Holes are keyed by
/// their start: a hole whose start moved after a partial fill is a new hole.
#[derive(Debug, Default, Clone)]
pub struct AttemptLedger {
    attempted: Vec<(f64, u32)>,
}

impl AttemptLedger {
    pub fn attempts_for(&self, gap: &Gap) -> u32 {
        self.attempted
            .iter()
            .find(|(start, _)| (start - gap.start).abs() < GAP_IDENTITY_TOLERANCE_SECONDS)
            .map(|(_, attempts)| *attempts)
            .unwrap_or(0)
    }

    pub fn record(&mut self, gap: &Gap) {
        if let Some(entry) = self
            .attempted
            .iter_mut()
            .find(|(start, _)| (start - gap.start).abs() < GAP_IDENTITY_TOLERANCE_SECONDS)
        {
            entry.1 += 1;
        } else {
            self.attempted.push((gap.start, 1));
        }
    }
}

/// The next hole to work on — the longest one with attempts left — and the
/// attempt index it gets.
pub fn next_attempt(gaps: &[Gap], ledger: &AttemptLedger) -> Option<(Gap, u32)> {
    gaps.iter()
        .map(|gap| (*gap, ledger.attempts_for(gap)))
        .filter(|(_, attempts)| *attempts < MAX_ATTEMPTS_PER_GAP)
        .max_by(|a, b| {
            a.0.length()
                .partial_cmp(&b.0.length())
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| {
                    b.0.start
                        .partial_cmp(&a.0.start)
                        .unwrap_or(std::cmp::Ordering::Equal)
                })
        })
}

/// One window's frame-aligned byte range inside a chunk and the exact time
/// its first frame starts at, chunk-relative.
#[derive(Debug, Clone, PartialEq)]
pub struct FrameSlice {
    pub byte_range: std::ops::Range<usize>,
    pub start_seconds: f64,
    pub end_seconds: f64,
}

impl FrameSlice {
    pub fn length_seconds(&self) -> f64 {
        self.end_seconds - self.start_seconds
    }
}

/// Skips an ID3v2 tag at the head of a buffer (container-path chunks may
/// carry one; native chunks never do).
fn skip_id3v2(audio: &[u8]) -> usize {
    if audio.len() < 10 || &audio[..3] != b"ID3" {
        return 0;
    }
    let size = audio[6..10]
        .iter()
        .fold(0usize, |acc, byte| (acc << 7) | usize::from(byte & 0x7F));
    let footer = if audio[5] & 0x10 != 0 { 10 } else { 0 };
    (10 + size + footer).min(audio.len())
}

/// Walks the chunk's frames to cut `window` on frame boundaries: the slice
/// starts at the first frame whose start is at or after `window.start` and
/// ends before the first frame at or after `window.end`. Bounded resync
/// tolerates a little junk; anything worse yields `None` and no repair.
pub fn slice_frames(audio: &[u8], window: &Window) -> Option<FrameSlice> {
    if !window.start.is_finite() || !window.end.is_finite() || window.end <= window.start {
        return None;
    }
    let mut offset = skip_id3v2(audio);
    let mut seconds = 0.0f64;
    let mut resynced = 0usize;
    let mut slice_start: Option<(usize, f64)> = None;
    while offset + 4 <= audio.len() {
        let Some(raw) = header_at(audio, offset) else {
            break;
        };
        let Ok(header) = FrameHeader::parse(raw) else {
            resynced += 1;
            if resynced > MAX_RESYNC_BYTES {
                return None;
            }
            offset += 1;
            continue;
        };
        let frame_bytes = header.frame_bytes as usize;
        if frame_bytes < 4 || offset + frame_bytes > audio.len() {
            // Impossible geometry or a truncated tail: stop at the last
            // complete frame.
            break;
        }
        if slice_start.is_none() && seconds + 1e-9 >= window.start {
            slice_start = Some((offset, seconds));
        }
        if let Some((start, start_seconds)) = slice_start {
            if seconds >= window.end {
                return Some(FrameSlice {
                    byte_range: start..offset,
                    start_seconds,
                    end_seconds: seconds,
                });
            }
        }
        seconds += f64::from(header.samples_per_frame) / f64::from(header.sample_rate);
        offset += frame_bytes;
    }
    let (start, start_seconds) = slice_start?;
    if offset <= start {
        return None;
    }
    Some(FrameSlice {
        byte_range: start..offset,
        start_seconds,
        end_seconds: seconds,
    })
}

fn extra_f64(segment: &WhisperSegment, key: &str) -> Option<f64> {
    segment.extra.get(key).and_then(serde_json::Value::as_f64)
}

/// Whisper's own silence/repetition rejection, applied to a repair segment
/// before any of its words may enter the transcript.
pub fn looks_hallucinated(segment: &WhisperSegment) -> bool {
    extra_f64(segment, "no_speech_prob").is_some_and(|value| value > NO_SPEECH_THRESHOLD)
        || extra_f64(segment, "avg_logprob").is_some_and(|value| value < LOGPROB_THRESHOLD)
        || extra_f64(segment, "compression_ratio")
            .is_some_and(|value| value > COMPRESSION_RATIO_THRESHOLD)
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct SpliceOutcome {
    pub inserted_words: usize,
    pub inserted_segments: usize,
    pub dropped_outside_words: usize,
    pub rejected_segments: usize,
    /// Base segments that bridged the hole and were split around it.
    pub split_segments: usize,
    pub invalid_candidate: bool,
}

/// Try a repair transactionally. Reconstruct contiguous segment runs from
/// word placement (including interleaved model segments), preserving metadata
/// and every base word. Accept only a finite, bounded, stitchable candidate.
/// The inset deliberately favors omissions over uncertain boundary overlap;
/// text equality alone never removes genuine repetitions.
pub fn splice(
    base: &mut WhisperResponse,
    gap: &Gap,
    slice_start_seconds: f64,
    repair: &WhisperResponse,
    chunk_duration_seconds: f64,
) -> SpliceOutcome {
    let mut outcome = SpliceOutcome::default();
    let reject = |mut outcome: SpliceOutcome| {
        outcome.inserted_words = 0;
        outcome.inserted_segments = 0;
        outcome.split_segments = 0;
        outcome.invalid_candidate = true;
        outcome
    };
    if !chunk_duration_seconds.is_finite()
        || chunk_duration_seconds <= 0.0
        || !gap.start.is_finite()
        || !gap.end.is_finite()
        || gap.start < 0.0
        || gap.end > chunk_duration_seconds
        || gap.start >= gap.end
        || !slice_start_seconds.is_finite()
        || slice_start_seconds < gap.start
    {
        return reject(outcome);
    }
    let low = gap.start + SPLICE_INSET_SECONDS;
    let high = gap.end - SPLICE_INSET_SECONDS;
    let mut sources = base.segments.clone();
    // (source segment, word); stable sorting preserves equal-time repetitions.
    let mut placed: Vec<(usize, WhisperWord)> = Vec::new();
    let mut previous = f64::NEG_INFINITY;
    for (index, segment) in base.segments.iter().enumerate() {
        for word in &segment.words {
            if !valid_interval(word.start, word.end, chunk_duration_seconds)
                || word.start < previous
            {
                return reject(outcome);
            }
            previous = word.start;
            placed.push((index, word.clone()));
        }
    }
    for segment in &repair.segments {
        if looks_hallucinated(segment) {
            outcome.rejected_segments += 1;
            continue;
        }
        // Model padding outside the retry window is not evidence of speech
        // inside it. Geometry faults reject the candidate, not the base.
        let window_seconds =
            (gap.end + TAIL_PAD_SECONDS).min(chunk_duration_seconds) - slice_start_seconds + 0.1; // one MP3 frame / model rounding
        if !valid_interval(segment.start, segment.end, window_seconds) {
            return reject(outcome);
        }
        let source_index = sources.len();
        let mut source = segment.clone();
        source
            .extra
            .insert("gap_repair".into(), serde_json::Value::Bool(true));
        sources.push(source);
        for word in &segment.words {
            if !valid_interval(word.start, word.end, window_seconds)
                || word.start < segment.start
                || word.end > segment.end
            {
                return reject(outcome);
            }
            if word.word.trim().is_empty() {
                continue;
            }
            let start = word.start + slice_start_seconds;
            let end = word.end + slice_start_seconds;
            if start < low || end > high {
                outcome.dropped_outside_words += 1;
                continue;
            }
            placed.push((
                source_index,
                WhisperWord {
                    word: word.word.clone(),
                    start,
                    end,
                    extra: word.extra.clone(),
                },
            ));
            outcome.inserted_words += 1;
        }
    }
    if outcome.inserted_words == 0 {
        return outcome;
    }
    placed.sort_by(|a, b| a.1.start.total_cmp(&b.1.start));
    let mut runs: Vec<(usize, Vec<WhisperWord>)> = Vec::new();
    for (source, word) in placed {
        match runs.last_mut() {
            Some((last_source, words)) if *last_source == source => words.push(word),
            _ => runs.push((source, vec![word])),
        }
    }
    let mut counts = vec![0; sources.len()];
    for (source, _) in &runs {
        counts[*source] += 1;
    }
    outcome.split_segments = counts[..base.segments.len()]
        .iter()
        .filter(|n| **n > 1)
        .count();
    let mut candidate = base.clone();
    candidate.segments = runs
        .into_iter()
        .map(|(index, words)| {
            let mut extra = sources[index].extra.clone();
            if index < base.segments.len() && counts[index] > 1 {
                extra.insert("gap_repair_split".into(), serde_json::Value::Bool(true));
            }
            if index >= base.segments.len() {
                outcome.inserted_segments += 1;
            }
            WhisperSegment {
                start: words[0].start,
                end: words.iter().map(|w| w.end).fold(0.0, f64::max),
                text: words
                    .iter()
                    .map(|w| w.word.trim())
                    .collect::<Vec<_>>()
                    .join(" "),
                words,
                extra,
            }
        })
        .collect();
    candidate.text = Some(
        candidate
            .segments
            .iter()
            .map(|s| s.text.as_str())
            .filter(|s| !s.is_empty())
            .collect::<Vec<_>>()
            .join(" "),
    );
    if !candidate_is_safe(&candidate, chunk_duration_seconds) {
        return reject(outcome);
    }
    *base = candidate;
    outcome
}

fn valid_interval(start: f64, end: f64, duration: f64) -> bool {
    start.is_finite() && end.is_finite() && start >= 0.0 && end >= start && end <= duration
}

fn candidate_is_safe(response: &WhisperResponse, duration: f64) -> bool {
    let mut previous = f64::NEG_INFINITY;
    for segment in &response.segments {
        if !valid_interval(segment.start, segment.end, duration) {
            return false;
        }
        for word in &segment.words {
            if !valid_interval(word.start, word.end, duration)
                || word.start < previous
                || word.start < segment.start
                || word.end > segment.end
            {
                return false;
            }
            previous = word.start;
        }
    }
    // Exercise the production stitcher with its ordinary rejection rules.
    crate::stitch::stitch(
        &[response.to_chunk_transcription(0.0, duration)],
        crate::job::OVERLAP_SECONDS,
        duration,
    )
    .is_ok()
}

/// One attempt's content-free record for the stored response.
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct AttemptReport {
    pub gap_start: f64,
    pub gap_end: f64,
    pub attempt: u32,
    pub window_start: f64,
    pub window_end: f64,
    pub inserted_words: usize,
    pub outcome: &'static str,
}

/// Per-chunk summary, stored under the response's top-level `gap_repair`
/// key and mirrored into counters. Numbers only — never text.
#[derive(Debug, Clone, Serialize, Default, PartialEq)]
pub struct RepairReport {
    pub version: u32,
    pub min_gap_seconds: f64,
    pub gaps_detected: usize,
    pub calls: u32,
    pub audio_seconds: f64,
    pub gaps_filled: usize,
    pub gaps_unfilled: usize,
    pub words_filled: usize,
    pub rejected_segments: usize,
    pub dropped_outside_words: usize,
    pub errors: u32,
    pub budget_exhausted: bool,
    pub unaffordable_windows: u32,
    pub service_denied: bool,
    pub timed_out: bool,
    pub attempts: Vec<AttemptReport>,
}

impl RepairReport {
    pub fn new(min_gap_seconds: f64) -> Self {
        Self {
            version: REPAIR_VERSION,
            min_gap_seconds,
            ..Self::default()
        }
    }

    pub fn touched(&self) -> bool {
        self.gaps_detected > 0 || self.errors > 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn word(text: &str, start: f64, end: f64) -> WhisperWord {
        WhisperWord {
            word: text.to_string(),
            start,
            end,
            extra: serde_json::Map::new(),
        }
    }

    fn segment(words: Vec<WhisperWord>) -> WhisperSegment {
        let text = words
            .iter()
            .map(|word| word.word.as_str())
            .collect::<Vec<_>>()
            .join(" ");
        WhisperSegment {
            start: words.first().map(|word| word.start).unwrap_or(0.0),
            end: words.last().map(|word| word.end).unwrap_or(0.0),
            text,
            words,
            extra: serde_json::Map::new(),
        }
    }

    fn response(segments: Vec<WhisperSegment>) -> WhisperResponse {
        WhisperResponse {
            transcription_info: None,
            text: Some(
                segments
                    .iter()
                    .map(|segment| segment.text.clone())
                    .collect::<Vec<_>>()
                    .join(" "),
            ),
            segments,
            extra: serde_json::Map::new(),
        }
    }

    /// The incident shape: chunk 6 (1788 s) lost 1900.64–1927.30 absolute,
    /// i.e. 112.64–139.30 chunk-relative.
    fn incident_response() -> WhisperResponse {
        response(vec![
            segment(vec![
                word("crises", 108.0, 110.0),
                word("crisis.", 111.5, 112.64),
            ]),
            segment(vec![
                word("Listing", 139.30, 139.7),
                word("takes", 139.8, 140.1),
            ]),
        ])
    }

    #[test]
    fn detects_interior_leading_and_trailing_gaps() {
        let gaps = detect_gaps(&incident_response(), 300.037, 5.0);
        assert_eq!(
            gaps,
            vec![
                Gap {
                    start: 0.0,
                    end: 108.0
                },
                Gap {
                    start: 112.64,
                    end: 139.30
                },
                Gap {
                    start: 140.1,
                    end: 300.037
                },
            ]
        );
        // Natural pauses under the threshold are not holes.
        let dense = response(vec![segment(vec![
            word("a", 0.2, 0.5),
            word("b", 4.9, 5.2),
            word("c", 9.0, 9.4),
        ])]);
        assert_eq!(detect_gaps(&dense, 10.0, 5.0), Vec::<Gap>::new());
        // Unsorted words and reversed/empty ones are ignored, not fatal.
        let messy = response(vec![segment(vec![
            word("late", 20.0, 20.5),
            word(" ", 3.0, 3.5),
            word("rev", 10.0, 9.0),
            word("early", 0.5, 1.0),
        ])]);
        assert_eq!(
            detect_gaps(&messy, 30.0, 5.0),
            vec![
                Gap {
                    start: 1.0,
                    end: 20.0
                },
                Gap {
                    start: 20.5,
                    end: 30.0
                }
            ]
        );
    }

    #[test]
    fn empty_response_is_one_whole_gap_and_bad_durations_are_none() {
        let empty = response(vec![]);
        assert_eq!(
            detect_gaps(&empty, 62.458, 5.0),
            vec![Gap {
                start: 0.0,
                end: 62.458
            }]
        );
        assert_eq!(detect_gaps(&empty, 3.0, 5.0), Vec::<Gap>::new());
        assert_eq!(detect_gaps(&empty, f64::NAN, 5.0), Vec::<Gap>::new());
        assert_eq!(detect_gaps(&empty, 0.0, 5.0), Vec::<Gap>::new());
        // A nonsense threshold falls back to the default.
        assert_eq!(detect_gaps(&empty, 4.0, -1.0), Vec::<Gap>::new());
        assert_eq!(
            detect_gaps(&empty, 6.0, 0.0),
            vec![Gap {
                start: 0.0,
                end: 6.0
            }]
        );
    }

    #[test]
    fn windows_anchor_at_the_gap_and_step_later_per_attempt() {
        let gap = Gap {
            start: 112.64,
            end: 139.30,
        };
        assert_eq!(
            plan_window(&gap, 0, 300.037),
            Some(Window {
                start: 112.64,
                end: 142.30
            })
        );
        assert_eq!(
            plan_window(&gap, 1, 300.037),
            Some(Window {
                start: 114.14,
                end: 142.30
            })
        );
        // The tail pad never runs past the chunk.
        let tail = Gap {
            start: 290.0,
            end: 300.037,
        };
        assert_eq!(
            plan_window(&tail, 0, 300.037),
            Some(Window {
                start: 290.0,
                end: 300.037
            })
        );
        // Too short to be worth a call.
        let tiny = Gap {
            start: 299.0,
            end: 300.0,
        };
        assert_eq!(plan_window(&tiny, 0, 300.0), None);
        assert_eq!(
            plan_window(
                &Gap {
                    start: 0.0,
                    end: 5.0
                },
                3,
                6.0
            ),
            None
        );
    }

    #[test]
    fn attempts_take_the_longest_gap_first_and_bound_per_gap() {
        let gaps = vec![
            Gap {
                start: 0.0,
                end: 6.0,
            },
            Gap {
                start: 112.64,
                end: 139.30,
            },
            Gap {
                start: 200.0,
                end: 210.0,
            },
        ];
        let mut ledger = AttemptLedger::default();
        let (first, attempt) = next_attempt(&gaps, &ledger).expect("longest gap");
        assert_eq!((first.start, attempt), (112.64, 0));
        ledger.record(&first);
        let (second, attempt) = next_attempt(&gaps, &ledger).expect("same gap, second attempt");
        assert_eq!((second.start, attempt), (112.64, 1));
        ledger.record(&second);
        let (third, attempt) = next_attempt(&gaps, &ledger).expect("next longest");
        assert_eq!((third.start, attempt), (200.0, 0));
        // A hole whose start moved by less than the tolerance is the same hole.
        let moved = Gap {
            start: 112.8,
            end: 139.30,
        };
        assert_eq!(ledger.attempts_for(&moved), 2);
        // Exhaust everything.
        ledger.record(&third);
        ledger.record(&third);
        ledger.record(&gaps[0]);
        ledger.record(&gaps[0]);
        assert_eq!(next_attempt(&gaps, &ledger), None);
    }

    /// MPEG-1 Layer III, 44.1 kHz, 192 kbps, stereo, no padding, no CRC:
    /// 626-byte frames of 1152 samples (the incident source's geometry).
    const FRAME_HEADER: [u8; 4] = [0xFF, 0xFB, 0xB0, 0x00];
    const FRAME_BYTES: usize = 626;
    const FRAME_SECONDS: f64 = 1152.0 / 44_100.0;

    fn synthetic_chunk(frames: usize) -> Vec<u8> {
        let mut audio = Vec::with_capacity(frames * FRAME_BYTES);
        for index in 0..frames {
            audio.extend_from_slice(&FRAME_HEADER);
            audio.extend(std::iter::repeat_n((index & 0xFF) as u8, FRAME_BYTES - 4));
        }
        audio
    }

    #[test]
    fn synthetic_frame_header_parses_as_expected() {
        let header = FrameHeader::parse(u32::from_be_bytes(FRAME_HEADER)).expect("valid header");
        assert_eq!(header.frame_bytes as usize, FRAME_BYTES);
        assert_eq!(header.samples_per_frame, 1152);
        assert_eq!(header.sample_rate, 44_100);
    }

    #[test]
    fn slices_on_frame_boundaries_with_exact_start_time() {
        let audio = synthetic_chunk(1_000);
        let window = Window {
            start: 5.0,
            end: 8.0,
        };
        let slice = slice_frames(&audio, &window).expect("slice");
        // Frame 192 starts at 5.0155 s: the first frame at/after 5.0 s.
        let first_frame = (5.0 / FRAME_SECONDS).ceil() as usize;
        assert_eq!(first_frame, 192);
        assert_eq!(slice.byte_range.start, first_frame * FRAME_BYTES);
        assert!((slice.start_seconds - first_frame as f64 * FRAME_SECONDS).abs() < 1e-9);
        let end_frame = (8.0 / FRAME_SECONDS).ceil() as usize;
        assert_eq!(slice.byte_range.end, end_frame * FRAME_BYTES);
        assert!((slice.end_seconds - end_frame as f64 * FRAME_SECONDS).abs() < 1e-9);
        // The cut bytes are whole frames that start with a sync word.
        let cut = &audio[slice.byte_range.clone()];
        assert_eq!(cut.len() % FRAME_BYTES, 0);
        assert_eq!(&cut[..4], &FRAME_HEADER);
    }

    #[test]
    fn slice_runs_to_the_chunk_end_and_skips_tags_and_junk() {
        let frames = 200;
        let audio = synthetic_chunk(frames);
        let total = frames as f64 * FRAME_SECONDS;
        let slice = slice_frames(
            &audio,
            &Window {
                start: 3.0,
                end: 60.0,
            },
        )
        .expect("slice");
        assert_eq!(slice.byte_range.end, audio.len());
        assert!((slice.end_seconds - total).abs() < 1e-9);

        // ID3v2 tag (size 0x100 syncsafe) then junk before the first frame.
        let mut tagged = b"ID3\x04\x00\x00\x00\x00\x02\x00".to_vec();
        tagged.extend(std::iter::repeat_n(0x41u8, 0x100));
        tagged.extend_from_slice(&[0x00, 0x11, 0x22]);
        tagged.extend_from_slice(&audio);
        let tagged_slice = slice_frames(
            &tagged,
            &Window {
                start: 0.0,
                end: 1.0,
            },
        )
        .expect("slice");
        assert_eq!(tagged_slice.byte_range.start, 10 + 0x100 + 3);
        assert_eq!(tagged_slice.start_seconds, 0.0);

        // Window entirely past the audio, or degenerate: nothing to cut.
        assert_eq!(
            slice_frames(
                &audio,
                &Window {
                    start: 100.0,
                    end: 110.0
                }
            ),
            None
        );
        assert_eq!(
            slice_frames(
                &audio,
                &Window {
                    start: 5.0,
                    end: 5.0
                }
            ),
            None
        );
        assert_eq!(
            slice_frames(
                &[],
                &Window {
                    start: 0.0,
                    end: 5.0
                }
            ),
            None
        );
        // Unbounded junk gives up instead of guessing.
        let junk = vec![0x00u8; MAX_RESYNC_BYTES + 64];
        assert_eq!(
            slice_frames(
                &junk,
                &Window {
                    start: 0.0,
                    end: 5.0
                }
            ),
            None
        );
    }

    fn repair_response() -> WhisperResponse {
        // Window anchored at 112.64; times are window-relative like the model
        // returns them. "crisis." is the tail of the pre-gap word the window
        // clipped, "Listing" duplicates the first word after the gap.
        response(vec![
            segment(vec![word("crisis.", 0.0, 0.05)]),
            segment(vec![
                word("Hi,", 3.7, 3.9),
                word("folks.", 3.95, 4.3),
                word("Vinted.", 5.0, 5.5),
            ]),
            segment(vec![
                word("cash.", 25.8, 26.36),
                word("Listing", 26.66, 27.06),
            ]),
        ])
    }

    #[test]
    fn splice_keeps_only_words_wholly_inside_the_gap() {
        let mut base = incident_response();
        let gap = Gap {
            start: 112.64,
            end: 139.30,
        };
        let outcome = splice(&mut base, &gap, 112.64, &repair_response(), 300.0);
        assert_eq!(
            outcome,
            SpliceOutcome {
                inserted_words: 4,
                inserted_segments: 2,
                dropped_outside_words: 2,
                rejected_segments: 0,
                split_segments: 0,
                invalid_candidate: false,
            }
        );
        let words: Vec<(String, f64)> = base
            .segments
            .iter()
            .flat_map(|segment| segment.words.iter())
            .map(|word| (word.word.clone(), word.start))
            .collect();
        assert_eq!(
            words,
            vec![
                ("crises".to_string(), 108.0),
                ("crisis.".to_string(), 111.5),
                ("Hi,".to_string(), 116.34),
                ("folks.".to_string(), 116.59),
                ("Vinted.".to_string(), 117.64),
                ("cash.".to_string(), 138.44),
                ("Listing".to_string(), 139.30),
                ("takes".to_string(), 139.8),
            ]
        );
        let mut previous = f64::NEG_INFINITY;
        for segment in &base.segments {
            for word in &segment.words {
                assert!(word.start >= previous);
                previous = word.start;
            }
        }
        let repaired: Vec<&WhisperSegment> = base
            .segments
            .iter()
            .filter(|segment| segment.extra.get("gap_repair") == Some(&json!(true)))
            .collect();
        assert_eq!(repaired.len(), 2);
        assert_eq!(repaired[0].text, "Hi, folks. Vinted.");
        assert_eq!(
            base.text.as_deref(),
            Some("crises crisis. Hi, folks. Vinted. cash. Listing takes")
        );
        // The sparse fixture leaves a residual hole between "Vinted." and
        // "cash."; the detector reports it as a new hole (its own attempts),
        // while the filled head of the original hole is gone.
        assert_eq!(
            detect_gaps(&base, 141.0, 5.0),
            vec![
                Gap {
                    start: 0.0,
                    end: 108.0
                },
                Gap {
                    start: 118.14,
                    end: 138.44
                },
            ]
        );
    }

    #[test]
    fn splice_rejects_hallucinated_segments_and_leaves_base_untouched() {
        let mut base = incident_response();
        let before = base.clone();
        let gap = Gap {
            start: 112.64,
            end: 139.30,
        };
        let mut hallucinated = repair_response();
        hallucinated.segments[1]
            .extra
            .insert("no_speech_prob".into(), json!(0.9));
        hallucinated.segments[2]
            .extra
            .insert("compression_ratio".into(), json!(3.1));
        hallucinated.segments[0]
            .extra
            .insert("avg_logprob".into(), json!(-1.4));
        let outcome = splice(&mut base, &gap, 112.64, &hallucinated, 300.0);
        assert_eq!(
            outcome,
            SpliceOutcome {
                inserted_words: 0,
                inserted_segments: 0,
                dropped_outside_words: 0,
                rejected_segments: 3,
                split_segments: 0,
                invalid_candidate: false,
            }
        );
        assert_eq!(base.segments.len(), before.segments.len());
        assert_eq!(base.text, before.text);
        // Empty retries (genuine silence) change nothing either.
        assert_eq!(
            splice(&mut base, &gap, 112.64, &response(vec![]), 300.0),
            SpliceOutcome::default()
        );
        assert_eq!(base.segments.len(), before.segments.len());
    }

    #[test]
    fn splice_splits_a_base_segment_that_bridges_the_hole() {
        // The workerd fake (and a model segment spanning a timestamp jump):
        // one segment with words on both sides of the hole.
        let mut base = response(vec![segment(vec![
            word("remote", 1.6, 2.0),
            word("transcription", 8.5, 8.9),
            word("chunk0", 9.5, 9.9),
        ])]);
        let gap = Gap {
            start: 2.0,
            end: 8.5,
        };
        let repair = response(vec![segment(vec![
            word("repair0", 1.0, 1.4),
            word("repair1", 5.0, 5.4),
        ])]);
        let outcome = splice(&mut base, &gap, 2.0, &repair, 10.0);
        assert_eq!(outcome.inserted_words, 2);
        assert_eq!(outcome.split_segments, 1);
        let texts: Vec<&str> = base.segments.iter().map(|s| s.text.as_str()).collect();
        assert_eq!(
            texts,
            vec!["remote", "repair0 repair1", "transcription chunk0"]
        );
        let starts: Vec<f64> = base
            .segments
            .iter()
            .flat_map(|s| s.words.iter().map(|w| w.start))
            .collect();
        assert_eq!(starts, vec![1.6, 3.0, 7.0, 8.5, 9.5]);
        assert_eq!(
            base.segments[0].extra.get("gap_repair_split"),
            Some(&json!(true))
        );
        assert_eq!(
            base.segments[2].extra.get("gap_repair_split"),
            Some(&json!(true))
        );
        assert_eq!(base.segments[1].extra.get("gap_repair"), Some(&json!(true)));
        assert_eq!(
            base.text.as_deref(),
            Some("remote repair0 repair1 transcription chunk0")
        );
        assert_eq!(detect_gaps(&base, 10.0, 5.0), Vec::<Gap>::new());
    }

    #[test]
    fn hallucination_guard_uses_whisper_thresholds_and_tolerates_missing_fields() {
        let mut plain = segment(vec![word("a", 0.0, 0.5)]);
        assert!(!looks_hallucinated(&plain));
        plain.extra.insert("no_speech_prob".into(), json!(0.2));
        plain.extra.insert("avg_logprob".into(), json!(-0.3));
        plain.extra.insert("compression_ratio".into(), json!(1.7));
        assert!(!looks_hallucinated(&plain));
        plain.extra.insert("no_speech_prob".into(), json!(0.61));
        assert!(looks_hallucinated(&plain));
        plain
            .extra
            .insert("no_speech_prob".into(), json!("garbage"));
        assert!(!looks_hallucinated(&plain));
    }

    #[test]
    fn job_cap_scales_with_the_source_but_never_below_the_floor() {
        assert_eq!(job_audio_cap_seconds(3_340.434), 3_340.434 * 0.15);
        assert_eq!(job_audio_cap_seconds(60.0), 120.0);
        assert_eq!(job_audio_cap_seconds(-5.0), 120.0);
    }

    #[test]
    fn leading_hole_orders_by_words_instead_of_coarse_segment_start() {
        let mut base = response(vec![segment(vec![word("Resume", 10.0, 11.0)])]);
        base.segments[0].start = 0.0;
        let repair = response(vec![segment(vec![word("Recovered", 1.0, 3.0)])]);
        let outcome = splice(
            &mut base,
            &Gap {
                start: 0.0,
                end: 10.0,
            },
            0.0,
            &repair,
            12.0,
        );
        assert_eq!(outcome.inserted_words, 1);
        assert_eq!(base.text.as_deref(), Some("Recovered Resume"));
        assert!(candidate_is_safe(&base, 12.0));
    }

    #[test]
    fn interleaved_repair_segments_are_reconstructed_as_ordered_runs() {
        let mut base = response(vec![segment(vec![word("after", 10.0, 11.0)])]);
        let repair = response(vec![
            segment(vec![word("first", 1.0, 2.0), word("last", 8.0, 9.0)]),
            segment(vec![word("middle", 4.0, 5.0)]),
        ]);
        let outcome = splice(
            &mut base,
            &Gap {
                start: 0.0,
                end: 10.0,
            },
            0.0,
            &repair,
            12.0,
        );
        assert_eq!(outcome.inserted_words, 3);
        assert_eq!(base.text.as_deref(), Some("first middle last after"));
        assert!(candidate_is_safe(&base, 12.0));
    }

    #[test]
    fn invalid_candidates_leave_the_base_byte_equivalent_and_stitchable() {
        let base = response(vec![segment(vec![word("after", 10.0, 11.0)])]);
        for (start, end) in [
            (f64::NAN, 3.0),
            (1.0, f64::INFINITY),
            (-1.0, 3.0),
            (3.0, 1.0),
            (1.0, 40.0),
        ] {
            let mut candidate = base.clone();
            let repair = response(vec![segment(vec![word("bad", start, end)])]);
            let before = serde_json::to_vec(&candidate).unwrap();
            let result = splice(
                &mut candidate,
                &Gap {
                    start: 0.0,
                    end: 10.0,
                },
                0.0,
                &repair,
                12.0,
            );
            assert!(result.invalid_candidate);
            assert_eq!(serde_json::to_vec(&candidate).unwrap(), before);
            assert!(candidate_is_safe(&candidate, 12.0));
        }
        // Bad coarse geometry cannot be hidden by otherwise valid words.
        let mut repair = response(vec![segment(vec![word("valid", 1.0, 3.0)])]);
        repair.segments[0].end = 2.0;
        let mut candidate = base.clone();
        assert!(
            splice(
                &mut candidate,
                &Gap {
                    start: 0.0,
                    end: 10.0
                },
                0.0,
                &repair,
                12.0
            )
            .invalid_candidate
        );
        assert_eq!(
            serde_json::to_vec(&candidate).unwrap(),
            serde_json::to_vec(&base).unwrap()
        );
    }

    #[test]
    fn missing_confidence_is_accepted_without_text_deduplication() {
        let mut base = response(vec![segment(vec![word("yes", 10.0, 11.0)])]);
        let repair = response(vec![segment(vec![
            word("yes", 1.0, 2.0),
            word("yes", 3.0, 4.0),
        ])]);
        assert_eq!(
            splice(
                &mut base,
                &Gap {
                    start: 0.0,
                    end: 10.0
                },
                0.0,
                &repair,
                12.0
            )
            .inserted_words,
            2
        );
        assert_eq!(base.text.as_deref(), Some("yes yes yes"));
    }

    #[test]
    fn boundary_policy_is_conservative_but_does_not_claim_drift_deduplication() {
        let mut base = response(vec![segment(vec![word("Listing", 10.0, 11.0)])]);
        let repair = response(vec![segment(vec![
            word("edge", 0.0, 0.3),
            word("speech", 1.0, 2.0),
            word("Listing", 9.3, 9.6),
            word("edge", 9.8, 10.0),
        ])]);
        let outcome = splice(
            &mut base,
            &Gap {
                start: 0.0,
                end: 10.0,
            },
            0.0,
            &repair,
            12.0,
        );
        assert_eq!(outcome.dropped_outside_words, 2);
        assert_eq!(base.text.as_deref(), Some("speech Listing Listing"));
        assert!(candidate_is_safe(&base, 12.0));
    }

    #[test]
    fn report_serializes_numbers_only() {
        let mut report = RepairReport::new(5.0);
        report.gaps_detected = 1;
        report.attempts.push(AttemptReport {
            gap_start: 112.64,
            gap_end: 139.30,
            attempt: 0,
            window_start: 112.64,
            window_end: 142.30,
            inserted_words: 4,
            outcome: "filled",
        });
        let value = serde_json::to_value(&report).expect("serializes");
        assert_eq!(value["version"], json!(REPAIR_VERSION));
        assert_eq!(value["attempts"][0]["outcome"], json!("filled"));
        assert!(report.touched());
        assert!(!RepairReport::new(5.0).touched());
    }
}
