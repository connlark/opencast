const EPISODE_NOTIFICATION_RETRY_INTERVAL_SECONDS: i64 = 5 * 60;

pub struct FeedPollCompletionInput<'a> {
    pub previous_etag: Option<&'a str>,
    pub previous_last_modified: Option<&'a str>,
    pub previous_episode_id: Option<&'a str>,
    pub previous_episode_title: Option<&'a str>,
    pub previous_episode_published_at: Option<i64>,
    pub fetched_etag: Option<&'a str>,
    pub fetched_last_modified: Option<&'a str>,
    pub fetched_episode_id: &'a str,
    pub fetched_episode_title: &'a str,
    pub fetched_episode_published_at: Option<i64>,
    pub computed_poll_interval_seconds: i64,
    pub retryable_failures: usize,
    pub now: i64,
}

pub struct FeedPollCompletion<'a> {
    pub etag: Option<&'a str>,
    pub last_modified: Option<&'a str>,
    pub latest_episode_id: Option<&'a str>,
    pub latest_episode_title: Option<&'a str>,
    pub latest_episode_published_at: Option<i64>,
    pub next_poll_at: i64,
}

pub fn feed_poll_completion(input: FeedPollCompletionInput<'_>) -> FeedPollCompletion<'_> {
    if input.retryable_failures > 0 {
        // Keep the previous validators as well as the episode checkpoint. If the
        // new validators were stored, the retry poll could receive 304 and never
        // re-enter notification fanout for this episode.
        return FeedPollCompletion {
            etag: input.previous_etag,
            last_modified: input.previous_last_modified,
            latest_episode_id: input.previous_episode_id,
            latest_episode_title: input.previous_episode_title,
            latest_episode_published_at: input.previous_episode_published_at,
            next_poll_at: input
                .now
                .saturating_add(EPISODE_NOTIFICATION_RETRY_INTERVAL_SECONDS),
        };
    }

    FeedPollCompletion {
        etag: input.fetched_etag,
        last_modified: input.fetched_last_modified,
        latest_episode_id: Some(input.fetched_episode_id),
        latest_episode_title: Some(input.fetched_episode_title),
        latest_episode_published_at: input.fetched_episode_published_at,
        next_poll_at: input
            .now
            .saturating_add(input.computed_poll_interval_seconds),
    }
}

pub fn should_disable_device(apns_status: Option<u16>, apns_error: Option<&str>) -> bool {
    apns_status == Some(410)
        || matches!(
            (apns_status, apns_error),
            (
                Some(400),
                Some("BadDeviceToken" | "Unregistered" | "DeviceTokenNotForTopic")
            )
        )
}

pub fn retryable_apns_failure(apns_status: Option<u16>, apns_error: Option<&str>) -> bool {
    matches!(apns_status, Some(429 | 500 | 503))
        || apns_status.is_none()
        || apns_error == Some("fetch_failed")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn completion_input(retryable_failures: usize) -> FeedPollCompletionInput<'static> {
        FeedPollCompletionInput {
            previous_etag: Some("old-etag"),
            previous_last_modified: Some("old-last-modified"),
            previous_episode_id: Some("known-episode"),
            previous_episode_title: Some("Known Episode"),
            previous_episode_published_at: Some(1_781_870_400),
            fetched_etag: Some("new-etag"),
            fetched_last_modified: Some("new-last-modified"),
            fetched_episode_id: "new-episode",
            fetched_episode_title: "New Episode",
            fetched_episode_published_at: Some(1_782_075_600),
            computed_poll_interval_seconds: 15 * 60,
            retryable_failures,
            now: 1_782_100_000,
        }
    }

    #[test]
    fn retryable_apns_failure_classifies_transient_outcomes() {
        assert!(retryable_apns_failure(Some(429), Some("TooManyRequests")));
        assert!(retryable_apns_failure(
            Some(500),
            Some("InternalServerError")
        ));
        assert!(retryable_apns_failure(
            Some(503),
            Some("ServiceUnavailable")
        ));
        assert!(retryable_apns_failure(None, Some("fetch_failed")));
        assert!(!retryable_apns_failure(Some(200), None));
        assert!(!retryable_apns_failure(Some(410), Some("Unregistered")));
        assert!(!retryable_apns_failure(Some(400), Some("BadDeviceToken")));
    }

    #[test]
    fn unregistered_apns_failure_prunes_instead_of_retrying() {
        assert!(should_disable_device(Some(410), Some("Unregistered")));
        assert!(!retryable_apns_failure(Some(410), Some("Unregistered")));
    }

    #[test]
    fn retryable_episode_send_preserves_feed_checkpoint_for_next_cron() {
        let completion = feed_poll_completion(completion_input(1));

        assert_eq!(completion.etag, Some("old-etag"));
        assert_eq!(completion.last_modified, Some("old-last-modified"));
        assert_eq!(completion.latest_episode_id, Some("known-episode"));
        assert_eq!(completion.latest_episode_title, Some("Known Episode"));
        assert_eq!(completion.latest_episode_published_at, Some(1_781_870_400));
        assert_eq!(
            completion.next_poll_at,
            1_782_100_000 + EPISODE_NOTIFICATION_RETRY_INTERVAL_SECONDS
        );
    }

    #[test]
    fn completed_episode_send_commits_fetched_checkpoint() {
        let completion = feed_poll_completion(completion_input(0));

        assert_eq!(completion.etag, Some("new-etag"));
        assert_eq!(completion.last_modified, Some("new-last-modified"));
        assert_eq!(completion.latest_episode_id, Some("new-episode"));
        assert_eq!(completion.latest_episode_title, Some("New Episode"));
        assert_eq!(completion.latest_episode_published_at, Some(1_782_075_600));
        assert_eq!(completion.next_poll_at, 1_782_100_000 + 15 * 60);
    }
}
