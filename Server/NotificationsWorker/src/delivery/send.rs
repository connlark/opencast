use super::{
    db::*,
    wire::{int, string, Event},
};
use crate::{apns, deadline::fetch_with_deadline, feed_stream::FeedFetchCancellation};
use futures_util::StreamExt;
use serde_json::{json, Value};
use std::time::Duration;
use worker::{D1Database, Delay, Env, Headers, Method, Request, RequestInit, Result};

pub async fn deliver(
    db: &D1Database,
    env: &Env,
    source: &str,
    delivery_id: &str,
    generation: i64,
) -> Result<()> {
    let t = now();
    let lease = id();
    let result = async {
    let switch = if source == "feed_polling" {
        "episode_send"
    } else if matches!(source, "ad_analysis" | "remote_transcription") {
        "job_send"
    } else {
        return Ok(());
    };
    if !permitted(env, db, switch).await? {
        return Ok(());
    }
    let apns_environment = env
        .var("APNS_ENVIRONMENT")
        .map(|v| v.to_string())
        .unwrap_or_default();
    let bundle = env
        .var("APPLE_BUNDLE_ID")
        .map(|v| v.to_string())
        .unwrap_or_default();
    let Some(environment) =
        apns::ApnsEnvironment::parse(&apns_environment).filter(|_| !bundle.is_empty())
    else {
        pause(db, "configuration").await?;
        return Ok(());
    };
    let args = [
        json!(delivery_id),
        json!(generation),
        json!(source),
        json!(t),
        json!(lease),
        json!(switch),
    ];
    let eligibility="EXISTS(SELECT 1 FROM n_install i WHERE i.install_id=n_delivery.install_id AND i.epoch=n_delivery.install_epoch AND i.enabled=1 AND i.next_send_at<=?4 AND (n_delivery.source='feed_polling' OR i.job_capable=1)) AND (EXISTS(SELECT 1 FROM n_interest j JOIN n_feed f ON f.feed_id=j.feed_id WHERE j.install_id=n_delivery.install_id AND j.feed_id=n_delivery.interest_key AND j.generation=n_delivery.interest_generation AND j.enabled=1 AND f.send_paused=0 AND f.epoch=n_delivery.owner_epoch) OR EXISTS(SELECT 1 FROM n_job_interest j WHERE j.interest_id=n_delivery.interest_key AND j.install_id=n_delivery.install_id AND j.install_epoch=n_delivery.install_epoch AND j.generation=n_delivery.interest_generation AND j.state='registered'))";
    let claim=statement(db,&format!("UPDATE n_delivery SET state='leased',lease_id=?5,lease_until=?4+60,attempt=attempt+1,attempt_started_at=COALESCE(attempt_started_at,?4),attempt_token_generation=(SELECT token_generation FROM n_install WHERE install_id=n_delivery.install_id) WHERE delivery_id=?1 AND interest_generation=?2 AND source=?3 AND state IN('pending','uncertain') AND next_attempt_at<=?4 AND expires_at>?4 AND failures<10 AND EXISTS(SELECT 1 FROM n_control WHERE name=?6 AND enabled=1) AND NOT EXISTS(SELECT 1 FROM n_circuit WHERE lane='apns' AND paused=1) AND {eligibility}"),&args)?;
    db.batch(vec![claim,
        statement(db,"UPDATE n_install SET next_send_at=?2+1 WHERE install_id=(SELECT install_id FROM n_delivery WHERE delivery_id=?1 AND lease_id=?3)",&[json!(delivery_id),json!(t),json!(lease)])?,
        statement(db,"UPDATE n_job_interest SET attempt_started_at=COALESCE(attempt_started_at,?2) WHERE interest_id=(SELECT interest_key FROM n_delivery WHERE delivery_id=?1 AND lease_id=?3)",&[json!(delivery_id),json!(t),json!(lease)])?,
    ]).await?;
    let Some(row)=first(db,"SELECT d.*,e.envelope_json FROM n_delivery d JOIN n_event e ON e.source=d.source AND e.event_id=d.event_id WHERE d.delivery_id=?1 AND d.lease_id=?2 AND d.state='leased'",&[json!(delivery_id),json!(lease)]).await? else{return Ok(());};
    let event: Event = serde_json::from_str(string(&row, "envelope_json"))?;
    let Some(endpoint)=first(db,"SELECT d.device_token,d.device_token_hash,d.apns_environment,d.bundle_id,i.token_generation,i.registered_at,i.registration_revision FROM n_install i JOIN devices d ON d.install_id=i.install_id AND d.device_token_hash=i.token_hash WHERE i.install_id=?1 AND i.epoch=?2 AND i.enabled=1 AND d.notifications_enabled=1",&[row["install_id"].clone(),row["install_epoch"].clone()]).await? else {
        return finish(db,delivery_id,&lease,"suppressed","no_endpoint",now(),None).await;
    };
    if int(&endpoint, "token_generation") != int(&row, "attempt_token_generation") {
        return finish(
            db,
            delivery_id,
            &lease,
            "pending",
            "token_rotated",
            now() + 1,
            None,
        )
        .await;
    }
    if string(&endpoint, "apns_environment") != apns_environment
        || string(&endpoint, "bundle_id") != bundle
    {
        return finish(
            db,
            delivery_id,
            &lease,
            "suppressed",
            "endpoint_lane",
            now(),
            None,
        )
        .await;
    }
    let mut request = if event.kind == "episode" {
        apns::episode_delivery_push_request(
            string(&endpoint, "device_token"),
            &bundle,
            environment,
            apns::EpisodeNotification {
                podcast_title: string(&event.data, "podcast_title"),
                episode_title: string(&event.data, "episode_title"),
                episode_summary: event.data["episode_summary"].as_str(),
                show_notes_html: None,
                duration_seconds: event.data["episode_duration_seconds"].as_i64(),
                podcast_artwork_url: event.data["artwork_url"].as_str(),
                episode_artwork_url: event.data["episode_artwork_url"].as_str(),
                feed_url: string(&event.data, "feed_url"),
                episode_id: string(&event.routing, "episode_id"),
            },
            event.eligible_at,
        )
        .map_err(|e| worker::Error::RustError(e.code().into()))?
    } else {
        let mut r = apns::diagnostic_push_request(
            string(&endpoint, "device_token"),
            &bundle,
            environment,
            None,
            None,
        )
        .map_err(|e| worker::Error::RustError(e.code().into()))?;
        let mut routing = json!({"schema_version":1,"environment":event.environment,"kind":event.kind,"event_id":event.event_id,"operation_id":event.routing["operation_id"],"run_id":event.routing["run_id"],"completed_at":event.occurred_at});
        for field in ["result_expires_at", "failure_code", "ad_analysis_state"] {
            if let Some(v) = event.data.get(field) {
                routing[field] = v.clone();
            }
        }
        r.body=json!({"aps":{"category":"OPENCAST_JOB_COMPLETION","thread-id":format!("opencast-operation-{}",string(&event.routing,"operation_id")),"sound":"default","alert":{"title":event.data["title"],"body":event.data["body"]}},"opencast":routing}).to_string();
        r
    };
    if event.kind == "episode" {
        apns::group_episode_request(&mut request, int(&row,"member_count"))
            .map_err(|e| worker::Error::RustError(e.code().into()))?;
    }

    request
        .headers
        .retain(|(k, _)| !matches!(*k, "apns-expiration" | "apns-collapse-id" | "apns-id"));
    request.headers.extend([
        ("apns-expiration", int(&row, "expires_at").to_string()),
        ("apns-collapse-id", string(&row, "collapse_id").to_owned()),
        ("apns-id", string(&row, "apns_id").to_owned()),
    ]);
    let fetcher = match env.service("APNS_CERT") {
        Ok(f) => f,
        Err(_) => {
            pause(db, "binding_missing").await?;
            return finish(
                db,
                delivery_id,
                &lease,
                "pending",
                "credentials",
                now() + 300,
                None,
            )
            .await;
        }
    };
    // Final authority query is after endpoint/config I/O and immediately before
    // fetch. It rechecks opt-out, current endpoint, owner, expiry and kill switch.
    if first(db,&format!("SELECT 1 FROM n_delivery WHERE delivery_id=?1 AND interest_generation=?2 AND source=?3 AND lease_id=?5 AND state='leased' AND expires_at>?4 AND lease_until>?4 AND attempt_token_generation=(SELECT token_generation FROM n_install WHERE install_id=n_delivery.install_id) AND EXISTS(SELECT 1 FROM n_control WHERE name=?6 AND enabled=1) AND NOT EXISTS(SELECT 1 FROM n_circuit WHERE lane='apns' AND paused=1) AND {}",eligibility.replace(" AND i.next_send_at<=?4","")),&[json!(delivery_id),json!(generation),json!(source),json!(now()),json!(lease),json!(switch)]).await?.is_none() {
        return finish(db,delivery_id,&lease,"pending","authority_changed",now()+60,None).await;
    }
    let outcome = attempt(fetcher, request).await;
    let t = now();
    let (state, reason, retry) = match &outcome {
        None => (
            "uncertain",
            "response_unknown",
            backoff(int(&row, "attempt")),
        ),
        Some(o) if o.status == 200 => ("accepted", "accepted", 0),
        Some(o)
            if o.status == 403
                || matches!(
                    o.reason.as_str(),
                    "ExpiredProviderToken"
                        | "InvalidProviderToken"
                        | "BadCertificate"
                        | "BadCertificateEnvironment"
                        | "MissingProviderToken"
                ) =>
        {
            pause(db, "credentials").await?;
            ("pending", "credentials", 300)
        }
        Some(o)
            if o.status == 410
                || (o.status == 400
                    && matches!(
                        o.reason.as_str(),
                        "BadDeviceToken" | "DeviceTokenNotForTopic"
                    )) =>
        {
            let timestamp = if o.status == 410 {
                o.timestamp.unwrap_or(0) / 1000
            } else {
                t
            };
            let changed=run(db,"UPDATE devices SET device_token='',notifications_enabled=0,last_seen_at=?5 WHERE install_id=?1 AND device_token_hash=?2 AND EXISTS(SELECT 1 FROM n_install i WHERE i.install_id=?1 AND i.token_hash=?2 AND i.token_generation=?3 AND i.registered_at<=?4 AND i.registration_revision=?6)",&[row["install_id"].clone(),endpoint["device_token_hash"].clone(),row["attempt_token_generation"].clone(),json!(timestamp),json!(t),endpoint["registration_revision"].clone()]).await?;
            if changed == 0 {
                if row["stale_410_generation"].as_i64()==row["attempt_token_generation"].as_i64() {
                    // Suppress this delivery only. An older APNs timestamp still
                    // cannot invalidate the installation's newer registration.
                    ("suppressed", "stale_token", 0)
                } else {
                    run(db,"UPDATE n_delivery SET stale_410_generation=?3 WHERE delivery_id=?1 AND lease_id=?2",&[json!(delivery_id),json!(lease),row["attempt_token_generation"].clone()]).await?;
                    ("pending", "stale_410", backoff(int(&row,"attempt")))
                }
            } else {
                ("suppressed", "token_invalid", 0)
            }
        }
        Some(o) if o.status == 429 => ("pending", "throttled", o.retry_after.unwrap_or(60).max(1)),
        Some(o) if o.status >= 500 => {
            ("pending", "apns_unavailable", backoff(int(&row, "attempt")))
        }
        Some(_) => ("permanent_failure", "apns_payload", 0),
    };
    if reason == "throttled" {
        run(
            db,
            "UPDATE n_install SET next_send_at=MAX(next_send_at,?2) WHERE install_id=?1",
            &[row["install_id"].clone(), json!(t + retry)],
        )
        .await?;
    }
    finish(
        db,
        delivery_id,
        &lease,
        state,
        reason,
        (t + retry).min(event.expires_at),
        Some(&event),
    )
    .await
    }.await;
    if result.is_err() {
        super::recovery::failed(db, "delivery", source, delivery_id, &lease).await?;
    }
    result
}

fn backoff(attempt: i64) -> i64 {
    match attempt {
        0 | 1 => 5,
        2 => 15,
        3 => 60,
        _ => 300,
    }
}
async fn pause(db: &D1Database, reason: &str) -> Result<()> {
    run(
        db,
        "UPDATE n_circuit SET paused=1,reason=?1,updated_at=?2 WHERE lane='apns'",
        &[json!(reason), json!(now())],
    )
    .await?;
    worker::console_error!("notification apns circuit paused: {}", reason);
    Ok(())
}
async fn finish(
    db: &D1Database,
    id: &str,
    lease: &str,
    state: &str,
    reason: &str,
    next: i64,
    _event: Option<&Event>,
) -> Result<()> {
    let terminal = matches!(
        state,
        "accepted" | "suppressed" | "expired" | "permanent_failure"
    );
    let writes=vec![statement(db,"UPDATE n_delivery SET state=?3,last_reason=?4,next_attempt_at=?5,terminal_at=?6,lease_id=NULL,lease_until=NULL,failures=0 WHERE delivery_id=?1 AND lease_id=?2 AND state='leased'",&[json!(id),json!(lease),json!(state),json!(reason),json!(next),if terminal {json!(now())} else {Value::Null}])?];
    db.batch(writes).await?;
    Ok(())
}

pub(crate) struct Outcome {
    pub status: u16,
    pub apns_id: Option<String>,
    pub reason: String,
    timestamp: Option<i64>,
    retry_after: Option<i64>,
}
pub(crate) async fn attempt(
    fetcher: worker::Fetcher,
    request: apns::PushRequest,
) -> Option<Outcome> {
    let cancellation = FeedFetchCancellation::default();
    let work = async {
        let headers = Headers::new();
        for (k, v) in request.headers {
            headers.set(k, &v)?;
        }
        let mut init = RequestInit::new();
        init.with_method(Method::Post)
            .with_headers(headers)
            .with_body(Some(request.body.into()));
        let init: worker::web_sys::RequestInit = (&init).into();
        init.set_signal(Some(&cancellation.signal()));
        let request = Request::from(worker::web_sys::Request::new_with_str_and_init(
            &request.url,
            &init,
        )?);
        let mut response = fetcher.fetch_request(request).await?;
        let status = response.status_code();
        let apns_id = response.headers().get("apns-id")?;
        let retry_after = response.headers().get("Retry-After")?.and_then(|s| {
            s.parse::<i64>().ok().or_else(|| {
                Some(((worker::js_sys::Date::parse(&s) as u64 / 1000) as i64 - now()).max(1))
            })
        });
        let mut bytes = vec![];
        if status != 200 {
            let mut stream = response.stream()?;
            while let Some(chunk) = stream.next().await {
                let chunk = chunk?;
                if bytes.len() + chunk.len() > 2048 {
                    break;
                }
                bytes.extend(chunk);
            }
        }
        let v: Value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
        Ok::<_, worker::Error>(Outcome {
            status,
            apns_id,
            reason: string(&v, "reason").to_owned(),
            timestamp: v["timestamp"].as_i64(),
            retry_after,
        })
    };
    fetch_with_deadline(
        work,
        Delay::from(Duration::from_secs(15)),
        worker::Error::RustError("apns_timeout".into()),
    )
    .await
    .ok()
}

/// The existing diagnostic endpoint keeps its public response shape while using
/// the same kill switch, circuit and token-version rules as durable delivery.
pub(crate) async fn diagnostic(
    db: &D1Database,
    env: &Env,
    install: &str,
    token_hash: &str,
    request: apns::PushRequest,
) -> Result<Option<Outcome>> {
    let fetcher = match env.service("APNS_CERT") {
        Ok(f) => f,
        Err(_) => {
            pause(db, "binding_missing").await?;
            return Ok(None);
        }
    };
    if !permitted(env, db, "diagnostic_send").await? {
        return Ok(None);
    }
    let Some(endpoint)=first(db,"SELECT token_generation,registration_revision FROM n_install WHERE install_id=?1 AND token_hash=?2 AND enabled=1 AND NOT EXISTS(SELECT 1 FROM n_circuit WHERE lane='apns' AND paused=1) AND EXISTS(SELECT 1 FROM n_control WHERE name='diagnostic_send' AND enabled=1)",&[json!(install),json!(token_hash)]).await? else { return Ok(None); };
    let outcome = attempt(fetcher, request).await;
    if let Some(o) = &outcome {
        if o.status == 403 {
            pause(db, "credentials").await?;
        }
        if o.status == 410
            || (o.status == 400
                && matches!(
                    o.reason.as_str(),
                    "BadDeviceToken" | "DeviceTokenNotForTopic"
                ))
        {
            let invalidated = if o.status == 410 {
                o.timestamp.unwrap_or(0) / 1000
            } else {
                now()
            };
            run(db,"UPDATE devices SET device_token='',notifications_enabled=0,last_seen_at=?5 WHERE install_id=?1 AND device_token_hash=?2 AND EXISTS(SELECT 1 FROM n_install WHERE install_id=?1 AND token_hash=?2 AND token_generation=?3 AND registered_at<=?4 AND registration_revision=?6)",&[json!(install),json!(token_hash),endpoint["token_generation"].clone(),json!(invalidated),json!(now()),endpoint["registration_revision"].clone()]).await?;
        }
    }
    Ok(outcome)
}
