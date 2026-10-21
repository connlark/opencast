// Read by the wasm32 glue and the storage_phases line; a host build only tests it.
#![cfg_attr(not(target_arch = "wasm32"), allow(dead_code))]
//! The storage timing witness's records for one invocation: operations,
//! their races, the primary failure and its pre-primary snapshot. Pure: every
//! time is passed in (epoch milliseconds, the storage deadlines' clock), so the
//! rules are unit-tested on the host. `database::witness` feeds it.
use opencast_worker_database_core::{
    lifecycle::Failure,
    race::{Limit, RaceEnd, RaceStart, RaceStatus},
};
use std::{
    cell::{Cell, RefCell},
    future::Future,
    rc::Rc,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    Operation,
    Readback,
    Identity,
    Interactive,
}

/// Which deadline an Authority clone carries.
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Scope {
    Main,
    Bookkeeping,
    Step,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OpStatus {
    Open,
    Completed,
    Failed,
    Dropped,
}

/// A storage failure as the core recorded it, before the public string.
#[derive(Clone, Debug)]
pub struct FailureRecord {
    pub kind: String,
    pub phase: String,
    pub outcome: String,
    pub sqlstate: Option<String>,
}
impl FailureRecord {
    pub fn of(failure: &Failure) -> Self {
        Self {
            kind: format!("{:?}", failure.kind),
            phase: serde_json::to_value(failure.phase)
                .ok()
                .and_then(|v| v.as_str().map(str::to_owned))
                .unwrap_or_default(),
            outcome: format!("{:?}", failure.outcome),
            sqlstate: failure.sqlstate.clone().filter(|s| valid(s, 5)),
        }
    }
}

/// Every string the line carries is `[A-Za-z0-9_.-]` and bounded, so JSON
/// escaping cannot occur and the encoded width is the computed one.
pub fn valid(text: &str, max: usize) -> bool {
    !text.is_empty()
        && text.len() <= max
        && text
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b'-'))
}
pub fn bounded(text: &str, max: usize) -> String {
    if valid(text, max) {
        text.to_owned()
    } else {
        "invalid".to_owned()
    }
}

#[derive(Debug)]
pub struct Op {
    pub op: String,
    pub role: Role,
    pub read: bool,
    pub parent: Option<usize>,
    pub start: u64,
    pub end: Option<u64>,
    pub status: OpStatus,
    pub failure: Option<FailureRecord>,
    pub rows_returned: Option<u64>,
    pub affected_rows: Option<u64>,
    pub races: Vec<usize>,
    /// The guard was refused by its identity child or an unreadable selection:
    /// it did no storage work of its own.
    pub child_caused: bool,
}

#[derive(Debug)]
pub struct Race {
    pub op: usize,
    pub boundary: &'static str,
    pub limit: Limit,
    pub budget_ms: u64,
    pub authority_remaining_ms: u64,
    pub authority_scope: Scope,
    pub start: u64,
    pub end: Option<u64>,
    pub status: Option<RaceStatus>,
    pub submitted: Option<bool>,
    pub steps_total: Option<u32>,
    pub steps_completed: u32,
    pub gate_reply_at: Option<u64>,
    pub gate_wait_us: Option<i64>,
    pub sqlstate: Option<String>,
}
impl Race {
    pub fn span(&self) -> Option<u64> {
        self.end.map(|end| end.saturating_sub(self.start))
    }
    /// connect, read, transaction and the interactive statements; never the
    /// cleanup races (close, rollback), which C2 ignores.
    pub fn is_work(&self) -> bool {
        matches!(
            self.boundary,
            "connect" | "read" | "transaction" | "statement"
        )
    }
}

/// The pre-primary validity snapshot, the line's `prior`.
#[derive(Clone, Debug)]
pub struct Prior {
    pub taken_at_ordinal: usize,
    pub noncompleted_count: u64,
    pub over_local_cap_count: u64,
    pub close_failures: u64,
    pub lost_records: u64,
    pub local_cap_sum_before_ms: u64,
}
impl Prior {
    pub fn all_within_local_caps(&self) -> &'static str {
        if self.lost_records > 0 {
            "unknown"
        } else if self.noncompleted_count == 0 && self.over_local_cap_count == 0 {
            "true"
        } else {
            "false"
        }
    }
}

#[derive(Clone, Debug)]
pub struct Primary {
    pub op: usize,
    pub race: Option<usize>,
    pub prior: Prior,
}

/// Non-storage leaf categories, each an interval list in the storage clock.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Category {
    R2,
    Service,
    Alert,
    Publisher,
    Queue,
}

#[derive(Default)]
pub struct Witness {
    pub origin: u64,
    /// `performance.now()` at the same arrival: the Date/performance divergence
    /// is an isolate-local diagnostic, never an independent clock.
    pub perf_origin: f64,
    /// The cron's scheduled time, from the private adapter header.
    pub scheduled_ms: Option<u64>,
    pub actions: Vec<Action>,
    pub context: Context,
    pub ops: Vec<Op>,
    pub races: Vec<Race>,
    pub primary: Option<Primary>,
    /// The invocation's identity state: decided, cached, ungated or unreadable.
    pub identity: Option<&'static str>,
    pub intervals: Vec<(Category, u64, u64)>,
}

impl Witness {
    pub fn new(origin: u64) -> Self {
        Self {
            origin,
            ..Self::default()
        }
    }

    /// The strongest identity state of the invocation wins: an unreadable or
    /// decided verdict over a cached one, any of them over an ungated gate.
    pub fn note_identity(&mut self, state: &'static str) {
        let rank = |state: &str| match state {
            "unreadable" => 3,
            "decided" => 2,
            "cached" => 1,
            _ => 0,
        };
        if self
            .identity
            .is_none_or(|current| rank(state) > rank(current))
        {
            self.identity = Some(state);
        }
    }

    pub fn open_op(
        &mut self,
        op: &str,
        role: Role,
        read: bool,
        parent: Option<usize>,
        now: u64,
    ) -> usize {
        self.ops.push(Op {
            op: bounded(op, 32),
            role,
            read,
            parent,
            start: now,
            end: None,
            status: OpStatus::Open,
            failure: None,
            rows_returned: None,
            affected_rows: None,
            races: vec![],
            child_caused: false,
        });
        self.ops.len() - 1
    }

    /// The snapshot at the primary's ONE terminal recording event: every
    /// connect/read/transaction race started before `before` (a race index, or
    /// the operation's own start for a no-race failure), in race order.
    fn prior(&self, op: usize, before: Before) -> Prior {
        let mut prior = Prior {
            taken_at_ordinal: op,
            noncompleted_count: 0,
            over_local_cap_count: 0,
            close_failures: 0,
            lost_records: 0,
            local_cap_sum_before_ms: 0,
        };
        let earlier = |index: usize, race: &Race| match before {
            Before::Race(primary) => index < primary,
            Before::Time(start) => race.start < start,
        };
        for (index, race) in self.races.iter().enumerate() {
            if !earlier(index, race) {
                continue;
            }
            if race.boundary == "close" {
                if race.status != Some(RaceStatus::Completed) {
                    prior.close_failures += 1;
                }
                continue;
            }
            if !race.is_work() {
                continue;
            }
            match (race.status, race.span()) {
                (Some(RaceStatus::Completed), Some(span)) => {
                    if span > race.budget_ms {
                        prior.over_local_cap_count += 1;
                    } else {
                        prior.local_cap_sum_before_ms += span;
                    }
                }
                _ => prior.noncompleted_count += 1,
            }
        }
        prior
    }

    fn race_ended(&mut self, index: usize) {
        let race = &self.races[index];
        let failed = race
            .status
            .is_some_and(|status| status != RaceStatus::Completed);
        if failed && self.primary.is_none() && race.is_work() {
            let op = race.op;
            let prior = self.prior(op, Before::Race(index));
            self.primary = Some(Primary {
                op,
                race: Some(index),
                prior,
            });
        }
    }

    fn op_ended(&mut self, op: usize) {
        let failed = matches!(self.ops[op].status, OpStatus::Failed | OpStatus::Dropped);
        if !failed || self.primary.is_some() || self.ops[op].child_caused {
            return;
        }
        // A failure none of the operation's own races carries: a decode,
        // assertion or configuration failure, or a drop between races.
        let start = self.ops[op].start;
        let prior = self.prior(op, Before::Time(start));
        self.primary = Some(Primary {
            op,
            race: None,
            prior,
        });
    }

    /// Ordinals of failed or dropped leaf operations after the primary, in order.
    pub fn later_failures(&self) -> Vec<usize> {
        let Some(primary) = &self.primary else {
            return vec![];
        };
        (0..self.ops.len())
            .filter(|&op| {
                op > primary.op
                    && matches!(self.ops[op].status, OpStatus::Failed | OpStatus::Dropped)
                    && !self.ops[op].child_caused
            })
            .collect()
    }

    pub fn record(&mut self, category: Category, start: u64, end: u64) {
        self.intervals.push((category, start, end));
    }
}

#[derive(Clone, Copy)]
enum Before {
    Race(usize),
    Time(u64),
}

impl Witness {
    /// A race of operation `op` started; `deadline` and `scope` are those of
    /// the Authority clone the operation runs under.
    pub fn push_race(&mut self, op: usize, race: RaceStart, deadline: u64, scope: Scope) -> usize {
        self.races.push(Race {
            op,
            boundary: race.boundary,
            limit: race.limit,
            budget_ms: race.budget_ms,
            authority_remaining_ms: deadline.saturating_sub(race.start_ms),
            authority_scope: scope,
            start: race.start_ms,
            end: None,
            status: None,
            submitted: None,
            steps_total: race.steps_total,
            steps_completed: 0,
            gate_reply_at: None,
            gate_wait_us: None,
            sqlstate: None,
        });
        let index = self.races.len() - 1;
        self.ops[op].races.push(index);
        index
    }
    /// The race's request went out; kept however the race ends, a drop included.
    pub fn race_submitted(&mut self, race: usize) {
        let record = &mut self.races[race];
        if record.end.is_none() {
            record.submitted = Some(true);
        }
    }
    /// A reply arrived, which also proves the request went out.
    pub fn race_step(
        &mut self,
        race: usize,
        boundary: &str,
        at_ms: u64,
        gate_wait_us: Option<i64>,
    ) {
        let record = &mut self.races[race];
        if record.end.is_some() {
            return;
        }
        record.steps_completed += 1;
        record.submitted = Some(true);
        if boundary == "gate" {
            record.gate_reply_at = Some(at_ms);
            record.gate_wait_us = gate_wait_us;
        }
    }
    /// The race's own end; the first failing work race becomes the primary.
    pub fn race_end(&mut self, race: usize, end: RaceEnd) {
        let record = &mut self.races[race];
        if record.end.is_some() {
            return;
        }
        record.end = Some(end.end_ms);
        record.status = Some(end.status);
        record.submitted = Some(end.submitted || record.submitted == Some(true));
        record.sqlstate = end.sqlstate.filter(|s| valid(s, 5));
        self.race_ended(race);
    }
    /// The operation's finalization. A race still open belonged to a future
    /// dropped mid-flight: it ends `dropped` now, naming the in-flight boundary.
    pub fn op_end(
        &mut self,
        op: usize,
        status: OpStatus,
        failure: Option<FailureRecord>,
        counts: Option<(u64, u64)>,
        child_caused: bool,
        now: u64,
    ) {
        if self.ops[op].status != OpStatus::Open {
            return;
        }
        let open: Vec<usize> = self.ops[op]
            .races
            .iter()
            .copied()
            .filter(|&race| self.races[race].end.is_none())
            .collect();
        for race in open {
            self.races[race].end = Some(now);
            self.races[race].status = Some(RaceStatus::Dropped);
            self.race_ended(race);
        }
        let record = &mut self.ops[op];
        record.end = Some(now);
        record.status = status;
        record.failure = failure;
        record.child_caused = child_caused;
        if let Some((rows, affected)) = counts {
            record.rows_returned = Some(rows);
            record.affected_rows = Some(affected);
        }
        self.op_ended(op);
    }
}

/// A checkpoint, coarse on purpose: a preparation's phase, or a
/// drain's page OFFSET inside one observation's manifest, never a page identity.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Checkpoint {
    pub kind: &'static str,
    pub phase: Option<i64>,
    pub candidate_cursor: Option<i64>,
    /// committed, uncommitted or unknown (an Unknown COMMIT outcome: terminal).
    pub status: Option<&'static str>,
}

/// One action of a delivery: today's ladder runs one (or a settle).
#[derive(Clone, Debug)]
pub struct Action {
    pub name: &'static str,
    pub result: String,
    pub start: u64,
    pub end: Option<u64>,
    /// completed, failed, cancelled or yielded; an action still open when the
    /// line is written takes the invocation's failed or cancelled outcome.
    pub status: &'static str,
    pub ops_from: usize,
    pub ops_to: Option<usize>,
    pub start_checkpoint: Option<Checkpoint>,
    pub end_checkpoint: Option<Checkpoint>,
    /// The operation count when the end checkpoint was attempted: its write is
    /// the first operation the action opens after it.
    pub checkpoint_from: Option<usize>,
    /// The relative remaining wait an idle action yielded to, in seconds.
    pub wait_remaining_s: Option<i64>,
}

#[derive(Clone, Debug)]
pub struct Chain {
    pub feed: String,
    pub generation: i64,
    pub step: u32,
    pub attempts: u32,
    pub message_digest: Option<String>,
}

#[derive(Clone, Debug)]
pub struct Sent {
    pub step: u32,
    pub delay_s: i64,
    /// ok, err, or uncertain while the send's outcome is not observed.
    pub result: &'static str,
}

#[derive(Clone, Debug, Default)]
pub struct Posts {
    pub n: u64,
    pub accepted: u64,
    pub retried: u64,
}

/// What the handler and the polling code know that storage does not.
#[derive(Clone, Debug, Default)]
pub struct Context {
    pub handler: &'static str,
    /// The effective main budget the C2 predicate divides by, at arrival.
    pub handler_main_ms: u64,
    pub budget_scope: &'static str,
    pub budget_source: &'static str,
    pub delivery_start: Option<u64>,
    pub chain: Option<Chain>,
    pub message_age_ms: Option<u64>,
    pub sent: Option<Sent>,
    pub posts: Option<Posts>,
    /// The existing `timings.publisher` total (the consume's publisher time).
    pub publisher_ms: Option<u64>,
    /// The consume's own outcome name and its poll_delivery gate.
    pub consume_outcome: Option<&'static str>,
    pub consume_gated: bool,
}

impl Witness {
    pub fn action_start(&mut self, name: &'static str, now: u64) {
        self.actions.push(Action {
            name,
            result: String::new(),
            start: now,
            end: None,
            status: "completed",
            ops_from: self.ops.len(),
            ops_to: None,
            start_checkpoint: None,
            end_checkpoint: None,
            checkpoint_from: None,
            wait_remaining_s: None,
        });
    }
    /// Ends the open action; `result` is bounded to the line's string rule.
    pub fn action_end(
        &mut self,
        result: &str,
        status: &'static str,
        wait_remaining_s: Option<i64>,
        now: u64,
    ) {
        let ops = self.ops.len();
        if let Some(action) = self.actions.last_mut().filter(|a| a.end.is_none()) {
            action.result = bounded(result, 24);
            action.status = status;
            action.end = Some(now);
            action.ops_to = Some(ops);
            action.wait_remaining_s = wait_remaining_s;
        }
    }
    fn open_action(&mut self) -> Option<&mut Action> {
        self.actions.last_mut().filter(|a| a.end.is_none())
    }
    pub fn checkpoint_start(
        &mut self,
        kind: &'static str,
        phase: Option<i64>,
        candidate_cursor: Option<i64>,
    ) {
        if let Some(action) = self.open_action() {
            action.start_checkpoint = Some(Checkpoint {
                kind,
                phase,
                candidate_cursor,
                status: Some("committed"),
            });
        }
    }
    /// The checkpoint the action is about to write, recorded before its write
    /// is awaited: `unknown` until `checkpoint_end` reads that write's result,
    /// so a delivery dropped mid-write keeps the attempted target.
    pub fn checkpoint_attempt(
        &mut self,
        kind: &'static str,
        phase: Option<i64>,
        candidate_cursor: Option<i64>,
    ) {
        let from = self.ops.len();
        if let Some(action) = self.open_action() {
            action.end_checkpoint = Some(Checkpoint {
                kind,
                phase,
                candidate_cursor,
                status: Some("unknown"),
            });
            action.checkpoint_from = Some(from);
        }
    }
    /// The attempted checkpoint's status from its own write, the first
    /// operation opened after the attempt: committed when it completed,
    /// uncommitted when it failed with a definite outcome, unknown otherwise
    /// (an Unknown outcome, a drop, or no write at all). Nothing later
    /// reconciles it.
    pub fn checkpoint_end(&mut self) {
        let Some(from) = self.open_action().and_then(|action| action.checkpoint_from) else {
            return;
        };
        let status = self.ops[from.min(self.ops.len())..]
            .iter()
            .find(|op| op.role == Role::Operation)
            .map_or("unknown", |op| match op.status {
                OpStatus::Completed => "committed",
                OpStatus::Failed if op.failure.as_ref().is_some_and(|f| f.outcome == "Unknown") => {
                    "unknown"
                }
                OpStatus::Failed => "uncommitted",
                OpStatus::Dropped | OpStatus::Open => "unknown",
            });
        if let Some(checkpoint) = self
            .open_action()
            .and_then(|action| action.end_checkpoint.as_mut())
        {
            checkpoint.status = Some(status);
        }
    }
}

/// The storage deadlines' clock (`Date.now()`); a host build has no isolate and
/// its timers are always inert, so it never reads one.
fn clock() -> u64 {
    #[cfg(target_arch = "wasm32")]
    {
        worker::Date::now().as_millis()
    }
    #[cfg(not(target_arch = "wasm32"))]
    {
        0
    }
}

/// A handle that times one invocation's non-storage calls (R2, the FeedEvents
/// POST, the alert exchange, the publisher fetch, the queue sends) into its
/// witness. Inert by default: without a witness it reads no clock at all.
#[derive(Clone, Default)]
pub struct Timer(Option<Rc<RefCell<Witness>>>);
impl Timer {
    pub fn new(witness: Option<Rc<RefCell<Witness>>>) -> Self {
        Self(witness)
    }
    /// One call from now until `end()` or the span's drop.
    pub fn span(&self, category: Category) -> TimerSpan {
        TimerSpan {
            timer: self.clone(),
            category,
            start: self.0.as_ref().map(|_| clock()),
            done: Cell::new(false),
        }
    }
    pub async fn time<T>(&self, category: Category, work: impl Future<Output = T>) -> T {
        let span = self.span(category);
        let output = work.await;
        span.end();
        output
    }
}
/// Records its interval once: at `end()`, or at its drop when the call's
/// future was dropped or returned early.
pub struct TimerSpan {
    timer: Timer,
    category: Category,
    start: Option<u64>,
    done: Cell<bool>,
}
impl TimerSpan {
    pub fn end(&self) {
        if self.done.replace(true) {
            return;
        }
        if let (Some(witness), Some(start)) = (&self.timer.0, self.start) {
            witness.borrow_mut().record(self.category, start, clock());
        }
    }
}
impl Drop for TimerSpan {
    fn drop(&mut self) {
        self.end();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use opencast_worker_database_core::lifecycle::{Kind, Outcome, Phase};

    fn start(boundary: &'static str, limit: Limit, budget_ms: u64, start_ms: u64) -> RaceStart {
        RaceStart {
            boundary,
            limit,
            budget_ms,
            start_ms,
            steps_total: None,
        }
    }
    fn end(end_ms: u64, status: RaceStatus) -> RaceEnd {
        RaceEnd {
            end_ms,
            status,
            submitted: true,
            sqlstate: None,
        }
    }
    /// An operation with a completed connect and one read race ending `status`.
    fn read_op(w: &mut Witness, at: u64, read_ms: u64, status: RaceStatus, budget: u64) -> usize {
        let op = w.open_op("A01", Role::Operation, true, None, at);
        let c = w.push_race(
            op,
            start("connect", Limit::ConnectMs, 3_000, at),
            99_000,
            Scope::Main,
        );
        w.race_end(c, end(at + 10, RaceStatus::Completed));
        let r = w.push_race(
            op,
            start("read", Limit::StatementMs, budget, at + 10),
            99_000,
            Scope::Main,
        );
        w.race_end(r, end(at + 10 + read_ms, status));
        let c = w.push_race(
            op,
            start("close", Limit::CloseMs, 500, at + 10 + read_ms),
            99_000,
            Scope::Main,
        );
        w.race_end(c, end(at + 20 + read_ms, RaceStatus::Completed));
        op
    }

    #[test]
    fn the_first_failing_work_race_is_the_primary_and_its_prior_is_every_earlier_race() {
        let mut w = Witness::new(0);
        let a = read_op(&mut w, 0, 2_000, RaceStatus::Completed, 4_000);
        w.op_end(a, OpStatus::Completed, None, Some((1, 0)), false, 2_020);
        let b = read_op(&mut w, 2_100, 4_000, RaceStatus::Timeout, 4_000);
        let failure = FailureRecord::of(&Failure::new(Kind::Deadline, Phase::Read));
        w.op_end(b, OpStatus::Failed, Some(failure), None, false, 6_200);
        let primary = w.primary.clone().expect("primary");
        assert_eq!((primary.op, primary.race), (b, Some(4)));
        // a's connect and read, b's own connect: three work races, all in cap.
        assert_eq!(primary.prior.noncompleted_count, 0);
        assert_eq!(primary.prior.over_local_cap_count, 0);
        assert_eq!(primary.prior.local_cap_sum_before_ms, 10 + 2_000 + 10);
        assert_eq!(primary.prior.all_within_local_caps(), "true");
        let read = &w.races[4];
        assert_eq!(
            read.span(),
            Some(read.budget_ms),
            "a timely timeout overshoots by 0"
        );
    }

    #[test]
    fn a_close_failure_is_counted_apart_and_never_breaks_prior_validity() {
        let mut w = Witness::new(0);
        let a = w.open_op("A01", Role::Operation, true, None, 0);
        let c = w.push_race(
            a,
            start("close", Limit::CloseMs, 500, 0),
            9_000,
            Scope::Main,
        );
        w.race_end(c, end(600, RaceStatus::Timeout));
        w.op_end(a, OpStatus::Completed, None, Some((0, 0)), false, 600);
        assert!(w.primary.is_none(), "a close failure is never the primary");
        let b = read_op(&mut w, 700, 4_000, RaceStatus::Timeout, 4_000);
        w.op_end(b, OpStatus::Failed, None, None, false, 5_000);
        let prior = w.primary.expect("primary").prior;
        assert_eq!(prior.close_failures, 1);
        assert_eq!(prior.all_within_local_caps(), "true");
    }

    #[test]
    fn a_completed_race_over_its_budget_makes_prior_false() {
        let mut w = Witness::new(0);
        // A delayed resumption: the read completed 300 ms past its budget.
        let a = read_op(&mut w, 0, 1_300, RaceStatus::Completed, 1_000);
        w.op_end(a, OpStatus::Completed, None, Some((1, 0)), false, 1_400);
        let b = read_op(&mut w, 1_500, 100, RaceStatus::Driver, 4_000);
        w.op_end(b, OpStatus::Failed, None, None, false, 1_700);
        let prior = w.primary.expect("primary").prior;
        assert_eq!(prior.over_local_cap_count, 1);
        assert_eq!(prior.all_within_local_caps(), "false");
        assert_eq!(prior.lost_records, 0);
    }

    #[test]
    fn an_identity_child_failure_is_the_primary_never_its_parent() {
        let mut w = Witness::new(0);
        let parent = w.open_op("A04", Role::Operation, true, None, 0);
        let child = w.open_op("identity", Role::Identity, true, Some(parent), 1);
        let c = w.push_race(
            child,
            start("connect", Limit::ConnectMs, 3_000, 1),
            9_000,
            Scope::Main,
        );
        w.race_end(c, end(3_001, RaceStatus::Timeout));
        w.op_end(child, OpStatus::Failed, None, None, false, 3_002);
        w.op_end(parent, OpStatus::Failed, None, None, true, 3_003);
        let primary = w.primary.clone().expect("primary");
        assert_eq!((primary.op, primary.race), (child, Some(c)));
        assert_eq!(w.ops[child].parent, Some(parent));
        assert!(
            w.later_failures().is_empty(),
            "the refused parent is not a later failure"
        );
    }

    #[test]
    fn a_no_race_failure_and_a_drop_mid_race_are_primaries_with_their_own_shape() {
        let mut w = Witness::new(0);
        let a = w.open_op("B09", Role::Operation, false, None, 0);
        let failure = FailureRecord::of(&Failure::new(Kind::Decode, Phase::Commit));
        w.op_end(a, OpStatus::Failed, Some(failure), None, false, 10);
        let primary = w.primary.clone().expect("primary");
        assert_eq!((primary.op, primary.race), (a, None));
        // A later operation dropped while its read was in flight.
        let b = w.open_op("B10", Role::Operation, false, None, 20);
        let r = w.push_race(
            b,
            start("transaction", Limit::StatementMs, 4_000, 25),
            9_000,
            Scope::Step,
        );
        w.op_end(b, OpStatus::Dropped, None, None, false, 900);
        assert_eq!(w.races[r].status, Some(RaceStatus::Dropped));
        assert_eq!(w.races[r].end, Some(900));
        assert_eq!(w.later_failures(), vec![b]);
    }

    #[test]
    fn an_attempted_checkpoint_takes_its_own_write_s_outcome_and_stays_unknown_when_dropped() {
        let unknown = {
            let mut f = Failure::new(Kind::Deadline, Phase::Commit);
            f.outcome = Outcome::Unknown;
            FailureRecord::of(&f)
        };
        let definite = FailureRecord::of(&Failure::new(Kind::Database, Phase::Transaction));
        for (status, failure, expected) in [
            (OpStatus::Completed, None, "committed"),
            (OpStatus::Failed, Some(unknown), "unknown"),
            (OpStatus::Failed, Some(definite), "uncommitted"),
            (OpStatus::Dropped, None, "unknown"),
        ] {
            let mut w = Witness::new(0);
            w.action_start("drain", 0);
            // An earlier completed operation never decides the checkpoint.
            let before = w.open_op("B08", Role::Operation, true, None, 1);
            w.op_end(before, OpStatus::Completed, None, None, false, 2);
            w.checkpoint_attempt("drain", None, Some(3));
            let write = w.open_op("B09", Role::Operation, false, None, 3);
            w.op_end(write, status, failure, None, false, 9);
            if status != OpStatus::Dropped {
                w.checkpoint_end();
            }
            let checkpoint = w.actions[0].end_checkpoint.clone().expect("attempted");
            assert_eq!(
                (
                    checkpoint.kind,
                    checkpoint.candidate_cursor,
                    checkpoint.status
                ),
                ("drain", Some(3), Some(expected)),
                "{status:?}"
            );
        }
        // Dropped before its write even opened: the target, unknown.
        let mut w = Witness::new(0);
        w.action_start("prepare", 0);
        w.checkpoint_attempt("prepare", Some(3), None);
        let checkpoint = w.actions[0].end_checkpoint.clone().expect("attempted");
        assert_eq!(
            (checkpoint.phase, checkpoint.status),
            (Some(3), Some("unknown"))
        );
    }

    #[test]
    fn a_dropped_race_keeps_its_submission() {
        let mut w = Witness::new(0);
        // Dropped after the replies to BEGIN and the gate.
        let a = w.open_op("B10", Role::Operation, false, None, 0);
        let replied = w.push_race(
            a,
            start("transaction", Limit::StatementMs, 4_000, 0),
            9_000,
            Scope::Step,
        );
        w.race_step(replied, "begin", 5, None);
        w.race_step(replied, "gate", 9, Some(40));
        w.op_end(a, OpStatus::Dropped, None, None, false, 50);
        // Dropped once its request went out, before any reply.
        let b = w.open_op("B10", Role::Operation, false, None, 60);
        let sent = w.push_race(
            b,
            start("transaction", Limit::StatementMs, 4_000, 60),
            9_000,
            Scope::Step,
        );
        w.race_submitted(sent);
        w.op_end(b, OpStatus::Dropped, None, None, false, 90);
        // Never polled: nothing says it went out.
        let c = w.open_op("B10", Role::Operation, false, None, 100);
        let idle = w.push_race(
            c,
            start("transaction", Limit::StatementMs, 4_000, 100),
            9_000,
            Scope::Step,
        );
        w.op_end(c, OpStatus::Dropped, None, None, false, 110);
        for race in [replied, sent] {
            assert_eq!(
                (w.races[race].submitted, w.races[race].status),
                (Some(true), Some(RaceStatus::Dropped))
            );
        }
        assert_eq!(w.races[idle].submitted, None);
        // An end that reports no submission keeps one already recorded.
        let d = w.open_op("A01", Role::Operation, true, None, 120);
        let read = w.push_race(
            d,
            start("read", Limit::StatementMs, 4_000, 120),
            9_000,
            Scope::Step,
        );
        w.race_submitted(read);
        let mut ended = end(200, RaceStatus::Cancelled);
        ended.submitted = false;
        w.race_end(read, ended);
        assert_eq!(w.races[read].submitted, Some(true));
    }

    #[test]
    fn pipelined_steps_record_the_gate_and_stop_at_the_race_end() {
        let mut w = Witness::new(0);
        let a = w.open_op("B10", Role::Operation, false, None, 0);
        let mut s = start("transaction", Limit::StatementMs, 4_000, 0);
        s.steps_total = Some(4);
        let r = w.push_race(a, s, 9_000, Scope::Step);
        w.race_step(r, "begin", 5, None);
        w.race_step(r, "gate", 9, Some(1_250));
        w.race_end(r, end(4_000, RaceStatus::Timeout));
        w.race_step(r, "statement", 4_100, None);
        let race = &w.races[r];
        assert_eq!((race.steps_total, race.steps_completed), (Some(4), 2));
        assert_eq!(
            (race.gate_reply_at, race.gate_wait_us),
            (Some(9), Some(1_250))
        );
    }
}
