//! Streaming MP3 frame walker.
//!
//! The caller feeds the object's bytes in order, in whatever range sizes it
//! likes; between feeds the walker holds only a partial-frame carry plus one
//! open chunk record per overlapping window, so peak memory tracks the
//! caller's range size, never the source length. Frame *payloads* are
//! streamed into each open window's SHA-256 and then dropped — never retained
//! beyond the planner's single candidate-frame carry — and the copy pass
//! re-reads the planned spans.
//!
//! Consumed bytes are trimmed from the front of the buffer once per feed (and
//! once per phase step), not once per frame: `Vec::drain` moves the whole
//! remaining tail, so a per-frame trim made the walk quadratic in the range
//! size — 8 MiB ranges cost ~35× more CPU than 8 KiB ranges for identical
//! output. Every read is offset-based (`cursor - buf_start`), so nothing
//! depends on the buffer starting at the cursor.
//!
//! Ordering mirrors `mp3_read_header` in the pinned `libavformat/mp3dec.c`:
//! skip consecutive leading ID3v2 tags, inspect the first frame for
//! Xing/Info/VBRI, then confirm the first audio frame with the same bounded
//! 64 KiB two-frame search.

use crate::header::{FrameHeader, HeaderReject, MAX_FRAME_BYTES};
use crate::plan::{chunk_count_for, ChunkPlan, FrameRef, Planner};
use crate::tags::{id3v2_len, id3v2_match, ID3V2_HEADER_SIZE};
use crate::vbr::{self, VbrTag};
use crate::{
    frame_micros, micros_to_seconds_q3, ticks_per_sample, ticks_to_micros, Mp3Error, CHUNK_SECONDS,
    STEP_SECONDS, TICKS_PER_SECOND,
};

/// ffmpeg's initial synchronization window.
const SYNC_WINDOW_BYTES: u64 = 64 * 1024;

/// Bytes of the structural first frame made available to the Xing/VBRI
/// parser. ffmpeg reads those fields through `avio` and can run past the
/// frame; 1 KiB covers every field either tag defines with room to spare.
const VBR_WINDOW_BYTES: u64 = 1024;

#[derive(Debug, Clone, Copy)]
pub struct WalkOptions {
    pub object_len: u64,
    /// Exclusive end of the audio region, from [`crate::tags::scan_tail`].
    pub audio_end: u64,
    pub chunk_ticks: u64,
    pub step_ticks: u64,
    pub max_resync_events: u32,
    /// Bytes a single resync may skip before the object is declared
    /// unsupported.
    pub max_resync_scan_bytes: u64,
    pub max_spans_per_chunk: usize,
    /// Largest chunk the caller can accept without re-encoding. Exceeding it
    /// aborts the walk immediately rather than after a full source read.
    pub chunk_byte_ceiling: u64,
}

impl WalkOptions {
    pub fn new(object_len: u64, audio_end: u64) -> Self {
        Self {
            object_len,
            audio_end,
            chunk_ticks: CHUNK_SECONDS * TICKS_PER_SECOND,
            step_ticks: STEP_SECONDS * TICKS_PER_SECOND,
            max_resync_events: 8,
            max_resync_scan_bytes: 64 * 1024,
            max_spans_per_chunk: 8,
            chunk_byte_ceiling: u64::MAX,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct WalkResult {
    pub object_len: u64,
    pub audio_end: u64,
    pub leading_tag_bytes: u64,
    pub trailing_tag_bytes: u64,
    pub first_audio_offset: u64,
    pub audio_frames: u64,
    pub sample_rate: u32,
    pub channels: u8,
    pub samples_per_frame: u32,
    pub vbr: Option<VbrTag>,
    /// Demux stream start, in the 14.112 MHz time base; the offset every
    /// requested chunk start is measured against.
    pub start_ticks: u64,
    /// Exact duration of the frames actually walked.
    pub walked_ticks: u64,
    pub canonical_micros: u64,
    pub chunks: Vec<ChunkPlan>,
    pub resync_events: u32,
    pub junk_bytes: u64,
    /// Bytes at the tail that belonged to an incomplete final frame.
    pub truncated_tail_bytes: u64,
    pub variable_bitrate: bool,
}

impl WalkResult {
    /// Probe `duration_seconds`: the canonical duration quantized to the
    /// manifest's three decimals.
    pub fn canonical_seconds(&self) -> f64 {
        micros_to_seconds_q3(self.canonical_micros)
    }

    pub fn max_chunk_bytes(&self) -> u64 {
        self.chunks
            .iter()
            .map(|chunk| chunk.byte_count)
            .max()
            .unwrap_or(0)
    }

    /// True when every planned chunk is a single contiguous source run — the
    /// normal case, and the one whose bytes are provably ffmpeg-identical.
    pub fn all_chunks_contiguous(&self) -> bool {
        self.chunks.iter().all(|chunk| chunk.spans.len() == 1)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Phase {
    LeadingTags,
    VbrProbe,
    InitialSync,
    Frames,
    Done,
}

#[derive(Debug)]
pub struct Mp3Walker {
    options: WalkOptions,
    phase: Phase,
    buf: Vec<u8>,
    buf_start: u64,
    fed_end: u64,
    cursor: u64,

    leading_tag_bytes: u64,
    data_offset: u64,
    sync_limit: u64,
    saw_free_format: bool,

    vbr: Option<VbrTag>,
    clock: Option<FrameHeader>,
    first_audio_offset: u64,
    audio_frames: u64,
    frame_ticks: u64,
    frame_micros: u64,
    walked_ticks: u64,
    variable_bitrate: bool,
    resync_events: u32,
    junk_bytes: u64,
    truncated_tail_bytes: u64,
    /// Bytes `trim` has memmoved so far: the deterministic cost counter that
    /// pins the once-per-feed trim discipline (test/telemetry only).
    trim_bytes_moved: u64,

    planner: Option<Planner>,
}

impl Mp3Walker {
    pub fn new(options: WalkOptions) -> Self {
        Self {
            options,
            phase: Phase::LeadingTags,
            buf: Vec::new(),
            buf_start: 0,
            fed_end: 0,
            cursor: 0,
            leading_tag_bytes: 0,
            data_offset: 0,
            sync_limit: 0,
            saw_free_format: false,
            vbr: None,
            clock: None,
            first_audio_offset: 0,
            audio_frames: 0,
            frame_ticks: 0,
            frame_micros: 0,
            walked_ticks: 0,
            variable_bitrate: false,
            resync_events: 0,
            junk_bytes: 0,
            truncated_tail_bytes: 0,
            trim_bytes_moved: 0,
            planner: None,
        }
    }

    /// Bytes currently held. Exposed so the Worker can assert that memory
    /// tracks range size rather than source length.
    pub fn buffered_bytes(&self) -> usize {
        self.buf.len()
    }

    /// Total bytes `trim` has moved to the front of the buffer. Linear in
    /// the number of feeds (a carry per feed), never in the number of frames;
    /// the walker tests pin that bound.
    pub fn trim_bytes_moved(&self) -> u64 {
        self.trim_bytes_moved
    }

    /// Feeds the next sequential slice of the object, starting at byte 0.
    pub fn feed(&mut self, bytes: &[u8]) -> Result<(), Mp3Error> {
        let len = bytes.len() as u64;
        let end = self.fed_end.checked_add(len).ok_or(Mp3Error::Overflow)?;
        if end > self.options.object_len {
            return Err(Mp3Error::FeedContractViolated);
        }
        let chunk_start = self.fed_end;
        self.fed_end = end;

        // Bytes the walker has already skipped past (leading tags, frame
        // payloads) are dropped without ever entering the buffer.
        let keep_from = self.cursor.max(chunk_start);
        if keep_from < self.fed_end {
            if self.buf.is_empty() {
                self.buf_start = keep_from;
            }
            let offset = (keep_from - chunk_start) as usize;
            self.buf.extend_from_slice(&bytes[offset..]);
        }
        self.pump(false)
    }

    /// Completes the walk. Every byte of the object must have been fed.
    pub fn finish(mut self) -> Result<WalkResult, Mp3Error> {
        if self.fed_end != self.options.object_len {
            return Err(Mp3Error::FeedContractViolated);
        }
        self.pump(true)?;
        if self.phase != Phase::Done {
            return Err(Mp3Error::NoMpegAudio);
        }
        let clock = self.clock.ok_or(Mp3Error::NoMpegAudio)?;
        if self.audio_frames == 0 {
            return Err(Mp3Error::NoMpegAudio);
        }

        let start_ticks = self.start_ticks(&clock)?;
        let canonical_ticks = self.canonical_ticks(&clock)?;
        let canonical_micros = ticks_to_micros(canonical_ticks).ok_or(Mp3Error::Overflow)?;
        let chunks = self
            .planner
            .take()
            .ok_or(Mp3Error::NoMpegAudio)?
            .finish(chunk_count_for(canonical_micros))?;

        Ok(WalkResult {
            object_len: self.options.object_len,
            audio_end: self.options.audio_end,
            leading_tag_bytes: self.leading_tag_bytes,
            trailing_tag_bytes: self.options.object_len - self.options.audio_end,
            first_audio_offset: self.first_audio_offset,
            audio_frames: self.audio_frames,
            sample_rate: clock.sample_rate,
            channels: clock.channels,
            samples_per_frame: clock.samples_per_frame,
            vbr: self.vbr,
            start_ticks,
            walked_ticks: self.walked_ticks,
            canonical_micros,
            chunks,
            resync_events: self.resync_events,
            junk_bytes: self.junk_bytes,
            truncated_tail_bytes: self.truncated_tail_bytes,
            variable_bitrate: self.variable_bitrate,
        })
    }

    fn start_ticks(&self, clock: &FrameHeader) -> Result<u64, Mp3Error> {
        let Some(tag) = self.vbr.as_ref() else {
            return Ok(0);
        };
        let per_sample = ticks_per_sample(clock.sample_rate).ok_or(Mp3Error::Overflow)?;
        u64::from(tag.start_skip_samples())
            .checked_mul(per_sample)
            .ok_or(Mp3Error::Overflow)
    }

    /// Canonical duration in ticks.
    ///
    /// A trusted VBR frame count is authoritative, exactly as in ffmpeg, but
    /// it is clamped to what the walk actually found: a tag that over-claims
    /// duration on a truncated object would otherwise produce a manifest the
    /// gateway's final-coverage gate must reject.
    fn canonical_ticks(&self, clock: &FrameHeader) -> Result<u64, Mp3Error> {
        let walked = self.walked_ticks;
        let Some(tag) = self.vbr.as_ref() else {
            return Ok(walked);
        };
        if tag.frames == 0 {
            return Ok(walked);
        }
        let per_sample = ticks_per_sample(clock.sample_rate).ok_or(Mp3Error::Overflow)?;
        let full = u64::from(tag.frames)
            .checked_mul(u64::from(clock.samples_per_frame))
            .ok_or(Mp3Error::Overflow)?;
        let padded = full
            .saturating_sub(u64::from(tag.start_pad))
            .saturating_sub(u64::from(tag.end_pad));
        let tagged = padded.checked_mul(per_sample).ok_or(Mp3Error::Overflow)?;
        Ok(tagged.min(walked))
    }

    fn avail(&self) -> u64 {
        self.fed_end
    }

    /// Buffered slice at an absolute object offset.
    ///
    /// Every offset in this walker is `u64` while `usize` is 32-bit on
    /// wasm32, so the range is bounds-checked *before* the cast; a truncating
    /// cast could otherwise alias a far offset onto a valid buffer index.
    fn peek(&self, absolute: u64, len: usize) -> Option<&[u8]> {
        let start = absolute.checked_sub(self.buf_start)?;
        if start > self.buf.len() as u64 {
            return None;
        }
        let start = start as usize;
        self.buf.get(start..start.checked_add(len)?)
    }

    fn header_at(&self, absolute: u64) -> Option<u32> {
        let bytes = self.peek(absolute, 4)?;
        Some(u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
    }

    /// Drops the consumed prefix. `Vec::drain` memmoves the remaining tail,
    /// so this must run once per feed/step — never per frame (see the
    /// module docs).
    fn trim(&mut self) {
        if self.buf.is_empty() || self.cursor <= self.buf_start {
            return;
        }
        let drop = (self.cursor - self.buf_start).min(self.buf.len() as u64) as usize;
        self.trim_bytes_moved += (self.buf.len() - drop) as u64;
        self.buf.drain(..drop);
        self.buf_start += drop as u64;
    }

    /// Runs every step the buffered bytes allow, then trims once so the
    /// buffer between feeds is only the carry (`buffered_bytes` telemetry
    /// and the peak-buffer bound depend on that).
    fn pump(&mut self, eof: bool) -> Result<(), Mp3Error> {
        let outcome = self.pump_inner(eof);
        self.trim();
        outcome
    }

    fn pump_inner(&mut self, eof: bool) -> Result<(), Mp3Error> {
        loop {
            self.trim();
            let progressed = match self.phase {
                Phase::LeadingTags => self.step_leading_tags(eof)?,
                Phase::VbrProbe => self.step_vbr_probe(eof)?,
                Phase::InitialSync => self.step_initial_sync(eof)?,
                Phase::Frames => self.step_frames(eof)?,
                Phase::Done => false,
            };
            if !progressed {
                return Ok(());
            }
        }
    }

    fn step_leading_tags(&mut self, eof: bool) -> Result<bool, Mp3Error> {
        let Some(head) = self.peek(self.cursor, ID3V2_HEADER_SIZE as usize) else {
            if eof || self.cursor + ID3V2_HEADER_SIZE > self.options.object_len {
                self.enter_vbr_probe();
                return Ok(true);
            }
            return Ok(false);
        };
        if !id3v2_match(head) {
            self.enter_vbr_probe();
            return Ok(true);
        }
        let len = id3v2_len(head);
        let end = self.cursor.checked_add(len).ok_or(Mp3Error::Overflow)?;
        if end > self.options.audio_end {
            return Err(Mp3Error::NoMpegAudio);
        }
        self.leading_tag_bytes += len;
        self.cursor = end;
        Ok(true)
    }

    fn enter_vbr_probe(&mut self) {
        self.data_offset = self.cursor;
        self.phase = Phase::VbrProbe;
    }

    fn step_vbr_probe(&mut self, eof: bool) -> Result<bool, Mp3Error> {
        let want = VBR_WINDOW_BYTES.min(self.options.audio_end.saturating_sub(self.cursor));
        if !eof && self.avail() < self.cursor + want {
            return Ok(false);
        }
        let available = self.avail().saturating_sub(self.cursor).min(want) as usize;
        let mut search_start = self.cursor;
        if let Some(window) = self.peek(self.cursor, available) {
            if let Some(raw) = self.header_at(self.cursor) {
                if let Ok(header) = FrameHeader::parse(raw) {
                    let after_header = self
                        .options
                        .object_len
                        .saturating_sub(self.cursor.saturating_add(4));
                    if let Some(tag) = vbr::parse_first_frame(&header, window, after_header) {
                        if tag.is_structural() {
                            let end = self.cursor + u64::from(header.frame_bytes);
                            if end <= self.options.audio_end {
                                self.vbr = Some(tag);
                                search_start = end;
                            }
                        }
                    }
                }
            }
        }
        self.cursor = search_start;
        self.sync_limit = search_start
            .checked_add(SYNC_WINDOW_BYTES)
            .ok_or(Mp3Error::Overflow)?;
        self.phase = Phase::InitialSync;
        Ok(true)
    }

    /// ffmpeg's `mp3_read_header` confirmation loop: a candidate is only the
    /// first audio frame if the next header is MP3_MASK-compatible. Accepting
    /// the first superficially valid four bytes false-syncs on tag or junk
    /// data, so the pair check is load-bearing.
    fn step_initial_sync(&mut self, eof: bool) -> Result<bool, Mp3Error> {
        let mut pos = self.cursor;
        loop {
            if pos >= self.sync_limit {
                self.cursor = pos;
                return Err(self.sync_failure());
            }
            let needed = (pos + 8 + u64::from(MAX_FRAME_BYTES)).min(self.options.audio_end);
            if !eof && self.avail() < needed {
                self.cursor = pos;
                return Ok(false);
            }
            if pos + 4 > self.options.audio_end {
                self.cursor = pos;
                return Err(self.sync_failure());
            }
            let Some(raw) = self.header_at(pos) else {
                self.cursor = pos;
                return Err(self.sync_failure());
            };
            match FrameHeader::parse(raw) {
                Ok(header) => {
                    let end = pos + u64::from(header.frame_bytes);
                    if end <= self.options.audio_end && self.confirms(&header, end) {
                        self.begin_frames(pos, header)?;
                        return Ok(true);
                    }
                }
                Err(HeaderReject::FreeFormat) => self.saw_free_format = true,
                Err(_) => {}
            }
            pos += 1;
        }
    }

    /// A candidate frame is confirmed by a compatible following header, or by
    /// ending exactly at the audio boundary (a legitimate single/final frame).
    fn confirms(&self, header: &FrameHeader, end: u64) -> bool {
        if end == self.options.audio_end {
            return true;
        }
        if end + 4 > self.options.audio_end {
            return false;
        }
        self.header_at(end)
            .and_then(|raw| FrameHeader::parse(raw).ok())
            .is_some_and(|next| header.compatible_with(&next))
    }

    fn sync_failure(&self) -> Mp3Error {
        if self.saw_free_format {
            Mp3Error::UnsupportedFreeFormat
        } else {
            Mp3Error::NoMpegAudio
        }
    }

    fn begin_frames(&mut self, offset: u64, header: FrameHeader) -> Result<(), Mp3Error> {
        let per_sample = ticks_per_sample(header.sample_rate).ok_or(Mp3Error::Overflow)?;
        self.frame_ticks = u64::from(header.samples_per_frame)
            .checked_mul(per_sample)
            .ok_or(Mp3Error::Overflow)?;
        self.frame_micros =
            frame_micros(header.samples_per_frame, header.sample_rate).ok_or(Mp3Error::Overflow)?;
        self.first_audio_offset = offset;
        self.clock = Some(header);
        self.cursor = offset;
        self.phase = Phase::Frames;

        let start_ticks = self.start_ticks(&header)?;
        self.planner = Some(Planner::new(
            start_ticks,
            self.options.chunk_ticks,
            self.options.step_ticks,
            self.options.max_spans_per_chunk,
            self.options.chunk_byte_ceiling,
        ));
        Ok(())
    }

    fn step_frames(&mut self, eof: bool) -> Result<bool, Mp3Error> {
        let clock = self.clock.ok_or(Mp3Error::NoMpegAudio)?;
        loop {
            if self.cursor >= self.options.audio_end {
                self.phase = Phase::Done;
                return Ok(true);
            }
            if self.cursor + 4 > self.options.audio_end {
                // Fewer than four bytes left: an incomplete final frame.
                self.truncated_tail_bytes += self.options.audio_end - self.cursor;
                self.cursor = self.options.audio_end;
                self.phase = Phase::Done;
                return Ok(true);
            }
            if !eof && self.avail() < self.cursor + 8 + u64::from(MAX_FRAME_BYTES) {
                return Ok(false);
            }
            let Some(raw) = self.header_at(self.cursor) else {
                return Ok(false);
            };
            match FrameHeader::parse(raw) {
                Ok(header) if header.same_clock(&clock) => {
                    let end = self.cursor + u64::from(header.frame_bytes);
                    if end > self.options.audio_end {
                        // Committed frame runs past the audio boundary: drop
                        // it rather than emit a partial frame.
                        self.truncated_tail_bytes += self.options.audio_end - self.cursor;
                        self.cursor = self.options.audio_end;
                        self.phase = Phase::Done;
                        return Ok(true);
                    }
                    self.accept_frame(&header, end)?;
                }
                Ok(_) => return Err(Mp3Error::UnsupportedHeaderTransition),
                Err(_) => {
                    if !self.resync(&clock, eof)? {
                        return Ok(false);
                    }
                }
            }
        }
    }

    fn accept_frame(&mut self, header: &FrameHeader, end: u64) -> Result<(), Mp3Error> {
        let clock = self.clock.expect("frame phase implies a clock");
        if header.bitrate_kbps != clock.bitrate_kbps || header.padding != clock.padding {
            self.variable_bitrate = true;
        }
        let pts = self.walked_ticks;
        let frame = FrameRef {
            offset: self.cursor,
            len: end - self.cursor,
            pts,
            micros: self.frame_micros,
        };
        // The frame is fully buffered at accept time (the `step_frames`
        // guard), so its payload is a direct slice of `buf` — indexed by
        // offset so the planner borrow and the buffer borrow stay disjoint.
        let start = (self.cursor - self.buf_start) as usize;
        let payload = &self.buf[start..start + frame.len as usize];
        self.planner
            .as_mut()
            .ok_or(Mp3Error::NoMpegAudio)?
            .push_frame(frame, payload)?;
        self.audio_frames += 1;
        self.walked_ticks = pts
            .checked_add(self.frame_ticks)
            .ok_or(Mp3Error::Overflow)?;
        self.cursor = end;
        Ok(())
    }

    /// Bounded forward resynchronization.
    ///
    /// Deliberately stricter than ffmpeg, whose run-time parser trusts the
    /// first header-shaped four bytes it finds and muxes the skipped bytes
    /// into the packet. Junk is excluded here instead, because the chunk
    /// contract is complete frames only.
    ///
    /// Returns `Ok(false)` when more data is needed to decide.
    fn resync(&mut self, clock: &FrameHeader, eof: bool) -> Result<bool, Mp3Error> {
        if self.resync_events >= self.options.max_resync_events {
            return Err(Mp3Error::ResyncLimitExceeded);
        }
        let origin = self.cursor;
        let scan_limit = origin
            .checked_add(self.options.max_resync_scan_bytes)
            .ok_or(Mp3Error::Overflow)?
            .min(self.options.audio_end);
        let mut pos = origin + 1;
        loop {
            if pos >= scan_limit {
                if pos >= self.options.audio_end {
                    // Only junk remains before the tail boundary.
                    self.truncated_tail_bytes += self.options.audio_end - origin;
                    self.junk_bytes += self.options.audio_end - origin;
                    self.resync_events += 1;
                    self.cursor = self.options.audio_end;
                    self.phase = Phase::Done;
                    return Ok(true);
                }
                return Err(Mp3Error::ResyncLimitExceeded);
            }
            let needed = (pos + 8 + u64::from(MAX_FRAME_BYTES)).min(self.options.audio_end);
            if !eof && self.avail() < needed {
                return Ok(false);
            }
            if pos + 4 > self.options.audio_end {
                pos = self.options.audio_end;
                continue;
            }
            let Some(raw) = self.header_at(pos) else {
                return Ok(false);
            };
            if let Ok(header) = FrameHeader::parse(raw) {
                let end = pos + u64::from(header.frame_bytes);
                if end <= self.options.audio_end && self.confirms(&header, end) {
                    if !header.same_clock(clock) {
                        return Err(Mp3Error::UnsupportedHeaderTransition);
                    }
                    self.junk_bytes += pos - origin;
                    self.resync_events += 1;
                    self.cursor = pos;
                    return Ok(true);
                }
            }
            pos += 1;
        }
    }
}
