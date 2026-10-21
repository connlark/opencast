//! The storage timing witness's view of one race: what bounded it at its start,
//! how long it ran and how it ended. A `Database` reports its races to a sink
//! only when one is installed; without one nothing is recorded and every
//! deadline, cancellation and outcome is exactly as before.
use crate::lifecycle::{Failure, Kind};
use serde::Serialize;

/// The bound that limited a race's budget at its start.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Limit {
    /// The enclosing operation's absolute deadline, below the race's own cap.
    AuthorityDeadline,
    ConnectMs,
    StatementMs,
    TransactionMs,
    /// The segment's own HANDLER_MS window.
    HandlerEnd,
    CloseMs,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum RaceStatus {
    Completed,
    Timeout,
    Cancelled,
    /// Transport or driver failure: no server error code.
    Driver,
    /// The server answered an error (its SQLSTATE is recorded).
    Database,
    /// The race's future was dropped before it ended (recorded by the sink's owner).
    Dropped,
}

impl RaceStatus {
    /// The race's own ending. A decode or assertion failure after a completed
    /// exchange is the operation's failure, not the race's.
    pub fn of(failure: Option<&Failure>) -> Self {
        match failure {
            None => Self::Completed,
            Some(failure) => match failure.kind {
                Kind::Deadline => Self::Timeout,
                Kind::Cancelled => Self::Cancelled,
                Kind::Database if failure.sqlstate.is_some() => Self::Database,
                Kind::Database | Kind::Driver | Kind::TlsUnavailable | Kind::Injected => {
                    Self::Driver
                }
                Kind::Configuration | Kind::Decode | Kind::Assertion => Self::Completed,
            },
        }
    }
}

pub struct RaceStart {
    /// `connect`, `read`, `transaction`, `rollback`, `close` or `statement`.
    pub boundary: &'static str,
    pub limit: Limit,
    pub budget_ms: u64,
    /// Epoch milliseconds, the clock every storage deadline uses.
    pub start_ms: u64,
    /// The pipeline length (BEGIN, gate, statements, COMMIT) of a write race.
    pub steps_total: Option<u32>,
}

pub struct RaceEnd {
    pub end_ms: u64,
    pub status: RaceStatus,
    pub submitted: bool,
    pub sqlstate: Option<String>,
}

/// Receives one storage segment's races. Every call is synchronous and never
/// awaits, so an implementation may borrow shared state for its duration.
pub trait RaceSink {
    fn start(&self, race: RaceStart) -> usize;
    /// The race's work was first polled, which is where the driver marks a
    /// request submitted: a race dropped from now on was submitted.
    fn submitted(&self, race: usize);
    /// One pipelined step's reply arrived; the gate's reply carries its wait.
    fn step(&self, race: usize, boundary: &'static str, at_ms: u64, gate_wait_us: Option<i64>);
    fn finish(&self, race: usize, end: RaceEnd);
}

/// The bound a race started at `now` hits first, and its budget. `local` is the
/// race's own cap; each other bound is an absolute end. The earliest absolute
/// end binds, so of several bounds already past, the one that expired first;
/// a tie goes to the local cap (nothing truncated it), then to the earlier
/// entry. The budget is that end's remainder, zero once past.
pub fn binding(now: u64, local: (u64, Limit), ends: &[(Option<u64>, Limit)]) -> (u64, Limit) {
    let local_end = (now.saturating_add(local.0), local.1);
    let (end, limit) = ends
        .iter()
        .fold(local_end, |best, &(end, limit)| match end {
            Some(end) if end < best.0 => (end, limit),
            _ => best,
        });
    (end.saturating_sub(now), limit)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lifecycle::Phase;

    #[test]
    fn the_first_bound_to_expire_limits_a_race_and_a_tie_keeps_the_local_cap() {
        let local = (4_000, Limit::StatementMs);
        assert_eq!(binding(1_000, local, &[]), (4_000, Limit::StatementMs));
        // The authority truncates the race below its own cap, zero included.
        assert_eq!(
            binding(1_000, local, &[(Some(2_500), Limit::AuthorityDeadline)]),
            (1_500, Limit::AuthorityDeadline)
        );
        assert_eq!(
            binding(9_000, local, &[(Some(2_500), Limit::AuthorityDeadline)]),
            (0, Limit::AuthorityDeadline)
        );
        assert_eq!(
            binding(1_000, local, &[(Some(5_000), Limit::AuthorityDeadline)]),
            (4_000, Limit::StatementMs)
        );
        // The earliest of several bounds wins; an absent one is ignored.
        assert_eq!(
            binding(
                0,
                local,
                &[
                    (None, Limit::TransactionMs),
                    (Some(3_000), Limit::HandlerEnd),
                    (Some(2_000), Limit::AuthorityDeadline),
                ]
            ),
            (2_000, Limit::AuthorityDeadline)
        );
    }

    #[test]
    fn of_several_bounds_already_past_the_one_that_expired_first_binds() {
        let local = (4_000, Limit::StatementMs);
        // The transaction cap is listed first, the authority expired first.
        assert_eq!(
            binding(
                10_000,
                local,
                &[
                    (Some(9_000), Limit::TransactionMs),
                    (Some(8_000), Limit::AuthorityDeadline),
                ]
            ),
            (0, Limit::AuthorityDeadline)
        );
        // An authority that expired before the handler window and the
        // transaction cap, with an absent bound between them.
        assert_eq!(
            binding(
                10_000,
                local,
                &[
                    (Some(9_900), Limit::TransactionMs),
                    (None, Limit::TransactionMs),
                    (Some(9_500), Limit::HandlerEnd),
                    (Some(9_000), Limit::AuthorityDeadline),
                ]
            ),
            (0, Limit::AuthorityDeadline)
        );
        // Genuinely equal ends: the local cap keeps a tie, then the earlier entry.
        assert_eq!(
            binding(10_000, local, &[(Some(14_000), Limit::AuthorityDeadline)]),
            (4_000, Limit::StatementMs)
        );
        assert_eq!(
            binding(
                10_000,
                local,
                &[
                    (Some(12_000), Limit::TransactionMs),
                    (Some(12_000), Limit::AuthorityDeadline),
                ]
            ),
            (2_000, Limit::TransactionMs)
        );
        assert_eq!(
            binding(
                10_000,
                local,
                &[
                    (Some(8_000), Limit::HandlerEnd),
                    (Some(8_000), Limit::AuthorityDeadline),
                ]
            ),
            (0, Limit::HandlerEnd)
        );
    }

    /// The budget a race records is the remaining time the core itself allows:
    /// the earliest end less now, saturated, capped by the local bound
    /// (`Database::remaining`'s rule), for every ordering of every bound.
    #[test]
    fn the_budget_is_the_effective_remaining_time_in_every_case() {
        let points = [
            None,
            Some(0),
            Some(5_000),
            Some(9_000),
            Some(10_000),
            Some(12_000),
            Some(14_000),
            Some(20_000),
        ];
        for now in [0, 9_000, 10_000, 15_000] {
            for local in [0, 500, 4_000] {
                for a in points {
                    for b in points {
                        for c in points {
                            let ends = [
                                (a, Limit::TransactionMs),
                                (b, Limit::HandlerEnd),
                                (c, Limit::AuthorityDeadline),
                            ];
                            let remaining = [a, b, c]
                                .into_iter()
                                .flatten()
                                .min()
                                .unwrap_or(u64::MAX)
                                .saturating_sub(now)
                                .min(local);
                            let (budget, limit) = binding(now, (local, Limit::StatementMs), &ends);
                            assert_eq!(budget, remaining, "now {now} local {local} {ends:?}");
                            // The rule before the earliest-end selection gave the
                            // same budget; only the named limit moved.
                            let previous =
                                ends.iter()
                                    .fold((local, Limit::StatementMs), |best, &(end, limit)| {
                                        match end {
                                            Some(end) if end.saturating_sub(now) < best.0 => {
                                                (end.saturating_sub(now), limit)
                                            }
                                            _ => best,
                                        }
                                    })
                                    .0;
                            assert_eq!(budget, previous, "now {now} local {local} {ends:?}");
                            // The named bound is one whose end is the earliest.
                            let earliest = [a, b, c].into_iter().flatten().min();
                            if limit != Limit::StatementMs {
                                let end = ends.iter().find(|e| e.1 == limit).and_then(|e| e.0);
                                assert_eq!(end, earliest, "now {now} local {local} {ends:?}");
                                assert!(end.unwrap() < now + local, "a tie keeps the local cap");
                            } else {
                                assert!(earliest.is_none_or(|e| e >= now + local));
                            }
                        }
                    }
                }
            }
        }
    }

    #[test]
    fn a_race_status_is_its_own_ending() {
        let failure = |kind| Failure::new(kind, Phase::Read);
        assert_eq!(RaceStatus::of(None), RaceStatus::Completed);
        assert_eq!(
            RaceStatus::of(Some(&failure(Kind::Deadline))),
            RaceStatus::Timeout
        );
        assert_eq!(
            RaceStatus::of(Some(&failure(Kind::Cancelled))),
            RaceStatus::Cancelled
        );
        assert_eq!(
            RaceStatus::of(Some(&failure(Kind::Driver))),
            RaceStatus::Driver
        );
        // A server error carries its SQLSTATE; a closed connection does not.
        let mut server = failure(Kind::Database);
        assert_eq!(RaceStatus::of(Some(&server)), RaceStatus::Driver);
        server.sqlstate = Some("57014".into());
        assert_eq!(RaceStatus::of(Some(&server)), RaceStatus::Database);
        // A decode failure after a completed exchange is the operation's.
        assert_eq!(
            RaceStatus::of(Some(&failure(Kind::Decode))),
            RaceStatus::Completed
        );
    }
}
