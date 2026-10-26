use crate::delivery::{db::*, wire};
use opencast_worker_database_core::lifecycle;
use serde_json::json;
use worker::*;

pub(super) fn flag(env: &Env, name: &str, missing: bool) -> bool {
    env.var(name)
        .map(|v| v.to_string() == "true")
        .unwrap_or(missing)
}
/// Release brakes in the deployment. The stored controls are part of every fence.
pub(super) fn permitted_by_environment(env: &Env) -> bool {
    flag(env, "NOTIFICATION_FEED_OBSERVATION", false)
        && flag(env, "NOTIFICATION_DISPATCHER_ADMISSION", false)
}
pub(super) async fn enabled(env: &Env, db: &crate::database::Authority) -> Result<bool> {
    let enabled = permitted_by_environment(env)
        && crate::database::execute(
            db,
            crate::database::polling::Operation::ReadControl {
                control: crate::database::polling::Control::DispatcherAdmission,
            },
        )
        .await?
        .first()
        .is_some_and(|v| wire::int(&v, "enabled") == 1)
        && crate::database::execute(
            db,
            crate::database::polling::Operation::ReadControl {
                control: crate::database::polling::Control::FeedObservation,
            },
        )
        .await?
        .first()
        .is_some_and(|v| wire::int(&v, "enabled") == 1);
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
/// Writes the invocation's `storage_phases` line when its gate says so: after
/// the handler returned, its error path included.
pub(super) fn emit(db: &crate::database::Authority, consume: bool, ok: bool) {
    let Some((outcome, gated)) = db.witness_emission(consume, ok) else {
        return;
    };
    if !gated {
        return;
    }
    #[cfg(feature = "fixture-hooks")]
    let started = super::timing::monotonic_ms();
    if let Some(line) = db.witness_line(outcome) {
        // Fixture builds only: the line's measured size and build time, for
        // the runtime maxima control. A shipped build has neither.
        #[cfg(feature = "fixture-hooks")]
        console_log!(
            "{}",
            json!({"event":"storage_phases_cost","bytes":line.len(),"build_us":((super::timing::monotonic_ms() - started) * 1000.0).round() as u64})
        );
        console_log!("{}", line.trim_end());
    }
}
pub async fn scheduled(env: Env) -> Result<()> {
    let arrived = super::timing::now_ms();
    let db =
        crate::database::Authority::new(&env, None, super::dispatch::storage_deadline(arrived))?
            .witnessed(arrived, super::timing::monotonic_ms());
    db.note(|witness, _| {
        witness.context.handler = "dispatch";
        witness.context.handler_main_ms = lifecycle::HANDLER_MS;
        witness.context.budget_scope = "main";
        witness.context.budget_source = "HANDLER_MS";
    });
    super::dispatch::run_dispatch(&env, db).await.map(|_| ())
}
pub async fn handle(mut request: Request, env: Env) -> Result<Response> {
    let arrived = super::timing::now_ms();
    let deadline = match request.path().as_str() {
        "/consume" => arrived.saturating_add(
            (super::policy::STEP_DEADLINE_SECONDS + super::policy::BOOKKEEPING_DEADLINE_SECONDS)
                * 1000,
        ),
        "/cleanup" => arrived.saturating_add(
            (super::policy::CLEANUP_BUDGET_SECONDS + super::policy::BOOKKEEPING_DEADLINE_SECONDS)
                * 1000,
        ),
        "/dispatch" => super::dispatch::storage_deadline(arrived),
        _ => crate::database::Authority::default_deadline(arrived),
    };
    let db = crate::database::Authority::new(&env, Some(request.inner().signal()), deadline)?
        .witnessed(arrived, super::timing::monotonic_ms());
    // The main budget a C2 reading divides by, recorded at arrival.
    let budget = match request.path().as_str() {
        "/dispatch" => Some(("dispatch", lifecycle::HANDLER_MS, "main", "HANDLER_MS")),
        "/cleanup" => Some((
            "cleanup",
            super::policy::CLEANUP_BUDGET_SECONDS * 1000,
            "main",
            "CLEANUP_BUDGET",
        )),
        "/consume" => Some((
            "consume",
            super::policy::STEP_DEADLINE_SECONDS * 1000,
            "step",
            "STEP_DEADLINE",
        )),
        "/dead-letter" => Some(("dead_letter", lifecycle::HANDLER_MS, "main", "HANDLER_MS")),
        _ => None,
    };
    if let Some((handler, main_ms, scope, source)) = budget {
        db.note(|witness, _| {
            witness.context.handler = handler;
            witness.context.handler_main_ms = main_ms;
            witness.context.budget_scope = scope;
            witness.context.budget_source = source;
        });
    }
    if matches!(request.path().as_str(), "/dispatch" | "/cleanup") {
        // Set only by the private adapter from the cron's scheduled time: a
        // diagnostic that never authorizes or bounds anything.
        let scheduled = request
            .headers()
            .get("x-poll-scheduled-ms")?
            .filter(|v| !v.is_empty() && v.len() <= 16 && v.bytes().all(|b| b.is_ascii_digit()))
            .and_then(|v| v.parse::<u64>().ok());
        db.note_scheduled(scheduled);
    }
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
    match request.path().as_str() {
        "/dispatch" => {
            let witness = db.clone();
            let result = super::dispatch::run_dispatch(&env, db).await;
            emit(&witness, false, result.is_ok());
            Response::from_json(&result?)
        }
        "/cleanup" => {
            let result = super::cleanup::consume(&env, &db, now().div_euclid(60)).await;
            emit(&db, false, result.is_ok());
            result?;
            Response::ok("cleanup_saved")
        }
        "/stats" => Response::from_json(&super::dispatch::stats(&env, &db).await?),
        "/consume" => {
            let signal = request.inner().signal();
            // Set only by the private adapter from the Queue's own counter.
            let attempts = request
                .headers()
                .get("x-poll-attempts")?
                .and_then(|v| v.parse().ok())
                .unwrap_or(1);
            let enqueued_ms = request
                .headers()
                .get("x-poll-enqueued-ms")?
                .and_then(|v| v.parse().ok());
            // The Queue's own message id, from the same adapter. An opaque
            // in-isolate key only: never stored or logged.
            let message = request
                .headers()
                .get("x-poll-message-id")?
                .filter(|v| !v.is_empty() && v.len() <= 64);
            let Some(wake) = wakeup(&mut request).await? else {
                return Response::error("invalid_wakeup", 400);
            };
            let witness = db.clone();
            let response =
                super::execute::consume(env, wake, attempts, message, signal, enqueued_ms, db)
                    .await;
            emit(&witness, true, response.is_ok());
            response
        }
        "/dead-letter" => {
            let Some(wake) = wakeup(&mut request).await? else {
                return Response::error("invalid_wakeup", 400);
            };
            let witness = db.clone();
            let response = super::execute::dead_letter(&env, &wake, db).await;
            emit(
                &witness,
                false,
                response
                    .as_ref()
                    .is_ok_and(|response| response.status_code() < 500),
            );
            response
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
            crate::database::slice_d::execute(
                &db,
                crate::database::slice_d::Operation::RepairFeed {
                    feed: repair.feed_id.clone(),
                },
            )
            .await?;
            crate::database::slice_d::execute(
                &db,
                crate::database::slice_d::Operation::RepairBursts {
                    feed: repair.feed_id.clone(),
                    now: now(),
                },
            )
            .await?;
            console_log!(
                "{}",
                json!({"event":"poll_operator_repair","feed_id":repair.feed_id})
            );
            Response::ok("repair_saved")
        }
        _ => Response::error("not_found", 404),
    }
}
