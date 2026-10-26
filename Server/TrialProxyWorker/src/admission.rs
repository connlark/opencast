//! What the request path hands the ledger: the subject a caller is counted
//! under, the hashed run key, the exchange's time plan and the admission
//! request. Only hashes, numbers and closed enums cross into the ledger.

use opencast_app_attest_core::auth::token_hash;

use crate::bundle::TrialBundle;
use crate::ledger::{AdmitRequest, Lane};
use crate::provider::COUNT_TOKENS_TIMEOUT_MS;
use crate::request::TrialWindow;

/// The exchange ends this long before the device's own budget runs out, so
/// the proxy settles (and frees the lock) before the device gives up.
pub const DEVICE_MARGIN_MS: i64 = 1_000;
/// Kept back after the forward for the settlement and the response.
pub const SETTLE_RESERVE_MS: i64 = 1_500;
/// Below this there is no point forwarding.
pub const MIN_FORWARD_BUDGET_MS: i64 = 2_000;
/// One ledger exchange never waits longer than this.
pub const LEDGER_EXCHANGE_TIMEOUT_MS: i64 = 5_000;
/// A settlement gets at least this long even when the budget is spent: a
/// lost settlement holds the install's lock until the reservation expires.
pub const SETTLE_FLOOR_MS: i64 = 750;

/// Counters key on the authenticated install id: the envelope binds it to
/// the registered key, and the app keeps it when it rotates keys.
pub fn app_attest_subject(install_id: &str) -> String {
    format!("app-attest-install:{}", token_hash(install_id))
}

pub fn bearer_subject(token: &str) -> String {
    format!("bearer:{}", token_hash(token))
}

/// Run ids are stored hashed: an identifier is not content, but nothing a
/// client typed is kept verbatim.
pub fn run_key(run_id: &str) -> String {
    token_hash(run_id)
}

/// When the exchange that started at `started_ms` must end, and how long the
/// count may take.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ExchangePlan {
    pub exchange_end_ms: i64,
    pub count_timeout_ms: u64,
}

pub fn plan(started_ms: i64, call_timeout_seconds: u32) -> ExchangePlan {
    let budget_ms = i64::from(call_timeout_seconds) * 1_000;
    ExchangePlan {
        exchange_end_ms: started_ms + budget_ms - DEVICE_MARGIN_MS,
        count_timeout_ms: COUNT_TOKENS_TIMEOUT_MS.min((budget_ms / 4).max(1) as u64),
    }
}

/// The forward's budget at `now_ms`, or `None` when too little is left to
/// forward at all. Asked before admission (it sizes the reservation's lock)
/// and again after it (it bounds the forward itself).
pub fn forward_budget_ms(plan: ExchangePlan, now_ms: i64) -> Option<u64> {
    let budget = plan.exchange_end_ms - now_ms - SETTLE_RESERVE_MS;
    (budget >= MIN_FORWARD_BUDGET_MS).then_some(budget as u64)
}

/// Admission must answer early enough to leave a minimal forward and the
/// settlement.
pub fn admit_deadline_ms(plan: ExchangePlan) -> i64 {
    plan.exchange_end_ms - SETTLE_RESERVE_MS - MIN_FORWARD_BUDGET_MS
}

/// How long one ledger exchange may wait before `deadline_ms` (`None`: no
/// time left), never less than `floor_ms` when one is given.
pub fn exchange_timeout_ms(deadline_ms: i64, now_ms: i64, floor_ms: i64) -> Option<u64> {
    let left = (deadline_ms - now_ms).max(floor_ms);
    (left > 0).then_some(left.min(LEDGER_EXCHANGE_TIMEOUT_MS) as u64)
}

/// The window `month_paused` asks about: the cheaper feature's (the smaller
/// output cap), with the forward budget its default call gets at `now_ms`,
/// so its lock, price interval and months are the ones its admission would
/// use.
pub fn status_window(bundle: &TrialBundle, now_ms: i64) -> (u32, u64) {
    let entry = if bundle.chapters_summary.max_output_tokens < bundle.ad_detection.max_output_tokens
    {
        &bundle.chapters_summary
    } else {
        &bundle.ad_detection
    };
    let budget = forward_budget_ms(plan(now_ms, entry.per_call_timeout_seconds), now_ms);
    (entry.max_output_tokens, budget.unwrap_or(0))
}

pub fn admit_request(
    reservation_id: String,
    subject: &str,
    lane: Lane,
    window: &TrialWindow,
    bundle: &TrialBundle,
    input_tokens: u64,
    forward_budget_ms: u64,
) -> AdmitRequest {
    AdmitRequest {
        reservation_id,
        subject: subject.to_string(),
        lane,
        run_id: run_key(&window.run_id),
        window_index: window.window_index,
        feature: window.feature,
        model: bundle.model.clone(),
        input_tokens,
        max_output_tokens: window.max_output_tokens,
        forward_budget_ms,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_exchange_ends_before_the_device_budget() {
        let plan = plan(1_000_000, 120);
        assert_eq!(plan.exchange_end_ms, 1_119_000);
        assert_eq!(plan.count_timeout_ms, 10_000);
        assert_eq!(forward_budget_ms(plan, 1_000_500), Some(117_000));
        assert_eq!(forward_budget_ms(plan, 1_116_000), None);
        // Admission must leave a minimal forward and the settlement.
        assert_eq!(admit_deadline_ms(plan), 1_115_500);
        assert_eq!(
            exchange_timeout_ms(admit_deadline_ms(plan), 1_000_000, 0),
            Some(5_000)
        );
        assert_eq!(
            exchange_timeout_ms(admit_deadline_ms(plan), 1_113_000, 0),
            Some(2_500)
        );
        assert_eq!(
            exchange_timeout_ms(admit_deadline_ms(plan), 1_115_500, 0),
            None
        );
        // A settlement always gets its floor.
        assert_eq!(
            exchange_timeout_ms(plan.exchange_end_ms, 1_200_000, SETTLE_FLOOR_MS),
            Some(750)
        );
        // A short device budget shortens the count too.
        assert_eq!(super::plan(0, 8).count_timeout_ms, 2_000);
    }

    #[test]
    fn a_slow_admission_cannot_push_the_exchange_past_the_device_budget() {
        // timeout_seconds 6: the exchange ends at 5,000 ms. Counting took
        // 200 ms; admission took 3,000 ms.
        let plan = plan(0, 6);
        let before = forward_budget_ms(plan, 200).expect("room to admit");
        assert_eq!(before, 3_300);
        let admit_timeout = exchange_timeout_ms(admit_deadline_ms(plan), 200, 0).unwrap();
        assert_eq!(
            admit_timeout, 1_300,
            "admission is cut before it can eat the forward"
        );
        // Whatever admission took, the forward is recomputed afterwards.
        assert_eq!(forward_budget_ms(plan, 1_500), Some(2_000));
        assert_eq!(forward_budget_ms(plan, 1_600), None);
        // Every phase ends by the exchange end, plus at most the settle floor.
        let end = 1_500 + 2_000 + SETTLE_RESERVE_MS.min(LEDGER_EXCHANGE_TIMEOUT_MS);
        assert!(end <= plan.exchange_end_ms);
    }

    #[test]
    fn status_asks_about_the_cheaper_window_with_its_default_budget() {
        let bundle = crate::bundle::embedded().unwrap();
        let (max_output, budget) = status_window(bundle, 1_000_000);
        let entry =
            if bundle.chapters_summary.max_output_tokens < bundle.ad_detection.max_output_tokens {
                &bundle.chapters_summary
            } else {
                &bundle.ad_detection
            };
        assert_eq!(max_output, entry.max_output_tokens);
        assert_eq!(
            budget,
            u64::from(entry.per_call_timeout_seconds) * 1_000
                - DEVICE_MARGIN_MS as u64
                - SETTLE_RESERVE_MS as u64
        );
    }

    #[test]
    fn subjects_hash_their_identifiers() {
        let subject = app_attest_subject("6F9619FF-8B86-D011-B42D-00CF4FC964FF");
        assert!(subject.starts_with("app-attest-install:"));
        assert!(!subject.contains("6F9619FF"));
        assert_eq!(subject.len(), "app-attest-install:".len() + 64);
        assert_ne!(app_attest_subject("a"), app_attest_subject("b"));
        assert_eq!(run_key("run").len(), 64);
        assert!(bearer_subject("token").starts_with("bearer:"));
    }
}
