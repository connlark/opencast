//! Origin URL policy (B5, pure part). The Workers runtime is the enforcement
//! floor for address-level SSRF (Cloudflare-owned and private space are
//! unreachable from the edge); these checks reject everything the policy can
//! decide from the URL itself, before any fetch. Redirects re-run the same
//! validation.

use url::{Host, Url};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OriginUrlError {
    Invalid,
    NotHttps,
    HasUserinfo,
    IpLiteralHost,
    UnusualPort,
    ForbiddenHost,
}

impl OriginUrlError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::Invalid => "origin_url_invalid",
            Self::NotHttps => "origin_url_not_https",
            Self::HasUserinfo => "origin_url_userinfo",
            Self::IpLiteralHost => "origin_url_ip_literal",
            Self::UnusualPort => "origin_url_port",
            Self::ForbiddenHost => "origin_url_forbidden_host",
        }
    }
}

pub fn validate_origin_url(raw: &str) -> Result<Url, OriginUrlError> {
    if raw.len() > 4096 {
        return Err(OriginUrlError::Invalid);
    }
    let url = Url::parse(raw).map_err(|_| OriginUrlError::Invalid)?;
    if url.scheme() != "https" {
        return Err(OriginUrlError::NotHttps);
    }
    if !url.username().is_empty() || url.password().is_some() {
        return Err(OriginUrlError::HasUserinfo);
    }
    match url.host() {
        Some(Host::Domain(domain)) => {
            let lowered = domain.to_ascii_lowercase();
            let lowered = lowered.trim_end_matches('.');
            if lowered == "localhost"
                || lowered.ends_with(".localhost")
                || lowered.ends_with(".local")
                || lowered.ends_with(".internal")
                || lowered.ends_with(".home.arpa")
                || !lowered.contains('.')
            {
                return Err(OriginUrlError::ForbiddenHost);
            }
        }
        Some(Host::Ipv4(_)) | Some(Host::Ipv6(_)) => return Err(OriginUrlError::IpLiteralHost),
        None => return Err(OriginUrlError::Invalid),
    }
    if let Some(port) = url.port() {
        if port != 443 {
            return Err(OriginUrlError::UnusualPort);
        }
    }
    Ok(url)
}

/// Shared media request profile: exact bytes, no content negotiation, a
/// stable URL-free UA the device downloader mirrors (C1). The app declares
/// the profile it downloads with on create (`media_profile`).
pub const MEDIA_ACCEPT_ENCODING: &str = "identity";
pub const MEDIA_PROFILE: u32 = 2;
pub const MEDIA_USER_AGENT: &str = "OpenCast-Media/2";
/// Profile 1: what app versions that predate the `media_profile` declaration
/// download with. Kept only so their jobs' origin fetch still mirrors the
/// device; delete once `jobs_created_legacy_media_profile` stops growing.
pub const LEGACY_MEDIA_USER_AGENT: &str = "OpenCast-Media/1 (+https://opencast.mobile)";

/// Whether a job's app predates profile 2 (no declaration, or profile 1).
pub fn uses_legacy_media_profile(declared_profile: Option<u32>) -> bool {
    matches!(declared_profile, None | Some(0 | 1))
}

/// The origin-fetch UA for a job: the one its app downloads with. A profile
/// newer than this Worker knows falls back to the current one; the hash
/// comparison still decides whether the copies match.
pub fn media_user_agent(declared_profile: Option<u32>) -> &'static str {
    if uses_legacy_media_profile(declared_profile) {
        LEGACY_MEDIA_USER_AGENT
    } else {
        MEDIA_USER_AGENT
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_normal_public_enclosures() {
        for url in [
            "https://example.com/audio.mp3",
            "https://cdn.example.co.uk/a/b/c.mp3?token=abc",
            "https://example.com:443/audio.mp3",
        ] {
            assert!(validate_origin_url(url).is_ok(), "{url}");
        }
    }

    #[test]
    fn rejects_policy_violations() {
        let cases = [
            ("http://example.com/a.mp3", OriginUrlError::NotHttps),
            ("ftp://example.com/a.mp3", OriginUrlError::NotHttps),
            (
                "https://user:pw@example.com/a.mp3",
                OriginUrlError::HasUserinfo,
            ),
            (
                "https://user@example.com/a.mp3",
                OriginUrlError::HasUserinfo,
            ),
            ("https://192.168.1.10/a.mp3", OriginUrlError::IpLiteralHost),
            ("https://[::1]/a.mp3", OriginUrlError::IpLiteralHost),
            (
                "https://example.com:8443/a.mp3",
                OriginUrlError::UnusualPort,
            ),
            ("https://localhost/a.mp3", OriginUrlError::ForbiddenHost),
            ("https://printer.local/a.mp3", OriginUrlError::ForbiddenHost),
            ("https://intranet/a.mp3", OriginUrlError::ForbiddenHost),
            ("https://db.internal/a.mp3", OriginUrlError::ForbiddenHost),
            ("not a url", OriginUrlError::Invalid),
        ];
        for (url, expected) in cases {
            assert_eq!(validate_origin_url(url), Err(expected), "{url}");
        }
    }

    #[test]
    fn media_request_profile_is_pinned_and_url_free() {
        // Byte-identical to the device downloader's profile so both fetch
        // the same origin representation; the hash still decides a match.
        assert_eq!(MEDIA_PROFILE, 2);
        assert_eq!(MEDIA_USER_AGENT, "OpenCast-Media/2");
        assert_eq!(MEDIA_USER_AGENT, format!("OpenCast-Media/{MEDIA_PROFILE}"));
        assert!(!MEDIA_USER_AGENT.contains("://"));
        assert_eq!(MEDIA_ACCEPT_ENCODING, "identity");
    }

    #[test]
    fn origin_fetch_mirrors_the_declared_media_profile() {
        assert_eq!(
            LEGACY_MEDIA_USER_AGENT,
            "OpenCast-Media/1 (+https://opencast.mobile)"
        );
        // Apps that predate the declaration keep the profile they download with.
        assert_eq!(media_user_agent(None), LEGACY_MEDIA_USER_AGENT);
        assert_eq!(media_user_agent(Some(0)), LEGACY_MEDIA_USER_AGENT);
        assert_eq!(media_user_agent(Some(1)), LEGACY_MEDIA_USER_AGENT);
        assert_eq!(media_user_agent(Some(MEDIA_PROFILE)), MEDIA_USER_AGENT);
        // A newer app against an older Worker falls back to the current profile.
        assert_eq!(media_user_agent(Some(MEDIA_PROFILE + 1)), MEDIA_USER_AGENT);
        assert!(uses_legacy_media_profile(None));
        assert!(!uses_legacy_media_profile(Some(MEDIA_PROFILE)));
    }
}
