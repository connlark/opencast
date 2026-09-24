//! No clock or I/O: successful schedules retain a stable phase, even after outages.
/// One request per origin per consumer isolate. With two Queue consumers the
/// fleet bound is two per origin, without any D1 permit row.
pub const ORIGIN_LIMIT_PER_CONSUMER: usize = 1;
pub const DISPATCH_LIMIT: usize = 400;
/// A dispatched generation is not re-dispatched for this long. It bounds the
/// delay after a lost message; it is never an authority to publish. It must
/// outlive the consumer's Queue retries (three, sixty seconds apart).
pub const DISPATCH_RESERVATION_SECONDS: i64 = 300;
/// A continuation chain that never settles is a handling fault, not a loop.
pub const MAX_STEPS: u32 = 5000;
pub const CLEANUP_INTERVAL_MINUTES: i64 = 15;
/// Healthy polls are sampled; every failure and publication is logged.
pub const SUCCESS_LOG_SAMPLE: u64 = 64;
pub const RETRY_AFTER_MAX_SECONDS: i64 = 86400;
// Queued scans share a tiny consumer budget. Bound a publisher's occupancy;
// private observation deadlines remain unchanged.
pub const SCAN_DEADLINE_SECONDS: u64 = 15;
pub const INACTIVITY_SECONDS: u64 = 5;
pub const STEP_DEADLINE_SECONDS: u64 = 200;
pub const STALL_RECOVERY_COMPLETIONS: i64 = 5;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StallRollup {
    pub completed_last_5min: i64,
    pub healthy_overdue: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StallAlert {
    Armed,
    Onset { stall_since: i64 },
    Hourly { stall_since: i64, hour: i64 },
    Recovery { stall_since: i64 },
}

/// Pure state machine for dispatcher alerts. Durable state is written by the
/// caller before sending; a failed send therefore retries the same idempotency
/// key while `stall_alerted_at` remains zero.
pub fn stall_transition(
    rollup: StallRollup,
    state: &str,
    stall_since: i64,
    stall_alerted_at: i64,
    alert_armed_at: i64,
    now: i64,
    secrets_present: bool,
) -> Option<StallAlert> {
    if !secrets_present {
        return None;
    }
    if alert_armed_at == 0 {
        return Some(StallAlert::Armed);
    }
    let stalled = rollup.completed_last_5min == 0 && rollup.healthy_overdue >= 50;
    if state == "stalled" {
        if rollup.completed_last_5min >= STALL_RECOVERY_COMPLETIONS {
            return Some(StallAlert::Recovery { stall_since });
        }
        if stall_alerted_at == 0 {
            return Some(StallAlert::Onset { stall_since });
        }
        if now.saturating_sub(stall_alerted_at) >= 3600 {
            return Some(StallAlert::Hourly {
                stall_since,
                hour: now.saturating_sub(stall_since).div_euclid(3600),
            });
        }
        return None;
    }
    stalled.then_some(StallAlert::Onset { stall_since: now })
}

pub fn contention_delay(execution: &str) -> i64 {
    5 + (execution
        .bytes()
        .fold(0_u32, |acc, b| acc.wrapping_mul(31).wrapping_add(b as u32))
        % 11) as i64
}

pub fn interval(now: i64, baseline: i64, latest: Option<i64>, cadence: Option<i64>) -> i64 {
    let latest = latest.filter(|t| *t > 0 && *t <= now);
    let active_window = (90 * 86400).max(cadence.unwrap_or(0).min(365 * 86400) * 2);
    if now - baseline < 7 * 86400 || latest.is_some_and(|t| now - t <= active_window) {
        300
    } else if now - latest.unwrap_or(baseline) >= 365 * 86400 {
        3600
    } else {
        1800
    }
}

/// The feed schedule columns a Queue message is fenced and settled against.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ScheduleInputs {
    pub due_at: i64,
    pub baseline_at: Option<i64>,
    pub credible_release_at: Option<i64>,
    pub credible_cadence: Option<i64>,
    pub publish_cadence: Option<i64>,
    pub five_minute: bool,
}
/// Schedule fields committed in the same fenced statement as a poll outcome.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Settle {
    pub due_at: i64,
    pub interval: i64,
    pub outcome: &'static str,
    pub credible_release_at: Option<i64>,
    pub credible_cadence: Option<i64>,
    pub publish_cadence: Option<i64>,
}
/// Every successful poll re-runs the production adaptive policy on live
/// inputs: a 15-minute hot floor, the 1-hour/6-hour/24-hour age tiers and the
/// cadence accelerator. The five-minute policy is a disabled fixture switch.
#[cfg(any(target_arch = "wasm32", test))]
pub fn settle(
    feed_id: &str,
    inputs: &ScheduleInputs,
    now: i64,
    outcome: &'static str,
    observed_release_at: Option<i64>,
    observed_credible_cadence: Option<i64>,
    observed_publish_cadence: Option<i64>,
) -> Settle {
    let release = match (inputs.credible_release_at, observed_release_at) {
        (Some(a), Some(b)) => Some(a.max(b)),
        (a, b) => a.or(b),
    };
    let credible_cadence = observed_credible_cadence.or(inputs.credible_cadence);
    let publish_cadence = observed_publish_cadence.or(inputs.publish_cadence);
    let interval = if inputs.five_minute {
        interval(
            now,
            inputs.baseline_at.unwrap_or(now),
            release,
            credible_cadence,
        )
    } else {
        crate::poll_scheduling::poll_interval_seconds(
            publish_cadence.or(credible_cadence),
            release,
            now,
        )
    };
    Settle {
        due_at: next_due(feed_id, now.max(inputs.due_at), interval),
        interval,
        outcome,
        credible_release_at: observed_release_at.and(release),
        credible_cadence: observed_credible_cadence,
        publish_cadence: observed_publish_cadence,
    }
}
pub fn sampled(feed_id: &str, generation: i64) -> bool {
    let seed = u64::from_str_radix(&feed_id[..feed_id.len().min(8)], 16).unwrap_or(0);
    seed.wrapping_add(generation as u64)
        .is_multiple_of(SUCCESS_LOG_SAMPLE)
}

pub fn next_due(feed_id: &str, now: i64, interval: i64) -> i64 {
    let seed = u64::from_str_radix(&feed_id[..feed_id.len().min(8)], 16).unwrap_or(0);
    // The early jitter is fixed, not accumulated on each successful response.
    let phase = ((seed % interval as u64) as i64 - ((seed >> 16) % 30) as i64).rem_euclid(interval);
    (now - phase).div_euclid(interval) * interval + interval + phase
}

pub fn feed_retry_delay(failures: i64) -> i64 {
    // An unavailable feed must not consume more scan slots than a healthy
    // five-minute feed, even when another publisher keeps the queue busy.
    (300_i64 * (1_i64 << failures.clamp(0, 7))).min(21600)
}

pub fn retry_delay(failures: i64) -> i64 {
    (30_i64 * (1_i64 << failures.clamp(0, 11))).min(21600)
}

pub fn cadence(dates: &[i64]) -> Option<i64> {
    if dates.len() < 4 {
        return None;
    }
    let mut gaps: Vec<_> = dates
        .windows(2)
        .map(|w| w[0] - w[1])
        .filter(|g| *g >= 3600 && *g <= 365 * 86400)
        .collect();
    if gaps.len() < 3 {
        return None;
    }
    gaps.sort_unstable();
    let median = gaps[gaps.len() / 2];
    // A few annual episodes are evidence; wildly irregular gaps are not.
    if gaps
        .iter()
        .filter(|g| **g >= median / 2 && **g <= median * 2)
        .count()
        * 4
        < gaps.len() * 3
    {
        return None;
    }
    Some(median)
}

pub fn retry_after(value: &str, now: i64) -> Option<i64> {
    let value = value.trim();
    if !value.is_empty() && value.bytes().all(|c| c.is_ascii_digit()) {
        return value.parse::<i64>().ok().map(|v| now.saturating_add(v));
    }
    crate::rss::parse_rss_date(value).map(|t| t.max(now))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn active_dormant_and_unknown_do_not_depend_on_popularity() {
        let now = 2000 * 86400;
        assert_eq!(interval(now, now - 6 * 86400, None, None), 300);
        assert_eq!(interval(now, now - 10 * 86400, None, None), 1800);
        assert_eq!(
            interval(
                now,
                now - 500 * 86400,
                Some(now - 200 * 86400),
                Some(120 * 86400)
            ),
            300
        );
        assert_eq!(
            interval(now, now - 500 * 86400, Some(now - 400 * 86400), None),
            3600
        );
        assert_eq!(
            interval(now, now - 500 * 86400, Some(now - 100 * 86400), None),
            1800
        );
        assert_eq!(interval(now, now - 10 * 86400, Some(0), None), 1800);
    }
    #[test]
    fn every_successful_poll_uses_the_adaptive_policy_with_a_fifteen_minute_floor() {
        let now = 2000 * 86400;
        let feed = "0badf00d";
        let at = |release: Option<i64>, cadence: Option<i64>, observed: Option<i64>| {
            settle(
                feed,
                &ScheduleInputs {
                    due_at: now - 10,
                    credible_release_at: release,
                    publish_cadence: cadence,
                    ..Default::default()
                },
                now,
                "unchanged",
                observed,
                None,
                None,
            )
        };
        // Hot for two days, then 1 h / 6 h / 24 h by age; unknown history 6 h.
        assert_eq!(at(Some(now - 3600), None, None).interval, 900);
        assert_eq!(at(Some(now - 3 * 86400), None, None).interval, 3600);
        assert_eq!(at(Some(now - 30 * 86400), None, None).interval, 21600);
        assert_eq!(at(Some(now - 90 * 86400), None, None).interval, 86400);
        assert_eq!(at(None, None, None).interval, 21600);
        // A weekly show ramps back to the floor as its release approaches,
        // and the accelerator never goes below fifteen minutes.
        let weekly = Some(7 * 86400);
        assert_eq!(at(Some(now - 7 * 86400 + 1800), weekly, None).interval, 900);
        assert_eq!(at(Some(now - 6 * 86400), weekly, None).interval, 3600);
        assert_eq!(at(Some(now - 8 * 86400), weekly, None).interval, 900);
        // A matured future date seen on an unchanged body restores the hot tier
        // and is the only case that rewrites the stored release time.
        let matured = at(Some(now - 30 * 86400), None, Some(now - 60));
        assert_eq!(
            (matured.interval, matured.credible_release_at),
            (900, Some(now - 60))
        );
        assert_eq!(at(Some(now - 60), None, None).credible_release_at, None);
        for settled in [at(Some(now - 3600), None, None), matured] {
            assert!(settled.due_at > now && settled.due_at <= now + settled.interval);
        }
        // The disabled fixture switch is the only route to five minutes.
        let five = settle(
            feed,
            &ScheduleInputs {
                five_minute: true,
                baseline_at: Some(now - 86400),
                ..Default::default()
            },
            now,
            "unchanged",
            None,
            None,
            None,
        );
        assert_eq!(five.interval, 300);
        assert_eq!((0..640).filter(|g| sampled(feed, *g)).count(), 10);
    }
    #[test]
    fn schedule_coalesces_outage_without_drift() {
        for i in 0..1000 {
            let feed = format!("{:08x}", (i as u32).wrapping_mul(2654435761));
            let first = next_due(&feed, 1000, 300);
            assert!((1..=300).contains(&(first - 1000)));
            assert_eq!(next_due(&feed, first + 7, 300), first + 300);
            let recovered = next_due(&feed, first + 1800 + 7, 300);
            assert_eq!(recovered, first + 2100);
        }
    }
    #[test]
    fn failed_feeds_do_not_retry_faster_than_healthy_polls() {
        assert_eq!(feed_retry_delay(0), 300);
        assert_eq!(feed_retry_delay(1), 600);
        assert_eq!(feed_retry_delay(2), 1200);
        assert_eq!(feed_retry_delay(100), 21600);
    }

    #[test]
    fn longer_cadence_requires_consistent_evidence() {
        let year = 365 * 86400;
        assert_eq!(cadence(&[4 * year, 3 * year, 2 * year, year]), Some(year));
        assert_eq!(cadence(&[4 * year, 3 * year, 2 * year]), None);
        assert_eq!(
            cadence(&[year, year - 3600, year - 7200, year - 10800, 0]),
            Some(3600)
        );
        assert_eq!(
            cadence(&[year, year - 3600, year - 7200, year / 2, 0]),
            None
        );
    }
    #[test]
    fn publisher_retry_after_seconds_dates_and_bad_values() {
        let t = 1781870400;
        assert_eq!(retry_after(" 120 ", t), Some(t + 120));
        assert_eq!(
            retry_after("Fri, 19 Jun 2026 12:05:00 GMT", t),
            Some(t + 300)
        );
        assert_eq!(retry_after("-1", t), None);
        assert_eq!(retry_after("1.5", t), None);
        assert_eq!(retry_after("garbage", t), None);
        assert!(retry_after("31536000", t).unwrap() > t + RETRY_AFTER_MAX_SECONDS);
        for id in ["a", "b", "uuid-123", "uuid-999"] {
            assert!((5..=15).contains(&contention_delay(id)));
        }
    }

    #[test]
    fn stall_state_machine_has_onset_hourly_recovery_and_armed_hysteresis() {
        let stalled = StallRollup {
            completed_last_5min: 0,
            healthy_overdue: 50,
        };
        assert_eq!(
            stall_transition(stalled, "clear", 0, 0, 1, 100, true),
            Some(StallAlert::Onset { stall_since: 100 })
        );
        assert_eq!(
            stall_transition(stalled, "stalled", 100, 200, 1, 300, true),
            None
        );
        assert_eq!(
            stall_transition(stalled, "stalled", 100, 200, 1, 3800, true),
            Some(StallAlert::Hourly {
                stall_since: 100,
                hour: 1
            })
        );
        assert_eq!(
            stall_transition(
                StallRollup {
                    completed_last_5min: 4,
                    healthy_overdue: 50
                },
                "stalled",
                100,
                200,
                1,
                300,
                true
            ),
            None
        );
        assert_eq!(
            stall_transition(
                StallRollup {
                    completed_last_5min: 5,
                    healthy_overdue: 50
                },
                "stalled",
                100,
                200,
                1,
                300,
                true
            ),
            Some(StallAlert::Recovery { stall_since: 100 })
        );
        assert_eq!(
            stall_transition(stalled, "clear", 0, 0, 0, 100, true),
            Some(StallAlert::Armed)
        );
        assert_eq!(
            stall_transition(stalled, "clear", 0, 0, 0, 100, false),
            None
        );
    }
}
