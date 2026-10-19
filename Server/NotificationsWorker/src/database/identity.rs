//! Bind-time identity gate. Off unless the version pins `STORAGE_IDENTITY`;
//! then the first storage call of an isolate reads the bound database's
//! identity once, and every call of that isolate follows the cached verdict.
//! A refusal submits nothing. An unreadable identity is not cached.
use super::authority::{Authority, Backend};
use crate::database_identity::{self as pure, Live, Reason};
use serde_json::{json, Value};
use std::cell::RefCell;

#[derive(Clone)]
struct Verdict {
    accepted: bool,
    report: Value,
}

thread_local! {
    // One verdict per isolate, keyed by the pin.
    static VERDICT: RefCell<Option<(String, Verdict)>> = const { RefCell::new(None) };
}

enum Unreadable {
    Postgres(opencast_worker_database_core::lifecycle::Failure),
}

enum Check {
    Ungated,
    Decided(Verdict),
    Unreadable(Unreadable, Value),
}

fn log(report: &Value) {
    let mut line = json!({"event": "storage_identity"});
    if let (Some(line), Some(report)) = (line.as_object_mut(), report.as_object()) {
        line.extend(report.clone());
    }
    if report["verdict"] == "accepted" {
        worker::console_log!("{line}");
    } else {
        worker::console_warn!("{line}");
    }
}

fn decide(key: String, result: Result<(), Reason>, mut report: Value) -> Check {
    report["verdict"] = json!(if result.is_ok() {
        "accepted"
    } else {
        "refused"
    });
    report["reason"] = json!(result.err().map(Reason::code));
    log(&report);
    let verdict = Verdict {
        accepted: result.is_ok(),
        report,
    };
    VERDICT.with(|cell| *cell.borrow_mut() = Some((key, verdict.clone())));
    Check::Decided(verdict)
}

async fn read(
    authority: &Authority,
    backend: &Backend<'_>,
    pin: &pure::Pin,
) -> Result<Live, Unreadable> {
    match backend {
        Backend::Postgres(env) => {
            let (cancel, deadline) = authority.context();
            let row = super::postgres::identity::read(env, cancel, deadline, pin.reads_system())
                .await
                .map_err(Unreadable::Postgres)?;
            let text = |name: &str| row[name].as_str().map(String::from);
            match (text("database"), text("schema")) {
                (Some(name), Some(schema)) => Ok(Live {
                    schema,
                    database: pure::Database::Postgres {
                        name,
                        system: text("system"),
                    },
                }),
                _ => Err(Unreadable::Postgres(super::decode_failure(true))),
            }
        }
    }
}

async fn check(authority: &Authority, backend: &Backend<'_>) -> Check {
    let Some(pin_text) = authority.identity_pin() else {
        return Check::Ungated;
    };
    let key = format!("{}|{}", pure::backend_code(), pin_text.unwrap_or(""));
    let cached = VERDICT.with(|cell| {
        cell.borrow()
            .as_ref()
            .filter(|(cached, _)| *cached == key)
            .map(|(_, verdict)| verdict.clone())
    });
    if let Some(verdict) = cached {
        return Check::Decided(verdict);
    }
    let environment = authority.identity_environment();
    let mut report = json!({
        "gated": true,
        "backend": pure::backend_code(),
        "environment": environment,
        "expected_schema": pure::expected_schema(),
        "database": null,
        "schema": null,
        "fence": null,
    });
    let Some(pin) = pin_text.ok().and_then(pure::parse) else {
        return decide(key, Err(Reason::Pin), report);
    };
    if let Err(reason) = pure::admit(&pin, environment) {
        return decide(key, Err(reason), report);
    }
    match read(authority, backend, &pin).await {
        Ok(live) => {
            report["database"] = json!(live.database.text());
            report["schema"] = json!(live.schema);
            decide(key, pure::judge(&pin, &live), report)
        }
        Err(unreadable) => {
            report["verdict"] = json!("unreadable");
            report["reason"] = json!(match &unreadable {
                Unreadable::Postgres(failure) => format!("{:?}", failure.kind),
            });
            log(&report);
            Check::Unreadable(unreadable, report)
        }
    }
}

fn outcome(read: bool) -> &'static str {
    if read {
        "NotApplicable"
    } else {
        "NotCommitted"
    }
}

/// Runs before any statement of `operation`. A refusal names the operation
/// and the pre-submission outcome; nothing was submitted.
pub(super) async fn admit(
    authority: &Authority,
    backend: &Backend<'_>,
    operation: &str,
    read: bool,
) -> worker::Result<()> {
    match check(authority, backend).await {
        Check::Ungated => Ok(()),
        Check::Decided(Verdict { accepted: true, .. }) => Ok(()),
        Check::Decided(_) => Err(worker::Error::RustError(format!(
            "storage_{operation}_Identity_{}",
            outcome(read)
        ))),
        Check::Unreadable(Unreadable::Postgres(failure), _) => Err(worker::Error::RustError(
            format!("storage_{operation}_{:?}_{}", failure.kind, outcome(read)),
        )),
    }
}

/// The operator's nonmutating readback: one identity read (or the cached
/// verdict), no gate lock, no write and no authentication.
pub async fn readback(authority: &Authority) -> worker::Result<Value> {
    let backend = authority.backend()?;
    Ok(match check(authority, &backend).await {
        Check::Ungated => json!({
            "gated": false,
            "backend": pure::backend_code(),
        }),
        Check::Decided(verdict) => verdict.report,
        Check::Unreadable(_, report) => report,
    })
}
