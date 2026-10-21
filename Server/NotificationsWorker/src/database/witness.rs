//! The storage timing witness's hooks into one invocation's storage calls:
//! the token an Authority clone carries, the operation guard a caller owns
//! across its executor call, and the core's race sink. Inert unless the
//! Authority was built `witnessed()`. The records are `storage_witness`'s.
pub(crate) use crate::storage_witness::{FailureRecord, OpStatus, Role, Scope, Witness};
use opencast_worker_database_core::{
    database::now,
    lifecycle::{self, Failure},
    race::{Limit, RaceEnd, RaceSink, RaceStart, RaceStatus},
};
use std::{
    cell::{Cell, RefCell},
    rc::Rc,
};

/// The invocation's witness, with the deadline and scope of the Authority
/// clone an operation runs under.
#[derive(Clone)]
pub(crate) struct Token {
    pub witness: Rc<RefCell<Witness>>,
    pub deadline: u64,
    pub scope: Scope,
}

/// One storage operation's record, owned by its caller across the executor
/// call. Dropped unfinished, it records `dropped` with its in-flight race.
pub(crate) struct OpGuard {
    inner: Option<(Token, usize)>,
    done: Cell<bool>,
}

impl OpGuard {
    pub(crate) fn open(
        token: Option<&Token>,
        op: &str,
        role: Role,
        read: bool,
        parent: Option<&OpGuard>,
    ) -> Self {
        let Some(token) = token else {
            return Self {
                inner: None,
                done: Cell::new(true),
            };
        };
        let parent = parent.and_then(OpGuard::ordinal);
        let ordinal = token
            .witness
            .borrow_mut()
            .open_op(op, role, read, parent, now());
        Self {
            inner: Some((token.clone(), ordinal)),
            done: Cell::new(false),
        }
    }
    pub(crate) fn ordinal(&self) -> Option<usize> {
        self.inner.as_ref().map(|(_, ordinal)| *ordinal)
    }
    /// What an executor needs: its connect race and the core's race sink.
    pub(crate) fn races(&self) -> Option<Races> {
        self.inner.as_ref().map(|(token, op)| Races {
            token: token.clone(),
            op: *op,
        })
    }
    fn finish(
        &self,
        status: OpStatus,
        failure: Option<FailureRecord>,
        counts: Option<(u64, u64)>,
        child_caused: bool,
    ) {
        let Some((token, op)) = &self.inner else {
            return;
        };
        if self.done.replace(true) {
            return;
        }
        token
            .witness
            .borrow_mut()
            .op_end(*op, status, failure, counts, child_caused, now());
    }
    /// The executor's result, by reference: the caller keeps it.
    pub(crate) fn settle(&self, result: &std::result::Result<super::Response, Failure>) {
        match result {
            Ok(response) => {
                let rows = response.replies.iter().map(|r| r.rows.len() as u64).sum();
                let read = self
                    .inner
                    .as_ref()
                    .is_some_and(|(token, op)| token.witness.borrow().ops[*op].read);
                // A write's affected rows are its statements' command tags.
                let affected = if read {
                    0
                } else {
                    response.replies.iter().map(|r| r.count).sum()
                };
                self.finish(OpStatus::Completed, None, Some((rows, affected)), false);
            }
            Err(failure) => self.failed(failure),
        }
    }
    pub(crate) fn failed(&self, failure: &Failure) {
        self.finish(
            OpStatus::Failed,
            Some(FailureRecord::of(failure)),
            None,
            false,
        );
    }
    /// Refused before any storage work of its own (its identity child failed or
    /// refused): never the primary.
    pub(crate) fn refused(&self) {
        self.finish(OpStatus::Failed, None, None, true);
    }
    /// A completion without a semantic Response (the identity read's one row).
    pub(crate) fn done(&self, rows: u64) {
        self.finish(OpStatus::Completed, None, Some((rows, 0)), false);
    }
}

impl Drop for OpGuard {
    fn drop(&mut self) {
        if !self.done.get() {
            self.finish(OpStatus::Dropped, None, None, false);
        }
    }
}

/// The executor-side view of one guard.
#[derive(Clone)]
pub(crate) struct Races {
    token: Token,
    op: usize,
}

impl Races {
    fn push(&self, race: RaceStart) -> usize {
        self.token.witness.borrow_mut().push_race(
            self.op,
            race,
            self.token.deadline,
            self.token.scope,
        )
    }
    /// The operation's ONE connect race, opened before `Database::connect` is
    /// awaited (or before an expired deadline returns): the authority race and
    /// the core's CONNECT_MS race are one record.
    pub(crate) fn connect(&self, started: u64, deadline: u64) -> usize {
        let left = deadline.saturating_sub(started);
        let (budget_ms, limit) = if left < lifecycle::CONNECT_MS {
            (left, Limit::AuthorityDeadline)
        } else {
            (lifecycle::CONNECT_MS, Limit::ConnectMs)
        };
        self.push(RaceStart {
            boundary: "connect",
            limit,
            budget_ms,
            start_ms: started,
            steps_total: None,
        })
    }
    pub(crate) fn connected(&self, race: usize, failure: Option<&Failure>, submitted: bool) {
        self.finish(
            race,
            RaceEnd {
                end_ms: now(),
                status: RaceStatus::of(failure),
                submitted,
                sqlstate: failure.and_then(|failure| failure.sqlstate.clone()),
            },
        );
    }
    pub(crate) fn sink(&self) -> Rc<dyn RaceSink> {
        Rc::new(self.clone())
    }
}

impl RaceSink for Races {
    fn start(&self, race: RaceStart) -> usize {
        self.push(race)
    }
    fn submitted(&self, race: usize) {
        self.token.witness.borrow_mut().race_submitted(race);
    }
    fn step(&self, race: usize, boundary: &'static str, at_ms: u64, gate_wait_us: Option<i64>) {
        self.token
            .witness
            .borrow_mut()
            .race_step(race, boundary, at_ms, gate_wait_us);
    }
    fn finish(&self, race: usize, end: RaceEnd) {
        self.token.witness.borrow_mut().race_end(race, end);
    }
}
