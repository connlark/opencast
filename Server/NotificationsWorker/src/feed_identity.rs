use sha2::{Digest, Sha256};
use std::borrow::Cow;
use url::Url;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CanonicalURLFailure {
    InvalidURL,
    MissingHost,
}

impl CanonicalURLFailure {
    pub fn code(&self) -> &'static str {
        match self {
            CanonicalURLFailure::InvalidURL => "invalid_url",
            CanonicalURLFailure::MissingHost => "missing_host",
        }
    }
}

pub fn canonical_string_for_raw_url(raw: &str) -> Result<String, CanonicalURLFailure> {
    let trimmed = raw.trim();
    let url = Url::parse(trimmed).map_err(|_| CanonicalURLFailure::InvalidURL)?;
    canonical_string_for_url(&url)
}

pub fn canonical_string_for_url(url: &Url) -> Result<String, CanonicalURLFailure> {
    let Some(host) = url.host_str() else {
        return Err(CanonicalURLFailure::MissingHost);
    };

    let scheme = url.scheme().to_ascii_lowercase();
    let host = host.to_ascii_lowercase();
    let mut result = format!("{scheme}://{host}");

    if let Some(port) = url.port() {
        result.push(':');
        result.push_str(&port.to_string());
    }

    let path = canonical_path(url.path());
    result.push_str(&path);

    if let Some(query) = canonical_query(url) {
        result.push('?');
        result.push_str(&query);
    }

    Ok(result)
}

pub fn episode_id(
    canonical_feed_url: &str,
    guid: Option<&str>,
    audio_url: Option<&str>,
    title: &str,
    published_at: Option<i64>,
) -> String {
    let identity_material = if let Some(guid) = trimmed_non_empty(guid) {
        format!("guid:{guid}")
    } else if let Some(audio_url) = audio_url.and_then(|url| canonical_string_for_raw_url(url).ok())
    {
        format!("audio:{audio_url}")
    } else {
        let timestamp = published_at
            .map(|value| value.to_string())
            .unwrap_or_else(|| "unknown-date".to_string());
        format!(
            "title-date:{}|{timestamp}",
            normalized_title_for_episode_identity(title)
        )
    };

    sha256_hex(format!("{canonical_feed_url}|{identity_material}").as_bytes())
}

pub fn normalized_title_for_episode_identity(title: &str) -> String {
    title
        .trim()
        .to_ascii_lowercase()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

#[derive(Debug, Clone, Copy)]
pub struct EpisodeNotificationFingerprintInput<'a> {
    pub title: &'a str,
    pub guid: Option<&'a str>,
    pub audio_url: Option<&'a str>,
    pub duration_seconds: Option<i64>,
    pub summary: Option<&'a str>,
    pub show_notes_html: Option<&'a str>,
    pub episode_id: &'a str,
}

pub fn episode_notification_fingerprint(
    input: EpisodeNotificationFingerprintInput<'_>,
) -> Option<String> {
    let title = normalized_title_for_episode_identity(input.title);
    let mut material = Vec::new();

    if let Some(audio_url) = input
        .audio_url
        .and_then(|url| canonical_string_for_raw_url(url).ok())
    {
        material.push(format!("audio:{audio_url}"));
    }

    if let Some(summary_digest) = notification_text_digest(input.summary, input.show_notes_html) {
        material.push(format!("summary:{summary_digest}"));
    }

    if let Some(duration) = input.duration_seconds.filter(|duration| *duration > 0) {
        material.push(format!("duration:{duration}"));
    }

    if material.is_empty() {
        if let Some(guid) = trimmed_non_empty(input.guid) {
            material.push(format!("guid:{}", normalized_text_for_fingerprint(guid)));
        }
    }

    if material.is_empty() {
        if title == "untitled episode" {
            return None;
        }
        material.push(format!("episode-id:{}", input.episode_id));
    }

    Some(sha256_hex(
        format!(
            "notification-episode-v2|title:{title}|{}",
            material.join("|")
        )
        .as_bytes(),
    ))
}

fn canonical_path(path: &str) -> String {
    if path == "/" {
        return String::new();
    }

    let mut value = path.to_string();
    while value.len() > 1 && value.ends_with('/') {
        value.pop();
    }
    value
}

fn canonical_query(url: &Url) -> Option<String> {
    url.query()?;

    let mut pairs: Vec<(Cow<'_, str>, Cow<'_, str>)> = url.query_pairs().collect();
    pairs.sort_by(|lhs, rhs| lhs.0.cmp(&rhs.0).then_with(|| lhs.1.cmp(&rhs.1)));

    let mut serializer = url::form_urlencoded::Serializer::new(String::new());
    for (name, value) in pairs {
        serializer.append_pair(&name, &value);
    }

    Some(serializer.finish())
}

fn trimmed_non_empty(value: Option<&str>) -> Option<&str> {
    let trimmed = value?.trim();
    (!trimmed.is_empty()).then_some(trimmed)
}

fn notification_text_digest(
    summary: Option<&str>,
    show_notes_html: Option<&str>,
) -> Option<String> {
    [summary, show_notes_html]
        .into_iter()
        .flatten()
        .map(normalized_plain_text_for_fingerprint)
        .find(|candidate| !candidate.is_empty())
        .map(|candidate| sha256_hex(candidate.as_bytes()))
}

fn normalized_plain_text_for_fingerprint(value: &str) -> String {
    normalized_text_for_fingerprint(&strip_html_tags(value))
}

fn normalized_text_for_fingerprint(value: &str) -> String {
    value
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_ascii_lowercase()
}

fn strip_html_tags(value: &str) -> String {
    let mut output = String::with_capacity(value.len());
    let mut in_tag = false;
    for character in value.chars() {
        match character {
            '<' => {
                in_tag = true;
                output.push(' ');
            }
            '>' => {
                in_tag = false;
                output.push(' ');
            }
            _ if !in_tag => output.push(character),
            _ => {}
        }
    }
    output
}

fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canonicalizes_feed_urls_like_opencast_core() {
        assert_eq!(
            canonical_string_for_raw_url(
                " HTTPS://Jumble.Top/f/americanprestige.xml/?b=2&a=1#fragment "
            )
            .expect("url should canonicalize"),
            "https://jumble.top/f/americanprestige.xml?a=1&b=2"
        );
        assert_eq!(
            canonical_string_for_raw_url("https://example.com/").expect("url should canonicalize"),
            "https://example.com"
        );
    }

    #[test]
    fn episode_id_prefers_guid() {
        assert_eq!(
            episode_id(
                "https://jumble.top/f/americanprestige.xml",
                Some(" ap-guid-001 "),
                Some("https://example.com/audio/changed.mp3"),
                "Changed",
                Some(1)
            ),
            "c8d85b9356e7615440a52ad65ea7f46609f425b59a15fdd7f6c8ad64177aa8f6"
        );
    }

    #[test]
    fn episode_id_falls_back_to_audio_url() {
        assert_eq!(
            episode_id(
                "https://jumble.top/f/americanprestige.xml",
                None,
                Some("HTTPS://Example.com/audio/ap-002.mp3?b=2&a=1#ignored"),
                "Retitled",
                Some(1)
            ),
            "8924c7df2a746eb7199d3bcc6f8321992637fac914467c7dce5fa30070a3cb1d"
        );
    }

    #[test]
    fn episode_id_falls_back_to_title_date() {
        assert_eq!(
            episode_id(
                "https://example.com/fallbacks.xml",
                Some("   "),
                None,
                "  Title   Date\nStable  ",
                Some(1_704_067_200)
            ),
            "581d246fae54c27583f468bd40413abd5bcbca84e441f077a57a31bca8e88a35"
        );
    }

    #[test]
    fn episode_id_uses_unknown_date_when_needed() {
        assert_eq!(
            episode_id(
                "https://example.com/fallbacks.xml",
                None,
                None,
                "Missing Date",
                None
            ),
            "20ffb3cc83e5fce7baf4024060ea0a7c09fe6a484c6935453769bdc769e98ea3"
        );
    }

    #[test]
    fn notification_fingerprint_dedupes_guid_churn_when_episode_material_is_stable() {
        let first = episode_notification_fingerprint(EpisodeNotificationFingerprintInput {
            title: "487 - Pride Loveline",
            guid: Some("old-guid"),
            audio_url: Some("HTTPS://Example.com/audio/episode.mp3?b=2&a=1"),
            duration_seconds: Some(2_640),
            summary: Some("<p>Summary &amp; context.</p>"),
            show_notes_html: None,
            episode_id: "old-id",
        })
        .expect("strong material should fingerprint");
        let second = episode_notification_fingerprint(EpisodeNotificationFingerprintInput {
            title: " 487   - Pride Loveline ",
            guid: Some("new-guid"),
            audio_url: Some("https://example.com/audio/episode.mp3?a=1&b=2"),
            duration_seconds: Some(2_640),
            summary: Some("Summary &amp; context."),
            show_notes_html: None,
            episode_id: "new-id",
        })
        .expect("strong material should fingerprint");

        assert_eq!(first, second);
        assert_eq!(first.len(), 64);
    }

    #[test]
    fn notification_fingerprint_distinguishes_same_title_episode_material() {
        let base = EpisodeNotificationFingerprintInput {
            title: "News Roundup",
            guid: Some("guid-a"),
            audio_url: Some("https://example.com/audio/a.mp3"),
            duration_seconds: Some(600),
            summary: Some("First story"),
            show_notes_html: None,
            episode_id: "episode-a",
        };
        let different_audio = EpisodeNotificationFingerprintInput {
            audio_url: Some("https://example.com/audio/b.mp3"),
            ..base
        };
        let different_summary = EpisodeNotificationFingerprintInput {
            audio_url: base.audio_url,
            summary: Some("Second story"),
            ..base
        };
        let different_duration = EpisodeNotificationFingerprintInput {
            audio_url: None,
            summary: None,
            duration_seconds: Some(601),
            ..base
        };
        let duration_only_base = EpisodeNotificationFingerprintInput {
            audio_url: None,
            summary: None,
            duration_seconds: Some(600),
            ..base
        };

        assert_ne!(
            episode_notification_fingerprint(base),
            episode_notification_fingerprint(different_audio)
        );
        assert_ne!(
            episode_notification_fingerprint(base),
            episode_notification_fingerprint(different_summary)
        );
        assert_ne!(
            episode_notification_fingerprint(duration_only_base),
            episode_notification_fingerprint(different_duration)
        );
    }

    #[test]
    fn notification_fingerprint_does_not_broaden_untitled_fallbacks() {
        assert_eq!(
            episode_notification_fingerprint(EpisodeNotificationFingerprintInput {
                title: "Untitled Episode",
                guid: None,
                audio_url: None,
                duration_seconds: None,
                summary: None,
                show_notes_html: None,
                episode_id: "title-only-id",
            }),
            None
        );
    }
}
