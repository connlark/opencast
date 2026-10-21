mod production;
use crate::race::{self, Limit, RaceEnd, RaceSink, RaceStart, RaceStatus};
pub use production::{Reply, TransactionReply};

use crate::{
    lifecycle::{self, Failure, Kind, Phase},
    socket::{CloseGuard, OwnedSocket, OwnedTls},
};
use futures_util::{
    future::{pending, LocalBoxFuture, Shared},
    FutureExt, TryStreamExt,
};
use serde::Serialize;
use std::{cell::Cell, future::Future, rc::Rc, time::Duration};
use tokio_postgres::{
    types::{ToSql, Type},
    Client, Row,
};
use worker::{Date, Delay, Env, SecureTransport, Socket};

pub type Cancellation = Shared<LocalBoxFuture<'static, ()>>;
pub fn now() -> u64 {
    Date::now().as_millis()
}
pub async fn delay(ms: u64) {
    // An already-expired absolute budget must not submit work while waiting for
    // a zero-duration JS timer to get its next event-loop turn.
    if ms > 0 {
        Delay::from(Duration::from_millis(ms)).await;
    }
}

#[derive(Serialize)]
pub struct Span {
    pub boundary: &'static str,
    pub elapsed_ms: u64,
    pub ok: bool,
    pub submitted: bool,
}

pub struct Database {
    client: Rc<Client>,
    driver: lifecycle::Driver<LocalBoxFuture<'static, Result<(), Failure>>>,
    guard: CloseGuard,
    cancel: Cancellation,
    handler_end: u64,
    transaction_end: Option<u64>,
    rollback_error: Option<Failure>,
    pub spans: Vec<Span>,
    // The witness only: which bound set handler_end, and where races go.
    handler_window_end: u64,
    authority_cap: Option<u64>,
    transaction_cap: Option<u64>,
    sink: Option<Rc<dyn RaceSink>>,
    race: Cell<Option<usize>>,
}

impl Database {
    pub async fn connect(
        env: &Env,
        cancel: Cancellation,
        handler_start: u64,
    ) -> Result<Self, Failure> {
        let start = now();
        let hd = env
            .hyperdrive("DB")
            .map_err(|_| Failure::new(Kind::Configuration, Phase::Connect))?;
        let socket = Socket::builder()
            .secure_transport(SecureTransport::StartTls)
            .connect(hd.host(), hd.port())
            .map_err(|_| Failure::new(Kind::Driver, Phase::Connect))?;
        let (socket, guard) = OwnedSocket::new(socket);
        // Use the binding's edge-connection policy, as the workers-rs example
        // does. This is not an origin connection string. Origin TLS/verify_full
        // belongs to the VPC service; defaults() verifies the actual PG TLS leg.
        // Forcing sslmode=require on the colocated Hyperdrive edge hop fails:
        // that endpoint replies N to PostgreSQL SSLRequest.
        let config = hd
            .connection_string()
            .parse::<tokio_postgres::Config>()
            .map_err(|_| Failure::new(Kind::Configuration, Phase::Connect))?;
        let work = async {
            config
                .connect_raw(socket, OwnedTls)
                .await
                .map_err(|e| Failure::postgres(e, Phase::Connect))
        };
        let (client, connection) = lifecycle::drive(
            pending(),
            work,
            delay(lifecycle::CONNECT_MS),
            cancel.clone(),
            Phase::Connect,
        )
        .await?;
        Ok(Self {
            client: Rc::new(client),
            driver: lifecycle::Driver::new(
                connection
                    .map(|r| {
                        r.map_err(|e| {
                            let mut failure = Failure::postgres(e, Phase::Read);
                            failure.kind = Kind::Driver;
                            failure
                        })
                    })
                    .fuse()
                    .boxed_local(),
            ),
            guard,
            cancel,
            handler_end: handler_start + lifecycle::HANDLER_MS,
            transaction_end: None,
            rollback_error: None,
            handler_window_end: handler_start + lifecycle::HANDLER_MS,
            authority_cap: None,
            transaction_cap: None,
            sink: None,
            race: Cell::new(None),
            spans: vec![Span {
                boundary: "connect",
                elapsed_ms: now().saturating_sub(start),
                ok: true,
                submitted: true,
            }],
        })
    }

    /// Report this segment's races (from now on) to `sink`. Without a sink the
    /// segment records nothing beyond its spans.
    pub fn witness(&mut self, sink: Rc<dyn RaceSink>) {
        self.sink = Some(sink);
    }

    /// The bound a race started now would hit first, and its budget.
    fn bound(&self, local: u64, local_limit: Limit) -> (u64, Limit) {
        race::binding(
            now(),
            (local, local_limit),
            &[
                (self.transaction_end, Limit::TransactionMs),
                (self.transaction_cap, Limit::TransactionMs),
                (Some(self.handler_window_end), Limit::HandlerEnd),
                (self.authority_cap, Limit::AuthorityDeadline),
            ],
        )
    }

    fn race_start(&self, boundary: &'static str, cleanup: bool, steps_total: Option<u32>) {
        let Some(sink) = &self.sink else { return };
        let (budget_ms, limit) = if cleanup {
            (lifecycle::CLOSE_MS, Limit::CloseMs)
        } else {
            self.bound(lifecycle::STATEMENT_MS, Limit::StatementMs)
        };
        let boundary = match boundary {
            "query" | "execute" => "statement",
            boundary => boundary,
        };
        self.race.set(Some(sink.start(RaceStart {
            boundary,
            limit,
            budget_ms,
            start_ms: now(),
            steps_total,
        })));
    }

    fn race_end<T>(&self, result: &Result<T, Failure>, submitted: bool) {
        let (Some(sink), Some(race)) = (&self.sink, self.race.take()) else {
            return;
        };
        let failure = result.as_ref().err();
        sink.finish(
            race,
            RaceEnd {
                end_ms: now(),
                status: RaceStatus::of(failure),
                submitted,
                sqlstate: failure.and_then(|failure| failure.sqlstate.clone()),
            },
        );
    }

    fn phase(&self) -> Phase {
        if self.transaction_end.is_some() {
            Phase::Transaction
        } else {
            Phase::Read
        }
    }
    fn remaining(&self, max: u64) -> u64 {
        self.handler_end
            .min(self.transaction_end.unwrap_or(u64::MAX))
            .saturating_sub(now())
            .min(max)
    }

    // Centralize deadline, cancellation, driver-error, outcome and span policy.
    // Cleanup has an independent bound and ignores the invocation's fired signal.
    async fn operation<T>(
        &mut self,
        boundary: &'static str,
        phase: Phase,
        cleanup: bool,
        cancelled: Option<Cancellation>,
        work: impl Future<Output = Result<T, Failure>>,
    ) -> Result<T, Failure> {
        let start = now();
        let remaining = if cleanup {
            lifecycle::CLOSE_MS
        } else {
            self.remaining(lifecycle::STATEMENT_MS)
        };
        let cancel = if cleanup {
            pending().boxed_local().shared()
        } else {
            cancelled.unwrap_or_else(|| self.cancel.clone())
        };
        let mut submitted = false;
        if boundary != "transaction" {
            self.race_start(boundary, cleanup, None);
        }
        // The sink learns of submission at the same first poll, so a race whose
        // future is dropped before it ends still reads submitted.
        let witness = self.sink.clone().zip(self.race.get());
        let work = async move {
            if let Some((sink, race)) = witness {
                sink.submitted(race);
            }
            work.await
        };
        let result = lifecycle::drive_tracked(
            &mut self.driver,
            work,
            delay(remaining),
            cancel,
            phase,
            &mut submitted,
        )
        .await;
        self.race_end(&result, submitted);
        self.spans.push(Span {
            boundary,
            elapsed_ms: now().saturating_sub(start),
            ok: result.is_ok(),
            submitted,
        });
        result
    }

    pub async fn query(&mut self, sql: &'static str, params: &[&str]) -> Result<Vec<Row>, Failure> {
        let typed: Vec<_> = params
            .iter()
            .map(|value| (value as &(dyn ToSql + Sync), Type::TEXT))
            .collect();
        self.typed(sql, &typed).await
    }

    pub async fn typed(
        &mut self,
        sql: &'static str,
        params: &[(&(dyn ToSql + Sync), Type)],
    ) -> Result<Vec<Row>, Failure> {
        let phase = self.phase();
        let client = self.client.clone();
        self.operation("query", phase, false, None, async move {
            client
                .query_typed(sql, params)
                .await
                .map_err(|e| Failure::postgres(e, phase))
        })
        .await
    }

    pub async fn execute(&mut self, sql: &'static str, params: &[&str]) -> Result<u64, Failure> {
        let phase = self.phase();
        if self.transaction_end.is_none() {
            return Err(Failure::new(Kind::Assertion, phase));
        }
        let client = self.client.clone();
        self.operation("execute", phase, false, None, async move {
            let stream = client
                .query_typed_raw(
                    sql,
                    params
                        .iter()
                        .map(|value| (value as &(dyn ToSql + Sync), Type::TEXT)),
                )
                .await
                .map_err(|e| Failure::postgres(e, phase))?;
            futures_util::pin_mut!(stream);
            while stream
                .try_next()
                .await
                .map_err(|e| Failure::postgres(e, phase))?
                .is_some()
            {}
            stream
                .rows_affected()
                .ok_or_else(|| Failure::new(Kind::Decode, phase))
        })
        .await
    }

    pub async fn finish(self) -> (Vec<Span>, Option<Failure>) {
        let Self {
            client,
            mut driver,
            guard,
            mut spans,
            rollback_error,
            sink,
            ..
        } = self;
        let start = now();
        let race = sink.as_ref().map(|sink| {
            sink.start(RaceStart {
                boundary: "close",
                limit: Limit::CloseMs,
                budget_ms: lifecycle::CLOSE_MS,
                start_ms: start,
                steps_total: None,
            })
        });
        // Query/execute/COMMIT consume ReadyForQuery. Observe any ready driver
        // error before deliberately closing the edge transport. The live pilot
        // observed a close error when driving Terminate/writable shutdown instead;
        // its underlying transport cause remains unproven.
        let observed = match (&mut driver).now_or_never() {
            Some(Err(error)) => Some(error),
            Some(Ok(())) => Some(Failure::new(Kind::Driver, Phase::Close)),
            None => None,
        };
        drop(driver);
        let closed = lifecycle::drive(
            pending(),
            async {
                #[cfg(feature = "fixture")]
                delay(CLOSE_DELAY_MS.with(std::cell::Cell::get)).await;
                guard
                    .close()
                    .await
                    .map_err(|_| Failure::new(Kind::Driver, Phase::Close))
            },
            delay(lifecycle::CLOSE_MS),
            pending(),
            Phase::Close,
        )
        .await;
        drop(client);
        if let (Some(sink), Some(race)) = (&sink, race) {
            let failure = closed.as_ref().err();
            sink.finish(
                race,
                RaceEnd {
                    end_ms: now(),
                    status: RaceStatus::of(failure),
                    submitted: true,
                    sqlstate: None,
                },
            );
        }
        spans.push(Span {
            boundary: "close",
            submitted: true,
            elapsed_ms: now().saturating_sub(start),
            ok: observed.is_none() && closed.is_ok(),
        });
        // Cleanup status cannot change a previously acknowledged commit outcome.
        let cleanup = rollback_error
            .or(observed)
            .or(closed.err())
            .map(|mut error| {
                error.outcome = lifecycle::Outcome::NotApplicable;
                error.phase = Phase::Close;
                error
            });
        (spans, cleanup)
    }

    pub fn is_in_transaction(&self) -> bool {
        self.transaction_end.is_some()
    }
}

// Fixture-only state sits after every other item, so a production build keeps
// the line numbers its panic locations record.
#[cfg(feature = "fixture")]
thread_local! {
    static CLOSE_DELAY_MS: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}
/// Fixture builds only: delay the close future inside `finish()` by `ms`, so a
/// test can give the close race a known span. The CLOSE_MS race around it,
/// and every other boundary, are unchanged.
#[cfg(feature = "fixture")]
pub fn set_close_delay_ms(ms: u64) {
    CLOSE_DELAY_MS.with(|delay| delay.set(ms));
}
