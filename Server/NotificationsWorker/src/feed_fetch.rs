// CBC's Akamai edge resets connections for URL-bearing User-Agent values.
// Keep the product identity URL-free for both admission and polling.
pub(crate) const FEED_USER_AGENT: &str = "OpenCast-Notifications/1";

#[cfg(target_arch = "wasm32")]
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum FeedFetchError {
    InvalidRedirect,
    TooManyRedirects,
    FetchFailed,
    MissingRedirectLocation,
    HTTPStatus(u16),
    UnexpectedNotModified,
    OriginDeferred,
    StorageFailed,
}

#[cfg(target_arch = "wasm32")]
impl FeedFetchError {
    pub(crate) fn code(&self) -> &'static str {
        match self {
            FeedFetchError::InvalidRedirect => "invalid_redirect",
            FeedFetchError::TooManyRedirects => "too_many_redirects",
            FeedFetchError::FetchFailed => "fetch_failed",
            FeedFetchError::MissingRedirectLocation => "missing_redirect_location",
            FeedFetchError::HTTPStatus(_) => "http_error",
            FeedFetchError::UnexpectedNotModified => "unexpected_not_modified",
            FeedFetchError::OriginDeferred => "origin_deferred",
            FeedFetchError::StorageFailed => "storage_failed",
        }
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

pub(crate) fn same_origin(left: &url::Url, right: &url::Url) -> bool {
    left.scheme() == right.scheme()
        && left.host_str() == right.host_str()
        && left.port_or_known_default() == right.port_or_known_default()
}

/// How a poll proved the published snapshot still current without a body.
#[cfg(target_arch = "wasm32")]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum NotModifiedProof {
    /// The publisher answered 304 to the stored validators.
    Status,
    /// A 200 repeated the stored strong ETag for the same resource.
    StrongETag,
}

/// How long a strong-ETag match stands in for the body after the parse that
/// stored it. Every always-200 feed is parsed at least once a day.
pub(crate) const VALIDATOR_TRUST_SECONDS: i64 = 86_400;

/// The whole header value as one strong entity-tag (RFC 9110 §8.8.3):
/// `DQUOTE *etagc DQUOTE`, `etagc = %x21 / %x23-7E / obs-text`. A weak tag,
/// a list, surrounding whitespace, a control byte or an unquoted value is
/// `None`. The tag keeps its quotes; equality is on the whole value.
pub(crate) fn strong_entity_tag(value: &str) -> Option<&str> {
    let tag = value.strip_prefix('"')?.strip_suffix('"')?;
    tag.bytes()
        .all(|b| b == 0x21 || (0x23..=0x7e).contains(&b) || b >= 0x80)
        .then_some(value)
}

/// The validators the authority row holds for its published snapshot: the
/// URL of the hop whose parsed 200 supplied them and when that was settled.
pub(crate) struct StoredValidators<'a> {
    pub(crate) etag: Option<&'a str>,
    pub(crate) last_modified: Option<&'a str>,
    pub(crate) url: Option<&'a str>,
    pub(crate) at: Option<i64>,
}

/// A 200 from `url` repeats the stored validators of that same resource:
/// both ETags are strong and byte-equal, a stored Last-Modified is repeated
/// exactly, and the stored ones came from a parse within the trust window.
/// Validators are scoped to one resource, so a redirect to another URL parses.
pub(crate) fn strong_etag_unchanged(
    stored: &StoredValidators,
    response_etag: Option<&str>,
    response_last_modified: Option<&str>,
    url: &str,
    now: i64,
) -> bool {
    let (Some(stored_tag), Some(response_tag)) = (
        stored.etag.and_then(strong_entity_tag),
        response_etag.and_then(strong_entity_tag),
    ) else {
        return false;
    };
    stored_tag == response_tag
        && stored
            .last_modified
            .is_none_or(|stored| response_last_modified == Some(stored))
        && stored.url == Some(url)
        && stored
            .at
            .is_some_and(|at| now - at <= VALIDATOR_TRUST_SECONDS)
}

#[cfg(test)]
mod tests {
    use super::*;

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

    #[test]
    fn accepts_only_one_strong_entity_tag_as_the_whole_value() {
        assert_eq!(strong_entity_tag("\"x\""), Some("\"x\""));
        // An empty strong tag is grammatical: DQUOTE *etagc DQUOTE.
        assert_eq!(strong_entity_tag("\"\""), Some("\"\""));
        // obs-text (%x80-FF) arrives as Latin-1 code points, all non-ASCII.
        assert_eq!(
            strong_entity_tag("\"v\u{80}\u{ff}1\""),
            Some("\"v\u{80}\u{ff}1\"")
        );
        assert_eq!(strong_entity_tag("\"!#~\""), Some("\"!#~\""));
        for rejected in [
            "W/\"x\"",
            "w/\"x\"",
            "x",
            "\"",
            "",
            "\"a\", \"b\"",
            "\"a\",\"b\"",
            "\"a b\"",
            "\"a\u{7f}\"",
            "\"a\tb\"",
            "\"a\u{0}\"",
            " \"x\"",
            "\"x\" ",
            "\"x",
            "x\"",
            "*",
        ] {
            assert_eq!(strong_entity_tag(rejected), None, "{rejected:?}");
        }
    }

    const URL: &str = "https://example.com/feed.xml";
    const NOW: i64 = 1_800_000_000;

    fn stored<'a>(etag: Option<&'a str>, last_modified: Option<&'a str>) -> StoredValidators<'a> {
        StoredValidators {
            etag,
            last_modified,
            url: Some(URL),
            at: Some(NOW - 60),
        }
    }

    #[test]
    fn strong_etag_shortcut_requires_equal_strong_tags() {
        let v1 = stored(Some("\"v1\""), None);
        assert!(strong_etag_unchanged(&v1, Some("\"v1\""), None, URL, NOW));
        assert!(!strong_etag_unchanged(&v1, Some("\"v2\""), None, URL, NOW));
        // Byte equality on the whole tag, not a case-insensitive compare.
        assert!(!strong_etag_unchanged(&v1, Some("\"V1\""), None, URL, NOW));
        // Weak on either side, or both.
        assert!(!strong_etag_unchanged(
            &v1,
            Some("W/\"v1\""),
            None,
            URL,
            NOW
        ));
        let weak = stored(Some("W/\"v1\""), None);
        assert!(!strong_etag_unchanged(
            &weak,
            Some("\"v1\""),
            None,
            URL,
            NOW
        ));
        assert!(!strong_etag_unchanged(
            &weak,
            Some("W/\"v1\""),
            None,
            URL,
            NOW
        ));
        // Missing on either side, or both.
        assert!(!strong_etag_unchanged(&v1, None, None, URL, NOW));
        let none = stored(None, None);
        assert!(!strong_etag_unchanged(
            &none,
            Some("\"v1\""),
            None,
            URL,
            NOW
        ));
        assert!(!strong_etag_unchanged(&none, None, None, URL, NOW));
        // Unquoted or listed tags are never strong, even when equal.
        let unquoted = stored(Some("v1"), None);
        assert!(!strong_etag_unchanged(
            &unquoted,
            Some("v1"),
            None,
            URL,
            NOW
        ));
        let list = stored(Some("\"a\", \"b\""), None);
        assert!(!strong_etag_unchanged(
            &list,
            Some("\"a\", \"b\""),
            None,
            URL,
            NOW
        ));
    }

    #[test]
    fn strong_etag_shortcut_requires_a_stored_last_modified_to_repeat() {
        let modified = "Wed, 07 Oct 2026 12:00:00 GMT";
        let other = "Thu, 08 Oct 2026 12:00:00 GMT";
        let with = stored(Some("\"v1\""), Some(modified));
        let without = stored(Some("\"v1\""), None);
        assert!(strong_etag_unchanged(
            &with,
            Some("\"v1\""),
            Some(modified),
            URL,
            NOW
        ));
        assert!(!strong_etag_unchanged(
            &with,
            Some("\"v1\""),
            Some(other),
            URL,
            NOW
        ));
        // Absent on both sides.
        assert!(strong_etag_unchanged(
            &without,
            Some("\"v1\""),
            None,
            URL,
            NOW
        ));
        // Present only on the stored side: the response dropped it.
        assert!(!strong_etag_unchanged(
            &with,
            Some("\"v1\""),
            None,
            URL,
            NOW
        ));
        // Present only on the response side: nothing stored to contradict.
        assert!(strong_etag_unchanged(
            &without,
            Some("\"v1\""),
            Some(modified),
            URL,
            NOW
        ));
    }

    #[test]
    fn strong_etag_shortcut_is_bound_to_the_exact_resource_url() {
        let mut validators = stored(Some("\"v1\""), None);
        assert!(strong_etag_unchanged(
            &validators,
            Some("\"v1\""),
            None,
            URL,
            NOW
        ));
        // Same origin, different path: another resource.
        assert!(!strong_etag_unchanged(
            &validators,
            Some("\"v1\""),
            None,
            "https://example.com/other.xml",
            NOW
        ));
        assert!(!strong_etag_unchanged(
            &validators,
            Some("\"v1\""),
            None,
            "https://example.com/feed.xml?page=2",
            NOW
        ));
        // Validators stored before the URL was recorded never match.
        validators.url = None;
        assert!(!strong_etag_unchanged(
            &validators,
            Some("\"v1\""),
            None,
            URL,
            NOW
        ));
    }

    #[test]
    fn strong_etag_shortcut_trusts_the_last_parse_for_one_day() {
        let at = |at: Option<i64>| StoredValidators {
            at,
            ..stored(Some("\"v1\""), None)
        };
        let unchanged = |validators: &StoredValidators| {
            strong_etag_unchanged(validators, Some("\"v1\""), None, URL, NOW)
        };
        assert!(unchanged(&at(Some(NOW))));
        assert!(unchanged(&at(Some(NOW - 86_399))));
        assert!(unchanged(&at(Some(NOW - 86_400))));
        assert!(!unchanged(&at(Some(NOW - 86_401))));
        assert!(!unchanged(&at(None)));
    }
}
