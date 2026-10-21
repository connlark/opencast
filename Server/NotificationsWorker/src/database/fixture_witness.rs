//! Storage-fixture builds only: one semantic entry run under a WITNESSED
//! authority whose core cancellation is the fixture's token, answered with the
//! storage_phases line its witness builds (the runtime's own builder). A
//! request the invocation owner disposes logs that line from its drop instead,
//! outcome cancelled, so the owner abort leaves its record too.
use super::Authority;
use serde::Deserialize;
use serde_json::{json, Value};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Input<T> {
    request: T,
}

struct Emit {
    authority: Authority,
    done: bool,
}
impl Drop for Emit {
    fn drop(&mut self) {
        if !self.done {
            if let Some(line) = self.authority.witness_line("cancelled") {
                worker::console_log!("{}", line.trim_end());
            }
        }
    }
}

fn parse<T: serde::de::DeserializeOwned>(text: &str) -> Option<T> {
    serde_json::from_str::<Input<T>>(text)
        .ok()
        .map(|input| input.request)
}

pub(super) async fn handle(
    route: &str,
    mut request: worker::Request,
    env: worker::Env,
    arrived: u64,
) -> worker::Result<worker::Response> {
    let deadline = arrived + opencast_worker_database_core::lifecycle::HANDLER_MS;
    let authority = Authority::new(&env, None, deadline)?
        .witnessed(arrived, crate::polling::timing::monotonic_ms())
        .with_cancel(super::fixture::cancel::token());
    let mut emit = Emit {
        authority: authority.clone(),
        done: false,
    };
    let text = request.text().await?;
    let invalid = || worker::Response::error("invalid_semantic_request", 400);
    let result = match route {
        "operation" => match parse(&text) {
            Some(op) => super::execute(&authority, op).await,
            None => return invalid(),
        },
        "slice-d/operation" => match parse(&text) {
            Some(op) => super::slice_d::execute(&authority, op).await,
            None => return invalid(),
        },
        "slice-e/operation" => match parse(&text) {
            Some(op) => super::slice_e::execute(&authority, op).await,
            None => return invalid(),
        },
        "slice-f/operation" => match parse(&text) {
            Some(op) => super::slice_f::execute(&authority, op).await,
            None => return invalid(),
        },
        _ => return worker::Response::error("unported_operation", 404),
    };
    emit.done = true;
    let line = authority
        .witness_line(if result.is_ok() { "ok" } else { "failed" })
        .and_then(|line| serde_json::from_str::<Value>(line.trim_end()).ok())
        .unwrap_or(Value::Null);
    worker::Response::from_json(&json!({
        "ok": result.is_ok(),
        "error": result.as_ref().err().map(|error| error.to_string()),
        "line": line,
    }))
}
