//! Executor-independent lifecycle policy. The invocation polls both work and driver;
//! there is no detached task, thread runtime, or cross-invocation client.
use futures_util::{future::poll_fn, pin_mut};
use serde::Serialize;
use std::{
    future::Future,
    pin::Pin,
    task::{Context, Poll},
};

pub const CONNECT_MS: u64 = 3_000;
pub const STATEMENT_MS: u64 = 4_000;
pub const TRANSACTION_MS: u64 = 8_000;
pub const HANDLER_MS: u64 = 12_000;
pub const CLOSE_MS: u64 = 500;

/// A failed/finished connection stays failed. Polling it again must not turn a
/// fused EOF into Pending and leave subsequent work waiting for its deadline.
pub struct Driver<F> {
    future: F,
    failure: Option<Failure>,
}
impl<F> Driver<F> {
    pub fn new(future: F) -> Self {
        Self {
            future,
            failure: None,
        }
    }
}
impl<F: Future<Output = Result<(), Failure>> + Unpin> Future for Driver<F> {
    type Output = Result<(), Failure>;
    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let this = self.get_mut();
        if let Some(error) = &this.failure {
            return Poll::Ready(Err(error.clone()));
        }
        match Pin::new(&mut this.future).poll(cx) {
            Poll::Pending => Poll::Pending,
            Poll::Ready(result) => {
                let error = result
                    .err()
                    .unwrap_or_else(|| Failure::new(Kind::Driver, Phase::Read));
                this.failure = Some(error.clone());
                Poll::Ready(Err(error))
            }
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Phase {
    Connect,
    Read,
    Transaction,
    Commit,
    Close,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    Configuration,
    Database,
    TlsUnavailable,
    Driver,
    Deadline,
    Cancelled,
    Decode,
    Assertion,
    Injected,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Outcome {
    NotCommitted,
    Unknown,
    NotApplicable,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Failure {
    pub kind: Kind,
    pub phase: Phase,
    pub outcome: Outcome,
    // PostgreSQL's five-character code only; never message, detail, query, or params.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sqlstate: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub driver_class: Option<&'static str>,
}

impl Failure {
    pub fn new(kind: Kind, phase: Phase) -> Self {
        Self {
            kind,
            phase,
            outcome: match phase {
                Phase::Commit => Outcome::Unknown,
                Phase::Close => Outcome::NotApplicable,
                _ => Outcome::NotCommitted,
            },
            sqlstate: None,
            driver_class: None,
        }
    }

    /// Only definite rollback reports may be retried at a semantic boundary.
    /// In particular, 55P03 while acquiring the transaction gate is not Unknown.
    /// This is a classification, never an instruction to replay external effects.
    pub fn retryable(&self) -> bool {
        self.outcome == Outcome::NotCommitted
            && matches!(self.sqlstate.as_deref(), Some("55P03" | "40001" | "40P01"))
    }

    #[cfg(feature = "postgres")]
    pub fn postgres(error: tokio_postgres::Error, phase: Phase) -> Self {
        let mut failure = Self::new(Kind::Database, phase);
        failure.driver_class = Some(match error.to_string().as_str() {
            "error communicating with the server" => "io",
            "unexpected message from server" => "unexpected_message",
            "error performing TLS handshake" => "tls",
            "connection closed" => "closed",
            "error parsing response from server" => "parse",
            "authentication error" => "authentication",
            "db error" => "server",
            _ => "other",
        });
        // Match one pinned driver's static diagnostic, never emit its source
        // chain (which may carry endpoint, credential, or SQL information).
        if std::error::Error::source(&error)
            .is_some_and(|source| source.to_string() == "server does not support TLS")
        {
            failure.kind = Kind::TlsUnavailable;
        }
        failure.sqlstate = error.code().map(|code| code.code().to_owned());
        // Only explicit transaction-rollback reports make a failed COMMIT definite.
        if matches!(failure.sqlstate.as_deref(), Some("40001" | "40P01")) {
            failure.outcome = Outcome::NotCommitted;
        }
        failure
    }
}

/// Driver is polled first so a ready fatal connection error cannot be masked by
/// a simultaneously ready query. Deadlines/cancellation win over unsent work.
pub async fn drive<T>(
    driver: impl Future<Output = Result<(), Failure>>,
    work: impl Future<Output = Result<T, Failure>>,
    deadline: impl Future<Output = ()>,
    cancelled: impl Future<Output = ()>,
    phase: Phase,
) -> Result<T, Failure> {
    drive_tracked(driver, work, deadline, cancelled, phase, &mut false).await
}

pub async fn drive_tracked<T>(
    driver: impl Future<Output = Result<(), Failure>>,
    work: impl Future<Output = Result<T, Failure>>,
    deadline: impl Future<Output = ()>,
    cancelled: impl Future<Output = ()>,
    phase: Phase,
    submitted: &mut bool,
) -> Result<T, Failure> {
    pin_mut!(driver, work, deadline, cancelled);
    let result = poll_fn(|cx| {
        if let Poll::Ready(result) = driver.as_mut().poll(cx) {
            let mut failure = result
                .err()
                .unwrap_or_else(|| Failure::new(Kind::Driver, phase));
            failure.phase = phase;
            failure.outcome = Failure::new(Kind::Driver, phase).outcome;
            return Poll::Ready(Err(failure));
        }
        if cancelled.as_mut().poll(cx).is_ready() {
            return Poll::Ready(Err(Failure::new(Kind::Cancelled, phase)));
        }
        if deadline.as_mut().poll(cx).is_ready() {
            return Poll::Ready(Err(Failure::new(Kind::Deadline, phase)));
        }
        *submitted = true;
        work.as_mut().poll(cx)
    })
    .await;
    result.map_err(|mut error| {
        if !*submitted && phase != Phase::Close {
            error.outcome = Outcome::NotCommitted;
        } else if phase == Phase::Read && error.sqlstate.is_none() {
            // Public row-returning APIs also accept autocommit mutations. Once
            // submitted, a transport/deadline failure cannot prove non-commit.
            error.outcome = Outcome::Unknown;
        }
        error
    })
}

#[cfg(test)]
mod tests {
    #[test]
    fn gate_lock_timeout_is_retryable_only_when_not_committed() {
        let mut failure = super::Failure::new(super::Kind::Database, super::Phase::Transaction);
        failure.sqlstate = Some("55P03".into());
        assert_eq!(failure.outcome, super::Outcome::NotCommitted);
        assert!(failure.retryable());
        failure.outcome = super::Outcome::Unknown;
        assert!(!failure.retryable());
    }

    use super::*;
    use futures_util::{
        future::{pending, ready},
        FutureExt,
    };
    use std::{cell::Cell, rc::Rc};

    fn block_on<F: Future>(future: F) -> F::Output {
        future
            .now_or_never()
            .expect("deterministic case must resolve on first poll")
    }

    struct Dropped(Rc<Cell<bool>>);
    impl Drop for Dropped {
        fn drop(&mut self) {
            self.0.set(true);
        }
    }

    #[test]
    fn completed_query_is_returned() {
        assert_eq!(
            block_on(drive(
                pending(),
                ready(Ok(7)),
                pending(),
                pending(),
                Phase::Read
            )),
            Ok(7)
        );
    }

    #[test]
    fn expired_work_is_never_submitted() {
        let submitted = Cell::new(false);
        let work = async {
            submitted.set(true);
            Ok(())
        };
        let result = block_on(drive(
            pending(),
            work,
            ready(()),
            pending(),
            Phase::Transaction,
        ));
        assert_eq!(result.unwrap_err().kind, Kind::Deadline);
        assert!(!submitted.get());
    }

    #[test]
    fn connection_failure_and_unexpected_eof_are_not_swallowed() {
        for result in [Ok(()), Err(Failure::new(Kind::Driver, Phase::Read))] {
            let error = block_on(drive(
                ready(result),
                ready(Ok(7)),
                pending(),
                pending(),
                Phase::Read,
            ))
            .unwrap_err();
            assert_eq!(error.kind, Kind::Driver);
        }
    }

    #[test]
    fn deadline_and_cancellation_drop_pending_work() {
        for cancelled in [false, true] {
            let flag = Rc::new(Cell::new(false));
            let guard = Dropped(flag.clone());
            let work = async move {
                let _owned = guard;
                pending::<Result<(), Failure>>().await
            };
            let signal = async move {
                if !cancelled {
                    pending::<()>().await
                }
            };
            let timeout = async move {
                if cancelled {
                    pending::<()>().await
                }
            };
            let error =
                block_on(drive(pending(), work, timeout, signal, Phase::Transaction)).unwrap_err();
            assert_eq!(
                error.kind,
                if cancelled {
                    Kind::Cancelled
                } else {
                    Kind::Deadline
                }
            );
            assert_eq!(error.outcome, Outcome::NotCommitted);
            assert!(flag.get());
        }
    }

    #[test]
    fn dropping_invocation_drops_driver_and_work() {
        let driver_dropped = Rc::new(Cell::new(false));
        let work_dropped = Rc::new(Cell::new(false));
        let driver_guard = Dropped(driver_dropped.clone());
        let work_guard = Dropped(work_dropped.clone());
        let driver = async move {
            let _owned = driver_guard;
            pending().await
        };
        let work = async move {
            let _owned = work_guard;
            pending::<Result<(), Failure>>().await
        };
        assert!(
            drive(driver, work, pending(), pending(), Phase::Transaction)
                .now_or_never()
                .is_none()
        );
        assert!(driver_dropped.get() && work_dropped.get());
    }

    #[test]
    fn lost_commit_ack_is_unknown_and_must_be_reconciled() {
        // First submit COMMIT, then lose its acknowledgement. A ready deadline
        // before the first work poll is a different (definitely unsent) case.
        for driver_failure in [false, true] {
            let submitted = Cell::new(false);
            let driver = poll_fn(|_| {
                if driver_failure && submitted.get() {
                    Poll::Ready(Err(Failure::new(Kind::Driver, Phase::Read)))
                } else {
                    Poll::Pending
                }
            });
            let deadline = poll_fn(|_| {
                if !driver_failure && submitted.get() {
                    Poll::Ready(())
                } else {
                    Poll::Pending
                }
            });
            let work = async {
                submitted.set(true);
                pending::<Result<(), Failure>>().await
            };
            let mut future = Box::pin(drive(driver, work, deadline, pending(), Phase::Commit));
            let waker = futures_util::task::noop_waker();
            let mut cx = Context::from_waker(&waker);
            assert!(future.as_mut().poll(&mut cx).is_pending());
            let Poll::Ready(Err(error)) = future.as_mut().poll(&mut cx) else {
                panic!("must fail after submission")
            };
            assert_eq!(error.outcome, Outcome::Unknown);
        }
    }

    #[test]
    fn unsent_commit_needs_no_reconciliation() {
        for cancelled in [false, true] {
            let error = block_on(drive(
                pending(),
                pending::<Result<(), Failure>>(),
                ready(()),
                async {
                    if !cancelled {
                        pending::<()>().await
                    }
                },
                Phase::Commit,
            ))
            .unwrap_err();
            assert_eq!(error.outcome, Outcome::NotCommitted);
        }
    }

    #[test]
    fn autocommit_transport_failure_after_submission_is_unknown() {
        let error = block_on(drive(
            pending(),
            ready(Err::<(), _>(Failure::new(Kind::Driver, Phase::Read))),
            pending(),
            pending(),
            Phase::Read,
        ))
        .unwrap_err();
        assert_eq!(error.outcome, Outcome::Unknown);
    }

    #[test]
    fn dead_driver_rejects_all_later_work_without_submission() {
        let mut driver = Driver::new(ready(Err(Failure::new(Kind::Driver, Phase::Read))));
        for _ in 0..2 {
            let mut submitted = false;
            let error = block_on(drive_tracked(
                &mut driver,
                ready(Ok(())),
                pending(),
                pending(),
                Phase::Transaction,
                &mut submitted,
            ))
            .unwrap_err();
            assert_eq!(error.kind, Kind::Driver);
            assert!(!submitted);
        }
    }

    #[test]
    fn deadlines_are_below_hyperdrive_and_server_bounds() {
        const { assert!(CONNECT_MS < 15_000 && STATEMENT_MS < 5_000) };
        const { assert!(TRANSACTION_MS < 10_000 && HANDLER_MS < 15_000) };
    }
}
