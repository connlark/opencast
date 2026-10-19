//! Fixture builds only (the fixture-hooks feature, never a shipped manifest):
//! the polling loop's clock and its completed-boundary gate, and the private
//! routes a fixture build of the polling Worker serves for them. The clock is
//! `timing::monotonic_ms()` plus an offset the test sets, so a test can cross
//! the loop's budget without moving `Date`, `performance.now()` or the storage
//! timing. The gate, once armed, holds the next caller at its boundary until
//! the test releases it; the caller polls its own request's timer, so a
//! release from another request resumes it in its own context.
use super::timing::monotonic_ms;
use std::{cell::Cell, time::Duration};
use worker::{Date, Env, Method, Request, Response, Result};

#[derive(Clone, Copy, PartialEq, Eq)]
enum Gate {
    Open,
    Armed,
    Waiting,
}
thread_local! {
    static LOOP_OFFSET_MS: Cell<f64> = const { Cell::new(0.0) };
    static GATE: Cell<Gate> = const { Cell::new(Gate::Open) };
}
const POLL_MS: u64 = 5;

pub fn set_loop_offset_ms(ms: f64) {
    LOOP_OFFSET_MS.with(|offset| offset.set(ms));
}
pub fn loop_offset_ms() -> f64 {
    LOOP_OFFSET_MS.with(Cell::get)
}
pub fn loop_now_ms() -> f64 {
    monotonic_ms() + loop_offset_ms()
}
pub fn arm_gate() {
    GATE.with(|gate| gate.set(Gate::Armed));
}
/// Opens the gate; true when a caller was waiting at it.
pub fn release_gate() -> bool {
    GATE.with(|gate| gate.replace(Gate::Open)) == Gate::Waiting
}
fn gate_state() -> &'static str {
    match GATE.with(Cell::get) {
        Gate::Open => "open",
        Gate::Armed => "armed",
        Gate::Waiting => "waiting",
    }
}
/// Waits while the gate is armed; true when this call waited.
pub async fn loop_gate() -> bool {
    if GATE.with(Cell::get) != Gate::Armed {
        return false;
    }
    GATE.with(|gate| gate.set(Gate::Waiting));
    while GATE.with(Cell::get) == Gate::Waiting {
        worker::Delay::from(Duration::from_millis(POLL_MS)).await;
    }
    true
}

/// The fixture routes, behind the same private capability as the other
/// polling operations: POST /loop-clock <ms> sets the loop clock's offset,
/// POST /loop-gate arm|release drives the gate, POST /loop-probe stands where
/// the loop's guard stands (it awaits the gate, then reads the loop clock
/// between two `performance.now()` samples, and `Date`), and POST
/// /close-delay <ms> sets the core's close delay. Any other path is not a
/// fixture route.
pub async fn route(request: &Request, env: &Env) -> Result<Option<Response>> {
    let path = request.path();
    if !matches!(
        path.as_str(),
        "/loop-clock" | "/loop-gate" | "/loop-probe" | "/close-delay"
    ) {
        return Ok(None);
    }
    let private = env
        .var("POLLING_CAPABILITY")
        .map(|v| v.to_string() == "private")
        .unwrap_or(false);
    if !private || request.method() != Method::Post {
        return Response::error("not_found", 404).map(Some);
    }
    let text = request.clone()?.text().await?;
    let body = text.trim();
    let json = |value: serde_json::Value| Response::from_json(&value);
    let response = match path.as_str() {
        "/loop-clock" => match body.parse::<f64>() {
            Ok(ms) if ms.is_finite() && ms >= 0.0 => {
                set_loop_offset_ms(ms);
                json(serde_json::json!({"loop_offset_ms": ms}))
            }
            _ => Response::error("invalid_loop_offset", 400),
        },
        "/loop-gate" => match body {
            "arm" => {
                arm_gate();
                json(serde_json::json!({"gate": gate_state()}))
            }
            "release" => {
                let waiter = release_gate();
                json(serde_json::json!({"gate": gate_state(), "released_waiter": waiter}))
            }
            _ => Response::error("invalid_loop_gate", 400),
        },
        "/loop-probe" => {
            let waited = loop_gate().await;
            // The loop clock read between two monotonic samples: the clock can
            // tick between any two reads, so its offset is only defined
            // against the bracket.
            let monotonic_before_ms = monotonic_ms();
            let loop_now = loop_now_ms();
            let monotonic_after_ms = monotonic_ms();
            json(serde_json::json!({
                "waited": waited,
                "monotonic_before_ms": monotonic_before_ms,
                "loop_now_ms": loop_now,
                "monotonic_after_ms": monotonic_after_ms,
                "loop_offset_ms": loop_offset_ms(),
                "date_ms": Date::now().as_millis(),
            }))
        }
        _ => match body.parse::<u64>() {
            Ok(ms) if ms <= opencast_worker_database_core::lifecycle::HANDLER_MS => {
                opencast_worker_database_core::database::set_close_delay_ms(ms);
                json(serde_json::json!({"close_delay_ms": ms}))
            }
            _ => Response::error("invalid_close_delay", 400),
        },
    };
    response.map(Some)
}
