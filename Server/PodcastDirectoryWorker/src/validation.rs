use crate::types::MAX_QUERY_CHARS;

/// Trims and collapses internal whitespace runs to single spaces, then
/// bounds the result to 1..=200 characters.
pub fn normalized_query(raw: &str) -> Option<String> {
    let normalized = raw.split_whitespace().collect::<Vec<_>>().join(" ");
    let character_count = normalized.chars().count();
    if character_count == 0 || character_count > MAX_QUERY_CHARS {
        return None;
    }
    Some(normalized)
}

/// A positive decimal integer with no sign, leading zeros, or trailing
/// path segments.
pub fn parse_apple_id(segment: &str) -> Option<u64> {
    if segment.is_empty()
        || segment.len() > 19
        || !segment.bytes().all(|byte| byte.is_ascii_digit())
    {
        return None;
    }
    if segment.len() > 1 && segment.starts_with('0') {
        return None;
    }
    let value = segment.parse::<u64>().ok()?;
    (value > 0).then_some(value)
}

/// `application/json` with optional parameters, case-insensitively.
pub fn is_json_content_type(value: &str) -> bool {
    let media_type = value.split(';').next().unwrap_or("").trim();
    media_type.eq_ignore_ascii_case("application/json")
}
