//! Containerless MP3 frame walker for OpenCast remote transcription.
//!
//! This crate replaces the pinned ffmpeg container's `probe` and `chunk`
//! operations for ordinary MPEG-1/2/2.5 Layer III podcast media. It is a pure,
//! allocation-bounded, dependency-free library: `RemoteTranscriptionWorker`
//! owns R2 range reads, hashing, persistence and cancellation, and this crate
//! owns nothing but arithmetic over the bytes it is handed.
//!
//! # Supported contract
//!
//! 1. ordinary MPEG-1/2/2.5 Layer III elementary streams, CBR or VBR;
//! 2. deterministic, tag-free runs of *complete* frames — never junk, never a
//!    partial frame;
//! 3. strict, bounded resynchronization; anything outside the contract is a
//!    stable [`Mp3Error`] the caller turns into a container fallback;
//! 4. exact integer sample-clock boundary selection, reproducing the pinned
//!    ffmpeg `-ss`/`-t` stream-copy spans frame for frame.
//!
//! It is explicitly *not* an ffmpeg emulator. ffmpeg's MP3 parser is
//! permissive and can mux junk bytes through a stream copy as part of an
//! invalid packet; reproducing that would violate the frame-valid output
//! requirement, so those inputs are rejected and fall back to the container.

#![forbid(unsafe_code)]

pub mod header;
pub mod plan;
pub mod sha256;
pub mod tags;
pub mod vbr;
pub mod walk;

pub use header::{FrameHeader, HeaderReject};
pub use plan::{ChunkPlan, Span};
pub use tags::TailTags;
pub use vbr::{VbrKind, VbrTag};
pub use walk::{Mp3Walker, WalkOptions, WalkResult};

/// ffmpeg's MP3 stream time base: the least common multiple of every MPEG
/// audio sample rate, so a frame duration is always an exact integer.
pub const TICKS_PER_SECOND: u64 = 14_112_000;

/// Bakeoff chunk contract (immutable): 300 s requested windows advancing in
/// 298 s steps, i.e. 2 s of overlap at every seam.
pub const CHUNK_SECONDS: u64 = 300;
pub const STEP_SECONDS: u64 = 298;

/// Four-hour source cap / 298 s step, with headroom.
pub const MAX_CHUNKS: u32 = 64;

/// Stable, content-free failure kinds. Every one of these means "hand this
/// object back to the ffmpeg container", never "fail the customer's job".
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mp3Error {
    /// No confirmed pair of MPEG audio frames inside ffmpeg's 64 KiB window.
    NoMpegAudio,
    /// Bitrate index 0 appeared where a frame was required.
    UnsupportedFreeFormat,
    /// Version / layer / sample-rate transition inside one object.
    UnsupportedHeaderTransition,
    /// Resync events or skipped bytes exceeded the configured caps.
    ResyncLimitExceeded,
    /// Object ended inside a frame that the walker had already committed to.
    TruncatedStream,
    /// More chunk windows than [`MAX_CHUNKS`], or more copy spans than the
    /// persisted plan is allowed to hold.
    PlanTooLarge,
    /// A chunk window grew past the caller's byte ceiling. Raised as soon as
    /// the window crosses it, so a source that needs re-encoding is handed
    /// back after a few megabytes instead of a full read.
    ChunkOverEnvelope,
    /// The caller fed bytes out of order or beyond the declared object length.
    FeedContractViolated,
    /// Integer arithmetic would have overflowed on hostile field values.
    Overflow,
}

impl Mp3Error {
    /// Short, content-free reason code for telemetry. Never derived from
    /// media bytes, titles or URLs.
    pub fn reason(&self) -> &'static str {
        match self {
            Self::NoMpegAudio => "no_mpeg_audio",
            Self::UnsupportedFreeFormat => "unsupported_free_format",
            Self::UnsupportedHeaderTransition => "unsupported_header_transition",
            Self::ResyncLimitExceeded => "resync_limit_exceeded",
            Self::TruncatedStream => "truncated_stream",
            Self::PlanTooLarge => "plan_too_large",
            Self::ChunkOverEnvelope => "chunk_over_envelope",
            Self::FeedContractViolated => "feed_contract_violated",
            Self::Overflow => "overflow",
        }
    }
}

impl core::fmt::Display for Mp3Error {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.write_str(self.reason())
    }
}

impl std::error::Error for Mp3Error {}

/// Ticks per sample for a supported MPEG audio sample rate. Every valid rate
/// divides [`TICKS_PER_SECOND`] exactly, which is the whole point of that
/// time base.
pub fn ticks_per_sample(sample_rate: u32) -> Option<u64> {
    let rate = u64::from(sample_rate);
    if rate == 0 || TICKS_PER_SECOND % rate != 0 {
        return None;
    }
    Some(TICKS_PER_SECOND / rate)
}

/// Per-frame duration in whole microseconds, matching what `ffprobe` prints
/// for `packet=duration_time` at `%f` precision.
///
/// The container's `measured_audio_duration()` sums those printed strings, so
/// a chunk's manifest duration is a sum of six-decimal values — not the exact
/// rational. Reproducing the quantization is a compatibility requirement:
/// summing exact rationals for dp225 chunk 0 gives 300.016 s where the pinned
/// regression value is 300.011 s.
pub fn frame_micros(samples_per_frame: u32, sample_rate: u32) -> Option<u64> {
    if sample_rate == 0 {
        return None;
    }
    Some(div_round_half_even(
        u64::from(samples_per_frame) * 1_000_000,
        u64::from(sample_rate),
    ))
}

/// Microsecond duration for a tick count, matching `av_rescale_q`'s default
/// `AV_ROUND_NEAR_INF` (nearest, ties away from zero) as used to build
/// `AVFormatContext::duration`, which is what `ffprobe` prints as
/// `format.duration`.
pub fn ticks_to_micros(ticks: u64) -> Option<u64> {
    let scaled = ticks.checked_mul(1_000_000)?;
    Some(div_round_half_away(scaled, TICKS_PER_SECOND))
}

/// Quantizes microseconds to the manifest's three-decimal seconds, matching
/// the container's `Decimal(str(value)).quantize(Decimal("0.001"))`
/// (`ROUND_HALF_EVEN`).
pub fn micros_to_seconds_q3(micros: u64) -> f64 {
    quantize_micros_to_millis(micros) as f64 / 1000.0
}

/// Whole milliseconds under the manifest's rounding. Anything that has to
/// agree with the *reported* canonical duration must quantize first: the
/// gateway validates chunk coverage against the three-decimal value it was
/// given, not against the exact walk.
pub fn quantize_micros_to_millis(micros: u64) -> u64 {
    div_round_half_even(micros, 1000)
}

fn div_round_half_even(numerator: u64, denominator: u64) -> u64 {
    let quotient = numerator / denominator;
    let remainder = numerator % denominator;
    let doubled = remainder * 2;
    if doubled > denominator || (doubled == denominator && quotient % 2 == 1) {
        quotient + 1
    } else {
        quotient
    }
}

fn div_round_half_away(numerator: u64, denominator: u64) -> u64 {
    let quotient = numerator / denominator;
    let remainder = numerator % denominator;
    if remainder * 2 >= denominator {
        quotient + 1
    } else {
        quotient
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_supported_sample_rate_divides_the_time_base() {
        for rate in [
            8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000,
        ] {
            let ticks = ticks_per_sample(rate).expect("supported rate");
            assert_eq!(ticks * u64::from(rate), TICKS_PER_SECOND);
        }
        assert_eq!(ticks_per_sample(44_100), Some(320));
        assert_eq!(ticks_per_sample(0), None);
        assert_eq!(ticks_per_sample(44_101), None);
    }

    #[test]
    fn frame_micros_reproduces_ffprobe_six_decimal_rounding() {
        // The pinned dp225 / DA009 value: 1152 / 44100 prints as 0.026122.
        assert_eq!(frame_micros(1152, 44_100), Some(26_122));
        assert_eq!(frame_micros(1152, 48_000), Some(24_000));
        assert_eq!(frame_micros(1152, 32_000), Some(36_000));
        assert_eq!(frame_micros(576, 22_050), Some(26_122));
        assert_eq!(frame_micros(576, 8_000), Some(72_000));
    }

    #[test]
    fn pinned_regression_packet_sums_survive_the_quantizer() {
        assert_eq!(micros_to_seconds_q3(11_485 * 26_122), 300.011);
        assert_eq!(micros_to_seconds_q3(11_486 * 26_122), 300.037);
        assert_eq!(micros_to_seconds_q3(11_100 * 26_122), 289.954);
        assert_eq!(micros_to_seconds_q3(7_657 * 26_122), 200.016);
        assert_eq!(micros_to_seconds_q3(121_736 * 26_122), 3_179.988);
    }

    #[test]
    fn canonical_durations_match_the_pinned_ffprobe_output() {
        // dp225: 33915 Xing frames * 1152 samples at 44.1 kHz, no padding.
        let dp225 = 33_915u64 * 1152 * 320;
        assert_eq!(ticks_to_micros(dp225), Some(885_942_857));
        assert_eq!(micros_to_seconds_q3(885_942_857), 885.943);

        // DA009: 121736 Info frames minus 576 + 1296 samples of LAME padding.
        let da009 = (121_736u64 * 1152 - 576 - 1296) * 320;
        assert_eq!(ticks_to_micros(da009), Some(3_180_000_000));
        assert_eq!(micros_to_seconds_q3(3_180_000_000), 3180.0);
    }

    #[test]
    fn rounding_helpers_break_ties_the_way_their_references_do() {
        assert_eq!(div_round_half_even(1500, 1000), 2);
        assert_eq!(div_round_half_even(2500, 1000), 2);
        assert_eq!(div_round_half_even(2501, 1000), 3);
        assert_eq!(div_round_half_even(2499, 1000), 2);
        assert_eq!(div_round_half_away(1500, 1000), 2);
        assert_eq!(div_round_half_away(2500, 1000), 3);
    }

    #[test]
    fn tick_conversion_refuses_to_overflow() {
        assert_eq!(ticks_to_micros(u64::MAX), None);
        // Four hours of ticks is comfortably inside the safe range.
        assert!(ticks_to_micros(4 * 3600 * TICKS_PER_SECOND).is_some());
    }

    #[test]
    fn error_reasons_are_stable_and_content_free() {
        for error in [
            Mp3Error::NoMpegAudio,
            Mp3Error::UnsupportedFreeFormat,
            Mp3Error::UnsupportedHeaderTransition,
            Mp3Error::ResyncLimitExceeded,
            Mp3Error::TruncatedStream,
            Mp3Error::PlanTooLarge,
            Mp3Error::ChunkOverEnvelope,
            Mp3Error::FeedContractViolated,
            Mp3Error::Overflow,
        ] {
            assert!(!error.reason().is_empty());
            assert_eq!(error.to_string(), error.reason());
        }
    }
}
