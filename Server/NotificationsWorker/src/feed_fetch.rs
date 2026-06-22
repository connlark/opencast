pub(crate) const MAX_FEED_BODY_BYTES: usize = 8 * 1024 * 1024;

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

pub(crate) fn feed_content_length_exceeds(value: Option<&str>, max_bytes: usize) -> bool {
    let Some(value) = value else {
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
) -> bool {
    let Some(next_len) = buffer.len().checked_add(chunk.len()) else {
        return false;
    };
    if next_len > max_bytes {
        return false;
    }

    buffer.extend_from_slice(chunk);
    true
}

pub(crate) fn same_origin(left: &url::Url, right: &url::Url) -> bool {
    left.scheme() == right.scheme()
        && left.host_str() == right.host_str()
        && left.port_or_known_default() == right.port_or_known_default()
}

#[cfg(test)]
mod tests {
    use super::*;

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
    fn checks_parseable_content_length_against_cap() {
        assert!(!feed_content_length_exceeds(None, 10));
        assert!(!feed_content_length_exceeds(Some("not-a-number"), 10));
        assert!(!feed_content_length_exceeds(Some("10"), 10));
        assert!(feed_content_length_exceeds(Some("11"), 10));
    }

    #[test]
    fn caps_unknown_length_bodies_while_accumulating_chunks() {
        let mut buffer = Vec::new();

        assert!(append_limited_feed_body_chunk(&mut buffer, b"12345", 10));
        assert!(append_limited_feed_body_chunk(&mut buffer, b"67890", 10));
        assert_eq!(buffer, b"1234567890");
        assert!(!append_limited_feed_body_chunk(&mut buffer, b"!", 10));
        assert_eq!(buffer, b"1234567890");
    }

    #[test]
    fn default_body_cap_admits_joe_rogan_experience_feed() {
        assert!(!feed_content_length_exceeds(
            Some("5276486"),
            MAX_FEED_BODY_BYTES
        ));
        assert!(feed_content_length_exceeds(
            Some(&(MAX_FEED_BODY_BYTES + 1).to_string()),
            MAX_FEED_BODY_BYTES
        ));
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
