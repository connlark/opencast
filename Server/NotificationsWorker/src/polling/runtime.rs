use crate::delivery::{db::*, wire};
use serde_json::json;
use worker::*;

pub(super) fn flag(env: &Env, name: &str, missing: bool) -> bool {
    env.var(name)
        .map(|v| v.to_string() == "true")
        .unwrap_or(missing)
}
/// Release brakes in the deployment. The D1 controls are part of every fence.
pub(super) fn permitted_by_environment(env: &Env) -> bool {
    flag(env, "NOTIFICATION_FEED_OBSERVATION", false)
        && flag(env, "NOTIFICATION_DISPATCHER_ADMISSION", false)
}
pub(super) async fn enabled(env: &Env, db: &D1Database) -> Result<bool> {
    let enabled = permitted_by_environment(env)
        && control(db, "dispatcher_admission").await?
        && control(db, "feed_observation").await?;
    if enabled {
        env.service("NOTIFICATION_EVENTS")
            .map_err(|_| Error::RustError("notification_events_binding_missing".into()))?;
    }
    Ok(enabled)
}
async fn wakeup(request: &mut Request) -> Result<Option<super::dispatch::Wakeup>> {
    use futures_util::StreamExt;
    let mut bytes = vec![];
    let mut stream = request.stream()?;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        if bytes.len() + chunk.len() > 1024 {
            return Ok(None);
        }
        bytes.extend(chunk);
    }
    Ok(serde_json::from_slice(&bytes).ok())
}
pub async fn scheduled(env: Env) -> Result<()> {
    super::dispatch::run_dispatch(&env).await.map(|_| ())
}
pub async fn handle(mut request: Request, env: Env) -> Result<Response> {
    if env
        .var("POLLING_CAPABILITY")
        .map(|v| v.to_string() != "private")
        .unwrap_or(true)
    {
        return Response::error("not_found", 404);
    }
    if request.method() != Method::Post {
        return Response::error("method_not_allowed", 405);
    }
    let db = env.d1("APP_ATTEST_DB")?;
    match request.path().as_str() {
        "/dispatch" => Response::from_json(&super::dispatch::run_dispatch(&env).await?),
        "/stats" => Response::from_json(&super::dispatch::stats(&db).await?),
        "/consume" => {
            let signal = request.inner().signal();
            // Set only by the private adapter from the Queue's own counter.
            let attempts = request
                .headers()
                .get("x-poll-attempts")?
                .and_then(|v| v.parse().ok())
                .unwrap_or(1);
            let Some(wake) = wakeup(&mut request).await? else {
                return Response::error("invalid_wakeup", 400);
            };
            super::execute::consume(env, wake, attempts, signal).await
        }
        "/dead-letter" => {
            let Some(wake) = wakeup(&mut request).await? else {
                return Response::error("invalid_wakeup", 400);
            };
            super::execute::dead_letter(&env, &wake).await
        }
        "/repair" => {
            #[derive(serde::Deserialize)]
            #[serde(deny_unknown_fields)]
            struct Repair {
                feed_id: String,
            }
            // Private operator action. It cannot change owner, enable controls or
            // renew an event; it only retries durable work after investigation.
            let repair: Repair = request.json().await?;
            if !wire::hex_id(&repair.feed_id) {
                return Response::error("invalid_feed_id", 400);
            }
            // Retry an investigated dead-lettered feed now, not at its backoff.
            run(&db,"UPDATE n_feed SET handling_failures=0,retry_at=0,last_poll_error='operator_repair' WHERE feed_id=?1 AND handling_failures>0",&[json!(repair.feed_id)]).await?;
            run(&db,"UPDATE n_burst SET failures=0,next_attempt_at=?2,lease_id=NULL,lease_until=NULL WHERE feed_id=?1 AND complete=0 AND failures>=10",&[json!(repair.feed_id),json!(now())]).await?;
            console_log!(
                "{}",
                json!({"event":"poll_operator_repair","feed_id":repair.feed_id})
            );
            Response::ok("repair_saved")
        }
        _ => Response::error("not_found", 404),
    }
}
