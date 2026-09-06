use super::*;
use crate::{feed_resource as limits, poll_decisions, poll_scheduling, storage};
use tokio::io::{AsyncRead, BufReader};

#[derive(Debug)]
pub(crate) struct ScannedFeed {
    pub title: String,
    pub website_url: Option<String>,
    pub artwork_url: Option<String>,
    pub latest: ParsedEpisode,
    pub notifications: Vec<NotificationCandidate>,
    pub item_count: usize,
    pub checkpoint_found: bool,
    pub publish_cadence_seconds: Option<i64>,
}

#[derive(Debug, Clone)]
pub(crate) struct NotificationCandidate {
    pub episode: ParsedEpisode,
    pub fingerprint: Option<String>,
}

impl NotificationCandidate {
    fn new(mut episode: ParsedEpisode) -> Self {
        let fingerprint = feed_identity::episode_notification_fingerprint(
            feed_identity::EpisodeNotificationFingerprintInput {
                title: &episode.title,
                guid: episode.guid.as_deref(),
                audio_url: episode.audio_url.as_deref(),
                duration_seconds: episode.duration_seconds,
                summary: episode.summary.as_deref(),
                show_notes_html: episode.show_notes_html.as_deref(),
                episode_id: &episode.id,
            },
        );
        // Identity material can itself be megabytes. After deriving the exact
        // identity and fingerprint, retain only the fields the APNs payload
        // actually uses, with its existing artwork output limit.
        episode.guid = None;
        episode.audio_url = None;
        episode.artwork_url = episode
            .artwork_url
            .map(|url| truncated_utf8(url.trim(), 512));
        Self {
            episode,
            fingerprint,
        }
    }
}

/// Complete-document scan with bounded retained state. Notification eligibility
/// uses the existing decision function; a deep checkpoint still authorizes the
/// same three candidates as the materializing parser.
pub(crate) async fn scan_rss<R: AsyncRead + Unpin>(
    source: R,
    feed: &storage::FeedPollRow,
) -> Result<ScannedFeed, RSSParseError> {
    let source = super::guarded_reader::GuardedReader::new(source);
    let mut reader = Reader::from_reader(BufReader::with_capacity(limits::CHUNK_BYTES, source));
    reader.config_mut().trim_text(false);
    reader.config_mut().allow_dangling_amp = true;
    let mut buffer = Vec::with_capacity(limits::CHUNK_BYTES);
    let mut channel = ChannelAccumulator::default();
    let mut current_item = None;
    let mut stack = Vec::new();
    let mut text = String::new();
    let mut field_bytes = 0usize;
    let mut prefix_sealed = false;
    let mut omitted_non_whitespace = false;
    let mut item_bytes = 0usize;
    let mut processed_bytes = 0usize;
    let mut item_count = 0usize;
    let mut root_seen = false;
    let mut root_closed = false;
    let mut latest: Option<NotificationCandidate> = None;
    let mut candidates = Vec::new();
    let mut checkpoint_found = false;
    let mut timestamps = Vec::with_capacity(11);

    loop {
        let event = reader
            .read_event_into_async(&mut buffer)
            .await
            .map_err(|error| {
                if let quick_xml::Error::Io(error) = &error {
                    match error.to_string().as_str() {
                        "oversized_body" => return RSSParseError::ResourceLimit("oversized_body"),
                        "feed_field_limit" => {
                            return RSSParseError::ResourceLimit("feed_field_limit")
                        }
                        "feed_inactivity_timeout" => return RSSParseError::InactivityTimeout,
                        _ => return RSSParseError::TransferInterrupted,
                    }
                }
                RSSParseError::InvalidXML
            })?;
        match event {
            Event::Start(element) => {
                let name = normalized_name(element.name().as_ref());
                if stack.is_empty() {
                    if root_seen || root_closed || name != "rss" {
                        return Err(RSSParseError::UnsupportedFeedFormat);
                    }
                    root_seen = true;
                }
                if stack.len() >= limits::MAX_DEPTH {
                    return Err(RSSParseError::ResourceLimit("feed_depth_limit"));
                }
                if name == "item" {
                    if current_item.is_some() {
                        return Err(RSSParseError::InvalidXML);
                    }
                    item_count += 1;
                    if item_count > limits::MAX_ITEMS {
                        return Err(RSSParseError::TooManyFeedItems);
                    }
                    item_bytes = 0;
                    current_item = Some(ItemAccumulator::default());
                }
                account_attributes(
                    &element,
                    current_item.is_some(),
                    &mut item_bytes,
                    &mut processed_bytes,
                )?;
                apply_start_element(&name, &element, &mut channel, &mut current_item, &reader);
                stack.push(name);
                text.clear();
                field_bytes = 0;
                prefix_sealed = false;
                omitted_non_whitespace = false;
            }
            Event::Empty(element) => {
                if stack.is_empty() {
                    return Err(RSSParseError::InvalidXML);
                }
                if stack.len() >= limits::MAX_DEPTH {
                    return Err(RSSParseError::ResourceLimit("feed_depth_limit"));
                }
                let name = normalized_name(element.name().as_ref());
                if name == "item" {
                    item_count += 1;
                    if item_count > limits::MAX_ITEMS {
                        return Err(RSSParseError::TooManyFeedItems);
                    }
                }
                account_attributes(
                    &element,
                    current_item.is_some(),
                    &mut item_bytes,
                    &mut processed_bytes,
                )?;
                apply_start_element(&name, &element, &mut channel, &mut current_item, &reader);
            }
            event @ (Event::Text(_) | Event::CData(_) | Event::GeneralRef(_)) => {
                // Decode text by reference when UTF-8, avoiding a second
                // token-sized allocation alongside quick-xml's event buffer.
                let decoded = match &event {
                    Event::Text(value) => value.decode().map_err(|_| RSSParseError::InvalidXML)?,
                    Event::CData(value) => value.decode().map_err(|_| RSSParseError::InvalidXML)?,
                    _ => {
                        let mut value = String::new();
                        xml_text::push_event_text(&mut value, &event);
                        std::borrow::Cow::Owned(value)
                    }
                };
                if stack.is_empty() && !decoded.trim().is_empty() {
                    return Err(RSSParseError::InvalidXML);
                }
                field_bytes += decoded.len();
                processed_bytes += decoded.len();
                if current_item.is_some() {
                    item_bytes += decoded.len();
                }
                check_text_budgets(field_bytes, item_bytes, processed_bytes)?;
                let text_limit = match stack.last().map(String::as_str) {
                    Some("description" | "itunes:summary" | "content:encoded") => {
                        MAX_EPISODE_TEXT_BYTES + 4
                    }
                    _ => limits::MAX_FIELD_BYTES,
                };
                // Preserve trim-before-truncate semantics even across chunks.
                let value = if text.is_empty() {
                    decoded.trim_start()
                } else {
                    &decoded
                };
                let remaining = text_limit.saturating_sub(text.len());
                if !prefix_sealed && remaining > 0 {
                    let retained = truncated_utf8(value, remaining);
                    let retained_bytes = retained.len();
                    text.push_str(&retained);
                    if retained_bytes < value.len() {
                        prefix_sealed = true;
                        omitted_non_whitespace |= !value[retained_bytes..].trim().is_empty();
                    }
                } else {
                    prefix_sealed = true;
                    omitted_non_whitespace |= !value.trim().is_empty();
                }
            }
            Event::End(element) => {
                let name = normalized_name(element.name().as_ref());
                if stack.last() != Some(&name) {
                    return Err(RSSParseError::InvalidXML);
                }
                if omitted_non_whitespace {
                    // A non-whitespace tail beyond the retained prefix keeps
                    // boundary whitespace intact through trim-before-truncate.
                    text.push('x');
                }
                if current_item.is_some() {
                    apply_item_value(&name, text.trim(), current_item.as_mut());
                } else {
                    apply_channel_value(&name, text.trim(), &stack, &mut channel);
                }
                if name == "item" {
                    let item = current_item.take().ok_or(RSSParseError::InvalidXML)?;
                    let episode = parsed_episode(item, &feed.feed_url);
                    if let Some(date) = episode.published_at {
                        timestamps.push(date);
                        timestamps.sort_unstable_by(|a, b| b.cmp(a));
                        timestamps.truncate(10);
                    }
                    if feed.latest_episode_id.as_deref() == Some(&episode.id) {
                        checkpoint_found = true;
                    }
                    let is_candidate = !checkpoint_found
                        && candidates.len() < poll_decisions::MAX_CATCH_UP_NOTIFICATIONS
                        && poll_decisions::changed_episode_should_notify(feed, &episode);
                    if latest.is_none() || is_candidate {
                        let candidate = NotificationCandidate::new(episode);
                        if latest.is_none() {
                            latest = Some(candidate.clone());
                        }
                        if is_candidate {
                            candidates.push(candidate);
                        }
                    }
                }
                stack.pop();
                if stack.is_empty() {
                    root_closed = true;
                }
                text.clear();
                field_bytes = 0;
                prefix_sealed = false;
                omitted_non_whitespace = false;
            }
            Event::Eof => break,
            _ => {}
        }
        buffer.clear();
    }
    if !root_seen || !root_closed || !stack.is_empty() {
        return Err(RSSParseError::InvalidXML);
    }
    let latest = latest.ok_or(RSSParseError::EmptyFeed)?;
    if feed.latest_episode_id.is_none() {
        candidates.clear();
    } else if !checkpoint_found {
        candidates.clear();
        if poll_decisions::changed_episode_should_notify(feed, &latest.episode) {
            candidates.push(latest.clone());
        }
    }
    candidates.reverse();
    let title = non_empty(channel.title.as_deref()).unwrap_or(&feed.feed_url);
    Ok(ScannedFeed {
        title: truncated_chars(title, MAX_FEED_TITLE_CHARS),
        website_url: channel.website_url.and_then(non_empty_string),
        artwork_url: channel.artwork_url.and_then(non_empty_string),
        latest: latest.episode,
        notifications: candidates,
        item_count,
        checkpoint_found,
        publish_cadence_seconds: poll_scheduling::publish_cadence_seconds(&mut timestamps),
    })
}

fn account_attributes(
    element: &BytesStart<'_>,
    in_item: bool,
    item: &mut usize,
    total: &mut usize,
) -> Result<(), RSSParseError> {
    for attribute in element.attributes() {
        let attribute = attribute.map_err(|_| RSSParseError::InvalidXML)?;
        let count = attribute.value.len();
        *total += count;
        if in_item {
            *item += count;
        }
        check_text_budgets(count, *item, *total)?;
    }
    Ok(())
}

fn check_text_budgets(field: usize, item: usize, total: usize) -> Result<(), RSSParseError> {
    if field > limits::MAX_FIELD_BYTES {
        return Err(RSSParseError::ResourceLimit("feed_field_limit"));
    }
    if item > limits::MAX_ITEM_TEXT_BYTES {
        return Err(RSSParseError::ResourceLimit("feed_item_text_limit"));
    }
    if total > limits::MAX_PROCESSING_BYTES {
        return Err(RSSParseError::ResourceLimit("feed_processing_limit"));
    }
    Ok(())
}
