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

#[cfg(test)]
mod tests {
    use super::*;

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
