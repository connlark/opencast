//! A bounded BYOB browser-stream adapter for quick-xml's Tokio io-util reader.
//! No Tokio runtime: Workers promises wake the existing async executor.
use crate::{feed_resource, poll_decisions::fetch_with_deadline};
use std::cell::Cell;
use std::future::Future;
use std::io;
use std::pin::Pin;
use std::rc::Rc;
use std::task::{Context, Poll};
use std::time::Duration;
use tokio::io::{AsyncRead, ReadBuf};
use worker::js_sys::Uint8Array;
use worker::wasm_bindgen::JsValue;
use worker::wasm_bindgen_futures::JsFuture;
use worker::{Delay, Response, ResponseBody};

/// Dropping a raced fetch future alone does not abort the browser's promise.
/// Keep this guard alive through headers, redirects and the entire body scan.
pub(crate) struct FeedFetchCancellation(Option<worker::AbortController>);

impl Default for FeedFetchCancellation {
    fn default() -> Self {
        Self(Some(worker::AbortController::default()))
    }
}

impl FeedFetchCancellation {
    pub(crate) fn signal(&self) -> worker::AbortSignal {
        self.0
            .as_ref()
            .expect("controller lives until drop")
            .signal()
    }
}

impl Drop for FeedFetchCancellation {
    fn drop(&mut self) {
        if let Some(controller) = self.0.take() {
            controller.abort();
        }
    }
}

type PendingRead = Pin<Box<dyn Future<Output = io::Result<Option<Vec<u8>>>>>>;

pub(crate) struct FeedStream {
    reader: JsValue,
    pending: Option<PendingRead>,
    chunk: Vec<u8>,
    offset: usize,
    ended: bool,
    invocation_bytes: Rc<Cell<usize>>,
    decoded_bytes: Rc<Cell<usize>>,
}

impl FeedStream {
    pub(crate) fn new(
        response: &Response,
        invocation_bytes: Rc<Cell<usize>>,
        decoded_bytes: Rc<Cell<usize>>,
    ) -> io::Result<Self> {
        let ResponseBody::Stream(body) = response.body() else {
            return Err(io::Error::other("missing_feed_stream"));
        };
        let reader = crate::worker_glue::open_feed_reader(body.as_ref())
            .map_err(|_| io::Error::other("feed_stream_unavailable"))?;
        Ok(Self {
            reader,
            pending: None,
            chunk: Vec::new(),
            offset: 0,
            ended: false,
            invocation_bytes,
            decoded_bytes,
        })
    }
}

impl Drop for FeedStream {
    fn drop(&mut self) {
        crate::worker_glue::cancel_feed_reader(&self.reader);
    }
}

impl AsyncRead for FeedStream {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        output: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        if output.remaining() == 0 {
            return Poll::Ready(Ok(()));
        }
        if self.offset == self.chunk.len() && !self.ended {
            if self.pending.is_none() {
                let promise = crate::worker_glue::read_feed_chunk(
                    &self.reader,
                    feed_resource::CHUNK_BYTES as u32,
                );
                self.pending = Some(Box::pin(async move {
                    let result = fetch_with_deadline(
                        async {
                            JsFuture::from(promise)
                                .await
                                .map_err(|_| io::Error::other("feed_transfer_interrupted"))
                        },
                        Delay::from(Duration::from_secs(feed_resource::INACTIVITY_SECONDS)),
                        io::Error::other("feed_inactivity_timeout"),
                    )
                    .await?;
                    if result.is_null() || result.is_undefined() {
                        return Ok(None);
                    }
                    let array = Uint8Array::new(&result);
                    if array.length() as usize > feed_resource::CHUNK_BYTES {
                        return Err(io::Error::other("feed_chunk_limit"));
                    }
                    Ok(Some(array.to_vec()))
                }));
            }
            match self
                .pending
                .as_mut()
                .expect("read created above")
                .as_mut()
                .poll(cx)
            {
                Poll::Pending => return Poll::Pending,
                Poll::Ready(result) => {
                    self.pending = None;
                    self.offset = 0;
                    match result? {
                        Some(chunk) => {
                            self.invocation_bytes
                                .set(self.invocation_bytes.get().saturating_add(chunk.len()));
                            self.decoded_bytes
                                .set(self.decoded_bytes.get().saturating_add(chunk.len()));
                            self.chunk = chunk;
                        }
                        None => {
                            self.ended = true;
                            self.chunk.clear();
                        }
                    }
                }
            }
        }
        let count = output.remaining().min(self.chunk.len() - self.offset);
        output.put_slice(&self.chunk[self.offset..self.offset + count]);
        self.offset += count;
        Poll::Ready(Ok(()))
    }
}
