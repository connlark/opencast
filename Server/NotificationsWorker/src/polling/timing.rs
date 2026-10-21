//! Request-local wall timings survive dropping a timed-out future. These are
//! diagnostics only and never write durable state or identify a subscriber;
//! `Storage`'s time also bounds a queued scan's publisher.
use std::{
    cell::{Cell, RefCell},
    rc::Rc,
};

pub fn now_ms() -> u64 {
    worker::Date::now().as_millis()
}
#[derive(Clone, Default)]
pub struct Timings {
    pub origin: Rc<RefCell<Option<String>>>,
    pub claim: Rc<Cell<u64>>,
    pub publisher: Rc<Cell<u64>>,
    pub sink: Rc<Cell<u64>>,
    /// How a `not_modified` poll was proved when it was not a 304.
    pub via: Rc<Cell<Option<&'static str>>>,
    /// Parses of the response body: 1 for a probe or a single full pass, 2
    /// when a changed probe replayed it; 0 when no body was parsed.
    pub passes: Rc<Cell<u8>>,
    /// The storage timing witness's handle (inert unless the step has one).
    pub witness: crate::storage_witness::Timer,
}
impl Timings {
    pub fn publisher_span(&self) -> Span {
        let mut span = Span::new(self.publisher.clone(), Some(self.sink.clone()));
        span.witness = Some(
            self.witness
                .span(crate::storage_witness::Category::Publisher),
        );
        span
    }
}
/// A scan's storage flag and the time it has been set, a write still pending
/// included. It reads `performance.now()`, never the `Date` tests freeze and
/// jump, because the queued publisher deadline leaves this time out.
#[derive(Clone, Default)]
pub struct Storage {
    since: Rc<Cell<Option<f64>>>,
    spent: Rc<Cell<f64>>,
}
impl Storage {
    pub fn set(&self, pending: bool) {
        match (self.since.get(), pending) {
            (None, true) => self.since.set(Some(monotonic_ms())),
            (Some(since), false) => {
                self.spent.set(self.spent.get() + (monotonic_ms() - since));
                self.since.set(None);
            }
            _ => {}
        }
    }
    pub fn get(&self) -> bool {
        self.since.get().is_some()
    }
    pub fn spent_ms(&self) -> f64 {
        self.spent.get() + self.since.get().map_or(0.0, |since| monotonic_ms() - since)
    }
}
pub fn monotonic_ms() -> f64 {
    crate::worker_glue::performance_now_ms()
}
pub struct Span {
    start: u64,
    total: Rc<Cell<u64>>,
    excluded: Option<Rc<Cell<u64>>>,
    excluded_start: u64,
    // The fetch's interval for the witness; recorded when this span drops.
    witness: Option<crate::storage_witness::TimerSpan>,
}
impl Span {
    pub fn new(total: Rc<Cell<u64>>, excluded: Option<Rc<Cell<u64>>>) -> Self {
        let excluded_start = excluded.as_ref().map_or(0, |c| c.get());
        Self {
            start: now_ms(),
            total,
            excluded,
            excluded_start,
            witness: None,
        }
    }
}
impl Drop for Span {
    fn drop(&mut self) {
        let excluded = self
            .excluded
            .as_ref()
            .map_or(0, |c| c.get().saturating_sub(self.excluded_start));
        self.total
            .set(self.total.get() + now_ms().saturating_sub(self.start).saturating_sub(excluded));
    }
}
