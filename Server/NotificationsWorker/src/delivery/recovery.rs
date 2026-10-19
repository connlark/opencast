use super::{
    db::*,
    wire::{int, string, TOMBSTONE_SECONDS},
};
use crate::database::slice_e::{self, Operation as EOperation};
use serde::Serialize;
use serde_json::json;
use worker::{Env, Result};

pub async fn enqueue(
    env: &Env,
    binding: &str,
    source: &str,
    id: &str,
    generation: i64,
) -> Result<()> {
    // A struct serializes as a JS object. serde_json::Value maps become JS Map
    // through serde-wasm-bindgen, which Queue JSON encoding would erase to {}.
    #[derive(Serialize)]
    struct Wakeup<'a> {
        schema_version: u8,
        environment: String,
        source: &'a str,
        id: &'a str,
        generation: i64,
    }
    env.queue(binding)?
        .send(Wakeup {
            schema_version: 1,
            environment: lane(env),
            source,
            id,
            generation,
        })
        .await
}
pub async fn failed(
    db: &crate::database::Authority,
    kind: &str,
    source: &str,
    id: &str,
    lease: &str,
) -> Result<()> {
    if kind == "event" {
        slice_e::execute(
            db,
            EOperation::FailedEvent {
                source: source.into(),
                event: id.into(),
                now: now(),
                lease: lease.into(),
            },
        )
        .await?;
    } else {
        slice_e::execute(
            db,
            EOperation::FailedDelivery {
                delivery: id.into(),
                now: now(),
                lease: lease.into(),
            },
        )
        .await?;
    }
    worker::console_warn!("notification handling failure kind={}", kind);
    Ok(())
}
pub async fn reconcile(env: &Env, db: crate::database::Authority) -> Result<()> {
    let t = now();
    slice_e::execute(&db, EOperation::RecoverLeases { now: t }).await?;
    slice_e::execute(&db, EOperation::ExpireDeliveries { now: t }).await?;
    slice_e::execute(&db, EOperation::ExpireEvents { now: t }).await?;
    for row in slice_e::execute(&db, EOperation::ReadDueEvents { now: t })
        .await?
        .rows()
    {
        if enqueue(
            env,
            "EVENT_QUEUE",
            string(&row, "source"),
            string(&row, "event_id"),
            1,
        )
        .await
        .is_err()
        {
            worker::console_warn!("notification event enqueue failed");
        }
    }
    // Independent bounded scans reserve capacity for each lane during catch-up.
    for (binding, switch) in [
        ("EPISODE_DELIVERY_QUEUE", "episode_send"),
        ("JOB_DELIVERY_QUEUE", "job_send"),
    ] {
        if !crate::database::permitted(env, &db, switch).await? {
            continue;
        }
        let work = slice_e::execute(
            &db,
            EOperation::ReadDueDeliveries {
                now: t,
                episode: binding == "EPISODE_DELIVERY_QUEUE",
            },
        )
        .await?
        .rows();
        for row in work {
            if enqueue(
                env,
                binding,
                string(&row, "source"),
                string(&row, "delivery_id"),
                int(&row, "interest_generation"),
            )
            .await
            .is_err()
            {
                worker::console_warn!("notification delivery enqueue failed");
            }
        }
    }
    // Terminal receipts keep only immutable digests/IDs. Source replay cannot
    // extend expiry; the ingress rejects old timestamps even after receipt GC.
    slice_e::execute(&db, EOperation::TerminalizeEvents { now: t }).await?;
    // The keyed deletion fence has a fixed seven-day privacy lifetime; pruning
    // it is user erasure, independent of the periodic cleanup feature switch.
    slice_e::execute(&db, EOperation::ExpireDeletedInstalls { now: t }).await?;
    if crate::database::permitted(env, &db, "cleanup").await? {
        for e in slice_e::execute(
            &db,
            EOperation::ReadTerminalEvents {
                before: t - TOMBSTONE_SECONDS,
            },
        )
        .await?
        .rows()
        {
            slice_e::execute(
                &db,
                EOperation::RetireEvent {
                    source: string(&e, "source").into(),
                    event: string(&e, "event_id").into(),
                },
            )
            .await?;
        }
    }
    if crate::database::permitted(env, &db, "cleanup").await? {
        slice_e::execute(&db, EOperation::ExpireLegacyBridges { now: t }).await?;
        slice_e::execute(&db, EOperation::ExpireTickets { now: t }).await?;
        slice_e::execute(
            &db,
            EOperation::RetireJobInterests {
                before: t - TOMBSTONE_SECONDS,
            },
        )
        .await?;
        // Later observation passes own history/snapshot GC. Only prune empty
        // identities here, after 30 days with no interested installations.
        slice_e::execute(
            &db,
            EOperation::PruneFeeds {
                before: t - TOMBSTONE_SECONDS,
            },
        )
        .await?;
    }
    let work = slice_e::execute(&db, EOperation::ReadDeliverySummary)
        .await?
        .rows();
    let events = slice_e::execute(&db, EOperation::ReadEventSummary)
        .await?
        .first();
    let circuit = slice_e::execute(&db, EOperation::ReadCircuit)
        .await?
        .first();
    worker::console_log!(
        "{}",
        json!({"event":"notification_reconciliation","delivery":work,"fanout":events,"circuit":circuit})
    );
    Ok(())
}

/// Re-enqueue due episode deliveries after an operator resumes a feed. The
/// durable rows remain the source of truth; this only restores queue wakeups
/// that were intentionally suppressed while `send_paused=1`.
pub async fn requeue_feed(env: &Env, db: &crate::database::Authority, feed_id: &str) -> Result<()> {
    let t = now();
    for row in slice_e::execute(
        db,
        EOperation::ReadFeedDeliveries {
            feed: feed_id.into(),
            now: t,
        },
    )
    .await?
    .rows()
    {
        if enqueue(
            env,
            "EPISODE_DELIVERY_QUEUE",
            string(&row, "source"),
            string(&row, "delivery_id"),
            int(&row, "interest_generation"),
        )
        .await
        .is_err()
        {
            worker::console_warn!("notification delivery requeue failed");
        }
    }
    Ok(())
}
