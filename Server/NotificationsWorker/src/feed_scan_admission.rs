//! Isolate-wide CPU/memory admission. Owner identities make late or duplicate
//! releases harmless. The only global state is scalar diagnostics and owner
//! IDs, never request I/O, buffers, or futures.
use crate::feed_resource::MAX_ACTIVE_SCANS;
use std::cell::RefCell;
use std::collections::BTreeSet;

thread_local! {
    static ADMISSION: RefCell<AdmissionState> = RefCell::new(AdmissionState::default());
}

#[derive(Default)]
struct AdmissionState {
    next_owner_id: u64,
    active_owner_ids: BTreeSet<u64>,
    abandonment_disposal_depth: usize,
    refused: u32,
    abandoned_recovered: u32,
    stale_releases: u32,
}

#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct FeedScanAdmissionDiagnostics {
    pub(crate) refused: u32,
    pub(crate) abandoned_recovered: u32,
    pub(crate) stale_releases: u32,
}

pub(crate) struct FeedScanPermit {
    owner_id: u64,
}

impl FeedScanPermit {
    pub(crate) fn try_acquire() -> Option<Self> {
        ADMISSION.with(|admission| {
            let mut admission = admission.borrow_mut();
            if admission.active_owner_ids.len() >= MAX_ACTIVE_SCANS {
                admission.refused = admission.refused.saturating_add(1);
                return None;
            }
            admission.next_owner_id = admission.next_owner_id.wrapping_add(1).max(1);
            let owner_id = admission.next_owner_id;
            admission.active_owner_ids.insert(owner_id);
            Some(Self { owner_id })
        })
    }

    pub(crate) fn active_count() -> usize {
        ADMISSION.with(|admission| admission.borrow().active_owner_ids.len())
    }

    pub(crate) fn take_diagnostics() -> FeedScanAdmissionDiagnostics {
        ADMISSION.with(|admission| {
            let mut admission = admission.borrow_mut();
            FeedScanAdmissionDiagnostics {
                refused: std::mem::take(&mut admission.refused),
                abandoned_recovered: std::mem::take(&mut admission.abandoned_recovered),
                stale_releases: std::mem::take(&mut admission.stale_releases),
            }
        })
    }
}

/// Drops all request-owned work inside an explicit abandonment scope. Permit
/// destructors then record capacity recovered by disposal rather than normal
/// completion. The operation is gone before another owner can be admitted.
pub(crate) fn dispose_abandoned<T>(value: T) {
    ADMISSION.with(|admission| {
        admission.borrow_mut().abandonment_disposal_depth += 1;
    });
    drop(value);
    ADMISSION.with(|admission| {
        let mut admission = admission.borrow_mut();
        admission.abandonment_disposal_depth =
            admission.abandonment_disposal_depth.saturating_sub(1);
    });
}

impl Drop for FeedScanPermit {
    fn drop(&mut self) {
        ADMISSION.with(|admission| {
            let mut admission = admission.borrow_mut();
            if admission.active_owner_ids.remove(&self.owner_id) {
                if admission.abandonment_disposal_depth > 0 {
                    admission.abandoned_recovered = admission.abandoned_recovered.saturating_add(1);
                }
            } else {
                // Owner identity prevents a stale handle from decrementing or
                // otherwise corrupting a later owner's capacity.
                admission.stale_releases = admission.stale_releases.saturating_add(1);
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
        let first = FeedScanPermit::try_acquire().unwrap();
        let second = FeedScanPermit::try_acquire().unwrap();
        assert!(FeedScanPermit::try_acquire().is_none());
        drop(first);
        let replacement = FeedScanPermit::try_acquire().unwrap();
        assert!(FeedScanPermit::try_acquire().is_none());
        drop((second, replacement));
        assert_eq!(FeedScanPermit::active_count(), 0);
        assert!(FeedScanPermit::try_acquire().is_some());
    }

    #[test]
    fn abandonment_disposes_owner_before_capacity_is_reused() {
        let _ = FeedScanPermit::take_diagnostics();
        let first = FeedScanPermit::try_acquire().unwrap();
        let second = FeedScanPermit::try_acquire().unwrap();
        dispose_abandoned((first, second));
        assert_eq!(FeedScanPermit::active_count(), 0);
        let diagnostics = FeedScanPermit::take_diagnostics();
        assert_eq!(diagnostics.abandoned_recovered, 2);
        let replacement = FeedScanPermit::try_acquire().unwrap();
        assert_eq!(FeedScanPermit::active_count(), 1);
        drop(replacement);
    }
}
