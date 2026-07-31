//! Pure decision helpers for the feed-poll pipeline: which parsed episode is
//! the latest, whether a changed feed should notify at all, and whether an
//! individual subscription should receive the episode. Host-compiled so the
//! tests actually run under `cargo test` (they were dead while these lived in
//! the wasm-only `worker_app`).

use crate::{feed_identity, rss, storage};
use futures_util::future::{select, Either};
use std::future::Future;
use std::pin::pin;

/// Matches the runtime's six-concurrent-connection cap (documented at
/// AdAnalysis `analysis.rs`); a chunk of six keeps the drain inside that
/// budget while a hung host can only stall its own chunk.
pub const FEED_POLL_CHUNK_SIZE: usize = 6;

/// Generous for a healthy feed host (p99 well under a few seconds) while
/// keeping one hung host from consuming the whole tick budget.
pub const FEED_FETCH_TIMEOUT_SECONDS: u64 = 12;

/// Races a fetch against a deadline future. A fetch that outlives the
/// deadline is dropped and reported as `timeout_error`, taking the same
/// failure/backoff path as any other failed fetch.
pub async fn fetch_with_deadline<T, E>(
    fetch: impl Future<Output = Result<T, E>>,
    deadline: impl Future<Output = ()>,
    timeout_error: E,
) -> Result<T, E> {
    let fetch = pin!(fetch);
    let deadline = pin!(deadline);
    match select(fetch, deadline).await {
        Either::Left((result, _)) => result,
        Either::Right(((), _)) => Err(timeout_error),
    }
}

/// Applies ±20% jitter to a failure backoff so a herd of feeds that failed
/// together (a host outage, a WAF episode) doesn't retry in lockstep.
/// `random` is a uniform draw in [0, 1), injected so host tests stay
/// deterministic; the result never exceeds `ceiling`. The success-path
/// scheduler (`poll_scheduling`, pure by tested contract) is deliberately
/// untouched — its adaptive divisor already desynchronizes healthy feeds.
pub fn jittered_backoff_seconds(base: i64, ceiling: i64, random: f64) -> i64 {
    let factor = 0.8 + 0.4 * random.clamp(0.0, 1.0);
    let jittered = (base as f64 * factor) as i64;
    jittered.clamp(1, ceiling)
}

/// Splits the due batch into order-preserving chunks of
/// [`FEED_POLL_CHUNK_SIZE`] for bounded-concurrency polling.
pub fn feed_poll_chunks<T>(feeds: Vec<T>) -> Vec<Vec<T>> {
    let mut chunks: Vec<Vec<T>> = Vec::new();
    for feed in feeds {
        match chunks.last_mut() {
            Some(chunk) if chunk.len() < FEED_POLL_CHUNK_SIZE => chunk.push(feed),
            _ => chunks.push(vec![feed]),
        }
    }
    chunks
}

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

/// Catch-up bound: a dormant feed's burst notifies at most this many
/// episodes (the newest ones), delivered oldest-first.
pub const MAX_CATCH_UP_NOTIFICATIONS: usize = 3;

/// Episodes that should notify after a poll, oldest-first. Episodes strictly
/// newer than the stored checkpoint (the parsed page is newest-first) each
/// pass the standard per-episode guards, and more than
/// [`MAX_CATCH_UP_NOTIFICATIONS`] new keeps only the newest. A checkpoint
/// that vanished from the page (GUID churn, rotation) falls back to
/// newest-only — never blast a page because the anchor vanished. A feed with
/// no stored episode id (the admission baseline pass) never notifies.
pub fn episodes_to_notify<'a>(
    feed: &storage::FeedPollRow,
    parsed: &'a rss::ParsedFeed,
) -> Vec<&'a rss::ParsedEpisode> {
    let Some(checkpoint) = feed.latest_episode_id.as_deref() else {
        return Vec::new();
    };

    let candidates: Vec<&rss::ParsedEpisode> = match parsed
        .episodes
        .iter()
        .position(|episode| episode.id == checkpoint)
    {
        Some(index) => parsed.episodes[..index].iter().collect(),
        None => parsed.episodes.first().into_iter().collect(),
    };

    let mut notifiable: Vec<&rss::ParsedEpisode> = candidates
        .into_iter()
        .filter(|episode| changed_episode_should_notify(feed, episode))
        .collect();
    notifiable.truncate(MAX_CATCH_UP_NOTIFICATIONS);
    notifiable.reverse();
    notifiable
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
    use futures_util::FutureExt;

    #[test]
    fn poll_bounds_pin_the_documented_policy() {
        // Chunks of six match the runtime connection cap; 12 s per fetch
        // keeps one hung host inside a bounded slice of the tick budget.
        assert_eq!(FEED_POLL_CHUNK_SIZE, 6);
        assert_eq!(FEED_FETCH_TIMEOUT_SECONDS, 12);
    }

    #[test]
    fn hung_fetch_times_out_onto_the_failure_path() {
        // A fetch that never resolves must not hang the tick: the deadline
        // arm wins and surfaces the caller's timeout error.
        let result = fetch_with_deadline(
            std::future::pending::<Result<&str, &str>>(),
            std::future::ready(()),
            "fetch_timeout",
        )
        .now_or_never();

        assert_eq!(result, Some(Err("fetch_timeout")));
    }

    #[test]
    fn completed_fetch_wins_over_pending_deadline() {
        let result = fetch_with_deadline(
            std::future::ready(Ok::<&str, &str>("body")),
            std::future::pending::<()>(),
            "fetch_timeout",
        )
        .now_or_never();

        assert_eq!(result, Some(Ok("body")));
    }

    #[test]
    fn fetch_error_passes_through_the_deadline_race_unchanged() {
        let result = fetch_with_deadline(
            std::future::ready(Err::<&str, &str>("dns_failure")),
            std::future::pending::<()>(),
            "fetch_timeout",
        )
        .now_or_never();

        assert_eq!(result, Some(Err("dns_failure")));
    }

    #[test]
    fn backoff_jitter_spans_plus_minus_twenty_percent_under_the_ceiling() {
        assert_eq!(jittered_backoff_seconds(1_000, 21_600, 0.0), 800);
        assert_eq!(jittered_backoff_seconds(1_000, 21_600, 0.5), 1_000);
        assert_eq!(jittered_backoff_seconds(1_000, 21_600, 1.0), 1_200);
    }

    #[test]
    fn backoff_jitter_respects_the_ceiling_and_the_floor() {
        // At the ceiling only downward jitter applies.
        assert_eq!(jittered_backoff_seconds(21_600, 21_600, 1.0), 21_600);
        assert_eq!(jittered_backoff_seconds(21_600, 21_600, 0.0), 17_280);
        // A degenerate base never jitters to zero.
        assert_eq!(jittered_backoff_seconds(1, 21_600, 0.0), 1);
    }

    #[test]
    fn feed_poll_chunks_preserve_order_in_chunks_of_six() {
        let chunks = feed_poll_chunks((0..14).collect::<Vec<_>>());

        assert_eq!(
            chunks,
            vec![
                (0..6).collect::<Vec<_>>(),
                (6..12).collect::<Vec<_>>(),
                vec![12, 13],
            ]
        );
    }

    #[test]
    fn feed_poll_chunks_handle_empty_and_exact_batches() {
        assert!(feed_poll_chunks(Vec::<i32>::new()).is_empty());

        let exact = feed_poll_chunks((0..6).collect::<Vec<_>>());
        assert_eq!(exact, vec![(0..6).collect::<Vec<_>>()]);
    }

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
    fn catch_up_notifies_a_burst_oldest_first() {
        let feed = feed_poll_row_with_latest(
            Some("episode-1"),
            Some("Episode 1"),
            Some(1_781_000_000),
            Some(1_780_000_000),
        );
        let parsed = parsed_feed(vec![
            parsed_episode("episode-3", "Episode 3", Some(1_781_200_000)),
            parsed_episode("episode-2", "Episode 2", Some(1_781_100_000)),
            parsed_episode("episode-1", "Episode 1", Some(1_781_000_000)),
        ]);

        let ids: Vec<&str> = episodes_to_notify(&feed, &parsed)
            .iter()
            .map(|episode| episode.id.as_str())
            .collect();
        assert_eq!(ids, vec!["episode-2", "episode-3"]);
    }

    #[test]
    fn dormant_catch_up_keeps_the_three_newest_oldest_first() {
        let feed = feed_poll_row_with_latest(
            Some("episode-1"),
            Some("Episode 1"),
            Some(1_781_000_000),
            Some(1_780_000_000),
        );
        let parsed = parsed_feed(vec![
            parsed_episode("episode-6", "Episode 6", Some(1_781_500_000)),
            parsed_episode("episode-5", "Episode 5", Some(1_781_400_000)),
            parsed_episode("episode-4", "Episode 4", Some(1_781_300_000)),
            parsed_episode("episode-3", "Episode 3", Some(1_781_200_000)),
            parsed_episode("episode-2", "Episode 2", Some(1_781_100_000)),
            parsed_episode("episode-1", "Episode 1", Some(1_781_000_000)),
        ]);

        let ids: Vec<&str> = episodes_to_notify(&feed, &parsed)
            .iter()
            .map(|episode| episode.id.as_str())
            .collect();
        assert_eq!(ids, vec!["episode-4", "episode-5", "episode-6"]);
    }

    #[test]
    fn vanished_checkpoint_falls_back_to_newest_only() {
        let feed = feed_poll_row_with_latest(
            Some("rotated-away"),
            Some("Old Episode"),
            Some(1_781_000_000),
            Some(1_780_000_000),
        );
        let parsed = parsed_feed(vec![
            parsed_episode("episode-9", "Episode 9", Some(1_781_500_000)),
            parsed_episode("episode-8", "Episode 8", Some(1_781_400_000)),
            parsed_episode("episode-7", "Episode 7", Some(1_781_300_000)),
        ]);

        let ids: Vec<&str> = episodes_to_notify(&feed, &parsed)
            .iter()
            .map(|episode| episode.id.as_str())
            .collect();
        assert_eq!(ids, vec!["episode-9"]);
    }

    #[test]
    fn admission_baseline_pass_never_notifies() {
        let feed = feed_poll_row_with_latest(None, None, None, None);
        let parsed = parsed_feed(vec![
            parsed_episode("episode-2", "Episode 2", Some(1_781_100_000)),
            parsed_episode("episode-1", "Episode 1", Some(1_781_000_000)),
        ]);

        assert!(episodes_to_notify(&feed, &parsed).is_empty());
    }

    #[test]
    fn episodes_at_or_behind_the_checkpoint_never_re_notify() {
        // The checkpoint is the newest page entry: nothing is new, including
        // the already-sent checkpoint episode itself and everything older.
        let feed = feed_poll_row_with_latest(
            Some("episode-2"),
            Some("Episode 2"),
            Some(1_781_100_000),
            Some(1_780_000_000),
        );
        let parsed = parsed_feed(vec![
            parsed_episode("episode-2", "Episode 2", Some(1_781_100_000)),
            parsed_episode("episode-1", "Episode 1", Some(1_781_000_000)),
        ]);

        assert!(episodes_to_notify(&feed, &parsed).is_empty());
    }

    #[test]
    fn catch_up_filters_guarded_episodes_and_keeps_the_rest() {
        // A candidate without a pubdate and one published before the
        // baseline both drop; the legitimate one still notifies.
        let feed = feed_poll_row_with_latest(
            Some("episode-1"),
            Some("Episode 1"),
            Some(1_781_000_000),
            Some(1_780_999_000),
        );
        let parsed = parsed_feed(vec![
            parsed_episode("episode-4", "Episode 4", Some(1_781_200_000)),
            parsed_episode("episode-3", "Episode 3", None),
            parsed_episode("episode-backfill", "Backfill", Some(1_780_000_000)),
            parsed_episode("episode-1", "Episode 1", Some(1_781_000_000)),
        ]);

        let ids: Vec<&str> = episodes_to_notify(&feed, &parsed)
            .iter()
            .map(|episode| episode.id.as_str())
            .collect();
        assert_eq!(ids, vec!["episode-4"]);
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

    fn parsed_feed(episodes: Vec<rss::ParsedEpisode>) -> rss::ParsedFeed {
        rss::ParsedFeed {
            title: "Catch-up Feed".to_string(),
            website_url: None,
            artwork_url: None,
            episodes,
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
