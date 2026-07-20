//! Pure poll-interval policy: feeds earn their polling rate from their
//! observed publish cadence instead of a flat constant. No I/O.

/// Base (fastest) poll interval. `worker_app::FEED_POLL_INTERVAL_SECONDS` is
/// defined from this constant; keep the literal only here.
pub const HOT_INTERVAL_SECONDS: i64 = 15 * 60;
/// Approach ramp: interval = time-to-expected-publish / this divisor.
const APPROACH_DIVISOR: i64 = 4;
/// Ceiling for the approach ramp while a cadence prediction is live.
const APPROACH_MAX_INTERVAL_SECONDS: i64 = 6 * 60 * 60;
/// Stay hot this long past the expected publish before declaring the
/// prediction stale and falling back to age tiers.
const PUBLISH_GRACE_SECONDS: i64 = 24 * 60 * 60;
const MIN_CADENCE_SECONDS: i64 = 60 * 60;
const MAX_CADENCE_SECONDS: i64 = 90 * 24 * 60 * 60;
const MIN_CADENCE_GAPS: usize = 3;
const CADENCE_EPISODE_SAMPLE: usize = 10;

/// Age tiers for feeds without a usable cadence prediction.
const RECENT_PUBLISH_AGE_SECONDS: i64 = 2 * 24 * 60 * 60;
const ACTIVE_AGE_SECONDS: i64 = 14 * 24 * 60 * 60;
const QUIET_AGE_SECONDS: i64 = 60 * 24 * 60 * 60;
const ACTIVE_INTERVAL_SECONDS: i64 = 60 * 60;
const QUIET_INTERVAL_SECONDS: i64 = 6 * 60 * 60;
const DORMANT_INTERVAL_SECONDS: i64 = 24 * 60 * 60;
/// No publish date at all: conditional GET keeps the slow lane cheap.
const UNKNOWN_HISTORY_INTERVAL_SECONDS: i64 = QUIET_INTERVAL_SECONDS;

/// Median gap between the newest episode publish timestamps, clamped to
/// `[MIN_CADENCE_SECONDS, MAX_CADENCE_SECONDS]`. Returns `None` when there are
/// fewer than `MIN_CADENCE_GAPS` positive gaps. Input order is not trusted;
/// the vector is sorted in place.
pub fn publish_cadence_seconds(published_at: &mut Vec<i64>) -> Option<i64> {
    published_at.sort_unstable_by(|a, b| b.cmp(a));
    let mut gaps: Vec<i64> = published_at
        .iter()
        .take(CADENCE_EPISODE_SAMPLE)
        .zip(published_at.iter().take(CADENCE_EPISODE_SAMPLE).skip(1))
        .map(|(newer, older)| newer.saturating_sub(*older))
        .filter(|gap| *gap > 0)
        .collect();
    if gaps.len() < MIN_CADENCE_GAPS {
        return None;
    }

    gaps.sort_unstable();
    let middle = gaps.len() / 2;
    let median = if gaps.len() % 2 == 0 {
        (gaps[middle - 1] + gaps[middle]) / 2
    } else {
        gaps[middle]
    };

    Some(median.clamp(MIN_CADENCE_SECONDS, MAX_CADENCE_SECONDS))
}

/// Poll interval for a feed given its learned cadence and latest publish
/// timestamp. Never returns less than `HOT_INTERVAL_SECONDS`.
pub fn poll_interval_seconds(
    cadence: Option<i64>,
    latest_published_at: Option<i64>,
    now: i64,
) -> i64 {
    let Some(latest) = latest_published_at else {
        return UNKNOWN_HISTORY_INTERVAL_SECONDS;
    };

    if let Some(cadence) = cadence {
        let expected = latest.saturating_add(cadence);
        if now <= expected.saturating_add(PUBLISH_GRACE_SECONDS) {
            let time_to_expected = expected.saturating_sub(now);
            if time_to_expected <= 0 {
                return HOT_INTERVAL_SECONDS;
            }
            return (time_to_expected / APPROACH_DIVISOR)
                .clamp(HOT_INTERVAL_SECONDS, APPROACH_MAX_INTERVAL_SECONDS);
        }
        // Expected publish blew past the grace window: the show is
        // off-schedule, so the prediction is stale. Fall through to age tiers.
    }

    let age = now.saturating_sub(latest);
    if age <= RECENT_PUBLISH_AGE_SECONDS {
        HOT_INTERVAL_SECONDS
    } else if age <= ACTIVE_AGE_SECONDS {
        ACTIVE_INTERVAL_SECONDS
    } else if age <= QUIET_AGE_SECONDS {
        QUIET_INTERVAL_SECONDS
    } else {
        DORMANT_INTERVAL_SECONDS
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DAY: i64 = 24 * 60 * 60;
    const WEEK: i64 = 7 * DAY;
    const NOW: i64 = 1_780_000_000;

    fn weekly_pubdates(count: usize) -> Vec<i64> {
        (0..count)
            .map(|index| NOW - WEEK * index as i64)
            .collect()
    }

    #[test]
    fn cadence_is_median_gap_of_weekly_show() {
        let mut published_at = weekly_pubdates(6);

        assert_eq!(publish_cadence_seconds(&mut published_at), Some(WEEK));
    }

    #[test]
    fn cadence_ignores_document_order() {
        let mut sorted = weekly_pubdates(6);
        let mut shuffled = vec![
            sorted[3], sorted[0], sorted[5], sorted[1], sorted[4], sorted[2],
        ];

        assert_eq!(
            publish_cadence_seconds(&mut shuffled),
            publish_cadence_seconds(&mut sorted)
        );
    }

    #[test]
    fn cadence_median_shrugs_off_bonus_drop() {
        // Weekly show with one bonus episode an hour after a main drop.
        let mut published_at = vec![
            NOW,
            NOW - WEEK,
            NOW - WEEK - 60 * 60,
            NOW - 2 * WEEK,
            NOW - 3 * WEEK,
            NOW - 4 * WEEK,
        ];

        assert_eq!(publish_cadence_seconds(&mut published_at), Some(WEEK));
    }

    #[test]
    fn cadence_requires_minimum_positive_gaps() {
        assert_eq!(publish_cadence_seconds(&mut vec![]), None);
        assert_eq!(publish_cadence_seconds(&mut vec![NOW]), None);
        assert_eq!(publish_cadence_seconds(&mut weekly_pubdates(3)), None);
        assert_eq!(
            publish_cadence_seconds(&mut weekly_pubdates(4)),
            Some(WEEK)
        );
    }

    #[test]
    fn cadence_drops_non_positive_gaps_from_bulk_imports() {
        // Four identical timestamps contribute zero-length gaps only.
        let mut published_at = vec![NOW, NOW, NOW, NOW, NOW - WEEK];

        assert_eq!(publish_cadence_seconds(&mut published_at), None);
    }

    #[test]
    fn cadence_clamps_to_floor_and_ceiling() {
        let mut rapid: Vec<i64> = (0..5).map(|index| NOW - 60 * index).collect();
        let mut glacial: Vec<i64> = (0..5).map(|index| NOW - 365 * DAY * index).collect();

        assert_eq!(
            publish_cadence_seconds(&mut rapid),
            Some(MIN_CADENCE_SECONDS)
        );
        assert_eq!(
            publish_cadence_seconds(&mut glacial),
            Some(MAX_CADENCE_SECONDS)
        );
    }

    #[test]
    fn cadence_samples_only_newest_episodes() {
        // Newest 10 episodes are weekly; a legacy daily era beyond the sample
        // window must not drag the median down.
        let mut published_at = weekly_pubdates(10);
        let oldest_sampled = *published_at.last().expect("sample floor");
        published_at.extend((1..30).map(|index| oldest_sampled - DAY * index));

        assert_eq!(publish_cadence_seconds(&mut published_at), Some(WEEK));
    }

    #[test]
    fn interval_without_publish_history_is_quiet_tier() {
        assert_eq!(
            poll_interval_seconds(None, None, NOW),
            UNKNOWN_HISTORY_INTERVAL_SECONDS
        );
        assert_eq!(
            poll_interval_seconds(Some(WEEK), None, NOW),
            UNKNOWN_HISTORY_INTERVAL_SECONDS
        );
    }

    #[test]
    fn interval_is_hot_inside_publish_window_and_grace() {
        // Exactly at the expected publish time.
        assert_eq!(
            poll_interval_seconds(Some(WEEK), Some(NOW - WEEK), NOW),
            HOT_INTERVAL_SECONDS
        );
        // Past expected but inside grace.
        assert_eq!(
            poll_interval_seconds(Some(WEEK), Some(NOW - WEEK - PUBLISH_GRACE_SECONDS), NOW),
            HOT_INTERVAL_SECONDS
        );
    }

    #[test]
    fn interval_ramps_down_as_expected_publish_approaches() {
        // Mid-cycle weekly show: 3.5 days out → capped at the approach max.
        assert_eq!(
            poll_interval_seconds(Some(WEEK), Some(NOW - WEEK / 2), NOW),
            APPROACH_MAX_INTERVAL_SECONDS
        );
        // 8 hours out → 2 hours.
        assert_eq!(
            poll_interval_seconds(Some(WEEK), Some(NOW - WEEK + 8 * 60 * 60), NOW),
            2 * 60 * 60
        );
        // 20 minutes out → floored at hot.
        assert_eq!(
            poll_interval_seconds(Some(WEEK), Some(NOW - WEEK + 20 * 60), NOW),
            HOT_INTERVAL_SECONDS
        );
    }

    #[test]
    fn interval_falls_back_to_age_tiers_after_grace_expires() {
        // One second past grace: cadence is stale; age (8 days) → active tier.
        assert_eq!(
            poll_interval_seconds(
                Some(WEEK),
                Some(NOW - WEEK - PUBLISH_GRACE_SECONDS - 1),
                NOW
            ),
            ACTIVE_INTERVAL_SECONDS
        );
    }

    #[test]
    fn interval_age_tiers_without_cadence() {
        assert_eq!(
            poll_interval_seconds(None, Some(NOW - RECENT_PUBLISH_AGE_SECONDS), NOW),
            HOT_INTERVAL_SECONDS
        );
        assert_eq!(
            poll_interval_seconds(None, Some(NOW - RECENT_PUBLISH_AGE_SECONDS - 1), NOW),
            ACTIVE_INTERVAL_SECONDS
        );
        assert_eq!(
            poll_interval_seconds(None, Some(NOW - ACTIVE_AGE_SECONDS), NOW),
            ACTIVE_INTERVAL_SECONDS
        );
        assert_eq!(
            poll_interval_seconds(None, Some(NOW - ACTIVE_AGE_SECONDS - 1), NOW),
            QUIET_INTERVAL_SECONDS
        );
        assert_eq!(
            poll_interval_seconds(None, Some(NOW - QUIET_AGE_SECONDS), NOW),
            QUIET_INTERVAL_SECONDS
        );
        assert_eq!(
            poll_interval_seconds(None, Some(NOW - QUIET_AGE_SECONDS - 1), NOW),
            DORMANT_INTERVAL_SECONDS
        );
        // Future-dated pubDate stays hot rather than misclassifying as dormant.
        assert_eq!(
            poll_interval_seconds(None, Some(NOW + DAY), NOW),
            HOT_INTERVAL_SECONDS
        );
    }

    #[test]
    fn interval_never_drops_below_hot() {
        let cadences = [None, Some(MIN_CADENCE_SECONDS), Some(WEEK)];
        let latests = [
            None,
            Some(NOW),
            Some(NOW - 30),
            Some(NOW - WEEK),
            Some(NOW - 400 * DAY),
            Some(NOW + DAY),
        ];
        for cadence in cadences {
            for latest in latests {
                assert!(
                    poll_interval_seconds(cadence, latest, NOW) >= HOT_INTERVAL_SECONDS,
                    "cadence={cadence:?} latest={latest:?}"
                );
            }
        }
    }
}
