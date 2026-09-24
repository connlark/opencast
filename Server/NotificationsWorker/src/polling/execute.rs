//! The Queue message is the poll-attempt lease. Delivery failure and the
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
    /// Set once a scan under this fence has sent a publisher request. The
    /// consumer outlives a step it cancels and records the bound for it.
    pub reached: Rc<RefCell<Option<observation::store::Bound>>>,
}
impl Fence {
    pub async fn rejected(&self, db: &D1Database) -> Result<()> {
        stat(db, "stale_commits").await?;
        console_log!("{}", json!({"event":"poll_stale_commit","count":1}));
        Ok(())
    }
    /// `dispatch_until>0` marks the generation as not yet settled. Its expiry
    /// only lets the dispatcher issue a newer generation, which is what fences
    /// this one; elapsed time alone grants and removes nothing.
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
) -> Result<Response> {
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
        super::cleanup::consume(&env, &db, wake.generation).await?;
        return outcome("cleanup_saved");
    }
    if wake.kind != "poll" || !wire::hex_id(&wake.feed_id) || wake.owner_epoch < 1 {
        return Response::error("invalid_wakeup", 400);
    }
    // Read-only claim: a stale epoch or generation stops here, before any
    // fetch. Equal-generation redelivery is allowed and is idempotent.
    let Some(row) = claim(&db, &wake).await? else {
        return outcome("obsolete");
    };
    if attempts > 1 {
        stat(&db, "redeliveries").await?;
        console_log!(
            "{}",
            json!({"event":"poll_redelivered","attempts":attempts,"step":wake.step})
        );
    }
    let fence = Fence {
        feed: wake.feed_id.clone(),
        epoch: wake.owner_epoch,
        generation: wake.generation,
        schedule: policy::ScheduleInputs {
            due_at: int(&row, "due_at"),
            baseline_at: row["baseline_at"].as_i64(),
            credible_release_at: row["credible_release_at"].as_i64(),
            credible_cadence: row["credible_cadence"].as_i64(),
            publish_cadence: row["publish_cadence"].as_i64(),
            five_minute: int(&row, "five_minute") == 1
                && super::runtime::flag(&env, "NOTIFICATION_FIVE_MINUTE_POLLING", true),
        },
        reached: Default::default(),
    };
    let step_env = env.clone();
    let step_fence = fence.clone();
    let step_wake = wake.clone();
    let result = crate::invocation_owner::run_with_abort_signal_and_deadline(
        signal,
        async move { step(step_env, step_fence, step_wake, row).await },
        policy::STEP_DEADLINE_SECONDS,
        wake.step,
    )
    .await;
    if result.is_none() {
        // A dropped scan cannot record its own failure. If it had sent a
        // publisher request, its start still bounds what a retry may first
        // observe; waiting for a permit or an origin slot saw nothing. A step
        // that failed without being dropped has already recorded its own.
        if let Some(bound) = fence.reached.take() {
            bound.record(&db).await?;
        }
    }
    // The scan future, its origin guard and its fetch AbortControllers are
    // gone here. Nothing durable was held, so there is nothing to release.
    match result {
        Some(Ok(name)) => outcome(name),
        Some(Err(error)) => {
            // Never count storage or handling trouble against the publisher.
            let reason = error.to_string();
            stat(&db, "handling_failures").await?;
            release(&db, &fence, "handling_failed", &reason).await?;
            console_warn!(
                "{}",
                json!({"event":"poll_handling_failed","feed_id":fence.feed,"attempts":attempts,"reason":reason})
            );
            // A failed response makes the Queue redeliver, then dead-letter.
            Response::error("poll_step_failed", 500)
        }
        None => {
            console_log!("{}", json!({"event":"poll_outcome","outcome":"cancelled"}));
            release(&db, &fence, "cancelled", "").await?;
            Response::error("poll_cancelled", 503)
        }
    }
}
/// A failed or cancelled step may have claimed the scan lease after proving a
/// change. Free it for the redelivery, unless it guards a complete preparation
/// that the redelivery resumes instead of refetching.
async fn release(db: &D1Database, fence: &Fence, outcome: &str, reason: &str) -> Result<()> {
    let idle = "NOT EXISTS(SELECT 1 FROM n_observation o WHERE o.lease_id=n_feed.lease_id AND o.state='staging' AND o.valid_eof=1)";
    run(db,&format!("UPDATE n_feed SET last_poll_at=?2,last_poll_outcome=?3,last_poll_error=?4,lease_until=CASE WHEN {idle} THEN NULL ELSE lease_until END,lease_id=CASE WHEN {idle} THEN NULL ELSE lease_id END WHERE feed_id=?1 AND {}",fence.sql(now())),&[json!(fence.feed),json!(now()),json!(outcome),json!(reason.chars().take(96).collect::<String>())]).await?;
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
    first(db,&format!("SELECT f.due_at,f.retry_at,f.baseline_at,f.credible_release_at,f.credible_cadence,f.publish_cadence,f.lease_until,{PREPARING} AS preparing,{DRAINING} AS draining,{OUTBOXING} AS outboxing,COALESCE((SELECT enabled FROM n_control WHERE name='five_minute_polling'),0) AS five_minute FROM n_feed f WHERE f.feed_id=?1 AND f.epoch=?2 AND f.schedule_generation=?3 AND f.dispatch_until>0 AND f.admission_paused=0 AND f.no_interest_since IS NULL AND EXISTS(SELECT 1 FROM n_interest j JOIN n_install i ON i.install_id=j.install_id WHERE j.feed_id=f.feed_id AND j.enabled=1 AND i.enabled=1) AND EXISTS(SELECT 1 FROM n_control WHERE name='dispatcher_admission' AND enabled=1) AND EXISTS(SELECT 1 FROM n_control WHERE name='feed_observation' AND enabled=1)"),&[json!(wake.feed_id),json!(wake.owner_epoch),json!(wake.generation),json!(now())]).await
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
            if policy::sampled(&fence.feed, fence.generation) {
                console_log!(
                    "{}",
                    json!({"event":"poll_sample","outcome":status["result"],"due_lag_seconds":t-fence.schedule.due_at,"sample":policy::SUCCESS_LOG_SAMPLE})
                );
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
