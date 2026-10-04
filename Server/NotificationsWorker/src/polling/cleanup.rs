//! Scheduled maintenance owns no poll Queue slot. Durable object reservations
//! are the cursor; unfinished work resumes on the next two-minute invocation.
use crate::delivery::db::*;
use serde_json::json;
use worker::*;

const LIMIT: usize = 200;
pub async fn consume(env: &Env, db: &D1Database, generation: i64) -> Result<()> {
    let budget = crate::observation::gc::Budget::new(super::policy::CLEANUP_BUDGET_SECONDS);
    if !permitted(env, db, "cleanup").await? {
        return Ok(());
    }
    let t = now();
    let lease = id();
    if run(db,"UPDATE n_poll_dispatch SET cleanup_lease=?1,cleanup_until=?2+180 WHERE id=1 AND cleanup_until<=?2 AND cleanup_generation<?3",&[json!(lease),json!(t),json!(generation)]).await? == 0 { return Ok(()); }
    // Retention cannot sit behind an exhausted scratch/object budget.
    run(
        db,
        "DELETE FROM n_poll_stat WHERE bucket<?1",
        &[json!(t.div_euclid(3600) - 48)],
    )
    .await?;
    let bucket = env.bucket("FEED_SNAPSHOTS")?;
    // Scratch has no D1 row. An aborted upload is never an object; this only
    // removes one completed by a scan that crashed before deleting it.
    let scratch =
        crate::observation::scratch::sweep(&bucket, Date::now().as_millis(), &budget).await;
    if let Ok(removed @ 1..) = scratch.as_ref() {
        console_warn!("{}", json!({"event":"feed_scratch_swept","count":removed}));
    }
    let result = crate::observation::gc::collect_bounded(db, &bucket, LIMIT, Some(&budget)).await;
    let exhausted = budget.expired();
    // A budget stop or failure never advances the cursor. A cancelled
    // invocation waits for lease expiry; neither case needs a chained message.
    run(db,"UPDATE n_poll_dispatch SET cleanup_lease=NULL,cleanup_until=0,cleanup_generation=CASE WHEN ?2 THEN MAX(cleanup_generation,?3) ELSE cleanup_generation END WHERE id=1 AND cleanup_lease=?1",&[json!(lease),json!(!exhausted && scratch.is_ok() && result.as_ref().is_ok_and(|n|*n<LIMIT)),json!(generation)]).await?;
    let selected = result?;
    scratch?;
    console_log!(
        "{}",
        json!({"event":"poll_cleanup","selected":selected,"budget_exhausted":exhausted})
    );
    Ok(())
}
