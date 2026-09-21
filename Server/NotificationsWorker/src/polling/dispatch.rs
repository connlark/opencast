//! One-minute admission. The feed row is the only schedule state: a dispatch
//! reserves the feed and advances its generation in one statement, and the
//! returned rows become Queue messages. There is no per-attempt job row.
use super::{execute, origin, policy};
use crate::delivery::{
    db::*,
    wire::{int, string},
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use worker::*;

pub const SCHEMA_VERSION: u8 = 2;
/// Opaque references only: never a URL, token or validator.
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Wakeup {
    pub schema_version: u8,
    pub environment: String,
    /// `poll` advances one feed; `cleanup` is the private maintenance wakeup.
    pub kind: String,
    pub feed_id: String,
    pub owner_epoch: i64,
    /// Dispatch generation for a poll; the minute for cleanup.
    pub generation: i64,
    pub due_at: i64,
    /// Continuation count within this generation.
    #[serde(default)]
    pub step: u32,
}

const ELIGIBLE:&str="f.admission_paused=0 AND f.no_interest_since IS NULL AND EXISTS(SELECT 1 FROM n_interest j JOIN n_install i ON i.install_id=j.install_id WHERE j.feed_id=f.feed_id AND j.enabled=1 AND i.enabled=1)";
const CONTROLS:&str="EXISTS(SELECT 1 FROM n_control WHERE name='dispatcher_admission' AND enabled=1) AND EXISTS(SELECT 1 FROM n_control WHERE name='feed_observation' AND enabled=1)";

pub async fn run_dispatch(env: &Env) -> Result<Value> {
    let db = env.d1("APP_ATTEST_DB")?;
    if !super::runtime::enabled(env, &db).await? {
        return Ok(json!({"disabled":true}));
    }
    let t = now();
    // Incomplete preparations with an obsolete interest generation cannot block
    // a new baseline. Retain their conservative recovery evidence for seven days.
    let abandoned = run(&db,"UPDATE n_observation SET state='abandoned',processing_token=NULL,processing_until=NULL WHERE observation_id IN(SELECT o.observation_id FROM n_observation o JOIN n_feed f ON f.feed_id=o.feed_id WHERE o.state='staging' AND (o.owner_epoch<>f.epoch OR o.eligibility_generation<>f.eligibility_generation OR f.no_interest_since IS NOT NULL) LIMIT 100)",&[]).await?;
    if abandoned > 0 {
        console_log!(
            "{}",
            json!({"event":"poll_eligibility_abandoned","count":abandoned})
        );
    }
    // Bounded early admission leaves processing headroom within the minute tick.
    // An unexpired reservation is the only thing that hides a due feed.
    let base=format!("{ELIGIBLE} AND f.dispatch_until<=?1 AND f.due_at<=?1+30 AND f.retry_at<=?1 AND NOT EXISTS(SELECT 1 FROM n_poll_origin h WHERE h.origin_key=f.origin_key AND h.cooldown_until>?1)");
    let query = |baseline: bool, limit: usize| {
        format!("SELECT feed_id,canonical_url FROM (SELECT f.feed_id,f.canonical_url,f.due_at,ROW_NUMBER() OVER(PARTITION BY COALESCE(f.origin_key,f.feed_id) ORDER BY f.due_at,f.feed_id) AS host_rank FROM n_feed f WHERE {base} AND (f.snapshot_key IS NULL)={}) ORDER BY host_rank,due_at,feed_id LIMIT {limit}",i32::from(baseline))
    };
    let mut recurring = rows(&db, &query(false, policy::DISPATCH_LIMIT), &[json!(t)])
        .await?
        .into_iter();
    let mut baselines = rows(&db, &query(true, policy::DISPATCH_LIMIT), &[json!(t)])
        .await?
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
    let polls = reserve(env, &db, &admitted, t).await?;
    // Separate maintenance admission keeps future/outbox recovery independent
    // of recurring due dates, publisher backoff and origin cooldowns. Oldest
    // work is selected, not alphabetical feeds. It also resumes a preparation
    // whose continuation message was lost.
    let pending = format!(
        "({} OR {} OR {})",
        execute::DRAINING.replace("?4", "?1"),
        execute::OUTBOXING.replace("?4", "?1"),
        execute::PREPARING.replace("?4", "?1")
    );
    let maintenance=rows(&db,&format!("SELECT f.feed_id,f.canonical_url FROM n_feed f WHERE {ELIGIBLE} AND f.dispatch_until<=?1 AND {pending} ORDER BY f.due_at,f.feed_id LIMIT 100"),&[json!(t)]).await?;
    let maintenance = maintenance.iter().map(record).collect::<Result<Vec<_>>>()?;
    let maintained = reserve(env, &db, &maintenance, t).await?;
    if permitted(env, &db, "cleanup").await?
        && t.div_euclid(60) % policy::CLEANUP_INTERVAL_MINUTES == 0
    {
        super::cleanup::enqueue(env, t.div_euclid(60)).await?;
        run(
            &db,
            "DELETE FROM n_poll_stat WHERE bucket<?1",
            &[json!(t.div_euclid(3600) - 48)],
        )
        .await?;
    }
    // The one-minute cost/lag rollup: no per-poll diagnostic rows exist.
    let mut rollup = first(&db,&format!("SELECT (SELECT COUNT(*) FROM n_feed f WHERE {ELIGIBLE} AND f.due_at<=?1) AS overdue,(SELECT COALESCE(MAX(?1-f.due_at),0) FROM n_feed f WHERE {ELIGIBLE} AND f.due_at<=?1 AND f.poll_failures=0 AND f.handling_failures=0 AND f.retry_at<=?1) AS oldest_due_seconds,(SELECT COUNT(*) FROM n_feed f WHERE f.dispatch_until>?1) AS in_flight,(SELECT COUNT(*) FROM n_feed f WHERE f.last_poll_at>?1-60 AND f.last_poll_outcome IN('not_modified','unchanged')) AS unchanged_last_minute,(SELECT COUNT(*) FROM n_feed f WHERE f.last_poll_at>?1-60 AND f.last_poll_outcome='published') AS published_last_minute,(SELECT COUNT(*) FROM n_feed f WHERE f.last_poll_at>?1-60 AND f.last_poll_outcome NOT IN('not_modified','unchanged','published')) AS failed_last_minute"),&[json!(t)]).await?.unwrap_or_else(|| json!({}));
    rollup["admitted"] = json!(polls);
    rollup["maintenance_admitted"] = json!(maintained);
    console_log!("{}", json!({"event":"poll_dispatch","work":rollup}));
    Ok(rollup)
}
fn record(row: &Value) -> Result<Value> {
    let url = url::Url::parse(string(row, "canonical_url"))
        .map_err(|_| Error::RustError("invalid_feed_mapping".into()))?;
    Ok(json!({"feed_id":row["feed_id"],"origin_key":origin::key(&url)}))
}
/// Reserve and advance the generation atomically. Overlapping dispatchers
/// cannot both reserve a feed, so no dispatcher lease is needed; only the rows
/// this statement returned are enqueued.
async fn reserve(env: &Env, db: &D1Database, records: &[Value], t: i64) -> Result<usize> {
    if records.is_empty() {
        return Ok(0);
    }
    let reserved=rows(db,&format!("UPDATE n_feed AS f SET schedule_generation=f.schedule_generation+1,dispatch_until=?2+{},origin_key=json_extract(j.value,'$.origin_key') FROM json_each(?1) j WHERE f.feed_id=json_extract(j.value,'$.feed_id') AND f.dispatch_until<=?2 AND {ELIGIBLE} AND {CONTROLS} RETURNING feed_id,epoch,schedule_generation,due_at",policy::DISPATCH_RESERVATION_SECONDS),&[json!(records),json!(t)]).await?;
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
        if send(env, chunk.to_vec(), 0).await.is_err() {
            // The send outcome is unknown. Settle these generations so the
            // next minute issues new ones; a message that did arrive is stale.
            let lost: Vec<_> = chunk
                .iter()
                .map(|w| json!({"feed_id":w.feed_id,"generation":w.generation}))
                .collect();
            run(db,"UPDATE n_feed SET dispatch_until=0 FROM json_each(?1) j WHERE n_feed.feed_id=json_extract(j.value,'$.feed_id') AND n_feed.schedule_generation=json_extract(j.value,'$.generation')",&[json!(lost)]).await?;
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
pub async fn stats(db: &D1Database) -> Result<Value> {
    let t = now();
    let cooling = "EXISTS(SELECT 1 FROM n_poll_origin h WHERE h.origin_key=f.origin_key AND h.cooldown_until>?1)";
    let healthy =
        format!("f.poll_failures=0 AND f.handling_failures=0 AND f.retry_at<=?1 AND NOT {cooling}");
    let eligible = format!("{ELIGIBLE} AND f.due_at<=?1");
    let mut value = first(db,&format!("SELECT
        (SELECT COUNT(*) FROM n_feed f WHERE {eligible}) AS overdue,
        (SELECT COUNT(*) FROM n_feed f WHERE {eligible} AND {healthy}) AS healthy_overdue,
        (SELECT COALESCE(MAX(?1-f.due_at),0) FROM n_feed f WHERE {eligible} AND {healthy}) AS oldest_due_seconds,
        (SELECT COALESCE(MAX(?1-f.due_at),0) FROM n_feed f WHERE {eligible} AND NOT({healthy})) AS oldest_unhealthy_due_seconds,
        (SELECT COUNT(*) FROM n_feed f WHERE {ELIGIBLE} AND f.handling_failures=0 AND (f.poll_failures>0 OR f.retry_at>?1 OR {cooling})) AS publisher_backoff,
        (SELECT COUNT(*) FROM n_feed f WHERE {ELIGIBLE} AND f.handling_failures>0) AS dead_lettered,
        (SELECT COUNT(*) FROM n_feed f WHERE f.dispatch_until>?1) AS in_flight,
        (SELECT COUNT(*) FROM n_feed f WHERE f.dispatch_until>0 AND f.dispatch_until<=?1) AS reservation_expired,
        (SELECT COALESCE(MAX(?1-f.due_at),0) FROM n_feed f WHERE f.dispatch_until>?1 AND f.due_at<=?1) AS queue_age_seconds,
        (SELECT COUNT(*) FROM n_poll_origin WHERE cooldown_until>?1) AS origin_cooldowns,
        (SELECT COUNT(*) FROM n_observation WHERE state='abandoned' AND processing_failures>=10) AS preparation_abandoned,
        (SELECT COUNT(*) FROM n_observation WHERE state='abandoned' AND processing_failures<10) AS eligibility_abandoned,
        (SELECT COUNT(*) FROM n_burst WHERE complete=0 AND failures>=10) AS burst_poisoned,
        (SELECT COUNT(*) FROM n_outbox WHERE source='feed_polling' AND state='pending') AS source_pending,
        (SELECT COUNT(*) FROM n_snapshot s WHERE s.state IN('reserved','uploaded','referenced','gc_claimed') AND s.gc_after<=?1 AND NOT({})) AS snapshot_orphan_total,
        (SELECT COALESCE(SUM(publisher_failures),0) FROM n_poll_stat WHERE bucket>=?2) AS publisher_failure_total,
        (SELECT COALESCE(SUM(handling_failures),0) FROM n_poll_stat WHERE bucket>=?2) AS handling_failure_total,
        (SELECT COALESCE(SUM(redeliveries),0) FROM n_poll_stat WHERE bucket>=?2) AS redelivery_total,
        (SELECT COALESCE(SUM(dead_letters),0) FROM n_poll_stat WHERE bucket>=?2) AS dead_letter_total,
        (SELECT COALESCE(SUM(stale_commits),0) FROM n_poll_stat WHERE bucket>=?2) AS stale_commit_total,
        (SELECT COALESCE(SUM(retry_after_clamps),0) FROM n_poll_stat WHERE bucket>=?2) AS retry_after_clamped_total",crate::observation::gc::live("s")),&[json!(t),json!(t.div_euclid(3600)-24)]).await?.ok_or_else(||Error::RustError("poll_stats_missing".into()))?;
    // Failure, redelivery and rejected-commit totals are a rolling 24 hours.
    // Healthy polls leave only the feed's last outcome and sampled events.
    value["counter_window"] = json!("rolling_24_hours");
    value["wasm_memory_bytes"] = json!(crate::runtime_diagnostics::current().wasm_memory_bytes);
    Ok(value)
}
