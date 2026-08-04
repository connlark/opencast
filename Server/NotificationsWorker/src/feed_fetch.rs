pub(crate) const MAX_FEED_BODY_BYTES: usize = 12 * 1024 * 1024;
// CBC's Akamai edge resets connections for URL-bearing User-Agent values.
// Keep the product identity URL-free for both admission and polling.
pub(crate) const FEED_USER_AGENT: &str = "OpenCast-Notifications/1";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum FeedBodyAppendError {
    Oversized,
    AllocationFailed,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum FeedFetchError {
    InvalidRedirect,
    TooManyRedirects,
    FetchFailed,
    MissingRedirectLocation,
    HTTPStatus(u16),
    OversizedBody,
    InvalidBodyEncoding,
}

impl FeedFetchError {
    #[cfg(target_arch = "wasm32")]
    pub(crate) fn code(&self) -> &'static str {
        match self {
            FeedFetchError::InvalidRedirect => "invalid_redirect",
            FeedFetchError::TooManyRedirects => "too_many_redirects",
            FeedFetchError::FetchFailed => "fetch_failed",
            FeedFetchError::MissingRedirectLocation => "missing_redirect_location",
            FeedFetchError::HTTPStatus(_) => "http_error",
            FeedFetchError::OversizedBody => "oversized_body",
            FeedFetchError::InvalidBodyEncoding => "invalid_body_encoding",
        }
    }

    #[cfg(target_arch = "wasm32")]
    pub(crate) fn http_status(&self) -> Option<u16> {
        match self {
            FeedFetchError::HTTPStatus(status) => Some(*status),
            _ => None,
        }
    }

    pub(crate) fn is_persistent_compatibility(&self) -> bool {
        matches!(self, FeedFetchError::OversizedBody)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum FeedResponseDisposition {
    NotModified,
    Redirect,
    Other,
}

pub(crate) fn feed_response_disposition(status: u16) -> FeedResponseDisposition {
    if status == 304 {
        FeedResponseDisposition::NotModified
    } else if (300..400).contains(&status) {
        FeedResponseDisposition::Redirect
    } else {
        FeedResponseDisposition::Other
    }
}

pub(crate) fn identity_feed_content_length_exceeds(
    content_length: Option<&str>,
    content_encoding: Option<&str>,
    max_bytes: usize,
) -> bool {
    if content_encoding
        .map(str::trim)
        .is_some_and(|encoding| !encoding.eq_ignore_ascii_case("identity"))
    {
        return false;
    }

    let Some(value) = content_length else {
        return false;
    };

    value
        .trim()
        .parse::<u64>()
        .map(|length| length > max_bytes as u64)
        .unwrap_or(false)
}

pub(crate) fn append_limited_feed_body_chunk(
    buffer: &mut Vec<u8>,
    chunk: &[u8],
    max_bytes: usize,
) -> Result<(), FeedBodyAppendError> {
    let Some(next_len) = buffer.len().checked_add(chunk.len()) else {
        return Err(FeedBodyAppendError::Oversized);
    };
    if next_len > max_bytes {
        return Err(FeedBodyAppendError::Oversized);
    }

    // Shape growth only when a large existing allocation cannot fit the next
    // chunk, reserving the remaining bounded allowance in one fallible step.
    if next_len > buffer.capacity() && buffer.capacity() > max_bytes / 2 {
        let remaining_capacity = max_bytes.saturating_sub(buffer.len());
        if buffer.try_reserve_exact(remaining_capacity).is_err() {
            return Err(FeedBodyAppendError::AllocationFailed);
        }
    }

    buffer.extend_from_slice(chunk);
    Ok(())
}

pub(crate) fn same_origin(left: &url::Url, right: &url::Url) -> bool {
    left.scheme() == right.scheme()
        && left.host_str() == right.host_str()
        && left.port_or_known_default() == right.port_or_known_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fmt::Write;

    #[test]
    fn feed_user_agent_is_identifiable_without_an_embedded_url() {
        assert_eq!(FEED_USER_AGENT, "OpenCast-Notifications/1");
        assert!(!FEED_USER_AGENT.contains("://"));
    }

    #[test]
    fn classifies_304_as_not_modified_before_redirects() {
        assert_eq!(
            feed_response_disposition(304),
            FeedResponseDisposition::NotModified
        );
        assert_eq!(
            feed_response_disposition(301),
            FeedResponseDisposition::Redirect
        );
        assert_eq!(
            feed_response_disposition(302),
            FeedResponseDisposition::Redirect
        );
        assert_eq!(
            feed_response_disposition(200),
            FeedResponseDisposition::Other
        );
        assert_eq!(
            feed_response_disposition(404),
            FeedResponseDisposition::Other
        );
    }

    #[test]
    fn only_identity_content_length_can_reject_early() {
        assert!(!identity_feed_content_length_exceeds(None, None, 10));
        assert!(!identity_feed_content_length_exceeds(
            Some("not-a-number"),
            None,
            10
        ));
        assert!(!identity_feed_content_length_exceeds(Some("10"), None, 10));
        assert!(identity_feed_content_length_exceeds(Some("11"), None, 10));
        assert!(identity_feed_content_length_exceeds(
            Some("11"),
            Some("identity"),
            10
        ));
        assert!(!identity_feed_content_length_exceeds(
            Some("11"),
            Some("gzip"),
            10
        ));
        assert!(!identity_feed_content_length_exceeds(
            Some("11"),
            Some("br"),
            10
        ));
    }

    #[test]
    fn caps_unknown_length_bodies_while_accumulating_chunks() {
        let mut buffer = Vec::new();

        assert_eq!(
            append_limited_feed_body_chunk(&mut buffer, b"12345", 10),
            Ok(())
        );
        assert_eq!(
            append_limited_feed_body_chunk(&mut buffer, b"67890", 10),
            Ok(())
        );
        assert_eq!(buffer, b"1234567890");
        assert_eq!(
            append_limited_feed_body_chunk(&mut buffer, b"!", 10),
            Err(FeedBodyAppendError::Oversized)
        );
        assert_eq!(buffer, b"1234567890");
    }

    #[test]
    fn sufficient_large_capacity_is_not_reallocated() {
        let mut buffer = Vec::with_capacity(6);
        buffer.extend_from_slice(b"12345");
        let pointer = buffer.as_ptr();
        let capacity = buffer.capacity();

        assert_eq!(
            append_limited_feed_body_chunk(&mut buffer, b"6", 10),
            Ok(())
        );

        assert_eq!(buffer.as_ptr(), pointer);
        assert_eq!(buffer.capacity(), capacity);
        assert_eq!(buffer, b"123456");
    }

    #[test]
    fn large_buffer_reserves_bounded_allowance_when_next_chunk_would_outgrow_it() {
        let mut buffer = Vec::with_capacity(9);
        buffer.extend_from_slice(b"123456789");

        assert_eq!(
            append_limited_feed_body_chunk(&mut buffer, b"0", 16),
            Ok(())
        );

        assert!(buffer.capacity() >= 16);
        assert_eq!(buffer, b"1234567890");
    }

    #[test]
    fn oversized_rejection_preserves_buffer_allocation_and_contents() {
        let mut buffer = Vec::with_capacity(12);
        buffer.extend_from_slice(b"1234567890");
        let pointer = buffer.as_ptr();
        let capacity = buffer.capacity();

        assert_eq!(
            append_limited_feed_body_chunk(&mut buffer, b"!", 10),
            Err(FeedBodyAppendError::Oversized)
        );

        assert_eq!(buffer.as_ptr(), pointer);
        assert_eq!(buffer.capacity(), capacity);
        assert_eq!(buffer, b"1234567890");
    }

    #[test]
    fn default_body_cap_admits_measured_large_feeds() {
        assert!(!identity_feed_content_length_exceeds(
            Some("5276486"),
            None,
            MAX_FEED_BODY_BYTES
        ));
        assert!(!identity_feed_content_length_exceeds(
            Some("8814510"),
            None,
            MAX_FEED_BODY_BYTES
        ));
        assert!(identity_feed_content_length_exceeds(
            Some(&(MAX_FEED_BODY_BYTES + 1).to_string()),
            None,
            MAX_FEED_BODY_BYTES
        ));
    }

    #[test]
    fn bounded_cap_admits_synthetic_full_catalog_rss_above_legacy_limit() {
        const LEGACY_MAX_FEED_BODY_BYTES: usize = 8 * 1024 * 1024;
        const ITEM_COUNT: usize = 1_725;
        let notes = "x".repeat(2_700);
        let mut xml = String::with_capacity(10 * 1024 * 1024);
        xml.push_str(r#"<?xml version="1.0"?><rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><title>Synthetic Full Catalog</title>"#);
        for index in 0..ITEM_COUNT {
            write!(
                xml,
                "<item><title>Episode {index}</title><guid>episode-{index}</guid><pubDate>Sat, 01 Aug 2026 12:00:00 +0000</pubDate><description>{notes}</description><content:encoded><![CDATA[{notes}]]></content:encoded></item>"
            )
            .expect("writing to String should succeed");
        }
        xml.push_str("</channel></rss>");

        assert!(xml.len() > LEGACY_MAX_FEED_BODY_BYTES + 512 * 1024);
        assert!(xml.len() < MAX_FEED_BODY_BYTES);

        let mut streamed_body = Vec::new();
        for chunk in xml.as_bytes().chunks(64 * 1024) {
            assert_eq!(
                append_limited_feed_body_chunk(&mut streamed_body, chunk, MAX_FEED_BODY_BYTES),
                Ok(())
            );
        }
        let body = String::from_utf8(streamed_body).expect("fixture should be UTF-8");
        let parsed = crate::rss::parse_rss(&body, "https://example.com/full-catalog.xml")
            .expect("fixture should remain valid RSS after bounded accumulation");

        assert_eq!(parsed.title, "Synthetic Full Catalog");
        assert_eq!(parsed.episodes.len(), ITEM_COUNT);
    }

    #[test]
    fn only_oversized_fetches_are_persistent_compatibility_failures() {
        assert!(FeedFetchError::OversizedBody.is_persistent_compatibility());
        for error in [
            FeedFetchError::InvalidRedirect,
            FeedFetchError::TooManyRedirects,
            FeedFetchError::FetchFailed,
            FeedFetchError::MissingRedirectLocation,
            FeedFetchError::HTTPStatus(503),
            FeedFetchError::InvalidBodyEncoding,
        ] {
            assert!(!error.is_persistent_compatibility(), "{error:?}");
        }
    }

    #[test]
    fn compares_redirect_origins_by_scheme_host_and_default_port() {
        let original = url::Url::parse("https://example.com/feed.xml").unwrap();
        let same_default_port = url::Url::parse("https://example.com:443/other.xml").unwrap();
        let different_scheme = url::Url::parse("http://example.com/feed.xml").unwrap();
        let different_host = url::Url::parse("https://other.example/feed.xml").unwrap();
        let different_port = url::Url::parse("https://example.com:444/feed.xml").unwrap();

        assert!(same_origin(&original, &same_default_port));
        assert!(!same_origin(&original, &different_scheme));
        assert!(!same_origin(&original, &different_host));
        assert!(!same_origin(&original, &different_port));
    }
}
