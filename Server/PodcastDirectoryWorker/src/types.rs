use serde::{Deserialize, Serialize};

/// Wire-format version stamped on every successful response body.
pub const DTO_VERSION: u32 = 1;

/// Request bodies larger than this are rejected with 413.
pub const MAX_REQUEST_BODY_BYTES: usize = 2 * 1024;

/// Upstream bodies are streamed and abandoned past this bound.
pub const MAX_UPSTREAM_BODY_BYTES: usize = 512 * 1024;

/// Podcast Index requests are aborted after this long.
pub const UPSTREAM_TIMEOUT_MS: u64 = 5_000;

/// Fixed `max` sent upstream and defensive cap on returned entries.
pub const UPSTREAM_MAX_RESULTS: usize = 25;

/// Normalized queries must be 1..=200 characters.
pub const MAX_QUERY_CHARS: usize = 200;

/// Cache TTLs are the smaller of the upstream directive and these caps.
pub const SEARCH_CACHE_TTL_CAP_SECONDS: u64 = 15 * 60;
pub const LOOKUP_CACHE_TTL_CAP_SECONDS: u64 = 60 * 60;

/// Defensive bounds on upstream-supplied strings.
pub const MAX_TEXT_CHARS: usize = 512;
pub const MAX_URL_CHARS: usize = 2_048;
pub const MAX_GUID_CHARS: usize = 128;

pub const ERROR_INVALID_CONTENT_TYPE: &str = "invalid_content_type";
pub const ERROR_INVALID_JSON: &str = "invalid_json";
pub const ERROR_INVALID_QUERY: &str = "invalid_query";
pub const ERROR_INVALID_APPLE_ID: &str = "invalid_apple_id";
pub const ERROR_NOT_FOUND: &str = "not_found";
pub const ERROR_METHOD_NOT_ALLOWED: &str = "method_not_allowed";
pub const ERROR_PAYLOAD_TOO_LARGE: &str = "payload_too_large";
pub const ERROR_RATE_LIMITED: &str = "rate_limited";
pub const ERROR_UPSTREAM_STATUS: &str = "upstream_status";
pub const ERROR_UPSTREAM_TIMEOUT: &str = "upstream_timeout";
pub const ERROR_UPSTREAM_UNREACHABLE: &str = "upstream_unreachable";
pub const ERROR_UPSTREAM_TOO_LARGE: &str = "upstream_too_large";
pub const ERROR_UPSTREAM_MALFORMED: &str = "upstream_malformed";
pub const ERROR_DISABLED: &str = "podcast_directory_disabled";
pub const ERROR_ENV_MISSING: &str = "worker_env_missing";
pub const ERROR_SECRET_MISSING: &str = "worker_secret_missing";
pub const ERROR_BINDING_MISSING: &str = "worker_binding_missing";

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct ErrorResponse {
    pub error: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

impl ErrorResponse {
    pub fn new(error: &str) -> Self {
        Self {
            error: error.to_string(),
            detail: None,
        }
    }

    pub fn with_detail(error: &str, detail: String) -> Self {
        Self {
            error: error.to_string(),
            detail: Some(detail),
        }
    }
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct SearchRequest {
    pub query: String,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct DirectoryEntry {
    #[serde(rename = "podcastIndexId")]
    pub podcast_index_id: u64,
    #[serde(rename = "podcastGuid", skip_serializing_if = "Option::is_none")]
    pub podcast_guid: Option<String>,
    #[serde(rename = "appleId", skip_serializing_if = "Option::is_none")]
    pub apple_id: Option<u64>,
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub author: Option<String>,
    #[serde(rename = "feedUrl")]
    pub feed_url: String,
    #[serde(rename = "artworkUrl", skip_serializing_if = "Option::is_none")]
    pub artwork_url: Option<String>,
    #[serde(rename = "websiteUrl", skip_serializing_if = "Option::is_none")]
    pub website_url: Option<String>,
    #[serde(
        rename = "reportedEpisodeCount",
        skip_serializing_if = "Option::is_none"
    )]
    pub reported_episode_count: Option<u32>,
    #[serde(rename = "reportedUpdatedAt", skip_serializing_if = "Option::is_none")]
    pub reported_updated_at: Option<i64>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct SearchResponse {
    pub version: u32,
    pub results: Vec<DirectoryEntry>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct LookupResponse {
    pub version: u32,
    pub result: DirectoryEntry,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct HealthResponse {
    pub message: String,
    pub enabled: bool,
}
