use crate::feed_resource::{MAX_DECODED_BYTES, MAX_FIELD_BYTES};
use std::io;
use std::pin::Pin;
use std::task::{Context, Poll};
use tokio::io::{AsyncRead, ReadBuf};

/// A lexical allocation guard before quick-xml fills its event buffer. This is
/// not a second XML parser: syntax validation stays with quick-xml. Track text,
/// quoted markup, CDATA and comments so embedded `>` cannot reset a huge token.
pub(super) struct GuardedReader<R> {
    inner: R,
    decoded: usize,
    token: usize,
    mode: Mode,
    quote: Option<u8>,
    recent: [u8; 9],
}

#[derive(Clone, Copy)]
enum Mode {
    Text,
    Markup,
    Cdata,
    Comment,
}

impl<R> GuardedReader<R> {
    pub(super) fn new(inner: R) -> Self {
        Self {
            inner,
            decoded: 0,
            token: 0,
            mode: Mode::Text,
            quote: None,
            recent: [0; 9],
        }
    }

    fn accept(&mut self, bytes: &[u8]) -> io::Result<()> {
        self.decoded = self
            .decoded
            .checked_add(bytes.len())
            .ok_or_else(|| io::Error::other("oversized_body"))?;
        if self.decoded > MAX_DECODED_BYTES {
            return Err(io::Error::other("oversized_body"));
        }
        for &byte in bytes {
            self.recent.rotate_left(1);
            self.recent[8] = byte;
            self.token += 1;
            // Allow CDATA/tag delimiters in addition to an exact-limit field.
            if self.token > MAX_FIELD_BYTES + 1024 {
                return Err(io::Error::other("feed_field_limit"));
            }
            match self.mode {
                Mode::Text if byte == b'<' => {
                    self.mode = Mode::Markup;
                    self.token = 1;
                }
                Mode::Markup => {
                    if self.recent == *b"<![CDATA[" {
                        self.mode = Mode::Cdata;
                    } else if self.recent.ends_with(b"<!--") {
                        self.mode = Mode::Comment;
                    } else if let Some(quote) = self.quote {
                        if byte == quote {
                            self.quote = None;
                        }
                    } else if byte == b'\'' || byte == b'"' {
                        self.quote = Some(byte);
                    } else if byte == b'>' {
                        self.mode = Mode::Text;
                        self.token = 0;
                    }
                }
                Mode::Cdata if self.recent.ends_with(b"]]>") => {
                    self.mode = Mode::Text;
                    self.token = 0;
                }
                Mode::Comment if self.recent.ends_with(b"-->") => {
                    self.mode = Mode::Text;
                    self.token = 0;
                }
                _ => {}
            }
        }
        Ok(())
    }
}

impl<R: AsyncRead + Unpin> AsyncRead for GuardedReader<R> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buffer: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let before = buffer.filled().len();
        match Pin::new(&mut self.inner).poll_read(cx, buffer) {
            Poll::Ready(Ok(())) => Poll::Ready(self.accept(&buffer.filled()[before..])),
            result => result,
        }
    }
}
