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
    markup_prefix_len: usize,
    markup_may_be_cdata: bool,
    markup_may_be_comment: bool,
    field_limit: usize,
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
            markup_prefix_len: 0,
            markup_may_be_cdata: false,
            markup_may_be_comment: false,
            field_limit: MAX_FIELD_BYTES,
        }
    }

    #[cfg(test)]
    fn with_field_limit(inner: R, field_limit: usize) -> Self {
        let mut reader = Self::new(inner);
        reader.field_limit = field_limit;
        reader
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
            if self.token > self.field_limit + 1024 {
                return Err(io::Error::other("feed_field_limit"));
            }
            match self.mode {
                Mode::Text if byte == b'<' => {
                    self.mode = Mode::Markup;
                    self.token = 1;
                    self.quote = None;
                    self.markup_prefix_len = 1;
                    self.markup_may_be_cdata = true;
                    self.markup_may_be_comment = true;
                }
                Mode::Markup => {
                    if let Some(quote) = self.quote {
                        if byte == quote {
                            self.quote = None;
                        }
                    } else if byte == b'\'' || byte == b'"' {
                        self.quote = Some(byte);
                    } else if self.advance_markup_prefix(byte) {
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

    fn advance_markup_prefix(&mut self, byte: u8) -> bool {
        const CDATA: &[u8] = b"<![CDATA[";
        const COMMENT: &[u8] = b"<!--";
        let index = self.markup_prefix_len;
        self.markup_may_be_cdata =
            self.markup_may_be_cdata && CDATA.get(index).is_some_and(|expected| *expected == byte);
        self.markup_may_be_comment = self.markup_may_be_comment
            && COMMENT.get(index).is_some_and(|expected| *expected == byte);
        self.markup_prefix_len += 1;
        if self.markup_may_be_cdata && self.markup_prefix_len == CDATA.len() {
            self.mode = Mode::Cdata;
            return true;
        }
        if self.markup_may_be_comment && self.markup_prefix_len == COMMENT.len() {
            self.mode = Mode::Comment;
            return true;
        }
        false
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

#[cfg(test)]
mod tests {
    use super::*;
    use futures_util::FutureExt;

    fn lexical_fixture() -> String {
        format!(
            r#"<rss hint="![CDATA[" other='![CDATA[' escaped="&lt;![CDATA["><channel><title>Lexical Show</title>{}<item><guid>one</guid><description><![CDATA[real cdata]]></description><!--real comment--></item></channel></rss>"#,
            "<extension>small</extension>".repeat(80)
        )
    }

    #[test]
    fn legal_attribute_text_never_opens_cdata_at_any_input_boundary() {
        let xml = lexical_fixture();
        assert!(xml.len() > 64 + 1024);
        for split in 0..=xml.len() {
            let mut reader = GuardedReader::with_field_limit(&[] as &[u8], 64);
            reader.accept(&xml.as_bytes()[..split]).unwrap();
            reader.accept(&xml.as_bytes()[split..]).unwrap();
        }

        let scanned =
            crate::rss::scan::scan_rss(xml.as_bytes(), &crate::rss::scan_tests::row(None))
                .now_or_never()
                .unwrap()
                .unwrap();
        assert_eq!(scanned.title, "Lexical Show");
        assert_eq!(scanned.item_count, 1);
    }
}
