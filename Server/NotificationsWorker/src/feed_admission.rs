use crate::feed_identity::{canonical_string_for_url, CanonicalURLFailure};
use std::net::IpAddr;
use std::str::FromStr;
use url::Url;

const MAX_FEED_URL_LENGTH: usize = 2048;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AdmittedFeedURL {
    pub canonical_url: String,
    pub source_url: String,
    pub host: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FeedURLAdmissionError {
    EmptyURL,
    URLTooLong,
    InvalidURL,
    UnsupportedScheme,
    MissingHost,
    CredentialsNotAllowed,
    FragmentNotAllowed,
    UnsupportedPort,
    BlockedHost,
}

impl FeedURLAdmissionError {
    pub fn code(&self) -> &'static str {
        match self {
            FeedURLAdmissionError::EmptyURL => "empty_url",
            FeedURLAdmissionError::URLTooLong => "url_too_long",
            FeedURLAdmissionError::InvalidURL => "invalid_url",
            FeedURLAdmissionError::UnsupportedScheme => "unsupported_scheme",
            FeedURLAdmissionError::MissingHost => "missing_host",
            FeedURLAdmissionError::CredentialsNotAllowed => "credentials_not_allowed",
            FeedURLAdmissionError::FragmentNotAllowed => "fragment_not_allowed",
            FeedURLAdmissionError::UnsupportedPort => "unsupported_port",
            FeedURLAdmissionError::BlockedHost => "blocked_host",
        }
    }
}

impl From<CanonicalURLFailure> for FeedURLAdmissionError {
    fn from(error: CanonicalURLFailure) -> Self {
        match error {
            CanonicalURLFailure::InvalidURL => FeedURLAdmissionError::InvalidURL,
            CanonicalURLFailure::MissingHost => FeedURLAdmissionError::MissingHost,
        }
    }
}

pub fn admit_feed_url(raw: &str) -> Result<AdmittedFeedURL, FeedURLAdmissionError> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(FeedURLAdmissionError::EmptyURL);
    }
    if trimmed.len() > MAX_FEED_URL_LENGTH {
        return Err(FeedURLAdmissionError::URLTooLong);
    }

    let url = Url::parse(trimmed).map_err(|_| FeedURLAdmissionError::InvalidURL)?;
    if !matches!(url.scheme(), "http" | "https") {
        return Err(FeedURLAdmissionError::UnsupportedScheme);
    }
    if !url.username().is_empty() || url.password().is_some() {
        return Err(FeedURLAdmissionError::CredentialsNotAllowed);
    }
    if url.fragment().is_some() {
        return Err(FeedURLAdmissionError::FragmentNotAllowed);
    }
    if !matches!(url.port(), None | Some(80 | 443)) {
        return Err(FeedURLAdmissionError::UnsupportedPort);
    }

    let Some(host) = url.host_str().map(|value| value.to_ascii_lowercase()) else {
        return Err(FeedURLAdmissionError::MissingHost);
    };
    if is_blocked_host(&host) {
        return Err(FeedURLAdmissionError::BlockedHost);
    }

    Ok(AdmittedFeedURL {
        canonical_url: canonical_string_for_url(&url)?,
        source_url: trimmed.to_string(),
        host,
    })
}

fn is_blocked_host(host: &str) -> bool {
    let ip_host = host
        .strip_prefix('[')
        .and_then(|value| value.strip_suffix(']'))
        .unwrap_or(host);

    host.is_empty()
        || host == "localhost"
        || host.ends_with(".localhost")
        || host.ends_with(".local")
        || host.split('.').any(str::is_empty)
        || host.starts_with("localhost.")
        || IpAddr::from_str(ip_host).is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_public_http_and_https_feed_urls() {
        let admitted =
            admit_feed_url(" HTTPS://Example.com/feed.xml/?b=2&a=1 ").expect("url should admit");

        assert_eq!(admitted.host, "example.com");
        assert_eq!(admitted.source_url, "HTTPS://Example.com/feed.xml/?b=2&a=1");
        assert_eq!(
            admitted.canonical_url,
            "https://example.com/feed.xml?a=1&b=2"
        );
    }

    #[test]
    fn rejects_hostile_feed_urls() {
        let cases = [
            ("ftp://example.com/feed.xml", "unsupported_scheme"),
            (
                "https://user:pass@example.com/feed.xml",
                "credentials_not_allowed",
            ),
            (
                "https://example.com/feed.xml#fragment",
                "fragment_not_allowed",
            ),
            ("https://example.com:8443/feed.xml", "unsupported_port"),
            ("https://127.0.0.1/feed.xml", "blocked_host"),
            ("https://[::1]/feed.xml", "blocked_host"),
            ("https://localhost/feed.xml", "blocked_host"),
            ("https://printer.local/feed.xml", "blocked_host"),
            ("https://example..com/feed.xml", "blocked_host"),
        ];

        for (url, code) in cases {
            assert_eq!(
                admit_feed_url(url).expect_err("url should reject").code(),
                code
            );
        }
    }
}
