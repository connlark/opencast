//! ID3v2 / ID3v1 / APEv2 boundary parsing.
//!
//! Leading ID3v2 handling mirrors `ff_id3v2_match` + `ff_id3v2_tag_len` and
//! the consecutive-tag loop in `id3v2_read_internal`. The tail rules are
//! deliberately *stricter* than ffmpeg: ffmpeg's MP3 parser only suppresses a
//! trailing `TAG`/`APETAGEX` marker that happens to be buffered at flush,
//! while this walker excludes the complete checked tag so no non-audio byte
//! can reach a chunk.

pub const ID3V2_HEADER_SIZE: u64 = 10;
pub const ID3V1_SIZE: u64 = 128;
pub const APE_FOOTER_SIZE: u64 = 32;

const APE_PREAMBLE: &[u8; 8] = b"APETAGEX";
const APE_MAX_VERSION: u32 = 2000;
const APE_MAX_TAG_BYTES: u32 = 16 * 1024 * 1024 + APE_FOOTER_SIZE as u32;
const APE_FLAG_CONTAINS_HEADER: u32 = 1 << 31;
const APE_FLAG_IS_HEADER: u32 = 1 << 29;

/// ffmpeg's `ff_id3v2_match` against `ID3v2_DEFAULT_MAGIC`.
pub fn id3v2_match(buf: &[u8]) -> bool {
    buf.len() >= ID3V2_HEADER_SIZE as usize
        && &buf[0..3] == b"ID3"
        && buf[3] != 0xFF
        && buf[4] != 0xFF
        && buf[6] & 0x80 == 0
        && buf[7] & 0x80 == 0
        && buf[8] & 0x80 == 0
        && buf[9] & 0x80 == 0
}

/// ffmpeg's `ff_id3v2_tag_len`: header + syncsafe size + optional footer.
/// The syncsafe value is at most 2^28-1, so the sum cannot overflow `u64`.
pub fn id3v2_len(buf: &[u8]) -> u64 {
    let size = (u64::from(buf[6] & 0x7F) << 21)
        | (u64::from(buf[7] & 0x7F) << 14)
        | (u64::from(buf[8] & 0x7F) << 7)
        | u64::from(buf[9] & 0x7F);
    size + ID3V2_HEADER_SIZE
        + if buf[5] & 0x10 != 0 {
            ID3V2_HEADER_SIZE
        } else {
            0
        }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct TailTags {
    /// Exclusive end of the audio region.
    pub audio_end: u64,
    pub id3v1_bytes: u64,
    pub ape_bytes: u64,
}

impl TailTags {
    pub fn total_bytes(&self) -> u64 {
        self.id3v1_bytes + self.ape_bytes
    }
}

/// How many trailing bytes [`scan_tail`] needs to classify every tail shape
/// it supports: an APEv2 footer sitting in front of an ID3v1 tag.
pub const TAIL_PROBE_BYTES: u64 = ID3V1_SIZE + APE_FOOTER_SIZE;

/// Classifies the trailing tag region. `tail` must be the last
/// `min(object_len, TAIL_PROBE_BYTES)` bytes of the object.
///
/// An APEv2 tag's footer records the size of the tag *including* the footer
/// but excluding an optional header, so the full extent is only knowable
/// after reading the footer — which is why the caller reads the tail before
/// walking rather than discovering the boundary at the end.
pub fn scan_tail(object_len: u64, tail: &[u8]) -> TailTags {
    let tail_start = object_len.saturating_sub(tail.len() as u64);
    let mut result = TailTags {
        audio_end: object_len,
        ..TailTags::default()
    };

    let at = |absolute: u64, len: u64| -> Option<&[u8]> {
        let start = absolute.checked_sub(tail_start)? as usize;
        tail.get(start..start.checked_add(len as usize)?)
    };

    if result.audio_end >= ID3V1_SIZE {
        if let Some(bytes) = at(result.audio_end - ID3V1_SIZE, ID3V1_SIZE) {
            if &bytes[0..3] == b"TAG" {
                result.id3v1_bytes = ID3V1_SIZE;
                result.audio_end -= ID3V1_SIZE;
            }
        }
    }

    if result.audio_end >= APE_FOOTER_SIZE {
        if let Some(footer) = at(result.audio_end - APE_FOOTER_SIZE, APE_FOOTER_SIZE) {
            if let Some(total) = ape_tag_bytes(footer, result.audio_end) {
                result.ape_bytes = total;
                result.audio_end -= total;
            }
        }
    }

    result
}

/// Checked APEv2 footer arithmetic (`ff_ape_parse_tag`, plus the header
/// inclusion ffmpeg applies when computing `tag_start`).
fn ape_tag_bytes(footer: &[u8], region_end: u64) -> Option<u64> {
    if &footer[0..8] != APE_PREAMBLE {
        return None;
    }
    let le32 = |offset: usize| {
        u32::from_le_bytes([
            footer[offset],
            footer[offset + 1],
            footer[offset + 2],
            footer[offset + 3],
        ])
    };
    if le32(8) > APE_MAX_VERSION {
        return None;
    }
    let tag_bytes = le32(12);
    if tag_bytes < APE_FOOTER_SIZE as u32 || tag_bytes > APE_MAX_TAG_BYTES {
        return None;
    }
    if le32(16) > 65_536 {
        return None;
    }
    let flags = le32(20);
    if flags & APE_FLAG_IS_HEADER != 0 {
        return None;
    }
    let mut total = u64::from(tag_bytes);
    if flags & APE_FLAG_CONTAINS_HEADER != 0 {
        total += APE_FOOTER_SIZE;
    }
    if total > region_end {
        return None;
    }
    Some(total)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id3v2_header(size: u32, footer: bool) -> Vec<u8> {
        let mut header = vec![b'I', b'D', b'3', 3, 0, if footer { 0x10 } else { 0 }];
        header.extend_from_slice(&[
            ((size >> 21) & 0x7F) as u8,
            ((size >> 14) & 0x7F) as u8,
            ((size >> 7) & 0x7F) as u8,
            (size & 0x7F) as u8,
        ]);
        header
    }

    #[test]
    fn id3v2_length_covers_syncsafe_limits_and_footer() {
        assert!(id3v2_match(&id3v2_header(0, false)));
        assert_eq!(id3v2_len(&id3v2_header(0, false)), 10);
        assert_eq!(id3v2_len(&id3v2_header(194_427, false)), 194_437);
        assert_eq!(id3v2_len(&id3v2_header(194_427, true)), 194_447);
        // Maximum syncsafe payload: 2^28-1.
        assert_eq!(id3v2_len(&id3v2_header(0x0FFF_FFFF, true)), 268_435_475);
    }

    #[test]
    fn id3v2_match_rejects_non_syncsafe_and_wrong_magic() {
        let mut bad = id3v2_header(10, false);
        bad[6] = 0x80;
        assert!(!id3v2_match(&bad));
        let mut version = id3v2_header(10, false);
        version[3] = 0xFF;
        assert!(!id3v2_match(&version));
        assert!(!id3v2_match(b"ID2\x03\x00\x00\x00\x00\x00\x0a"));
        assert!(!id3v2_match(b"ID3"));
    }

    fn ape_footer(tag_bytes: u32, fields: u32, flags: u32, version: u32) -> Vec<u8> {
        let mut footer = APE_PREAMBLE.to_vec();
        footer.extend_from_slice(&version.to_le_bytes());
        footer.extend_from_slice(&tag_bytes.to_le_bytes());
        footer.extend_from_slice(&fields.to_le_bytes());
        footer.extend_from_slice(&flags.to_le_bytes());
        footer.extend_from_slice(&[0u8; 8]);
        footer
    }

    #[test]
    fn tail_scan_strips_id3v1_then_checked_ape() {
        let mut object = vec![0u8; 4096];
        let footer = ape_footer(200, 3, APE_FLAG_CONTAINS_HEADER, 2000);
        let ape_start = 4096 - 128 - 200 - 32;
        object[ape_start + 200..ape_start + 232].copy_from_slice(&footer);
        object[4096 - 128..4096 - 125].copy_from_slice(b"TAG");

        let tail = &object[object.len() - TAIL_PROBE_BYTES as usize..];
        let tags = scan_tail(object.len() as u64, tail);
        assert_eq!(tags.id3v1_bytes, 128);
        assert_eq!(tags.ape_bytes, 232);
        assert_eq!(tags.audio_end, ape_start as u64);
    }

    #[test]
    fn tail_scan_rejects_impossible_ape_footers() {
        let cases = [
            ape_footer(200, 3, APE_FLAG_IS_HEADER, 2000),
            ape_footer(200, 3, 0, 2001),
            ape_footer(4, 3, 0, 2000),
            ape_footer(u32::MAX, 3, 0, 2000),
            ape_footer(200, 70_000, 0, 2000),
            // Tag larger than the object.
            ape_footer(9000, 3, 0, 2000),
        ];
        for footer in cases {
            let mut object = vec![0u8; 4096];
            object[4096 - 32..].copy_from_slice(&footer);
            let tail = &object[object.len() - TAIL_PROBE_BYTES as usize..];
            let tags = scan_tail(object.len() as u64, tail);
            assert_eq!(tags.ape_bytes, 0, "footer {footer:?} should be rejected");
            assert_eq!(tags.audio_end, 4096);
        }
    }

    #[test]
    fn tail_scan_is_a_no_op_on_short_and_clean_objects() {
        assert_eq!(scan_tail(0, &[]).audio_end, 0);
        assert_eq!(scan_tail(10, &[0u8; 10]).audio_end, 10);
        let clean = vec![0xAAu8; 4096];
        let tail = &clean[clean.len() - TAIL_PROBE_BYTES as usize..];
        assert_eq!(
            scan_tail(4096, tail),
            TailTags {
                audio_end: 4096,
                id3v1_bytes: 0,
                ape_bytes: 0
            }
        );
    }
}
