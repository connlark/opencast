use super::{
    db::*,
    recovery,
    wire::{self, int, string, Event},
};
use crate::database::slice_d::{self as storage, Operation};
use worker::{Env, Result};

pub async fn page(
    db: &crate::database::Authority,
    env: &Env,
    source: &str,
    event_id: &str,
) -> Result<()> {
    if source == "feed_polling" && super::grouping::page(db, env, event_id).await? {
        return Ok(());
    }
    let t = now();
    let lease = id();
    let result = async {
        if storage::execute(
            db,
            Operation::ClaimEvent {
                source: source.to_owned(),
                event: event_id.to_owned(),
                lease: lease.to_owned(),
                now: t,
            },
        )
        .await?
        .count()
            == 0
        {
            return Ok(());
        }
        let Some(row) = storage::execute(
            db,
            Operation::ReadClaimedEvent {
                source: source.to_owned(),
                event: event_id.to_owned(),
                lease: lease.to_owned(),
            },
        )
        .await?
        .first() else {
            return Ok(());
        };
        let event: Event = serde_json::from_str(string(&row, "envelope_json"))?;
        let cursor = string(&row, "fanout_cursor");
        let episode = event.kind == "episode";
        let key = if episode {
            string(&event.routing, "feed_id")
        } else {
            string(&event.routing, "interest_id")
        };
        let recipients = if episode {
            storage::execute(
                db,
                Operation::ReadEpisodeRecipients {
                    feed: key.to_owned(),
                    occurred_at: event.occurred_at,
                    cursor: cursor.to_owned(),
                    reason: serde_json::from_value(event.data["decision_reason"].clone())?,
                    generation: serde_json::from_value(
                        event.routing["observation_generation"].clone(),
                    )?,
                    eligible_at: event.eligible_at,
                    published_at: serde_json::from_value(event.data["published_at"].clone())?,
                },
            )
            .await?
            .rows()
        } else {
            storage::execute(
                db,
                Operation::ReadJobRecipients {
                    interest: key.to_owned(),
                    cursor: cursor.to_owned(),
                    run: serde_json::from_value(event.routing["run_id"].clone())?,
                    generation: serde_json::from_value(
                        event.routing["interest_generation"].clone(),
                    )?,
                },
            )
            .await?
            .rows()
        };
        let t = now();
        let mut page_recipients = vec![];
        let mut delivery_ids = vec![];
        for recipient in &recipients {
            let install = string(recipient, "install_id");
            let generation = int(recipient, "generation");
            let epoch = int(recipient, "epoch");
            let delivery = wire::hash(&[
                "delivery-v1",
                &lane(env),
                event_id,
                install,
                &epoch.to_string(),
                key,
                &generation.to_string(),
            ]);
            page_recipients.push(storage::FanoutRecipient {
                delivery: delivery.clone(),
                install: install.into(),
                epoch,
                generation,
                apns: id(),
            });
            delivery_ids.push((delivery, generation));
        }
        let last = recipients
            .last()
            .map(|r| string(r, "install_id"))
            .unwrap_or(cursor);
        storage::execute(
            db,
            Operation::Fanout {
                page: storage::FanoutPage {
                    episode,
                    source: source.into(),
                    event: event_id.into(),
                    lease: lease.clone(),
                    cursor: cursor.into(),
                    last: last.into(),
                    complete: recipients.len() < 100,
                    interest: key.into(),
                    expires_at: event.expires_at,
                    now: t,
                    owner_epoch: serde_json::from_value(event.routing["owner_epoch"].clone())?,
                    episode_id: serde_json::from_value(event.routing["episode_id"].clone())?,
                    fingerprint: serde_json::from_value(event.data["fingerprint"].clone())?,
                    run: serde_json::from_value(event.routing["run_id"].clone())?,
                    recipients: page_recipients,
                },
            },
        )
        .await?;
        let queue = if episode {
            "EPISODE_DELIVERY_QUEUE"
        } else {
            "JOB_DELIVERY_QUEUE"
        };
        for (id, generation) in delivery_ids {
            let _ = recovery::enqueue(env, queue, source, &id, generation).await;
        }
        if recipients.len() == 100 {
            let _ = recovery::enqueue(env, "EVENT_QUEUE", source, event_id, 1).await;
        }
        Ok(())
    }
    .await;
    if result.is_err() {
        recovery::failed(db, "event", source, event_id, &lease).await?;
    }
    result
}
