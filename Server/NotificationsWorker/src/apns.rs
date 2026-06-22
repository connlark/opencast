use serde::Serialize;
use sha2::{Digest, Sha256};

pub const DEVELOPMENT_ENVIRONMENT: &str = "development";
pub const PRODUCTION_ENVIRONMENT: &str = "production";

const SANDBOX_BASE_URL: &str = "https://api.sandbox.push.apple.com";
const PRODUCTION_BASE_URL: &str = "https://api.push.apple.com";
const MIN_TOKEN_HEX_LENGTH: usize = 32;
const MAX_TOKEN_HEX_LENGTH: usize = 512;
const MAX_APNS_PAYLOAD_BYTES: usize = 3_800;
const MAX_SUMMARY_SOURCE_BYTES: usize = 16 * 1024;
const MAX_ALERT_BODY_BYTES: usize = 520;
const MAX_CUSTOM_SUMMARY_BYTES: usize = 700;
const MAX_CUSTOM_VALUE_BYTES: usize = 512;
const MAX_NOTIFICATION_DURATION_SECONDS: i64 = 24 * 60 * 60;
const EPISODE_NOTIFICATION_CATEGORY: &str = "OPENCAST_EPISODE";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApnsEnvironment {
    Development,
    Production,
}

impl ApnsEnvironment {
    pub fn parse(environment: &str) -> Option<Self> {
        match environment {
            DEVELOPMENT_ENVIRONMENT => Some(Self::Development),
            PRODUCTION_ENVIRONMENT => Some(Self::Production),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Development => DEVELOPMENT_ENVIRONMENT,
            Self::Production => PRODUCTION_ENVIRONMENT,
        }
    }

    fn base_url(self) -> &'static str {
        match self {
            Self::Development => SANDBOX_BASE_URL,
            Self::Production => PRODUCTION_BASE_URL,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceToken {
    pub value: String,
    pub hash: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeviceTokenError {
    InvalidShape,
}

impl DeviceTokenError {
    pub fn code(&self) -> &'static str {
        match self {
            DeviceTokenError::InvalidShape => "invalid_device_token",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PushRequestError {
    InvalidDeviceToken(DeviceTokenError),
    PayloadTooLarge,
}

impl PushRequestError {
    pub fn code(&self) -> &'static str {
        match self {
            PushRequestError::InvalidDeviceToken(error) => error.code(),
            PushRequestError::PayloadTooLarge => "apns_payload_too_large",
        }
    }
}

impl From<DeviceTokenError> for PushRequestError {
    fn from(error: DeviceTokenError) -> Self {
        Self::InvalidDeviceToken(error)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PushRequest {
    pub url: String,
    pub headers: Vec<(&'static str, String)>,
    pub body: String,
}

#[derive(Debug, Clone, Copy)]
pub struct EpisodeNotification<'a> {
    pub podcast_title: &'a str,
    pub episode_title: &'a str,
    pub episode_summary: Option<&'a str>,
    pub show_notes_html: Option<&'a str>,
    pub duration_seconds: Option<i64>,
    pub artwork_url: Option<&'a str>,
    pub feed_url: &'a str,
    pub episode_id: &'a str,
}

pub fn normalize_device_token(token: &str) -> Result<DeviceToken, DeviceTokenError> {
    if token.len() < MIN_TOKEN_HEX_LENGTH
        || token.len() > MAX_TOKEN_HEX_LENGTH
        || !token.len().is_multiple_of(2)
        || !token.bytes().all(is_lowercase_hex)
    {
        return Err(DeviceTokenError::InvalidShape);
    }

    Ok(DeviceToken {
        value: token.to_string(),
        hash: sha256_hex(token.as_bytes()),
    })
}

pub fn validate_device_token_hash(hash: &str) -> bool {
    hash.len() == 64 && hash.bytes().all(is_lowercase_hex)
}

pub fn validate_apns_environment(environment: &str) -> bool {
    ApnsEnvironment::parse(environment).is_some()
}

pub fn apns_environment_matches(environment: &str, configured: ApnsEnvironment) -> bool {
    ApnsEnvironment::parse(environment) == Some(configured)
}

pub fn diagnostic_push_request(
    device_token: &str,
    bundle_id: &str,
    environment: ApnsEnvironment,
    title: Option<&str>,
    body: Option<&str>,
) -> Result<PushRequest, DeviceTokenError> {
    let token = normalize_device_token(device_token)?;
    let alert_title = normalized_alert_text(title, "OpenCast");
    let alert_body = normalized_alert_text(body, "Notification test");
    let payload = DiagnosticPayload {
        aps: Aps {
            alert: Alert {
                title: alert_title,
                subtitle: None,
                body: alert_body,
            },
            sound: "default",
            category: None,
            thread_id: None,
            mutable_content: None,
            target_content_id: None,
        },
        opencast: DiagnosticOpenCastPayload { kind: "diagnostic" },
    };

    let body = serde_json::to_string(&payload).expect("diagnostic payload should encode");
    Ok(push_request(token, bundle_id, environment, body))
}

pub fn episode_push_request(
    device_token: &str,
    bundle_id: &str,
    environment: ApnsEnvironment,
    notification: EpisodeNotification<'_>,
) -> Result<PushRequest, PushRequestError> {
    let token = normalize_device_token(device_token)?;
    let podcast_title = normalized_alert_text(Some(notification.podcast_title), "OpenCast");
    let episode_title = normalized_alert_text(Some(notification.episode_title), "New episode");
    let summary = notification_summary(
        notification.episode_summary,
        notification.show_notes_html,
        episode_title.as_str(),
    );
    let duration_text = notification
        .duration_seconds
        .and_then(format_duration_for_notification);
    let body = notification_body(summary.as_deref());
    let artwork_url = notification.artwork_url.and_then(normalized_custom_value);
    let mut payload = EpisodePayload {
        aps: Aps {
            alert: Alert {
                title: podcast_title.clone(),
                subtitle: Some(episode_title.clone()),
                body,
            },
            sound: "default",
            category: Some(EPISODE_NOTIFICATION_CATEGORY),
            thread_id: Some(podcast_thread_id(notification.feed_url)),
            mutable_content: Some(1),
            target_content_id: Some(truncated_chars(notification.episode_id, 128)),
        },
        opencast: EpisodeOpenCastPayload {
            kind: "episode",
            feed_url: truncated_chars(notification.feed_url, 512),
            episode_id: truncated_chars(notification.episode_id, 128),
            podcast_title: Some(podcast_title),
            episode_title: Some(episode_title),
            episode_summary: summary,
            episode_duration_seconds: notification.duration_seconds.filter(|value| *value > 0),
            episode_duration_text: duration_text,
            artwork_url,
        },
    };

    let mut body = episode_payload_body(&payload)?;
    if body.len() > MAX_APNS_PAYLOAD_BYTES {
        payload.opencast.episode_summary = None;
        body = episode_payload_body(&payload)?;
    }
    if body.len() > MAX_APNS_PAYLOAD_BYTES {
        payload.opencast.podcast_title = None;
        payload.opencast.episode_title = None;
        payload.opencast.episode_duration_seconds = None;
        payload.opencast.episode_duration_text = None;
        body = episode_payload_body(&payload)?;
    }
    if body.len() > MAX_APNS_PAYLOAD_BYTES {
        payload.aps.alert.body = notification_body(None);
        body = episode_payload_body(&payload)?;
    }
    if body.len() > MAX_APNS_PAYLOAD_BYTES {
        payload.aps.alert.body = "New episode available".to_string();
        body = episode_payload_body(&payload)?;
    }
    if body.len() > MAX_APNS_PAYLOAD_BYTES {
        payload.opencast.artwork_url = None;
        body = episode_payload_body(&payload)?;
    }
    if body.len() > MAX_APNS_PAYLOAD_BYTES {
        return Err(PushRequestError::PayloadTooLarge);
    }

    Ok(push_request(token, bundle_id, environment, body))
}

fn episode_payload_body(payload: &EpisodePayload) -> Result<String, PushRequestError> {
    serde_json::to_string(payload).map_err(|_| PushRequestError::PayloadTooLarge)
}

fn push_request(
    token: DeviceToken,
    bundle_id: &str,
    environment: ApnsEnvironment,
    body: String,
) -> PushRequest {
    PushRequest {
        url: format!("{}/3/device/{}", environment.base_url(), token.value),
        headers: vec![
            ("apns-topic", bundle_id.to_string()),
            ("apns-push-type", "alert".to_string()),
            ("apns-priority", "10".to_string()),
            ("content-type", "application/json".to_string()),
        ],
        body,
    }
}

fn normalized_alert_text(value: Option<&str>, fallback: &'static str) -> String {
    let value = value.unwrap_or(fallback).trim();
    if value.is_empty() {
        fallback.to_string()
    } else {
        truncated_chars(value, 180)
    }
}

fn normalized_custom_value(value: &str) -> Option<String> {
    let value = value.trim();
    (!value.is_empty()).then(|| truncated_utf8(value, MAX_CUSTOM_VALUE_BYTES))
}

fn notification_summary(
    summary: Option<&str>,
    show_notes_html: Option<&str>,
    episode_title: &str,
) -> Option<String> {
    [summary, show_notes_html]
        .into_iter()
        .flatten()
        .map(|value| collapsed_plain_text(&truncated_utf8(value, MAX_SUMMARY_SOURCE_BYTES)))
        .find(|candidate| is_useful_summary(candidate.as_str(), episode_title))
        .map(|candidate| truncated_utf8(candidate.as_str(), MAX_CUSTOM_SUMMARY_BYTES))
}

fn notification_body(summary: Option<&str>) -> String {
    match summary {
        Some(summary) => truncated_utf8(summary, MAX_ALERT_BODY_BYTES),
        None => "New episode available".to_string(),
    }
}

fn is_useful_summary(candidate: &str, episode_title: &str) -> bool {
    !candidate.is_empty() && !titles_match(candidate, episode_title)
}

fn titles_match(lhs: &str, rhs: &str) -> bool {
    normalized_text_for_match(lhs) == normalized_text_for_match(rhs)
}

fn normalized_text_for_match(value: &str) -> String {
    value
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_ascii_lowercase()
}

fn collapsed_plain_text(value: &str) -> String {
    let decoded = decode_html_entities_until_stable(value);
    let without_tags = strip_html_tags(&decoded);
    let without_url_debris = remove_url_and_attribute_debris(&without_tags);
    trim_orphan_punctuation(&collapse_whitespace(&without_url_debris)).to_string()
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

fn decode_html_entities(value: &str) -> String {
    let mut output = String::with_capacity(value.len());
    let mut rest = value;
    while let Some(start) = rest.find('&') {
        output.push_str(&rest[..start]);
        let after_ampersand = &rest[start + 1..];
        let Some(end) = after_ampersand.find(';') else {
            output.push('&');
            rest = after_ampersand;
            continue;
        };
        let entity = &after_ampersand[..end];
        if let Some(decoded) = decode_entity(entity) {
            output.push(decoded);
        } else {
            output.push('&');
            output.push_str(entity);
            output.push(';');
        }
        rest = &after_ampersand[end + 1..];
    }
    output.push_str(rest);
    output
}

fn decode_html_entities_until_stable(value: &str) -> String {
    let mut current = value.to_string();
    for _ in 0..2 {
        let decoded = decode_html_entities(&current);
        if decoded == current {
            break;
        }
        current = decoded;
    }
    current
}

fn decode_entity(entity: &str) -> Option<char> {
    match entity {
        "amp" => Some('&'),
        "quot" => Some('"'),
        "apos" => Some('\''),
        "lt" => Some('<'),
        "gt" => Some('>'),
        "nbsp" => Some(' '),
        "ndash" | "mdash" => Some('-'),
        "lsquo" | "rsquo" => Some('\''),
        "ldquo" | "rdquo" => Some('"'),
        "hellip" => Some('.'),
        _ => decode_numeric_entity(entity),
    }
}

fn decode_numeric_entity(entity: &str) -> Option<char> {
    let value = entity
        .strip_prefix("#x")
        .or_else(|| entity.strip_prefix("#X"))
        .and_then(|hex| u32::from_str_radix(hex, 16).ok())
        .or_else(|| {
            entity
                .strip_prefix('#')
                .and_then(|decimal| decimal.parse::<u32>().ok())
        })?;
    char::from_u32(value)
}

fn collapse_whitespace(value: &str) -> String {
    value.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn remove_url_and_attribute_debris(value: &str) -> String {
    let tokens = value.split_whitespace().collect::<Vec<_>>();
    let mut output = Vec::new();
    let mut removed_link_debris = false;
    let mut index = 0;
    while index < tokens.len() {
        let token = strip_malformed_paragraph_prefix(tokens[index]);
        let normalized = token.trim_matches(orphan_punctuation);
        let next = tokens
            .get(index + 1)
            .map(|token| strip_malformed_paragraph_prefix(token).trim_matches(orphan_punctuation));

        if is_html_tag_marker(normalized) {
            index += 1;
            continue;
        }
        if is_attribute_token(normalized)
            || is_url_like(normalized)
            || (normalized == "a" && next.is_some_and(is_attribute_token))
        {
            removed_link_debris = true;
            index += 1;
            continue;
        }

        output.push(token);
        index += 1;
    }

    let output = output.join(" ");
    if removed_link_debris {
        trim_trailing_link_prompt(&output)
    } else {
        output.trim().to_string()
    }
}

fn strip_malformed_paragraph_prefix(token: &str) -> &str {
    for prefix in ["/p", "p"] {
        if let Some(rest) = token.strip_prefix(prefix) {
            let mut characters = rest.chars();
            if let Some(first) = characters.next() {
                if first.is_uppercase()
                    && characters
                        .next()
                        .is_some_and(|character| character.is_lowercase())
                {
                    return rest;
                }
            }
        }
    }
    token
}

fn is_html_tag_marker(value: &str) -> bool {
    matches!(value, "p" | "/p" | "br" | "/br" | "/a")
}

fn is_attribute_token(value: &str) -> bool {
    let value = value.trim_matches(orphan_punctuation).to_ascii_lowercase();
    value.starts_with("href=")
        || value.starts_with("src=")
        || value.starts_with("target=")
        || value.starts_with("rel=")
}

fn is_url_like(value: &str) -> bool {
    let value = value.trim_matches(orphan_punctuation).to_ascii_lowercase();
    value.starts_with("http://")
        || value.starts_with("https://")
        || value.starts_with("www.")
        || value.contains("://")
}

fn trim_trailing_link_prompt(value: &str) -> String {
    let mut value = value.trim().to_string();
    for prompt in [
        "Visit",
        "Read more",
        "Learn more",
        "Listen now",
        "Subscribe",
    ] {
        if value == prompt {
            value.clear();
            break;
        }

        let suffix = format!(" {prompt}");
        if value.ends_with(&suffix) {
            value.truncate(value.len() - suffix.len());
            break;
        }
    }
    value
}

fn trim_orphan_punctuation(value: &str) -> &str {
    value.trim_matches(orphan_punctuation)
}

fn orphan_punctuation(character: char) -> bool {
    character.is_whitespace()
        || matches!(
            character,
            '"' | '\''
                | ','
                | ';'
                | ':'
                | '-'
                | '_'
                | '|'
                | '/'
                | '\\'
                | '('
                | ')'
                | '['
                | ']'
                | '{'
                | '}'
        )
}

fn format_duration_for_notification(seconds: i64) -> Option<String> {
    if seconds <= 0 || seconds > MAX_NOTIFICATION_DURATION_SECONDS {
        return None;
    }
    let rounded_minutes = (seconds.saturating_add(30) / 60).max(1);
    if rounded_minutes < 60 {
        Some(format!("{rounded_minutes} MIN"))
    } else {
        let hours = rounded_minutes / 60;
        let minutes = rounded_minutes % 60;
        if minutes == 0 {
            Some(format!("{hours} HR"))
        } else {
            Some(format!("{hours} HR {minutes} MIN"))
        }
    }
}

fn podcast_thread_id(feed_url: &str) -> String {
    let hash = sha256_hex(feed_url.as_bytes());
    format!("opencast-podcast-{}", &hash[..16])
}

fn truncated_chars(value: &str, max_chars: usize) -> String {
    value.chars().take(max_chars).collect()
}

fn truncated_utf8(value: &str, max_bytes: usize) -> String {
    if value.len() <= max_bytes {
        return value.to_string();
    }

    let mut end = max_bytes;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    value[..end].to_string()
}

fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

fn is_lowercase_hex(byte: u8) -> bool {
    byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
}

#[derive(Serialize)]
struct DiagnosticPayload {
    aps: Aps,
    opencast: DiagnosticOpenCastPayload,
}

#[derive(Serialize)]
struct EpisodePayload {
    aps: Aps,
    opencast: EpisodeOpenCastPayload,
}

#[derive(Serialize)]
struct Aps {
    alert: Alert,
    sound: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    category: Option<&'static str>,
    #[serde(rename = "thread-id", skip_serializing_if = "Option::is_none")]
    thread_id: Option<String>,
    #[serde(rename = "mutable-content", skip_serializing_if = "Option::is_none")]
    mutable_content: Option<u8>,
    #[serde(rename = "target-content-id", skip_serializing_if = "Option::is_none")]
    target_content_id: Option<String>,
}

#[derive(Serialize)]
struct Alert {
    title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    subtitle: Option<String>,
    body: String,
}

#[derive(Serialize)]
struct DiagnosticOpenCastPayload {
    kind: &'static str,
}

#[derive(Serialize)]
struct EpisodeOpenCastPayload {
    kind: &'static str,
    feed_url: String,
    episode_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    podcast_title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    episode_title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    episode_summary: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    episode_duration_seconds: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    episode_duration_text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    artwork_url: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    const DEVICE_TOKEN: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    #[test]
    fn device_token_normalizes_raw_value_and_derives_log_safe_hash() {
        let token = normalize_device_token(DEVICE_TOKEN).expect("token should validate");

        assert_eq!(token.value, DEVICE_TOKEN);
        assert_eq!(
            token.hash,
            "a8ae6e6ee929abea3afcfc5258c8ccd6f85273e0d4626d26c7279f3250f77c8e"
        );
    }

    #[test]
    fn device_token_rejects_uppercase_and_odd_length_values() {
        assert_eq!(
            normalize_device_token(
                "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"
            )
            .expect_err("uppercase should fail")
            .code(),
            "invalid_device_token"
        );

        assert!(normalize_device_token("123").is_err());
    }

    #[test]
    fn diagnostic_push_request_targets_development_apns_with_alert_headers() {
        let request = diagnostic_push_request(
            DEVICE_TOKEN,
            "com.connor.opencast",
            ApnsEnvironment::Development,
            Some("Debug Title"),
            Some("Debug Body"),
        )
        .expect("request should build");

        assert_eq!(
            request.url,
            format!("https://api.sandbox.push.apple.com/3/device/{DEVICE_TOKEN}")
        );
        assert!(request
            .headers
            .contains(&("apns-topic", "com.connor.opencast".to_string())));
        assert!(request
            .headers
            .contains(&("apns-push-type", "alert".to_string())));
        assert!(request
            .headers
            .contains(&("apns-priority", "10".to_string())));
        assert_eq!(
            request.body,
            r#"{"aps":{"alert":{"title":"Debug Title","body":"Debug Body"},"sound":"default"},"opencast":{"kind":"diagnostic"}}"#
        );
    }

    #[test]
    fn diagnostic_push_request_targets_production_apns_when_configured() {
        let request = diagnostic_push_request(
            DEVICE_TOKEN,
            "com.connor.opencast",
            ApnsEnvironment::Production,
            Some("Prod Title"),
            Some("Prod Body"),
        )
        .expect("request should build");

        assert_eq!(
            request.url,
            format!("https://api.push.apple.com/3/device/{DEVICE_TOKEN}")
        );
        assert_eq!(
            request.body,
            r#"{"aps":{"alert":{"title":"Prod Title","body":"Prod Body"},"sound":"default"},"opencast":{"kind":"diagnostic"}}"#
        );
    }

    #[test]
    fn apns_environment_match_rejects_mixed_token_lanes() {
        assert!(apns_environment_matches(
            DEVELOPMENT_ENVIRONMENT,
            ApnsEnvironment::Development
        ));
        assert!(apns_environment_matches(
            PRODUCTION_ENVIRONMENT,
            ApnsEnvironment::Production
        ));
        assert!(!apns_environment_matches(
            DEVELOPMENT_ENVIRONMENT,
            ApnsEnvironment::Production
        ));
        assert!(!apns_environment_matches(
            PRODUCTION_ENVIRONMENT,
            ApnsEnvironment::Development
        ));
        assert!(!apns_environment_matches(
            "sandbox",
            ApnsEnvironment::Development
        ));
    }

    #[test]
    fn episode_push_request_carries_rich_metadata_and_alert_fields() {
        let request = episode_push_request(
            DEVICE_TOKEN,
            "com.connor.opencast",
            ApnsEnvironment::Development,
            EpisodeNotification {
                podcast_title: "Podcast Title",
                episode_title: "Episode Title",
                episode_summary: Some("<p>Summary &amp; context.</p>"),
                show_notes_html: None,
                duration_seconds: Some(2_640),
                artwork_url: Some("https://example.com/artwork.jpg"),
                feed_url: "https://example.com/feed.xml",
                episode_id: "episode-id",
            },
        )
        .expect("request should build");

        let payload = json_payload(&request);
        assert_eq!(payload["aps"]["category"], "OPENCAST_EPISODE");
        assert_eq!(payload["aps"]["mutable-content"], 1);
        assert_eq!(
            payload["aps"]["thread-id"],
            "opencast-podcast-7a775db75c1d6d17"
        );
        assert_eq!(payload["aps"]["target-content-id"], "episode-id");
        assert_eq!(payload["aps"]["alert"]["title"], "Podcast Title");
        assert_eq!(payload["aps"]["alert"]["subtitle"], "Episode Title");
        assert_eq!(payload["aps"]["alert"]["body"], "Summary & context.");
        assert_eq!(payload["opencast"]["kind"], "episode");
        assert_eq!(
            payload["opencast"]["feed_url"],
            "https://example.com/feed.xml"
        );
        assert_eq!(payload["opencast"]["episode_id"], "episode-id");
        assert_eq!(payload["opencast"]["podcast_title"], "Podcast Title");
        assert_eq!(payload["opencast"]["episode_title"], "Episode Title");
        assert_eq!(payload["opencast"]["episode_summary"], "Summary & context.");
        assert_eq!(payload["opencast"]["episode_duration_seconds"], 2640);
        assert_eq!(payload["opencast"]["episode_duration_text"], "44 MIN");
        assert_eq!(
            payload["opencast"]["artwork_url"],
            "https://example.com/artwork.jpg"
        );
    }

    #[test]
    fn episode_push_request_uses_show_notes_when_summary_is_blank_or_title_duplicate() {
        let request = episode_push_request(
            DEVICE_TOKEN,
            "com.connor.opencast",
            ApnsEnvironment::Development,
            EpisodeNotification {
                podcast_title: "Podcast Title",
                episode_title: "Episode Title",
                episode_summary: Some(" Episode Title "),
                show_notes_html: Some("<article><p>Full notes for notification.</p></article>"),
                duration_seconds: None,
                artwork_url: None,
                feed_url: "https://example.com/feed.xml",
                episode_id: "episode-id",
            },
        )
        .expect("request should build");

        let payload = json_payload(&request);
        assert_eq!(
            payload["aps"]["alert"]["body"],
            "Full notes for notification."
        );
        assert_eq!(
            payload["opencast"]["episode_summary"],
            "Full notes for notification."
        );
    }

    #[test]
    fn episode_push_request_keeps_duration_out_of_alert_body() {
        let request = episode_push_request(
            DEVICE_TOKEN,
            "com.connor.opencast",
            ApnsEnvironment::Development,
            EpisodeNotification {
                podcast_title: "The Rest Is Science",
                episode_title: "A Paleontology Of The Future",
                episode_summary: Some("We spend the hour looking at deep time and future fossils."),
                show_notes_html: None,
                duration_seconds: Some(3_960),
                artwork_url: None,
                feed_url: "https://example.com/feed.xml",
                episode_id: "episode-id",
            },
        )
        .expect("request should build");

        let payload = json_payload(&request);
        assert_eq!(
            payload["aps"]["alert"]["body"],
            "We spend the hour looking at deep time and future fossils."
        );
        assert_eq!(payload["opencast"]["episode_duration_text"], "1 HR 6 MIN");
    }

    #[test]
    fn summary_cleaner_decodes_escaped_html_before_stripping_tags() {
        assert_eq!(
            collapsed_plain_text("&lt;p&gt;We spend the hour in deep time.&lt;/p&gt;"),
            "We spend the hour in deep time."
        );
        assert_eq!(
            collapsed_plain_text("AT&amp;T explains the network."),
            "AT&T explains the network."
        );
    }

    #[test]
    fn summary_cleaner_strips_tags_after_double_entity_decoding() {
        let script = collapsed_plain_text("&amp;lt;script&amp;gt;alert(1)&amp;lt;/script&amp;gt;");
        assert!(!script.contains('<'));
        assert!(!script.contains('>'));

        assert_eq!(
            collapsed_plain_text("&amp;lt;b&amp;gt;Bold&amp;lt;/b&amp;gt;"),
            "Bold"
        );
    }

    #[test]
    fn episode_push_request_keeps_double_escaped_markup_out_of_payload_text() {
        let request = episode_push_request(
            DEVICE_TOKEN,
            "com.connor.opencast",
            ApnsEnvironment::Development,
            EpisodeNotification {
                podcast_title: "Podcast Title",
                episode_title: "Episode Title",
                episode_summary: Some("&amp;lt;script&amp;gt;alert(1)&amp;lt;/script&amp;gt;"),
                show_notes_html: None,
                duration_seconds: None,
                artwork_url: None,
                feed_url: "https://example.com/feed.xml",
                episode_id: "episode-id",
            },
        )
        .expect("request should build");

        let payload = json_payload(&request);
        let alert_body = payload["aps"]["alert"]["body"]
            .as_str()
            .expect("alert body should be a string");
        let summary = payload["opencast"]["episode_summary"]
            .as_str()
            .expect("summary should be a string");
        assert!(!alert_body.contains('<'));
        assert!(!alert_body.contains('>'));
        assert!(!summary.contains('<'));
        assert!(!summary.contains('>'));
    }

    #[test]
    fn summary_cleaner_drops_urls_and_keeps_useful_link_text() {
        assert_eq!(
            collapsed_plain_text(
                r#"<p>Visit <a href="https://example.com/path?utm=1">this link</a></p>"#
            ),
            "Visit this link"
        );
        assert_eq!(
            collapsed_plain_text("Listen at https://example.com/track?utm=1 for more."),
            "Listen at for more."
        );
    }

    #[test]
    fn summary_cleaner_removes_malformed_html_debris() {
        assert_eq!(
            collapsed_plain_text(
                "pWe spend the hour in deep time. /pVisit a href=https://example.com"
            ),
            "We spend the hour in deep time."
        );
    }

    #[test]
    fn summary_cleaner_keeps_legitimate_p_prefixed_prose() {
        assert_eq!(
            collapsed_plain_text("pH balance and p5 protocol matter."),
            "pH balance and p5 protocol matter."
        );
    }

    #[test]
    fn summary_cleaner_does_not_trim_legitimate_subscribe_endings() {
        assert_eq!(collapsed_plain_text("Please Subscribe"), "Please Subscribe");
        assert_eq!(
            collapsed_plain_text("We discuss why you should Subscribe"),
            "We discuss why you should Subscribe"
        );
        assert_eq!(collapsed_plain_text("Read more https://example.com"), "");
    }

    #[test]
    fn notification_summary_rejects_title_and_url_only_candidates() {
        assert_eq!(
            notification_summary(
                Some("A Paleontology Of The Future"),
                Some("https://example.com/show-notes"),
                "A Paleontology Of The Future",
            ),
            None
        );
        assert_eq!(
            notification_summary(
                Some("A Paleontology Of The Future"),
                Some("<p>Useful fallback notes.</p>"),
                "A Paleontology Of The Future",
            )
            .as_deref(),
            Some("Useful fallback notes.")
        );
        assert_eq!(
            notification_summary(
                Some("Useful prose about foo:// URI schemes."),
                None,
                "A Paleontology Of The Future",
            )
            .as_deref(),
            Some("Useful prose about foo:// URI schemes.")
        );
        assert_eq!(
            notification_summary(
                Some("Useful prose explaining how https:// links work."),
                None,
                "A Paleontology Of The Future",
            )
            .as_deref(),
            Some("Useful prose explaining how https:// links work.")
        );
    }

    #[test]
    fn duration_formatter_handles_normal_and_implausible_values() {
        assert_eq!(
            format_duration_for_notification(2_640).as_deref(),
            Some("44 MIN")
        );
        assert_eq!(
            format_duration_for_notification(3_960).as_deref(),
            Some("1 HR 6 MIN")
        );
        assert_eq!(
            format_duration_for_notification(3_600).as_deref(),
            Some("1 HR")
        );
        assert_eq!(format_duration_for_notification(i64::MAX), None);
        assert_eq!(format_duration_for_notification(2 * 24 * 60 * 60), None);
    }

    #[test]
    fn notification_body_shortens_long_unicode_without_splitting_characters() {
        let summary = "Summary 😀 ".repeat(200);
        let body = notification_body(Some(&summary));

        assert!(body.len() <= MAX_ALERT_BODY_BYTES);
        assert!(std::str::from_utf8(body.as_bytes()).is_ok());
    }

    #[test]
    fn episode_push_request_keeps_multibyte_payload_under_apns_limit() {
        let podcast_title = "ポッドキャスト".repeat(80);
        let episode_title = "新しいエピソード😀".repeat(80);
        let episode_summary = "要約😀".repeat(2_000);
        let artwork_url = "https://example.com/artwork/".repeat(40);
        let request = episode_push_request(
            DEVICE_TOKEN,
            "com.connor.opencast",
            ApnsEnvironment::Development,
            EpisodeNotification {
                podcast_title: &podcast_title,
                episode_title: &episode_title,
                episode_summary: Some(&episode_summary),
                show_notes_html: None,
                duration_seconds: Some(3_600),
                artwork_url: Some(&artwork_url),
                feed_url: "https://example.com/feed.xml",
                episode_id: "episode-id",
            },
        )
        .expect("request should fit after shrinking");

        assert!(request.body.len() <= MAX_APNS_PAYLOAD_BYTES);
        assert!(std::str::from_utf8(request.body.as_bytes()).is_ok());
    }

    #[test]
    fn episode_push_request_drops_optional_custom_metadata_before_alert_titles() {
        let long_title = "😀".repeat(300);
        let long_summary = "Summary 😀 ".repeat(1_000);
        let long_url = format!("https://example.com/{}", "artwork".repeat(200));
        let request = episode_push_request(
            DEVICE_TOKEN,
            "com.connor.opencast",
            ApnsEnvironment::Development,
            EpisodeNotification {
                podcast_title: &long_title,
                episode_title: &long_title,
                episode_summary: Some(&long_summary),
                show_notes_html: None,
                duration_seconds: Some(3_600),
                artwork_url: Some(&long_url),
                feed_url: &long_url,
                episode_id: "episode-id",
            },
        )
        .expect("request should fit after dropping optional custom metadata");

        assert!(request.body.len() <= MAX_APNS_PAYLOAD_BYTES);
        assert!(request.body.contains(r#""title":"#));
        assert!(request.body.contains(r#""subtitle":"#));
        assert!(!request.body.contains("podcast_title"));
        assert!(!request.body.contains("episode_title"));
    }

    fn json_payload(request: &PushRequest) -> serde_json::Value {
        serde_json::from_str(&request.body).expect("payload should decode")
    }
}
