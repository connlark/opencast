//! One complete observation determines presentation membership. Fanout waits
//! for the source drain and every member receipt before assigning recipients.
use super::{
    db::*,
    recovery,
    wire::{self, int, string},
};
use crate::database::slice_d::{self as storage, Operation};
use serde::Deserialize;

#[derive(Deserialize)]
struct Member {
    event_id: String,
    episode_id: String,
    eligible_at: i64,
    expires_at: i64,
}
use worker::{Env, Result};

pub async fn page(db: &crate::database::Authority, env: &Env, event_id: &str) -> Result<bool> {
    let Some(release) = storage::execute(
        db,
        Operation::ReadRelease {
            event: event_id.to_owned(),
        },
    )
    .await?
    .first() else {
        return Ok(false);
    };
    let key = string(&release, "presentation_key");
    let feed = string(&release, "feed_id");
    let epoch = int(&release, "owner_epoch");
    let t = now();
    if storage::execute(
        db,
        Operation::ReadUnreadyBurst {
            presentation: key.to_owned(),
        },
    )
    .await?
    .first()
    .is_some()
    {
        return Ok(true);
    }
    storage::execute(
        db,
        Operation::EnsureBurst {
            presentation: key.to_owned(),
            feed: feed.to_owned(),
            epoch: (epoch),
        },
    )
    .await?
    .count();
    let lease = id();
    if storage::execute(
        db,
        Operation::ClaimBurst {
            presentation: key.to_owned(),
            lease: lease.to_owned(),
            now: (t),
        },
    )
    .await?
    .count()
        == 0
    {
        return Ok(true);
    }
    let result = async {
        let burst = storage::execute(
            db,
            Operation::ReadClaimedBurst {
                presentation: key.to_owned(),
                lease: lease.to_owned(),
            },
        )
        .await?
        .first()
        .expect("claimed burst");
        let cursor = string(&burst, "cursor");
        // One installation per invocation bounds the large-burst transaction.
        let recipient = storage::execute(
            db,
            Operation::ReadBurstRecipient {
                feed: feed.to_owned(),
                cursor: cursor.to_owned(),
            },
        )
        .await?
        .first();
        let Some(recipient) = recipient else {
            storage::execute(
                db,
                Operation::CompleteBurst {
                    presentation: key.into(),
                    lease: lease.clone(),
                    events_now: now(),
                    burst_now: now(),
                },
            )
            .await?;
            return Ok(true);
        };
        let install = string(&recipient, "install_id");
        let generation = int(&recipient, "generation");
        let install_epoch = int(&recipient, "epoch");
        let mut members = Vec::<Member>::new();
        let mut after = String::new();
        loop {
            let page = storage::execute(
                db,
                Operation::ReadBurstMembers {
                    presentation: key.to_owned(),
                    cursor: after.to_owned(),
                    activated_at: serde_json::from_value(recipient["activated_at"].clone())?,
                    absence_generation: serde_json::from_value(
                        recipient["absence_generation"].clone(),
                    )?,
                    absence_at: serde_json::from_value(recipient["absence_at"].clone())?,
                    install: install.to_owned(),
                    now: (t),
                },
            )
            .await?
            .rows();
            if page.is_empty() {
                break;
            }
            after = string(page.last().expect("page"), "event_id").into();
            let complete = page.len() < 1000;
            for value in page {
                members.push(serde_json::from_value(value)?);
            }
            if complete {
                break;
            }
        }
        let t = now();
        let mut page_groups = vec![];
        let mut wake = vec![];
        if !members.is_empty() {
            let groups: Vec<Vec<Member>> = if members.len() > 3 {
                vec![members]
            } else {
                members.sort_by(|a, b| {
                    (a.eligible_at, &a.episode_id).cmp(&(b.eligible_at, &b.episode_id))
                });
                members.into_iter().map(|m| vec![m]).collect()
            };
            for members in groups {
                let ids: Vec<_> = members.iter().map(|m| m.event_id.as_str()).collect();
                let group = if members.len() > 3 {
                    let environment = lane(env);
                    let mut parts =
                        vec!["group-v1", &environment, string(&release, "observation_id")];
                    parts.extend(ids.iter().copied());
                    wire::hash(&parts)
                } else {
                    ids[0].into()
                };
                let newest = members
                    .iter()
                    .max_by_key(|m| (m.eligible_at, m.episode_id.as_str()))
                    .expect("members");
                let route_event = &newest.event_id;
                let expires = members.iter().map(|m| m.expires_at).min().expect("members");
                let delivery = wire::hash(&[
                    "delivery-v1",
                    &lane(env),
                    &group,
                    install,
                    &install_epoch.to_string(),
                    feed,
                    &generation.to_string(),
                ]);
                page_groups.push(storage::BurstGroup {
                    delivery: delivery.clone(),
                    presentation: group,
                    route_event: route_event.clone(),
                    expires_at: expires,
                    apns: id(),
                    events: ids.into_iter().map(str::to_owned).collect(),
                });
                wake.push(delivery);
            }
        }
        storage::execute(
            db,
            Operation::GroupBurst {
                page: storage::BurstPage {
                    presentation: key.into(),
                    lease: lease.clone(),
                    now: t,
                    feed: feed.into(),
                    install: install.into(),
                    generation,
                    install_epoch,
                    owner_epoch: epoch,
                    groups: page_groups,
                },
            },
        )
        .await?;
        for delivery in wake {
            let _ = recovery::enqueue(
                env,
                "EPISODE_DELIVERY_QUEUE",
                "feed_polling",
                &delivery,
                generation,
            )
            .await;
        }
        let _ = recovery::enqueue(env, "EVENT_QUEUE", "feed_polling", event_id, 1).await;
        Ok(true)
    }
    .await;
    if result.is_err() {
        storage::execute(
            db,
            Operation::FailBurst {
                presentation: key.to_owned(),
                lease: lease.to_owned(),
                now: (now()),
            },
        )
        .await?
        .count();
    }
    result
}
