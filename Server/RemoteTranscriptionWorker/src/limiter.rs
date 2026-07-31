//! Global usage limiter: fair FIFO tickets in front of N inference-slot
//! holds, plus a daily spend backstop in micro-USD. Every wave renews its
//! ticket or hold; expired state is reaped on the next limiter operation so
//! a crashed job cannot wedge the queue.

use serde::{Deserialize, Serialize};

pub const USAGE_LIMITER_BINDING: &str = "TRANSCRIPTION_USAGE_LIMITER";
pub const GLOBAL_LIMITER_OBJECT: &str = "global";
pub const LIMITER_ADMIT_PATH: &str = "/admit";
pub const LIMITER_RELEASE_PATH: &str = "/release";
pub const LIMITER_INTERNAL_ORIGIN: &str = "https://usage-limiter.opencast.internal";

/// Long enough for the largest expected chunk-preparation pass, but bounded
/// so a crashed job cannot strand the queue indefinitely.
pub const HOLD_TTL_SECONDS: i64 = 600;
pub const TICKET_TTL_SECONDS: i64 = 60;
pub const DEFAULT_QUEUE_REMAINING_SECONDS: u32 = 64;

/// Published Large Turbo price: $0.0005 per audio minute.
pub const MICRO_USD_PER_AUDIO_SECOND_NUMERATOR: i64 = 500;
pub const MICRO_USD_PER_AUDIO_SECOND_DENOMINATOR: i64 = 60;

pub fn estimated_micro_usd(audio_seconds: f64) -> i64 {
    if !audio_seconds.is_finite() || audio_seconds <= 0.0 {
        return 0;
    }
    let scaled = audio_seconds * MICRO_USD_PER_AUDIO_SECOND_NUMERATOR as f64
        / MICRO_USD_PER_AUDIO_SECOND_DENOMINATOR as f64;
    scaled.ceil() as i64
}

fn default_max_slots() -> u32 {
    1
}

fn default_queue_remaining_seconds() -> u32 {
    DEFAULT_QUEUE_REMAINING_SECONDS
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LimiterAdmitRequest {
    pub job_id: String,
    pub audio_seconds: f64,
    pub daily_cap_micro_usd: i64,
    /// Slot count from lane config; defaults to 1 for requests sent by a
    /// not-yet-redeployed gateway during a rolling deploy.
    #[serde(default = "default_max_slots")]
    pub max_slots: u32,
    /// The job's current read-only ETA, excluding queue wait. Older callers
    /// omit it and contribute the calibrated bakeoff median instead.
    #[serde(default)]
    pub remaining_seconds: Option<u32>,
    #[serde(default = "default_queue_remaining_seconds")]
    pub default_remaining_seconds: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LimiterReleaseRequest {
    pub job_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct LimiterBusyResponse {
    pub queue_position: u32,
    pub wait_seconds: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AdmitDecision {
    Admit {
        spend_micro_usd: i64,
    },
    Busy {
        queue_position: u32,
        wait_seconds: u32,
    },
    SpendCapped,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct LimiterSlot {
    pub job_id: String,
    pub updated_at: i64,
    #[serde(default)]
    pub expires_at: i64,
    #[serde(default)]
    pub remaining_seconds: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct LimiterTicket {
    pub job_id: String,
    pub enqueued_at: i64,
    pub updated_at: i64,
    pub expires_at: i64,
    pub remaining_seconds: u32,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct LimiterState {
    pub day_index: i64,
    pub spent_micro_usd: i64,
    #[serde(default)]
    pub active: Vec<LimiterSlot>,
    #[serde(default)]
    pub tickets: Vec<LimiterTicket>,
    // Legacy single-slot fields (pass 0 shape): read once so a deploy does
    // not drop the active slot or the day's spend, never written back.
    #[serde(default, skip_serializing)]
    active_job_id: Option<String>,
    #[serde(default, skip_serializing)]
    active_updated_at: i64,
}

impl LimiterState {
    /// Fold the legacy single-slot fields into the active set.
    fn normalized(&self) -> LimiterState {
        let mut next = self.clone();
        if let Some(job_id) = next.active_job_id.take() {
            if !next.active.iter().any(|slot| slot.job_id == job_id) {
                next.active.push(LimiterSlot {
                    job_id,
                    updated_at: self.active_updated_at,
                    expires_at: self.active_updated_at.saturating_add(HOLD_TTL_SECONDS),
                    remaining_seconds: 0,
                });
            }
        }
        next.active_updated_at = 0;
        next
    }
}

pub fn decode_state(payload: &str) -> Result<LimiterState, serde_json::Error> {
    serde_json::from_str(payload)
}

/// Pure admission decision so the policy is host-testable; the DO persists
/// the returned state.
pub fn admit(
    state: &LimiterState,
    request: &LimiterAdmitRequest,
    day_index: i64,
    now: i64,
) -> (LimiterState, AdmitDecision) {
    let mut next = state.normalized();
    if next.day_index != day_index {
        next.day_index = day_index;
        next.spent_micro_usd = 0;
    }

    reap(&mut next, now);

    let estimate = estimated_micro_usd(request.audio_seconds);
    if next.spent_micro_usd.saturating_add(estimate) > request.daily_cap_micro_usd {
        next.tickets
            .retain(|ticket| ticket.job_id != request.job_id);
        return (next, AdmitDecision::SpendCapped);
    }

    let max_slots = request.max_slots.max(1) as usize;
    let remaining_seconds = request
        .remaining_seconds
        .unwrap_or(request.default_remaining_seconds.max(1));
    if let Some(index) = next
        .active
        .iter()
        .position(|slot| slot.job_id == request.job_id)
    {
        let slot = &mut next.active[index];
        slot.updated_at = now;
        slot.expires_at = now.saturating_add(HOLD_TTL_SECONDS);
        slot.remaining_seconds = remaining_seconds;
        next.tickets
            .retain(|ticket| ticket.job_id != request.job_id);
        next.spent_micro_usd = next.spent_micro_usd.saturating_add(estimate);
        return (
            next.clone(),
            AdmitDecision::Admit {
                spend_micro_usd: next.spent_micro_usd,
            },
        );
    }

    let ticket_index = match next
        .tickets
        .iter()
        .position(|ticket| ticket.job_id == request.job_id)
    {
        Some(index) => {
            let ticket = &mut next.tickets[index];
            ticket.updated_at = now;
            ticket.expires_at = now.saturating_add(TICKET_TTL_SECONDS);
            ticket.remaining_seconds = remaining_seconds;
            index
        }
        None if next.active.len() < max_slots && next.tickets.is_empty() => {
            next.active.push(LimiterSlot {
                job_id: request.job_id.clone(),
                updated_at: now,
                expires_at: now.saturating_add(HOLD_TTL_SECONDS),
                remaining_seconds,
            });
            next.spent_micro_usd = next.spent_micro_usd.saturating_add(estimate);
            return (
                next.clone(),
                AdmitDecision::Admit {
                    spend_micro_usd: next.spent_micro_usd,
                },
            );
        }
        None => {
            next.tickets.push(LimiterTicket {
                job_id: request.job_id.clone(),
                enqueued_at: now,
                updated_at: now,
                expires_at: now.saturating_add(TICKET_TTL_SECONDS),
                remaining_seconds,
            });
            next.tickets.len() - 1
        }
    };

    // A free slot is claimed only by the oldest ticket. Later callers stay
    // queued even if they happen to retry first.
    if next.active.len() < max_slots && ticket_index == 0 {
        next.tickets.remove(0);
        next.active.push(LimiterSlot {
            job_id: request.job_id.clone(),
            updated_at: now,
            expires_at: now.saturating_add(HOLD_TTL_SECONDS),
            remaining_seconds,
        });
        next.spent_micro_usd = next.spent_micro_usd.saturating_add(estimate);
        return (
            next.clone(),
            AdmitDecision::Admit {
                spend_micro_usd: next.spent_micro_usd,
            },
        );
    }

    let queue_position = (ticket_index + 1).min(u32::MAX as usize) as u32;
    let wait_seconds = projected_queue_wait_seconds(
        &next.active,
        &next.tickets[..ticket_index],
        request.max_slots,
        request.default_remaining_seconds,
    );
    (
        next,
        AdmitDecision::Busy {
            queue_position,
            wait_seconds,
        },
    )
}

pub fn release(state: &LimiterState, job_id: &str) -> LimiterState {
    let mut next = state.normalized();
    next.active.retain(|slot| slot.job_id != job_id);
    next.tickets.retain(|ticket| ticket.job_id != job_id);
    next
}

fn reap(state: &mut LimiterState, now: i64) {
    state.active.retain(|slot| {
        let expires_at = if slot.expires_at > 0 {
            slot.expires_at
        } else {
            slot.updated_at.saturating_add(HOLD_TTL_SECONDS)
        };
        now < expires_at
    });
    state.tickets.retain(|ticket| now < ticket.expires_at);
}

fn effective_remaining(value: u32, default_value: u32) -> u32 {
    if value == 0 {
        default_value.max(1)
    } else {
        value
    }
}

fn projected_queue_wait_seconds(
    active: &[LimiterSlot],
    tickets_ahead: &[LimiterTicket],
    max_slots: u32,
    default_remaining_seconds: u32,
) -> u32 {
    let mut lane_availability = vec![0u32; max_slots.max(1) as usize];
    let work_ahead = active
        .iter()
        .map(|slot| effective_remaining(slot.remaining_seconds, default_remaining_seconds))
        .chain(tickets_ahead.iter().map(|ticket| {
            effective_remaining(ticket.remaining_seconds, default_remaining_seconds)
        }));

    for remaining_seconds in work_ahead {
        if let Some(lane) = lane_availability.iter_mut().min() {
            *lane = lane.saturating_add(remaining_seconds);
        }
    }

    lane_availability.into_iter().min().unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(
        job: &str,
        seconds: f64,
        max_slots: u32,
        remaining_seconds: Option<u32>,
    ) -> LimiterAdmitRequest {
        LimiterAdmitRequest {
            job_id: job.to_string(),
            audio_seconds: seconds,
            daily_cap_micro_usd: 1_000_000,
            max_slots,
            remaining_seconds,
            default_remaining_seconds: DEFAULT_QUEUE_REMAINING_SECONDS,
        }
    }

    fn slot(job: &str, remaining_seconds: u32) -> LimiterSlot {
        LimiterSlot {
            job_id: job.to_string(),
            updated_at: 100,
            expires_at: 1_000,
            remaining_seconds,
        }
    }

    fn ticket(job: &str, remaining_seconds: u32) -> LimiterTicket {
        LimiterTicket {
            job_id: job.to_string(),
            enqueued_at: 100,
            updated_at: 100,
            expires_at: 1_000,
            remaining_seconds,
        }
    }

    #[test]
    fn cost_estimate_matches_published_rate() {
        // One hour = $0.03 exactly at $0.0005/minute -> 30,000 micro-USD.
        assert_eq!(estimated_micro_usd(3600.0), 30_000);
        assert_eq!(estimated_micro_usd(300.0), 2_500);
        assert_eq!(estimated_micro_usd(0.0), 0);
    }

    #[test]
    fn fifo_grants_in_ticket_order_and_sums_wait_ahead() {
        let (held, decision) = admit(
            &LimiterState::default(),
            &request("job-a", 300.0, 1, Some(50)),
            1,
            100,
        );
        assert!(matches!(decision, AdmitDecision::Admit { .. }));

        let (held, b_busy) = admit(&held, &request("job-b", 300.0, 1, Some(30)), 1, 110);
        assert_eq!(
            b_busy,
            AdmitDecision::Busy {
                queue_position: 1,
                wait_seconds: 50,
            }
        );
        let (held, c_busy) = admit(&held, &request("job-c", 300.0, 1, Some(20)), 1, 120);
        assert_eq!(
            c_busy,
            AdmitDecision::Busy {
                queue_position: 2,
                wait_seconds: 80,
            }
        );

        // A later ticket cannot cut in when it happens to retry first.
        let released = release(&held, "job-a");
        let (released, c_still_busy) =
            admit(&released, &request("job-c", 300.0, 1, Some(20)), 1, 130);
        assert_eq!(
            c_still_busy,
            AdmitDecision::Busy {
                queue_position: 2,
                wait_seconds: 30,
            }
        );
        let (held_by_b, b_admitted) =
            admit(&released, &request("job-b", 300.0, 1, Some(25)), 1, 140);
        assert!(matches!(b_admitted, AdmitDecision::Admit { .. }));
        let (held_by_b, c_first) = admit(&held_by_b, &request("job-c", 300.0, 1, Some(20)), 1, 150);
        assert_eq!(
            c_first,
            AdmitDecision::Busy {
                queue_position: 1,
                wait_seconds: 25,
            }
        );
        let released = release(&held_by_b, "job-b");
        let (_, c_admitted) = admit(&released, &request("job-c", 300.0, 1, Some(20)), 1, 160);
        assert!(matches!(c_admitted, AdmitDecision::Admit { .. }));
    }

    #[test]
    fn multi_slot_admits_up_to_the_slot_count_and_projects_earliest_release() {
        let (state, first) = admit(
            &LimiterState::default(),
            &request("job-a", 300.0, 2, Some(40)),
            1,
            100,
        );
        assert!(matches!(first, AdmitDecision::Admit { .. }));
        let (state, second) = admit(&state, &request("job-b", 300.0, 2, Some(30)), 1, 110);
        assert!(matches!(second, AdmitDecision::Admit { .. }));

        let (state, third) = admit(&state, &request("job-c", 300.0, 2, Some(20)), 1, 120);
        assert_eq!(
            third,
            AdmitDecision::Busy {
                queue_position: 1,
                wait_seconds: 30,
            }
        );
        // Holders renew without re-entering the queue.
        let (state, a_again) = admit(&state, &request("job-a", 300.0, 2, Some(35)), 1, 130);
        assert!(matches!(a_again, AdmitDecision::Admit { .. }));

        let released = release(&state, "job-b");
        let (released, c_next) = admit(&released, &request("job-c", 300.0, 2, Some(20)), 1, 140);
        assert!(matches!(c_next, AdmitDecision::Admit { .. }));
        let (_, d_busy) = admit(&released, &request("job-d", 300.0, 2, Some(10)), 1, 150);
        assert!(matches!(
            d_busy,
            AdmitDecision::Busy {
                queue_position: 1,
                ..
            }
        ));
    }

    #[test]
    fn expired_head_ticket_yields_to_renewing_followers_in_fifo_order() {
        let (state, _) = admit(
            &LimiterState::default(),
            &request("holder", 300.0, 1, Some(40)),
            1,
            100,
        );
        let (state, _) = admit(&state, &request("dead", 300.0, 1, Some(30)), 1, 101);
        let (state, _) = admit(&state, &request("live-a", 300.0, 1, Some(20)), 1, 102);
        let (state, _) = admit(&state, &request("live-b", 300.0, 1, Some(10)), 1, 103);

        let (state, _) = admit(&state, &request("live-a", 300.0, 1, Some(20)), 1, 150);
        let (state, _) = admit(&state, &request("live-b", 300.0, 1, Some(10)), 1, 150);
        let state = release(&state, "holder");

        let (state, first_live) = admit(
            &state,
            &request("live-a", 300.0, 1, Some(20)),
            1,
            101 + TICKET_TTL_SECONDS,
        );
        assert!(matches!(first_live, AdmitDecision::Admit { .. }));
        assert_eq!(state.active[0].job_id, "live-a");
        assert_eq!(state.tickets.len(), 1);
        assert_eq!(state.tickets[0].job_id, "live-b");

        let (_, second_live) = admit(
            &state,
            &request("live-b", 300.0, 1, Some(10)),
            1,
            101 + TICKET_TTL_SECONDS,
        );
        assert!(matches!(
            second_live,
            AdmitDecision::Busy {
                queue_position: 1,
                ..
            }
        ));
    }

    #[test]
    fn renewed_head_ticket_retains_its_fifo_position() {
        let (state, _) = admit(
            &LimiterState::default(),
            &request("holder", 300.0, 1, Some(40)),
            1,
            100,
        );
        let (state, _) = admit(&state, &request("head", 300.0, 1, Some(30)), 1, 101);
        let (state, _) = admit(&state, &request("follower", 300.0, 1, Some(20)), 1, 102);
        let renewal_time = 101 + TICKET_TTL_SECONDS - 1;
        let (state, _) = admit(
            &state,
            &request("head", 300.0, 1, Some(30)),
            1,
            renewal_time,
        );
        let (state, _) = admit(
            &state,
            &request("follower", 300.0, 1, Some(20)),
            1,
            renewal_time,
        );
        let state = release(&state, "holder");

        let after_original_expiry = 101 + TICKET_TTL_SECONDS + 1;
        let (state, follower) = admit(
            &state,
            &request("follower", 300.0, 1, Some(20)),
            1,
            after_original_expiry,
        );
        assert!(matches!(
            follower,
            AdmitDecision::Busy {
                queue_position: 2,
                ..
            }
        ));
        assert_eq!(state.tickets[0].job_id, "head");

        let (_, head) = admit(
            &state,
            &request("head", 300.0, 1, Some(30)),
            1,
            after_original_expiry,
        );
        assert!(matches!(head, AdmitDecision::Admit { .. }));
    }

    #[test]
    fn hold_expiry_remains_six_hundred_seconds() {
        assert_eq!(HOLD_TTL_SECONDS, 600);
        assert_eq!(TICKET_TTL_SECONDS, 60);

        let (state, _) = admit(
            &LimiterState::default(),
            &request("holder", 300.0, 1, Some(40)),
            1,
            100,
        );
        let (state, _) = admit(&state, &request("next", 300.0, 1, Some(20)), 1, 101);
        assert_eq!(state.active[0].expires_at, 100 + HOLD_TTL_SECONDS);

        let (state, before_expiry) = admit(
            &state,
            &request("next", 300.0, 1, Some(20)),
            1,
            100 + HOLD_TTL_SECONDS - 1,
        );
        assert!(matches!(before_expiry, AdmitDecision::Busy { .. }));
        assert_eq!(state.active[0].job_id, "holder");

        let (state, after_expiry) = admit(
            &state,
            &request("next", 300.0, 1, Some(20)),
            1,
            100 + HOLD_TTL_SECONDS,
        );
        assert!(matches!(after_expiry, AdmitDecision::Admit { .. }));
        assert_eq!(state.active[0].job_id, "next");
    }

    #[test]
    fn missing_estimates_use_the_configured_default_in_queue_math() {
        let state = LimiterState {
            active: vec![LimiterSlot {
                job_id: "job-a".into(),
                updated_at: 100,
                expires_at: 1_000,
                remaining_seconds: 0,
            }],
            tickets: vec![LimiterTicket {
                job_id: "job-b".into(),
                enqueued_at: 100,
                updated_at: 100,
                expires_at: 1_000,
                remaining_seconds: 0,
            }],
            ..LimiterState::default()
        };
        let (_, decision) = admit(&state, &request("job-c", 300.0, 1, Some(10)), 1, 200);
        assert_eq!(
            decision,
            AdmitDecision::Busy {
                queue_position: 2,
                wait_seconds: DEFAULT_QUEUE_REMAINING_SECONDS * 2,
            }
        );
    }

    #[test]
    fn multiple_fifo_tickets_are_scheduled_onto_the_next_available_lane() {
        let active = vec![slot("job-a", 40), slot("job-b", 70)];
        let tickets = vec![ticket("job-c", 50), ticket("job-d", 20)];

        assert_eq!(
            projected_queue_wait_seconds(&active, &tickets, 2, DEFAULT_QUEUE_REMAINING_SECONDS,),
            90
        );
    }

    #[test]
    fn free_configured_lane_has_no_projected_wait() {
        assert_eq!(
            projected_queue_wait_seconds(
                &[slot("job-a", 40)],
                &[],
                2,
                DEFAULT_QUEUE_REMAINING_SECONDS,
            ),
            0
        );
    }

    #[test]
    fn queue_projection_saturates_near_u32_max() {
        assert_eq!(
            projected_queue_wait_seconds(
                &[slot("job-a", u32::MAX - 5)],
                &[ticket("job-b", 10)],
                1,
                DEFAULT_QUEUE_REMAINING_SECONDS,
            ),
            u32::MAX
        );
    }

    #[test]
    fn daily_spend_cap_is_global_across_slots_and_resets_daily() {
        let mut state = LimiterState::default();
        let mut first = request("job-a", 3600.0, 2, Some(60));
        first.daily_cap_micro_usd = 45_000;
        let (next, decision) = admit(&state, &first, 1, 100);
        assert!(matches!(decision, AdmitDecision::Admit { .. }));
        state = next;

        // A different job on a FREE slot is still blocked by the shared cap.
        let mut second = request("job-b", 3600.0, 2, Some(60));
        second.daily_cap_micro_usd = 45_000;
        let (_, capped) = admit(&state, &second, 1, 200);
        assert_eq!(capped, AdmitDecision::SpendCapped);

        // New day resets the spend counter.
        let (_, fresh) = admit(&state, &second, 2, 300);
        assert!(matches!(fresh, AdmitDecision::Admit { .. }));
    }

    #[test]
    fn legacy_single_slot_state_migrates_without_losing_spend() {
        let legacy = r#"{"day_index":7,"spent_micro_usd":1234,"active_job_id":"job-old","active_updated_at":90}"#;
        let state = decode_state(legacy).expect("legacy state parses");

        // The legacy holder still occupies a slot and the spend survives.
        let (next, busy) = admit(&state, &request("job-new", 300.0, 1, Some(20)), 7, 100);
        assert!(matches!(
            busy,
            AdmitDecision::Busy {
                queue_position: 1,
                ..
            }
        ));
        let _ = next;
        let (next, again) = admit(&state, &request("job-old", 300.0, 1, Some(20)), 7, 100);
        assert!(matches!(again, AdmitDecision::Admit { .. }));
        assert_eq!(next.spent_micro_usd, 1234 + estimated_micro_usd(300.0));

        // Round-tripping the new shape drops the legacy fields.
        let serialized = serde_json::to_string(&next).expect("state serializes");
        assert!(!serialized.contains("active_job_id"));
    }

    #[test]
    fn current_payload_round_trips() {
        let state = LimiterState {
            day_index: 7,
            spent_micro_usd: 1_234,
            active: vec![slot("job-active", 40)],
            tickets: vec![ticket("job-queued", 20)],
            ..LimiterState::default()
        };
        let encoded = serde_json::to_string(&state).expect("state serializes");

        assert_eq!(decode_state(&encoded).expect("state decodes"), state);
    }

    #[test]
    fn legacy_payload_missing_additive_fields_uses_defaults() {
        let legacy = r#"{"day_index":7,"spent_micro_usd":1234,"active":[{"job_id":"job-old","updated_at":90}]}"#;
        let state = decode_state(legacy).expect("legacy state decodes");

        assert_eq!(state.active.len(), 1);
        assert_eq!(state.active[0].expires_at, 0);
        assert_eq!(state.active[0].remaining_seconds, 0);
        assert!(state.tickets.is_empty());
    }

    #[test]
    fn invalid_payload_returns_an_error() {
        assert!(decode_state("{not valid json").is_err());
    }
}
