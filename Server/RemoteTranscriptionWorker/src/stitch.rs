//! Stitcher (v2 pinned contract; see the golden fixtures and STATE.md):
//! native-word timestamp-midpoint ownership at each seam boundary
//! (`seam start + overlap/2`), segments surviving iff they keep ≥1 owned
//! word with words trimmed / start-end clamped / text rebuilt from owned
//! words, sequential re-numbering, and a normalized transcript SHA-256 using
//! the bakeoff normalization. Must reproduce the committed golden fixtures
//! bit-for-bit; the Swift mapper implements the same normalization.
//!
//! Adjacent overlap copies are aligned one-to-one by normalized word text,
//! interval adjacency, and midpoint skew. When timestamp drift makes both
//! copies appear owned, the copies' consensus midpoint selects the owning
//! chunk and the other copy is dropped. The rule is seam-local, so genuine
//! repetitions within a chunk or outside the overlap survive.
//!
//! Adjacent chunks transcribe their shared overlap independently, so their
//! timelines disagree by up to ~1s at a seam; midpoint ownership can then emit
//! a word pair whose starts run backwards (job-4jODJ84DNjOpsQkcAn6ehw: chunk 6
//! kept "You" at 2086.86, chunk 7 kept "on" at 2086.82). Ordering is repaired
//! by clamping the later word's start forward — a backward jump larger than
//! `overlap_seconds` cannot come from seam disagreement and still rejects the
//! transcript. Clamping never fires on monotonic input, preserving fixture
//! parity.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashSet;

pub const PIPELINE_VERSION: &str = "stitch-v2";
const SEAM_DEDUPE_EPSILON_SECONDS: f64 = 0.9;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ModelWord {
    pub text: String,
    pub start: f64,
    pub end: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ModelSegment {
    pub start: f64,
    pub end: f64,
    #[serde(default)]
    pub text: String,
    #[serde(default)]
    pub words: Vec<ModelWord>,
}

#[derive(Debug, Clone)]
pub struct ChunkTranscription {
    pub requested_start_seconds: f64,
    pub segments: Vec<ModelSegment>,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct StitchedSegment {
    pub id: u32,
    pub start: f64,
    pub end: f64,
    pub text: String,
    pub words: Vec<ModelWord>,
}

#[derive(Debug, Clone)]
pub struct StitchedTranscript {
    pub segments: Vec<StitchedSegment>,
    pub text: String,
    pub word_count: usize,
    pub deduplicated_word_count: usize,
    pub normalized_transcript_sha256: String,
}

#[derive(Debug, Clone, PartialEq)]
pub enum StitchError {
    NonFiniteTimestamp {
        chunk_index: usize,
    },
    OutOfOrderWords {
        chunk_index: usize,
        prev_start: f64,
        next_start: f64,
    },
    Empty,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct WordLocation {
    chunk_index: usize,
    segment_index: usize,
    word_index: usize,
}

#[derive(Debug)]
struct SeamWordRef {
    location: WordLocation,
    normalized: String,
    start: f64,
    end: f64,
    midpoint: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum AlignmentChoice {
    End,
    SkipRight,
    SkipLeft,
    Match,
}

#[derive(Debug, Clone, Copy)]
struct AlignmentScore {
    matches: usize,
    cost: f64,
    choice: AlignmentChoice,
}

fn choice_rank(choice: AlignmentChoice) -> u8 {
    match choice {
        AlignmentChoice::End => 0,
        AlignmentChoice::SkipRight => 1,
        AlignmentChoice::SkipLeft => 2,
        AlignmentChoice::Match => 3,
    }
}

fn better_alignment(candidate: AlignmentScore, current: AlignmentScore) -> bool {
    candidate.matches > current.matches
        || (candidate.matches == current.matches
            && (candidate.cost < current.cost
                || (candidate.cost == current.cost
                    && choice_rank(candidate.choice) > choice_rank(current.choice))))
}

fn interval_gap(left: &SeamWordRef, right: &SeamWordRef) -> f64 {
    (right.start - left.end)
        .max(left.start - right.end)
        .max(0.0)
}

fn can_align(left: &SeamWordRef, right: &SeamWordRef) -> bool {
    !left.normalized.is_empty()
        && left.normalized == right.normalized
        && (left.midpoint - right.midpoint).abs() <= SEAM_DEDUPE_EPSILON_SECONDS
        && interval_gap(left, right) <= SEAM_DEDUPE_EPSILON_SECONDS
}

fn ordered_matches(left: &[SeamWordRef], right: &[SeamWordRef]) -> Vec<(usize, usize)> {
    let mut scores = vec![
        vec![
            AlignmentScore {
                matches: 0,
                cost: 0.0,
                choice: AlignmentChoice::End,
            };
            right.len() + 1
        ];
        left.len() + 1
    ];

    for left_index in (0..=left.len()).rev() {
        for right_index in (0..=right.len()).rev() {
            if left_index == left.len() && right_index == right.len() {
                continue;
            }
            if left_index == left.len() {
                scores[left_index][right_index] = AlignmentScore {
                    choice: AlignmentChoice::SkipRight,
                    ..scores[left_index][right_index + 1]
                };
                continue;
            }
            if right_index == right.len() {
                scores[left_index][right_index] = AlignmentScore {
                    choice: AlignmentChoice::SkipLeft,
                    ..scores[left_index + 1][right_index]
                };
                continue;
            }

            let mut best = AlignmentScore {
                choice: AlignmentChoice::SkipLeft,
                ..scores[left_index + 1][right_index]
            };
            let skip_right = AlignmentScore {
                choice: AlignmentChoice::SkipRight,
                ..scores[left_index][right_index + 1]
            };
            if better_alignment(skip_right, best) {
                best = skip_right;
            }
            if can_align(&left[left_index], &right[right_index]) {
                let next = scores[left_index + 1][right_index + 1];
                let matched = AlignmentScore {
                    matches: next.matches + 1,
                    cost: next.cost
                        + (left[left_index].midpoint - right[right_index].midpoint).abs(),
                    choice: AlignmentChoice::Match,
                };
                if better_alignment(matched, best) {
                    best = matched;
                }
            }
            scores[left_index][right_index] = best;
        }
    }

    let mut matches = Vec::new();
    let (mut left_index, mut right_index) = (0, 0);
    while left_index < left.len() && right_index < right.len() {
        match scores[left_index][right_index].choice {
            AlignmentChoice::Match => {
                matches.push((left_index, right_index));
                left_index += 1;
                right_index += 1;
            }
            AlignmentChoice::SkipLeft => left_index += 1,
            AlignmentChoice::SkipRight => right_index += 1,
            AlignmentChoice::End => break,
        }
    }
    matches
}

fn seam_word_refs(
    chunk: &ChunkTranscription,
    chunk_index: usize,
    window_start: f64,
    window_end: f64,
) -> Vec<SeamWordRef> {
    let mut refs = Vec::new();
    for (segment_index, segment) in chunk.segments.iter().enumerate() {
        for (word_index, word) in segment.words.iter().enumerate() {
            let start = word.start + chunk.requested_start_seconds;
            let end = word.end + chunk.requested_start_seconds;
            if end < window_start || start > window_end {
                continue;
            }
            refs.push(SeamWordRef {
                location: WordLocation {
                    chunk_index,
                    segment_index,
                    word_index,
                },
                normalized: normalized_tokens(&word.text).join(" "),
                start,
                end,
                midpoint: (start + end) / 2.0,
            });
        }
    }
    refs
}

fn seam_duplicate_drops(
    chunks: &[ChunkTranscription],
    overlap_seconds: f64,
) -> HashSet<WordLocation> {
    let mut drops = HashSet::new();
    for (left_index, chunks) in chunks.windows(2).enumerate() {
        let left_chunk = &chunks[0];
        let right_chunk = &chunks[1];
        let seam_start = right_chunk.requested_start_seconds;
        let seam_end = seam_start + overlap_seconds;
        let boundary = seam_start + overlap_seconds / 2.0;
        let left = seam_word_refs(left_chunk, left_index, seam_start, seam_end);
        let right = seam_word_refs(right_chunk, left_index + 1, seam_start, seam_end);
        for (left_match, right_match) in ordered_matches(&left, &right) {
            let left_word = &left[left_match];
            let right_word = &right[right_match];
            if left_word.midpoint >= boundary || right_word.midpoint < boundary {
                continue;
            }
            let consensus_midpoint = (left_word.midpoint + right_word.midpoint) / 2.0;
            drops.insert(if consensus_midpoint < boundary {
                right_word.location
            } else {
                left_word.location
            });
        }
    }
    drops
}

pub fn stitch(
    chunks: &[ChunkTranscription],
    overlap_seconds: f64,
) -> Result<StitchedTranscript, StitchError> {
    let duplicate_drops = seam_duplicate_drops(chunks, overlap_seconds);
    let boundaries: Vec<f64> = chunks
        .iter()
        .skip(1)
        .map(|chunk| chunk.requested_start_seconds + overlap_seconds / 2.0)
        .collect();

    let mut segments: Vec<StitchedSegment> = Vec::new();
    let mut previous_start: Option<f64> = None;
    for (index, chunk) in chunks.iter().enumerate() {
        let lower = if index > 0 {
            Some(boundaries[index - 1])
        } else {
            None
        };
        let upper = boundaries.get(index).copied();
        let offset = chunk.requested_start_seconds;

        for (segment_index, segment) in chunk.segments.iter().enumerate() {
            let mut owned: Vec<ModelWord> = Vec::new();
            for (word_index, word) in segment.words.iter().enumerate() {
                let mut start = word.start + offset;
                let mut end = word.end + offset;
                if !start.is_finite() || !end.is_finite() {
                    return Err(StitchError::NonFiniteTimestamp { chunk_index: index });
                }
                let midpoint = (start + end) / 2.0;
                if lower.is_some_and(|lower| midpoint < lower) {
                    continue;
                }
                if upper.is_some_and(|upper| midpoint >= upper) {
                    continue;
                }
                if duplicate_drops.contains(&WordLocation {
                    chunk_index: index,
                    segment_index,
                    word_index,
                }) {
                    continue;
                }
                if let Some(previous) = previous_start {
                    if start + 0.001 < previous {
                        if previous - start > overlap_seconds {
                            return Err(StitchError::OutOfOrderWords {
                                chunk_index: index,
                                prev_start: previous,
                                next_start: start,
                            });
                        }
                        start = previous;
                        end = end.max(start);
                    }
                }
                previous_start = Some(start);
                owned.push(ModelWord {
                    text: word.text.trim().to_string(),
                    start,
                    end,
                });
            }
            let (Some(first), Some(last)) = (owned.first(), owned.last()) else {
                continue;
            };
            let segment_start = (segment.start + offset).max(first.start);
            let segment_end = last.end;
            let text = owned
                .iter()
                .map(|word| word.text.as_str())
                .collect::<Vec<_>>()
                .join(" ");
            segments.push(StitchedSegment {
                id: 0,
                start: segment_start,
                end: segment_end,
                text,
                words: owned,
            });
        }
    }

    if segments.is_empty() {
        return Err(StitchError::Empty);
    }
    for (id, segment) in segments.iter_mut().enumerate() {
        segment.id = id as u32;
    }

    let all_words: Vec<&ModelWord> = segments
        .iter()
        .flat_map(|segment| segment.words.iter())
        .collect();
    let text = all_words
        .iter()
        .map(|word| word.text.as_str())
        .collect::<Vec<_>>()
        .join(" ");
    let normalized = normalized_transcript_sha256(&text);
    Ok(StitchedTranscript {
        word_count: all_words.len(),
        deduplicated_word_count: duplicate_drops.len(),
        segments,
        text,
        normalized_transcript_sha256: normalized,
    })
}

/// Bakeoff normalization, mirrored bit-for-bit by
/// `OpenCastRemoteTranscriptNormalization` in the Swift package: lowercase,
/// strip apostrophes, collapse digit-grouping commas with python `re.sub`
/// non-overlapping semantics, other non-`[a-z0-9 ]` to space, split, join
/// with single spaces.
pub fn normalized_tokens(text: &str) -> Vec<String> {
    let lowered = text.to_lowercase();
    let without_apostrophes: String = lowered
        .chars()
        .filter(|character| !matches!(character, '\u{2018}' | '\u{2019}' | '\''))
        .collect();
    let collapsed = collapse_digit_grouping_commas(&without_apostrophes);
    let spaced: String = collapsed
        .chars()
        .map(|character| {
            if character.is_ascii_lowercase() || character.is_ascii_digit() || character == ' ' {
                character
            } else {
                ' '
            }
        })
        .collect();
    spaced.split_whitespace().map(str::to_string).collect()
}

pub fn normalized_transcript_sha256(text: &str) -> String {
    let joined = normalized_tokens(text).join(" ");
    hex::encode(Sha256::digest(joined.as_bytes()))
}

fn collapse_digit_grouping_commas(text: &str) -> String {
    let characters: Vec<char> = text.chars().collect();
    let mut result = String::with_capacity(characters.len());
    let mut index = 0;
    while index < characters.len() {
        if index + 2 < characters.len()
            && characters[index].is_ascii_digit()
            && characters[index + 1] == ','
            && characters[index + 2].is_ascii_digit()
        {
            result.push(characters[index]);
            result.push(characters[index + 2]);
            index += 3;
            continue;
        }
        result.push(characters[index]);
        index += 1;
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalization_matches_bakeoff_rules() {
        assert_eq!(
            normalized_tokens("It\u{2019}s 3,000 Bugs — don't panic!"),
            vec!["its", "3000", "bugs", "dont", "panic"]
        );
        assert_eq!(normalized_tokens("1,2,3"), vec!["12", "3"]);
        assert_eq!(normalized_tokens("1,234,567"), vec!["1234567"]);
        assert!(normalized_tokens("  ").is_empty());
    }

    #[test]
    fn words_at_seams_follow_midpoint_ownership() {
        let chunks = vec![
            ChunkTranscription {
                requested_start_seconds: 0.0,
                segments: vec![ModelSegment {
                    start: 296.0,
                    end: 300.0,
                    text: String::new(),
                    words: vec![
                        ModelWord {
                            text: "left".into(),
                            start: 297.0,
                            end: 298.0,
                        },
                        // Midpoint 299.25 >= boundary 299.0: dropped from left chunk.
                        ModelWord {
                            text: "dropped".into(),
                            start: 299.0,
                            end: 299.5,
                        },
                    ],
                }],
            },
            ChunkTranscription {
                requested_start_seconds: 298.0,
                segments: vec![ModelSegment {
                    start: 0.0,
                    end: 4.0,
                    text: String::new(),
                    words: vec![
                        // Absolute 298.2-298.8, midpoint 298.5 < 299.0: dropped from right chunk.
                        ModelWord {
                            text: "early".into(),
                            start: 0.2,
                            end: 0.8,
                        },
                        // Absolute 299.2-299.8, midpoint 299.5 >= 299.0: owned.
                        ModelWord {
                            text: "right".into(),
                            start: 1.2,
                            end: 1.8,
                        },
                    ],
                }],
            },
        ];
        let stitched = stitch(&chunks, 2.0).expect("stitches");
        let words: Vec<&str> = stitched
            .segments
            .iter()
            .flat_map(|segment| segment.words.iter().map(|word| word.text.as_str()))
            .collect();
        assert_eq!(words, vec!["left", "right"]);
        assert_eq!(stitched.segments.len(), 2);
        assert_eq!(stitched.segments[0].id, 0);
        assert_eq!(stitched.segments[1].id, 1);
        assert!((stitched.segments[1].start - 299.2).abs() < 1e-9);
    }

    #[test]
    fn seam_duplicate_keeps_the_consensus_midpoint_owner() {
        let chunks = vec![
            ChunkTranscription {
                requested_start_seconds: 0.0,
                segments: vec![ModelSegment {
                    start: 298.22,
                    end: 299.52,
                    text: String::new(),
                    words: vec![ModelWord {
                        text: "prescriptive".into(),
                        start: 298.22,
                        end: 299.52,
                    }],
                }],
            },
            ChunkTranscription {
                requested_start_seconds: 298.0,
                segments: vec![ModelSegment {
                    start: 0.98,
                    end: 1.5,
                    text: String::new(),
                    words: vec![ModelWord {
                        text: " prescriptive".into(),
                        start: 0.98,
                        end: 1.5,
                    }],
                }],
            },
        ];

        let stitched = stitch(&chunks, 2.0).expect("stitches");
        let words: Vec<&ModelWord> = stitched
            .segments
            .iter()
            .flat_map(|segment| segment.words.iter())
            .collect();
        assert_eq!(words.len(), 1);
        assert_eq!(words[0].text, "prescriptive");
        assert_eq!(words[0].start, 298.98);
        assert_eq!(stitched.deduplicated_word_count, 1);
    }

    #[test]
    fn legitimate_repetitions_and_out_of_window_echoes_survive() {
        let chunks = vec![
            ChunkTranscription {
                requested_start_seconds: 0.0,
                segments: vec![
                    ModelSegment {
                        start: 100.0,
                        end: 101.8,
                        text: String::new(),
                        words: vec![
                            ModelWord {
                                text: "New".into(),
                                start: 100.0,
                                end: 100.3,
                            },
                            ModelWord {
                                text: "York".into(),
                                start: 100.3,
                                end: 100.7,
                            },
                            ModelWord {
                                text: "New".into(),
                                start: 101.0,
                                end: 101.3,
                            },
                            ModelWord {
                                text: "York".into(),
                                start: 101.3,
                                end: 101.8,
                            },
                        ],
                    },
                    ModelSegment {
                        start: 250.0,
                        end: 250.4,
                        text: String::new(),
                        words: vec![ModelWord {
                            text: "echo".into(),
                            start: 250.0,
                            end: 250.4,
                        }],
                    },
                    ModelSegment {
                        start: 298.2,
                        end: 299.6,
                        text: String::new(),
                        words: vec![
                            ModelWord {
                                text: "very".into(),
                                start: 298.2,
                                end: 298.6,
                            },
                            ModelWord {
                                text: "very".into(),
                                start: 299.2,
                                end: 299.6,
                            },
                        ],
                    },
                ],
            },
            ChunkTranscription {
                requested_start_seconds: 298.0,
                segments: vec![
                    ModelSegment {
                        start: 0.25,
                        end: 1.6,
                        text: String::new(),
                        words: vec![
                            ModelWord {
                                text: " very".into(),
                                start: 0.25,
                                end: 0.6,
                            },
                            ModelWord {
                                text: " very".into(),
                                start: 1.25,
                                end: 1.6,
                            },
                        ],
                    },
                    ModelSegment {
                        start: 10.0,
                        end: 10.4,
                        text: String::new(),
                        words: vec![ModelWord {
                            text: "echo".into(),
                            start: 10.0,
                            end: 10.4,
                        }],
                    },
                ],
            },
        ];

        let stitched = stitch(&chunks, 2.0).expect("stitches");
        let words: Vec<&str> = stitched
            .segments
            .iter()
            .flat_map(|segment| segment.words.iter().map(|word| word.text.as_str()))
            .collect();
        assert_eq!(
            words,
            vec!["New", "York", "New", "York", "echo", "very", "very", "echo"]
        );
        assert_eq!(stitched.deduplicated_word_count, 0);
    }

    #[test]
    fn seam_inversion_is_clamped_not_fatal() {
        // Real timings from job-4jODJ84DNjOpsQkcAn6ehw, seam 6/7 (boundary
        // 2087.0): chunk 6 kept a 20ms edge fragment "You" starting 2086.86;
        // chunk 7 dropped its "Laurie" but kept "on" starting 2086.82 — a
        // 40ms backward jump that used to fail the whole job.
        let chunks = vec![
            ChunkTranscription {
                requested_start_seconds: 1788.0,
                segments: vec![ModelSegment {
                    start: 296.0,
                    end: 298.88,
                    text: String::new(),
                    words: vec![
                        ModelWord {
                            text: " lori".into(),
                            start: 298.08,
                            end: 298.86,
                        },
                        ModelWord {
                            text: " You".into(),
                            start: 298.86,
                            end: 298.88,
                        },
                    ],
                }],
            },
            ChunkTranscription {
                requested_start_seconds: 2086.0,
                segments: vec![ModelSegment {
                    start: 0.0,
                    end: 2.88,
                    text: String::new(),
                    words: vec![
                        ModelWord {
                            text: " Laurie".into(),
                            start: 0.0,
                            end: 0.82,
                        },
                        ModelWord {
                            text: " on".into(),
                            start: 0.82,
                            end: 2.52,
                        },
                        ModelWord {
                            text: " season".into(),
                            start: 2.52,
                            end: 2.88,
                        },
                    ],
                }],
            },
        ];
        let stitched = stitch(&chunks, 2.0).expect("clamps the seam inversion");
        let words: Vec<&ModelWord> = stitched
            .segments
            .iter()
            .flat_map(|segment| segment.words.iter())
            .collect();
        let texts: Vec<&str> = words.iter().map(|word| word.text.as_str()).collect();
        assert_eq!(texts, vec!["lori", "You", "on", "season"]);
        assert_eq!(words[2].start, 1788.0 + 298.86);
        for pair in words.windows(2) {
            assert!(pair[1].start + 0.001 >= pair[0].start);
        }
        assert_eq!(stitched.segments[1].start, 1788.0 + 298.86);
    }

    #[test]
    fn backward_jump_beyond_overlap_still_fails() {
        let chunks = vec![ChunkTranscription {
            requested_start_seconds: 0.0,
            segments: vec![ModelSegment {
                start: 0.0,
                end: 11.0,
                text: String::new(),
                words: vec![
                    ModelWord {
                        text: "a".into(),
                        start: 10.0,
                        end: 10.5,
                    },
                    ModelWord {
                        text: "b".into(),
                        start: 5.0,
                        end: 5.4,
                    },
                ],
            }],
        }];
        let error = stitch(&chunks, 2.0).expect_err("gross inversion rejects");
        assert_eq!(
            error,
            StitchError::OutOfOrderWords {
                chunk_index: 0,
                prev_start: 10.0,
                next_start: 5.0,
            }
        );
    }

    #[test]
    fn reproduces_committed_golden_fixtures() {
        #[derive(Deserialize)]
        struct FixtureChunk {
            requested_start_seconds: f64,
            response: FixtureResponse,
        }
        #[derive(Deserialize)]
        struct FixtureResponse {
            segments: Vec<ModelSegment>,
        }
        #[derive(Deserialize)]
        struct FixtureExpectedSegment {
            start: f64,
            end: f64,
            text: String,
            words: Vec<ModelWord>,
        }
        #[derive(Deserialize)]
        struct FixtureExpected {
            segments: Vec<FixtureExpectedSegment>,
            stitched_word_count: usize,
            deduplicated_word_count: usize,
            normalized_transcript_sha256: String,
        }
        #[derive(Deserialize)]
        struct FixtureContract {
            overlap_seconds: f64,
        }
        #[derive(Deserialize)]
        struct Fixture {
            contract: FixtureContract,
            chunks: Vec<FixtureChunk>,
            expected: FixtureExpected,
        }

        let fixtures_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../Packages/OpenCastTranscription/Tests/OpenCastTranscriptionTests/Fixtures");
        for fixture_name in [
            "RemoteTranscriptionGoldenStitch.json",
            "RemoteTranscriptionSeamDuplicateStitch.json",
        ] {
            let raw = std::fs::read_to_string(fixtures_dir.join(fixture_name))
                .expect("read committed golden fixture");
            let fixture: Fixture = serde_json::from_str(&raw).expect("decode fixture");

            let chunks: Vec<ChunkTranscription> = fixture
                .chunks
                .iter()
                .map(|chunk| ChunkTranscription {
                    requested_start_seconds: chunk.requested_start_seconds,
                    segments: chunk.response.segments.clone(),
                })
                .collect();
            let stitched = stitch(&chunks, fixture.contract.overlap_seconds).expect("stitches");

            assert_eq!(
                stitched.word_count, fixture.expected.stitched_word_count,
                "{fixture_name} word count"
            );
            assert_eq!(
                stitched.deduplicated_word_count, fixture.expected.deduplicated_word_count,
                "{fixture_name} deduplicated word count"
            );
            assert_eq!(
                stitched.normalized_transcript_sha256,
                fixture.expected.normalized_transcript_sha256,
                "{fixture_name} normalized hash"
            );
            assert_eq!(
                stitched.segments.len(),
                fixture.expected.segments.len(),
                "{fixture_name} segment count"
            );
            for (produced, expected) in stitched.segments.iter().zip(&fixture.expected.segments) {
                assert_eq!(produced.text, expected.text, "{fixture_name} segment text");
                assert_eq!(
                    produced.start.to_bits(),
                    expected.start.to_bits(),
                    "{fixture_name} segment start"
                );
                assert_eq!(
                    produced.end.to_bits(),
                    expected.end.to_bits(),
                    "{fixture_name} segment end"
                );
                assert_eq!(
                    produced.words.len(),
                    expected.words.len(),
                    "{fixture_name} segment word count"
                );
                for (produced_word, expected_word) in produced.words.iter().zip(&expected.words) {
                    assert_eq!(
                        produced_word.text, expected_word.text,
                        "{fixture_name} word text"
                    );
                    assert_eq!(
                        produced_word.start.to_bits(),
                        expected_word.start.to_bits(),
                        "{fixture_name} word start"
                    );
                    assert_eq!(
                        produced_word.end.to_bits(),
                        expected_word.end.to_bits(),
                        "{fixture_name} word end"
                    );
                }
            }
        }
    }
}
