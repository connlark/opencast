//! Xing / Info / VBRI structural-frame parsing.
//!
//! Mirrors `mp3_parse_vbr_tags`, `mp3_parse_info_tag` and
//! `mp3_parse_vbri_tag` in the pinned `libavformat/mp3dec.c`, including the
//! version/channel-dependent Xing offset table, the concatenated-file trust
//! guard, and the LAME/Lavf/Lavc encoder delay/padding extension that moves
//! the demuxer's stream start time.
//!
//! Every field read is bounds-checked against the supplied window. ffmpeg
//! reads these through `avio` and will happily run past the structural frame
//! into following audio; the window this crate is given always covers that
//! reach for real media, and a truncated window degrades to "no VBR tag"
//! rather than to a panic.

use crate::header::FrameHeader;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VbrKind {
    Xing,
    Info,
    Vbri,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VbrTag {
    pub kind: VbrKind,
    /// Frame count advertised by the tag, excluding the structural frame
    /// itself. Zero means "absent or distrusted".
    pub frames: u32,
    /// Stream byte count advertised by the tag. Zero means absent.
    pub header_filesize: u32,
    pub start_pad: u32,
    pub end_pad: u32,
    pub encoder_recognized: bool,
    /// True when ffmpeg's concatenated-file guard discarded `frames`.
    pub frame_count_distrusted: bool,
}

impl VbrTag {
    /// ffmpeg skips the structural frame only when the tag yielded at least
    /// one usable field (`!frames && !header_filesize` → `return -1`).
    pub fn is_structural(&self) -> bool {
        self.frames != 0 || self.header_filesize != 0
    }

    /// `sti->start_skip_samples` — the demuxer's stream start offset, which
    /// input-side `-ss` targets are measured against.
    pub fn start_skip_samples(&self) -> u32 {
        if self.encoder_recognized {
            self.start_pad + 528 + 1
        } else {
            0
        }
    }
}

struct Window<'a> {
    bytes: &'a [u8],
    cursor: usize,
    overrun: bool,
}

impl<'a> Window<'a> {
    fn new(bytes: &'a [u8], cursor: usize) -> Self {
        Self {
            bytes,
            cursor,
            overrun: false,
        }
    }

    fn take(&mut self, len: usize) -> Option<&'a [u8]> {
        let end = self.cursor.checked_add(len)?;
        let slice = self.bytes.get(self.cursor..end);
        match slice {
            Some(slice) => {
                self.cursor = end;
                Some(slice)
            }
            None => {
                self.overrun = true;
                None
            }
        }
    }

    fn skip(&mut self, len: usize) {
        self.cursor = self.cursor.saturating_add(len);
    }

    fn be32(&mut self) -> Option<u32> {
        let bytes = self.take(4)?;
        Some(u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
    }

    fn be24(&mut self) -> Option<u32> {
        let bytes = self.take(3)?;
        Some(u32::from_be_bytes([0, bytes[0], bytes[1], bytes[2]]))
    }

    fn be16(&mut self) -> Option<u16> {
        let bytes = self.take(2)?;
        Some(u16::from_be_bytes([bytes[0], bytes[1]]))
    }
}

/// Parses the structural first frame.
///
/// `window` starts at the frame's first byte. `bytes_after_header` is the
/// number of object bytes following that frame's 4-byte header, which is what
/// ffmpeg compares against the tag's advertised stream size.
pub fn parse_first_frame(
    header: &FrameHeader,
    window: &[u8],
    bytes_after_header: u64,
) -> Option<VbrTag> {
    let mut tag = parse_xing(header, window, bytes_after_header);
    // ffmpeg runs the VBRI probe unconditionally after the Xing probe and lets
    // it overwrite `frames` / `header_filesize`.
    if let Some(vbri) = parse_vbri(window) {
        match tag.as_mut() {
            Some(existing) => {
                existing.frames = vbri.frames;
                existing.header_filesize = vbri.header_filesize;
                existing.frame_count_distrusted = false;
            }
            None => tag = Some(vbri),
        }
    }
    tag
}

fn parse_xing(header: &FrameHeader, window: &[u8], bytes_after_header: u64) -> Option<VbrTag> {
    // xing_offtbl[lsf][mono] from mp3dec.c.
    let offset = match (header.lsf, header.channels == 1) {
        (false, false) => 32,
        (false, true) => 17,
        (true, false) => 17,
        (true, true) => 9,
    };
    let mut reader = Window::new(window, 4 + offset);
    let magic = reader.be32()?;
    let kind = match magic {
        0x496E_666F => VbrKind::Info, // "Info"
        0x5869_6E67 => VbrKind::Xing, // "Xing"
        _ => return None,
    };

    let flags = reader.be32()?;
    let mut tag = VbrTag {
        kind,
        frames: 0,
        header_filesize: 0,
        start_pad: 0,
        end_pad: 0,
        encoder_recognized: false,
        frame_count_distrusted: false,
    };
    if flags & 0x01 != 0 {
        tag.frames = reader.be32()?;
    }
    if flags & 0x02 != 0 {
        tag.header_filesize = reader.be32()?;
    }
    // Concatenated-file guard: a stream whose real size runs well past what
    // the tag advertises is a concatenation, and its frame count would
    // under-report duration.
    if bytes_after_header != 0 && tag.header_filesize != 0 {
        let advertised = u64::from(tag.header_filesize);
        let min = bytes_after_header.min(advertised);
        let delta = bytes_after_header.max(advertised) - min;
        if bytes_after_header > advertised && delta > min >> 4 {
            tag.frames = 0;
            tag.frame_count_distrusted = true;
        }
    }
    if flags & 0x04 != 0 {
        reader.skip(100); // TOC
    }
    if flags & 0x08 != 0 {
        reader.skip(4); // VBR quality scale
    }

    let version = reader.take(9)?;
    // Info Tag revision + VBR method, lowpass, ReplayGain peak, radio gain,
    // audiophile gain, encoding flags + ATH type, ABR/minimal bitrate.
    reader.skip(1 + 1 + 4 + 2 + 2 + 1 + 1);
    let delays = reader.be24()?;
    if matches!(&version[0..4], b"LAME" | b"Lavf" | b"Lavc") {
        tag.encoder_recognized = true;
        tag.start_pad = delays >> 12;
        tag.end_pad = delays & 0xFFF;
    }
    Some(tag)
}

fn parse_vbri(window: &[u8]) -> Option<VbrTag> {
    let mut reader = Window::new(window, 4 + 32);
    if reader.be32()? != 0x5642_5249 {
        // "VBRI"
        return None;
    }
    if reader.be16()? != 1 {
        return None;
    }
    reader.skip(4); // delay + quality
    let header_filesize = reader.be32()?;
    let frames = reader.be32()?;
    Some(VbrTag {
        kind: VbrKind::Vbri,
        frames,
        header_filesize,
        start_pad: 0,
        end_pad: 0,
        encoder_recognized: false,
        frame_count_distrusted: false,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::header::build_test_header;

    fn frame(mono: bool, lsf: bool) -> (FrameHeader, Vec<u8>) {
        let version = if lsf { 2 } else { 3 };
        let raw = build_test_header(version, 9, 0, 0) | if mono { 3 << 6 } else { 0 };
        let header = FrameHeader::parse(raw).expect("valid");
        let mut buf = raw.to_be_bytes().to_vec();
        buf.resize(1024, 0);
        (header, buf)
    }

    fn write_xing(
        buf: &mut [u8],
        offset: usize,
        magic: &[u8; 4],
        flags: u32,
        frames: Option<u32>,
        size: Option<u32>,
        toc: bool,
        encoder: Option<(&[u8; 4], u32, u32)>,
    ) {
        let mut at = 4 + offset;
        buf[at..at + 4].copy_from_slice(magic);
        at += 4;
        buf[at..at + 4].copy_from_slice(&flags.to_be_bytes());
        at += 4;
        if let Some(frames) = frames {
            buf[at..at + 4].copy_from_slice(&frames.to_be_bytes());
            at += 4;
        }
        if let Some(size) = size {
            buf[at..at + 4].copy_from_slice(&size.to_be_bytes());
            at += 4;
        }
        if toc {
            at += 100;
        }
        if let Some((name, start_pad, end_pad)) = encoder {
            buf[at..at + 4].copy_from_slice(name);
            at += 9;
            at += 1 + 1 + 4 + 2 + 2 + 1 + 1;
            let delays = (start_pad << 12) | end_pad;
            buf[at..at + 3].copy_from_slice(&delays.to_be_bytes()[1..4]);
        }
    }

    #[test]
    fn xing_offsets_follow_version_and_channel_count() {
        for (mono, lsf, offset) in [
            (false, false, 32usize),
            (true, false, 17),
            (false, true, 17),
            (true, true, 9),
        ] {
            let (header, mut buf) = frame(mono, lsf);
            write_xing(
                &mut buf,
                offset,
                b"Xing",
                0x07,
                Some(33_915),
                Some(9_825_356),
                true,
                None,
            );
            let tag = parse_first_frame(&header, &buf, 9_630_915).expect("xing");
            assert_eq!(tag.kind, VbrKind::Xing);
            assert_eq!(tag.frames, 33_915);
            assert_eq!(tag.header_filesize, 9_825_356);
            assert!(!tag.encoder_recognized);
            assert!(tag.is_structural());

            // The same bytes at the wrong offset must not be recognized.
            let (header, mut wrong) = frame(!mono, lsf);
            write_xing(
                &mut wrong,
                offset,
                b"Xing",
                0x07,
                Some(1),
                Some(1),
                true,
                None,
            );
            if offset != if lsf { 17 } else { 32 } || mono == lsf {
                assert!(parse_first_frame(&header, &wrong, 1).is_none());
            }
        }
    }

    #[test]
    fn lame_extension_supplies_encoder_delay_and_padding() {
        let (header, mut buf) = frame(true, false);
        write_xing(
            &mut buf,
            17,
            b"Info",
            0x03,
            Some(121_736),
            Some(25_440_547),
            false,
            Some((b"Lavc", 576, 1296)),
        );
        let tag = parse_first_frame(&header, &buf, 25_440_543).expect("info");
        assert_eq!(tag.kind, VbrKind::Info);
        assert_eq!(tag.frames, 121_736);
        assert!(tag.encoder_recognized);
        assert_eq!(tag.start_pad, 576);
        assert_eq!(tag.end_pad, 1296);
        assert_eq!(tag.start_skip_samples(), 1105);
    }

    #[test]
    fn unrecognized_encoder_leaves_the_stream_start_at_zero() {
        let (header, mut buf) = frame(true, false);
        write_xing(
            &mut buf,
            17,
            b"Xing",
            0x07,
            Some(10),
            Some(1000),
            true,
            Some((b"NERO", 100, 200)),
        );
        let tag = parse_first_frame(&header, &buf, 990).expect("xing");
        assert!(!tag.encoder_recognized);
        assert_eq!(tag.start_pad, 0);
        assert_eq!(tag.start_skip_samples(), 0);
    }

    #[test]
    fn concatenation_guard_discards_an_untrustworthy_frame_count() {
        let (header, mut buf) = frame(true, false);
        write_xing(
            &mut buf,
            17,
            b"Xing",
            0x03,
            Some(100),
            Some(1_000_000),
            false,
            None,
        );
        // Real stream is more than 1/16 larger than advertised.
        let tag = parse_first_frame(&header, &buf, 4_000_000).expect("xing");
        assert_eq!(tag.frames, 0);
        assert!(tag.frame_count_distrusted);
        // Still structural: header_filesize survives, so ffmpeg skips the frame.
        assert!(tag.is_structural());

        // A growing file (advertised larger than real) keeps the count.
        let tag = parse_first_frame(&header, &buf, 100_000).expect("xing");
        assert_eq!(tag.frames, 100);
        assert!(!tag.frame_count_distrusted);
    }

    #[test]
    fn empty_flags_leave_a_non_structural_tag() {
        let (header, mut buf) = frame(true, false);
        write_xing(&mut buf, 17, b"Xing", 0x00, None, None, false, None);
        let tag = parse_first_frame(&header, &buf, 1000).expect("xing");
        assert!(!tag.is_structural());
    }

    #[test]
    fn vbri_overrides_and_requires_version_one() {
        let (header, mut buf) = frame(false, false);
        buf[4 + 32..4 + 36].copy_from_slice(b"VBRI");
        buf[4 + 36..4 + 38].copy_from_slice(&1u16.to_be_bytes());
        buf[4 + 42..4 + 46].copy_from_slice(&5_000_000u32.to_be_bytes());
        buf[4 + 46..4 + 50].copy_from_slice(&20_000u32.to_be_bytes());
        let tag = parse_first_frame(&header, &buf, 5_000_000).expect("vbri");
        assert_eq!(tag.kind, VbrKind::Vbri);
        assert_eq!(tag.frames, 20_000);
        assert_eq!(tag.header_filesize, 5_000_000);

        buf[4 + 36..4 + 38].copy_from_slice(&2u16.to_be_bytes());
        assert!(parse_first_frame(&header, &buf, 5_000_000).is_none());
    }

    #[test]
    fn truncated_windows_degrade_to_no_tag_instead_of_panicking() {
        let (header, buf) = frame(true, false);
        for len in 0..buf.len().min(200) {
            let _ = parse_first_frame(&header, &buf[..len], 1000);
        }
        let mut short = buf.clone();
        write_xing(
            &mut short,
            17,
            b"Xing",
            0x07,
            Some(10),
            Some(20),
            true,
            None,
        );
        for len in 0..180 {
            let _ = parse_first_frame(&header, &short[..len], 1000);
        }
    }
}
