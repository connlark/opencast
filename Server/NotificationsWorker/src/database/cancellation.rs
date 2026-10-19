//! A request abort wakes storage without replacing the invocation owner's listener.
use std::{
    cell::RefCell,
    future::Future,
    pin::Pin,
    rc::Rc,
    task::{Context, Poll, Waker},
};
use worker::{
    wasm_bindgen::{closure::Closure, JsCast},
    web_sys::{AbortSignal, Event},
};
pub(super) struct Abort {
    signal: AbortSignal,
    wake: Rc<RefCell<Option<Waker>>>,
    listener: Closure<dyn FnMut(Event)>,
}
impl Abort {
    pub(super) fn new(signal: AbortSignal) -> worker::Result<Self> {
        let wake: Rc<RefCell<Option<Waker>>> = Rc::new(RefCell::new(None));
        let pending = wake.clone();
        let listener = Closure::<dyn FnMut(Event)>::new(move |_| {
            if let Some(waker) = pending.borrow_mut().take() {
                waker.wake();
            }
        });
        signal.add_event_listener_with_callback("abort", listener.as_ref().unchecked_ref())?;
        Ok(Self {
            signal,
            wake,
            listener,
        })
    }
}
impl Future for Abort {
    type Output = ();
    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<()> {
        if self.signal.aborted() {
            return Poll::Ready(());
        }
        *self.wake.borrow_mut() = Some(cx.waker().clone());
        Poll::Pending
    }
}
impl Drop for Abort {
    fn drop(&mut self) {
        let _ = self
            .signal
            .remove_event_listener_with_callback("abort", self.listener.as_ref().unchecked_ref());
    }
}
