//! Owns an invocation's Rust future behind a synchronous cancellation handle.
//! An incoming Request AbortSignal can therefore dispose scanner futures and
//! their permits even if the generated promise bridge never polls them again.
use crate::feed_scan_admission;
use std::cell::RefCell;
use std::future::Future;
use std::pin::Pin;
use std::rc::Rc;
use std::task::{Context, Poll, Waker};

struct State<F> {
    future: Option<Pin<Box<F>>>,
    cancelled: bool,
    polling: bool,
    waker: Option<Waker>,
}

pub(crate) struct OwnedInvocation<F> {
    state: Rc<RefCell<State<F>>>,
}

#[derive(Clone)]
pub(crate) struct InvocationCancellation<F> {
    state: Rc<RefCell<State<F>>>,
}

impl<F> OwnedInvocation<F> {
    pub(crate) fn new(future: F) -> (Self, InvocationCancellation<F>) {
        let state = Rc::new(RefCell::new(State {
            future: Some(Box::pin(future)),
            cancelled: false,
            polling: false,
            waker: None,
        }));
        (
            Self {
                state: state.clone(),
            },
            InvocationCancellation { state },
        )
    }
}

impl<F> InvocationCancellation<F> {
    pub(crate) fn cancel(&self) {
        let (future, waker) = {
            let mut state = self.state.borrow_mut();
            if state.cancelled {
                return;
            }
            state.cancelled = true;
            let future = if state.polling {
                None
            } else {
                state.future.take()
            };
            (future, state.waker.take())
        };
        if let Some(future) = future {
            feed_scan_admission::dispose_abandoned(future);
        }
        if let Some(waker) = waker {
            waker.wake();
        }
    }
}

impl<F: Future> Future for OwnedInvocation<F> {
    type Output = Option<F::Output>;

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let mut future = {
            let mut state = self.state.borrow_mut();
            if state.cancelled {
                return Poll::Ready(None);
            }
            state.polling = true;
            state.waker = Some(cx.waker().clone());
            state
                .future
                .take()
                .expect("an owned invocation cannot be polled after completion")
        };

        match future.as_mut().poll(cx) {
            Poll::Ready(output) => {
                let mut state = self.state.borrow_mut();
                state.polling = false;
                state.waker = None;
                Poll::Ready(Some(output))
            }
            Poll::Pending => {
                let abandoned = {
                    let mut state = self.state.borrow_mut();
                    state.polling = false;
                    if state.cancelled {
                        Some(future)
                    } else {
                        state.future = Some(future);
                        None
                    }
                };
                if let Some(future) = abandoned {
                    feed_scan_admission::dispose_abandoned(future);
                    Poll::Ready(None)
                } else {
                    Poll::Pending
                }
            }
        }
    }
}

#[cfg(target_arch = "wasm32")]
pub(crate) async fn run_with_abort_signal<F: Future + 'static>(
    signal: worker::web_sys::AbortSignal,
    future: F,
) -> Option<F::Output> {
    use worker::wasm_bindgen::closure::Closure;
    use worker::wasm_bindgen::JsCast;

    let (owned, cancellation) = OwnedInvocation::new(future);
    if signal.aborted() {
        cancellation.cancel();
        return None;
    }
    let previous_handler = signal.onabort();
    let on_abort = Closure::<dyn FnMut(worker::web_sys::Event)>::new(move |_| {
        cancellation.cancel();
    });
    signal.set_onabort(Some(on_abort.as_ref().unchecked_ref()));
    let output = owned.await;
    signal.set_onabort(previous_handler.as_ref());
    output
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::feed_scan_admission::FeedScanPermit;
    use futures_util::task::noop_waker;
    use std::cell::Cell;

    struct PendingScan {
        _permit: FeedScanPermit,
        dropped: Rc<Cell<bool>>,
    }

    impl Future for PendingScan {
        type Output = ();

        fn poll(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<Self::Output> {
            Poll::Pending
        }
    }

    impl Drop for PendingScan {
        fn drop(&mut self) {
            self.dropped.set(true);
        }
    }

    #[test]
    fn cancellation_synchronously_disposes_pending_scan_and_permit() {
        let _ = FeedScanPermit::take_diagnostics();
        let dropped = Rc::new(Cell::new(false));
        let scan = PendingScan {
            _permit: FeedScanPermit::try_acquire().unwrap(),
            dropped: dropped.clone(),
        };
        let (mut owned, cancellation) = OwnedInvocation::new(scan);
        let waker = noop_waker();
        let mut context = Context::from_waker(&waker);
        assert!(Pin::new(&mut owned).poll(&mut context).is_pending());
        assert_eq!(FeedScanPermit::active_count(), 1);

        cancellation.cancel();

        assert!(dropped.get());
        assert_eq!(FeedScanPermit::active_count(), 0);
        assert!(Pin::new(&mut owned).poll(&mut context).is_ready());
        assert_eq!(FeedScanPermit::take_diagnostics().abandoned_recovered, 1);
    }
}
