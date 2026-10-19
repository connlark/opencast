use super::{
    db::*,
    wire::{int, string, Event},
};
use crate::database::slice_d::{self as storage, Operation};
use crate::{apns, deadline::fetch_with_deadline, feed_stream::FeedFetchCancellation};
use futures_util::StreamExt;
use serde_json::{json, Value};
use std::time::Duration;
use worker::{Delay, Env, Headers, Method, Request, RequestInit, Result};

pub async fn deliver(
    db: &crate::database::Authority,
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
    if !crate::database::permitted(env, db, switch).await? {
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
    storage::execute(db,Operation::ClaimDelivery {delivery:delivery_id.into(),generation,source:source.into(),now:t,lease:lease.clone(),control:switch.into()}).await?;
    let Some(row)=storage::execute(db, Operation::ReadClaimedDelivery { delivery: delivery_id.to_owned(), lease: lease.to_owned() }).await?.first() else{return Ok(());};
    let event: Event = serde_json::from_str(string(&row, "envelope_json"))?;
    let Some(endpoint)=storage::execute(db, Operation::ReadEndpoint { install: serde_json::from_value(row["install_id"].clone())?, epoch: serde_json::from_value(row["install_epoch"].clone())? }).await?.first() else {
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
    if storage::execute(db, Operation::ReadSendAuthority { delivery: delivery_id.to_owned(), generation, source: source.to_owned(), now: now(), lease: lease.to_owned(), control: switch.to_owned() }).await?.first().is_none() {
        return finish(db,delivery_id,&lease,"pending","authority_changed",now()+60,None).await;
    }
    let started = worker::Date::now().as_millis();
    let outcome = attempt(fetcher, request).await;
    let latency_ms = worker::Date::now().as_millis().saturating_sub(started);
    let t = now();
    // The witness line is written even when deciding the disposition fails,
    // so every APNs attempt leaves exactly one line.
    let disposition = async { Ok::<_, worker::Error>(match &outcome {
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
            let changed=storage::execute(db, Operation::InvalidateEndpoint { install: serde_json::from_value(row["install_id"].clone())?, token_hash: serde_json::from_value(endpoint["device_token_hash"].clone())?, token_generation: serde_json::from_value(row["attempt_token_generation"].clone())?, invalidated_at: timestamp, now: t, registration_revision: serde_json::from_value(endpoint["registration_revision"].clone())? }).await?.count();
            if changed == 0 {
                if row["stale_410_generation"].as_i64()==row["attempt_token_generation"].as_i64() {
                    // Suppress this delivery only. An older APNs timestamp still
                    // cannot invalidate the installation's newer registration.
                    ("suppressed", "stale_token", 0)
                } else {
                    storage::execute(db, Operation::MarkStaleToken { delivery: delivery_id.to_owned(), lease: lease.to_owned(), token_generation: serde_json::from_value(row["attempt_token_generation"].clone())? }).await?.count();
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
    }) }.await;
    let witness = super::witness::ApnsSend {
        source,
        kind: &event.kind,
        event_id: &event.event_id,
        device_token_hash: string(&endpoint, "device_token_hash"),
        attempt: int(&row, "attempt"),
        status: outcome.as_ref().map(|o| o.status),
        apns_id: outcome.as_ref().and_then(|o| o.apns_id.as_deref()),
        apns_reason: outcome.as_ref().map_or("", |o| o.reason.as_str()),
        latency_ms,
        disposition: disposition.as_ref().ok().map(|(state, reason, _)| (*state, *reason)),
    };
    if witness.accepted() {
        worker::console_log!("{}", witness.line());
    } else {
        worker::console_warn!("{}", witness.line());
    }
    let (state, reason, retry) = disposition?;
    if reason == "throttled" {
        storage::execute(db, Operation::ThrottleInstall { install: serde_json::from_value(row["install_id"].clone())?, until: (t + retry) }).await?.count();
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
async fn pause(db: &crate::database::Authority, reason: &str) -> Result<()> {
    storage::execute(
        db,
        Operation::PauseCircuit {
            reason: reason.to_owned(),
            now: now(),
        },
    )
    .await?
    .count();
    worker::console_error!("notification apns circuit paused: {}", reason);
    Ok(())
}
async fn finish(
    db: &crate::database::Authority,
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
    storage::execute(
        db,
        Operation::FinishDelivery {
            delivery: id.into(),
            lease: lease.into(),
            state: state.into(),
            reason: reason.into(),
            next,
            terminal_at: if terminal { Some(now()) } else { None },
        },
    )
    .await?;
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
    db: &crate::database::Authority,
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
    if !crate::database::permitted(env, db, "diagnostic_send").await? {
        return Ok(None);
    }
    let Some(endpoint) = storage::execute(
        db,
        Operation::ReadDiagnosticAuthority {
            install: install.to_owned(),
            token_hash: token_hash.to_owned(),
        },
    )
    .await?
    .first() else {
        return Ok(None);
    };
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
            storage::execute(
                db,
                Operation::InvalidateDiagnosticEndpoint {
                    install: install.to_owned(),
                    token_hash: token_hash.to_owned(),
                    token_generation: serde_json::from_value(endpoint["token_generation"].clone())?,
                    invalidated_at: invalidated,
                    now: now(),
                    registration_revision: serde_json::from_value(
                        endpoint["registration_revision"].clone(),
                    )?,
                },
            )
            .await?
            .count();
        }
    }
    Ok(outcome)
}
