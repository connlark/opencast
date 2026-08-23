use serde::Deserialize;
use sha1::{Digest, Sha1};
use url::Url;

use crate::types::{
    DirectoryEntry, MAX_GUID_CHARS, MAX_TEXT_CHARS, MAX_URL_CHARS, UPSTREAM_MAX_RESULTS,
};

pub const PODCAST_INDEX_API_BASE: &str = "https://api.podcastindex.org/api/1.0";
pub const DIRECTORY_USER_AGENT: &str = "OpenCast-Directory/1 (+https://opencast.mobile)";

/// Podcast Index request authorization: lowercase hex SHA-1 of
/// key + secret + timestamp (scheme verified against the live API
/// 2026-08-22).
pub fn auth_token(api_key: &str, api_secret: &str, unix_seconds: u64) -> String {
    let mut hasher = Sha1::new();
    hasher.update(api_key.as_bytes());
    hasher.update(api_secret.as_bytes());
    hasher.update(unix_seconds.to_string().as_bytes());
    hex::encode(hasher.finalize())
}

pub fn search_url(query: &str) -> String {
    let mut url = Url::parse(PODCAST_INDEX_API_BASE).expect("static base URL parses");
    url.path_segments_mut()
        .expect("https base URL has segments")
        .extend(["search", "byterm"]);
    url.query_pairs_mut()
        .append_pair("q", query)
        .append_pair("max", &UPSTREAM_MAX_RESULTS.to_string());
    url.into()
}

pub fn lookup_url(apple_id: u64) -> String {
    let mut url = Url::parse(PODCAST_INDEX_API_BASE).expect("static base URL parses");
    url.path_segments_mut()
        .expect("https base URL has segments")
        .extend(["podcasts", "byitunesid"]);
    url.query_pairs_mut()
        .append_pair("id", &apple_id.to_string());
    url.into()
}

#[derive(Debug, Deserialize)]
struct UpstreamSearchEnvelope {
    #[serde(default)]
    feeds: Vec<serde_json::Value>,
}

#[derive(Debug, Deserialize)]
struct UpstreamLookupEnvelope {
    #[serde(default)]
    feed: serde_json::Value,
}

#[derive(Debug, Deserialize)]
struct UpstreamFeed {
    id: Option<u64>,
    #[serde(rename = "podcastGuid")]
    podcast_guid: Option<String>,
    title: Option<String>,
    url: Option<String>,
    author: Option<String>,
    #[serde(rename = "ownerName")]
    owner_name: Option<String>,
    link: Option<String>,
    image: Option<String>,
    artwork: Option<String>,
    #[serde(rename = "itunesId")]
    itunes_id: Option<i64>,
    #[serde(rename = "episodeCount")]
    episode_count: Option<i64>,
    #[serde(rename = "newestItemPubdate")]
    newest_item_pubdate: Option<i64>,
    #[serde(rename = "lastUpdateTime")]
    last_update_time: Option<i64>,
}

/// Tolerates a missing or empty `feeds` array; fails only on
/// non-JSON or non-object envelopes. Entries missing a Podcast Index
/// ID, title, or valid HTTP feed URL are dropped, and the list is
/// defensively capped at the upstream maximum.
pub fn parse_search_response(body: &[u8]) -> Result<Vec<DirectoryEntry>, serde_json::Error> {
    let envelope: UpstreamSearchEnvelope = serde_json::from_slice(body)?;
    Ok(envelope
        .feeds
        .into_iter()
        .filter_map(normalized_entry)
        .take(UPSTREAM_MAX_RESULTS)
        .collect())
}

/// The live API returns `feed` as an object on a hit and an empty
/// array (or null) on a miss; a non-object is treated as no result.
pub fn parse_lookup_response(body: &[u8]) -> Result<Option<DirectoryEntry>, serde_json::Error> {
    let envelope: UpstreamLookupEnvelope = serde_json::from_slice(body)?;
    if !envelope.feed.is_object() {
        return Ok(None);
    }
    Ok(normalized_entry(envelope.feed))
}

fn normalized_entry(value: serde_json::Value) -> Option<DirectoryEntry> {
    let feed: UpstreamFeed = serde_json::from_value(value).ok()?;
    let podcast_index_id = feed.id.filter(|id| *id > 0)?;
    let title = bounded_text(feed.title?)?;
    let feed_url = valid_http_url(feed.url?)?;

    Some(DirectoryEntry {
        podcast_index_id,
        podcast_guid: feed
            .podcast_guid
            .and_then(|guid| bounded(guid, MAX_GUID_CHARS)),
        apple_id: feed.itunes_id.filter(|id| *id > 0).map(|id| id as u64),
        title,
        author: feed
            .author
            .and_then(bounded_text)
            .or_else(|| feed.owner_name.and_then(bounded_text)),
        feed_url,
        artwork_url: feed
            .artwork
            .and_then(valid_http_url)
            .or_else(|| feed.image.and_then(valid_http_url)),
        website_url: feed.link.and_then(valid_http_url),
        reported_episode_count: feed
            .episode_count
            .filter(|count| *count > 0)
            .and_then(|count| u32::try_from(count).ok()),
        reported_updated_at: feed
            .newest_item_pubdate
            .filter(|seconds| *seconds > 0)
            .or(feed.last_update_time.filter(|seconds| *seconds > 0)),
    })
}

fn bounded_text(value: String) -> Option<String> {
    bounded(value, MAX_TEXT_CHARS)
}

fn bounded(value: String, max_chars: usize) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() || trimmed.chars().count() > max_chars {
        return None;
    }
    Some(trimmed.to_string())
}

fn valid_http_url(value: String) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.chars().count() > MAX_URL_CHARS {
        return None;
    }
    let parsed = Url::parse(trimmed).ok()?;
    matches!(parsed.scheme(), "http" | "https").then(|| trimmed.to_string())
}
