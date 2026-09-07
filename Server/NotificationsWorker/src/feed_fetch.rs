// CBC's Akamai edge resets connections for URL-bearing User-Agent values.
// Keep the product identity URL-free for both admission and polling.
pub(crate) const FEED_USER_AGENT: &str = "OpenCast-Notifications/1";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum FeedFetchError {
    InvalidRedirect,
    TooManyRedirects,
    FetchFailed,
    MissingRedirectLocation,
    HTTPStatus(u16),
    UnexpectedNotModified,
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
            FeedFetchError::UnexpectedNotModified => "unexpected_not_modified",
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
        false
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
    fn current_fetch_failures_use_transient_retry_policy() {
        for error in [
            FeedFetchError::InvalidRedirect,
            FeedFetchError::TooManyRedirects,
            FeedFetchError::FetchFailed,
            FeedFetchError::MissingRedirectLocation,
            FeedFetchError::HTTPStatus(503),
            FeedFetchError::UnexpectedNotModified,
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
