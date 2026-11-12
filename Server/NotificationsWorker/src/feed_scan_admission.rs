//! Isolate-wide scan admission. Owner identities make late releases harmless.
//! No request I/O, buffers, or futures are stored here.
//!
//! The publisher origin slots live here too: each one belongs to the scan
//! permit owner that took it, and a slot whose owner is gone is dead. Either
//! permit reclaim removes its owners' slots; an origin entry sweeps slots
//! orphaned through any other path; a late `Drop` removes only its own slot.
use crate::feed_resource::MAX_ACTIVE_SCANS;
use crate::polling::policy::ORIGIN_LIMIT_PER_CONSUMER;
use std::{cell::RefCell, collections::BTreeMap};

pub(crate) const PERMIT_RECLAIM_SECONDS: i64 = 240;
// The first permit of an acquisition names its origin slots' owner.
const _: () = assert!(MAX_ACTIVE_SCANS >= 1);

thread_local! {
    static ADMISSION: RefCell<AdmissionState> = RefCell::new(AdmissionState::default());
    #[cfg(test)]
    static TEST_NOW: std::cell::Cell<Option<i64>> = const { std::cell::Cell::new(None) };
    #[cfg(test)]
    static TEST_REPORTED: RefCell<Vec<DeadSlot>> = const { RefCell::new(Vec::new()) };
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
    /// Origin slots by origin key and owning permit owner id, each with its
    /// own acquisition time (the permit's stays on the owner).
    slots: BTreeMap<(String, u64), i64>,
    abandonment_disposal_depth: usize,
    refused: u32,
    abandoned_recovered: u32,
    stale_releases: u32,
    reclaimed: u32,
    /// Late origin slot `Drop`s that found their slot gone; read by the tests
    /// and the fixture build's readout only.
    #[cfg(any(test, feature = "fixture-hooks"))]
    origin_stale_releases: u32,
}

impl Default for AdmissionState {
    fn default() -> Self {
        Self {
            isolate: isolate_id(),
            next_owner_id: 0,
            owners: BTreeMap::new(),
            slots: BTreeMap::new(),
            abandonment_disposal_depth: 0,
            refused: 0,
            abandoned_recovered: 0,
            stale_releases: 0,
            reclaimed: 0,
            #[cfg(any(test, feature = "fixture-hooks"))]
            origin_stale_releases: 0,
        }
    }
}

/// An origin slot removed because its owner is gone, reported after the
/// borrow that removed it.
#[derive(Debug, Clone, PartialEq, Eq)]
struct DeadSlot {
    origin: String,
    slot_age_seconds: i64,
    reason: &'static str,
}

impl AdmissionState {
    /// Removes the slots of the owners a permit reclaim just removed.
    fn remove_slots_of(&mut self, removed: &[u64], t: i64, dead: &mut Vec<DeadSlot>) {
        if removed.is_empty() {
            return;
        }
        self.slots.retain(|(origin, owner), acquired_at| {
            let gone = removed.contains(owner);
            if gone {
                dead.push(DeadSlot {
                    origin: origin.clone(),
                    slot_age_seconds: t.saturating_sub(*acquired_at),
                    reason: "permit_reclaimed",
                });
            }
            !gone
        });
    }
    /// Removes every slot whose owner is no longer a permit owner.
    fn sweep_slots(&mut self, t: i64, dead: &mut Vec<DeadSlot>) {
        let owners = &self.owners;
        self.slots.retain(|(origin, owner), acquired_at| {
            let live = owners.contains_key(owner);
            if !live {
                dead.push(DeadSlot {
                    origin: origin.clone(),
                    slot_age_seconds: t.saturating_sub(*acquired_at),
                    reason: "owner_gone",
                });
            }
            live
        });
    }
}

/// One warn line per removed slot, emitted after the borrow is released.
fn report_dead_slots(isolate: u64, dead: Vec<DeadSlot>) {
    #[cfg(target_arch = "wasm32")]
    for slot in &dead {
        worker::console_warn!(
            "{}",
            serde_json::json!({"event":"origin_slot_reclaimed","origin":slot.origin.get(..16).unwrap_or(&slot.origin),"slot_age_seconds":slot.slot_age_seconds,"reason":slot.reason,"isolate":isolate})
        );
    }
    #[cfg(test)]
    TEST_REPORTED.with(|reported| reported.borrow_mut().extend(dead.iter().cloned()));
    let _ = (isolate, dead);
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
    /// Also removes the reclaimed owners' origin slots; their warn lines are
    /// the caller's to emit after the borrow.
    fn reclaim(state: &mut AdmissionState, t: i64, dead: &mut Vec<DeadSlot>) -> u32 {
        let isolate = state.isolate;
        let mut expired = Vec::new();
        let mut removed = Vec::new();
        state.owners.retain(|&id, owner| {
            let age = t.saturating_sub(owner.acquired_at);
            if age >= PERMIT_RECLAIM_SECONDS {
                expired.push((age, owner.step));
                removed.push(id);
                false
            } else {
                true
            }
        });
        state.remove_slots_of(&removed, t, dead);
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
    fn reclaim_redelivered(
        state: &mut AdmissionState,
        t: i64,
        delivery: &Delivery,
        dead_slots: &mut Vec<DeadSlot>,
    ) -> u32 {
        let isolate = state.isolate;
        let mut dead = Vec::new();
        let mut removed = Vec::new();
        state.owners.retain(|&id, owner| {
            let earlier = owner.delivery.as_ref().is_some_and(|previous| {
                previous.message == delivery.message && previous.attempt < delivery.attempt
            });
            if earlier {
                dead.push((t.saturating_sub(owner.acquired_at), owner.step));
                removed.push(id);
            }
            !earlier
        });
        state.remove_slots_of(&removed, t, dead_slots);
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
        let (permit, isolate, dead) = ADMISSION.with(|admission| {
            let mut state = admission.borrow_mut();
            let t = now_seconds();
            let mut dead = Vec::new();
            Self::reclaim(&mut state, t, &mut dead);
            let permit = if state.owners.len() >= MAX_ACTIVE_SCANS {
                state.refused = state.refused.saturating_add(1);
                None
            } else {
                Some(Self::insert(&mut state, t, step, None))
            };
            (permit, state.isolate, dead)
        });
        report_dead_slots(isolate, dead);
        permit
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
        let (acquisition, isolate, dead) = ADMISSION.with(|admission| {
            let mut state = admission.borrow_mut();
            let t = now_seconds();
            let mut dead = Vec::new();
            let reclaimed = Self::reclaim(&mut state, t, &mut dead);
            let acquisition = if !state.owners.is_empty() {
                state.refused = state.refused.saturating_add(1);
                None
            } else {
                let permits = (0..MAX_ACTIVE_SCANS)
                    .map(|_| Self::insert(&mut state, t, step, delivery))
                    .collect();
                Some(ExclusiveAcquisition { permits, reclaimed })
            };
            (acquisition, state.isolate, dead)
        });
        report_dead_slots(isolate, dead);
        acquisition
    }
    /// Frees the owners this delivery's earlier attempts left, before it routes,
    /// so a redelivery that never asks for a permit still frees them, and
    /// their origin slots with them.
    pub(crate) fn reclaim_earlier_attempts(delivery: &Delivery) -> u32 {
        let (count, isolate, dead) = ADMISSION.with(|admission| {
            let mut state = admission.borrow_mut();
            let t = now_seconds();
            let mut dead = Vec::new();
            let count = Self::reclaim_redelivered(&mut state, t, delivery, &mut dead);
            (count, state.isolate, dead)
        });
        report_dead_slots(isolate, dead);
        count
    }
    /// The owner id this permit holds; an acquisition's first permit names the
    /// owner of its origin slots.
    pub(crate) fn owner_id(&self) -> u64 {
        self.owner_id
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

/// One publisher origin's request slot on this isolate, owned by the scan
/// permit owner that took it. Dropping it, including by cancellation
/// disposal, frees exactly that slot.
pub(crate) struct OriginSlot {
    origin: String,
    owner: u64,
}

/// Why an origin entry was refused. Every cause is logged as the deferral's
/// `consumer_busy` reason: `occupied` (live holders at the limit),
/// `owner_not_live` (the entering owner is not a permit owner) or `duplicate`
/// (the owner already holds this origin's slot).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct OriginRefused {
    pub(crate) cause: &'static str,
    /// The oldest holder's slot age; `None` without a holder.
    pub(crate) holder_slot_age_seconds: Option<i64>,
    pub(crate) isolate: u64,
}

impl OriginSlot {
    /// Takes `origin`'s slot for a live permit owner. Under one borrow it
    /// first sweeps every slot whose owner is gone, then refuses at
    /// `ORIGIN_LIMIT_PER_CONSUMER` live slots; the sweep's warn lines are
    /// emitted after the borrow.
    pub(crate) fn enter(origin: &str, owner: u64) -> Result<Self, OriginRefused> {
        let (entered, isolate, dead) = ADMISSION.with(|admission| {
            let mut state = admission.borrow_mut();
            let t = now_seconds();
            let mut dead = Vec::new();
            state.sweep_slots(t, &mut dead);
            let held = (origin.to_string(), owner);
            let entered = if !state.owners.contains_key(&owner) {
                Err(("owner_not_live", None))
            } else if let Some(&acquired_at) = state.slots.get(&held) {
                Err(("duplicate", Some(t.saturating_sub(acquired_at))))
            } else {
                let holders = state
                    .slots
                    .range((origin.to_string(), 0)..=(origin.to_string(), u64::MAX))
                    .map(|(_, &acquired_at)| acquired_at);
                let (count, oldest) = holders.fold((0, None), |(count, oldest), at| {
                    (count + 1, Some(oldest.map_or(at, |o: i64| o.min(at))))
                });
                if count >= ORIGIN_LIMIT_PER_CONSUMER {
                    Err(("occupied", oldest.map(|at| t.saturating_sub(at))))
                } else {
                    state.slots.insert(held, t);
                    Ok(())
                }
            };
            (entered, state.isolate, dead)
        });
        report_dead_slots(isolate, dead);
        match entered {
            Ok(()) => Ok(Self {
                origin: origin.into(),
                owner,
            }),
            Err((cause, holder_slot_age_seconds)) => Err(OriginRefused {
                cause,
                holder_slot_age_seconds,
                isolate,
            }),
        }
    }
    /// A redirect within the origin keeps its slot; one to another origin
    /// gives up the previous slot first, then enters under the same owner.
    pub(crate) fn hop(
        current: Option<Self>,
        origin: &str,
        owner: u64,
    ) -> Result<Self, OriginRefused> {
        match current {
            Some(slot) if slot.origin == origin => Ok(slot),
            previous => {
                drop(previous);
                Self::enter(origin, owner)
            }
        }
    }
    pub(crate) fn origin(&self) -> &str {
        &self.origin
    }
}

impl Drop for OriginSlot {
    fn drop(&mut self) {
        let held = (std::mem::take(&mut self.origin), self.owner);
        ADMISSION.with(|admission| {
            let mut state = admission.borrow_mut();
            // A reclaimed owner's late drop finds nothing and touches nothing else.
            let stale = state.slots.remove(&held).is_none();
            #[cfg(any(test, feature = "fixture-hooks"))]
            if stale {
                state.origin_stale_releases = state.origin_stale_releases.saturating_add(1);
            }
            #[cfg(not(any(test, feature = "fixture-hooks")))]
            let _ = stale;
        });
    }
}

/// A read-only view of this isolate's origin slots, for tests and the fixture
/// build's `/origin-slots` route only.
#[cfg(any(test, feature = "fixture-hooks"))]
pub(crate) struct OriginSlotsView {
    /// (origin key, owner id, whether the owner is a live permit owner, slot age)
    pub(crate) slots: Vec<(String, u64, bool, i64)>,
    pub(crate) origin_stale_releases: u32,
    pub(crate) isolate: u64,
}

#[cfg(any(test, feature = "fixture-hooks"))]
pub(crate) fn origin_slots() -> OriginSlotsView {
    ADMISSION.with(|admission| {
        let state = admission.borrow();
        let t = now_seconds();
        OriginSlotsView {
            slots: state
                .slots
                .iter()
                .map(|((origin, owner), &acquired_at)| {
                    (
                        origin.clone(),
                        *owner,
                        state.owners.contains_key(owner),
                        t.saturating_sub(acquired_at),
                    )
                })
                .collect(),
            origin_stale_releases: state.origin_stale_releases,
            isolate: state.isolate,
        }
    })
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

    // The origin slots: the production table and guard, on the permit's clock.
    fn slots() -> Vec<(String, u64)> {
        origin_slots()
            .slots
            .into_iter()
            .map(|(origin, owner, _, _)| (origin, owner))
            .collect()
    }
    fn held(origin: &str, owner: u64) -> (String, u64) {
        (origin.into(), owner)
    }
    fn take_reported() -> Vec<(String, i64, &'static str)> {
        TEST_REPORTED.with(|reported| {
            reported
                .borrow_mut()
                .drain(..)
                .map(|slot| (slot.origin, slot.slot_age_seconds, slot.reason))
                .collect()
        })
    }
    fn first_owner(acquisition: &ExclusiveAcquisition) -> u64 {
        acquisition.permits[0].owner_id()
    }
    fn origin_stale_releases() -> u32 {
        origin_slots().origin_stale_releases
    }
    /// 3(a): a cancelled attempt never drops its origin guard; its redelivery
    /// reclaims the owner, the next entry of that origin under a new owner
    /// succeeds, and the old guard's late drop leaves the replacement's slot.
    #[test]
    fn redelivery_frees_the_origin_slot_its_earlier_attempt_left() {
        set_test_now(Some(1000));
        let first = Delivery {
            message: "m1".into(),
            attempt: 1,
        };
        let leaked = FeedScanPermit::try_acquire_exclusive_for("scan", Some(&first)).unwrap();
        let leaked_slot = OriginSlot::enter("o", first_owner(&leaked)).unwrap();
        set_test_now(Some(1049));
        let retry = Delivery {
            message: "m1".into(),
            attempt: 2,
        };
        assert_eq!(FeedScanPermit::reclaim_earlier_attempts(&retry), 2);
        let replacement = FeedScanPermit::try_acquire_exclusive_for("scan", Some(&retry))
            .expect("the earlier attempt's permits are reclaimed");
        let slot = OriginSlot::enter("o", first_owner(&replacement))
            .expect("the next entry of the origin under the new owner succeeds");
        drop(leaked_slot);
        assert_eq!(
            slots(),
            [held("o", first_owner(&replacement))],
            "the reclaimed owner's late drop leaves the replacement's slot"
        );
        assert_eq!(origin_stale_releases(), 1);
        drop(slot);
        assert!(slots().is_empty());
        drop((leaked, replacement));
        assert_eq!(FeedScanPermit::active_count(), 0);
        set_test_now(None);
    }
    /// 3(b): the same with the owner reclaimed by age: refused at 239 s, the
    /// next exclusive acquisition at 240 s reclaims owner and slot.
    #[test]
    fn age_reclaim_frees_the_origin_slot_with_its_owner() {
        set_test_now(Some(1000));
        let leaked = FeedScanPermit::try_acquire_exclusive("scan").unwrap();
        let leaked_slot = OriginSlot::enter("o", first_owner(&leaked)).unwrap();
        set_test_now(Some(1239));
        assert!(FeedScanPermit::try_acquire_exclusive("scan").is_none());
        assert_eq!(slots(), [held("o", first_owner(&leaked))]);
        set_test_now(Some(1240));
        let replacement = FeedScanPermit::try_acquire_exclusive("scan").unwrap();
        assert_eq!(replacement.reclaimed, 2);
        let slot = OriginSlot::enter("o", first_owner(&replacement))
            .expect("the next entry of the origin under the new owner succeeds");
        drop(leaked_slot);
        assert_eq!(
            slots(),
            [held("o", first_owner(&replacement))],
            "the reclaimed owner's late drop leaves the replacement's slot"
        );
        assert_eq!(origin_stale_releases(), 1);
        drop(slot);
        assert!(slots().is_empty());
        drop((leaked, replacement));
        set_test_now(None);
    }
    /// 3(f): for both triggers the slot goes with the permit at the reclaim
    /// itself, before any origin entry, with its warning.
    #[test]
    fn either_permit_reclaim_removes_its_owners_slots_before_any_entry() {
        set_test_now(Some(1000));
        let first = Delivery {
            message: "m1".into(),
            attempt: 1,
        };
        let leaked = FeedScanPermit::try_acquire_exclusive_for("scan", Some(&first)).unwrap();
        let leaked_slot = OriginSlot::enter("o", first_owner(&leaked)).unwrap();
        set_test_now(Some(1049));
        let retry = Delivery {
            message: "m1".into(),
            attempt: 2,
        };
        assert_eq!(FeedScanPermit::reclaim_earlier_attempts(&retry), 2);
        assert!(
            slots().is_empty(),
            "the redelivery reclaim removes the slot before any origin entry"
        );
        assert_eq!(take_reported(), [("o".into(), 49, "permit_reclaimed")]);
        drop((leaked_slot, leaked));
        set_test_now(Some(2000));
        let aged = FeedScanPermit::try_acquire_exclusive("scan").unwrap();
        let aged_slot = OriginSlot::enter("p", first_owner(&aged)).unwrap();
        set_test_now(Some(2240));
        let replacement = FeedScanPermit::try_acquire_exclusive("scan").unwrap();
        assert!(
            slots().is_empty(),
            "the age reclaim removes the slot before any origin entry"
        );
        assert_eq!(take_reported(), [("p".into(), 240, "permit_reclaimed")]);
        drop((aged_slot, aged, replacement));
        assert_eq!(origin_stale_releases(), 2);
        set_test_now(None);
    }
    /// All three reclaiming callers report the removed slots after their
    /// borrow, the exclusive acquisition's refusal included; the permit
    /// counters still count owners, not slots.
    #[test]
    fn every_reclaiming_caller_reports_its_removed_slots() {
        let _ = FeedScanPermit::take_diagnostics();
        set_test_now(Some(1000));
        let old = FeedScanPermit::try_acquire("scan").unwrap();
        let old_slot = OriginSlot::enter("o", old.owner_id()).unwrap();
        set_test_now(Some(1100));
        let young = FeedScanPermit::try_acquire("scan").unwrap();
        set_test_now(Some(1240));
        assert!(FeedScanPermit::try_acquire_exclusive("prepare").is_none());
        assert!(slots().is_empty());
        assert_eq!(take_reported(), [("o".into(), 240, "permit_reclaimed")]);
        assert_eq!(FeedScanPermit::diagnostics().reclaimed, 1);
        let young_slot = OriginSlot::enter("p", young.owner_id()).unwrap();
        set_test_now(Some(1340));
        let next = FeedScanPermit::try_acquire("scan").unwrap();
        assert!(slots().is_empty());
        assert_eq!(take_reported(), [("p".into(), 100, "permit_reclaimed")]);
        assert_eq!(FeedScanPermit::diagnostics().reclaimed, 2);
        drop((old_slot, young_slot, old, young, next));
        assert_eq!(origin_stale_releases(), 2);
        assert_eq!(FeedScanPermit::diagnostics().stale_releases, 2);
        set_test_now(None);
    }
    /// 3(c): a LIVE owner's slot refuses another live owner (`occupied`) and is
    /// removed neither by the entry sweep nor by a reclaim of another owner.
    #[test]
    fn a_live_owners_slot_is_never_removed() {
        let _ = FeedScanPermit::take_diagnostics();
        set_test_now(Some(1000));
        let other = FeedScanPermit::try_acquire("scan").unwrap();
        let other_slot = OriginSlot::enter("q", other.owner_id()).unwrap();
        set_test_now(Some(1100));
        let live = FeedScanPermit::try_acquire("scan").unwrap();
        let live_slot = OriginSlot::enter("o", live.owner_id()).unwrap();
        let refused = OriginSlot::enter("o", other.owner_id()).err();
        assert_eq!(
            refused,
            Some(OriginRefused {
                cause: "occupied",
                holder_slot_age_seconds: Some(0),
                isolate: 1,
            }),
            "a live holder refuses the second entry of its origin"
        );
        assert_eq!(refused.map(|r| r.isolate), Some(origin_slots().isolate));
        // Another owner reclaimed by age, and a redelivery reclaim that
        // matches no owner, leave the live slot.
        set_test_now(Some(1240));
        let third = FeedScanPermit::try_acquire("scan").unwrap();
        assert_eq!(FeedScanPermit::diagnostics().reclaimed, 1);
        let unrelated = Delivery {
            message: "m9".into(),
            attempt: 5,
        };
        assert_eq!(FeedScanPermit::reclaim_earlier_attempts(&unrelated), 0);
        assert!(
            slots().contains(&held("o", live.owner_id())),
            "another owner's reclaim leaves the live slot"
        );
        // The entry sweep of an unrelated origin leaves it too.
        let third_slot = OriginSlot::enter("p", third.owner_id()).unwrap();
        assert_eq!(
            slots(),
            [held("o", live.owner_id()), held("p", third.owner_id())],
            "neither the sweep nor another owner's reclaim removes the live slot"
        );
        assert_eq!(
            OriginSlot::enter("o", third.owner_id())
                .err()
                .map(|r| r.cause),
            Some("occupied")
        );
        drop(live_slot);
        let admitted =
            OriginSlot::enter("o", third.owner_id()).expect("admitted once the first guard drops");
        drop((admitted, third_slot, other_slot));
        assert!(slots().is_empty());
        assert_eq!(origin_stale_releases(), 1);
        drop((other, live, third));
        set_test_now(None);
    }
    /// 3(d): an owner that is not live is refused (`owner_not_live`, no
    /// holder); a duplicate (origin, owner) is refused (`duplicate`) and the
    /// held record is not overwritten.
    #[test]
    fn entry_needs_a_live_owner_and_never_overwrites_a_held_slot() {
        set_test_now(Some(1000));
        let never = OriginRefused {
            cause: "owner_not_live",
            holder_slot_age_seconds: None,
            isolate: 1,
        };
        assert_eq!(OriginSlot::enter("o", 77).err(), Some(never));
        let permit = FeedScanPermit::try_acquire_exclusive("scan").unwrap();
        let owner = first_owner(&permit);
        let slot = OriginSlot::enter("o", owner).unwrap();
        set_test_now(Some(1007));
        assert_eq!(
            OriginSlot::enter("o", owner).err(),
            Some(OriginRefused {
                cause: "duplicate",
                holder_slot_age_seconds: Some(7),
                isolate: 1,
            })
        );
        assert_eq!(
            origin_slots().slots,
            [("o".to_string(), owner, true, 7)],
            "the held record keeps its acquisition time"
        );
        drop(slot);
        drop(permit);
        assert_eq!(OriginSlot::enter("o", owner).err(), Some(never));
        assert!(slots().is_empty());
        assert_eq!(origin_stale_releases(), 0);
        set_test_now(None);
    }
    /// 3(e): the production hop: a same-origin hop keeps its guard, a
    /// cross-origin hop holds only the destination, and back at the first
    /// origin the intermediate one is released and the first retaken under the
    /// same owner. A refused cross-origin hop has already given up its slot.
    #[test]
    fn redirect_hops_hold_only_the_pending_requests_origin() {
        set_test_now(Some(1000));
        let permit = FeedScanPermit::try_acquire_exclusive("scan").unwrap();
        let owner = first_owner(&permit);
        let slot = OriginSlot::hop(None, "o", owner).unwrap();
        set_test_now(Some(1005));
        let slot = OriginSlot::hop(Some(slot), "o", owner).unwrap();
        assert_eq!(
            origin_slots().slots,
            [("o".to_string(), owner, true, 5)],
            "a same-origin hop keeps its guard"
        );
        let slot = OriginSlot::hop(Some(slot), "p", owner).unwrap();
        assert_eq!(slot.origin(), "p");
        assert_eq!(
            origin_slots().slots,
            [("p".to_string(), owner, true, 0)],
            "a cross-origin hop holds only the destination"
        );
        let slot = OriginSlot::hop(Some(slot), "o", owner).unwrap();
        assert_eq!(
            origin_slots().slots,
            [("o".to_string(), owner, true, 0)],
            "returning releases the intermediate origin and retakes the first"
        );
        drop((slot, permit));
        assert!(slots().is_empty());
        let holder = FeedScanPermit::try_acquire("scan").unwrap();
        let hopping = FeedScanPermit::try_acquire("scan").unwrap();
        let holding = OriginSlot::enter("p", holder.owner_id()).unwrap();
        let slot = OriginSlot::enter("o", hopping.owner_id()).unwrap();
        let refused = OriginSlot::hop(Some(slot), "p", hopping.owner_id()).err();
        assert_eq!(refused.map(|r| r.cause), Some("occupied"));
        assert_eq!(slots(), [held("p", holder.owner_id())]);
        drop((holding, holder, hopping));
        assert!(slots().is_empty());
        assert_eq!(origin_stale_releases(), 0);
        set_test_now(None);
    }
    /// 3(g): the backstop. An ordinary permit drop removes only its owner, so
    /// its retained guard's slot is orphaned; the next entry of ANY origin
    /// sweeps it (`owner_gone`), live slots stay, and its late drop is stale.
    #[test]
    fn entry_sweeps_slots_orphaned_by_any_other_path() {
        set_test_now(Some(1000));
        let gone = FeedScanPermit::try_acquire("scan").unwrap();
        let live = FeedScanPermit::try_acquire("scan").unwrap();
        let gone_owner = gone.owner_id();
        let orphan = OriginSlot::enter("o", gone_owner).unwrap();
        let live_slot = OriginSlot::enter("q", live.owner_id()).unwrap();
        drop(gone);
        assert_eq!(slots(), [held("o", gone_owner), held("q", live.owner_id())]);
        set_test_now(Some(1010));
        let other = FeedScanPermit::try_acquire("scan").unwrap();
        assert!(take_reported().is_empty(), "no permit was reclaimed");
        let entered = OriginSlot::enter("p", other.owner_id()).unwrap();
        assert_eq!(take_reported(), [("o".into(), 10, "owner_gone")]);
        assert_eq!(
            slots(),
            [held("p", other.owner_id()), held("q", live.owner_id())]
        );
        drop(orphan);
        assert_eq!(origin_stale_releases(), 1);
        assert_eq!(
            slots(),
            [held("p", other.owner_id()), held("q", live.owner_id())]
        );
        drop((entered, live_slot, live, other));
        assert!(slots().is_empty());
        set_test_now(None);
    }
}
