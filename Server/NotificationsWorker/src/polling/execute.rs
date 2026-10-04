//! The Queue message wakes a durable feed obligation. Delivery failure and the
//! consumer's retry policy own crash recovery; the feed's owner epoch and
//! dispatch generation decide whether a delivery may still mutate anything.
//! A redelivery may repeat one conditional fetch. It can never publish twice:
//! snapshot publication, event keys and the settle statement are all fenced.
use super::{dispatch, policy, stat};
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
}
impl Fence {
    pub async fn rejected(&self, db: &D1Database) -> Result<()> {
        stat(db, "stale_commits").await?;
        console_log!("{}", json!({"event":"poll_stale_commit","count":1}));
        Ok(())
    }
    /// `dispatch_until>0` marks the generation as not yet settled. Its expiry
    /// only lets the dispatcher repair the same generation; elapsed time alone
    /// grants and removes nothing.
    pub fn sql(&self, _t: i64) -> String {
        // The feed ID is a validated hex digest, never raw request text.
        format!("EXISTS(SELECT 1 FROM n_feed f WHERE f.feed_id='{}' AND f.epoch={} AND f.schedule_generation={} AND f.dispatch_until>0 AND f.admission_paused=0 AND f.no_interest_since IS NULL AND EXISTS(SELECT 1 FROM n_interest j JOIN n_install i ON i.install_id=j.install_id WHERE j.feed_id=f.feed_id AND j.enabled=1 AND i.enabled=1) AND EXISTS(SELECT 1 FROM n_control WHERE name='dispatcher_admission' AND enabled=1) AND EXISTS(SELECT 1 FROM n_control WHERE name='feed_observation' AND enabled=1))",self.feed,self.epoch,self.generation)
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
pub(crate) async fn fetch_failed(env: &Env, fence: &Fence, reason: &str) -> Result<()> {
    let db = env.d1("APP_ATTEST_DB")?;
    let t = now();
    let changed = run(&db,&format!("UPDATE n_feed SET retry_at=?2+MIN(21600,300*(1<<MIN(poll_failures,7))),poll_failures=MIN(poll_failures+1,12),dispatch_until=0,last_poll_at=?2,last_poll_outcome='publisher_failed',last_poll_error=?3 WHERE feed_id=?1 AND {}",fence.sql(t)),&[json!(fence.feed),json!(t),json!(reason)]).await?;
    if changed == 0 {
        return fence.rejected(&db).await;
    }
    stat(&db, "publisher_failures").await
}

pub async fn consume(
    env: Env,
    wake: dispatch::Wakeup,
    attempts: u32,
    signal: web_sys::AbortSignal,
    enqueued_ms: Option<u64>,
) -> Result<Response> {
    let started = super::timing::now_ms();
    let timings = super::timing::Timings::default();
    let db = env.d1("APP_ATTEST_DB")?;
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
        return outcome("cleanup_ignored");
    }
    if wake.kind != "poll" || !wire::hex_id(&wake.feed_id) || wake.owner_epoch < 1 {
        return Response::error("invalid_wakeup", 400);
    }
    let claimed: Rc<RefCell<Option<Fence>>> = Default::default();
    let step_claimed = claimed.clone();
    let step_timings = timings.clone();
    let step_env = env.clone();
    let step_wake = wake.clone();
    let result = crate::invocation_owner::run_with_abort_signal_and_deadline(
        signal,
        async move {
            let db = step_env.d1("APP_ATTEST_DB")?;
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
            };
            if attempts > 1 {
                stat(&db, "redeliveries").await?;
                console_log!(
                    "{}",
                    json!({"event":"poll_redelivered","attempts":attempts,"step":step_wake.step})
                );
            }
            *step_claimed.borrow_mut() = Some(fence.clone());
            step(step_env, fence, step_wake, row).await
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
                        stat(&db, "handling_failures").await?;
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
    let plain = matches!(name, "unchanged" | "not_modified");
    let sampled = plain && policy::sampled(&wake.feed_id, wake.generation);
    if !plain || sampled || wall_ms > 5000 || initial_queue_wait_ms.is_some_and(|ms| ms > 120_000) {
        console_log!(
            "{}",
            json!({"event":"poll_delivery","outcome":name,"feed":wake.feed_id,"origin":*timings.origin.borrow(),"step":wake.step,"attempts":attempts,"message_age_ms":message_age_ms,"initial_queue_wait_ms":initial_queue_wait_ms,"due_lag_seconds":due_lag_seconds,"wall_ms":wall_ms,"claim_ms":timings.claim.get(),"publisher_fetch_ms":timings.publisher.get(),"storage_ms":wall_ms.saturating_sub(timings.claim.get()).saturating_sub(timings.publisher.get()),"sample":if plain && wall_ms<=5000 && initial_queue_wait_ms.is_none_or(|ms|ms<=120_000) {policy::SUCCESS_LOG_SAMPLE} else {1}})
        );
    }
    outcome(name).map(|response| response.with_status(status))
}

/// A failed or cancelled step may have claimed the scan lease after proving a
/// change. Free it for the redelivery, unless it guards a complete preparation
/// that the redelivery resumes instead of refetching.
async fn release(db: &D1Database, fence: &Fence, outcome: &str, reason: &str) -> Result<()> {
    let idle = "NOT EXISTS(SELECT 1 FROM n_observation o WHERE o.lease_id=n_feed.lease_id AND o.state='staging' AND o.valid_eof=1)";
    let lease = fence.scan_lease.borrow().clone();
    run(db,&format!("UPDATE n_feed SET last_poll_at=?2,last_poll_outcome=?3,last_poll_error=?4,lease_until=CASE WHEN lease_id=?5 AND {idle} THEN NULL ELSE lease_until END,lease_id=CASE WHEN lease_id=?5 AND {idle} THEN NULL ELSE lease_id END WHERE feed_id=?1 AND {}",fence.sql(now())),&[json!(fence.feed),json!(now()),json!(outcome),json!(reason.chars().take(96).collect::<String>()),json!(lease)]).await?;
    Ok(())
}
fn outcome(name: &str) -> Result<Response> {
    Response::from_json(&json!({ "outcome": name }))
}

/// The exhausted message is diagnostic; the feed row is the recovery source.
/// Back the feed off without blaming its publisher and settle the generation.
pub async fn dead_letter(env: &Env, wake: &dispatch::Wakeup) -> Result<Response> {
    let db = env.d1("APP_ATTEST_DB")?;
    // A release brake exhausts messages too; that is not the feed's fault.
    if wake.kind != "poll"
        || !wire::hex_id(&wake.feed_id)
        || !super::runtime::permitted_by_environment(env)
    {
        return outcome("ignored");
    }
    let t = now();
    let changed = run(&db,"UPDATE n_feed SET retry_at=?4+MIN(21600,300*(1<<MIN(handling_failures,7))),handling_failures=MIN(handling_failures+1,12),dispatch_until=0,last_poll_at=?4,last_poll_outcome='dead_letter' WHERE feed_id=?1 AND epoch=?2 AND schedule_generation=?3 AND dispatch_until>0",&[json!(wake.feed_id),json!(wake.owner_epoch),json!(wake.generation),json!(t)]).await?;
    if changed > 0 {
        stat(&db, "dead_letters").await?;
    }
    console_warn!(
        "{}",
        json!({"event":"poll_dead_letter","feed_id":wake.feed_id,"settled":changed>0})
    );
    outcome("dead_letter_saved")
}

pub(super) const PREPARING:&str="EXISTS(SELECT 1 FROM n_observation o WHERE o.feed_id=f.feed_id AND o.state='staging' AND o.valid_eof=1 AND o.processing_failures<10 AND o.lease_id=f.lease_id AND o.owner_epoch=f.epoch AND o.eligibility_generation=f.eligibility_generation AND o.scan_started_at>?4-604800)";
pub(super) const DRAINING:&str="(EXISTS(SELECT 1 FROM n_observation o WHERE o.feed_id=f.feed_id AND o.state='published' AND o.drain_complete=0 AND o.owner_epoch=f.epoch) OR EXISTS(SELECT 1 FROM n_episode_release r WHERE r.feed_id=f.feed_id AND r.owner_epoch=f.epoch AND r.state IN('ready','pending_future') AND r.eligible_at<=?4 AND r.expires_at>?4))";
pub(super) const OUTBOXING:&str="EXISTS(SELECT 1 FROM n_outbox x JOIN n_observation o ON o.observation_id=x.observation_id WHERE o.feed_id=f.feed_id AND o.owner_epoch=f.epoch AND x.source='feed_polling' AND x.state='pending' AND x.next_attempt_at<=?4)";

async fn claim(db: &D1Database, wake: &dispatch::Wakeup) -> Result<Option<Value>> {
    first(db,&format!("SELECT f.origin_key,f.due_at,f.retry_at,f.baseline_at,f.credible_release_at,f.credible_cadence,f.publish_cadence,f.lease_until,{PREPARING} AS preparing,{DRAINING} AS draining,{OUTBOXING} AS outboxing,COALESCE((SELECT enabled FROM n_control WHERE name='five_minute_polling'),0) AS five_minute FROM n_feed f WHERE f.feed_id=?1 AND f.epoch=?2 AND f.schedule_generation=?3 AND f.dispatch_until>0 AND f.admission_paused=0 AND f.no_interest_since IS NULL AND EXISTS(SELECT 1 FROM n_interest j JOIN n_install i ON i.install_id=j.install_id WHERE j.feed_id=f.feed_id AND j.enabled=1 AND i.enabled=1) AND EXISTS(SELECT 1 FROM n_control WHERE name='dispatcher_admission' AND enabled=1) AND EXISTS(SELECT 1 FROM n_control WHERE name='feed_observation' AND enabled=1)"),&[json!(wake.feed_id),json!(wake.owner_epoch),json!(wake.generation),json!(now())]).await
}

/// One bounded step. The action is derived from durable observation state, so
/// a redelivered or re-dispatched message resumes exactly where work stopped.
async fn step(env: Env, fence: Fence, wake: dispatch::Wakeup, row: Value) -> Result<&'static str> {
    let db = env.d1("APP_ATTEST_DB")?;
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
    )
    .await?;
    match response.status_code() {
        200 => {}
        // Memory admission pressure is never a handling failure.
        429 => {
            stat(&db, "scan_busy").await?;
            let view = crate::feed_scan_admission::FeedScanPermit::view();
            console_log!(
                "{}",
                json!({"event":"poll_outcome","outcome":"scan_busy","active_permits":view.active_permits,"oldest_permit_age_seconds":view.oldest_permit_age_seconds,"holder_step":view.holder_step,"isolate":view.isolate})
            );
            let delay = if view.oldest_permit_age_seconds >= 60 {
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
                let changed = run(&db,&format!("UPDATE n_feed SET retry_at=MAX(retry_at,?2),dispatch_until=0,last_poll_at=?3,last_poll_outcome='origin_cooldown' WHERE feed_id=?1 AND {}",fence.sql(t)),&[json!(fence.feed),json!(until),json!(t)]).await?;
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
            let waiting=first(&db,"SELECT processing_next_at,processing_until FROM n_observation WHERE feed_id=?1 AND state='staging' AND valid_eof=1 AND processing_failures<10 ORDER BY scan_started_at DESC LIMIT 1",&[json!(fence.feed)]).await?;
            let delay = waiting
                .map(|w| int(&w, "processing_next_at").max(int(&w, "processing_until")) - now())
                .unwrap_or(5);
            proceed(&env, &db, &fence, &wake, delay, "staged").await
        }
    }
}

/// Nothing is due for this generation any more.
async fn settle_idle(db: &D1Database, fence: &Fence) -> Result<&'static str> {
    let changed = run(
        db,
        &format!(
            "UPDATE n_feed SET dispatch_until=0 WHERE feed_id=?1 AND {}",
            fence.sql(now())
        ),
        &[json!(fence.feed)],
    )
    .await?;
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
    db: &D1Database,
    fence: &Fence,
    wake: &dispatch::Wakeup,
    delay: i64,
    name: &'static str,
) -> Result<&'static str> {
    let delay = delay.clamp(0, 900);
    let t = now();
    let changed = run(
        db,
        &format!(
            "UPDATE n_feed SET dispatch_until=?2 WHERE feed_id=?1 AND {}",
            fence.sql(t)
        ),
        &[
            json!(fence.feed),
            json!(t + delay + policy::DISPATCH_RESERVATION_SECONDS),
        ],
    )
    .await?;
    if changed == 0 {
        fence.rejected(db).await?;
        return Ok("obsolete");
    }
    let mut next = wake.clone();
    next.step += 1;
    dispatch::send(env, vec![next], delay as u32).await?;
    Ok(name)
}
