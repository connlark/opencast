//! Poll in statement order at every wake, including the first submission poll.
//! Unlike size-dependent join_all implementations, this has no scheduling switch.
use futures_util::{
    future::{poll_fn, LocalBoxFuture},
    FutureExt,
};
use std::task::Poll;

pub(crate) async fn drain_ordered<'a, T: 'a>(work: Vec<LocalBoxFuture<'a, T>>) -> Vec<T> {
    let mut work: Vec<_> = work.into_iter().map(Some).collect();
    let mut replies: Vec<Option<T>> = (0..work.len()).map(|_| None).collect();
    poll_fn(move |cx| {
        let mut pending = false;
        for (index, future) in work.iter_mut().enumerate() {
            if let Some(request) = future {
                match request.poll_unpin(cx) {
                    Poll::Ready(reply) => {
                        replies[index] = Some(reply);
                        *future = None;
                    }
                    Poll::Pending => pending = true,
                }
            }
        }
        if pending {
            Poll::Pending
        } else {
            Poll::Ready(
                replies
                    .iter_mut()
                    .map(|r| r.take().expect("completed request"))
                    .collect(),
            )
        }
    })
    .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures_util::task::noop_waker;
    use std::{cell::RefCell, rc::Rc, task::Context};
    #[test]
    fn large_pipeline_submits_in_order_and_drains_past_an_early_error() {
        let submitted = Rc::new(RefCell::new(Vec::new()));
        let replies = Rc::new(RefCell::new(vec![false; 70]));
        let work = (0..70)
            .map(|index| {
                let submitted = submitted.clone();
                let replies = replies.clone();
                let mut first = true;
                poll_fn(move |_| {
                    if first {
                        submitted.borrow_mut().push(index);
                        first = false;
                    }
                    if replies.borrow()[index] {
                        Poll::Ready(if index == 2 { Err(index) } else { Ok(index) })
                    } else {
                        Poll::Pending
                    }
                })
                .boxed_local()
            })
            .collect();
        let mut operation = drain_ordered(work).boxed_local();
        let waker = noop_waker();
        let mut cx = Context::from_waker(&waker);
        assert!(operation.as_mut().poll(&mut cx).is_pending());
        assert_eq!(*submitted.borrow(), (0..70).collect::<Vec<_>>());
        replies.borrow_mut()[2] = true;
        assert!(operation.as_mut().poll(&mut cx).is_pending());
        replies.borrow_mut().fill(true);
        let Poll::Ready(result) = operation.as_mut().poll(&mut cx) else {
            panic!("all replies drained")
        };
        assert_eq!(result.len(), 70);
        assert_eq!(result[2], Err(2));
        assert_eq!(result[69], Ok(69));
        assert_eq!(submitted.borrow().len(), 70);
    }
}
