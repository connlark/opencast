//! Pure decision helpers for the feed-poll pipeline: which parsed episode is
//! the latest, whether a changed feed should notify at all, and whether an
//! individual subscription should receive the episode. Host-compiled so the
//! tests actually run under `cargo test` (they were dead while these lived in
//! the wasm-only `worker_app`).

use crate::{feed_identity, rss, storage};

pub fn latest_polled_episode(
    parsed: &rss::ParsedFeed,
) -> Result<&rss::ParsedEpisode, &'static str> {
    parsed
        .episodes
        .first()
        .ok_or(rss::RSSParseError::EmptyFeed.code())
}

pub fn changed_episode_should_notify(
    feed: &storage::FeedPollRow,
    latest: &rss::ParsedEpisode,
) -> bool {
    let changed = feed
        .latest_episode_id
        .as_deref()
        .map(|known| known != latest.id)
        .unwrap_or(false);
    if !changed {
        return false;
    }

    if let Some(previous_title) = feed.latest_episode_title.as_deref() {
        let previous_title = feed_identity::normalized_title_for_episode_identity(previous_title);
        let latest_title = feed_identity::normalized_title_for_episode_identity(&latest.title);
        if previous_title == latest_title && feed.latest_episode_published_at == latest.published_at
        {
            return false;
        }
    }

    let Some(published_at) = latest.published_at else {
        return false;
    };
    if let Some(baseline) = feed.baseline_established_at {
        if published_at <= baseline {
            return false;
        }
    }
    if let Some(previous_published_at) = feed.latest_episode_published_at {
        if published_at < previous_published_at {
            return false;
        }
    }

    true
}

pub fn episode_should_notify_subscription(
    episode: &rss::ParsedEpisode,
    subscription_created_at: i64,
) -> bool {
    episode
        .published_at
        .map(|published_at| published_at > subscription_created_at)
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn latest_polled_episode_rejects_empty_parsed_feed() {
        let parsed = rss::ParsedFeed {
            title: "Empty".to_string(),
            website_url: None,
            artwork_url: None,
            episodes: Vec::new(),
        };

        assert_eq!(latest_polled_episode(&parsed), Err("empty_feed"));
    }

    #[test]
    fn changed_episode_should_notify_skips_backfilled_episode_before_baseline() {
        let feed = feed_poll_row_with_latest(
            Some("known-episode"),
            Some("486 - Pod Session"),
            Some(1_781_265_600),
            Some(1_781_989_485),
        );
        let latest = parsed_episode("new-id", "487 - Pride Loveline", Some(1_781_870_400));

        assert!(!changed_episode_should_notify(&feed, &latest));
    }

    #[test]
    fn changed_episode_should_notify_allows_newer_episode_after_baseline() {
        let feed = feed_poll_row_with_latest(
            Some("known-episode"),
            Some("486 - Pod Session"),
            Some(1_781_265_600),
            Some(1_781_989_485),
        );
        let latest = parsed_episode("new-id", "487 - Pride Loveline", Some(1_782_075_600));

        assert!(changed_episode_should_notify(&feed, &latest));
    }

    #[test]
    fn changed_episode_should_notify_skips_missing_pubdate() {
        let feed = feed_poll_row_with_latest(
            Some("known-episode"),
            Some("486 - Pod Session"),
            Some(1_781_265_600),
            Some(1_781_989_485),
        );
        let latest = parsed_episode("new-id", "487 - Pride Loveline", None);

        assert!(!changed_episode_should_notify(&feed, &latest));
    }

    #[test]
    fn changed_episode_should_notify_skips_visible_identity_churn() {
        let feed = feed_poll_row_with_latest(
            Some("old-guid-id"),
            Some(" 487   - Pride Loveline "),
            Some(1_781_870_400),
            Some(1_781_800_000),
        );
        let latest = parsed_episode("new-guid-id", "487 - Pride Loveline", Some(1_781_870_400));

        assert!(!changed_episode_should_notify(&feed, &latest));
    }

    #[test]
    fn episode_should_notify_subscription_skips_episode_published_before_subscription() {
        let episode = parsed_episode("new-id", "487 - Pride Loveline", Some(1_781_870_400));

        assert!(!episode_should_notify_subscription(&episode, 1_782_036_569));
    }

    #[test]
    fn episode_should_notify_subscription_allows_episode_published_after_subscription() {
        let episode = parsed_episode("new-id", "488 - New Episode", Some(1_782_075_600));

        assert!(episode_should_notify_subscription(&episode, 1_782_036_569));
    }

    #[test]
    fn episode_should_notify_subscription_skips_missing_pubdate() {
        let episode = parsed_episode("new-id", "Undated Episode", None);

        assert!(!episode_should_notify_subscription(&episode, 1_782_036_569));
    }

    fn feed_poll_row_with_latest(
        latest_episode_id: Option<&str>,
        latest_episode_title: Option<&str>,
        latest_episode_published_at: Option<i64>,
        baseline_established_at: Option<i64>,
    ) -> storage::FeedPollRow {
        storage::FeedPollRow {
            feed_url: "https://example.com/feed.xml".to_string(),
            source_url: "https://example.com/feed.xml".to_string(),
            etag: None,
            last_modified: None,
            latest_episode_id: latest_episode_id.map(str::to_string),
            latest_episode_title: latest_episode_title.map(str::to_string),
            latest_episode_published_at,
            baseline_established_at,
            consecutive_failures: 0,
            publish_cadence_seconds: None,
        }
    }

    fn parsed_episode(id: &str, title: &str, published_at: Option<i64>) -> rss::ParsedEpisode {
        rss::ParsedEpisode {
            id: id.to_string(),
            title: title.to_string(),
            summary: None,
            show_notes_html: None,
            guid: None,
            published_at,
            duration_seconds: None,
            audio_url: None,
            artwork_url: None,
        }
    }
}
