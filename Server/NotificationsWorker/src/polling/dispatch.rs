//! One-minute admission. The feed row is the only schedule state: a dispatch
//! reserves a new obligation or repairs its same-generation wakeup, and the
//! returned rows become Queue messages. There is no per-attempt job row.
use super::{origin, policy};
use crate::database::{
    self,
    polling::{AlertMarker, Candidate, Candidates, EnqueueIdentity, Operation, ReservationMode},
};
use crate::delivery::{
    db::*,
    wire::{int, string},
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::time::Duration;
use worker::*;

pub const SCHEMA_VERSION: u8 = 2;
/// Opaque references only: never a URL, token or validator.
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Wakeup {
    pub schema_version: u8,
    pub environment: String,
    /// `poll` advances one feed; retained legacy `cleanup` messages are ignored.
    pub kind: String,
    pub feed_id: String,
    pub owner_epoch: i64,
    /// Dispatch generation for a poll; legacy cleanup minutes are ignored.
    pub generation: i64,
    pub due_at: i64,
    /// Continuation count within this generation.
    #[serde(default)]
    pub step: u32,
}

const ALERT_TIMEOUT_SECONDS: u64 = 10;

pub(super) fn storage_deadline(arrived: u64) -> u64 {
    crate::database::Authority::default_deadline(arrived)
        .saturating_add((ALERT_TIMEOUT_SECONDS + policy::BOOKKEEPING_DEADLINE_SECONDS) * 1000)
}

pub async fn run_dispatch(env: &Env, db: crate::database::Authority) -> Result<Value> {
    let bookkeeping = db.clone();
    let db = db.capped_at(crate::database::Authority::default_deadline(
        super::timing::now_ms(),
    ));
    if !super::runtime::enabled(env, &db).await? {
        return Ok(json!({"disabled":true}));
    }
    let t = now();
    // Incomplete preparations with an obsolete interest generation cannot block
    // a new baseline. Retain their conservative recovery evidence for seven days.
    let abandoned = database::execute(&db, Operation::AbandonIneligible)
        .await?
        .count();
    if abandoned > 0 {
        console_log!(
            "{}",
            json!({"event":"poll_eligibility_abandoned","count":abandoned})
        );
    }
    // Repair lapsed obligations first, across both scan and maintenance work.
    // Their original wakeups remain useful, regardless of time spent queued.
    let repair_rows = database::execute(
        &db,
        Operation::ReadCandidates {
            class: Candidates::Repairs,
            now: t,
        },
    )
    .await?
    .rows();
    let repairs = repair_rows.iter().map(record).collect::<Result<Vec<_>>>()?;
    let repaired = reserve(env, &db, &repairs, t, ReservationMode::Repair).await?;
    // Settled feeds alone create a new obligation. Bounded early admission
    // leaves processing headroom within the minute tick.
    // Each class may borrow all global headroom; reserve rechecks both caps.
    let mut recurring = database::execute(
        &db,
        Operation::ReadCandidates {
            class: Candidates::Recurring,
            now: t,
        },
    )
    .await?
    .rows()
    .into_iter();
    let mut baselines = database::execute(
        &db,
        Operation::ReadCandidates {
            class: Candidates::Baselines,
            now: t,
        },
    )
    .await?
    .rows()
    .into_iter();
    let mut admitted = vec![];
    for i in 0..policy::DISPATCH_LIMIT {
        let next = if i % 5 == 4 {
            baselines.next().or_else(|| recurring.next())
        } else {
            recurring.next().or_else(|| baselines.next())
        };
        let Some(row) = next else {
            break;
        };
        admitted.push(record(&row)?);
    }
    let polls = reserve(env, &db, &admitted, t, ReservationMode::Admission).await?;
    // Separate maintenance admission keeps future/outbox recovery independent
    // of recurring due dates, publisher backoff and origin cooldowns. Oldest
    // work is selected, not alphabetical feeds. It also resumes a preparation
    // whose continuation message was lost.
    let maintenance = database::execute(
        &db,
        Operation::ReadCandidates {
            class: Candidates::Maintenance,
            now: t,
        },
    )
    .await?
    .rows();
    let maintenance = maintenance.iter().map(record).collect::<Result<Vec<_>>>()?;
    let maintained = reserve(env, &db, &maintenance, t, ReservationMode::Maintenance).await?;
    // The one-minute cost/lag rollup: no per-poll diagnostic rows exist.
    let mut rollup = database::execute(&db, Operation::ReadRollup { now: t })
        .await?
        .first()
        .unwrap_or_else(|| json!({}));
    rollup["outstanding"] = rollup["in_flight"].clone();
    rollup["repairs"] = json!(repaired);
    rollup["admitted"] = json!(polls);
    rollup["maintenance_admitted"] = json!(maintained);
    let (alerting, alert_state) = alert_dispatch(env, &db, &bookkeeping, &rollup, t).await?;
    rollup["alerting"] = json!(alerting);
    rollup["stall_state"] = json!(alert_state["stall_state"]);
    rollup["stall_since"] = json!(alert_state["stall_since"]);
    console_log!("{}", json!({"event":"poll_dispatch","work":rollup}));
    Ok(rollup)
}

/// The operator alert webhook. The endpoint is deployment configuration, not
/// source: alerting is on only when all three secrets are set, and a
/// non-HTTPS URL is refused so the bearer credential never travels in clear.
pub(super) struct AlertTarget {
    url: String,
    credential: String,
    recipient: String,
}

pub(super) fn alert_target(env: &Env) -> Option<AlertTarget> {
    let secret = |name: &str| {
        env.secret(name)
            .ok()
            .map(|v| v.to_string())
            .filter(|v| !v.is_empty())
    };
    let url = secret("ALERT_WEBHOOK_URL")?;
    if !url.starts_with("https://") {
        console_warn!(
            "{}",
            json!({"event":"poll_alert_misconfigured","reason":"webhook_url_not_https"})
        );
        return None;
    }
    Some(AlertTarget {
        url,
        credential: secret("ALERT_CREDENTIAL")?,
        recipient: secret("ALERT_RECIPIENT")?,
    })
}

#[derive(Clone, Copy)]
pub(super) enum AlertDraft<'a> {
    Watchdog {
        lane: &'a str,
        bucket: i64,
        late: Option<i64>,
    },
    Armed {
        lane: &'a str,
    },
    Onset {
        lane: &'a str,
        stall_since: i64,
        healthy_overdue: i64,
        late_600: i64,
        in_flight: i64,
        oldest_due_seconds: i64,
    },
    Hourly {
        lane: &'a str,
        stall_since: i64,
        healthy_overdue: i64,
        late_600: i64,
        in_flight: i64,
        oldest_due_seconds: i64,
        hour: i64,
    },
    Recovery {
        lane: &'a str,
        stall_since: i64,
        completions: i64,
    },
}

impl AlertDraft<'_> {
    fn idempotency_key(self) -> String {
        match self {
            Self::Watchdog { lane, bucket, .. } => format!("feed-polling-watchdog-{lane}-{bucket}"),
            Self::Armed { lane } => format!("feed-polling-alerts-armed-{lane}"),
            Self::Onset {
                lane, stall_since, ..
            } => format!("feed-polling-stall-{lane}-{stall_since}"),
            Self::Hourly {
                lane,
                stall_since,
                hour,
                ..
            } => format!("feed-polling-stall-{lane}-{stall_since}-{hour}"),
            Self::Recovery {
                lane, stall_since, ..
            } => format!("feed-polling-recovered-{lane}-{stall_since}"),
        }
    }
    fn body(self) -> String {
        match self {
            Self::Watchdog { lane, late: Some(late), .. } => format!("Feed polling watchdog ({lane}): {late} healthy scanned feeds are over 15 minutes late while the dispatcher stall state is clear."),
            Self::Watchdog { lane, late: None, .. } => format!("Feed polling watchdog ({lane}) could not read polling health within 10 seconds. Check the dispatcher and database."),
            Self::Armed { lane } => format!("Feed polling alerts are armed for {lane}."),
            Self::Onset { lane, healthy_overdue, late_600, in_flight, oldest_due_seconds, .. } | Self::Hourly { lane, healthy_overdue, late_600, in_flight, oldest_due_seconds, .. } => format!("Feed polling is late or stalled ({lane}). Healthy overdue: {healthy_overdue}; late_600: {late_600}; oldest healthy overdue: {oldest_due_seconds}s; in flight: {in_flight}."),
            Self::Recovery { lane, stall_since, completions } => format!("Feed polling recovered for {lane} after {}s; {completions} completions in 5 min.", now().saturating_sub(stall_since)),
        }
    }
    fn payload(self) -> Value {
        let (title, interruption_level, expiration, priority, collapse_id) = match self {
            Self::Watchdog { lane, .. } => (
                format!("Feed polling watchdog ({lane})"),
                "time_sensitive",
                "one_hour",
                "immediate",
                json!("feed-polling-watchdog"),
            ),
            Self::Armed { lane } => (
                format!("Feed polling alerts armed ({lane})"),
                "passive",
                "one_day",
                "immediate",
                Value::Null,
            ),
            Self::Onset { lane, .. } | Self::Hourly { lane, .. } => (
                format!("Feed polling stalled ({lane})"),
                "time_sensitive",
                "one_hour",
                "immediate",
                json!("feed-polling-stall"),
            ),
            Self::Recovery { lane, .. } => (
                format!("Feed polling recovered ({lane})"),
                "active",
                "one_day",
                "immediate",
                Value::Null,
            ),
        };
        json!({"schema_version":1,"title":title,"subtitle":"","body":self.body(),"sound":"default","badge":null,"interruption_level":interruption_level,"relevance_score":null,"category_id":null,"thread_id":null,"collapse_id":collapse_id,"expiration":expiration,"priority":priority,"custom_data":{}})
    }
}

/// The relay's answer to one alert request. `status` is 0 when the request
/// or its response failed before an HTTP status was read.
#[derive(Clone, Copy)]
pub(super) struct AlertReply {
    pub delivered: bool,
    pub status: u16,
}

pub(super) async fn send_alert(target: &AlertTarget, draft: AlertDraft<'_>) -> Result<AlertReply> {
    let envelope = json!({"recipient":target.recipient,"draft":draft.payload()});
    let headers = Headers::new();
    headers.set("authorization", &format!("Bearer {}", target.credential))?;
    headers.set("content-type", "application/json")?;
    headers.set("idempotency-key", &draft.idempotency_key())?;
    let mut init = RequestInit::new();
    init.with_method(Method::Post)
        .with_headers(headers)
        .with_body(Some(envelope.to_string().into()));
    let request = Request::new_with_init(&target.url, &init)?;
    let mut response = crate::deadline::fetch_with_deadline(
        Fetch::Request(request).send(),
        Delay::from(Duration::from_secs(ALERT_TIMEOUT_SECONDS)),
        Error::RustError("poll_alert_timeout".into()),
    )
    .await?;
    let status = response.status_code();
    let body: Value = response.json().await.unwrap_or(Value::Null);
    let aggregate = body["aggregate_status"].as_str().unwrap_or("");
    let code = body["error"]["code"]
        .as_str()
        .or_else(|| body["code"].as_str())
        .unwrap_or("");
    // A replay after an uncertain response is settled by the webhook's
    // idempotency ledger. The body is intentionally not compared here: live
    // counts change between retries, while the key identifies the alert.
    let delivered = (status == 409 && code == "idempotency_conflict")
        || (status == 200
            && matches!(
                aggregate,
                "accepted"
                    | "partially_accepted"
                    | "recipient_muted"
                    | "recipient_revoked"
                    | "no_active_target"
            ));
    if !delivered {
        console_warn!(
            "{}",
            json!({"event":"poll_alert_failed","status":status,"code":if code.is_empty() { aggregate } else { code }})
        );
    } else if matches!(
        aggregate,
        "recipient_muted" | "recipient_revoked" | "no_active_target"
    ) {
        console_warn!(
            "{}",
            json!({"event":"poll_alert_recipient_status","status":aggregate})
        );
    }
    Ok(AlertReply { delivered, status })
}

async fn send_alert_safely(
    timer: &crate::storage_witness::Timer,
    target: &AlertTarget,
    draft: AlertDraft<'_>,
) -> AlertReply {
    // The whole exchange, the reply body included: the segment no timer bounds.
    let _alert = timer.span(crate::storage_witness::Category::Alert);
    match send_alert(target, draft).await {
        Ok(reply) => reply,
        Err(error) => {
            console_warn!(
                "{}",
                json!({"event":"poll_alert_failed","status":0,"code":error.to_string()})
            );
            AlertReply {
                delivered: false,
                status: 0,
            }
        }
    }
}

/// Writes the attempt's marker, if any, then logs the attempt's one
/// `poll_alert_delivery` line: kind, lane, relay status and the marker with
/// whether it changed the dispatch row (null when the write failed, whose
/// error is then returned).
async fn settle_alert(
    db: &crate::database::Authority,
    kind: &str,
    lane: &str,
    reply: AlertReply,
    marker: Option<(&str, AlertMarker)>,
) -> Result<bool> {
    let name = marker.as_ref().map(|(name, _)| *name);
    let marked = match marker {
        Some((_, marker)) => {
            let bookkeeping = db.bookkeeping(
                super::timing::now_ms().saturating_add(policy::BOOKKEEPING_DEADLINE_SECONDS * 1000),
            );
            Some(
                database::execute(&bookkeeping, Operation::MarkAlert { marker })
                    .await
                    .map(|response| response.count() > 0),
            )
        }
        None => None,
    };
    let line = json!({"event":"poll_alert_delivery","kind":kind,"lane":lane,"status":reply.status,"delivered":reply.delivered,"marker":name,"marked":marked.as_ref().and_then(|m| m.as_ref().ok())});
    if reply.delivered {
        console_log!("{line}");
    } else {
        console_warn!("{line}");
    }
    if let Some(Err(error)) = marked {
        return Err(error);
    }
    Ok(reply.delivered)
}

async fn alert_dispatch(
    env: &Env,
    db: &crate::database::Authority,
    bookkeeping: &crate::database::Authority,
    rollup: &Value,
    t: i64,
) -> Result<(bool, Value)> {
    let state = database::execute(db, Operation::ReadDispatchState { full: true }).await?.first().unwrap_or_else(|| json!({"stall_state":"clear","stall_since":0,"stall_alerted_at":0,"alert_armed_at":0}));
    let Some(target) = alert_target(env) else {
        return Ok((false, state));
    };
    let stall_state = state["stall_state"].as_str().unwrap_or("clear");
    let stall_since = state["stall_since"].as_i64().unwrap_or(0);
    let stall_alerted_at = state["stall_alerted_at"].as_i64().unwrap_or(0);
    let alert_armed_at = state["alert_armed_at"].as_i64().unwrap_or(0);
    let transition = super::policy::stall_transition(
        super::policy::StallRollup {
            completed_last_5min: rollup["completed_last_5min"].as_i64().unwrap_or(0),
            healthy_overdue: rollup["healthy_overdue"].as_i64().unwrap_or(0),
            late_600: rollup["late_600"].as_i64().unwrap_or(0),
        },
        stall_state,
        stall_since,
        stall_alerted_at,
        alert_armed_at,
        t,
        true,
    );
    let lane_name = lane(env);
    let delivered = match transition {
        Some(super::policy::StallAlert::Armed) => {
            let reply =
                send_alert_safely(&db.timer(), &target, AlertDraft::Armed { lane: &lane_name })
                    .await;
            let marker = reply
                .delivered
                .then_some(("armed", AlertMarker::Armed { now: t }));
            settle_alert(bookkeeping, "armed", &lane_name, reply, marker).await?
        }
        Some(super::policy::StallAlert::Onset { stall_since: onset }) => {
            let entered = if stall_state == "stalled" {
                true
            } else {
                database::execute(
                    db,
                    Operation::MarkAlert {
                        marker: AlertMarker::Onset { since: onset },
                    },
                )
                .await?
                .count()
                    > 0
            };
            if !entered {
                false
            } else {
                let reply = send_alert_safely(
                    &db.timer(),
                    &target,
                    AlertDraft::Onset {
                        lane: &lane_name,
                        stall_since: onset,
                        healthy_overdue: rollup["healthy_overdue"].as_i64().unwrap_or(0),
                        late_600: rollup["late_600"].as_i64().unwrap_or(0),
                        in_flight: rollup["in_flight"].as_i64().unwrap_or(0),
                        oldest_due_seconds: rollup["oldest_due_seconds"].as_i64().unwrap_or(0),
                    },
                )
                .await;
                let marker = reply.delivered.then_some((
                    "onset_sent",
                    AlertMarker::OnsetSent {
                        since: onset,
                        now: t,
                    },
                ));
                settle_alert(bookkeeping, "onset", &lane_name, reply, marker).await?
            }
        }
        Some(super::policy::StallAlert::Hourly {
            stall_since: since,
            hour,
        }) => {
            let marker = -t.max(1);
            let claimed = database::execute(
                db,
                Operation::MarkAlert {
                    marker: AlertMarker::ClaimHourly {
                        since,
                        previous: stall_alerted_at,
                        marker,
                    },
                },
            )
            .await?
            .count()
                > 0;
            if !claimed {
                false
            } else {
                let reply = send_alert_safely(
                    &db.timer(),
                    &target,
                    AlertDraft::Hourly {
                        lane: &lane_name,
                        stall_since: since,
                        healthy_overdue: rollup["healthy_overdue"].as_i64().unwrap_or(0),
                        late_600: rollup["late_600"].as_i64().unwrap_or(0),
                        in_flight: rollup["in_flight"].as_i64().unwrap_or(0),
                        oldest_due_seconds: rollup["oldest_due_seconds"].as_i64().unwrap_or(0),
                        hour,
                    },
                )
                .await;
                // A failed reminder restores the previous send time.
                let finish = AlertMarker::FinishHourly {
                    expected: marker,
                    value: if reply.delivered { t } else { stall_alerted_at },
                };
                settle_alert(
                    bookkeeping,
                    "hourly",
                    &lane_name,
                    reply,
                    Some(("finish_hourly", finish)),
                )
                .await?
            }
        }
        Some(super::policy::StallAlert::Recovery { stall_since: since }) => {
            let reply = send_alert_safely(
                &db.timer(),
                &target,
                AlertDraft::Recovery {
                    lane: &lane_name,
                    stall_since: since,
                    completions: rollup["completed_last_5min"].as_i64().unwrap_or(0),
                },
            )
            .await;
            let marker = reply
                .delivered
                .then_some(("recovery", AlertMarker::Recovery { since }));
            settle_alert(bookkeeping, "recovery", &lane_name, reply, marker).await?
        }
        None => false,
    };
    let bookkeeping = bookkeeping.bookkeeping(
        super::timing::now_ms().saturating_add(policy::BOOKKEEPING_DEADLINE_SECONDS * 1000),
    );
    let current = database::execute(&bookkeeping, Operation::ReadDispatchState { full: false })
        .await?
        .first()
        .unwrap_or_else(|| json!({"stall_state":"clear","stall_since":0}));
    let _ = delivered;
    Ok((true, current))
}
fn record(row: &Value) -> Result<Candidate> {
    let url = url::Url::parse(string(row, "canonical_url"))
        .map_err(|_| Error::RustError("invalid_feed_mapping".into()))?;
    Ok(Candidate {
        feed_id: string(row, "feed_id").into(),
        origin_key: origin::key(&url),
        admission_origin: url.origin().ascii_serialization(),
    })
}
/// Reserve atomically; only a new obligation advances the generation. Overlapping dispatchers
/// cannot both reserve a feed, so no dispatcher lease is needed; only the rows
/// this statement returned are enqueued.
async fn reserve(
    env: &Env,
    db: &crate::database::Authority,
    records: &[Candidate],
    t: i64,
    mode: ReservationMode,
) -> Result<usize> {
    if records.is_empty() {
        return Ok(0);
    }
    // Materialize the valid ordered candidates and headroom in this one atomic
    // statement. An overlapping dispatcher sees the preceding reservations;
    // rows it already took cannot consume this statement's available slots.
    let reserved = database::execute(
        db,
        Operation::ReserveDispatch {
            candidates: records.to_vec(),
            mode,
            now: t,
        },
    )
    .await?
    .rows();
    let messages: Vec<_> = reserved
        .iter()
        .map(|r| Wakeup {
            schema_version: SCHEMA_VERSION,
            environment: lane(env),
            kind: "poll".into(),
            feed_id: string(r, "feed_id").into(),
            owner_epoch: int(r, "epoch"),
            generation: int(r, "schedule_generation"),
            due_at: int(r, "due_at"),
            step: 0,
        })
        .collect();
    let count = messages.len();
    for chunk in messages.chunks(100) {
        let sent = db
            .timer()
            .time(
                crate::storage_witness::Category::Queue,
                send(env, chunk.to_vec(), 0),
            )
            .await;
        if sent.is_err() {
            // The send outcome is unknown. Lapse only still-unsettled work;
            // the next tick repairs it and any delivered copy stays valid.
            let lost: Vec<_> = chunk
                .iter()
                .map(|w| EnqueueIdentity {
                    feed_id: w.feed_id.clone(),
                    generation: w.generation,
                })
                .collect();
            database::execute(
                db,
                Operation::LapseUncertainEnqueue {
                    identities: lost,
                    now: t,
                },
            )
            .await?;
            console_warn!(
                "{}",
                json!({"event":"poll_enqueue_failed","count":chunk.len()})
            );
            return Err(Error::RustError("poll_enqueue_failed".into()));
        }
    }
    Ok(count)
}
pub async fn send(env: &Env, messages: Vec<Wakeup>, delay: u32) -> Result<()> {
    env.queue("POLL_QUEUE")?
        .send_batch(
            BatchMessageBuilder::new()
                .messages(messages)
                .delay_seconds(delay)
                .build(),
        )
        .await
}
pub async fn stats(env: &Env, db: &crate::database::Authority) -> Result<Value> {
    let t = now();
    let mut value = database::execute(db, Operation::ReadStats { now: t })
        .await?
        .first()
        .ok_or_else(|| Error::RustError("poll_stats_missing".into()))?;
    // Failure, redelivery and rejected-commit totals are a rolling 24 hours.
    // Healthy polls leave only the feed's last outcome and sampled events.
    value["counter_window"] = json!("rolling_24_hours");
    value["wasm_memory_bytes"] = json!(crate::runtime_diagnostics::current().wasm_memory_bytes);
    let permits = crate::feed_scan_admission::FeedScanPermit::view();
    let diagnostics = crate::feed_scan_admission::FeedScanPermit::diagnostics();
    value["active_permits"] = json!(permits.active_permits);
    value["oldest_permit_age_seconds"] = json!(permits.oldest_permit_age_seconds);
    value["holder_step"] = json!(permits.holder_step);
    value["isolate"] = json!(permits.isolate);
    value["permit_refused"] = json!(diagnostics.refused);
    value["abandoned_recovered"] = json!(diagnostics.abandoned_recovered);
    value["stale_releases"] = json!(diagnostics.stale_releases);
    value["permit_reclaims"] = json!(diagnostics.reclaimed);
    let state = database::execute(db, Operation::ReadDispatchState { full: false })
        .await?
        .first()
        .unwrap_or_else(|| json!({"stall_state":"clear","stall_since":0}));
    value["stall_state"] = json!(state["stall_state"].as_str().unwrap_or("clear"));
    value["stall_since"] = json!(state["stall_since"].as_i64().unwrap_or(0));
    value["alerting"] = json!(alert_target(env).is_some());
    Ok(value)
}
