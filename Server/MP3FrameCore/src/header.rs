//! MPEG-1/2/2.5 Layer III frame header arithmetic.
//!
//! Mirrors `libavcodec/mpegaudiodecheader.{c,h}` from the pinned ffmpeg 9
//! source for the subset the MP3 stream-copy path actually depends on:
//! `ff_mpa_check_header` plus the Layer III branch of
//! `avpriv_mpegaudio_decode_header`. Layers I and II are rejected here — the
//! gateway contract already requires `codec == "mp3"`, and ffmpeg's own MP3
//! demuxer abandons VBR parsing on `c.layer != 3`.

/// ffmpeg's `MP3_MASK`: the header bits that must stay equal across the two
/// frames of an initial/resync confirmation pair. Fixes sync, MPEG version,
/// layer, sample rate, channel mode, copyright, original and emphasis, while
/// deliberately allowing CRC protection, bitrate, padding, private and
/// mode-extension to vary (VBR is normal).
pub const MP3_MASK: u32 = 0xFFFE_0CCF;

/// Bits that may never change inside one supported elementary stream: sync,
/// version, layer, sample rate. A change here moves the sample clock, which
/// would invalidate every downstream timestamp, so it is a hard stop rather
/// than a resync.
pub const CLOCK_MASK: u32 = 0xFFE0_0000 | (3 << 19) | (3 << 17) | (3 << 10);

/// Largest possible Layer III frame: MPEG-1, 320 kbps, 32 kHz, padded.
pub const MAX_FRAME_BYTES: u32 = 1441;

const FREQ_TAB: [u32; 3] = [44_100, 48_000, 32_000];

/// `ff_mpa_bitrate_tab[lsf][layer 3]`, in kbps. Index 0 is free format and
/// index 15 is reserved; both are rejected before lookup.
const BITRATE_TAB: [[u32; 16]; 2] = [
    [
        0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0,
    ],
    [
        0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0,
    ],
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HeaderReject {
    NoSync,
    ReservedVersion,
    NotLayerIii,
    ReservedBitrate,
    /// Bitrate index 0. ffmpeg's low-level header check admits it, but the
    /// MP3 demux/parser path cannot derive a frame size for it and rejects
    /// the stream, so version 1 refuses it explicitly rather than guessing.
    FreeFormat,
    ReservedSampleRate,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FrameHeader {
    pub raw: u32,
    /// Low sampling frequency: MPEG-2 or MPEG-2.5.
    pub lsf: bool,
    pub mpeg25: bool,
    pub sample_rate: u32,
    pub bitrate_kbps: u32,
    pub padding: bool,
    pub channels: u8,
    pub crc_protected: bool,
    pub frame_bytes: u32,
    pub samples_per_frame: u32,
}

impl FrameHeader {
    pub fn parse(raw: u32) -> Result<Self, HeaderReject> {
        if raw & 0xFFE0_0000 != 0xFFE0_0000 {
            return Err(HeaderReject::NoSync);
        }
        let version = (raw >> 19) & 3;
        if version == 1 {
            return Err(HeaderReject::ReservedVersion);
        }
        // ffmpeg: layer = 4 - ((header >> 17) & 3); Layer III is field 0b01.
        if (raw >> 17) & 3 != 1 {
            return Err(HeaderReject::NotLayerIii);
        }
        let bitrate_index = ((raw >> 12) & 0xF) as usize;
        if bitrate_index == 0xF {
            return Err(HeaderReject::ReservedBitrate);
        }
        if bitrate_index == 0 {
            return Err(HeaderReject::FreeFormat);
        }
        let rate_index = ((raw >> 10) & 3) as usize;
        if rate_index == 3 {
            return Err(HeaderReject::ReservedSampleRate);
        }

        let (lsf, mpeg25) = match version {
            3 => (false, false), // MPEG-1
            2 => (true, false),  // MPEG-2
            _ => (true, true),   // MPEG-2.5 (field 0b00)
        };
        let shift = u32::from(lsf) + u32::from(mpeg25);
        let sample_rate = FREQ_TAB[rate_index] >> shift;
        let bitrate_kbps = BITRATE_TAB[usize::from(lsf)][bitrate_index];
        let padding = (raw >> 9) & 1 == 1;
        let channels = if (raw >> 6) & 3 == 3 { 1 } else { 2 };

        // ffmpeg Layer III: (bitrate * 144000) / (sample_rate << lsf) + padding.
        let frame_bytes =
            (bitrate_kbps * 144_000) / (sample_rate << u32::from(lsf)) + u32::from(padding);

        Ok(Self {
            raw,
            lsf,
            mpeg25,
            sample_rate,
            bitrate_kbps,
            padding,
            channels,
            crc_protected: (raw >> 16) & 1 == 0,
            frame_bytes,
            samples_per_frame: if lsf { 576 } else { 1152 },
        })
    }

    /// True when both headers describe the same stream closely enough for
    /// ffmpeg's two-frame confirmation to accept them.
    pub fn compatible_with(&self, other: &Self) -> bool {
        self.raw & MP3_MASK == other.raw & MP3_MASK
    }

    /// True when the sample clock is unchanged. Weaker than
    /// [`Self::compatible_with`]: a channel-mode or emphasis change alters
    /// neither `frame_bytes` arithmetic nor `samples_per_frame`, so it stays
    /// walkable, while a version/rate change does not.
    pub fn same_clock(&self, other: &Self) -> bool {
        self.raw & CLOCK_MASK == other.raw & CLOCK_MASK
    }
}

/// Reads a big-endian 32-bit header at `offset` in `buf`.
pub fn header_at(buf: &[u8], offset: usize) -> Option<u32> {
    let bytes = buf.get(offset..offset.checked_add(4)?)?;
    Some(u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Builds a syntactically valid Layer III header.
    pub(crate) fn build(version: u32, bitrate_index: u32, rate_index: u32, padding: u32) -> u32 {
        0xFFE0_0000
            | (version << 19)
            | (1 << 17)
            | (1 << 16)
            | (bitrate_index << 12)
            | (rate_index << 10)
            | (padding << 9)
    }

    #[test]
    fn mpeg1_layer3_frame_sizes() {
        // 44.1 kHz / 128 kbps, unpadded then padded.
        let header = FrameHeader::parse(build(3, 9, 0, 0)).expect("valid");
        assert_eq!(header.sample_rate, 44_100);
        assert_eq!(header.bitrate_kbps, 128);
        assert_eq!(header.samples_per_frame, 1152);
        assert_eq!(header.frame_bytes, 417);
        assert_eq!(
            FrameHeader::parse(build(3, 9, 0, 1)).unwrap().frame_bytes,
            418
        );

        // Largest legal frame: 320 kbps at 32 kHz, padded.
        let biggest = FrameHeader::parse(build(3, 14, 2, 1)).expect("valid");
        assert_eq!(biggest.frame_bytes, MAX_FRAME_BYTES);
    }

    #[test]
    fn mpeg2_and_mpeg25_halve_and_quarter_the_clock() {
        let mpeg2 = FrameHeader::parse(build(2, 8, 0, 0)).expect("valid");
        assert_eq!(mpeg2.sample_rate, 22_050);
        assert_eq!(mpeg2.samples_per_frame, 576);
        assert_eq!(mpeg2.bitrate_kbps, 64);
        assert_eq!(mpeg2.frame_bytes, (64 * 144_000) / (22_050 * 2));

        let mpeg25 = FrameHeader::parse(build(0, 8, 0, 0)).expect("valid");
        assert_eq!(mpeg25.sample_rate, 11_025);
        assert_eq!(mpeg25.samples_per_frame, 576);
    }

    #[test]
    fn reserved_and_free_format_combinations_are_rejected() {
        assert_eq!(FrameHeader::parse(0), Err(HeaderReject::NoSync));
        assert_eq!(
            FrameHeader::parse(build(1, 9, 0, 0)),
            Err(HeaderReject::ReservedVersion)
        );
        // Layer II (field 0b10) and Layer I (0b11) and reserved (0b00).
        for layer_field in [0u32, 2, 3] {
            let raw = (build(3, 9, 0, 0) & !(3 << 17)) | (layer_field << 17);
            assert_eq!(FrameHeader::parse(raw), Err(HeaderReject::NotLayerIii));
        }
        assert_eq!(
            FrameHeader::parse(build(3, 15, 0, 0)),
            Err(HeaderReject::ReservedBitrate)
        );
        assert_eq!(
            FrameHeader::parse(build(3, 0, 0, 0)),
            Err(HeaderReject::FreeFormat)
        );
        assert_eq!(
            FrameHeader::parse(build(3, 9, 3, 0)),
            Err(HeaderReject::ReservedSampleRate)
        );
    }

    #[test]
    fn exhaustive_valid_matrix_never_panics_and_stays_bounded() {
        let mut seen = 0u32;
        for version in [0u32, 2, 3] {
            for bitrate_index in 1..15u32 {
                for rate_index in 0..3u32 {
                    for padding in 0..2u32 {
                        for mode in 0..4u32 {
                            for protection in 0..2u32 {
                                let raw = build(version, bitrate_index, rate_index, padding)
                                    & !(1 << 16)
                                    | (protection << 16)
                                    | (mode << 6);
                                let header = FrameHeader::parse(raw).expect("valid matrix entry");
                                assert!(header.frame_bytes >= 24);
                                assert!(header.frame_bytes <= MAX_FRAME_BYTES);
                                assert_eq!(header.channels, if mode == 3 { 1 } else { 2 });
                                assert_eq!(header.crc_protected, protection == 0);
                                seen += 1;
                            }
                        }
                    }
                }
            }
        }
        assert_eq!(seen, 3 * 14 * 3 * 2 * 4 * 2);
    }

    #[test]
    fn masks_separate_clock_changes_from_vbr_changes() {
        let base = FrameHeader::parse(build(3, 9, 0, 0)).unwrap();
        let other_bitrate = FrameHeader::parse(build(3, 12, 0, 0)).unwrap();
        let padded = FrameHeader::parse(build(3, 9, 0, 1)).unwrap();
        let other_rate = FrameHeader::parse(build(3, 9, 1, 0)).unwrap();
        let mono = FrameHeader::parse(build(3, 9, 0, 0) | (3 << 6)).unwrap();

        assert!(base.same_clock(&other_bitrate));
        assert!(base.same_clock(&padded));
        assert!(base.same_clock(&mono));
        assert!(!base.same_clock(&other_rate));

        assert!(base.compatible_with(&other_bitrate));
        assert!(base.compatible_with(&padded));
        assert!(!base.compatible_with(&mono));
        assert!(!base.compatible_with(&other_rate));
    }
}

#[cfg(test)]
pub(crate) use tests::build as build_test_header;
