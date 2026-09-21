//! One complete observation determines presentation membership. Fanout waits
//! for the source drain and every member receipt before assigning recipients.
use super::{
    db::*,
    recovery,
    wire::{self, int, string},
};
use serde::Deserialize;
use serde_json::json;

#[derive(Deserialize)]
struct Member {
    event_id: String,
    episode_id: String,
    eligible_at: i64,
    expires_at: i64,
}
use worker::{D1Database, Env, Result};

pub async fn page(db: &D1Database, env: &Env, event_id: &str) -> Result<bool> {
    let Some(release) = first(
        db,
        "SELECT r.* FROM n_episode_release r WHERE event_id=?1",
        &[json!(event_id)],
    )
    .await?
    else {
        return Ok(false);
    };
    let key = string(&release, "presentation_key");
    let feed = string(&release, "feed_id");
    let epoch = int(&release, "owner_epoch");
    let t = now();
    if first(db,"SELECT 1 FROM n_episode_release r JOIN n_observation o ON o.observation_id=r.observation_id LEFT JOIN n_event e ON e.source='feed_polling' AND e.event_id=r.event_id WHERE r.presentation_key=?1 AND (o.drain_complete=0 OR (r.state NOT IN('withdrawn','expired') AND e.event_id IS NULL)) LIMIT 1",&[json!(key)]).await?.is_some(){return Ok(true);}
    run(db,"INSERT INTO n_burst(presentation_key,feed_id,owner_epoch) VALUES(?1,?2,?3) ON CONFLICT DO NOTHING",&[json!(key),json!(feed),json!(epoch)]).await?;
    let lease = id();
    if run(db,"UPDATE n_burst SET lease_id=?2,lease_until=?3+180 WHERE presentation_key=?1 AND complete=0 AND failures<10 AND next_attempt_at<=?3 AND (lease_id IS NULL OR lease_until<=?3) AND EXISTS(SELECT 1 FROM n_feed f WHERE f.feed_id=n_burst.feed_id AND f.epoch=n_burst.owner_epoch)",&[json!(key),json!(lease),json!(t)]).await?==0{return Ok(true);}
    let result=async {
    let burst = first(
        db,
        "SELECT * FROM n_burst WHERE presentation_key=?1 AND lease_id=?2",
        &[json!(key), json!(lease)],
    )
    .await?
    .expect("claimed burst");
    let cursor = string(&burst, "cursor");
    // One installation per invocation bounds the large-burst transaction.
    let recipient=first(db,"SELECT j.*,i.epoch FROM n_interest j JOIN n_install i ON i.install_id=j.install_id WHERE j.feed_id=?1 AND j.enabled=1 AND i.enabled=1 AND j.install_id>?2 ORDER BY j.install_id LIMIT 1",&[json!(feed),json!(cursor)]).await?;
    let fence="EXISTS(SELECT 1 FROM n_burst b JOIN n_feed f ON f.feed_id=b.feed_id WHERE b.presentation_key=?1 AND b.lease_id=?2 AND b.lease_until>?3 AND b.complete=0 AND f.epoch=b.owner_epoch)";
    let Some(recipient) = recipient else {
        db.batch(vec![
            statement(db,&format!("UPDATE n_event SET fanout_complete=1 WHERE source='feed_polling' AND event_id IN(SELECT event_id FROM n_episode_release WHERE presentation_key=?1) AND {fence}"),&[json!(key),json!(lease),json!(now())])?,
            statement(db,&format!("UPDATE n_burst SET complete=1,lease_id=NULL,lease_until=NULL WHERE presentation_key=?1 AND {fence}"),&[json!(key),json!(lease),json!(now())])?,
        ]).await?;
        return Ok(true);
    };
    let install = string(&recipient, "install_id");
    let generation = int(&recipient, "generation");
    let install_epoch = int(&recipient, "epoch");
    let mut members = Vec::<Member>::new();
    let mut after = String::new();
    loop {
        let page=rows(db,"SELECT r.event_id,r.eligible_at,r.episode_id,r.expires_at FROM n_episode_release r JOIN n_event e ON e.event_id=r.event_id AND e.source='feed_polling' WHERE r.presentation_key=?1 AND r.event_id>?2 AND e.disposition='accepted' AND ((r.reason IN('undated','anomalous_date') AND ?3<=r.first_observed_at AND ?4<r.generation AND ?5>=?3 AND ?5<=r.first_observed_at) OR (r.reason NOT IN('undated','anomalous_date') AND r.eligible_at>=?3 AND r.published_at>=?3)) AND NOT EXISTS(SELECT 1 FROM n_legacy_bridge b WHERE b.install_id=?6 AND b.feed_id=r.feed_id AND b.expires_at>?7 AND b.identity_key IN('episode:'||r.episode_id,'fingerprint:v2:'||r.fingerprint)) ORDER BY r.event_id LIMIT 1000",&[json!(key),json!(after),recipient["activated_at"].clone(),recipient["absence_generation"].clone(),recipient["absence_at"].clone(),json!(install),json!(t)]).await?;
        if page.is_empty() {
            break;
        }
        after = string(page.last().expect("page"), "event_id").into();
        let complete = page.len() < 1000;
        for value in page {members.push(serde_json::from_value(value)?);}
        if complete {
            break;
        }
    }
    let t = now();
    let recipient_fence=format!("{fence} AND EXISTS(SELECT 1 FROM n_interest j JOIN n_install i ON i.install_id=j.install_id WHERE j.feed_id=?4 AND j.install_id=?5 AND j.generation=?6 AND j.enabled=1 AND i.epoch=?7 AND i.enabled=1)");
    let base = vec![
        json!(key),
        json!(lease),
        json!(t),
        json!(feed),
        json!(install),
        json!(generation),
        json!(install_epoch),
    ];
    let mut writes = vec![];
    let mut wake = vec![];
    if !members.is_empty() {
        let groups: Vec<Vec<Member>> = if members.len() > 3 {
            vec![members]
        } else {
            members.sort_by(|a,b|(a.eligible_at,&a.episode_id).cmp(&(b.eligible_at,&b.episode_id)));
            members.into_iter().map(|m| vec![m]).collect()
        };
        for members in groups {
            let ids: Vec<_> = members.iter().map(|m| m.event_id.as_str()).collect();
            let group = if members.len() > 3 {
                let environment = lane(env);
                let mut parts = vec!["group-v1", &environment, string(&release, "observation_id")];
                parts.extend(ids.iter().copied());
                wire::hash(&parts)
            } else {
                ids[0].into()
            };
            let newest = members
                .iter()
                .max_by_key(|m| (m.eligible_at,m.episode_id.as_str()))
                .expect("members");
            let route_event = &newest.event_id;
            let expires = members
                .iter()
                .map(|m| m.expires_at)
                .min()
                .expect("members");
            let delivery = wire::hash(&[
                "delivery-v1",
                &lane(env),
                &group,
                install,
                &install_epoch.to_string(),
                feed,
                &generation.to_string(),
            ]);
            let mut args = base.clone();
            args.extend([
                json!(delivery),
                json!(group),
                json!(route_event),
                json!(expires),
                json!(id()),
                json!(epoch),
                json!(members.len()),
            ]);
            writes.push(statement(db,&format!("INSERT INTO n_delivery(delivery_id,presentation_id,install_id,install_epoch,interest_key,interest_generation,state,expires_at,next_attempt_at,apns_id,collapse_id,source,event_id,owner_epoch,member_count) SELECT ?8,?9,?5,?7,?4,?6,'pending',?11,?3,?12,?8,'feed_polling',?10,?13,?14 WHERE {recipient_fence} ON CONFLICT DO NOTHING"),&args)?);
            for (page_number, chunk) in members.chunks(1000).enumerate() {
                let mut args = base.clone();
                args.extend([
                    json!(delivery),
                    json!(group),
                    json!(chunk.iter().map(|m|m.event_id.as_str()).collect::<Vec<_>>()),
                    json!(page_number * 1000),
                ]);
                if members.len() > 3 {
                    writes.push(statement(db,&format!("INSERT INTO n_group_member(group_id,source,event_id,ordinal) SELECT ?9,'feed_polling',value,CAST(j.key AS INTEGER)+?11 FROM json_each(?10) j WHERE {recipient_fence} AND EXISTS(SELECT 1 FROM n_delivery WHERE delivery_id=?8) ON CONFLICT DO NOTHING"),&args)?);
                }
                writes.push(statement(db,&format!("INSERT INTO n_delivery_member(delivery_id,source,event_id,install_id,install_epoch,interest_generation) SELECT ?8,'feed_polling',value,?5,?7,?6 FROM json_each(?10) WHERE {recipient_fence} AND EXISTS(SELECT 1 FROM n_delivery WHERE delivery_id=?8) ON CONFLICT DO NOTHING"),&args[..10])?);
            }
            wake.push(delivery);
        }
    }
    writes.push(statement(db,&format!("UPDATE n_burst SET cursor=?4,lease_id=NULL,lease_until=NULL,failures=0,next_attempt_at=0 WHERE presentation_key=?1 AND {fence}"),&[json!(key),json!(lease),json!(t),json!(install)])?);
    db.batch(writes).await?;
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
    }.await;
    if result.is_err() {
        run(db,"UPDATE n_burst SET failures=failures+1,next_attempt_at=?3+300,lease_id=NULL,lease_until=NULL WHERE presentation_key=?1 AND lease_id=?2",&[json!(key),json!(lease),json!(now())]).await?;
    }
    result
}
