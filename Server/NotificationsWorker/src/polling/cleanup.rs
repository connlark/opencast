//! Scheduled maintenance owns no poll Queue slot. Durable object reservations
//! are the cursor; unfinished work resumes on the next two-minute invocation.
use crate::delivery::db::*;
use serde_json::json;
use worker::*;

const LIMIT: usize = 200;
pub async fn consume(env: &Env, db: &crate::database::Authority, generation: i64) -> Result<()> {
    let budget = crate::observation::gc::Budget::new(super::policy::CLEANUP_BUDGET_SECONDS);
    if !crate::database::permitted(env, db, "cleanup").await? {
        return Ok(());
    }
    let t = now();
    let lease = id();
    if crate::database::slice_e::execute(
        db,
        crate::database::slice_e::Operation::ClaimCleanup {
            lease: lease.clone(),
            now: t,
            generation,
        },
    )
    .await?
    .count()
        == 0
    {
        return Ok(());
    }
    // Retention cannot sit behind an exhausted scratch/object budget.
    crate::database::slice_e::execute(
        db,
        crate::database::slice_e::Operation::PrunePollStats {
            before: t.div_euclid(3600) - 48,
        },
    )
    .await?;
    let bucket = env.bucket("FEED_SNAPSHOTS")?;
    // Scratch has no database row. An aborted upload is never an object; this only
    // removes one completed by a scan that crashed before deleting it.
    let scratch =
        crate::observation::scratch::sweep(&bucket, Date::now().as_millis(), &budget, &db.timer())
            .await;
    if let Ok(removed @ 1..) = scratch.as_ref() {
        console_warn!("{}", json!({"event":"feed_scratch_swept","count":removed}));
    }
    // The object budget stops new object work, not the original retirement and
    // lease-release writes. Their independent context stays within the outer cap.
    let bookkeeping = db.bookkeeping(
        budget
            .deadline_ms()
            .saturating_add(super::policy::BOOKKEEPING_DEADLINE_SECONDS * 1000),
    );
    let result =
        crate::observation::gc::collect_bounded(&bookkeeping, &bucket, LIMIT, Some(&budget)).await;
    let exhausted = budget.expired();
    // A budget stop or failure never advances the cursor. A cancelled
    // invocation waits for lease expiry; neither case needs a chained message.
    crate::database::slice_e::execute(
        &bookkeeping,
        crate::database::slice_e::Operation::ReleaseCleanup {
            lease,
            advance: !exhausted && scratch.is_ok() && result.as_ref().is_ok_and(|n| *n < LIMIT),
            generation,
        },
    )
    .await?;
    let selected = result?;
    scratch?;
    console_log!(
        "{}",
        json!({"event":"poll_cleanup","selected":selected,"budget_exhausted":exhausted})
    );
    Ok(())
}
