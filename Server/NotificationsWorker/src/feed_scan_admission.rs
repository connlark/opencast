//! Isolate-wide CPU/memory admission. The only global state is a count, never
//! request I/O or futures. A busy isolate leaves unstarted feeds due.
use crate::feed_resource::MAX_ACTIVE_SCANS;
use std::cell::Cell;

thread_local! { static ACTIVE: Cell<usize> = const { Cell::new(0) }; }

pub(crate) struct FeedScanPermit;

impl FeedScanPermit {
    pub(crate) fn try_acquire() -> Option<Self> {
        ACTIVE.with(|active| {
            if active.get() >= MAX_ACTIVE_SCANS {
                return None;
            }
            active.set(active.get() + 1);
            Some(Self)
        })
    }
}

impl Drop for FeedScanPermit {
    fn drop(&mut self) {
        ACTIVE.with(|active| active.set(active.get() - 1));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn overlapping_requests_share_two_slots_and_drop_releases_them() {
        let first = FeedScanPermit::try_acquire().unwrap();
        let second = FeedScanPermit::try_acquire().unwrap();
        assert!(FeedScanPermit::try_acquire().is_none());
        drop(first);
        let replacement = FeedScanPermit::try_acquire().unwrap();
        assert!(FeedScanPermit::try_acquire().is_none());
        drop((second, replacement));
        assert!(FeedScanPermit::try_acquire().is_some());
    }
}
