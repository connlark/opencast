//! End-to-end walker tests over synthetic MPEG streams.
//!
//! Real-media parity lives in the pinned-ffmpeg differential harness; these
//! cover the structural decisions that harness cannot express safely —
//! malformed tails, junk, truncation, free format, and the byte ceiling —
//! plus the invariant that results never depend on how the caller sliced its
//! reads.

use opencast_mp3_frame_core::tags::{scan_tail, TAIL_PROBE_BYTES};
use opencast_mp3_frame_core::{Mp3Error, Mp3Walker, VbrKind, WalkOptions, WalkResult};

const MPEG1_44100_MONO_128: u32 = 0xFFFB_90C0;
const FRAME_BYTES: usize = 417;
const TICKS_PER_FRAME: u64 = 1152 * 320;

/// One valid MPEG-1 Layer III frame: real header, deterministic filler.
fn frame(seed: u8) -> Vec<u8> {
    let mut bytes = MPEG1_44100_MONO_128.to_be_bytes().to_vec();
    bytes.extend((0..FRAME_BYTES - 4).map(|index| seed.wrapping_add(index as u8)));
    bytes
}

fn frames(count: usize) -> Vec<u8> {
    (0..count).flat_map(|index| frame(index as u8)).collect()
}

fn id3v2(payload_len: usize) -> Vec<u8> {
    let mut tag = vec![b'I', b'D', b'3', 3, 0, 0];
    let size = payload_len as u32;
    tag.extend_from_slice(&[
        ((size >> 21) & 0x7F) as u8,
        ((size >> 14) & 0x7F) as u8,
        ((size >> 7) & 0x7F) as u8,
        (size & 0x7F) as u8,
    ]);
    // Fill with bytes that include a false 0xFF sync run, so a walker that
    // skipped the tag by scanning rather than by length would mis-sync.
    tag.extend((0..payload_len).map(|index| if index % 7 == 0 { 0xFF } else { 0xE3 }));
    tag
}

/// A Xing frame: same header, "Xing" at the MPEG-1 mono offset, frame count.
fn xing_frame(frames_advertised: u32, byte_count: u32) -> Vec<u8> {
    let mut bytes = frame(0);
    let at = 4 + 17;
    bytes[at..at + 4].copy_from_slice(b"Xing");
    bytes[at + 4..at + 8].copy_from_slice(&0x03u32.to_be_bytes());
    bytes[at + 8..at + 12].copy_from_slice(&frames_advertised.to_be_bytes());
    bytes[at + 12..at + 16].copy_from_slice(&byte_count.to_be_bytes());
    bytes
}

fn walk_with(
    bytes: &[u8],
    range: usize,
    tune: impl Fn(&mut WalkOptions),
) -> Result<WalkResult, Mp3Error> {
    let object_len = bytes.len() as u64;
    let tail_start = object_len.saturating_sub(TAIL_PROBE_BYTES) as usize;
    let tags = scan_tail(object_len, &bytes[tail_start..]);
    let mut options = WalkOptions::new(object_len, tags.audio_end);
    tune(&mut options);
    let mut walker = Mp3Walker::new(options);
    for slice in bytes.chunks(range.max(1)) {
        walker.feed(slice)?;
    }
    walker.finish()
}

fn walk(bytes: &[u8]) -> Result<WalkResult, Mp3Error> {
    walk_with(bytes, 4096, |_| {})
}

#[test]
fn plain_stream_walks_every_frame() {
    let bytes = frames(200);
    let result = walk(&bytes).expect("walk");
    assert_eq!(result.audio_frames, 200);
    assert_eq!(result.first_audio_offset, 0);
    assert_eq!(result.sample_rate, 44_100);
    assert_eq!(result.channels, 1);
    assert!(result.vbr.is_none());
    assert_eq!(result.walked_ticks, 200 * TICKS_PER_FRAME);
    assert_eq!(result.chunks.len(), 1);
    assert_eq!(result.chunks[0].byte_count, bytes.len() as u64);
    assert!(!result.variable_bitrate);
}

#[test]
fn leading_id3v2_tags_are_skipped_by_length_not_by_scanning() {
    let mut bytes = id3v2(1000);
    bytes.extend(id3v2(37));
    let tag_bytes = bytes.len() as u64;
    bytes.extend(frames(50));

    let result = walk(&bytes).expect("walk");
    assert_eq!(result.leading_tag_bytes, tag_bytes);
    assert_eq!(result.first_audio_offset, tag_bytes);
    assert_eq!(result.audio_frames, 50);
}

#[test]
fn a_structural_xing_frame_is_excluded_from_the_audio_walk() {
    let mut bytes = xing_frame(50, 0);
    bytes.extend(frames(50));
    let result = walk(&bytes).expect("walk");
    assert_eq!(result.audio_frames, 50);
    assert_eq!(result.first_audio_offset, FRAME_BYTES as u64);
    assert_eq!(result.vbr.expect("xing").kind, VbrKind::Xing);
    // Canonical comes from the tag, which agrees with the walk here.
    assert_eq!(
        result.canonical_micros,
        result.walked_ticks * 1_000_000 / 14_112_000
    );
}

#[test]
fn an_over_claiming_frame_count_is_clamped_to_what_was_walked() {
    let mut bytes = xing_frame(5_000, 0);
    bytes.extend(frames(50));
    let result = walk(&bytes).expect("walk");
    assert_eq!(result.audio_frames, 50);
    // Clamped: the tag claims 5000 frames but only 50 exist, and a manifest
    // built against the tag's duration could never cover it.
    assert_eq!(result.canonical_micros, 1_306_122);
}

#[test]
fn trailing_id3v1_and_ape_tags_never_reach_a_chunk() {
    let mut bytes = frames(50);
    let audio_len = bytes.len() as u64;

    // APEv2 with header, then ID3v1.
    let ape_payload = 64usize;
    bytes.extend(std::iter::repeat_n(0u8, 32 + ape_payload));
    let mut footer = b"APETAGEX".to_vec();
    footer.extend_from_slice(&2000u32.to_le_bytes());
    footer.extend_from_slice(&((32 + ape_payload) as u32).to_le_bytes());
    footer.extend_from_slice(&1u32.to_le_bytes());
    footer.extend_from_slice(&(1u32 << 31).to_le_bytes());
    footer.extend_from_slice(&[0u8; 8]);
    bytes.extend(footer);
    let mut id3v1 = b"TAG".to_vec();
    id3v1.extend(std::iter::repeat_n(0u8, 125));
    bytes.extend(id3v1);

    let result = walk(&bytes).expect("walk");
    assert_eq!(result.audio_frames, 50);
    assert_eq!(result.audio_end, audio_len);
    assert_eq!(result.trailing_tag_bytes, bytes.len() as u64 - audio_len);
    assert_eq!(result.chunks[0].byte_count, audio_len);
    assert_eq!(result.truncated_tail_bytes, 0);
}

#[test]
fn a_truncated_final_frame_is_dropped_rather_than_emitted_partially() {
    let mut bytes = frames(50);
    bytes.extend_from_slice(&frame(9)[..FRAME_BYTES / 2]);
    let result = walk(&bytes).expect("walk");
    assert_eq!(result.audio_frames, 50);
    assert_eq!(result.truncated_tail_bytes, (FRAME_BYTES / 2) as u64);
    assert_eq!(result.chunks[0].byte_count, 50 * FRAME_BYTES as u64);
}

#[test]
fn mid_stream_junk_resyncs_within_bounds_and_is_excluded_from_output() {
    let mut bytes = frames(20);
    bytes.extend([0x11u8; 30]);
    bytes.extend(frames(20));

    let result = walk(&bytes).expect("walk");
    assert_eq!(result.audio_frames, 40);
    assert_eq!(result.resync_events, 1);
    assert_eq!(result.junk_bytes, 30);
    // Junk is not copied: the chunk is two spans that skip it entirely.
    assert_eq!(result.chunks[0].spans.len(), 2);
    assert_eq!(result.chunks[0].byte_count, 40 * FRAME_BYTES as u64);
    let spans = &result.chunks[0].spans;
    assert_eq!(spans[0].end, 20 * FRAME_BYTES as u64);
    assert_eq!(spans[1].start, 20 * FRAME_BYTES as u64 + 30);
}

#[test]
fn resync_caps_fail_closed() {
    let mut bytes = frames(20);
    bytes.extend(std::iter::repeat_n(0x11u8, 200_000));
    bytes.extend(frames(20));
    assert_eq!(walk(&bytes), Err(Mp3Error::ResyncLimitExceeded));

    // Many small junk runs exhaust the event budget instead.
    let mut many = frames(5);
    for _ in 0..12 {
        many.extend([0x11u8; 8]);
        many.extend(frames(5));
    }
    assert_eq!(
        walk_with(&many, 4096, |options| options.max_resync_events = 3),
        Err(Mp3Error::ResyncLimitExceeded)
    );
}

#[test]
fn free_format_streams_get_their_own_stable_reason() {
    // Bitrate index 0 everywhere: ffmpeg's own MP3 path cannot size these.
    let free = MPEG1_44100_MONO_128 & !(0xF << 12);
    let mut bytes = Vec::new();
    for _ in 0..20 {
        bytes.extend_from_slice(&free.to_be_bytes());
        bytes.extend([0u8; 413]);
    }
    assert_eq!(walk(&bytes), Err(Mp3Error::UnsupportedFreeFormat));
}

#[test]
fn a_sample_rate_change_stops_the_walk_instead_of_reclocking_it() {
    let mut bytes = frames(20);
    // Same everything, 48 kHz instead of 44.1 kHz.
    let other_rate = (MPEG1_44100_MONO_128 & !(3 << 10)) | (1 << 10);
    for _ in 0..20 {
        let mut next = frame(3);
        next[..4].copy_from_slice(&other_rate.to_be_bytes());
        bytes.extend(next);
    }
    assert_eq!(walk(&bytes), Err(Mp3Error::UnsupportedHeaderTransition));
}

#[test]
fn non_mpeg_objects_are_refused_after_the_bounded_search() {
    assert_eq!(walk(&vec![0u8; 200_000]), Err(Mp3Error::NoMpegAudio));
    assert_eq!(walk(b"not audio at all"), Err(Mp3Error::NoMpegAudio));
    assert_eq!(walk(&[]), Err(Mp3Error::NoMpegAudio));
    // A lone header-shaped four bytes must not confirm as a stream.
    assert_eq!(
        walk(&MPEG1_44100_MONO_128.to_be_bytes()),
        Err(Mp3Error::NoMpegAudio)
    );
}

#[test]
fn junk_beyond_the_search_window_is_refused() {
    let mut bytes = vec![0u8; 70_000];
    bytes.extend(frames(20));
    assert_eq!(walk(&bytes), Err(Mp3Error::NoMpegAudio));

    // Just inside the window still syncs.
    let mut inside = vec![0u8; 60_000];
    inside.extend(frames(20));
    assert_eq!(walk(&inside).expect("walk").audio_frames, 20);
}

#[test]
fn the_chunk_byte_ceiling_aborts_early_instead_of_reading_everything() {
    let bytes = frames(2_000);
    assert_eq!(
        walk_with(&bytes, 4096, |options| options.chunk_byte_ceiling = 100_000),
        Err(Mp3Error::ChunkOverEnvelope)
    );
    assert!(
        walk_with(&bytes, 4096, |options| options.chunk_byte_ceiling =
            u64::MAX)
        .is_ok()
    );
}

#[test]
fn results_are_identical_no_matter_how_the_caller_slices_its_reads() {
    let mut bytes = id3v2(500);
    bytes.extend(xing_frame(120, 0));
    bytes.extend(frames(120));
    bytes.extend([0x11u8; 17]);
    bytes.extend(frames(30));

    let baseline = walk_with(&bytes, bytes.len(), |_| {}).expect("walk");
    // The streamed per-chunk hash must equal a digest of the materialized
    // span bytes...
    for chunk in &baseline.chunks {
        let mut blob = Vec::new();
        for span in &chunk.spans {
            blob.extend_from_slice(&bytes[span.start as usize..span.end as usize]);
        }
        assert_eq!(
            chunk.sha256,
            opencast_mp3_frame_core::sha256::digest(&blob),
            "chunk {} streamed hash diverged from its span bytes",
            chunk.index
        );
    }
    // ...and, like every other walk field, be invariant to read slicing
    // (`WalkResult` equality includes each chunk's sha256).
    for range in [1usize, 3, 7, 64, 417, 418, 1024, 4096, 65_536] {
        let sliced = walk_with(&bytes, range, |_| {}).expect("walk");
        assert_eq!(sliced, baseline, "range {range} diverged");
    }
}

#[test]
fn peak_buffering_tracks_range_size_not_source_length() {
    let bytes = frames(20_000);
    let object_len = bytes.len() as u64;
    let mut walker = Mp3Walker::new(WalkOptions::new(object_len, object_len));
    let mut peak = 0usize;
    for slice in bytes.chunks(64 * 1024) {
        walker.feed(slice).expect("feed");
        peak = peak.max(walker.buffered_bytes());
    }
    walker.finish().expect("finish");
    // Only the lookahead window is ever retained, regardless of the 8 MB source.
    assert!(peak < 64 * 1024 + 2 * FRAME_BYTES, "peak {peak}");
}

#[test]
fn the_feed_contract_is_enforced() {
    let bytes = frames(10);
    let mut walker = Mp3Walker::new(WalkOptions::new(bytes.len() as u64, bytes.len() as u64));
    walker.feed(&bytes).expect("feed");
    assert_eq!(walker.feed(&[0u8; 1]), Err(Mp3Error::FeedContractViolated));

    // finish() before every byte arrived must not produce a partial result.
    let mut short = Mp3Walker::new(WalkOptions::new(bytes.len() as u64, bytes.len() as u64));
    short.feed(&bytes[..100]).expect("feed");
    assert_eq!(short.finish(), Err(Mp3Error::FeedContractViolated));
}

/// Deterministic mutation sweep: no input may panic, hang, or allocate
/// unboundedly, whatever the walker decides about it.
#[test]
fn mutated_streams_never_panic_or_retain_unbounded_state() {
    let mut base = id3v2(64);
    base.extend(xing_frame(40, 0));
    base.extend(frames(40));

    let mut state = 0x1234_5678u32;
    let mut next = || {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        state
    };

    for iteration in 0..3_000 {
        let mut mutant = base.clone();
        for _ in 0..(1 + iteration % 8) {
            let position = (next() as usize) % mutant.len();
            match next() % 4 {
                0 => mutant[position] = (next() & 0xFF) as u8,
                1 => mutant[position] = 0xFF,
                2 => mutant.truncate(position.max(1)),
                _ => mutant.insert(position, (next() & 0xFF) as u8),
            }
        }
        let object_len = mutant.len() as u64;
        let tail_start = object_len.saturating_sub(TAIL_PROBE_BYTES) as usize;
        let tags = scan_tail(object_len, &mutant[tail_start..]);
        let mut walker = Mp3Walker::new(WalkOptions::new(object_len, tags.audio_end));
        let mut peak = 0usize;
        let mut fed = true;
        for slice in mutant.chunks(1024) {
            if walker.feed(slice).is_err() {
                fed = false;
                break;
            }
            peak = peak.max(walker.buffered_bytes());
        }
        assert!(
            peak <= 1024 + 4 * FRAME_BYTES,
            "iteration {iteration} peak {peak}"
        );
        if fed {
            if let Ok(result) = walker.finish() {
                // Whatever survived must still be a self-consistent plan.
                for chunk in &result.chunks {
                    let total: u64 = chunk.spans.iter().map(|span| span.len()).sum();
                    assert_eq!(total, chunk.byte_count);
                    for span in &chunk.spans {
                        assert!(span.end <= result.audio_end);
                    }
                }
            }
        }
    }
}
