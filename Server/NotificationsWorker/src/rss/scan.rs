use super::*;
use crate::feed_resource as limits;
use tokio::io::{AsyncRead, BufReader};

#[derive(Debug)]
pub(crate) struct ScannedFeed {
    pub title: String,
    pub artwork_url: Option<String>,
    #[cfg(test)]
    pub item_count: usize,
}

/// An awaited consumer shares the validated streaming parser. It may stage data,
/// but must not publish until `scan_rss_with_sink` returns successfully.
#[allow(async_fn_in_trait)]
pub(crate) trait EpisodeSink {
    async fn item(
        &mut self,
        episode: &ParsedEpisode,
        raw_date: Option<&str>,
    ) -> Result<(), RSSParseError>;
}
#[cfg(test)]
struct IgnoreEpisodes;
#[cfg(test)]
impl EpisodeSink for IgnoreEpisodes {
    async fn item(&mut self, _: &ParsedEpisode, _: Option<&str>) -> Result<(), RSSParseError> {
        Ok(())
    }
}

/// Complete-document scan with bounded retained state.
#[cfg(test)]
pub(crate) async fn scan_rss<R: AsyncRead + Unpin>(
    source: R,
    feed_url: &str,
) -> Result<ScannedFeed, RSSParseError> {
    scan_rss_with_sink(source, feed_url, &mut IgnoreEpisodes).await
}

pub(crate) async fn scan_rss_with_sink<R: AsyncRead + Unpin, S: EpisodeSink>(
    source: R,
    feed_url: &str,
    sink: &mut S,
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
    let mut parsed_items = 0usize;

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
                    let raw_date = item.raw_date.clone();
                    let episode = parsed_episode(item, feed_url);
                    sink.item(&episode, raw_date.as_deref()).await?;
                    parsed_items += 1;
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
    if parsed_items == 0 {
        return Err(RSSParseError::EmptyFeed);
    }
    let title = non_empty(channel.title.as_deref()).unwrap_or(feed_url);
    Ok(ScannedFeed {
        title: truncated_chars(title, MAX_FEED_TITLE_CHARS),
        artwork_url: channel.artwork_url.and_then(non_empty_string),
        #[cfg(test)]
        item_count,
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
