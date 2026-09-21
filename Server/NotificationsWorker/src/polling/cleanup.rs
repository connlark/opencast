//! One private maintenance wakeup, separate from feed job authority. Durable
//! object reservations are the cursor; a lost wakeup resumes on the next minute.
use super::dispatch::Wakeup;
use crate::delivery::db::*;
use serde_json::json;
use worker::*;

const LIMIT: usize = 200;
pub async fn enqueue(env: &Env, generation: i64) -> Result<()> {
    env.queue("POLL_QUEUE")?
        .send(Wakeup {
            schema_version: super::dispatch::SCHEMA_VERSION,
            environment: lane(env),
            kind: "cleanup".into(),
            feed_id: String::new(),
            owner_epoch: 0,
            generation,
            due_at: generation * 60,
            step: 0,
        })
        .await
}
pub async fn consume(env: &Env, db: &D1Database, generation: i64) -> Result<()> {
    if !permitted(env, db, "cleanup").await? {
        return Ok(());
    }
    let t = now();
    if generation > t.div_euclid(60) || generation < t.div_euclid(60) - 60 {
        // A stale or future wakeup; a later interval creates its own.
        return Ok(());
    }
    let lease = id();
    if run(db,"UPDATE n_poll_dispatch SET cleanup_lease=?1,cleanup_until=?2+180 WHERE id=1 AND cleanup_until<=?2 AND cleanup_generation<?3",&[json!(lease),json!(t),json!(generation)]).await? == 0 { return Ok(()); }
    let bucket = env.bucket("FEED_SNAPSHOTS")?;
    // Scratch has no D1 row. An aborted upload is never an object; this only
    // removes one completed by a scan that crashed before deleting it.
    let scratch = crate::observation::scratch::sweep(&bucket, Date::now().as_millis()).await;
    if let Ok(removed @ 1..) = scratch.as_ref() {
        console_warn!("{}", json!({"event":"feed_scratch_swept","count":removed}));
    }
    let result = crate::observation::gc::collect_bounded(db, &bucket, LIMIT).await;
    // Both successful batches and failures release only their own lease. A
    // cancelled invocation/crash waits for expiry; the cron recreates wakeups.
    run(db,"UPDATE n_poll_dispatch SET cleanup_lease=NULL,cleanup_until=0,cleanup_generation=CASE WHEN ?2 THEN MAX(cleanup_generation,?3) ELSE cleanup_generation END WHERE id=1 AND cleanup_lease=?1",&[json!(lease),json!(result.as_ref().is_ok_and(|n|*n<LIMIT)),json!(generation)]).await?;
    let selected = result?;
    scratch?;
    if selected == LIMIT {
        enqueue(env, generation).await?;
    }
    console_log!("{}", json!({"event":"poll_cleanup","selected":selected}));
    Ok(())
}
