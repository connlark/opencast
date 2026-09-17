//! Durable, content-free reservations for optional inference. Reservations
//! are never refunded: a lost response or reset cannot prove a call was free.
//! The DO serializes each mutation and persists it before external I/O.

use serde::{Deserialize, Serialize};

use crate::{gap_repair, job::JobRecord};

pub const CHUNK_WALL_MILLIS: i64 = 60_000;
pub const CALL_WALL_MILLIS: i64 = 20_000;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Attempt {
    pub chunk_index: u32,
    pub gap_start: f64,
    pub gap_end: f64,
    pub ordinal: u32,
    pub window_start: f64,
    pub window_end: f64,
    pub issued: bool,
    pub outcome: String,
}

impl Attempt {
    pub fn seconds(&self) -> f64 {
        self.window_end - self.window_start
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Reservation {
    Reserved(usize),
    Unaffordable,
    ChunkLimit,
    AlreadyAttempted,
    Inactive,
}

pub fn is_active(record: &JobRecord) -> bool {
    matches!(
        record.state.as_str(),
        crate::job::STATE_CHUNKING | crate::job::STATE_TRANSCRIBING
    )
}

pub fn ledger(record: &JobRecord, chunk_index: u32) -> gap_repair::AttemptLedger {
    let mut ledger = gap_repair::AttemptLedger::default();
    for attempt in record
        .gap_repair_attempts
        .iter()
        .filter(|a| a.chunk_index == chunk_index)
    {
        // The ordinal includes skipped local candidates, so restore the
        // actual retry offset instead of just counting successful calls.
        let gap = gap_repair::Gap {
            start: attempt.gap_start,
            end: attempt.gap_end,
        };
        while ledger.attempts_for(&gap) <= attempt.ordinal {
            ledger.record(&gap);
        }
    }
    ledger
}

pub fn reserve(
    record: &mut JobRecord,
    chunk_index: u32,
    gap: &gap_repair::Gap,
    ordinal: u32,
    window: &gap_repair::Window,
    now_millis: i64,
) -> Reservation {
    if !is_active(record) {
        return Reservation::Inactive;
    }
    let deadline = record
        .gap_repair_deadlines
        .entry(chunk_index)
        .or_insert(now_millis.saturating_add(CHUNK_WALL_MILLIS));
    if now_millis >= *deadline
        || record
            .gap_repair_attempts
            .iter()
            .filter(|a| a.chunk_index == chunk_index)
            .count()
            >= gap_repair::MAX_CALLS_PER_CHUNK as usize
    {
        return Reservation::ChunkLimit;
    }
    if ordinal >= gap_repair::MAX_ATTEMPTS_PER_GAP
        || ledger(record, chunk_index).attempts_for(gap) > ordinal
    {
        return Reservation::AlreadyAttempted;
    }
    let cap =
        gap_repair::job_audio_cap_seconds(record.canonical_duration_seconds.unwrap_or_default());
    if !window.start.is_finite()
        || !window.end.is_finite()
        || window.length() <= 0.0
        || record.gap_repair_audio_seconds + window.length() > cap
    {
        return Reservation::Unaffordable;
    }
    let id = record.gap_repair_attempts.len();
    record.gap_repair_audio_seconds += window.length();
    record.gap_repair_attempts.push(Attempt {
        chunk_index,
        gap_start: gap.start,
        gap_end: gap.end,
        ordinal,
        window_start: window.start,
        window_end: window.end,
        issued: false,
        outcome: "reserved".into(),
    });
    Reservation::Reserved(id)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gap_repair::{Gap, Window};

    fn record() -> JobRecord {
        let mut r = JobRecord::created(
            "job".into(),
            "account".into(),
            "episode".into(),
            None,
            None,
            None,
            None,
            0,
        );
        r.state = crate::job::STATE_TRANSCRIBING.into();
        r.canonical_duration_seconds = Some(1200.0);
        r
    }

    #[test]
    fn siblings_and_reentry_share_one_nonrefundable_allowance() {
        let mut r = record();
        let gap = Gap {
            start: 0.0,
            end: 97.0,
        };
        let window = Window {
            start: 0.0,
            end: 100.0,
        };
        assert_eq!(
            reserve(&mut r, 0, &gap, 0, &window, 1),
            Reservation::Reserved(0)
        );
        for sibling in 1..4 {
            assert_eq!(
                reserve(&mut r, sibling, &gap, 0, &window, 1),
                Reservation::Unaffordable
            );
        }
        // A failed R2 write/reset never refunds the first reservation.
        let mut restored: JobRecord =
            serde_json::from_slice(&serde_json::to_vec(&r).unwrap()).unwrap();
        assert_eq!(restored.gap_repair_audio_seconds, 100.0);
        assert_eq!(
            reserve(&mut restored, 0, &gap, 0, &window, 2),
            Reservation::AlreadyAttempted
        );
        assert_eq!(
            reserve(
                &mut restored,
                1,
                &gap,
                0,
                &Window {
                    start: 0.0,
                    end: 80.0
                },
                2
            ),
            Reservation::Reserved(1)
        );
        assert_eq!(restored.gap_repair_audio_seconds, 180.0);
        assert_eq!(restored.requested_audio_seconds, 0.0);
    }

    #[test]
    fn terminal_state_call_count_and_persisted_deadline_refuse_optional_work() {
        let gap = Gap {
            start: 0.0,
            end: 5.0,
        };
        let window = Window {
            start: 0.0,
            end: 8.0,
        };
        for state in [
            crate::job::STATE_CANCELLED,
            crate::job::STATE_CANCELLING,
            crate::job::STATE_FAILED,
            crate::job::STATE_STITCHING,
        ] {
            let mut r = record();
            r.state = state.into();
            assert_eq!(
                reserve(&mut r, 0, &gap, 0, &window, 1),
                Reservation::Inactive
            );
            assert_eq!(r.gap_repair_audio_seconds, 0.0);
        }
        let mut r = record();
        reserve(&mut r, 0, &gap, 0, &window, 1);
        assert_eq!(
            reserve(&mut r, 0, &gap, 1, &window, CHUNK_WALL_MILLIS + 1),
            Reservation::ChunkLimit
        );
        let mut r = record();
        for i in 0..gap_repair::MAX_CALLS_PER_CHUNK {
            let gap = Gap {
                start: i as f64 * 10.0,
                end: i as f64 * 10.0 + 5.0,
            };
            assert!(matches!(
                reserve(&mut r, 0, &gap, 0, &window, 1),
                Reservation::Reserved(_)
            ));
        }
        assert_eq!(
            reserve(
                &mut r,
                0,
                &Gap {
                    start: 90.0,
                    end: 96.0
                },
                0,
                &window,
                1
            ),
            Reservation::ChunkLimit
        );
    }
}
