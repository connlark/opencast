//! Production descriptor execution. Only typed unnamed protocol messages.
use super::{now, Database, Span};
use crate::{
    lifecycle::{self, Failure, Kind, Outcome, Phase},
    ordered::drain_ordered,
    statement::{Parameter, Statement},
};
use futures_util::{FutureExt, TryStreamExt};
use std::{cell::RefCell, rc::Rc};
use tokio_postgres::{Client, Row};

pub struct Reply {
    pub rows: Vec<Row>,
    pub affected: u64,
}
pub struct TransactionReply {
    pub gate: Reply,
    pub statements: Vec<Reply>,
}

async fn query(
    client: &Client,
    sql: &str,
    parameters: &[Parameter],
    phase: Phase,
) -> Result<Reply, Failure> {
    let parameters: Vec<_> = parameters.iter().map(Parameter::typed).collect();
    let stream = client
        .query_typed_raw(sql, parameters)
        .await
        .map_err(|error| Failure::postgres(error, phase))?;
    futures_util::pin_mut!(stream);
    let mut rows = Vec::new();
    while let Some(row) = stream
        .try_next()
        .await
        .map_err(|error| Failure::postgres(error, phase))?
    {
        rows.push(row);
    }
    let affected = stream
        .rows_affected()
        .ok_or_else(|| Failure::new(Kind::Decode, Phase::Commit))?;
    Ok(Reply { rows, affected })
}

impl Database {
    /// Cap this storage segment by the enclosing operation's absolute deadline
    /// (epoch milliseconds). The window only shrinks: a caller's scan or step
    /// deadline then bounds every later statement, transaction and poll budget.
    pub fn cap_deadline(&mut self, until: u64) {
        self.handler_end = self.handler_end.min(until);
        self.authority_cap = Some(self.authority_cap.map_or(until, |cap| cap.min(until)));
    }

    /// The same narrowing as `cap_deadline`, for a caller's own transaction
    /// window (the witness names it `transaction_ms`, not the authority).
    pub fn cap_transaction(&mut self, until: u64) {
        self.handler_end = self.handler_end.min(until);
        self.transaction_cap = Some(self.transaction_cap.map_or(until, |cap| cap.min(until)));
    }

    /// Pure reads have no mutation outcome. A caller cannot use this method for
    /// a write; the semantic backend constructs the closed set of read statements.
    pub async fn read_statement(&mut self, statement: &Statement) -> Result<Reply, Failure> {
        statement.validate().map_err(|mut error| {
            error.outcome = Outcome::NotApplicable;
            error
        })?;
        if self.transaction_end.is_some() {
            let mut error = Failure::new(Kind::Assertion, Phase::Read);
            error.outcome = Outcome::NotApplicable;
            return Err(error);
        }
        let client = self.client.clone();
        let reply = self
            .operation(
                "read",
                Phase::Read,
                false,
                None,
                query(&client, &statement.sql, &statement.parameters, Phase::Read),
            )
            .await;
        reply
            .and_then(|reply| {
                if statement.count.accepts(reply.affected) {
                    Ok(reply)
                } else {
                    Err(Failure::new(Kind::Decode, Phase::Read))
                }
            })
            .map_err(|mut error| {
                error.outcome = Outcome::NotApplicable;
                error
            })
    }

    /// Submit BEGIN, the mandatory mutation gate, each application statement,
    /// then COMMIT in one ordered poll. Application-dependent no-ops belong in
    /// SQL fences; no reply controls submission of a later statement.
    pub async fn write_transaction(
        &mut self,
        gate: &Statement,
        statements: &[Statement],
    ) -> Result<TransactionReply, Failure> {
        if self.transaction_end.is_some() || statements.is_empty() {
            return Err(Failure::new(Kind::Assertion, Phase::Transaction));
        }
        gate.validate()?;
        for statement in statements {
            statement.validate()?;
        }
        let started = now();
        self.transaction_end = Some(started + lifecycle::TRANSACTION_MS);
        let client = self.client.clone();
        let timings = Rc::new(RefCell::new(Vec::new()));
        let completed = timings.clone();
        let steps_total = u32::try_from(statements.len() + 3).ok();
        self.race_start("transaction", false, steps_total);
        let witness = self.sink.clone().zip(self.race.get());
        let result = self
            .operation("transaction", Phase::Commit, false, None, async move {
                let mut steps = vec![
                    ("BEGIN", &[][..], Phase::Transaction, "begin"),
                    (
                        gate.sql.as_str(),
                        gate.parameters.as_slice(),
                        Phase::Transaction,
                        "gate",
                    ),
                ];
                steps.extend(statements.iter().map(|statement| {
                    (
                        statement.sql.as_str(),
                        statement.parameters.as_slice(),
                        Phase::Transaction,
                        "statement",
                    )
                }));
                steps.push(("COMMIT", &[], Phase::Commit, "commit"));
                let work = steps
                    .into_iter()
                    .map(|(sql, parameters, phase, boundary)| {
                        let client = client.clone();
                        let completed = completed.clone();
                        let witness = witness.clone();
                        async move {
                            let started = now();
                            let reply = query(&client, sql, parameters, phase).await;
                            if let (Some((sink, race)), Ok(reply)) = (&witness, &reply) {
                                // The gate's wait survives a later failure of the race.
                                let gate_wait_us = (boundary == "gate")
                                    .then(|| reply.rows.first())
                                    .flatten()
                                    .and_then(|row| row.try_get::<_, i64>("gate_wait_us").ok());
                                sink.step(*race, boundary, now(), gate_wait_us);
                            }
                            completed.borrow_mut().push(Span {
                                boundary,
                                elapsed_ms: now().saturating_sub(started),
                                ok: reply.is_ok(),
                                submitted: true,
                            });
                            reply
                        }
                        .boxed_local()
                    })
                    .collect();
                // This drains every reply, including COMMIT after an earlier error.
                let replies = drain_ordered(work).await;
                let mut successful = Vec::with_capacity(replies.len());
                for (index, reply) in replies.into_iter().enumerate() {
                    let reply = reply.map_err(|mut error| {
                        // Failed BEGIN permits later queued statements to autocommit.
                        // Missing transport/decoding evidence cannot certify rollback.
                        if index == 0 || error.sqlstate.is_none() {
                            error.outcome = Outcome::Unknown;
                        }
                        error
                    })?;
                    successful.push(reply);
                }
                // A successful COMMIT cannot hide an earlier statement's SQL error.
                // Count validation follows all protocol replies; failure is Unknown
                // because the writes may already have committed.
                let mut replies = successful.into_iter();
                let _begin = replies.next().expect("BEGIN response");
                let gate_reply = replies.next().expect("gate response");
                if !gate.count.accepts(gate_reply.affected) {
                    return Err(Failure::new(Kind::Decode, Phase::Commit));
                }
                let mut application = Vec::with_capacity(statements.len());
                for statement in statements {
                    let reply = replies.next().expect("application response");
                    if !statement.count.accepts(reply.affected) {
                        return Err(Failure::new(Kind::Decode, Phase::Commit));
                    }
                    application.push(reply);
                }
                Ok(TransactionReply {
                    gate: gate_reply,
                    statements: application,
                })
            })
            .await;
        self.spans.extend(timings.borrow_mut().drain(..));
        if result.is_err() {
            let client = self.client.clone();
            self.rollback_error = self
                .operation("rollback", Phase::Transaction, true, None, async move {
                    query(&client, "ROLLBACK", &[], Phase::Transaction)
                        .await
                        .map(|_| ())
                })
                .await
                .err();
        }
        self.transaction_end = None;
        result
    }
}
