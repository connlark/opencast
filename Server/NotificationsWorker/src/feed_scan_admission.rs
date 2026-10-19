//! Isolate-wide scan admission. Owner identities make late releases harmless.
//! No request I/O, buffers, or futures are stored here.
use crate::feed_resource::MAX_ACTIVE_SCANS;
use std::{cell::RefCell, collections::BTreeMap};

pub(crate) const PERMIT_RECLAIM_SECONDS: i64 = 240;

thread_local! {
    static ADMISSION: RefCell<AdmissionState> = RefCell::new(AdmissionState::default());
    #[cfg(test)]
    static TEST_NOW: std::cell::Cell<Option<i64>> = const { std::cell::Cell::new(None) };
}

#[derive(Clone)]
struct Owner {
    acquired_at: i64,
    step: &'static str,
    delivery: Option<Delivery>,
}

/// The Queue delivery a queued owner serves: its message id and attempt.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Delivery {
    pub(crate) message: String,
    pub(crate) attempt: u32,
}

struct AdmissionState {
    isolate: u64,
    next_owner_id: u64,
    owners: BTreeMap<u64, Owner>,
    abandonment_disposal_depth: usize,
    refused: u32,
    abandoned_recovered: u32,
    stale_releases: u32,
    reclaimed: u32,
}

impl Default for AdmissionState {
    fn default() -> Self {
        Self {
            isolate: isolate_id(),
            next_owner_id: 0,
            owners: BTreeMap::new(),
            abandonment_disposal_depth: 0,
            refused: 0,
            abandoned_recovered: 0,
            stale_releases: 0,
            reclaimed: 0,
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn isolate_id() -> u64 {
    (worker::js_sys::Math::random() * ((1_u64 << 53) as f64)) as u64
}
#[cfg(not(target_arch = "wasm32"))]
fn isolate_id() -> u64 {
    1
}

#[cfg(target_arch = "wasm32")]
fn now_seconds() -> i64 {
    (worker::Date::now().as_millis() / 1000) as i64
}
#[cfg(not(target_arch = "wasm32"))]
fn now_seconds() -> i64 {
    #[cfg(test)]
    if let Some(t) = TEST_NOW.with(|clock| clock.get()) {
        return t;
    }
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("system clock before epoch")
        .as_secs() as i64
}

#[cfg(test)]
fn set_test_now(t: Option<i64>) {
    TEST_NOW.with(|clock| clock.set(t));
}

#[derive(Debug, Clone, Copy)]
#[allow(dead_code)]
pub(crate) struct PermitView {
    pub(crate) active_permits: usize,
    pub(crate) oldest_permit_age_seconds: i64,
    pub(crate) holder_step: Option<&'static str>,
    pub(crate) isolate: u64,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct FeedScanAdmissionDiagnostics {
    pub(crate) refused: u32,
    pub(crate) abandoned_recovered: u32,
    pub(crate) stale_releases: u32,
    pub(crate) reclaimed: u32,
}

pub(crate) struct FeedScanPermit {
    owner_id: u64,
}
#[allow(dead_code)]
pub(crate) struct ExclusiveAcquisition {
    pub(crate) permits: Vec<FeedScanPermit>,
    pub(crate) reclaimed: u32,
}

impl FeedScanPermit {
    fn reclaim(state: &mut AdmissionState, t: i64) -> u32 {
        let isolate = state.isolate;
        let mut expired = Vec::new();
        state.owners.retain(|_, owner| {
            let age = t.saturating_sub(owner.acquired_at);
            if age >= PERMIT_RECLAIM_SECONDS {
                expired.push((age, owner.step));
                false
            } else {
                true
            }
        });
        let count = expired.len() as u32;
        state.reclaimed = state.reclaimed.saturating_add(count);
        #[cfg(target_arch = "wasm32")]
        for (age, step) in expired {
            worker::console_warn!(
                "{}",
                serde_json::json!({"event":"scan_permit_reclaimed","owner_age_seconds":age,"holder_step":step,"isolate":isolate,"wasm_memory_bytes":crate::runtime_diagnostics::current().wasm_memory_bytes})
            );
        }
        #[cfg(not(target_arch = "wasm32"))]
        let _ = (isolate, expired);
        count
    }
    /// The Queue redelivers a message only after its previous delivery ended
    /// unacknowledged, and a cancelled invocation is never polled again, so an
    /// owner left by an earlier attempt of the same message is dead.
    fn reclaim_redelivered(state: &mut AdmissionState, t: i64, delivery: &Delivery) -> u32 {
        let isolate = state.isolate;
        let mut dead = Vec::new();
        state.owners.retain(|_, owner| {
            let earlier = owner.delivery.as_ref().is_some_and(|previous| {
                previous.message == delivery.message && previous.attempt < delivery.attempt
            });
            if earlier {
                dead.push((t.saturating_sub(owner.acquired_at), owner.step));
            }
            !earlier
        });
        let count = dead.len() as u32;
        state.reclaimed = state.reclaimed.saturating_add(count);
        #[cfg(target_arch = "wasm32")]
        for (age, step) in dead {
            worker::console_warn!(
                "{}",
                serde_json::json!({"event":"scan_permit_reclaimed","reason":"redelivered","owner_age_seconds":age,"holder_step":step,"isolate":isolate,"wasm_memory_bytes":crate::runtime_diagnostics::current().wasm_memory_bytes})
            );
        }
        #[cfg(not(target_arch = "wasm32"))]
        let _ = (isolate, dead);
        count
    }
    fn insert(
        state: &mut AdmissionState,
        t: i64,
        step: &'static str,
        delivery: Option<&Delivery>,
    ) -> Self {
        state.next_owner_id = state.next_owner_id.wrapping_add(1).max(1);
        let owner_id = state.next_owner_id;
        state.owners.insert(
            owner_id,
            Owner {
                acquired_at: t,
                step,
                delivery: delivery.cloned(),
            },
        );
        Self { owner_id }
    }
    #[allow(dead_code)]
    pub(crate) fn try_acquire(step: &'static str) -> Option<Self> {
        ADMISSION.with(|admission| {
            let mut state = admission.borrow_mut();
            let t = now_seconds();
            Self::reclaim(&mut state, t);
            if state.owners.len() >= MAX_ACTIVE_SCANS {
                state.refused = state.refused.saturating_add(1);
                return None;
            }
            Some(Self::insert(&mut state, t, step, None))
        })
    }
    #[allow(dead_code)]
    pub(crate) fn try_acquire_exclusive(step: &'static str) -> Option<ExclusiveAcquisition> {
        Self::try_acquire_exclusive_for(step, None)
    }
    /// A queued delivery's owners carry its identity, so its redelivery can
    /// reclaim them through `reclaim_earlier_attempts`.
    pub(crate) fn try_acquire_exclusive_for(
        step: &'static str,
        delivery: Option<&Delivery>,
    ) -> Option<ExclusiveAcquisition> {
        ADMISSION.with(|admission| {
            let mut state = admission.borrow_mut();
            let t = now_seconds();
            let reclaimed = Self::reclaim(&mut state, t);
            if !state.owners.is_empty() {
                state.refused = state.refused.saturating_add(1);
                return None;
            }
            let permits = (0..MAX_ACTIVE_SCANS)
                .map(|_| Self::insert(&mut state, t, step, delivery))
                .collect();
            Some(ExclusiveAcquisition { permits, reclaimed })
        })
    }
    /// Frees the owners this delivery's earlier attempts left, before it routes,
    /// so a redelivery that never asks for a permit still frees them.
    pub(crate) fn reclaim_earlier_attempts(delivery: &Delivery) -> u32 {
        ADMISSION.with(|admission| {
            let mut state = admission.borrow_mut();
            let t = now_seconds();
            Self::reclaim_redelivered(&mut state, t, delivery)
        })
    }
    #[allow(dead_code)]
    pub(crate) fn active_count() -> usize {
        ADMISSION.with(|admission| admission.borrow().owners.len())
    }
    pub(crate) fn view() -> PermitView {
        ADMISSION.with(|admission| {
            let state = admission.borrow();
            let oldest = state.owners.values().min_by_key(|owner| owner.acquired_at);
            PermitView {
                active_permits: state.owners.len(),
                oldest_permit_age_seconds: oldest
                    .map(|owner| now_seconds().saturating_sub(owner.acquired_at))
                    .unwrap_or(0),
                holder_step: oldest.map(|owner| owner.step),
                isolate: state.isolate,
            }
        })
    }
    pub(crate) fn diagnostics() -> FeedScanAdmissionDiagnostics {
        ADMISSION.with(|admission| {
            let state = admission.borrow();
            FeedScanAdmissionDiagnostics {
                refused: state.refused,
                abandoned_recovered: state.abandoned_recovered,
                stale_releases: state.stale_releases,
                reclaimed: state.reclaimed,
            }
        })
    }
    #[cfg(test)]
    pub(crate) fn take_diagnostics() -> FeedScanAdmissionDiagnostics {
        ADMISSION.with(|admission| {
            let mut state = admission.borrow_mut();
            let value = FeedScanAdmissionDiagnostics {
                refused: state.refused,
                abandoned_recovered: state.abandoned_recovered,
                stale_releases: state.stale_releases,
                reclaimed: state.reclaimed,
            };
            state.refused = 0;
            state.abandoned_recovered = 0;
            state.stale_releases = 0;
            state.reclaimed = 0;
            value
        })
    }
}

/// Polls `acquire` every `step_ms` until it succeeds or `patience_ms` of sleep
/// has passed. A stalled owner will not release within any patience, so the
/// waiter refuses at once. The sleep is the caller's, so host tests can drive
/// the clock.
pub(crate) async fn wait_for_exclusive<T, A, W, S, F>(
    patience_ms: u64,
    step_ms: u64,
    mut acquire: A,
    mut stalled: W,
    mut sleep: S,
) -> Option<T>
where
    A: FnMut() -> Option<T>,
    W: FnMut() -> bool,
    S: FnMut(u64) -> F,
    F: std::future::Future<Output = ()>,
{
    let mut waited = 0;
    loop {
        if let Some(acquisition) = acquire() {
            return Some(acquisition);
        }
        if waited >= patience_ms || stalled() {
            return None;
        }
        sleep(step_ms).await;
        waited += step_ms;
    }
}

/// Drops request-owned work in an explicit abandonment scope.
pub(crate) fn dispose_abandoned<T>(value: T) {
    ADMISSION.with(|admission| admission.borrow_mut().abandonment_disposal_depth += 1);
    drop(value);
    ADMISSION.with(|admission| {
        let mut state = admission.borrow_mut();
        state.abandonment_disposal_depth = state.abandonment_disposal_depth.saturating_sub(1);
    });
}

impl Drop for FeedScanPermit {
    fn drop(&mut self) {
        ADMISSION.with(|admission| {
            let mut state = admission.borrow_mut();
            if state.owners.remove(&self.owner_id).is_some() {
                if state.abandonment_disposal_depth > 0 {
                    state.abandoned_recovered = state.abandoned_recovered.saturating_add(1);
                }
            } else {
                state.stale_releases = state.stale_releases.saturating_add(1);
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn overlapping_requests_share_two_slots_and_owner_drop_releases_them() {
        let _ = FeedScanPermit::take_diagnostics();
        let first = FeedScanPermit::try_acquire("scan").unwrap();
        let second = FeedScanPermit::try_acquire("scan").unwrap();
        assert!(FeedScanPermit::try_acquire("scan").is_none());
        drop(first);
        let replacement = FeedScanPermit::try_acquire("scan").unwrap();
        assert!(FeedScanPermit::try_acquire("scan").is_none());
        drop((second, replacement));
        assert_eq!(FeedScanPermit::active_count(), 0);
    }
    #[test]
    fn complete_observation_reserves_the_whole_scan_budget() {
        let ordinary = FeedScanPermit::try_acquire("scan").unwrap();
        assert!(FeedScanPermit::try_acquire_exclusive("prepare").is_none());
        drop(ordinary);
        let observation = FeedScanPermit::try_acquire_exclusive("prepare").unwrap();
        assert!(FeedScanPermit::try_acquire("scan").is_none());
        drop(observation);
        assert_eq!(FeedScanPermit::active_count(), 0);
    }
    #[test]
    fn abandonment_disposes_owner_before_capacity_is_reused() {
        let _ = FeedScanPermit::take_diagnostics();
        let first = FeedScanPermit::try_acquire("scan").unwrap();
        let second = FeedScanPermit::try_acquire("scan").unwrap();
        dispose_abandoned((first, second));
        assert_eq!(FeedScanPermit::active_count(), 0);
        assert_eq!(FeedScanPermit::take_diagnostics().abandoned_recovered, 2);
        let replacement = FeedScanPermit::try_acquire("scan").unwrap();
        assert_eq!(FeedScanPermit::active_count(), 1);
        drop(replacement);
    }
    #[test]
    fn leaked_owner_is_reclaimed_at_240_seconds_and_late_drop_is_stale() {
        let _ = FeedScanPermit::take_diagnostics();
        set_test_now(Some(1000));
        let leaked = FeedScanPermit::try_acquire_exclusive("scan").unwrap();
        set_test_now(Some(1239));
        assert!(FeedScanPermit::try_acquire_exclusive("prepare").is_none());
        assert_eq!(FeedScanPermit::view().oldest_permit_age_seconds, 239);
        set_test_now(Some(1240));
        let replacement = FeedScanPermit::try_acquire_exclusive("prepare").unwrap();
        assert_eq!(replacement.reclaimed, 2);
        drop(leaked);
        assert_eq!(FeedScanPermit::active_count(), 2);
        assert_eq!(FeedScanPermit::diagnostics().stale_releases, 2);
        drop(replacement);
        assert_eq!(FeedScanPermit::active_count(), 0);
        set_test_now(None);
    }
    /// Runs the queued waiter against a holder `owner_age` seconds old that
    /// releases after `hold_ms` on a clock that only the waiter's sleeps
    /// advance. Returns whether it acquired and how long it slept.
    fn queued_wait_from(patience_ms: u64, hold_ms: u64, owner_age: i64) -> (bool, u64) {
        use std::cell::{Cell, RefCell};
        use std::future::Future;
        use std::task::{Context, Poll};
        set_test_now(Some(1000));
        let holder = RefCell::new(FeedScanPermit::try_acquire_exclusive("scan"));
        assert!(holder.borrow().is_some());
        set_test_now(Some(1000 + owner_age));
        let clock = Cell::new(0);
        let waiter = wait_for_exclusive(
            patience_ms,
            100,
            || FeedScanPermit::try_acquire_exclusive("scan"),
            || {
                FeedScanPermit::view().oldest_permit_age_seconds
                    >= crate::polling::policy::STALLED_OWNER_SECONDS
            },
            |ms| {
                clock.set(clock.get() + ms);
                if clock.get() >= hold_ms {
                    holder.borrow_mut().take();
                }
                std::future::ready(())
            },
        );
        let waker = futures_util::task::noop_waker();
        let Poll::Ready(acquired) = std::pin::pin!(waiter).poll(&mut Context::from_waker(&waker))
        else {
            panic!("the waiter's sleeps are always ready");
        };
        let admitted = acquired.is_some();
        drop((acquired, holder));
        assert_eq!(FeedScanPermit::active_count(), 0);
        set_test_now(None);
        (admitted, clock.get())
    }
    fn queued_wait(patience_ms: u64, hold_ms: u64) -> bool {
        queued_wait_from(patience_ms, hold_ms, 0).0
    }
    #[test]
    fn stalled_owner_is_refused_without_waiting() {
        let patience = crate::polling::policy::SCAN_PERMIT_WAIT_MS;
        // A leaked owner (61-239 s in a rehearsal) never releases within any patience.
        assert_eq!(queued_wait_from(patience, u64::MAX, 61), (false, 0));
        assert_eq!(queued_wait_from(patience, u64::MAX, 60), (false, 0));
        // A live owner younger than the threshold is still waited for.
        assert_eq!(queued_wait_from(patience, 500, 59), (true, 500));
    }
    #[test]
    fn queued_scan_waits_out_measured_holds() {
        // Measured: the PostgreSQL baseline hold p95, the D1
        // production-size maximum and the largest contention wait.
        for hold_ms in [6_165, 8_050, 9_366] {
            assert!(
                queued_wait(crate::polling::policy::SCAN_PERMIT_WAIT_MS, hold_ms),
                "a {hold_ms} ms hold must be waited out"
            );
            assert!(
                !queued_wait(3_000, hold_ms),
                "the old 3 s patience refuses it"
            );
        }
        assert!(!queued_wait(
            crate::polling::policy::SCAN_PERMIT_WAIT_MS,
            10_100
        ));
        assert!(!queued_wait(0, 100), "a direct caller never waits");
    }
    #[test]
    fn redelivery_reclaims_the_owner_its_earlier_attempt_left() {
        let _ = FeedScanPermit::take_diagnostics();
        let first = Delivery {
            message: "m1".into(),
            attempt: 1,
        };
        // A cancelled attempt's owner is never dropped (as in a rehearsal ramp).
        let leaked = FeedScanPermit::try_acquire_exclusive_for("scan", Some(&first)).unwrap();
        // Another message, the same attempt again and a direct caller still wait.
        let other = Delivery {
            message: "m2".into(),
            attempt: 2,
        };
        for delivery in [&other, &first] {
            assert_eq!(FeedScanPermit::reclaim_earlier_attempts(delivery), 0);
        }
        for delivery in [Some(&other), Some(&first), None] {
            assert!(FeedScanPermit::try_acquire_exclusive_for("scan", delivery).is_none());
        }
        let retry = Delivery {
            message: "m1".into(),
            attempt: 2,
        };
        assert_eq!(FeedScanPermit::reclaim_earlier_attempts(&retry), 2);
        assert_eq!(FeedScanPermit::active_count(), 0);
        assert_eq!(FeedScanPermit::diagnostics().reclaimed, 2);
        let replacement = FeedScanPermit::try_acquire_exclusive_for("scan", Some(&retry))
            .expect("the redelivery's earlier attempt no longer holds the permits");
        assert_eq!(replacement.reclaimed, 0);
        assert_eq!(FeedScanPermit::active_count(), 2);
        drop(leaked);
        assert_eq!(FeedScanPermit::active_count(), 2);
        assert_eq!(FeedScanPermit::diagnostics().stale_releases, 2);
        drop(replacement);
        assert_eq!(FeedScanPermit::active_count(), 0);
    }
    #[test]
    fn live_owner_is_not_evicted() {
        set_test_now(Some(1000));
        let live = FeedScanPermit::try_acquire_exclusive("scan").unwrap();
        set_test_now(Some(1199));
        assert!(FeedScanPermit::try_acquire_exclusive("scan").is_none());
        assert_eq!(FeedScanPermit::active_count(), 2);
        drop(live);
        set_test_now(None);
    }
}
