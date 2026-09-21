use serde::{Deserialize, Serialize};

pub const RECENT_SECONDS: i64 = 72 * 3600;
pub const FUTURE_SECONDS: i64 = 7 * 86400;
pub const CLOCK_SKEW_SECONDS: i64 = 600;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Reason {
    Baseline,
    KnownIdentity,
    IdentityChurn,
    Stale,
    Recent,
    Undated,
    AnomalousDate,
    Future,
}
impl Reason {
    pub fn candidate(self) -> bool {
        matches!(
            self,
            Self::Recent | Self::Undated | Self::AnomalousDate | Self::Future
        )
    }
    pub fn needs_absence(self) -> bool {
        matches!(self, Self::Undated | Self::AnomalousDate)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Decision {
    pub reason: Reason,
    pub eligible_at: i64,
    pub published_at: Option<i64>,
}

/// The first observation, including a conservative unfinished-scan bound, is
/// used only to bound eligibility. Date windows use the actual scan start, so
/// an outage cannot turn already-published episodes into future releases.
pub fn classify(
    baseline: bool,
    known_identity: bool,
    known_fingerprint: bool,
    published_at: Option<i64>,
    first_observed_at: i64,
    scan_started_at: i64,
) -> Decision {
    let mut result = Decision {
        reason: Reason::Undated,
        eligible_at: first_observed_at,
        published_at,
    };
    result.reason = if baseline {
        Reason::Baseline
    } else if known_identity {
        Reason::KnownIdentity
    } else if known_fingerprint {
        Reason::IdentityChurn
    } else if let Some(date) = published_at {
        if date > scan_started_at.saturating_add(FUTURE_SECONDS) {
            result.published_at = None;
            Reason::AnomalousDate
        } else if date > scan_started_at.saturating_add(CLOCK_SKEW_SECONDS) {
            result.eligible_at = date;
            Reason::Future
        } else if date < scan_started_at.saturating_sub(RECENT_SECONDS) {
            Reason::Stale
        } else {
            // A credible release cannot predate its publication. Preserve the
            // near-future clock-skew rule: availability is the current scan.
            result.eligible_at = first_observed_at.max(date.min(scan_started_at));
            Reason::Recent
        }
    } else {
        Reason::Undated
    };
    result
}

/// Publication records absence at poll *start*, never at the later commit.
/// An interest joining during the request gets its own quiet first window.
pub fn recipient_eligible(
    decision: Decision,
    first_observed_at: i64,
    observation_generation: i64,
    activated_at: i64,
    absence: Option<(i64, i64)>,
) -> bool {
    decision.reason.candidate()
        && if decision.reason.needs_absence() {
            activated_at <= first_observed_at
                && absence.is_some_and(|(generation, at)| {
                    generation < observation_generation
                        && at >= activated_at
                        && at <= first_observed_at
                })
        } else {
            activated_at <= decision.eligible_at
                && decision.published_at.is_some_and(|at| at >= activated_at)
        }
}

#[cfg(test)]
mod tests {
    use super::*;
    const NOW: i64 = 1_800_000_000;
    #[test]
    fn policy_boundaries_and_precedence() {
        for date in [None, Some(NOW - 999999), Some(NOW), Some(NOW + 999999)] {
            assert_eq!(
                classify(true, false, false, date, NOW, NOW).reason,
                Reason::Baseline
            );
            assert_eq!(
                classify(false, true, false, date, NOW, NOW).reason,
                Reason::KnownIdentity
            );
            assert_eq!(
                classify(false, false, true, date, NOW, NOW).reason,
                Reason::IdentityChurn
            );
        }
        for (date, reason, eligibility) in [
            (None, Reason::Undated, NOW),
            (Some(NOW - RECENT_SECONDS - 1), Reason::Stale, NOW),
            (Some(NOW - RECENT_SECONDS), Reason::Recent, NOW),
            (Some(NOW + 600), Reason::Recent, NOW),
            (Some(NOW + 601), Reason::Future, NOW + 601),
            (
                Some(NOW + FUTURE_SECONDS),
                Reason::Future,
                NOW + FUTURE_SECONDS,
            ),
            (Some(NOW + FUTURE_SECONDS + 1), Reason::AnomalousDate, NOW),
        ] {
            let d = classify(false, false, false, date, NOW, NOW);
            assert_eq!((d.reason, d.eligible_at), (reason, eligibility));
        }
    }
    #[test]
    fn retry_bound_does_not_move_date_windows_or_hide_post_activation_releases() {
        let bound = NOW - 2 * 86400;
        for (date, reason, eligibility) in [
            (None, Reason::Undated, bound),
            (Some(NOW - RECENT_SECONDS - 1), Reason::Stale, bound),
            (Some(NOW - 3600), Reason::Recent, NOW - 3600),
            (Some(NOW + 600), Reason::Recent, NOW),
            (Some(NOW + 601), Reason::Future, NOW + 601),
            (Some(NOW + 6 * 86400), Reason::Future, NOW + 6 * 86400),
            (
                Some(NOW + FUTURE_SECONDS),
                Reason::Future,
                NOW + FUTURE_SECONDS,
            ),
            (Some(NOW + FUTURE_SECONDS + 1), Reason::AnomalousDate, bound),
        ] {
            let decision = classify(false, false, false, date, bound, NOW);
            assert_eq!(
                (decision.reason, decision.eligible_at),
                (reason, eligibility)
            );
        }
        let recent = classify(false, false, false, Some(NOW - 3600), bound, NOW);
        assert!(recipient_eligible(recent, bound, 2, NOW - 7200, None));
        assert!(!recipient_eligible(recent, bound, 2, NOW - 1800, None));
        let undated = classify(false, false, false, None, bound, NOW);
        assert!(!recipient_eligible(
            undated,
            bound,
            2,
            NOW - 7200,
            Some((1, NOW - 7200))
        ));
        let skew = classify(false, false, false, Some(NOW + 600), bound, NOW);
        assert!(!recipient_eligible(skew, bound, 2, NOW + 1, None));
    }

    #[test]
    fn interest_time_uses_publication_or_prior_absence() {
        let dated = classify(false, false, false, Some(NOW - 60), NOW, NOW);
        assert!(recipient_eligible(dated, NOW, 2, NOW - 60, None));
        assert!(!recipient_eligible(dated, NOW, 2, NOW - 59, None));
        let undated = classify(false, false, false, None, NOW, NOW);
        assert!(recipient_eligible(
            undated,
            NOW,
            2,
            NOW - 60,
            Some((1, NOW - 60))
        ));
        for absence in [
            None,
            Some((2, NOW - 60)),
            Some((1, NOW - 61)),
            Some((1, NOW + 1)),
        ] {
            assert!(!recipient_eligible(undated, NOW, 2, NOW - 60, absence));
        }
        assert!(!recipient_eligible(
            undated,
            NOW,
            2,
            NOW + 1,
            Some((1, NOW))
        ));
    }
}
