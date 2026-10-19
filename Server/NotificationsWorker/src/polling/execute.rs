//! The Queue message wakes a durable feed obligation. Delivery failure and the
//! consumer's retry policy own crash recovery; the feed's owner epoch and
//! dispatch generation decide whether a delivery may still mutate anything.
//! A redelivery may repeat one conditional fetch. It can never publish twice:
//! snapshot publication, event keys and the settle statement are all fenced.
use super::{dispatch, policy, stat};
use crate::database::{self, polling::Operation};
use crate::{
    delivery::{
        db::*,
        wire::{self, int, string},
    },
    observation,
};
use serde_json::{json, Value};
use std::{cell::RefCell, rc::Rc};
use worker::*;

#[derive(Clone)]
pub(crate) struct Fence {
    pub feed: String,
    pub epoch: i64,
    pub generation: i64,
    pub schedule: policy::ScheduleInputs,
    pub timings: super::timing::Timings,
    /// Set once a scan under this fence has sent a publisher request. The
    /// consumer outlives a step it cancels and records the bound for it.
    pub reached: Rc<RefCell<Option<observation::store::Bound>>>,
    /// A generated lease ID this invocation may have acquired. Register before
    /// the claim await, so cancellation can clean up an uncertain commit safely.
    pub scan_lease: Rc<RefCell<Option<String>>>,
    /// The Queue message and attempt, when the queue adapter delivered it.
    pub delivery: Option<crate::feed_scan_admission::Delivery>,
}
impl Fence {
    pub(crate) fn storage(&self) -> database::polling::Fence {
        database::polling::Fence {
            feed: self.feed.clone(),
            epoch: self.epoch,
            generation: self.generation,
        }
    }
    pub async fn rejected(&self, db: &crate::database::Authority) -> Result<()> {
        stat(db, crate::database::polling::Counter::StaleCommits).await?;
        console_log!("{}", json!({"event":"poll_stale_commit","count":1}));
        Ok(())
    }
    pub fn settle(
        &self,
        now: i64,
        outcome: &'static str,
        release_at: Option<i64>,
        credible_cadence: Option<i64>,
        publish_cadence: Option<i64>,
    ) -> policy::Settle {
        policy::settle(
            &self.feed,
            &self.schedule,
            now,
            outcome,
            release_at,
            credible_cadence,
            publish_cadence,
        )
    }
}

/// A publisher failure backs the feed off and settles this generation. The
/// dispatcher issues the next one after `retry_at`; no message waits for it.
pub(crate) async fn fetch_failed(
    db: &crate::database::Authority,
    fence: &Fence,
    reason: &str,
) -> Result<()> {
    let t = now();
    let changed = database::execute(
        db,
        Operation::SettlePublisherFailure {
            fence: fence.storage(),
            reason: reason.into(),
            now: t,
        },
    )
    .await?
    .count();
    if changed == 0 {
        return fence.rejected(db).await;
    }
    stat(db, crate::database::polling::Counter::PublisherFailures).await
}

pub async fn consume(
    env: Env,
    wake: dispatch::Wakeup,
    attempts: u32,
    message: Option<String>,
    signal: web_sys::AbortSignal,
    enqueued_ms: Option<u64>,
    db: crate::database::Authority,
) -> Result<Response> {
    let started = super::timing::now_ms();
    let timings = super::timing::Timings::default();
    if !super::runtime::permitted_by_environment(&env) {
        return Response::error("polling_disabled", 503);
    }
    if wake.schema_version != dispatch::SCHEMA_VERSION
        || wake.environment != lane(&env)
        || wake.generation < 1
    {
        return Response::error("invalid_wakeup", 400);
    }
    if wake.kind == "cleanup" {
        // Compatibility with messages retained from the old cron.
        return outcome("cleanup_ignored", None, None);
    }
    if wake.kind != "poll" || !wire::hex_id(&wake.feed_id) || wake.owner_epoch < 1 {
        return Response::error("invalid_wakeup", 400);
    }
    let claimed: Rc<RefCell<Option<Fence>>> = Default::default();
    let step_claimed = claimed.clone();
    let step_timings = timings.clone();
    let step_env = env.clone();
    let step_wake = wake.clone();
    let step_delivery = message.map(|message| crate::feed_scan_admission::Delivery {
        message,
        attempt: attempts,
    });
    let step_db = db.capped_at(started.saturating_add(policy::STEP_DEADLINE_SECONDS * 1000));
    let result = crate::invocation_owner::run_with_abort_signal_and_deadline(
        signal,
        async move {
            let db = step_db;
            // Before any route: an obsolete wake or a step that needs no new
            // permit must still free what this message's cancelled attempt left.
            if let Some(delivery) = step_delivery.as_ref() {
                if crate::feed_scan_admission::FeedScanPermit::reclaim_earlier_attempts(delivery)
                    > 0
                {
                    stat(&db, crate::database::polling::Counter::PermitReclaims).await?;
                }
            }
            // The read-only claim and continuation send share the step budget.
            let claim_span = super::timing::Span::new(step_timings.claim.clone(), None);
            let row = claim(&db, &step_wake).await?;
            drop(claim_span);
            let Some(row) = row else {
                return Ok("obsolete");
            };
            *step_timings.origin.borrow_mut() = row["origin_key"].as_str().map(str::to_string);
            let fence = Fence {
                feed: step_wake.feed_id.clone(),
                epoch: step_wake.owner_epoch,
                generation: step_wake.generation,
                schedule: policy::ScheduleInputs {
                    due_at: int(&row, "due_at"),
                    baseline_at: row["baseline_at"].as_i64(),
                    credible_release_at: row["credible_release_at"].as_i64(),
                    credible_cadence: row["credible_cadence"].as_i64(),
                    publish_cadence: row["publish_cadence"].as_i64(),
                    five_minute: int(&row, "five_minute") == 1
                        && super::runtime::flag(
                            &step_env,
                            "NOTIFICATION_FIVE_MINUTE_POLLING",
                            true,
                        ),
                },
                reached: Default::default(),
                scan_lease: Default::default(),
                timings: step_timings,
                delivery: step_delivery,
            };
            if attempts > 1 {
                stat(&db, crate::database::polling::Counter::Redeliveries).await?;
                console_log!(
                    "{}",
                    json!({"event":"poll_redelivered","attempts":attempts,"step":step_wake.step})
                );
            }
            *step_claimed.borrow_mut() = Some(fence.clone());
            step(step_env, fence, step_wake, row, db).await
        },
        policy::STEP_DEADLINE_SECONDS,
        wake.step,
    )
    .await;
    let fence = claimed.take();
    let (name, status) = match result {
        Some(Ok(name)) => (name, 200),
        failure => {
            let cancelled = failure.is_none();
            let reason = failure
                .and_then(|r| r.err())
                .map(|e| e.to_string())
                .unwrap_or_default();
            let db = db.bookkeeping(
                super::timing::now_ms().saturating_add(policy::BOOKKEEPING_DEADLINE_SECONDS * 1000),
            );
            let bookkeeping = crate::deadline::fetch_with_deadline(
                async {
                    if let Some(fence) = fence.as_ref() {
                        if cancelled {
                            if let Some(bound) = fence.reached.take() {
                                bound.record(&db).await?;
                            }
                        }
                    }
                    if !cancelled {
                        stat(&db, crate::database::polling::Counter::HandlingFailures).await?;
                    }
                    if let Some(fence) = fence.as_ref() {
                        release(
                            &db,
                            fence,
                            if cancelled {
                                "cancelled"
                            } else {
                                "handling_failed"
                            },
                            &reason,
                        )
                        .await?;
                    }
                    Ok::<_, Error>(())
                },
                Delay::from(std::time::Duration::from_secs(
                    policy::BOOKKEEPING_DEADLINE_SECONDS,
                )),
                Error::RustError("poll_bookkeeping_deadline".into()),
            )
            .await;
            if !cancelled || bookkeeping.is_err() {
                console_warn!(
                    "{}",
                    json!({"event":"poll_handling_failed","feed_id":wake.feed_id,"attempts":attempts,"reason":reason,"bookkeeping_failed":bookkeeping.is_err()})
                );
            }
            (
                if cancelled { "cancelled" } else { "failed" },
                if cancelled { 503 } else { 500 },
            )
        }
    };
    if name == "obsolete" {
        console_log!(
            "{}",
            json!({"event":"poll_outcome","outcome":name,"feed":wake.feed_id,"step":wake.step})
        );
    }
    let wall_ms = super::timing::now_ms().saturating_sub(started);
    let message_age_ms = enqueued_ms.map(|at| started.saturating_sub(at));
    // Continuations and retries include deliberate delay. Only a first
    // delivery of a dispatcher wakeup has an undelayed send timestamp.
    let initial_queue_wait_ms = message_age_ms.filter(|_| wake.step == 0 && attempts == 1);
    let due_lag_seconds = fence
        .as_ref()
        .map(|f| started as i64 / 1000 - f.schedule.due_at);
    // Body parses this step made; a step that parsed none logs null.
    let passes = Some(timings.passes.get()).filter(|n| *n > 0);
    let plain = matches!(name, "unchanged" | "not_modified");
    let sampled = plain && policy::sampled(&wake.feed_id, wake.generation);
    if !plain || sampled || wall_ms > 5000 || initial_queue_wait_ms.is_some_and(|ms| ms > 120_000) {
        console_log!(
            "{}",
            json!({"event":"poll_delivery","outcome":name,"feed":wake.feed_id,"origin":*timings.origin.borrow(),"step":wake.step,"attempts":attempts,"message_age_ms":message_age_ms,"initial_queue_wait_ms":initial_queue_wait_ms,"due_lag_seconds":due_lag_seconds,"wall_ms":wall_ms,"claim_ms":timings.claim.get(),"publisher_fetch_ms":timings.publisher.get(),"via":timings.via.get(),"passes":passes,"storage_ms":wall_ms.saturating_sub(timings.claim.get()).saturating_sub(timings.publisher.get()),"sample":if plain && wall_ms<=5000 && initial_queue_wait_ms.is_none_or(|ms|ms<=120_000) {policy::SUCCESS_LOG_SAMPLE} else {1}})
        );
    }
    outcome(name, timings.via.get(), passes).map(|response| response.with_status(status))
}

/// A failed or cancelled step may have claimed the scan lease after proving a
/// change. Free it for the redelivery, unless it guards a complete preparation
/// that the redelivery resumes instead of refetching.
async fn release(
    db: &crate::database::Authority,
    fence: &Fence,
    outcome: &str,
    reason: &str,
) -> Result<()> {
    let lease = fence.scan_lease.borrow().clone();
    database::execute(
        db,
        Operation::ReleaseAttempt {
            fence: fence.storage(),
            lease,
            outcome: outcome.into(),
            reason: reason.into(),
            now: now(),
        },
    )
    .await?;
    Ok(())
}
fn outcome(name: &str, via: Option<&str>, passes: Option<u8>) -> Result<Response> {
    Response::from_json(&json!({ "outcome": name, "via": via, "passes": passes }))
}

/// The exhausted message is diagnostic; the feed row is the recovery source.
/// Back the feed off without blaming its publisher and settle the generation.
pub async fn dead_letter(
    env: &Env,
    wake: &dispatch::Wakeup,
    db: crate::database::Authority,
) -> Result<Response> {
    // A release brake exhausts messages too; that is not the feed's fault.
    if wake.kind != "poll"
        || !wire::hex_id(&wake.feed_id)
        || !super::runtime::permitted_by_environment(env)
    {
        return outcome("ignored", None, None);
    }
    let t = now();
    let changed = database::execute(
        &db,
        Operation::SettleDeadLetter {
            fence: database::polling::Fence {
                feed: wake.feed_id.clone(),
                epoch: wake.owner_epoch,
                generation: wake.generation,
            },
            now: t,
        },
    )
    .await?
    .count();
    if changed > 0 {
        stat(&db, crate::database::polling::Counter::DeadLetters).await?;
    }
    console_warn!(
        "{}",
        json!({"event":"poll_dead_letter","feed_id":wake.feed_id,"settled":changed>0})
    );
    outcome("dead_letter_saved", None, None)
}

async fn claim(db: &crate::database::Authority, wake: &dispatch::Wakeup) -> Result<Option<Value>> {
    Ok(database::execute(
        db,
        Operation::ReadClaim {
            fence: database::polling::Fence {
                feed: wake.feed_id.clone(),
                epoch: wake.owner_epoch,
                generation: wake.generation,
            },
            now: now(),
        },
    )
    .await?
    .first())
}

/// One bounded step. The action is derived from durable observation state, so
/// a redelivered or re-dispatched message resumes exactly where work stopped.
async fn step(
    env: Env,
    fence: Fence,
    wake: dispatch::Wakeup,
    row: Value,
    db: crate::database::Authority,
) -> Result<&'static str> {
    if wake.step >= policy::MAX_STEPS {
        return Err(Error::RustError("poll_step_limit".into()));
    }
    let t = now();
    let scan_due = int(&row, "due_at") <= t + 30 && int(&row, "retry_at") <= t;
    // Finish a published observation before another scan; future releases and
    // accepted-observation outboxes never wait for a failing publisher.
    let action = if int(&row, "draining") == 1 {
        "drain"
    } else if int(&row, "preparing") == 1 {
        "prepare"
    } else if int(&row, "outboxing") == 1 {
        "outbox"
    } else if scan_due {
        "scan"
    } else {
        return settle_idle(&db, &fence).await;
    };
    let mut response = observation::runtime::execute(
        &format!("/{action}"),
        &fence.feed,
        env.clone(),
        Some(fence.clone()),
        db.clone(),
    )
    .await?;
    match response.status_code() {
        200 => {}
        // Memory admission pressure is never a handling failure.
        429 => {
            stat(&db, crate::database::polling::Counter::ScanBusy).await?;
            let view = crate::feed_scan_admission::FeedScanPermit::view();
            console_log!(
                "{}",
                json!({"event":"poll_outcome","outcome":"scan_busy","active_permits":view.active_permits,"oldest_permit_age_seconds":view.oldest_permit_age_seconds,"holder_step":view.holder_step,"isolate":view.isolate})
            );
            let delay = if view.oldest_permit_age_seconds >= policy::STALLED_OWNER_SECONDS {
                console_warn!(
                    "{}",
                    json!({"event":"scan_permit_stalled","owner_age_seconds":view.oldest_permit_age_seconds,"isolate":view.isolate})
                );
                60
            } else {
                policy::contention_delay(&format!("{}{}", fence.feed, wake.step))
            };
            return proceed(&env, &db, &fence, &wake, delay, "scan_busy").await;
        }
        // Another scan owns the feed. Look again when its lease can end.
        409 => {
            let delay = (int(&row, "lease_until") - t).clamp(5, 180);
            return proceed(&env, &db, &fence, &wake, delay, "scan_held").await;
        }
        _ => return Err(Error::RustError("poll_step_failed".into())),
    }
    if action != "scan" && action != "prepare" {
        return proceed(&env, &db, &fence, &wake, 0, "continued").await;
    }
    let status: Value = response.json().await?;
    match string(&status, "result") {
        // The unchanged statement settled schedule and generation together.
        "not_modified" | "unchanged" => {
            if status["settled"] != true {
                return Ok("obsolete");
            }
            Ok(if string(&status, "result") == "unchanged" {
                "unchanged"
            } else {
                "not_modified"
            })
        }
        "published" => {
            console_log!(
                "{}",
                json!({"event":"poll_published","feed_id":fence.feed,"due_lag_seconds":t-fence.schedule.due_at,"candidates":status["candidates"]})
            );
            // A candidate-free publication settled itself; otherwise drain.
            if status["settled"] == true {
                return Ok("published");
            }
            proceed(&env, &db, &fence, &wake, 0, "published").await
        }
        "publisher_failed" => Ok("publisher_failed"),
        "origin_deferred" => {
            let until = status["cooldown_until"].as_i64().unwrap_or(0);
            if until > t + 60 {
                // A publisher cooldown is schedule state, not a held message.
                let changed = database::execute(
                    &db,
                    Operation::SettleCooldown {
                        fence: fence.storage(),
                        until,
                        now: t,
                    },
                )
                .await?
                .count();
                if changed == 0 {
                    fence.rejected(&db).await?;
                }
                return Ok("origin_cooldown");
            }
            let delay =
                policy::contention_delay(&format!("{}{}", fence.feed, wake.step)).max(until - t);
            proceed(&env, &db, &fence, &wake, delay, "origin_deferred").await
        }
        "lost_fence" => Ok("obsolete"),
        // Staged, or a preparation step that checkpointed or found nothing to
        // resume: look at the durable state again.
        _ => {
            let waiting = crate::database::slice_b::execute(
                &db,
                crate::database::slice_b::Operation::ReadPreparationWait {
                    feed: fence.feed.clone(),
                },
            )
            .await?
            .first();
            let delay = waiting
                .map(|w| int(&w, "processing_next_at").max(int(&w, "processing_until")) - now())
                .unwrap_or(5);
            proceed(&env, &db, &fence, &wake, delay, "staged").await
        }
    }
}

/// Nothing is due for this generation any more.
async fn settle_idle(db: &crate::database::Authority, fence: &Fence) -> Result<&'static str> {
    let changed = database::execute(
        db,
        Operation::SettleIdle {
            fence: fence.storage(),
            now: now(),
        },
    )
    .await?
    .count();
    if changed == 0 {
        fence.rejected(db).await?;
        return Ok("obsolete");
    }
    Ok("settled")
}

/// Durable progress is saved; chain the next step under the same generation.
/// A lost continuation is repaired by the reservation expiring.
async fn proceed(
    env: &Env,
    db: &crate::database::Authority,
    fence: &Fence,
    wake: &dispatch::Wakeup,
    delay: i64,
    name: &'static str,
) -> Result<&'static str> {
    let delay = delay.clamp(0, 900);
    let t = now();
    let changed = database::execute(
        db,
        Operation::RenewContinuation {
            fence: fence.storage(),
            delay,
            now: t,
        },
    )
    .await?
    .count();
    if changed == 0 {
        fence.rejected(db).await?;
        return Ok("obsolete");
    }
    let mut next = wake.clone();
    next.step += 1;
    dispatch::send(env, vec![next], delay as u32).await?;
    Ok(name)
}
