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
    collapsed_lowercase(title, false)
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
    episode_notification_fingerprint_hash(input).map(hex::encode)
}

/// The fingerprint's SHA-256 bytes; `episode_notification_fingerprint` is
/// their hex form. Scans that only compare hashes skip the hex round trip.
pub fn episode_notification_fingerprint_hash(
    input: EpisodeNotificationFingerprintInput<'_>,
) -> Option<[u8; 32]> {
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

    Some(
        Sha256::digest(
            format!(
                "notification-episode-v2|title:{title}|{}",
                material.join("|")
            )
            .as_bytes(),
        )
        .into(),
    )
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
    collapsed_lowercase(value, true)
}

fn normalized_text_for_fingerprint(value: &str) -> String {
    collapsed_lowercase(value, false)
}

/// One pass, one allocation: every `char::is_whitespace` run becomes one ASCII
/// space, the ends are trimmed and ASCII letters lowercased; entities stay as
/// written. With `strip_tags`, `<` and `>` also separate words and everything
/// between them (or after an unclosed `<`) is dropped. Equal, by the oracle
/// test below, to stripping tags into spaces, then `split_whitespace`, `join`
/// and `to_ascii_lowercase`: the fingerprint and episode-id contracts.
fn collapsed_lowercase(value: &str, strip_tags: bool) -> String {
    let mut output = String::with_capacity(value.len());
    let mut in_tag = false;
    let mut separated = false;
    for character in value.chars() {
        if strip_tags && matches!(character, '<' | '>') {
            in_tag = character == '<';
            separated = true;
        } else if character.is_whitespace() {
            separated = true;
        } else if !in_tag {
            if separated && !output.is_empty() {
                output.push(' ');
            }
            separated = false;
            output.push(character.to_ascii_lowercase());
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
                " HTTPS://Feeds.Example.com/example-current-affairs.xml/?b=2&a=1#fragment "
            )
            .expect("url should canonicalize"),
            "https://feeds.example.com/example-current-affairs.xml?a=1&b=2"
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
                "https://feeds.example.com/example-current-affairs.xml",
                Some(" example-guid-001 "),
                Some("https://example.com/audio/changed.mp3"),
                "Changed",
                Some(1)
            ),
            "ac103bb72f511765e54752d3319b4f5f2a1db87d0b5188f9a8905591d07f8cd2"
        );
    }

    #[test]
    fn episode_id_falls_back_to_audio_url() {
        assert_eq!(
            episode_id(
                "https://feeds.example.com/example-current-affairs.xml",
                None,
                Some("HTTPS://Example.com/audio/example-002.mp3?b=2&a=1#ignored"),
                "Retitled",
                Some(1)
            ),
            "800837fff7062cf74cc7234f1d41a2109dc2b803adcbe67b3218d740950cbf44"
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

    /// Digest-arm inputs pinned before the one-pass normalization: every
    /// tag, entity and whitespace shape the summary digest has to keep.
    fn digest_arm_goldens(
        long: &str,
    ) -> Vec<(&'static str, EpisodeNotificationFingerprintInput<'_>)> {
        let base = EpisodeNotificationFingerprintInput {
            title: "Episode 12: The Return",
            guid: Some("guid-12"),
            audio_url: None,
            duration_seconds: None,
            summary: None,
            show_notes_html: None,
            episode_id: "episode-12",
        };
        vec![
            (
                "inline tags",
                EpisodeNotificationFingerprintInput {
                    summary: Some("<p>Hello <b>World</b>,<br/>and <i>more</i>.</p><div>Next</div>"),
                    audio_url: Some("https://example.com/audio/12.mp3"),
                    ..base
                },
            ),
            (
                "unclosed anchor",
                EpisodeNotificationFingerprintInput {
                    summary: Some("Intro text <a href=\"https://example.com/x?y=1 trailing words never closed"),
                    duration_seconds: Some(1_800),
                    ..base
                },
            ),
            (
                "entities",
                EpisodeNotificationFingerprintInput {
                    summary: Some("Fish &amp; chips&nbsp;tonight &lt;b&gt; raw &#8217;quoted&#8217;"),
                    ..base
                },
            ),
            (
                "nbsp",
                EpisodeNotificationFingerprintInput {
                    summary: Some("\u{a0}Before\u{a0}after \u{a0}\u{a0} spaced\u{a0}"),
                    ..base
                },
            ),
            (
                "crlf and tab runs",
                EpisodeNotificationFingerprintInput {
                    summary: Some("\r\n\tLine one\r\n\r\n\tLine two\t\t  three\r\n"),
                    ..base
                },
            ),
            (
                "mixed case",
                EpisodeNotificationFingerprintInput {
                    title: "  MiXeD   Title\tHERE ",
                    summary: Some("MiXeD CaSe \u{c9}COLE \u{dc}n\u{ef}code TEXT <EM>Loud</EM>"),
                    ..base
                },
            ),
            (
                "16 KiB body",
                EpisodeNotificationFingerprintInput {
                    summary: Some(long),
                    audio_url: Some("https://example.com/audio/long.mp3"),
                    duration_seconds: Some(3_600),
                    ..base
                },
            ),
            (
                "empty summary, show notes",
                EpisodeNotificationFingerprintInput {
                    summary: Some("  <p> \u{a0}</p> <br> "),
                    show_notes_html: Some("<div>Show <em>notes</em>\n here</div>"),
                    ..base
                },
            ),
        ]
    }

    fn long_golden_body() -> String {
        let paragraph = "<p>Show notes with <a href=\"https://example.com/notes?utm_source=feed\">a link</a> &amp; <strong>emphasis</strong>,\r\n plus\u{a0}prose.</p>";
        let mut body = String::new();
        while body.len() + paragraph.len() <= 16 * 1024 {
            body.push_str(paragraph);
        }
        body
    }

    #[test]
    fn notification_fingerprint_digest_arm_goldens() {
        let long = long_golden_body();
        assert!(long.len() > 16 * 1024 - 200 && long.len() <= 16 * 1024);
        let expected = [
            "6d5891f7be528b4548414123da7a9de6f193cc5c9462ea3778980ac55bbb0da4",
            "1793d54f640d65c64539db9af5661d394926eeacf9fd558711bd4adb39550526",
            "a39dbfa3fc2aac9367125c9077eb9203fa0e4fc460ae660cca90a4d7c5b47af8",
            "65215f85831970772857a0c3b0bbc8530649aec19deeab1726b11b363b1c92dc",
            "debd8732d71f185d03f474982eefd5b749293e350f90fe19a90ad49a888675c6",
            "e6a8ca2327f8682283c0aa5222427276ff11f71029f733273307bde99d944cbf",
            "8f5276baf72f8e89733a935e05a142b6269d056a8c42a771c68a5ca90d80efa8",
            "c62e33636c389d88ecfbac70fac2053b6521451b6f33ac14e38d31f09f8b573b",
        ];
        let goldens = digest_arm_goldens(&long);
        assert_eq!(goldens.len(), expected.len());
        for ((name, input), expected) in goldens.into_iter().zip(expected) {
            assert_eq!(
                episode_notification_fingerprint(input).as_deref(),
                Some(expected),
                "{name}"
            );
            assert_eq!(
                episode_notification_fingerprint_hash(input)
                    .map(hex::encode)
                    .as_deref(),
                Some(expected),
                "{name}"
            );
        }
    }

    /// `main`'s normalization functions before the one-pass rewrite, kept
    /// verbatim as the oracle. A divergence is a defect in the new function:
    /// it would re-fingerprint every feed once and break identity matching.
    mod oracle {
        pub fn normalized_title_for_episode_identity(title: &str) -> String {
            title
                .trim()
                .to_ascii_lowercase()
                .split_whitespace()
                .collect::<Vec<_>>()
                .join(" ")
        }

        pub fn normalized_plain_text_for_fingerprint(value: &str) -> String {
            normalized_text_for_fingerprint(&strip_html_tags(value))
        }

        pub fn normalized_text_for_fingerprint(value: &str) -> String {
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
    }

    fn element_texts<'a>(xml: &'a str, name: &str) -> Vec<&'a str> {
        let (open, close) = (format!("<{name}>"), format!("</{name}>"));
        let mut texts = vec![];
        let mut rest = xml;
        while let Some(start) = rest.find(&open) {
            let body = &rest[start + open.len()..];
            let Some(end) = body.find(&close) else {
                break;
            };
            texts.push(&body[..end]);
            rest = &body[end + close.len()..];
        }
        texts
    }

    /// Raw string bodies, and the quoted segments of every line as written.
    fn string_literals(source: &str) -> Vec<String> {
        let mut literals = vec![];
        let mut rest = source;
        while let Some(start) = rest.find("r#\"") {
            let body = &rest[start + 3..];
            let Some(end) = body.find("\"#") else {
                break;
            };
            literals.push(body[..end].to_string());
            rest = &body[end + 2..];
        }
        for line in source.lines() {
            literals.extend(line.split('"').skip(1).step_by(2).map(str::to_string));
        }
        literals
    }

    #[test]
    fn one_pass_normalization_matches_the_oracle() {
        let mut inputs: Vec<String> = vec![];
        for xml in [
            include_str!(
                "../../../Packages/OpenCastCore/Tests/OpenCastCoreTests/Fixtures/examplecurrentaffairs.xml"
            ),
            include_str!(
                "../../../Packages/OpenCastCore/Tests/OpenCastCoreTests/Fixtures/fallbacks.xml"
            ),
        ] {
            // Each fixture must contribute prose; the exact count is the
            // fixture's business (the public copy ships a synthetic one).
            let mut fixture_texts = 0;
            for name in ["description", "content:encoded"] {
                for text in element_texts(xml, name) {
                    fixture_texts += 1;
                    inputs.push(text.to_string());
                    if let Some(inner) = text
                        .trim()
                        .strip_prefix("<![CDATA[")
                        .and_then(|inner| inner.strip_suffix("]]>"))
                    {
                        inputs.push(inner.to_string());
                    }
                }
            }
            assert!(fixture_texts >= 1, "a fixture without description or content text");
        }
        let prose = include_str!("notification_text.rs");
        inputs.extend(prose.lines().map(str::to_string));
        inputs.extend(string_literals(prose));
        let long = long_golden_body();
        for (_, input) in digest_arm_goldens(&long) {
            inputs.extend(
                [input.title, input.summary.unwrap_or_default()]
                    .into_iter()
                    .chain(input.show_notes_html)
                    .map(str::to_string),
            );
        }
        // Every other `char::is_whitespace` code point, alone and between tags.
        for space in [
            '\u{b}', '\u{c}', '\u{85}', '\u{1680}', '\u{2000}', '\u{200a}', '\u{2028}', '\u{2029}',
            '\u{202f}', '\u{205f}', '\u{3000}',
        ] {
            inputs.push(format!("{space}A{space}<b{space}c>{space}D{space}"));
        }
        inputs.extend(["", " ", "<", ">", "<<>>", "a<b", "a>b", "<a>", "x<>y"].map(str::to_string));
        // A tiny LCG over the markup, whitespace, entity and case alphabet.
        let alphabet = [
            '<', '>', '/', 'a', 'B', '\n', '\t', '\r', '\u{a0}', '&', ';', '\u{e9}', '1', '.', '"',
        ];
        let mut state: u64 = 0x5eed_f00d;
        let mut next = move || {
            state = state
                .wrapping_mul(6_364_136_223_846_793_005)
                .wrapping_add(1_442_695_040_888_963_407);
            (state >> 33) as usize
        };
        for _ in 0..10_000 {
            let length = next() % 48;
            inputs.push(
                (0..length)
                    .map(|_| alphabet[next() % alphabet.len()])
                    .collect(),
            );
        }
        assert!(inputs.len() > 10_500);
        for input in &inputs {
            assert_eq!(
                normalized_plain_text_for_fingerprint(input),
                oracle::normalized_plain_text_for_fingerprint(input),
                "{input:?}"
            );
            assert_eq!(
                normalized_text_for_fingerprint(input),
                oracle::normalized_text_for_fingerprint(input),
                "{input:?}"
            );
            assert_eq!(
                normalized_title_for_episode_identity(input),
                oracle::normalized_title_for_episode_identity(input),
                "{input:?}"
            );
        }
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
