// Written by the wasm32 runtime; a host build only tests it.
#![cfg_attr(not(target_arch = "wasm32"), allow(dead_code))]
//! FeedPolling's one `storage_phases` line per invocation (schema 2): the
//! witness's records as cap-independent summaries, the pre-primary snapshot,
//! the recovery terms, and bounded detail under one byte ceiling. Every string
//! is `[A-Za-z0-9_.-]` and bounded, so no JSON escaping can occur; the line is
//! NEVER written over the ceiling: an impossible overflow writes the one-line
//! `storage_phases_overflow` instead.
use crate::storage_witness::{Action, Checkpoint, OpStatus, Race, Role, Witness};
use opencast_worker_database_core::race::RaceStatus;
use serde_json::{json, Map, Value};

pub const SCHEMA: u64 = 2;
/// The contract: no line is ever larger, marked or not.
pub const CEILING: usize = 8_192;
const MAX_INT: u64 = 999_999_999_999;
const DETAILED_OPS: usize = 16;
const ACTIONS: usize = 16;
const SLOWEST: usize = 3;
const FAILURES: usize = 4;

fn int(value: u64) -> Value {
    json!(value.min(MAX_INT))
}
fn opt(value: Option<u64>) -> Value {
    value.map_or(Value::Null, int)
}
fn signed(value: i64) -> Value {
    json!(value.clamp(-(MAX_INT as i64), MAX_INT as i64))
}
fn snake<T: serde::Serialize>(value: T) -> Value {
    serde_json::to_value(value).unwrap_or(Value::Null)
}

/// Union length of half-open intervals, overlap counted once.
pub fn union_ms(mut intervals: Vec<(u64, u64)>) -> u64 {
    intervals.retain(|(start, end)| end > start);
    intervals.sort_unstable();
    let mut total = 0;
    let mut current: Option<(u64, u64)> = None;
    for (start, end) in intervals {
        match current {
            Some((s, e)) if start <= e => current = Some((s, e.max(end))),
            Some((s, e)) => {
                total += e - s;
                current = Some((start, end));
            }
            None => current = Some((start, end)),
        }
    }
    total + current.map_or(0, |(s, e)| e - s)
}

pub struct Inputs {
    /// ok, failed, cancelled, or refused (a consume the environment brake
    /// answered before any storage call).
    pub outcome: &'static str,
    pub now_ms: u64,
    pub perf_now: f64,
}

/// How a failure entry finds its race.
#[derive(Clone, Copy)]
enum RaceOf {
    /// The primary's recorded race; None is a failure no race carried.
    Recorded(Option<usize>),
    /// A later failure's race, found from its own races.
    Discovered,
}

struct View<'a> {
    w: &'a Witness,
    now: u64,
}

impl View<'_> {
    fn op_end(&self, op: usize) -> u64 {
        self.w.ops[op].end.unwrap_or(self.now)
    }
    fn race_end(&self, race: &Race) -> u64 {
        race.end.unwrap_or(self.now)
    }
    fn race_status(&self, race: &Race) -> RaceStatus {
        race.status.unwrap_or(RaceStatus::Dropped)
    }
    fn race(&self, index: usize) -> Value {
        let race = &self.w.races[index];
        let status = self.race_status(race);
        let span = self.race_end(race).saturating_sub(race.start);
        json!({
            "boundary": race.boundary,
            "limit": snake(race.limit),
            "budget_ms": int(race.budget_ms),
            "authority_remaining_ms": int(race.authority_remaining_ms),
            "authority_scope": snake(race.authority_scope),
            "start_ms": int(race.start.saturating_sub(self.w.origin)),
            "end_ms": opt(race.end.map(|end| end.saturating_sub(self.w.origin))),
            "status": snake(status),
            "submitted": race.submitted.map_or(Value::Null, Value::Bool),
            "steps_total": race.steps_total.map_or(Value::Null, |n| int(n.into())),
            "steps_completed": race.steps_total.map_or(Value::Null, |_| int(race.steps_completed.into())),
            "gate_reply_at_ms": opt(race.gate_reply_at.map(|at| at.saturating_sub(self.w.origin))),
            "gate_wait_us": race.gate_wait_us.map_or(Value::Null, |us| int(us.max(0) as u64)),
            "sqlstate": race.sqlstate.clone().map_or(Value::Null, Value::String),
            "overshoot_ms": if status == RaceStatus::Timeout {
                int(span.saturating_sub(race.budget_ms))
            } else {
                Value::Null
            },
        })
    }
    fn op(&self, op: usize, races: bool) -> Value {
        let record = &self.w.ops[op];
        let mut value = json!({
            "ordinal": int(op as u64 + 1),
            "op": record.op,
            "role": snake(record.role),
            "parent": record.parent.map_or(Value::Null, |p| int(p as u64 + 1)),
            "read": record.read,
            "start_ms": int(record.start.saturating_sub(self.w.origin)),
            "end_ms": opt(record.end.map(|end| end.saturating_sub(self.w.origin))),
            "status": match record.status {
                OpStatus::Completed => "completed",
                OpStatus::Failed => "failed",
                OpStatus::Dropped | OpStatus::Open => "dropped",
            },
            "rows_returned": opt(record.rows_returned),
            "affected_rows": opt(record.affected_rows),
        });
        if races {
            value["race"] = Value::Array(record.races.iter().map(|&r| self.race(r)).collect());
        }
        value
    }
    /// A failed or dropped leaf operation in the shape of `primary`.
    fn failure(&self, op: usize, race: RaceOf, local_cap_sum_before_ms: u64) -> Value {
        let record = &self.w.ops[op];
        let race = match race {
            // The primary's own race, or none: a failure no race carried
            // keeps race null even when a cleanup race failed beside it.
            RaceOf::Recorded(race) => race,
            // A later failure: its first work race that did not complete; a
            // dropped operation's in-flight race, a cleanup one included,
            // when no work race failed.
            RaceOf::Discovered => {
                let failed = |work: bool| {
                    record.races.iter().copied().find(|&r| {
                        let race = &self.w.races[r];
                        (!work || race.is_work()) && self.race_status(race) != RaceStatus::Completed
                    })
                };
                failed(true).or_else(|| {
                    matches!(record.status, OpStatus::Dropped | OpStatus::Open)
                        .then(|| failed(false))
                        .flatten()
                })
            }
        };
        let (kind, phase, outcome, sqlstate) = match &record.failure {
            Some(f) => (
                f.kind.clone(),
                f.phase.clone(),
                f.outcome.clone(),
                f.sqlstate.clone(),
            ),
            // A dropped future has no Failure: the abort, at its race.
            None => {
                let boundary = race.map_or("connect", |r| self.w.races[r].boundary);
                let submitted = race.and_then(|r| self.w.races[r].submitted).unwrap_or(true);
                let phase = match boundary {
                    "transaction" | "statement" => "transaction",
                    "read" => "read",
                    "close" => "close",
                    "rollback" => "transaction",
                    _ => "connect",
                };
                let outcome = if record.read {
                    "NotApplicable"
                } else if submitted && boundary != "connect" {
                    "Unknown"
                } else {
                    "NotCommitted"
                };
                (
                    "Cancelled".to_owned(),
                    phase.to_owned(),
                    outcome.to_owned(),
                    None,
                )
            }
        };
        let overshoot = race.and_then(|r| {
            let race = &self.w.races[r];
            (self.race_status(race) == RaceStatus::Timeout).then(|| {
                self.race_end(race)
                    .saturating_sub(race.start)
                    .saturating_sub(race.budget_ms)
            })
        });
        json!({
            "ordinal": int(op as u64 + 1),
            "op": record.op,
            "role": snake(record.role),
            "parent": record.parent.map_or(Value::Null, |p| int(p as u64 + 1)),
            "status": if record.status == OpStatus::Failed { "failed" } else { "dropped" },
            "kind": kind,
            "phase": phase,
            "outcome": outcome,
            "sqlstate": sqlstate.map_or(Value::Null, Value::String),
            "race": race.map_or(Value::Null, |r| self.race(r)),
            "overshoot_ms": opt(overshoot),
            "local_cap_sum_before_ms": int(local_cap_sum_before_ms),
        })
    }
    fn checkpoint(checkpoint: &Option<Checkpoint>) -> Value {
        checkpoint.as_ref().map_or(Value::Null, |c| {
            json!({
                "kind": c.kind,
                "phase": c.phase.map_or(Value::Null, |p| int(p.max(0) as u64)),
                "candidate_cursor": c.candidate_cursor.map_or(Value::Null, |p| int(p.max(0) as u64)),
                "status": c.status.map_or(Value::Null, |s| json!(s)),
            })
        })
    }
    fn action_status(&self, action: &Action, outcome: &str) -> &'static str {
        if action.end.is_some() {
            action.status
        } else if outcome == "cancelled" {
            "cancelled"
        } else {
            "failed"
        }
    }
    fn outbox(&self, from: usize, to: usize) -> Value {
        let (mut acknowledged, mut attempted, mut unknown) = (0, 0, 0);
        for op in &self.w.ops[from.min(self.w.ops.len())..to.min(self.w.ops.len())] {
            if op.op != "B10" || op.role != Role::Operation {
                continue;
            }
            let submitted = op.races.iter().any(|&r| {
                self.w.races[r].boundary == "transaction" && self.w.races[r].submitted == Some(true)
            });
            if submitted {
                attempted += 1;
            }
            match op.status {
                OpStatus::Completed => acknowledged += 1,
                OpStatus::Failed if op.failure.as_ref().is_some_and(|f| f.outcome == "Unknown") => {
                    unknown += 1
                }
                OpStatus::Dropped | OpStatus::Open if submitted => unknown += 1,
                _ => {}
            }
        }
        json!({"acknowledged_txns": int(acknowledged), "attempted_txns": int(attempted), "unknown_txns": int(unknown)})
    }
    fn action(&self, index: usize, outcome: &str) -> Value {
        let a = &self.w.actions[index];
        let to = a.ops_to.unwrap_or(self.w.ops.len());
        let end = a.end.unwrap_or(self.now);
        let r2: Vec<(u64, u64)> = self
            .w
            .intervals
            .iter()
            .filter(|(c, start, _)| {
                *c == crate::storage_witness::Category::R2 && *start >= a.start && *start <= end
            })
            .map(|(_, s, e)| (*s, *e))
            .collect();
        let (rows, affected) = self.w.ops
            [a.ops_from.min(self.w.ops.len())..to.min(self.w.ops.len())]
            .iter()
            .fold((0, 0), |(r, f), op| {
                (
                    r + op.rows_returned.unwrap_or(0),
                    f + op.affected_rows.unwrap_or(0),
                )
            });
        json!({
            "ordinal": int(index as u64),
            "name": a.name,
            "result": a.result,
            "start_ms": int(a.start.saturating_sub(self.w.origin)),
            "end_ms": opt(a.end.map(|e| e.saturating_sub(self.w.origin))),
            "status": self.action_status(a, outcome),
            "ops_from": int(a.ops_from as u64 + 1),
            "ops_to": int(to as u64),
            "r2_calls": int(r2.len() as u64),
            "r2_ms": int(r2.iter().map(|(s, e)| e.saturating_sub(*s)).sum()),
            "start_checkpoint": Self::checkpoint(&a.start_checkpoint),
            "end_checkpoint": Self::checkpoint(&a.end_checkpoint),
            "wait_remaining_s": a.wait_remaining_s.map_or(Value::Null, |s| int(s.max(0) as u64)),
            "outbox_release": if a.name == "drain" || a.name == "outbox" { self.outbox(a.ops_from, to) } else { Value::Null },
            "affected_rows": int(affected),
            "rows_returned": int(rows),
        })
    }
}

/// The deterministic notability order of `op[]`: (1) operations not completed,
/// (2) operations with a race not completed, (3) total span descending, (4) the
/// first two and last two ordinals; ties by ascending ordinal; at most 16.
fn notable(view: &View) -> Vec<usize> {
    let ops = &view.w.ops;
    let n = ops.len();
    let mut chosen: Vec<usize> = vec![];
    let push = |op: usize, chosen: &mut Vec<usize>| {
        if chosen.len() < DETAILED_OPS && !chosen.contains(&op) {
            chosen.push(op);
        }
    };
    for (op, record) in ops.iter().enumerate() {
        if record.status != OpStatus::Completed {
            push(op, &mut chosen);
        }
    }
    for (op, record) in ops.iter().enumerate() {
        if record
            .races
            .iter()
            .any(|&r| view.race_status(&view.w.races[r]) != RaceStatus::Completed)
        {
            push(op, &mut chosen);
        }
    }
    let mut by_span: Vec<usize> = (0..n).collect();
    by_span.sort_by_key(|&op| {
        (
            std::cmp::Reverse(view.op_end(op).saturating_sub(ops[op].start)),
            op,
        )
    });
    for op in by_span
        .into_iter()
        .filter(|&op| view.op_end(op).saturating_sub(ops[op].start) >= 1_000)
    {
        push(op, &mut chosen);
    }
    for op in [0, 1, n.saturating_sub(2), n.saturating_sub(1)] {
        if op < n {
            push(op, &mut chosen);
        }
    }
    chosen.sort_unstable();
    chosen
}

pub fn line(w: &Witness, inputs: &Inputs) -> String {
    render(w, inputs, CEILING, false)
}

/// `line()` under a given ceiling; `force_compact` skips to the compact form
/// (the tests' handle on a path bounded widths make unreachable).
fn render(w: &Witness, inputs: &Inputs, ceiling: usize, force_compact: bool) -> String {
    let view = View {
        w,
        now: inputs.now_ms,
    };
    let outcome = inputs.outcome;
    let wall = inputs.now_ms.saturating_sub(w.origin);
    let ctx = &w.context;
    // ---- durations: the union of every storage interval, then the leaf categories
    let storage: Vec<(u64, u64)> = (0..w.ops.len())
        .filter(|&op| !w.ops[op].races.is_empty() || w.ops[op].status != OpStatus::Completed)
        .map(|op| (w.ops[op].start, view.op_end(op)))
        .collect();
    let category = |c: crate::storage_witness::Category| -> Vec<(u64, u64)> {
        w.intervals
            .iter()
            .filter(|(k, _, _)| *k == c)
            .map(|(_, s, e)| (*s, *e))
            .collect()
    };
    use crate::storage_witness::Category::*;
    let mut all = storage.clone();
    for c in [R2, Service, Alert, Publisher, Queue] {
        all.extend(category(c));
    }
    let publisher = ctx
        .publisher_ms
        .unwrap_or_else(|| union_ms(category(Publisher)));
    let durations = json!({
        "storage": int(union_ms(storage)),
        "r2": int(union_ms(category(R2))),
        "service": int(union_ms(category(Service))),
        "alert": int(union_ms(category(Alert))),
        "publisher": int(publisher),
        "queue": int(union_ms(category(Queue))),
        "idle": int(wall.saturating_sub(union_ms(all))),
    });
    // ---- the summary over EVERY race, independent of the detail cap
    let mut counts = [0u64; 6];
    let (mut connect, mut connect_max, mut connect_timeouts) = (vec![], 0u64, 0u64);
    let (mut read_max, mut read_timeouts, mut tx_max, mut tx_timeouts) = (0u64, 0u64, 0u64, 0u64);
    let (mut close_sum, mut close_max, mut rollback_sum) = (0u64, 0u64, 0u64);
    let (mut gate_wait_max, mut gate_reply_max, mut overshoot_max): (
        Option<u64>,
        Option<u64>,
        Option<u64>,
    ) = (None, None, None);
    let mut budget_min: Option<(u64, Value)> = None;
    let mut local_cap_sum = 0u64;
    for race in &w.races {
        let status = view.race_status(race);
        let span = view.race_end(race).saturating_sub(race.start);
        let slot = match status {
            RaceStatus::Completed => 0,
            RaceStatus::Timeout => 1,
            RaceStatus::Cancelled => 2,
            RaceStatus::Driver => 3,
            RaceStatus::Database => 4,
            RaceStatus::Dropped => 5,
        };
        counts[slot] += 1;
        let timeout = u64::from(status == RaceStatus::Timeout);
        match race.boundary {
            "connect" => {
                connect.push((race.start, view.race_end(race)));
                connect_max = connect_max.max(span);
                connect_timeouts += timeout;
            }
            "read" => {
                read_max = read_max.max(span);
                read_timeouts += timeout;
            }
            "transaction" | "statement" => {
                tx_max = tx_max.max(span);
                tx_timeouts += timeout;
            }
            "close" => {
                close_sum += span;
                close_max = close_max.max(span);
            }
            "rollback" => rollback_sum += span,
            _ => {}
        }
        if let Some(us) = race.gate_wait_us {
            gate_wait_max = Some(gate_wait_max.unwrap_or(0).max(us.max(0) as u64));
        }
        if let Some(at) = race.gate_reply_at {
            gate_reply_max = Some(
                gate_reply_max
                    .unwrap_or(0)
                    .max(at.saturating_sub(race.start)),
            );
        }
        if status == RaceStatus::Timeout {
            overshoot_max = Some(
                overshoot_max
                    .unwrap_or(0)
                    .max(span.saturating_sub(race.budget_ms)),
            );
        }
        if race.is_work() {
            if budget_min.as_ref().is_none_or(|(b, _)| race.budget_ms < *b) {
                budget_min = Some((race.budget_ms, snake(race.limit)));
            }
            if status == RaceStatus::Completed && span <= race.budget_ms {
                local_cap_sum += span;
            }
        }
    }
    let (rows_returned, affected_rows) = w.ops.iter().fold((0, 0), |(r, f), op| {
        (
            r + op.rows_returned.unwrap_or(0),
            f + op.affected_rows.unwrap_or(0),
        )
    });
    let summary = json!({
        "races": {"total": int(w.races.len() as u64), "completed": int(counts[0]), "timeout": int(counts[1]),
                  "cancelled": int(counts[2]), "driver": int(counts[3]), "database": int(counts[4]), "dropped": int(counts[5])},
        "connect": {"union_ms": int(union_ms(connect)), "max_ms": int(connect_max), "timeouts": int(connect_timeouts)},
        "read": {"max_ms": int(read_max), "timeouts": int(read_timeouts)},
        "transaction": {"max_ms": int(tx_max), "timeouts": int(tx_timeouts)},
        "close": {"sum_ms": int(close_sum), "max_ms": int(close_max)},
        "rollback": {"sum_ms": int(rollback_sum)},
        "gate_wait_us_max": opt(gate_wait_max),
        "gate_reply_ms_max": opt(gate_reply_max),
        "overshoot_ms_max": opt(overshoot_max),
        "budget_min_ms": opt(budget_min.as_ref().map(|(b, _)| *b)),
        "budget_min_limit": budget_min.map_or(Value::Null, |(_, l)| l),
        "local_cap_sum_ms": int(local_cap_sum),
        "affected_rows": int(affected_rows),
        "rows_returned": int(rows_returned),
    });
    // ---- the primary, its snapshot, the later failures
    let primary = w.primary.as_ref();
    let later = w.later_failures();
    let count = |role: Role| int(w.ops.iter().filter(|op| op.role == role).count() as u64);
    let detailed = notable(&view);
    let prior = primary.map_or(Value::Null, |p| {
        json!({
            "taken_at_ordinal": int(p.prior.taken_at_ordinal as u64 + 1),
            "noncompleted_count": int(p.prior.noncompleted_count),
            "over_local_cap_count": int(p.prior.over_local_cap_count),
            "close_failures": int(p.prior.close_failures),
            "lost_records": int(p.prior.lost_records),
            "all_within_local_caps": p.prior.all_within_local_caps(),
        })
    });
    let primary_value = primary.map_or(Value::Null, |p| {
        view.failure(
            p.op,
            RaceOf::Recorded(p.race),
            p.prior.local_cap_sum_before_ms,
        )
    });
    let failures: Vec<Value> = later
        .iter()
        .map(|&op| view.failure(op, RaceOf::Discovered, 0))
        .collect();
    // ---- recovery: exactly the terms the fields carry
    let first = w.actions.first();
    let last = w.actions.last();
    let brief = |a: Option<&Action>| {
        a.map_or(Value::Null, |a| {
            json!({"name": a.name, "start_checkpoint": View::checkpoint(&a.start_checkpoint), "end_checkpoint": View::checkpoint(&a.end_checkpoint)})
        })
    };
    let recovery = json!({
        "admission_ms": opt(ctx.delivery_start.zip(first).map(|(s, a)| a.start.saturating_sub(s))),
        "wait_remaining_s": last.and_then(|a| a.wait_remaining_s).map_or(Value::Null, |s| int(s.max(0) as u64)),
        "first_action": brief(first),
        "last_action": brief(last),
        "outbox_release": view.outbox(0, w.ops.len()),
        // Same-page provenance is never positively established in production.
        "page_repeated": "unknown",
    });
    let mut slowest: Vec<usize> = (0..w.races.len()).collect();
    slowest.sort_by_key(|&r| {
        (
            std::cmp::Reverse(view.race_end(&w.races[r]).saturating_sub(w.races[r].start)),
            r,
        )
    });
    let slowest: Vec<Value> = slowest
        .into_iter()
        .take(SLOWEST)
        .map(|r| {
            let race = &w.races[r];
            json!({"ordinal": int(race.op as u64 + 1), "op": w.ops[race.op].op, "boundary": race.boundary,
                   "limit": snake(race.limit), "budget_ms": int(race.budget_ms),
                   "span_ms": int(view.race_end(race).saturating_sub(race.start)), "status": snake(view.race_status(race)),
                   "gate_wait_us": race.gate_wait_us.map_or(Value::Null, |us| int(us.max(0) as u64))})
        })
        .collect();
    let actions: Vec<Value> = (0..w.actions.len())
        .map(|i| view.action(i, outcome))
        .collect();
    let scheduled_lag = w.scheduled_ms.map(|s| w.origin.saturating_sub(s));
    let date_vs_perf = inputs.now_ms as f64 - w.origin as f64 - (inputs.perf_now - w.perf_origin);
    let chain = ctx.chain.as_ref().map_or(Value::Null, |c| {
        json!({"feed": crate::storage_witness::bounded(&c.feed, 64), "generation": int(c.generation.max(0) as u64),
               "step": int(c.step.into()), "attempts": int(c.attempts.into()),
               "message_digest": c.message_digest.clone().map_or(Value::Null, Value::String)})
    });
    let root = |ops: Value| {
        let mut m = Map::new();
        m.insert("schema".into(), json!(SCHEMA));
        m.insert("event".into(), json!("storage_phases"));
        m.insert(
            "handler".into(),
            json!(if ctx.handler.is_empty() {
                "consume"
            } else {
                ctx.handler
            }),
        );
        m.insert("outcome".into(), json!(outcome));
        m.insert("wall_ms".into(), int(wall));
        m.insert("scheduled_lag_ms".into(), opt(scheduled_lag));
        m.insert(
            "date_vs_perf_ms".into(),
            signed(date_vs_perf.round() as i64),
        );
        m.insert("identity".into(), json!(w.identity.unwrap_or("ungated")));
        m.insert("durations".into(), durations.clone());
        m.insert("ops".into(), ops);
        m.insert(
            "budget".into(),
            json!({"handler_main_ms": int(ctx.handler_main_ms),
            "scope": if ctx.budget_scope.is_empty() { "main" } else { ctx.budget_scope },
            "source": if ctx.budget_source.is_empty() { "HANDLER_MS" } else { ctx.budget_source }}),
        );
        m.insert("prior".into(), prior.clone());
        m.insert("recovery".into(), recovery.clone());
        m.insert("summary".into(), summary.clone());
        m.insert("primary".into(), primary_value.clone());
        m.insert("chain".into(), chain.clone());
        m.insert("message_age_ms".into(), opt(ctx.message_age_ms));
        m.insert(
            "sent".into(),
            ctx.sent.as_ref().map_or(Value::Null, |s| {
                json!({"step": int(s.step.into()),
            "delay_s": int(s.delay_s.max(0) as u64), "result": s.result})
            }),
        );
        m.insert(
            "posts".into(),
            ctx.posts.as_ref().map_or(Value::Null, |p| {
                json!({"n": int(p.n),
            "accepted": int(p.accepted), "retried": int(p.retried)})
            }),
        );
        m
    };
    let ops_value = |detailed: usize| {
        json!({"total": int(w.ops.len() as u64), "reads": int(w.ops.iter().filter(|o| o.role == Role::Operation && o.read).count() as u64),
               "writes": int(w.ops.iter().filter(|o| o.role == Role::Operation && !o.read).count() as u64),
               "readbacks": count(Role::Readback), "identity": count(Role::Identity), "interactive": count(Role::Interactive),
               "after_primary": int(primary.map_or(0, |p| w.ops.len().saturating_sub(p.op + 1)) as u64),
               "dropped": int(w.ops.iter().filter(|o| matches!(o.status, OpStatus::Dropped | OpStatus::Open)).count() as u64),
               "detailed": int(detailed as u64), "omitted": int(w.ops.len().saturating_sub(detailed) as u64)})
    };
    // ---- the full form, then the trimming order (a)-(e), then the compact form
    let mut op_detail: Vec<Value> = detailed.iter().map(|&op| view.op(op, true)).collect();
    let mut op_ordinals = detailed.clone();
    let mut action_list = actions.clone();
    let mut slowest_list = slowest;
    let mut failure_list = failures.clone();
    let (mut t_races, mut t_detail, mut t_actions, mut t_slowest, mut t_failures) =
        (false, false, false, false, false);
    let failures_total = failures.len();
    let actions_total = actions.len();
    let build = |op_detail: &[Value],
                 action_list: &[Value],
                 slowest_list: &[Value],
                 failure_list: &[Value],
                 marks: [bool; 5],
                 policy: &str| {
        let mut m = root(ops_value(op_detail.len()));
        m.insert("op".into(), Value::Array(op_detail.to_vec()));
        let shown: Vec<Value> = failure_list.iter().take(FAILURES).cloned().collect();
        m.insert("failures".into(), Value::Array(shown));
        m.insert(
            "failures_truncated".into(),
            int(failures_total.saturating_sub(failure_list.len().min(FAILURES)) as u64),
        );
        m.insert("slowest".into(), Value::Array(slowest_list.to_vec()));
        let shown: Vec<Value> = action_list.iter().take(ACTIONS).cloned().collect();
        m.insert("action".into(), Value::Array(shown));
        m.insert(
            "actions_truncated".into(),
            int(actions_total.saturating_sub(action_list.len().min(ACTIONS)) as u64),
        );
        m.insert(
            "truncated".into(),
            json!({"op_detail": marks[1], "op_races": marks[0], "actions": marks[2],
                                            "slowest": marks[3], "failures": marks[4]}),
        );
        m.insert("bytes_policy".into(), json!(policy));
        serde_json::to_string(&Value::Object(m)).unwrap_or_default() + "\n"
    };
    let marks = |r, d, a, s, f| [r, d, a, s, f];
    let mut text = build(
        &op_detail,
        &action_list,
        &slowest_list,
        &failure_list,
        [false; 5],
        "within",
    );
    if text.len() > ceiling {
        // (a) the races of the detailed operations
        t_races = true;
        op_detail = op_ordinals.iter().map(|&op| view.op(op, false)).collect();
        text = build(
            &op_detail,
            &action_list,
            &slowest_list,
            &failure_list,
            marks(t_races, t_detail, t_actions, t_slowest, t_failures),
            "trimmed",
        );
    }
    if text.len() > ceiling {
        // (b) entries the primary or failures[] already carry, then newest first
        t_detail = true;
        let carried: Vec<usize> = primary
            .map(|p| p.op)
            .into_iter()
            .chain(later.iter().copied())
            .collect();
        op_ordinals.retain(|op| !carried.contains(op));
        op_detail = op_ordinals.iter().map(|&op| view.op(op, false)).collect();
        text = build(
            &op_detail,
            &action_list,
            &slowest_list,
            &failure_list,
            marks(t_races, t_detail, t_actions, t_slowest, t_failures),
            "trimmed",
        );
        while text.len() > ceiling && !op_detail.is_empty() {
            op_detail.pop();
            text = build(
                &op_detail,
                &action_list,
                &slowest_list,
                &failure_list,
                marks(t_races, t_detail, t_actions, t_slowest, t_failures),
                "trimmed",
            );
        }
    }
    if text.len() > ceiling {
        // (c) actions beyond the first and the first failed/cancelled/yielded one
        t_actions = true;
        action_list = keep_actions(&actions);
        text = build(
            &op_detail,
            &action_list,
            &slowest_list,
            &failure_list,
            marks(t_races, t_detail, t_actions, t_slowest, t_failures),
            "trimmed",
        );
    }
    if text.len() > ceiling {
        // (d) slowest
        t_slowest = true;
        slowest_list.clear();
        text = build(
            &op_detail,
            &action_list,
            &slowest_list,
            &failure_list,
            marks(t_races, t_detail, t_actions, t_slowest, t_failures),
            "trimmed",
        );
    }
    if text.len() > ceiling {
        // (e) failures beyond the first two
        t_failures = true;
        failure_list.truncate(2);
        text = build(
            &op_detail,
            &action_list,
            &slowest_list,
            &failure_list,
            marks(t_races, t_detail, t_actions, t_slowest, t_failures),
            "trimmed",
        );
    }
    if force_compact || text.len() > ceiling {
        // The compact form: no op[], no slowest; two failures, two actions.
        let mut m = root(ops_value(0));
        m.insert(
            "failures".into(),
            Value::Array(failures.iter().take(2).cloned().collect()),
        );
        m.insert(
            "failures_truncated".into(),
            int(failures_total.saturating_sub(2) as u64),
        );
        m.insert("action".into(), Value::Array(keep_actions(&actions)));
        m.insert(
            "actions_truncated".into(),
            int(actions_total.saturating_sub(keep_actions(&actions).len()) as u64),
        );
        m.insert("truncated".into(), json!({"op_detail": true, "op_races": true, "actions": true, "slowest": true, "failures": true}));
        m.insert("bytes_policy".into(), json!("compact"));
        text = serde_json::to_string(&Value::Object(m)).unwrap_or_default() + "\n";
    }
    if text.len() > ceiling {
        return overflow(ctx.handler, outcome, &chain, &primary_value);
    }
    text
}

/// The first action and the first failed, cancelled or yielded one.
fn keep_actions(actions: &[Value]) -> Vec<Value> {
    let mut kept: Vec<Value> = actions.first().cloned().into_iter().collect();
    if let Some(a) = actions.iter().skip(1).find(|a| a["status"] != "completed") {
        kept.push(a.clone());
    }
    kept
}

/// Never an oversized row: an implementation defect writes this instead, which
/// the parser reads as UNAVAILABLE evidence, never as a zero-valued row.
pub fn overflow(handler: &str, outcome: &str, chain: &Value, primary: &Value) -> String {
    let primary = if primary.is_null() {
        Value::Null
    } else {
        json!({"op": primary["op"], "kind": primary["kind"], "phase": primary["phase"], "outcome": primary["outcome"]})
    };
    serde_json::to_string(
        &json!({"schema": SCHEMA, "event": "storage_phases_overflow", "handler": handler,
        "outcome": outcome, "chain": chain, "primary": primary}),
    )
    .unwrap_or_default()
        + "\n"
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage_witness::{Category, Chain, Context, FailureRecord, Role, Scope, Witness};
    use opencast_worker_database_core::{
        lifecycle::{Failure, Kind, Outcome, Phase},
        race::{Limit, RaceEnd, RaceStart},
    };

    fn race(
        w: &mut Witness,
        op: usize,
        boundary: &'static str,
        start: u64,
        end: u64,
        status: RaceStatus,
    ) {
        let r = w.push_race(
            op,
            RaceStart {
                boundary,
                limit: Limit::StatementMs,
                budget_ms: 4_000,
                start_ms: start,
                steps_total: None,
            },
            start + 12_000,
            Scope::Main,
        );
        w.race_end(
            r,
            RaceEnd {
                end_ms: end,
                status,
                submitted: true,
                sqlstate: None,
            },
        );
    }
    /// One read operation: connect, read and close, `read_ms` of read.
    fn read(w: &mut Witness, op_id: &str, at: u64, read_ms: u64, status: RaceStatus) -> usize {
        let op = w.open_op(op_id, Role::Operation, true, None, at);
        race(w, op, "connect", at, at + 5, RaceStatus::Completed);
        race(w, op, "read", at + 5, at + 5 + read_ms, status);
        race(
            w,
            op,
            "close",
            at + 5 + read_ms,
            at + 6 + read_ms,
            RaceStatus::Completed,
        );
        let (status, failure) = if status == RaceStatus::Completed {
            (OpStatus::Completed, None)
        } else {
            (
                OpStatus::Failed,
                Some(FailureRecord::of(&Failure::new(
                    Kind::Deadline,
                    Phase::Read,
                ))),
            )
        };
        w.op_end(op, status, failure, Some((1, 0)), false, at + 6 + read_ms);
        op
    }
    fn parse(line: &str) -> Value {
        assert!(
            line.ends_with('\n') && line.len() <= CEILING,
            "{} bytes",
            line.len()
        );
        serde_json::from_str(line.trim_end()).expect("one JSON object")
    }
    fn dispatch(origin: u64) -> Witness {
        let mut w = Witness::new(origin);
        w.context = Context {
            handler: "dispatch",
            handler_main_ms: 12_000,
            budget_scope: "main",
            budget_source: "HANDLER_MS",
            ..Default::default()
        };
        w
    }

    /// An OutboxRelease whose future the owner drops mid-transaction counts as
    /// attempted and unknown, never acknowledged: after the replies to BEGIN and
    /// the gate, and after submission with no reply yet.
    #[test]
    fn a_dropped_outbox_release_is_attempted_and_unknown() {
        for replies in [2, 0] {
            let mut w = dispatch(0);
            let op = w.open_op("B10", Role::Operation, false, None, 10);
            race(&mut w, op, "connect", 10, 15, RaceStatus::Completed);
            let r = w.push_race(
                op,
                RaceStart {
                    boundary: "transaction",
                    limit: Limit::StatementMs,
                    budget_ms: 4_000,
                    start_ms: 15,
                    steps_total: Some(5),
                },
                12_000,
                Scope::Main,
            );
            w.race_submitted(r);
            for step in ["begin", "gate"].into_iter().take(replies) {
                w.race_step(r, step, 20, None);
            }
            w.op_end(op, OpStatus::Dropped, None, None, false, 40);
            let v = parse(&line(
                &w,
                &Inputs {
                    outcome: "cancelled",
                    now_ms: 50,
                    perf_now: 50.0,
                },
            ));
            assert_eq!(
                v["recovery"]["outbox_release"],
                json!({"acknowledged_txns": 0, "attempted_txns": 1, "unknown_txns": 1}),
                "{replies} replies"
            );
            assert_eq!(v["primary"]["race"]["submitted"], true);
            assert_eq!(v["primary"]["race"]["steps_completed"], replies);
        }
    }

    /// A completed exchange whose ignored close failed, then a Decode or
    /// Assertion failure: the primary keeps race null, never the close; a
    /// later work-race timeout is found as its own; a later race-free failure
    /// stays race-free; a later drop during its close names that close.
    #[test]
    fn a_race_free_failure_never_takes_a_cleanup_race() {
        for kind in [Kind::Decode, Kind::Assertion] {
            let mut w = dispatch(0);
            let exchange = |w: &mut Witness, id: &str, at: u64, failure: Kind| {
                let op = w.open_op(id, Role::Operation, true, None, at);
                race(w, op, "connect", at, at + 5, RaceStatus::Completed);
                race(w, op, "read", at + 5, at + 10, RaceStatus::Completed);
                race(w, op, "close", at + 10, at + 510, RaceStatus::Timeout);
                let mut f = Failure::new(failure, Phase::Read);
                f.outcome = Outcome::NotApplicable;
                w.op_end(
                    op,
                    OpStatus::Failed,
                    Some(FailureRecord::of(&f)),
                    None,
                    false,
                    at + 510,
                );
            };
            exchange(&mut w, "A01", 10, kind);
            read(&mut w, "A02", 600, 4_000, RaceStatus::Timeout);
            exchange(&mut w, "A03", 5_000, kind);
            let dropped = w.open_op("A04", Role::Operation, true, None, 6_000);
            race(&mut w, dropped, "read", 6_000, 6_010, RaceStatus::Completed);
            w.push_race(
                dropped,
                RaceStart {
                    boundary: "close",
                    limit: Limit::CloseMs,
                    budget_ms: 500,
                    start_ms: 6_010,
                    steps_total: None,
                },
                18_000,
                Scope::Main,
            );
            w.op_end(dropped, OpStatus::Dropped, None, None, false, 6_100);
            let v = parse(&line(
                &w,
                &Inputs {
                    outcome: "failed",
                    now_ms: 6_200,
                    perf_now: 6_200.0,
                },
            ));
            let primary = &v["primary"];
            assert_eq!(
                (
                    &primary["op"],
                    &primary["kind"],
                    &primary["race"],
                    &primary["overshoot_ms"]
                ),
                (
                    &json!("A01"),
                    &json!(format!("{kind:?}")),
                    &Value::Null,
                    &Value::Null
                ),
                "{primary}"
            );
            let failures = v["failures"].as_array().expect("failures");
            let shape: Vec<(Value, Value, Value)> = failures
                .iter()
                .map(|f| {
                    (
                        f["op"].clone(),
                        f["race"]["boundary"].clone(),
                        f["race"]["status"].clone(),
                    )
                })
                .collect();
            assert_eq!(
                shape,
                vec![
                    (json!("A02"), json!("read"), json!("timeout")),
                    (json!("A03"), Value::Null, Value::Null),
                    (json!("A04"), json!("close"), json!("dropped")),
                ],
                "{}",
                v["failures"]
            );
        }
    }

    #[test]
    fn intervals_union_once() {
        assert_eq!(
            union_ms(vec![(0, 10), (5, 20), (30, 40), (40, 41), (50, 50)]),
            31
        );
        assert_eq!(union_ms(vec![]), 0);
    }

    #[test]
    fn a_small_tick_is_within_the_ceiling_with_every_field() {
        let mut w = dispatch(1_000);
        w.scheduled_ms = Some(990);
        let a = read(&mut w, "A01", 1_010, 100, RaceStatus::Completed);
        // A readback runs after its parent: the union counts both, no idle between.
        let rb = w.open_op("B10.readback", Role::Readback, true, Some(a), 1_116);
        race(&mut w, rb, "read", 1_116, 1_200, RaceStatus::Completed);
        w.op_end(rb, OpStatus::Completed, None, Some((0, 0)), false, 1_200);
        w.record(Category::Alert, 1_200, 1_300);
        let v = parse(&line(
            &w,
            &Inputs {
                outcome: "ok",
                now_ms: 1_400,
                perf_now: 400.0,
            },
        ));
        assert_eq!(v["schema"], 2);
        assert_eq!(v["event"], "storage_phases");
        assert_eq!(v["bytes_policy"], "within");
        assert_eq!(v["wall_ms"], 400);
        assert_eq!(v["scheduled_lag_ms"], 10);
        assert_eq!(v["durations"]["storage"], 190);
        assert_eq!(v["durations"]["alert"], 100);
        assert_eq!(v["durations"]["idle"], 400 - 290);
        assert_eq!(v["ops"]["total"], 2);
        assert_eq!(v["ops"]["readbacks"], 1);
        assert_eq!(v["primary"], Value::Null);
        assert_eq!(v["prior"], Value::Null);
        assert_eq!(v["recovery"]["page_repeated"], "unknown");
        assert_eq!(v["summary"]["races"]["total"], 4);
        assert_eq!(v["budget"]["handler_main_ms"], 12_000);
        for key in [
            "durations",
            "ops",
            "budget",
            "prior",
            "recovery",
            "summary",
            "op",
            "primary",
            "failures",
            "failures_truncated",
            "slowest",
            "action",
            "actions_truncated",
            "chain",
            "message_age_ms",
            "sent",
            "posts",
            "truncated",
            "bytes_policy",
            "identity",
            "date_vs_perf_ms",
        ] {
            assert!(v.get(key).is_some(), "{key}");
        }
    }

    /// A synthetic accumulator record: 300 recorded operations, a
    /// primary at ordinal 90, four later failures, sixteen actions.
    fn accumulator() -> Witness {
        let mut w = dispatch(0);
        w.context.handler = "cleanup";
        w.context.chain = Some(Chain {
            feed: "f".repeat(64),
            generation: 7,
            step: 3,
            attempts: 2,
            message_digest: Some("a".repeat(16)),
        });
        for i in 0..300u64 {
            let status = if i == 89 || (95..99).contains(&i) {
                RaceStatus::Timeout
            } else {
                RaceStatus::Completed
            };
            if i % 18 == 0 {
                w.action_start(
                    ["scan", "prepare", "drain", "outbox", "settle"][(i as usize / 18) % 5],
                    i * 100,
                );
            }
            read(&mut w, "e_retire_observations", i * 100, 1_200 + i, status);
            if i % 18 == 17 {
                w.action_end(
                    "staged_and_continued_long",
                    if i % 36 == 17 { "yielded" } else { "completed" },
                    Some(300),
                    i * 100 + 99,
                );
            }
        }
        w
    }

    #[test]
    fn the_accumulator_record_keeps_its_primary_and_summary_under_the_ceiling() {
        let w = accumulator();
        let text = line(
            &w,
            &Inputs {
                outcome: "failed",
                now_ms: 40_000,
                perf_now: 40_000.0,
            },
        );
        let v = parse(&text);
        assert_ne!(v["bytes_policy"], "within");
        assert_eq!(v["primary"]["ordinal"], 90);
        assert_eq!(v["primary"]["race"]["boundary"], "read");
        assert_eq!(v["primary"]["race"]["status"], "timeout");
        assert_eq!(v["ops"]["total"], 300);
        assert_eq!(v["summary"]["races"]["total"], 900);
        assert_eq!(v["summary"]["read"]["timeouts"], 5);
        assert_eq!(v["prior"]["all_within_local_caps"], "true");
        assert!(v["ops"]["detailed"].as_u64().unwrap() <= 16);
        assert_eq!(
            v["ops"]["omitted"].as_u64().unwrap() + v["ops"]["detailed"].as_u64().unwrap(),
            300
        );
    }

    #[test]
    fn exhausted_trimming_never_exceeds_the_ceiling_and_the_compact_form_stays_within_its_computed_bound(
    ) {
        // Long, failing, fully detailed: every trim runs.
        let mut w = accumulator();
        for a in w.actions.iter_mut() {
            a.status = "cancelled";
            a.result = "x".repeat(24);
        }
        let inputs = Inputs {
            outcome: "cancelled",
            now_ms: 40_000,
            perf_now: 0.0,
        };
        let trimmed = parse(&line(&w, &inputs));
        assert_eq!(trimmed["primary"]["ordinal"], 90);
        // The compact form itself (compact_width.py's model, schema 2): 6,349 bytes at most.
        let compact = render(&w, &inputs, CEILING, true);
        let v = parse(&compact);
        assert!(
            compact.len() <= 6_349,
            "compact line {} bytes",
            compact.len()
        );
        assert_eq!(v["bytes_policy"], "compact");
        assert!(v.get("op").is_none() && v.get("slowest").is_none());
        assert_eq!(v["primary"]["ordinal"], 90);
        assert!(
            v["failures"].as_array().unwrap().len() <= 2
                && v["action"].as_array().unwrap().len() <= 2
        );
        // A line that cannot fit even compact is never written: the overflow event is.
        let over: Value =
            serde_json::from_str(render(&w, &inputs, 1_000, false).trim_end()).unwrap();
        assert_eq!(over["event"], "storage_phases_overflow");
        assert_eq!(over["primary"]["op"], "e_retire_observations");
    }

    /// Why the compact fallback is unreachable at the production ceiling while
    /// every width holds: after trimming (e) the line is the compact form plus
    /// exactly the two empty arrays `op` and `slowest` (21 bytes); the compact
    /// form is at most 6,349 bytes, so a fully trimmed line is at most 6,370,
    /// under 8,192. Only a width defect can need the fallback (the overflow
    /// event covers that). The ceilings below are this arithmetic, not a path.
    #[test]
    fn the_fully_trimmed_line_is_the_compact_form_plus_two_empty_arrays() {
        let mut w = accumulator();
        for a in w.actions.iter_mut() {
            a.status = "cancelled";
            a.result = "x".repeat(24);
        }
        let inputs = Inputs {
            outcome: "cancelled",
            now_ms: 40_000,
            perf_now: 0.0,
        };
        let compact = render(&w, &inputs, CEILING, true);
        let trimmed = render(&w, &inputs, compact.len() + 21, false);
        let v = parse(&trimmed);
        assert_eq!(v["bytes_policy"], "trimmed");
        assert_eq!((&v["op"], &v["slowest"]), (&json!([]), &json!([])));
        assert_eq!(trimmed.len(), compact.len() + 21);
        // One byte less and the renderer falls back to the compact form itself.
        assert_eq!(render(&w, &inputs, compact.len() + 20, false), compact);
        assert!(compact.len() + 21 <= 6_349 + 21 && 6_349 + 21 < CEILING);
    }

    /// A cancelled consume whose line the renderer trims (its op detail and its
    /// actions beyond the kept two) and the delivery that resumes it: the
    /// protected recovery object survives the emitter's own trimming. The two
    /// lines are the parser's trimmed-recovery fixture
    /// (`FeedPollingWorker/storage_phases/trimmed_recovery.jsonl`), checked here
    /// so the fixture is always what this emitter writes.
    fn trimmed_recovery_trace() -> (String, String) {
        let checkpoint = |cursor: i64, status: &'static str| crate::storage_witness::Checkpoint {
            kind: "drain",
            phase: None,
            candidate_cursor: Some(cursor),
            status: Some(status),
        };
        let mut w = accumulator();
        w.context.handler = "consume";
        w.context.budget_scope = "step";
        w.context.budget_source = "STEP_DEADLINE";
        w.context.handler_main_ms = 200_000;
        w.context.delivery_start = Some(0);
        w.context.consume_outcome = Some("cancelled");
        let names = ["drain", "outbox", "settle"];
        let count = w.actions.len();
        for (i, a) in w.actions.iter_mut().enumerate() {
            // The last, open action is a settle: its checkpoint the attempted one.
            a.name = if i + 1 == count {
                "settle"
            } else {
                names[i % 3]
            };
            a.result = "x".repeat(24);
            a.start_checkpoint = Some(checkpoint(i as i64 * 100, "committed"));
            a.end_checkpoint = Some(checkpoint(
                (i as i64 + 1) * 100,
                if i + 1 == count {
                    "unknown"
                } else {
                    "committed"
                },
            ));
        }
        let cancelled = line(
            &w,
            &Inputs {
                outcome: "cancelled",
                now_ms: 40_000,
                perf_now: 40_000.0,
            },
        );
        let mut r = dispatch(0);
        r.context.handler = "consume";
        r.context.budget_scope = "step";
        r.context.budget_source = "STEP_DEADLINE";
        r.context.handler_main_ms = 200_000;
        r.context.delivery_start = Some(0);
        r.context.consume_outcome = Some("continued");
        r.context.chain = Some(Chain {
            feed: "f".repeat(64),
            generation: 7,
            step: 3,
            attempts: 3,
            message_digest: Some("a".repeat(16)),
        });
        r.action_start("drain", 5);
        r.checkpoint_start("drain", None, Some(count as i64 * 100));
        read(&mut r, "B08", 10, 20, RaceStatus::Completed);
        r.action_end("continued", "completed", None, 40);
        let resuming = line(
            &r,
            &Inputs {
                outcome: "ok",
                now_ms: 50,
                perf_now: 50.0,
            },
        );
        (cancelled, resuming)
    }

    #[test]
    fn a_trimmed_line_keeps_its_protected_recovery() {
        let (cancelled, resuming) = trimmed_recovery_trace();
        let v = parse(&cancelled);
        assert_eq!(v["bytes_policy"], "trimmed");
        assert_eq!(v["truncated"]["actions"], true);
        assert_eq!(v["action"].as_array().unwrap().len(), 2);
        let last = &v["recovery"]["last_action"];
        assert_eq!(last["name"], "settle");
        assert_eq!(last["end_checkpoint"]["status"], "unknown");
        assert_eq!(v["recovery"]["first_action"]["name"], "drain");
        assert!(v["recovery"]["admission_ms"].is_u64());
        let fixture = include_str!("../../FeedPollingWorker/storage_phases/trimmed_recovery.jsonl");
        let expected = format!("{cancelled}{resuming}");
        if std::env::var_os("STORAGE_PHASES_WRITE_FIXTURE").is_some() {
            std::fs::write(
                concat!(
                    env!("CARGO_MANIFEST_DIR"),
                    "/../FeedPollingWorker/storage_phases/trimmed_recovery.jsonl"
                ),
                &expected,
            )
            .unwrap();
            return;
        }
        assert_eq!(
            fixture, expected,
            "the parser's fixture is what this emitter writes"
        );
    }

    /// Every property path of a value: `.a.b`, arrays by their first element.
    fn paths(value: &Value, prefix: &str, out: &mut Vec<String>) {
        match value {
            Value::Object(map) => {
                for (key, item) in map {
                    paths(item, &format!("{prefix}.{key}"), out);
                }
            }
            Value::Array(items) => match items.first() {
                Some(first) => paths(first, &format!("{prefix}[]"), out),
                None => out.push(format!("{prefix}[]")),
            },
            _ => out.push(prefix.to_owned()),
        }
    }

    #[test]
    fn the_compact_form_has_exactly_the_compact_model_s_properties() {
        // Every nullable object present, so the paths are the full shape.
        let mut w = accumulator();
        w.scheduled_ms = Some(0);
        w.context.delivery_start = Some(0);
        w.context.sent = Some(crate::storage_witness::Sent {
            step: 4,
            delay_s: 0,
            result: "ok",
        });
        w.context.posts = Some(crate::storage_witness::Posts {
            n: 1,
            accepted: 1,
            retried: 0,
        });
        let checkpoint = crate::storage_witness::Checkpoint {
            kind: "drain",
            phase: None,
            candidate_cursor: Some(100),
            status: Some("committed"),
        };
        for (i, a) in w.actions.iter_mut().enumerate() {
            a.name = "drain";
            a.status = if i == 0 { "completed" } else { "cancelled" };
            a.start_checkpoint = Some(checkpoint.clone());
            a.end_checkpoint = Some(checkpoint.clone());
            a.wait_remaining_s = Some(0);
        }
        let compact = render(
            &w,
            &Inputs {
                outcome: "failed",
                now_ms: 40_000,
                perf_now: 0.0,
            },
            CEILING,
            true,
        );
        let value = parse(&compact);
        let mut found = vec![];
        paths(&value, "", &mut found);
        found.sort();
        let model: Vec<String> = serde_json::from_str(include_str!(
            "../../FeedPollingWorker/storage_phases/compact_keys.json"
        ))
        .unwrap();
        assert_eq!(found, model);
    }

    #[test]
    fn the_overflow_line_names_the_handler_and_the_primary_only() {
        let v: Value = serde_json::from_str(overflow("cleanup", "failed", &Value::Null,
            &json!({"op": "A01", "kind": "Deadline", "phase": "read", "outcome": "NotApplicable", "race": {}})).trim_end()).unwrap();
        assert_eq!(v["event"], "storage_phases_overflow");
        assert_eq!(v["primary"]["kind"], "Deadline");
        assert!(v["primary"].get("race").is_none());
    }
}
