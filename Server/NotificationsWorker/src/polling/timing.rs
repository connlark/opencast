//! Request-local wall timings survive dropping a timed-out future. These are
//! diagnostics only and never write durable state or identify a subscriber.
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
}
impl Timings {
    pub fn publisher_span(&self) -> Span {
        Span::new(self.publisher.clone(), Some(self.sink.clone()))
    }
}
pub struct Span {
    start: u64,
    total: Rc<Cell<u64>>,
    excluded: Option<Rc<Cell<u64>>>,
    excluded_start: u64,
}
impl Span {
    pub fn new(total: Rc<Cell<u64>>, excluded: Option<Rc<Cell<u64>>>) -> Self {
        let excluded_start = excluded.as_ref().map_or(0, |c| c.get());
        Self {
            start: now_ms(),
            total,
            excluded,
            excluded_start,
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
