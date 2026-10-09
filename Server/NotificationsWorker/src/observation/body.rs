//! The complete body of a probe scan, retained so a proved change can be
//! observed in full without a second publisher request. The first
//! `BODY_BUFFER_BYTES` stay in the isolate; a larger body spills its leading
//! parts into one private multipart scratch upload, exactly as the spool does.
//! An unchanged or failed scan aborts it, so nothing becomes an object; a
//! changed scan uploads the in-isolate tail as the final part, completes the
//! upload, replays it by range and then deletes it.

/// R2's minimum part size, so it is also the scratch part size: one buffer of
/// this size is allocated on a body's first byte and never grows.
pub const BODY_BUFFER_BYTES: usize = 5 * 1024 * 1024;

/// Range-read size of a spilled body's replay. The replay already holds the
/// full observation's spool buffer and a part in flight, and every window is
/// held twice (the runtime's read buffer and its Wasm copy), so it reads 1 MiB
/// at a time rather than a part. A changed body over the buffer is rare, so the
/// extra range reads are cheap.
pub const REPLAY_WINDOW_BYTES: usize = 1024 * 1024;
const _: () = assert!(REPLAY_WINDOW_BYTES <= BODY_BUFFER_BYTES);

/// The next range `(offset, length)` of a replay that has read `read` of
/// `length` bytes; `None` at the end. The last window is the remainder.
pub fn replay_window(read: usize, length: usize) -> Option<(usize, usize)> {
    (read < length).then(|| (read, REPLAY_WINDOW_BYTES.min(length - read)))
}

/// Collects a body into `BODY_BUFFER_BYTES` parts. 304 and strong-ETag polls
/// never push a byte, so they allocate nothing.
#[derive(Default)]
pub struct BodyAccumulator {
    buffer: Vec<u8>,
}
impl BodyAccumulator {
    /// Appends `bytes`. When the buffer becomes exactly full it is handed out
    /// as the next part and the remainder starts the next buffer. Reads are at
    /// most `CHUNK_BYTES`, so one push completes at most one part.
    pub fn push(&mut self, bytes: &[u8]) -> Option<Vec<u8>> {
        if bytes.is_empty() {
            return None;
        }
        if self.buffer.capacity() == 0 {
            self.buffer = Vec::with_capacity(BODY_BUFFER_BYTES);
        }
        let room = BODY_BUFFER_BYTES - self.buffer.len();
        if bytes.len() < room {
            self.buffer.extend_from_slice(bytes);
            return None;
        }
        let (head, rest) = bytes.split_at(room);
        self.buffer.extend_from_slice(head);
        let part = std::mem::take(&mut self.buffer);
        if !rest.is_empty() {
            self.buffer = Vec::with_capacity(BODY_BUFFER_BYTES);
            self.buffer.extend_from_slice(rest);
        }
        Some(part)
    }
    /// The bytes after the last handed-out part.
    pub fn finish(self) -> Vec<u8> {
        self.buffer
    }
}

#[cfg(target_arch = "wasm32")]
pub use retained::*;
#[cfg(target_arch = "wasm32")]
mod retained {
    use super::{
        super::{
            scratch::{self, Spill, BUFFER_BYTES},
            store::fault,
        },
        replay_window, BodyAccumulator,
    };
    use crate::polling::timing::Span;
    use std::{
        cell::Cell,
        future::Future,
        io,
        pin::Pin,
        rc::Rc,
        task::{ready, Context, Poll},
    };
    use tokio::io::{AsyncRead, ReadBuf};
    use worker::{Bucket, Result};

    /// The parser maps this read error to `observation_stage_failed`: storage
    /// trouble, never a publisher failure.
    const STAGE_FAILED: &str = "observation_stage_failed";

    type Pending<T> = Pin<Box<dyn Future<Output = Result<T>>>>;

    /// The scan's shared view of its storage: `storage` marks an outstanding
    /// R2 operation (a deadline then is a storage failure) and `sink` is the
    /// timer that keeps that time out of `publisher_fetch_ms`.
    #[derive(Clone)]
    pub struct Scratch {
        pub bucket: Bucket,
        pub feed_id: String,
        pub storage: Rc<Cell<bool>>,
        pub sink: Rc<Cell<u64>>,
    }

    /// Feeds every byte the parser reads into the accumulator. A full part is
    /// uploaded before the next read returns, so the parser waits while it
    /// uploads (the spool's backpressure); its bytes have already been read.
    pub struct Retained<R> {
        inner: R,
        accumulator: BodyAccumulator,
        spill: Spill,
        spilled: usize,
        scratch: Scratch,
        uploading: Option<Pending<()>>,
    }
    impl<R> Retained<R> {
        pub fn new(inner: R, spill: Spill, scratch: Scratch) -> Self {
            Self {
                inner,
                accumulator: BodyAccumulator::default(),
                spill,
                spilled: 0,
                scratch,
                uploading: None,
            }
        }
        /// The body after a complete, valid-EOF parse. The parser read EOF only
        /// after the last part finished uploading.
        pub fn into_body(self) -> Result<Body> {
            if self.uploading.is_some() {
                return Err(fault("body_part_in_flight"));
            }
            let tail = self.accumulator.finish();
            Ok(if self.spilled == 0 {
                Body::Memory(tail)
            } else {
                Body::Spilled {
                    spill: self.spill,
                    bucket: self.scratch.bucket,
                    spilled: self.spilled,
                    tail,
                    object: None,
                }
            })
        }
    }
    impl<R: AsyncRead + Unpin> AsyncRead for Retained<R> {
        fn poll_read(
            mut self: Pin<&mut Self>,
            cx: &mut Context<'_>,
            output: &mut ReadBuf<'_>,
        ) -> Poll<io::Result<()>> {
            let this = &mut *self;
            if let Some(uploading) = this.uploading.as_mut() {
                // Items parsed since the part was handed out reset the shared
                // flag; while the parser waits here, storage is what it waits on.
                this.scratch.storage.set(true);
                let uploaded = ready!(uploading.as_mut().poll(cx));
                this.uploading = None;
                this.scratch.storage.set(false);
                uploaded.map_err(|_| io::Error::other(STAGE_FAILED))?;
                this.spilled += BUFFER_BYTES;
            }
            let before = output.filled().len();
            ready!(Pin::new(&mut this.inner).poll_read(cx, output))?;
            if let Some(part) = this.accumulator.push(&output.filled()[before..]) {
                let (spill, scratch) = (this.spill.clone(), this.scratch.clone());
                this.uploading = Some(Box::pin(async move {
                    let _span = Span::new(scratch.sink.clone(), None);
                    scratch::push_part(&spill, &scratch.bucket, &scratch.feed_id, part).await
                }));
            }
            Poll::Ready(Ok(()))
        }
    }

    /// A complete probe body.
    pub enum Body {
        /// Every byte is in the isolate; no part was uploaded.
        Memory(Vec<u8>),
        /// The leading `spilled` bytes are uploaded parts, the rest is `tail`,
        /// until `complete` uploads it as the final part. `object` is the
        /// scratch key once the upload is being completed.
        Spilled {
            spill: Spill,
            bucket: Bucket,
            spilled: usize,
            tail: Vec<u8>,
            object: Option<String>,
        },
    }
    impl Body {
        /// The scan ended without a committed full observation: unchanged,
        /// failed or deferred. An upload that was never completed (including
        /// one whose final part failed) is aborted; a completed one is deleted.
        pub async fn discard(self) {
            if let Body::Spilled {
                spill,
                bucket,
                object,
                ..
            } = self
            {
                scratch::abort(&spill).await;
                if let Some(key) = object {
                    // Best effort: the cleanup cron sweeps a left object.
                    Self::delete(&bucket, key).await;
                }
            }
        }
        /// Makes a spilled body readable: the tail becomes the upload's final
        /// part, so the replay streams the completed object and the isolate
        /// holds none of the body. The key is recorded just before completion,
        /// so a deadline during it still leaves its owner a key to delete.
        pub async fn complete(&mut self) -> Result<()> {
            if let Body::Spilled {
                spill,
                bucket,
                spilled,
                tail,
                object: object @ None,
            } = self
            {
                if !tail.is_empty() {
                    let part = std::mem::take(tail);
                    let length = part.len();
                    scratch::push_final_part(spill, part).await?;
                    *spilled += length;
                }
                *object = spill
                    .borrow()
                    .key()
                    .map(str::to_string)
                    .ok_or_else(|| fault("scratch_missing"))
                    .map(Some)?;
                scratch::complete(spill, bucket)
                    .await?
                    .ok_or_else(|| fault("scratch_missing"))?;
            }
            Ok(())
        }
        /// A reader over the whole body; a spilled body must be completed.
        pub fn reader(&self, storage: Rc<Cell<bool>>) -> Result<BodyReader<'_>> {
            Ok(match self {
                Body::Memory(bytes) => BodyReader::new(None, bytes, storage),
                Body::Spilled {
                    bucket,
                    spilled,
                    tail,
                    object: Some(key),
                    ..
                } => BodyReader::new(Some((bucket.clone(), key.clone(), *spilled)), tail, storage),
                Body::Spilled { object: None, .. } => return Err(fault("scratch_incomplete")),
            })
        }
        /// The replay finished: free the in-isolate bytes before the full
        /// observation's own storage work. Only a scratch key remains.
        pub fn release_bytes(&mut self) {
            match self {
                Body::Memory(bytes) | Body::Spilled { tail: bytes, .. } => *bytes = Vec::new(),
            }
        }
        /// After the full observation: the completed scratch object is no
        /// longer needed. A crash before this delete leaves one object for the
        /// sweeper; a failed delete after a committed scan is only logged.
        pub async fn delete_object(self) {
            if let Body::Spilled {
                bucket,
                object: Some(key),
                ..
            } = self
            {
                Self::delete(&bucket, key).await;
            }
        }
        async fn delete(bucket: &Bucket, key: String) {
            if bucket.delete(key).await.is_err() {
                worker::console_warn!(
                    "{}",
                    serde_json::json!({"event":"feed_scratch_delete_failed"})
                );
            }
        }
    }

    /// Replays a retained body: a completed object in `REPLAY_WINDOW_BYTES`
    /// range reads, or the in-isolate bytes in place. Every byte is the first
    /// response's.
    pub struct BodyReader<'a> {
        /// The completed scratch object and its length.
        object: Option<(Bucket, String, usize)>,
        read: usize,
        window: Vec<u8>,
        tail: &'a [u8],
        offset: usize,
        storage: Rc<Cell<bool>>,
        pending: Option<Pending<Vec<u8>>>,
    }
    impl<'a> BodyReader<'a> {
        fn new(
            object: Option<(Bucket, String, usize)>,
            tail: &'a [u8],
            storage: Rc<Cell<bool>>,
        ) -> Self {
            Self {
                object,
                read: 0,
                window: vec![],
                tail,
                offset: 0,
                storage,
                pending: None,
            }
        }
    }
    impl AsyncRead for BodyReader<'_> {
        fn poll_read(
            mut self: Pin<&mut Self>,
            cx: &mut Context<'_>,
            output: &mut ReadBuf<'_>,
        ) -> Poll<io::Result<()>> {
            let this = &mut *self;
            if output.remaining() == 0 {
                return Poll::Ready(Ok(()));
            }
            if this.offset == this.window.len() {
                let Some((bucket, key, (offset, size))) =
                    this.object.as_ref().and_then(|(bucket, key, length)| {
                        replay_window(this.read, *length).map(|window| (bucket, key, window))
                    })
                else {
                    // An in-isolate body is read in place; a completed object
                    // has no tail left, so this is its end.
                    this.window = Vec::new();
                    this.offset = 0;
                    let count = output.remaining().min(this.tail.len());
                    output.put_slice(&this.tail[..count]);
                    this.tail = &this.tail[count..];
                    return Poll::Ready(Ok(()));
                };
                if this.pending.is_none() {
                    let (bucket, key) = (bucket.clone(), key.clone());
                    this.pending = Some(Box::pin(async move {
                        scratch::read(&bucket, &key, offset, size).await
                    }));
                }
                this.storage.set(true);
                let window = ready!(this
                    .pending
                    .as_mut()
                    .expect("read created above")
                    .as_mut()
                    .poll(cx));
                this.pending = None;
                this.storage.set(false);
                this.window = window.map_err(|_| io::Error::other(STAGE_FAILED))?;
                this.read += this.window.len();
                this.offset = 0;
            }
            let count = output.remaining().min(this.window.len() - this.offset);
            output.put_slice(&this.window[this.offset..this.offset + count]);
            this.offset += count;
            Poll::Ready(Ok(()))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Pushes `length` bytes in `chunk`-sized reads; returns parts and tail.
    fn accumulate(length: usize, chunk: usize) -> (Vec<Vec<u8>>, Vec<u8>) {
        let body: Vec<u8> = (0..length).map(|i| (i % 251) as u8).collect();
        let mut accumulator = BodyAccumulator::default();
        let mut parts = vec![];
        for bytes in body.chunks(chunk) {
            assert!(accumulator.buffer.capacity() <= BODY_BUFFER_BYTES);
            parts.extend(accumulator.push(bytes));
            assert!(accumulator.buffer.capacity() <= BODY_BUFFER_BYTES);
        }
        let tail = accumulator.finish();
        let mut rebuilt = parts.concat();
        rebuilt.extend(&tail);
        assert_eq!(rebuilt, body, "{length} bytes in {chunk}-byte reads");
        (parts, tail)
    }

    #[test]
    fn body_parts_are_exact_buffers_and_the_tail_is_the_rest() {
        let cap = BODY_BUFFER_BYTES;
        for chunk in [64 * 1024, 65_537, 4_093, 1] {
            if chunk == 1 {
                // A byte at a time across one boundary is enough.
                let (parts, tail) = accumulate(cap + 3, chunk);
                assert_eq!((parts.len(), tail.len()), (1, 3));
                continue;
            }
            for (length, expected_parts, expected_tail) in [
                (0, 0, 0),
                (cap - 1, 0, cap - 1),
                (cap, 1, 0),
                (cap + 1, 1, 1),
                (2 * cap, 2, 0),
                (2 * cap + 12_345, 2, 12_345),
            ] {
                let (parts, tail) = accumulate(length, chunk);
                assert_eq!(parts.len(), expected_parts, "{length}/{chunk}");
                assert_eq!(tail.len(), expected_tail, "{length}/{chunk}");
                for part in &parts {
                    assert_eq!(part.len(), cap);
                    assert_eq!(part.capacity(), cap, "a part never grows");
                }
                assert!(tail.capacity() <= cap);
            }
        }
    }

    /// The bytes a replay reads back with `replay_window` from `object`.
    fn replay(object: &[u8]) -> Vec<u8> {
        let (mut read, mut replayed) = (0, vec![]);
        while let Some((offset, size)) = replay_window(read, object.len()) {
            assert_eq!(offset, read, "windows are contiguous");
            assert!(size > 0 && size <= REPLAY_WINDOW_BYTES);
            replayed.extend_from_slice(&object[offset..offset + size]);
            read += size;
        }
        replayed
    }

    #[test]
    fn a_spilled_body_with_its_tail_as_final_part_is_a_valid_upload_that_replays_exactly() {
        let cap = BODY_BUFFER_BYTES;
        for length in [
            cap + 1,
            cap + 3 * REPLAY_WINDOW_BYTES,
            2 * cap,
            2 * cap + 12_345,
        ] {
            let (mut parts, tail) = accumulate(length, 64 * 1024);
            if !tail.is_empty() {
                parts.push(tail);
            }
            // R2: every part but the last is the same size; the last is not
            // larger and is never empty.
            let (last, leading) = parts.split_last().expect("a spilled body has parts");
            assert!(leading.iter().all(|part| part.len() == cap), "{length}");
            assert!(!last.is_empty() && last.len() <= cap, "{length}");
            let object = parts.concat();
            assert_eq!(object.len(), length);
            let body: Vec<u8> = (0..length).map(|i| (i % 251) as u8).collect();
            assert_eq!(replay(&object), body, "{length}");
        }
    }

    #[test]
    fn replay_windows_end_with_the_short_remainder() {
        let w = REPLAY_WINDOW_BYTES;
        assert_eq!(replay_window(0, 0), None);
        assert_eq!(replay_window(0, 1), Some((0, 1)));
        assert_eq!(replay_window(0, w - 1), Some((0, w - 1)));
        assert_eq!(replay_window(0, w), Some((0, w)));
        assert_eq!(replay_window(w, w), None);
        assert_eq!(replay_window(w, w + 1), Some((w, 1)));
        let length = 5 * w + 777;
        let windows: Vec<_> = std::iter::successors(replay_window(0, length), |(offset, size)| {
            replay_window(offset + size, length)
        })
        .collect();
        assert_eq!(windows.len(), 6);
        assert_eq!(windows.last(), Some(&(5 * w, 777)));
    }

    #[test]
    fn an_empty_body_allocates_nothing() {
        let mut accumulator = BodyAccumulator::default();
        assert_eq!(accumulator.push(&[]), None);
        assert_eq!(accumulator.finish().capacity(), 0);
    }
}
