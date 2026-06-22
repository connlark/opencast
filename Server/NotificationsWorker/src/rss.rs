use crate::feed_identity;
use quick_xml::events::{BytesStart, Event};
use quick_xml::Reader;

const MIN_RSS_YEAR: i32 = 1900;
const MAX_RSS_YEAR: i32 = 9_999;
const MAX_FEED_TITLE_CHARS: usize = 512;
const MAX_EPISODE_TITLE_CHARS: usize = 512;
const MAX_EPISODE_TEXT_BYTES: usize = 16 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedFeed {
    pub title: String,
    pub website_url: Option<String>,
    pub artwork_url: Option<String>,
    pub episodes: Vec<ParsedEpisode>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedEpisode {
    pub id: String,
    pub title: String,
    pub summary: Option<String>,
    pub show_notes_html: Option<String>,
    pub guid: Option<String>,
    pub published_at: Option<i64>,
    pub duration_seconds: Option<i64>,
    pub audio_url: Option<String>,
    pub artwork_url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RSSParseError {
    InvalidXML,
    UnsupportedFeedFormat,
    EmptyFeed,
}

impl RSSParseError {
    pub fn code(&self) -> &'static str {
        match self {
            RSSParseError::InvalidXML => "invalid_xml",
            RSSParseError::UnsupportedFeedFormat => "unsupported_feed_format",
            RSSParseError::EmptyFeed => "empty_feed",
        }
    }
}

#[derive(Default)]
struct ChannelAccumulator {
    title: Option<String>,
    website_url: Option<String>,
    artwork_url: Option<String>,
}

#[derive(Default)]
struct ItemAccumulator {
    title: Option<String>,
    summary: Option<String>,
    show_notes_html: Option<String>,
    guid: Option<String>,
    published_at: Option<i64>,
    duration_seconds: Option<i64>,
    audio_url: Option<String>,
    artwork_url: Option<String>,
}

pub fn parse_rss(xml: &str, canonical_feed_url: &str) -> Result<ParsedFeed, RSSParseError> {
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(false);

    let mut channel = ChannelAccumulator::default();
    let mut current_item: Option<ItemAccumulator> = None;
    let mut items = Vec::new();
    let mut stack: Vec<String> = Vec::new();
    let mut text_buffer = String::new();
    let mut saw_rss = false;
    let mut saw_atom = false;

    loop {
        match reader.read_event() {
            Ok(Event::Start(element)) => {
                let name = normalized_name(element.name().as_ref());
                if stack.is_empty() {
                    saw_rss = name == "rss";
                    saw_atom = name == "feed";
                }
                apply_start_element(&name, &element, &mut channel, &mut current_item, &reader);
                if name == "item" {
                    current_item = Some(ItemAccumulator::default());
                }
                stack.push(name);
                text_buffer.clear();
            }
            Ok(Event::Empty(element)) => {
                let name = normalized_name(element.name().as_ref());
                apply_start_element(&name, &element, &mut channel, &mut current_item, &reader);
            }
            Ok(Event::Text(text)) => {
                if let Ok(value) = text.decode() {
                    text_buffer.push_str(&value);
                }
            }
            Ok(Event::CData(text)) => {
                if let Ok(value) = text.decode() {
                    text_buffer.push_str(&value);
                }
            }
            Ok(Event::End(element)) => {
                let name = normalized_name(element.name().as_ref());
                let value = text_buffer.trim();
                if current_item.is_some() {
                    apply_item_value(&name, value, current_item.as_mut());
                } else {
                    apply_channel_value(&name, value, &stack, &mut channel);
                }

                if name == "item" {
                    if let Some(item) = current_item.take() {
                        items.push(item);
                    }
                }
                stack.pop();
                text_buffer.clear();
            }
            Ok(Event::Eof) => break,
            Err(_) => return Err(RSSParseError::InvalidXML),
            _ => {}
        }
    }

    if !saw_rss {
        return if saw_atom {
            Err(RSSParseError::UnsupportedFeedFormat)
        } else {
            Err(RSSParseError::InvalidXML)
        };
    }

    let title = non_empty(channel.title.as_deref()).unwrap_or(canonical_feed_url);
    let episodes = items
        .into_iter()
        .map(|item| parsed_episode(item, canonical_feed_url))
        .collect::<Vec<_>>();

    if episodes.is_empty() {
        return Err(RSSParseError::EmptyFeed);
    }

    Ok(ParsedFeed {
        title: truncated_chars(title, MAX_FEED_TITLE_CHARS),
        website_url: channel.website_url.and_then(non_empty_string),
        artwork_url: channel.artwork_url.and_then(non_empty_string),
        episodes,
    })
}

pub fn parse_rss_date(value: &str) -> Option<i64> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return None;
    }

    if let Some(timestamp) = parse_rfc3339_date(trimmed) {
        return Some(timestamp);
    }

    let date_part = trimmed
        .split_once(',')
        .map(|(_, date)| date.trim())
        .unwrap_or(trimmed);
    let mut parts = date_part.split_whitespace();
    let day = parts.next()?.parse::<i32>().ok()?;
    let month = month_number(parts.next()?)?;
    let year = parts.next()?.parse::<i32>().ok()?;
    if !(MIN_RSS_YEAR..=MAX_RSS_YEAR).contains(&year) {
        return None;
    }
    let time = parts.next()?;
    let zone = parts.next()?;
    if parts.next().is_some() {
        return None;
    }

    let mut time_parts = time.split(':');
    let hour = time_parts.next()?.parse::<i32>().ok()?;
    let minute = time_parts.next()?.parse::<i32>().ok()?;
    let second = time_parts
        .next()
        .map(|value| value.parse::<i32>().ok())
        .unwrap_or(Some(0))?;
    if time_parts.next().is_some()
        || !valid_day(year, month, day)
        || !(0..=23).contains(&hour)
        || !(0..=59).contains(&minute)
        || !(0..=59).contains(&second)
    {
        return None;
    }

    let offset = timezone_offset_seconds(zone)?;
    let days = days_from_civil(year, month, day);
    Some(i64::from(days) * 86_400 + i64::from(hour * 3_600 + minute * 60 + second) - offset)
}

fn apply_start_element(
    name: &str,
    element: &BytesStart<'_>,
    channel: &mut ChannelAccumulator,
    current_item: &mut Option<ItemAccumulator>,
    reader: &Reader<&[u8]>,
) {
    match name {
        "enclosure" => {
            if let Some(item) = current_item {
                item.audio_url = attribute_value(element, "url", reader);
            }
        }
        "itunes:image" => {
            if let Some(url) = attribute_value(element, "href", reader) {
                if let Some(item) = current_item {
                    item.artwork_url = Some(url);
                } else {
                    channel.artwork_url = Some(url);
                }
            }
        }
        _ => {}
    }
}

fn apply_channel_value(
    name: &str,
    value: &str,
    stack: &[String],
    channel: &mut ChannelAccumulator,
) {
    match name {
        "title" => channel.title = Some(value.to_string()),
        "link" => channel.website_url = Some(value.to_string()),
        "url" if stack.iter().any(|element| element == "image") => {
            channel.artwork_url = Some(value.to_string());
        }
        _ => {}
    }
}

fn apply_item_value(name: &str, value: &str, item: Option<&mut ItemAccumulator>) {
    let Some(item) = item else {
        return;
    };

    match name {
        "title" => item.title = Some(value.to_string()),
        "description" | "itunes:summary" => {
            if non_empty(item.summary.as_deref()).is_none() {
                item.summary = Some(value.to_string());
            }
        }
        "content:encoded" => item.show_notes_html = Some(value.to_string()),
        "guid" => item.guid = Some(value.to_string()),
        "pubdate" => item.published_at = parse_rss_date(value),
        "itunes:duration" => item.duration_seconds = parse_rss_duration_seconds(value),
        _ => {}
    }
}

fn parsed_episode(item: ItemAccumulator, canonical_feed_url: &str) -> ParsedEpisode {
    let title = non_empty(item.title.as_deref()).unwrap_or("Untitled Episode");
    let title = truncated_chars(title, MAX_EPISODE_TITLE_CHARS);
    let audio_url = item.audio_url.and_then(non_empty_string);
    let guid = item.guid.and_then(non_empty_string);
    let id = feed_identity::episode_id(
        canonical_feed_url,
        guid.as_deref(),
        audio_url.as_deref(),
        &title,
        item.published_at,
    );

    ParsedEpisode {
        id,
        title,
        summary: item
            .summary
            .and_then(non_empty_string)
            .map(|value| truncated_utf8(&value, MAX_EPISODE_TEXT_BYTES)),
        show_notes_html: item
            .show_notes_html
            .and_then(non_empty_string)
            .map(|value| truncated_utf8(&value, MAX_EPISODE_TEXT_BYTES)),
        guid,
        published_at: item.published_at,
        duration_seconds: item.duration_seconds,
        audio_url,
        artwork_url: item.artwork_url.and_then(non_empty_string),
    }
}

pub fn parse_rss_duration_seconds(value: &str) -> Option<i64> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return None;
    }

    if let Ok(seconds) = trimmed.parse::<f64>() {
        return finite_non_negative_seconds(seconds);
    }

    let raw_parts = trimmed.split(':').collect::<Vec<_>>();
    let parts = raw_parts
        .iter()
        .map(|part| part.parse::<f64>())
        .collect::<std::result::Result<Vec<_>, _>>()
        .ok()?;
    if parts.len() != raw_parts.len() {
        return None;
    }

    let seconds = match parts.as_slice() {
        [hours, minutes, seconds] => hours * 3_600.0 + minutes * 60.0 + seconds,
        [minutes, seconds] => minutes * 60.0 + seconds,
        [seconds] => *seconds,
        _ => return None,
    };
    finite_non_negative_seconds(seconds)
}

fn finite_non_negative_seconds(seconds: f64) -> Option<i64> {
    if seconds.is_finite() && seconds >= 0.0 && seconds <= i64::MAX as f64 {
        Some(seconds.round() as i64)
    } else {
        None
    }
}

fn attribute_value(element: &BytesStart<'_>, name: &str, reader: &Reader<&[u8]>) -> Option<String> {
    element
        .attributes()
        .with_checks(false)
        .filter_map(Result::ok)
        .find_map(|attribute| {
            (normalized_name(attribute.key.as_ref()) == name).then(|| {
                attribute
                    .decode_and_unescape_value(reader.decoder())
                    .ok()
                    .map(|value| value.trim().to_string())
            })?
        })
}

fn normalized_name(name: &[u8]) -> String {
    String::from_utf8_lossy(name).to_ascii_lowercase()
}

fn non_empty(value: Option<&str>) -> Option<&str> {
    let value = value?.trim();
    (!value.is_empty()).then_some(value)
}

fn non_empty_string(value: String) -> Option<String> {
    let trimmed = value.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

fn month_number(value: &str) -> Option<i32> {
    match value.to_ascii_lowercase().as_str() {
        "jan" => Some(1),
        "feb" => Some(2),
        "mar" => Some(3),
        "apr" => Some(4),
        "may" => Some(5),
        "jun" => Some(6),
        "jul" => Some(7),
        "aug" => Some(8),
        "sep" => Some(9),
        "oct" => Some(10),
        "nov" => Some(11),
        "dec" => Some(12),
        _ => None,
    }
}

fn timezone_offset_seconds(value: &str) -> Option<i64> {
    match value.to_ascii_uppercase().as_str() {
        "GMT" | "UTC" | "UT" => return Some(0),
        "EST" => return Some(-5 * 3_600),
        "EDT" => return Some(-4 * 3_600),
        "CST" => return Some(-6 * 3_600),
        "CDT" => return Some(-5 * 3_600),
        "MST" => return Some(-7 * 3_600),
        "MDT" => return Some(-6 * 3_600),
        "PST" => return Some(-8 * 3_600),
        "PDT" => return Some(-7 * 3_600),
        _ => {}
    }

    let bytes = value.as_bytes();
    if !matches!(bytes.len(), 5 | 6) || !bytes.is_ascii() {
        return None;
    }

    let sign = match bytes[0] {
        b'+' => 1,
        b'-' => -1,
        _ => return None,
    };
    let hours = ascii_digit(bytes[1])? * 10 + ascii_digit(bytes[2])?;
    let minute_start = if bytes.len() == 6 {
        if bytes[3] != b':' {
            return None;
        }
        4
    } else {
        3
    };
    let minutes = ascii_digit(bytes[minute_start])? * 10 + ascii_digit(bytes[minute_start + 1])?;
    if hours > 23 || minutes > 59 {
        return None;
    }
    Some(sign * (hours * 3_600 + minutes * 60))
}

fn ascii_digit(byte: u8) -> Option<i64> {
    byte.is_ascii_digit().then_some(i64::from(byte - b'0'))
}

fn days_from_civil(year: i32, month: i32, day: i32) -> i32 {
    let year = year - i32::from(month <= 2);
    let era = if year >= 0 { year } else { year - 399 } / 400;
    let yoe = year - era * 400;
    let month_prime = month + if month > 2 { -3 } else { 9 };
    let doy = (153 * month_prime + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

fn parse_rfc3339_date(value: &str) -> Option<i64> {
    let (date, time_and_zone) = value
        .split_once('T')
        .or_else(|| value.split_once('t'))
        .or_else(|| value.split_once(' '))?;
    let (year, month, day) = parse_iso_date(date)?;
    let (hour, minute, second, offset) = parse_iso_time_and_zone(time_and_zone)?;
    let days = days_from_civil(year, month, day);
    Some(i64::from(days) * 86_400 + i64::from(hour * 3_600 + minute * 60 + second) - offset)
}

fn parse_iso_date(value: &str) -> Option<(i32, i32, i32)> {
    let mut parts = value.split('-');
    let year = parts.next()?.parse::<i32>().ok()?;
    let month = parts.next()?.parse::<i32>().ok()?;
    let day = parts.next()?.parse::<i32>().ok()?;
    if parts.next().is_some()
        || !(MIN_RSS_YEAR..=MAX_RSS_YEAR).contains(&year)
        || !(1..=12).contains(&month)
        || !valid_day(year, month, day)
    {
        return None;
    }
    Some((year, month, day))
}

fn parse_iso_time_and_zone(value: &str) -> Option<(i32, i32, i32, i64)> {
    let (time, zone) =
        if let Some(time) = value.strip_suffix('Z').or_else(|| value.strip_suffix('z')) {
            (time, "Z")
        } else {
            let offset_index = value
                .char_indices()
                .skip(1)
                .find_map(|(index, character)| matches!(character, '+' | '-').then_some(index))?;
            (&value[..offset_index], &value[offset_index..])
        };
    let time = time.split_once('.').map(|(whole, _)| whole).unwrap_or(time);
    let mut parts = time.split(':');
    let hour = parts.next()?.parse::<i32>().ok()?;
    let minute = parts.next()?.parse::<i32>().ok()?;
    let second = parts
        .next()
        .map(|value| value.parse::<i32>().ok())
        .unwrap_or(Some(0))?;
    if parts.next().is_some()
        || !(0..=23).contains(&hour)
        || !(0..=59).contains(&minute)
        || !(0..=59).contains(&second)
    {
        return None;
    }
    let offset = if zone == "Z" {
        0
    } else {
        timezone_offset_seconds(zone)?
    };
    Some((hour, minute, second, offset))
}

fn valid_day(year: i32, month: i32, day: i32) -> bool {
    (1..=days_in_month(year, month)).contains(&day)
}

fn days_in_month(year: i32, month: i32) -> i32 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if leap_year(year) => 29,
        2 => 28,
        _ => 0,
    }
}

fn leap_year(year: i32) -> bool {
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
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

#[cfg(test)]
mod tests {
    use super::*;

    const AMERICAN_PRESTIGE: &str = include_str!(
        "../../../Packages/OpenCastCore/Tests/OpenCastCoreTests/Fixtures/americanprestige.xml"
    );
    const FALLBACKS: &str = include_str!(
        "../../../Packages/OpenCastCore/Tests/OpenCastCoreTests/Fixtures/fallbacks.xml"
    );

    #[test]
    fn parses_rss_fields_needed_for_notifications() {
        let feed = parse_rss(
            AMERICAN_PRESTIGE,
            "https://jumble.top/f/americanprestige.xml",
        )
        .expect("fixture should parse");

        assert_eq!(feed.title, "American Prestige");
        assert_eq!(
            feed.artwork_url.as_deref(),
            Some("https://example.com/american-prestige.jpg")
        );
        assert_eq!(feed.episodes.len(), 2);
        assert_eq!(feed.episodes[0].title, "Episode With GUID");
        assert_eq!(
            feed.episodes[0].summary.as_deref(),
            Some("<p>First fixture episode.</p>")
        );
        assert_eq!(
            feed.episodes[0].show_notes_html.as_deref(),
            Some("<article><p>Full notes for the first episode.</p></article>")
        );
        assert_eq!(feed.episodes[0].duration_seconds, Some(3_723));
        assert_eq!(feed.episodes[0].guid.as_deref(), Some("ap-guid-001"));
        assert_eq!(
            feed.episodes[0].audio_url.as_deref(),
            Some("https://example.com/audio/ap-001.mp3")
        );
    }

    #[test]
    fn parses_fallback_identity_inputs() {
        let feed = parse_rss(FALLBACKS, "https://example.com/fallbacks.xml")
            .expect("fixture should parse");

        let audio_episode = feed
            .episodes
            .iter()
            .find(|episode| episode.title == "Audio URL Stable Original")
            .expect("audio fallback should exist");
        assert_eq!(audio_episode.guid, None);
        assert_eq!(
            audio_episode.audio_url.as_deref(),
            Some("https://example.com/audio/stable-audio.mp3")
        );

        let title_episode = feed
            .episodes
            .iter()
            .find(|episode| episode.title == "Title Date Stable")
            .expect("title fallback should exist");
        assert_eq!(title_episode.audio_url, None);
        assert_eq!(title_episode.published_at, Some(1_775_736_000));
    }

    #[test]
    fn parses_supported_rss_dates() {
        assert_eq!(
            parse_rss_date("Mon, 1 Jan 2024 00:00:00 +0000"),
            Some(1_704_067_200)
        );
        assert_eq!(
            parse_rss_date("Mon, 01 Jan 2024 00:00 +0000"),
            Some(1_704_067_200)
        );
        assert_eq!(
            parse_rss_date("1 Jan 2024 00:00:00 +0000"),
            Some(1_704_067_200)
        );
        assert_eq!(
            parse_rss_date("01 Jan 2024 00:00:00 -0600"),
            Some(1_704_088_800)
        );
        assert_eq!(
            parse_rss_date("Fri, 19 Jun 2026 12:00:00 GMT"),
            Some(1_781_870_400)
        );
        assert_eq!(
            parse_rss_date("Fri, 19 Jun 2026 12:00:00 +00:00"),
            Some(1_781_870_400)
        );
        assert_eq!(parse_rss_date("2026-06-19T12:00:00Z"), Some(1_781_870_400));
        assert_eq!(
            parse_rss_date("2026-06-19T07:00:00-05:00"),
            Some(1_781_870_400)
        );
        assert_eq!(
            parse_rss_date("Fri, 19 Jun 2026 07:00:00 CDT"),
            Some(1_781_870_400)
        );
    }

    #[test]
    fn parses_supported_rss_durations() {
        assert_eq!(parse_rss_duration_seconds("01:02:03"), Some(3_723));
        assert_eq!(parse_rss_duration_seconds("32:10"), Some(1_930));
        assert_eq!(parse_rss_duration_seconds("3723"), Some(3_723));
        assert_eq!(parse_rss_duration_seconds("3723.4"), Some(3_723));
        assert_eq!(parse_rss_duration_seconds("not a duration"), None);
        assert_eq!(parse_rss_duration_seconds("-1"), None);
    }

    #[test]
    fn parses_ascii_timezone_offsets() {
        assert_eq!(timezone_offset_seconds("+0000"), Some(0));
        assert_eq!(timezone_offset_seconds("-0530"), Some(-19_800));
        assert_eq!(timezone_offset_seconds("-05:30"), Some(-19_800));
        assert_eq!(timezone_offset_seconds("GMT"), Some(0));
        assert_eq!(timezone_offset_seconds("utc"), Some(0));
        assert_eq!(timezone_offset_seconds("PST"), Some(-28_800));
    }

    #[test]
    fn rejects_malformed_timezone_offsets() {
        assert_eq!(timezone_offset_seconds("+000"), None);
        assert_eq!(timezone_offset_seconds("+00000"), None);
        assert_eq!(timezone_offset_seconds("00000"), None);
        assert_eq!(timezone_offset_seconds("+0A0"), None);
        assert_eq!(timezone_offset_seconds("+2400"), None);
        assert_eq!(timezone_offset_seconds("+0060"), None);
        assert_eq!(timezone_offset_seconds("é123"), None);
        assert_eq!(timezone_offset_seconds("+0é0"), None);
    }

    #[test]
    fn rejects_out_of_range_rss_years() {
        assert_eq!(parse_rss_date("01 Jan 1899 00:00:00 +0000"), None);
        assert_eq!(parse_rss_date("01 Jan 10000 00:00:00 +0000"), None);
        assert_eq!(parse_rss_date("31 Feb 2024 00:00:00 +0000"), None);
        assert_eq!(parse_rss_date("2024-02-31T00:00:00Z"), None);
        assert_eq!(
            parse_rss_date("01 Jan 2024 00:00:00 +0000"),
            Some(1_704_067_200)
        );
    }

    #[test]
    fn rejects_atom_and_empty_feeds() {
        assert_eq!(
            parse_rss(
                "<feed><title>Atom</title></feed>",
                "https://example.com/feed"
            )
            .expect_err("atom should reject")
            .code(),
            "unsupported_feed_format"
        );
        assert_eq!(
            parse_rss(
                "<rss><channel><title>Empty</title></channel></rss>",
                "https://example.com/feed"
            )
            .expect_err("empty should reject")
            .code(),
            "empty_feed"
        );
    }
}
