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

#[derive(Clone, Copy)]
struct Owner {
    acquired_at: i64,
    step: &'static str,
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
    fn insert(state: &mut AdmissionState, t: i64, step: &'static str) -> Self {
        state.next_owner_id = state.next_owner_id.wrapping_add(1).max(1);
        let owner_id = state.next_owner_id;
        state.owners.insert(
            owner_id,
            Owner {
                acquired_at: t,
                step,
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
            Some(Self::insert(&mut state, t, step))
        })
    }
    pub(crate) fn try_acquire_exclusive(step: &'static str) -> Option<ExclusiveAcquisition> {
        ADMISSION.with(|admission| {
            let mut state = admission.borrow_mut();
            let t = now_seconds();
            let reclaimed = Self::reclaim(&mut state, t);
            if !state.owners.is_empty() {
                state.refused = state.refused.saturating_add(1);
                return None;
            }
            let permits = (0..MAX_ACTIVE_SCANS)
                .map(|_| Self::insert(&mut state, t, step))
                .collect();
            Some(ExclusiveAcquisition { permits, reclaimed })
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
