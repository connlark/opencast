//! Claim-before-delete protects every live manifest, including unfinished drains.
use crate::database::slice_e::{self, Operation as EOperation};
use crate::delivery::{db::*, wire::string};
use worker::{Bucket, Result};

/// A cooperative wall budget: finish the current object's fenced delete, then
/// start no new object. The caller retains its cursor when this expires.
pub struct Budget {
    until_ms: u64,
}
impl Budget {
    pub fn new(seconds: u64) -> Self {
        Self {
            until_ms: worker::Date::now().as_millis() + seconds * 1000,
        }
    }
    pub(crate) fn deadline_ms(&self) -> u64 {
        self.until_ms
    }
    pub fn expired(&self) -> bool {
        worker::Date::now().as_millis() >= self.until_ms
    }
}

pub async fn collect(db: &crate::database::Authority, bucket: &Bucket) -> Result<()> {
    collect_bounded(db, bucket, 50, None).await.map(|_| ())
}
/// Scheduled cleanup bounds object count and wall time without changing fences.
pub async fn collect_bounded(
    db: &crate::database::Authority,
    bucket: &Bucket,
    limit: usize,
    budget: Option<&Budget>,
) -> Result<usize> {
    // Retention must make progress even when scratch exhausted the object
    // budget. The existing bounded deletion batches and predicates remain.
    if !crate::database::control(db, "cleanup").await? {
        return Ok(0);
    }
    collect_enabled(bucket, limit, budget, |operation| {
        slice_e::execute(db, operation)
    })
    .await
}

// The storage fixture exercises this exact orchestration. The production
// caller above still checks its stored cleanup control and its Authority.
pub(crate) async fn collect_enabled<F, Fut>(
    bucket: &Bucket,
    limit: usize,
    budget: Option<&Budget>,
    mut execute: F,
) -> Result<usize>
where
    F: FnMut(EOperation) -> Fut,
    Fut: std::future::Future<Output = Result<crate::database::Response>>,
{
    let t = now();
    // History expiry never races a new interest: the eligibility projection and
    // no-interest timestamp are checked again in the pointer transaction.
    execute(EOperation::ExpireFeedHistory { now: t }).await?;
    // Source payloads stop at expiry; compact outcomes last seven more days.
    execute(EOperation::ExpireOutbox { now: t }).await?;
    execute(EOperation::ScrubOutbox { now: t }).await?;
    execute(EOperation::RetireOutbox { now: t }).await?;
    execute(EOperation::RetireReleases { now: t }).await?;
    execute(EOperation::RetireBursts).await?;
    let candidates = if budget.is_some_and(Budget::expired) {
        vec![]
    } else {
        execute(EOperation::ReadGcCandidates { now: t, limit })
            .await?
            .rows()
    };
    let selected = candidates.len();
    for row in candidates {
        if budget.is_some_and(Budget::expired) {
            break;
        }
        let key = string(&row, "object_key");
        if execute(EOperation::ClaimGc {
            now: now(),
            key: key.into(),
        })
        .await?
        .count()
            == 0
        {
            continue;
        }
        if execute(EOperation::ReadGcClaim {
            now: now(),
            key: key.into(),
        })
        .await?
        .first()
        .is_none()
        {
            continue;
        }
        // A failed delete keeps gc_claimed and is retried by the next sweep.
        if bucket.delete(key).await.is_ok() {
            execute(EOperation::MarkDeleted { key: key.into() }).await?;
        }
    }
    execute(EOperation::RetireObservations { now: t }).await?;
    execute(EOperation::RetireSnapshotRefs).await?;
    execute(EOperation::RetireSnapshots).await?;
    Ok(selected)
}
