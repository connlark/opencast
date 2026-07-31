pub(crate) const MAX_SUBSCRIPTIONS_PER_INSTALL: usize = 200;
pub(crate) const MAX_EXPECTED_PUBLIC_ROLLOUT_INSTALLS_PER_DAY: i64 = 300;
pub(crate) const MAX_NEW_FEED_ADMISSIONS_PER_INSTALL_PER_DAY: i64 =
    MAX_SUBSCRIPTIONS_PER_INSTALL as i64;
pub(crate) const MAX_NEW_FEED_ADMISSIONS_PER_HOST_PER_DAY: i64 = 10_000;
pub(crate) const MAX_GLOBAL_NEW_FEED_ADMISSIONS_PER_DAY: i64 =
    MAX_SUBSCRIPTIONS_PER_INSTALL as i64 * MAX_EXPECTED_PUBLIC_ROLLOUT_INSTALLS_PER_DAY;

const _: () = assert!(MAX_NEW_FEED_ADMISSIONS_PER_INSTALL_PER_DAY == 200);
const _: () = assert!(MAX_GLOBAL_NEW_FEED_ADMISSIONS_PER_DAY == 60_000);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum FeedAdmissionStatus {
    AlreadyKnown,
    New,
}

pub(crate) fn subscription_count_error(count: usize) -> Option<&'static str> {
    if count > MAX_SUBSCRIPTIONS_PER_INSTALL {
        Some("too_many_subscriptions")
    } else {
        None
    }
}

pub(crate) fn feed_admission_error(
    status: FeedAdmissionStatus,
    install_accepted_new_feed_count: i64,
    host_accepted_new_feed_count: i64,
    global_accepted_new_feed_count: i64,
) -> Option<&'static str> {
    if status == FeedAdmissionStatus::AlreadyKnown {
        return None;
    }

    if install_accepted_new_feed_count >= MAX_NEW_FEED_ADMISSIONS_PER_INSTALL_PER_DAY {
        return Some("new_feed_limit_exceeded");
    }
    if host_accepted_new_feed_count >= MAX_NEW_FEED_ADMISSIONS_PER_HOST_PER_DAY {
        return Some("host_new_feed_limit_exceeded");
    }
    if global_accepted_new_feed_count >= MAX_GLOBAL_NEW_FEED_ADMISSIONS_PER_DAY {
        return Some("global_new_feed_limit_exceeded");
    }

    None
}

/// Enqueue-time admission for an unknown feed. A pending enqueue consumes
/// install/host/global budget exactly like the old inline admission did —
/// over-cap feeds reject with the existing error codes before any row is
/// written.
pub(crate) fn admit_pending_enqueue(
    install_accepted: &mut i64,
    host_accepted: &mut i64,
    global_accepted: &mut i64,
) -> std::result::Result<(), &'static str> {
    if let Some(error) = feed_admission_error(
        FeedAdmissionStatus::New,
        *install_accepted,
        *host_accepted,
        *global_accepted,
    ) {
        return Err(error);
    }

    *install_accepted += 1;
    *host_accepted += 1;
    *global_accepted += 1;
    Ok(())
}

/// Full-set reconciliation: a sync request declares the install's entire
/// active set, so every existing subscription absent from `kept` is marked
/// deleted. `kept` includes pending enqueues — a pending feed must never be
/// reconciled away by the request that created it.
pub(crate) fn stale_subscription_urls(
    existing: impl IntoIterator<Item = String>,
    kept: &std::collections::BTreeSet<String>,
) -> Vec<String> {
    existing
        .into_iter()
        .filter(|feed_url| !kept.contains(feed_url))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pending_enqueue_consumes_all_three_budgets() {
        let mut install = 0;
        let mut host = 0;
        let mut global = 0;

        assert_eq!(
            admit_pending_enqueue(&mut install, &mut host, &mut global),
            Ok(())
        );
        assert_eq!((install, host, global), (1, 1, 1));
    }

    #[test]
    fn pending_enqueue_rejects_at_the_install_cap_with_the_existing_code() {
        let mut install = MAX_NEW_FEED_ADMISSIONS_PER_INSTALL_PER_DAY - 1;
        let mut host = 0;
        let mut global = 0;

        assert_eq!(
            admit_pending_enqueue(&mut install, &mut host, &mut global),
            Ok(())
        );
        assert_eq!(
            admit_pending_enqueue(&mut install, &mut host, &mut global),
            Err("new_feed_limit_exceeded")
        );
        // A rejected enqueue consumes nothing.
        assert_eq!(
            (install, host, global),
            (MAX_NEW_FEED_ADMISSIONS_PER_INSTALL_PER_DAY, 1, 1)
        );
    }

    #[test]
    fn pending_enqueue_rejects_at_the_host_and_global_caps() {
        let mut install = 0;
        let mut host = MAX_NEW_FEED_ADMISSIONS_PER_HOST_PER_DAY;
        let mut global = 0;
        assert_eq!(
            admit_pending_enqueue(&mut install, &mut host, &mut global),
            Err("host_new_feed_limit_exceeded")
        );

        let mut install = 0;
        let mut host = 0;
        let mut global = MAX_GLOBAL_NEW_FEED_ADMISSIONS_PER_DAY;
        assert_eq!(
            admit_pending_enqueue(&mut install, &mut host, &mut global),
            Err("global_new_feed_limit_exceeded")
        );
    }

    #[test]
    fn full_set_reconciliation_deletes_exactly_the_absent_urls() {
        let kept: std::collections::BTreeSet<String> = [
            "https://example.com/accepted.xml".to_string(),
            "https://example.com/pending.xml".to_string(),
        ]
        .into();
        let existing = vec![
            "https://example.com/accepted.xml".to_string(),
            "https://example.com/pending.xml".to_string(),
            "https://example.com/unsubscribed.xml".to_string(),
        ];

        assert_eq!(
            stale_subscription_urls(existing, &kept),
            vec!["https://example.com/unsubscribed.xml".to_string()]
        );
    }

    #[test]
    fn full_set_reconciliation_with_an_empty_kept_set_deletes_everything() {
        let kept = std::collections::BTreeSet::new();
        let existing = vec![
            "https://example.com/a.xml".to_string(),
            "https://example.com/b.xml".to_string(),
        ];

        assert_eq!(stale_subscription_urls(existing.clone(), &kept), existing);
    }

    #[test]
    fn new_install_can_admit_more_than_ten_new_feeds() {
        assert_eq!(MAX_NEW_FEED_ADMISSIONS_PER_INSTALL_PER_DAY, 200);
        assert_eq!(
            feed_admission_error(FeedAdmissionStatus::New, 10, 10, 10),
            None
        );
    }

    #[test]
    fn new_install_can_admit_up_to_subscription_ceiling() {
        assert_eq!(
            MAX_NEW_FEED_ADMISSIONS_PER_INSTALL_PER_DAY,
            MAX_SUBSCRIPTIONS_PER_INSTALL as i64
        );
        assert_eq!(
            feed_admission_error(FeedAdmissionStatus::New, 199, 199, 199),
            None
        );
        assert_eq!(
            feed_admission_error(FeedAdmissionStatus::New, 200, 0, 0),
            Some("new_feed_limit_exceeded")
        );
    }

    #[test]
    fn subscription_sync_rejects_two_hundred_first_subscription() {
        assert_eq!(subscription_count_error(200), None);
        assert_eq!(
            subscription_count_error(201),
            Some("too_many_subscriptions")
        );
    }

    #[test]
    fn already_known_feeds_do_not_spend_new_feed_budget() {
        assert_eq!(
            feed_admission_error(
                FeedAdmissionStatus::AlreadyKnown,
                MAX_NEW_FEED_ADMISSIONS_PER_INSTALL_PER_DAY,
                MAX_NEW_FEED_ADMISSIONS_PER_HOST_PER_DAY,
                MAX_GLOBAL_NEW_FEED_ADMISSIONS_PER_DAY,
            ),
            None
        );
    }

    #[test]
    fn raised_host_and_global_circuit_breakers_still_reject() {
        assert_eq!(MAX_NEW_FEED_ADMISSIONS_PER_HOST_PER_DAY, 10_000);
        assert_eq!(MAX_GLOBAL_NEW_FEED_ADMISSIONS_PER_DAY, 60_000);
        assert_eq!(
            feed_admission_error(
                FeedAdmissionStatus::New,
                0,
                MAX_NEW_FEED_ADMISSIONS_PER_HOST_PER_DAY,
                0,
            ),
            Some("host_new_feed_limit_exceeded")
        );
        assert_eq!(
            feed_admission_error(
                FeedAdmissionStatus::New,
                0,
                0,
                MAX_GLOBAL_NEW_FEED_ADMISSIONS_PER_DAY,
            ),
            Some("global_new_feed_limit_exceeded")
        );
    }
}
